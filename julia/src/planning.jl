using JuMP, HiGHS

# ── Daily capacity planning LP ───────────────────────────────────────────────
#
# Given external milk/cream inputs and initial silo levels, find the
# production plan that maximises revenue subject to:
#   - Equipment capacity (hours per horizon)
#   - Silo balance (end levels within [0, capacity])
#   - Supply limits (can't consume more than available)
#
# Fully data-driven from process.operations + machine modes + Yield quantities.
# Decision variables: hours allocated to each machine mode (x[machine_id][mode_id]).

# ── Available hours ──────────────────────────────────────────────────────────

# Maximum production hours for a machine in `horizon` hours, accounting for
# forced cleaning cycles (max_run_hours + clean_hours).
function avail_hours(machine::Dict{String,Any}, horizon::Float64)::Float64
    if haskey(machine, "max_run_hours") && haskey(machine, "clean_hours")
        max_run = Float64(machine["max_run_hours"])
        clean   = Float64(machine["clean_hours"])
        cycle   = max_run + clean
        n_full  = floor(horizon / cycle)
        remain  = horizon - n_full * cycle
        return n_full * max_run + min(remain, max_run)
    end
    horizon
end

# ── LP solver ────────────────────────────────────────────────────────────────

"""
    plan(machines, quantities, external_in, initial_levels, capacity, prices, horizon_hr)

Build and solve the daily capacity planning LP.

- `machines`       — machine defs with modes pre-enriched with `inputs` / `outputs`
- `quantities`     — from Yield.compute(): kg per kg of master input (milk)
- `external_in`    — Dict{stream_id => kg} of external supply arriving this period
- `initial_levels` — Dict{silo_id => kg} current silo levels
- `capacity`       — Dict{silo_id => kg} silo capacity (absent = unlimited)
- `prices`         — Dict{stream_id => price/kg} revenue per kg of output stream
- `horizon_hr`     — planning horizon in hours
- `labels`         — Dict{id => display name} for streams and machines (optional)

Returns a Dict ready for JSON serialisation.
"""
function plan(
    machines::Vector{Dict{String,Any}},
    quantities::Dict{String,Float64},
    external_in::Dict{String,Float64},
    initial_levels::Dict{String,Float64},
    capacity::Dict{String,Float64},
    prices::Dict{String,Float64},
    horizon_hr::Float64;
    labels::Dict{String,String} = Dict{String,String}(),
)::Dict{String,Any}

    model = Model(HiGHS.Optimizer)
    set_silent(model)

    # ── Decision variables: hours per mode ──────────────────────────────────
    # x[(machine_id, mode_id)] ≥ 0
    mode_list = Tuple{String,String,Dict{String,Any}}[]  # (machine_id, mode_id, mode_dict)
    for machine in machines
        mid = string(machine["id"])
        for mode in machine["modes"]
            push!(mode_list, (mid, string(mode["id"]), mode))
        end
    end

    @variable(model, x[i=1:length(mode_list)] >= 0)

    # Index helpers
    mode_idx = Dict((m, mo) => i for (i, (m, mo, _)) in enumerate(mode_list))

    # ── Equipment capacity constraints ──────────────────────────────────────
    for machine in machines
        mid   = string(machine["id"])
        avail = avail_hours(machine, horizon_hr)
        # Sum of hours across all modes of this machine ≤ available hours
        idxs  = [mode_idx[(mid, string(mode["id"]))] for mode in machine["modes"]]
        @constraint(model, sum(x[i] for i in idxs) <= avail)
    end

    # ── Silo balance constraints ─────────────────────────────────────────────
    #
    # For each silo stream s:
    #   end_level = initial[s] + external_in[s]
    #             + Σ_{modes producing s} x[i] * rate[i] * (qty[s] / qty[driver[i]])
    #             - Σ_{modes consuming s} x[i] * rate[i] * (qty[s] / qty[driver[i]])
    #   0 ≤ end_level ≤ capacity[s]
    #
    # Collect all silo stream ids (streams that have silos).
    silo_streams = collect(keys(initial_levels))

    for stream in silo_streams
        init  = get(initial_levels, stream, 0.0)
        ext   = get(external_in,    stream, 0.0)

        # Net flow into this silo from all machine modes
        net_terms = AffExpr()
        for (i, (_, _, mode)) in enumerate(mode_list)
            rate   = Float64(mode["rate_kg_per_hour"])
            inputs  = [string(s) for s in get(mode, "inputs",  [])]
            outputs = [string(s) for s in get(mode, "outputs", [])]
            isempty(inputs) && continue
            driver     = inputs[1]
            driver_qty = get(quantities, driver, 1.0)

            if stream in outputs
                qty_s = get(quantities, stream, 0.0)
                ratio = driver_qty > 0 ? qty_s / driver_qty : 0.0
                add_to_expression!(net_terms, x[i] * rate * ratio)
            end
            if stream in inputs
                qty_s = get(quantities, stream, 0.0)
                ratio = driver_qty > 0 ? qty_s / driver_qty : 0.0
                add_to_expression!(net_terms, -x[i] * rate * ratio)
            end
        end

        # end_level ≥ 0 (hard — can't consume more than available)
        # Upper capacity is NOT enforced here; overflow is reported after solving.
        @constraint(model, init + ext + net_terms >= 0)
    end

    # ── Objective: maximise revenue ──────────────────────────────────────────
    revenue = AffExpr()
    for (i, (_, _, mode)) in enumerate(mode_list)
        rate    = Float64(mode["rate_kg_per_hour"])
        inputs  = [string(s) for s in get(mode, "inputs",  [])]
        outputs = [string(s) for s in get(mode, "outputs", [])]
        isempty(inputs) && continue
        driver     = inputs[1]
        driver_qty = get(quantities, driver, 1.0)

        for out in outputs
            price = get(prices, out, 0.0)
            price == 0.0 && continue
            qty_out = get(quantities, out, 0.0)
            ratio   = driver_qty > 0 ? qty_out / driver_qty : 0.0
            add_to_expression!(revenue, x[i] * rate * ratio * price)
        end
    end
    @objective(model, Max, revenue)

    optimize!(model)

    status = string(termination_status(model))

    if primal_status(model) != MOI.FEASIBLE_POINT
        # Log silo constraint bounds to make infeasibility obvious.
        # A silo is impossible if its lower bound alone (external_in + initial) already
        # exceeds its capacity, or if even running everything flat-out can't drain it.
        @warn "plan infeasible" status
        for stream in silo_streams
            init  = get(initial_levels, stream, 0.0)
            ext   = get(external_in,    stream, 0.0)
            cap   = get(capacity,       stream, Inf)
            floor_level = init + ext   # level with no production/consumption
            @info "  silo" stream floor_level cap feasible=(floor_level <= cap)
        end
        return Dict{String,Any}("status" => status)
    end

    x_val = value.(x)

    # ── Build result flows: machine_id => mode_id => hours ──────────────────
    flows = Dict{String,Any}()
    for (i, (mid, moid, _)) in enumerate(mode_list)
        get!(flows, mid, Dict{String,Any}())[moid] = x_val[i]
    end

    # ── Compute end silo levels ──────────────────────────────────────────────
    end_levels = Dict{String,Float64}()
    for stream in silo_streams
        init = get(initial_levels, stream, 0.0)
        ext  = get(external_in,    stream, 0.0)
        net  = 0.0
        for (i, (_, _, mode)) in enumerate(mode_list)
            rate    = Float64(mode["rate_kg_per_hour"])
            inputs  = [string(s) for s in get(mode, "inputs",  [])]
            outputs = [string(s) for s in get(mode, "outputs", [])]
            isempty(inputs) && continue
            driver     = inputs[1]
            driver_qty = get(quantities, driver, 1.0)

            if stream in outputs
                qty_s = get(quantities, stream, 0.0)
                ratio = driver_qty > 0 ? qty_s / driver_qty : 0.0
                net  += x_val[i] * rate * ratio
            end
            if stream in inputs
                qty_s = get(quantities, stream, 0.0)
                ratio = driver_qty > 0 ? qty_s / driver_qty : 0.0
                net  -= x_val[i] * rate * ratio
            end
        end
        end_levels[stream] = init + ext + net
    end

    # ── Compute output stream quantities ─────────────────────────────────────
    outputs = Dict{String,Float64}()
    for (i, (_, _, mode)) in enumerate(mode_list)
        rate    = Float64(mode["rate_kg_per_hour"])
        inputs  = [string(s) for s in get(mode, "inputs",  [])]
        outs    = [string(s) for s in get(mode, "outputs", [])]
        isempty(inputs) && continue
        driver     = inputs[1]
        driver_qty = get(quantities, driver, 1.0)

        for out in outs
            # Only track streams that are NOT in silos (i.e. final outputs)
            out in silo_streams && continue
            qty_out = get(quantities, out, 0.0)
            ratio   = driver_qty > 0 ? qty_out / driver_qty : 0.0
            outputs[out] = get(outputs, out, 0.0) + x_val[i] * rate * ratio
        end
    end

    # Silos whose end level exceeds physical capacity.
    overfull = Set{String}(
        s for s in silo_streams
        if get(end_levels, s, 0.0) > get(capacity, s, Inf) + 0.5
    )

    # Machines running flat-out (allocated hours ≈ available hours).
    at_capacity = Set{String}()
    for machine in machines
        mid   = string(machine["id"])
        avail = avail_hours(machine, horizon_hr)
        avail < 0.01 && continue
        total = sum(x_val[mode_idx[(mid, string(mode["id"]))]] for mode in machine["modes"])
        if avail - total < 0.01
            push!(at_capacity, mid)
        end
    end

    machine_avail = Dict{String,Float64}(
        string(machine["id"]) => avail_hours(machine, horizon_hr)
        for machine in machines
    )

    sankey = build_plan_sankey(
        mode_list, quantities, external_in, initial_levels, end_levels, x_val,
        labels, capacity, overfull, at_capacity, machine_avail
    )

    Dict{String,Any}(
        "status"          => status,
        "flows"           => flows,
        "end_levels"      => end_levels,
        "overfull_silos"  => collect(overfull),
        "outputs"         => outputs,
        "revenue"         => objective_value(model),
        "sankey"          => sankey,
    )
end

# ── Sankey ───────────────────────────────────────────────────────────────────
#
# Nodes:
#   - One node per stream that carries flow (using display name from `labels`).
#   - One node per physical machine (merged across modes).
#   - One "(end)" node per silo that has material left over.
#
# For streams that are ONLY externally supplied (e.g. milk — no machine produces
# it), the stream node is a natural left-side source.  For streams that are both
# produced by machines AND externally supplied (e.g. cream when cream_in > 0),
# we add an explicit "Cream supply" source so the node visually balances.
#
# Links carry kg (rounded to 1 decimal place).

function build_plan_sankey(
    mode_list::Vector{Tuple{String,String,Dict{String,Any}}},
    quantities::Dict{String,Float64},
    external_in::Dict{String,Float64},
    initial_levels::Dict{String,Float64},
    end_levels::Dict{String,Float64},
    x_val::Vector{Float64},
    labels::Dict{String,String},
    capacity::Dict{String,Float64},
    overfull::Set{String},          # stream ids whose end level exceeds capacity
    at_capacity::Set{String},       # machine ids running at full available hours
    machine_avail::Dict{String,Float64},
)::Dict{String,Any}

    label(id) = get(labels, id, id)

    node_order = String[]
    node_set   = Set{String}()
    links      = Dict{Tuple{String,String}, Float64}()
    node_extra = Dict{String,Dict{String,Any}}()   # extra fields merged into each node dict

    add_node!(n)        = (n ∉ node_set && (push!(node_set, n); push!(node_order, n)))
    add_link!(s, t, kg) = begin
        kg < 0.5 && return
        add_node!(s); add_node!(t)
        key = (s, t)
        links[key] = get(links, key, 0.0) + kg
    end

    # Pre-compute total hours allocated per machine across all its modes.
    machine_hours_used = Dict{String,Float64}()
    for (i, (mid, _, _)) in enumerate(mode_list)
        machine_hours_used[mid] = get(machine_hours_used, mid, 0.0) + x_val[i]
    end

    # Which streams does any machine produce?
    machine_outputs = Set{String}()
    for (_, _, mode) in mode_list
        for s in get(mode, "outputs", []); push!(machine_outputs, string(s)); end
    end

    # Machine flow links (stream → machine, machine → stream).
    # Group by machine_id so the display name is consistent across modes.
    for (i, (mid, _, mode)) in enumerate(mode_list)
        hours = x_val[i]
        hours < 1e-6 && continue
        rate       = Float64(mode["rate_kg_per_hour"])
        inputs     = [string(s) for s in get(mode, "inputs",  [])]
        outputs    = [string(s) for s in get(mode, "outputs", [])]
        isempty(inputs) && continue
        driver     = inputs[1]
        driver_qty = get(quantities, driver, 1.0)
        mname      = mid ∈ at_capacity ? label(mid) * " AT CAPACITY" : label(mid)

        # Annotate machine node with hours (only needs to be set once per machine).
        if !haskey(node_extra, mname)
            node_extra[mname] = Dict{String,Any}(
                "hours_used"  => round(machine_hours_used[mid], digits = 1),
                "hours_avail" => round(get(machine_avail, mid, 0.0), digits = 1),
            )
        end

        for inp in inputs
            qty_s = get(quantities, inp, 1.0)
            ratio = driver_qty > 0 ? qty_s / driver_qty : 0.0
            add_link!(label(inp), mname, hours * rate * ratio)
        end
        for out in outputs
            qty_s = get(quantities, out, 0.0)
            ratio = driver_qty > 0 ? qty_s / driver_qty : 0.0
            add_link!(mname, label(out), hours * rate * ratio)
        end
    end

    # External supply links.
    # Streams not produced by any machine are natural source nodes — no extra link.
    # Streams also produced by machines (e.g. cream with cream_in > 0) need an
    # explicit source node so the diagram visually balances.
    for (stream, ext) in external_in
        init  = get(initial_levels, stream, 0.0)
        total = ext + init
        total < 0.5 && continue
        if stream ∈ machine_outputs
            add_link!(label(stream) * " supply", label(stream), total)
        end
    end

    # Silo remainder links: stream node → "(end)" sink.
    # Overfull silos get an " OVERFULL" suffix so the label is self-explanatory.
    for (stream, end_kg) in end_levels
        end_kg < 0.5 && continue
        end_name = stream ∈ overfull ? label(stream) * " (end) OVERFULL" : label(stream) * " (end)"
        add_link!(label(stream), end_name, end_kg)
        cap = get(capacity, stream, Inf)
        node_extra[end_name] = Dict{String,Any}(
            "level_t"    => round(end_kg / 1000, digits = 1),
            "capacity_t" => isfinite(cap) ? round(cap / 1000, digits = 1) : nothing,
        )
    end

    # Red nodes: overfull silo ends + at-capacity machines.
    red_nodes = union(
        Set{String}(get(labels, s, s) * " (end) OVERFULL" for s in overfull),
        Set{String}(get(labels, m, m) * " AT CAPACITY"    for m in at_capacity),
    )

    function make_node(n)
        d = Dict{String,Any}("name" => n)
        n ∈ red_nodes && (d["itemStyle"] = Dict("color" => "#dc3545"))
        haskey(node_extra, n) && merge!(d, node_extra[n])
        d
    end

    Dict{String,Any}(
        "nodes" => [make_node(n) for n in node_order],
        "links" => [Dict("source" => src, "target" => tgt, "value" => round(kg, digits = 1))
                    for ((src, tgt), kg) in links],
    )
end

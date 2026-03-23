using Oxygen, HTTP, Dates, JSON3, Yield

include(joinpath(@__DIR__, "bind.jl"))
include(joinpath(@__DIR__, "simulation.jl"))
include(joinpath(@__DIR__, "planning.jl"))

# ── Handlers ────────────────────────────────────────────────────────────────────

function health(::HTTP.Request)
    json(Dict("status" => "ok", "time" => string(now())))
end

# GET /config — returns site.json verbatim; the frontend loads this on startup.
function site_config(::HTTP.Request, data_dir::String)
    f = joinpath(data_dir, "site.json")
    isfile(f) || return json(Dict("error" => "no site config"), status = 404)
    json(JSON3.read(read(f, String), Dict{String, Any}))
end

# POST /yield — stateless mass-balance solve.
# Body is the "process" section of site.json (a Yield.jl-compatible config dict)
# with any slider overrides already applied by the frontend.
function yield_calc(req::HTTP.Request)
    config = try
        JSON3.read(String(req.body), Dict{String, Any})
    catch
        return json(Dict("error" => "invalid JSON"), status = 400)
    end

    quantities, compositions = try
        Yield.compute(config)
    catch e
        @warn "Yield computation failed" exception=(e, catch_backtrace())
        return json(Dict("error" => "yield computation failed: $(sprint(showerror, e))"), status = 422)
    end

    # Merge quantity into each stream's composition dict for a flat, easy-to-use shape.
    streams = Dict{String, Any}(
        s => merge(
            Dict{String, Any}("quantity" => quantities[s]),
            Dict{String, Any}(compositions[s]),
        )
        for s in keys(quantities)
    )

    json(Dict{String, Any}(
        "streams" => streams,
        "sankey"  => Yield.sankey_data(quantities, config),
    ))
end

# POST /simulate — event-driven silo-level simulation.
# Body: { process, intakes, blocks, horizon_hr }
#   process    — Yield.jl config dict (same shape as the yield endpoint body)
#   intakes    — [{ silo_id, start_hr, end_hr, rate_kg_per_hr }]
#   blocks     — [{ machine_id, mode, start_hr, end_hr }]
#   horizon_hr — simulation length in hours (default 24)
#
# Machines and silos are loaded from site.json; the process config drives the
# mass-balance ratios that determine how much of each stream each machine produces.
function simulate_run(req::HTTP.Request, data_dir::String)
    body = try
        JSON3.read(String(req.body), Dict{String, Any})
    catch
        return json(Dict("error" => "invalid JSON"), status = 400)
    end

    haskey(body, "process") || return json(Dict("error" => "missing 'process'"), status = 400)

    # Load site.json for machine and silo definitions.
    site_path = joinpath(data_dir, "site.json")
    isfile(site_path) || return json(Dict("error" => "no site config"), status = 500)
    site_raw = JSON3.read(read(site_path, String), Dict{String, Any})

    # Normalise nested JSON3.Objects to plain Dict{String,Any} so all key lookups
    # use strings consistently (JSON3 uses Symbol keys for nested objects).
    norm(x) = JSON3.read(JSON3.write(x), Dict{String, Any})
    norm_vec(x) = [norm(e) for e in x]

    machines = norm_vec(get(site_raw, "machines", []))
    silos    = norm_vec(get(site_raw, "silos",    []))

    # Run Yield to get per-stream mass ratios (kg per kg of driver stream).
    process_config = norm(body["process"])
    quantities, _ = try
        Yield.compute(process_config)
    catch e
        @warn "Yield failed in simulate_run" exception=(e, catch_backtrace())
        return json(Dict("error" => "yield failed: $(sprint(showerror, e))"), status = 422)
    end

    # Build operation lookup: id → operation (for pre-joining inputs/outputs onto modes).
    ops_by_id = Dict{String, Dict{String, Any}}(
        string(op["id"]) => norm(op)
        for op in get(process_config, "operations", [])
        if haskey(op, "id")
    )

    # Pre-join each mode with its operation's inputs/outputs so compute_effects
    # is fully data-driven with no machine-type branching.
    enrich_mode(mode) = let op = get(ops_by_id, string(mode["operation"]), Dict{String,Any}())
        merge(mode, Dict{String,Any}(
            "inputs"  => [string(s) for s in get(op, "inputs",  get(op, "input",  []))],
            "outputs" => [string(s) for s in get(op, "outputs", get(op, "output", []))],
        ))
    end

    # Apply rate overrides from the frontend: { machine_id => { mode_id => { rate_kg_per_hour => value } } }.
    rates_raw = get(body, "rates", nothing)
    mode_overrides = rates_raw !== nothing ? norm(rates_raw) : Dict{String,Any}()

    machines = [
        let id            = string(m["id"])
            mach_overrides = get(mode_overrides, id, Dict{String,Any}())
            enriched_modes = [
                let mid = string(mode["id"])
                    enriched = enrich_mode(norm(mode))
                    haskey(mach_overrides, mid) ? merge(enriched, norm(mach_overrides[mid])) : enriched
                end
                for mode in m["modes"]
            ]
            merge(m, Dict{String,Any}("modes" => enriched_modes))
        end
        for m in machines
    ]

    effects = compute_effects(machines, quantities)

    # Pull max_run_hours / clean_hours out of machines that have them.
    machine_params = Dict{String, Dict{String, Any}}()
    for m in machines
        p = Dict{String, Any}(k => m[k] for k in ("max_run_hours", "clean_hours", "changeover_hours") if haskey(m, k))
        isempty(p) || (machine_params[string(m["id"])] = p)
    end

    initial_levels = Dict{String, Float64}(string(s["id"]) => Float64(get(s, "initial_kg", 0.0)) for s in silos)
    capacity       = Dict{String, Float64}(string(s["id"]) => Float64(get(s, "volume_kg", Inf)) for s in silos)
    # Frontend capacity overrides (edited by the user at runtime) take precedence.
    for (silo_id, kg) in get(body, "capacities", Dict{String,Any}())
        capacity[string(silo_id)] = Float64(kg)
    end
    horizon_hr     = Float64(get(body, "horizon_hr", 24.0))

    intakes = Intake[]
    for i in norm_vec(get(body, "intakes", []))
        push!(intakes, Intake(string(i["silo_id"]), Float64(i["start_hr"]), Float64(i["end_hr"]), Float64(i["rate_kg_per_hr"])))
    end

    blocks = Block[]
    for b in norm_vec(get(body, "blocks", []))
        push!(blocks, Block(string(b["machine_id"]), string(b["mode"]), Float64(b["start_hr"]), Float64(b["end_hr"])))
    end

    result = try
        simulate(intakes, blocks, initial_levels, capacity, effects, machine_params, horizon_hr)
    catch e
        @error "simulate failed" exception=(e, catch_backtrace())
        return json(Dict("error" => "simulation error: $(sprint(showerror, e))"), status=500)
    end

    json(Dict{String, Any}(
        "snapshots" => [Dict{String, Any}(
            "time_hr"      => s.time_hr,
            "levels"       => s.levels,
            "label"        => s.label,
            "equipment_id" => s.equipment_id,
            "mode"         => s.mode,
        ) for s in result.snapshots],
        "intervals" => [Dict{String, Any}(
            "machine_id"  => iv.machine_id,
            "mode"        => iv.mode,
            "start_hr"    => iv.start_hr,
            "end_hr"      => iv.end_hr,
            "stop_reason" => iv.stop_reason,
        ) for iv in result.intervals],
        "effects" => effects,
    ))
end

# POST /plan — daily capacity planning LP.
# Body: { process, milk_in, cream_in, prices, horizon_hr, initial_levels?, capacities? }
#   process        — Yield.jl config dict
#   milk_in        — kg raw milk arriving this period (default 0)
#   cream_in       — kg cream arriving from external source (default 0)
#   prices         — { stream_id: $/kg } for output streams (default {})
#   horizon_hr     — planning horizon in hours (default 24)
#   initial_levels — { silo_id: kg } overrides for silo starting levels
#   capacities     — { silo_id: kg } overrides for silo capacities
function plan_run(req::HTTP.Request, data_dir::String)
    body = try
        JSON3.read(String(req.body), Dict{String,Any})
    catch
        return json(Dict("error" => "invalid JSON"), status = 400)
    end

    haskey(body, "process") || return json(Dict("error" => "missing 'process'"), status = 400)

    site_path = joinpath(data_dir, "site.json")
    isfile(site_path) || return json(Dict("error" => "no site config"), status = 500)
    site_raw = JSON3.read(read(site_path, String), Dict{String,Any})

    norm(x)     = JSON3.read(JSON3.write(x), Dict{String,Any})
    norm_vec(x) = [norm(e) for e in x]

    machines = norm_vec(get(site_raw, "machines", []))
    silos    = norm_vec(get(site_raw, "silos",    []))

    process_config = norm(body["process"])
    quantities, _ = try
        Yield.compute(process_config)
    catch e
        @warn "Yield failed in plan_run" exception=(e, catch_backtrace())
        return json(Dict("error" => "yield failed: $(sprint(showerror, e))"), status = 422)
    end

    ops_by_id = Dict{String,Dict{String,Any}}(
        string(op["id"]) => norm(op)
        for op in get(process_config, "operations", [])
        if haskey(op, "id")
    )
    enrich_mode(mode) = let op = get(ops_by_id, string(mode["operation"]), Dict{String,Any}())
        merge(mode, Dict{String,Any}(
            "inputs"  => [string(s) for s in get(op, "inputs",  get(op, "input",  []))],
            "outputs" => [string(s) for s in get(op, "outputs", get(op, "output", []))],
        ))
    end
    machines = [merge(m, Dict{String,Any}("modes" => [enrich_mode(norm(mode)) for mode in m["modes"]])) for m in machines]

    initial_levels = Dict{String,Float64}(string(s["id"]) => Float64(get(s, "initial_kg", 0.0)) for s in silos)
    for (k, v) in get(body, "initial_levels", Dict{String,Any}())
        initial_levels[string(k)] = Float64(v)
    end

    capacity = Dict{String,Float64}(string(s["id"]) => Float64(get(s, "volume_kg", Inf)) for s in silos)
    for (k, v) in get(body, "capacities", Dict{String,Any}())
        capacity[string(k)] = Float64(v)
    end

    external_in = Dict{String,Float64}(
        "milk"  => Float64(get(body, "milk_in",  0.0)),
        "cream" => Float64(get(body, "cream_in", 0.0)),
    )

    prices = Dict{String,Float64}()
    for (k, v) in get(body, "prices", Dict{String,Any}())
        prices[string(k)] = Float64(v)
    end

    horizon_hr = Float64(get(body, "horizon_hr", 24.0))

    labels = Dict{String,String}(
        string(s["id"]) => string(s["name"]) for s in get(site_raw, "streams", [])
    )
    for m in norm_vec(get(site_raw, "machines", []))
        labels[string(m["id"])] = string(m["name"])
    end

    @info "plan request" milk_in=external_in["milk"] cream_in=external_in["cream"] horizon_hr prices

    result = try
        plan(machines, quantities, external_in, initial_levels, capacity, prices, horizon_hr; labels)
    catch e
        @error "plan failed" exception=(e, catch_backtrace())
        return json(Dict("error" => "planning error: $(sprint(showerror, e))"), status = 500)
    end

    @info "plan result" status=result["status"] revenue=get(result, "revenue", nothing)

    json(result)
end

# ── Route registration ──────────────────────────────────────────────────────────

function register_routes(data_dir::String)
    @get  "/health"   health
    @get  "/config"   req -> site_config(req, data_dir)
    @post "/yield"    yield_calc
    @post "/simulate" req -> simulate_run(req, data_dir)
    @post "/plan"     req -> plan_run(req, data_dir)
end

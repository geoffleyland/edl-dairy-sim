using JuMP, HiGHS

# ── 𝓓 data structs ──────────────────────────────────────────────────────────
#
# Post-validation, pre-model.  Both load_from_json() (tests / fixtures) and
# load_from_db() (production, Layer 2) must produce the same 𝓓 structs.
# Everything downstream — the JuMP model — sees no difference.

struct ShiftCapacity
    shift_id        ::String
    capacity        ::Int
end

struct Plant
    id              ::String
    shifts          ::Vector{ShiftCapacity}
end

struct Supply
    farm_id         ::String
    stock_type_id   ::String
    quantity        ::Int
end

struct Delivery
    farm_id         ::String
    stock_type_id   ::String
    plant_id        ::String
    shift_id        ::String
    quantity        ::Int
end

struct ProblemData
    plants          ::Vector{Plant}
    supplies        ::Vector{Supply}
    deliveries      ::Vector{Delivery}
end

# Default: no existing deliveries when the field is absent from JSON.
computed_fields(::Type{ProblemData}) = Dict(
    :deliveries => _ -> Delivery[],
)

struct SolveResult
    status          ::Symbol              # :optimal | :infeasible | :error
    deliveries      ::Vector{Delivery}
    objective       ::Int
end

# ── Data loading ─────────────────────────────────────────────────────────────
#
# Accepts a materialised Dict{String,Any} — typically from:
#   JSON3.read(str, Dict{String,Any})

function load_problem(d::Dict{String, Any}) :: ProblemData
    bind(d, ProblemData)
end

# ── Solver ───────────────────────────────────────────────────────────────────
#
# Phase 1 model: maximise total quantity processed subject to:
#   • supply limits  — sum over (plant, shift) ≤ available quantity per (farm, stock type)
#   • shift capacity — sum over (farm, stock type) ≤ capacity per (plant, shift)
#
# Farms may be split across plants freely (no do-not-split constraint yet).
# The constraint matrix is totally unimodular, so the LP relaxation always
# yields integer solutions when supply and capacity are integers.
# This ceases to hold once do-not-split or minimum collection constraints are
# added — integer variables will be required at that point.
#
# 𝓓.deliveries — deliveries already entered by the user.  These are honoured
# even if they violate constraints: the corresponding decision variables are
# fixed with fix(), and effective supply and capacity bounds are expanded to
# match any over-committed delivery, so the violation is preserved but not
# worsened.  The solver fills whatever headroom remains.  The returned
# deliveries are the union of existing and solver additions.


function build_model(𝓓::ProblemData)::Model
    𝓜 = Model(HiGHS.Optimizer)
    set_silent(𝓜)

    existing_supply_commitments = Dict()
    existing_processing_commitments = Dict()
    for a in 𝓓.deliveries
        existing_supply_commitments[(a.farm_id, a.stock_type_id)] =
            get(existing_supply_commitments, (a.farm_id, a.stock_type_id), 0) + a.quantity
        existing_processing_commitments[(a.plant_id, a.shift_id)] =
            get(existing_processing_commitments, (a.plant_id, a.shift_id), 0) + a.quantity
    end

    supply_quantities = Dict((q.farm_id, q.stock_type_id) =>
        max(q.quantity, get(existing_supply_commitments, (q.farm_id, q.stock_type_id), 0))
        for q in 𝓓.supplies)
    plant_shift_capacities = Dict((p.id, s.shift_id) =>
        max(s.capacity, get(existing_processing_commitments, (p.id, s.shift_id), 0))
        for p in 𝓓.plants for s in p.shifts)

    @variables 𝓜 begin
        0 <= deliveries[qk in keys(supply_quantities), psk in keys(plant_shift_capacities)] <= supply_quantities[qk], Int
    end

    for a in 𝓓.deliveries
        fix(deliveries[(a.farm_id, a.stock_type_id), (a.plant_id, a.shift_id)], a.quantity, force=true)
    end

    @constraints 𝓜 begin
        deliveries_must_not_exceed_supply[qk in keys(supply_quantities)],
        sum(deliveries[qk, psk] for psk in keys(plant_shift_capacities)) <= supply_quantities[qk]

        deliveries_must_not_exceed_shift_capacity[psk in keys(plant_shift_capacities)],
        sum(deliveries[qk, psk] for qk in keys(supply_quantities)) <= plant_shift_capacities[psk]
    end

    @objective(𝓜, Max, sum(deliveries))

    𝓜
end


function solve(𝓜::Model, 𝓓::ProblemData)::SolveResult
    n_supply_rows  = length(𝓓.supplies)
    n_shift_slots  = sum(length(p.shifts) for p in 𝓓.plants; init = 0)
    n_pinned       = length(𝓓.deliveries)
    n_vars         = num_variables(𝓜)
    @info "Solving" supply_rows=n_supply_rows shift_slots=n_shift_slots variables=n_vars pinned=n_pinned

    optimize!(𝓜)

    status     = termination_status(𝓜)
    solve_time = round(Int, JuMP.solve_time(𝓜) * 1000)
    gap        = MOI.get(𝓜, MOI.RelativeGap())

    if status != MOI.OPTIMAL
        @warn "Solve failed" solver_status=status solve_time_ms=solve_time
        return SolveResult(:infeasible, 𝓓.deliveries, 0)
    end

    obj = round(Int, objective_value(𝓜))
    @info "Solved" status=:optimal objective=obj solve_time_ms=solve_time gap=gap

    d = 𝓜[:deliveries]
    deliveries = [Delivery(qk[1], qk[2], psk[1], psk[2], round(Int, value(d[qk, psk])))
                  for qk in axes(d, 1) for psk in axes(d, 2) if value(d[qk, psk]) > 0]

    SolveResult(:optimal, deliveries, obj)
end

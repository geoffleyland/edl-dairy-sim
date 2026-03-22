# Event-driven dairy factory simulation.
#
# Tracks silo levels (kg) over time given:
#   - Intakes:  scheduled raw-material deliveries
#   - Blocks:   scheduled machine runs
#   - Effects:  kg/hr change per silo for each machine mode (precomputed from Yield ratios)
#
# Machines with max_run_hours / clean_hours (condenser, drier) auto-schedule forced
# cleans when their run time reaches the limit, then resume the scheduled mode.

using DataStructures

# ── Public output types ─────────────────────────────────────────────────────────

# Each snapshot records silo levels at a moment in time.
# label/equipment_id/mode describe what event caused it ("" for t=0 and horizon).
struct Snapshot
    time_hr::Float64
    levels::Dict{String, Float64}
    label::String
    equipment_id::String
    mode::String
end

struct SimResult
    snapshots::Vector{Snapshot}
end

# ── Public input types ──────────────────────────────────────────────────────────

struct Intake
    silo_id::String
    start_hr::Float64
    end_hr::Float64
    rate_kg_per_hr::Float64
end

struct Block
    machine_id::String
    mode::String
    start_hr::Float64
    end_hr::Float64
end

# ── compute_effects ─────────────────────────────────────────────────────────────
#
# Build the effects table from Yield mass-balance ratios and machine mode rates.
# Fully data-driven: no machine-type branching. Each mode declares an operation
# (via site.json machines[].modes[].operation); routes.jl pre-joins the operation's
# inputs/outputs onto the mode before calling this function.
#
# For each mode the driver stream is inputs[1]. All input rates are proportional to
# the driver via Yield quantities; all output rates are derived the same way.
#
# `machines`   — machines array from site.json, with each mode already carrying
#                "inputs" and "outputs" arrays from the referenced operation
# `quantities` — from Yield.compute(): kg of each stream per kg of driver stream
#
# Returns: Dict{ machine_id => Dict{ mode_id => Dict{ stream_id => Δkg/hr } } }
# Positive Δ = filling, negative = draining.

function compute_effects(
    machines,
    quantities::Dict{String, Float64},
)::Dict{String, Dict{String, Dict{String, Float64}}}

    effects = Dict{String, Dict{String, Dict{String, Float64}}}()

    for machine in machines
        machine_id          = string(machine["id"])
        effects[machine_id] = Dict{String, Dict{String, Float64}}()

        for mode in machine["modes"]
            mode_id       = string(mode["id"])
            rate          = Float64(mode["rate_kg_per_hour"])
            inputs        = [string(s) for s in mode["inputs"]]
            outputs       = [string(s) for s in mode["outputs"]]
            driver        = inputs[1]
            driver_qty    = get(quantities, driver, 0.0)

            stream_deltas = Dict{String, Float64}()

            for input in inputs
                ratio = driver_qty > 0 ? get(quantities, input, driver_qty) / driver_qty : 0.0
                stream_deltas[input] = -rate * ratio
            end

            for output in outputs
                ratio = driver_qty > 0 ? get(quantities, output, 0.0) / driver_qty : 0.0
                stream_deltas[output] = +rate * ratio
            end

            effects[machine_id][mode_id] = stream_deltas
        end
    end

    effects
end

# ── Heap event ──────────────────────────────────────────────────────────────────

# End/off events fire before start events at the same time (a machine stopping at
# hour 5 frees its resources before another starts at hour 5).
const PRIORITY_END   = 0
const PRIORITY_START = 1

# A handler returns STALE to suppress the event label on its snapshot.
const STALE = false

struct Event
    time::Float64
    priority::Int
    serial::Int
    label::String        # recorded in the snapshot ("" for internal/sentinel events)
    equipment_id::String # machine id, silo id, or "" for non-equipment events
    handler::Function
end
Base.isless(a::Event, b::Event) =
    (a.time, a.priority, a.serial) < (b.time, b.priority, b.serial)

# ── Simulation state ────────────────────────────────────────────────────────────

mutable struct SimState
    time::Float64
    levels::Dict{String, Float64}           # current kg per silo
    rates::Dict{String, Float64}            # current net kg/hr per silo
    scheduled::Dict{String, String}         # what the user schedule says
    running::Dict{String, String}           # what's actually happening (may differ during clean)
    effects::Dict{String, Dict{String, Dict{String, Float64}}}
    machine_params::Dict{String, Dict{String, Any}}
    snapshots::Vector{Snapshot}
    heap::BinaryMinHeap{Event}
    serial::Int
end

# ── Internal helpers ────────────────────────────────────────────────────────────

function schedule!(state::SimState, at::Float64, label::String, equipment_id::String,
                   handler::Function, priority::Int = PRIORITY_START)
    state.serial += 1
    push!(state.heap, Event(at, priority, state.serial, label, equipment_id, handler))
end

# Advance all silo levels forward to time `to` at current rates, then update clock.
function advance!(state::SimState, to::Float64)
    elapsed = to - state.time
    elapsed > 0 || return
    for (silo, rate) in state.rates
        state.levels[silo] = get(state.levels, silo, 0.0) + rate * elapsed
    end
    state.time = to
end

# Switch a machine to `mode`, removing the old mode's rate contributions first.
function apply_mode!(state::SimState, machine_id::String, mode::String)
    old = get(state.running, machine_id, "off")
    if old != "off"
        for (silo, rate) in get(get(state.effects, machine_id, Dict()), old, Dict())
            state.rates[silo] = get(state.rates, silo, 0.0) - rate
        end
    end
    for (silo, rate) in get(get(state.effects, machine_id, Dict()), mode, Dict())
        state.rates[silo] = get(state.rates, silo, 0.0) + rate
    end
    state.running[machine_id] = mode
end

# Schedule a forced clean at `state.time + max_run_hours` if the machine has those params.
# When clean finishes, resume the scheduled mode and re-arm the next clean.
function maybe_schedule_clean!(state::SimState, machine_id::String)
    params = get(state.machine_params, machine_id, nothing)
    params === nothing && return
    haskey(params, "max_run_hours") || return

    max_run   = Float64(params["max_run_hours"])
    clean_dur = Float64(params["clean_hours"])
    clean_at  = state.time + max_run

    schedule!(state, clean_at, "clean-start", machine_id, function ()
        # Stale event: machine already off or mid-clean — skip.
        get(state.running, machine_id, "off") ∈ ("off", "cleaning") && return STALE
        apply_mode!(state, machine_id, "cleaning")

        clean_end = clean_at + clean_dur
        schedule!(state, clean_end, "clean-end", machine_id, function ()
            next = get(state.scheduled, machine_id, "off")
            apply_mode!(state, machine_id, next)
            next != "off" && maybe_schedule_clean!(state, machine_id)
        end)
    end)
end

# ── Public API ──────────────────────────────────────────────────────────────────

"""
    simulate(intakes, blocks, initial_levels, effects, machine_params, horizon_hr)

Run the event-driven simulation and return a `SimResult`.

- `intakes`        — scheduled raw-material deliveries (`Vector{Intake}`)
- `blocks`         — scheduled machine runs (`Vector{Block}`)
- `initial_levels` — `Dict{silo_id => initial_kg}`
- `effects`        — from `compute_effects`
- `machine_params` — `Dict{machine_id => Dict}` with `"max_run_hours"` / `"clean_hours"` if needed
- `horizon_hr`     — simulation end time in hours
"""
function simulate(
    intakes::Vector{Intake},
    blocks::Vector{Block},
    initial_levels::Dict{String, Float64},
    effects::Dict{String, Dict{String, Dict{String, Float64}}},
    machine_params::Dict{String, Dict{String, Any}},
    horizon_hr::Float64,
)::SimResult

    state = SimState(
        0.0,
        copy(initial_levels),
        Dict{String, Float64}(silo => 0.0 for silo in keys(initial_levels)),
        Dict{String, String}(),
        Dict{String, String}(),
        effects,
        machine_params,
        Snapshot[],
        BinaryMinHeap{Event}(),
        0,
    )

    # Intake events
    for intake in intakes
        schedule!(state, intake.start_hr, "intake-start", intake.silo_id, function ()
            state.rates[intake.silo_id] = get(state.rates, intake.silo_id, 0.0) + intake.rate_kg_per_hr
        end)
        schedule!(state, intake.end_hr, "intake-end", intake.silo_id, function ()
            state.rates[intake.silo_id] = get(state.rates, intake.silo_id, 0.0) - intake.rate_kg_per_hr
        end, PRIORITY_END)
    end

    # Block events
    for block in blocks
        schedule!(state, block.start_hr, "block-start", block.machine_id, function ()
            state.scheduled[block.machine_id] = block.mode
            apply_mode!(state, block.machine_id, block.mode)
            maybe_schedule_clean!(state, block.machine_id)
        end)
        schedule!(state, block.end_hr, "block-end", block.machine_id, function ()
            state.scheduled[block.machine_id] = "off"
            # Don't interrupt a forced clean already in progress
            if get(state.running, block.machine_id, "off") != "cleaning"
                apply_mode!(state, block.machine_id, "off")
            end
        end, PRIORITY_END)
    end

    # Horizon sentinel
    schedule!(state, horizon_hr, "", "", function () end)

    # t=0 snapshot
    push!(state.snapshots, Snapshot(0.0, copy(state.levels), "", "", ""))

    # Event loop: advance time, run handler, snapshot after every event.
    # Handlers return STALE to suppress the label on their snapshot.
    while !isempty(state.heap)
        event = pop!(state.heap)
        event.time > horizon_hr + 1e-9 && break
        advance!(state, event.time)
        fired = event.handler()
        label = fired === STALE ? "" : event.label
        mode  = isempty(event.equipment_id) ? "" : get(state.running, event.equipment_id, "")
        push!(state.snapshots, Snapshot(state.time, copy(state.levels), label, event.equipment_id, mode))
    end

    SimResult(state.snapshots)
end

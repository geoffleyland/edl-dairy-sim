# Event-driven dairy factory simulation.
#
# Tracks silo levels (kg) over time given:
#   - Intakes:  scheduled raw-material deliveries
#   - Blocks:   scheduled machine runs
#   - Effects:  kg/hr change per silo for each machine mode (precomputed from Yield ratios)
#
# Machines with max_run_hours / clean_hours (condenser, drier) auto-schedule forced
# cleans when their run time reaches the limit, then resume the scheduled mode.
#
# Silo limits (0 and capacity) are enforced: when a silo hits a limit the machines
# causing it are stopped and recorded in MachineInterval with a stop_reason.

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

# One continuous run of a machine in a single mode.
# stop_reason: "block-end" | "clean-start" | "clean-end" | "silo-empty" | "silo-full" | "horizon"
struct MachineInterval
    machine_id::String
    mode::String
    start_hr::Float64
    end_hr::Float64
    stop_reason::String
end

struct SimResult
    snapshots::Vector{Snapshot}
    intervals::Vector{MachineInterval}
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
    intake_rates::Dict{String, Float64}     # portion of rates coming from active intakes
    capacity::Dict{String, Float64}         # max kg per silo (Inf = unlimited)
    scheduled::Dict{String, String}         # what the user schedule says
    running::Dict{String, String}           # what's actually happening (may differ during clean)
    mode_started::Dict{String, Float64}     # machine_id → time the current mode started
    effects::Dict{String, Dict{String, Dict{String, Float64}}}
    machine_params::Dict{String, Dict{String, Any}}
    snapshots::Vector{Snapshot}
    intervals::Vector{MachineInterval}
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

# Switch a machine to `mode`, closing its current interval with `reason`.
# `reason` describes why the previous mode ended and is recorded in MachineInterval.
function apply_mode!(state::SimState, machine_id::String, mode::String, reason::String = "")
    old = get(state.running, machine_id, "off")

    # Close out the old mode's rate contributions and record the interval.
    if old != "off"
        for (silo, rate) in get(get(state.effects, machine_id, Dict()), old, Dict())
            state.rates[silo] = get(state.rates, silo, 0.0) - rate
        end
        started = get(state.mode_started, machine_id, state.time)
        push!(state.intervals, MachineInterval(machine_id, old, started, state.time, reason))
        delete!(state.mode_started, machine_id)
    end

    # Apply the new mode's rate contributions.
    for (silo, rate) in get(get(state.effects, machine_id, Dict()), mode, Dict())
        state.rates[silo] = get(state.rates, silo, 0.0) + rate
    end

    if mode != "off"
        state.mode_started[machine_id] = state.time
    end
    state.running[machine_id] = mode
end

# After any rate change, (re)schedule limit events for all silos.
# Stale limit events are filtered at fire time by checking actual levels.
# Only schedules events for silos with finite capacity (full) or positive initial level (empty).
function reschedule_limit_events!(state::SimState)
    for (silo, rate) in state.rates
        level = get(state.levels, silo, 0.0)
        cap   = get(state.capacity, silo, Inf)

        if rate < 0
            # Hits empty at: now + max(0, level) / |rate|
            t_empty = state.time + max(0.0, level) / (-rate)
            schedule!(state, t_empty, "silo-empty", silo, function ()
                get(state.levels, silo, 0.0) > 1e-6 && return STALE
                get(state.rates,  silo, 0.0) >= 0   && return STALE
                for (mid, current_mode) in collect(state.running)
                    current_mode == "off" && continue
                    get(get(get(state.effects, mid, Dict()), current_mode, Dict()), silo, 0.0) < 0 || continue
                    apply_mode!(state, mid, "off", "silo-empty")
                end
            end, PRIORITY_END)
        end

        if rate > 0 && isfinite(cap)
            # Hits capacity at: now + max(0, cap - level) / rate
            t_full = state.time + max(0.0, cap - level) / rate
            schedule!(state, t_full, "silo-full", silo, function ()
                get(state.levels, silo, 0.0) < cap - 1e-6 && return STALE
                get(state.rates,  silo, 0.0) <= 0          && return STALE
                for (mid, current_mode) in collect(state.running)
                    current_mode == "off" && continue
                    get(get(get(state.effects, mid, Dict()), current_mode, Dict()), silo, 0.0) > 0 || continue
                    apply_mode!(state, mid, "off", "silo-full")
                end
                # Stop any active intakes filling this silo; their end-events become no-ops.
                intake_contrib = get(state.intake_rates, silo, 0.0)
                if intake_contrib > 0
                    state.rates[silo]        = get(state.rates, silo, 0.0) - intake_contrib
                    state.intake_rates[silo] = 0.0
                end
            end, PRIORITY_END)
        end
    end
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
        get(state.running, machine_id, "off") ∈ ("off", "cleaning") && return STALE
        apply_mode!(state, machine_id, "cleaning", "clean-start")

        clean_end = clean_at + clean_dur
        schedule!(state, clean_end, "clean-end", machine_id, function ()
            next = get(state.scheduled, machine_id, "off")
            apply_mode!(state, machine_id, next, "clean-end")
            next != "off" && maybe_schedule_clean!(state, machine_id)
        end)
    end)
end

# ── Public API ──────────────────────────────────────────────────────────────────

"""
    simulate(intakes, blocks, initial_levels, capacity, effects, machine_params, horizon_hr)

Run the event-driven simulation and return a `SimResult`.

- `intakes`        — scheduled raw-material deliveries (`Vector{Intake}`)
- `blocks`         — scheduled machine runs (`Vector{Block}`)
- `initial_levels` — `Dict{silo_id => initial_kg}`
- `capacity`       — `Dict{silo_id => max_kg}` (omit a silo or use Inf for no upper limit)
- `effects`        — from `compute_effects`
- `machine_params` — `Dict{machine_id => Dict}` with `"max_run_hours"` / `"clean_hours"` if needed
- `horizon_hr`     — simulation end time in hours
"""
function simulate(
    intakes::Vector{Intake},
    blocks::Vector{Block},
    initial_levels::Dict{String, Float64},
    capacity::Dict{String, Float64},
    effects::Dict{String, Dict{String, Dict{String, Float64}}},
    machine_params::Dict{String, Dict{String, Any}},
    horizon_hr::Float64,
)::SimResult

    state = SimState(
        0.0,
        copy(initial_levels),
        Dict{String, Float64}(silo => 0.0 for silo in keys(initial_levels)),
        Dict{String, Float64}(silo => 0.0 for silo in keys(initial_levels)),
        capacity,
        Dict{String, String}(),
        Dict{String, String}(),
        Dict{String, Float64}(),
        effects,
        machine_params,
        Snapshot[],
        MachineInterval[],
        BinaryMinHeap{Event}(),
        0,
    )

    # Intake events
    for intake in intakes
        schedule!(state, intake.start_hr, "intake-start", intake.silo_id, function ()
            state.rates[intake.silo_id]        = get(state.rates,        intake.silo_id, 0.0) + intake.rate_kg_per_hr
            state.intake_rates[intake.silo_id] = get(state.intake_rates, intake.silo_id, 0.0) + intake.rate_kg_per_hr
        end)
        schedule!(state, intake.end_hr, "intake-end", intake.silo_id, function ()
            # Only subtract as much as is still active (may have been zeroed by silo-full).
            removed = min(get(state.intake_rates, intake.silo_id, 0.0), intake.rate_kg_per_hr)
            state.intake_rates[intake.silo_id] = get(state.intake_rates, intake.silo_id, 0.0) - removed
            state.rates[intake.silo_id]        = get(state.rates,        intake.silo_id, 0.0) - removed
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
                apply_mode!(state, block.machine_id, "off", "block-end")
            end
        end, PRIORITY_END)
    end

    # Horizon sentinel
    schedule!(state, horizon_hr, "", "", function () end)

    # t=0 snapshot
    push!(state.snapshots, Snapshot(0.0, copy(state.levels), "", "", ""))

    # Event loop: advance time, run handler, snapshot after every event.
    # Handlers return STALE to suppress the label on their snapshot.
    # reschedule_limit_events! runs after every state-changing event.
    while !isempty(state.heap)
        event = pop!(state.heap)
        event.time > horizon_hr + 1e-9 && break
        advance!(state, event.time)
        fired = event.handler()
        if fired !== STALE
            reschedule_limit_events!(state)
        end
        label = fired === STALE ? "" : event.label
        mode  = isempty(event.equipment_id) ? "" : get(state.running, event.equipment_id, "")
        push!(state.snapshots, Snapshot(state.time, copy(state.levels), label, event.equipment_id, mode))
    end

    # Close any intervals still running at the horizon.
    for (machine_id, started) in state.mode_started
        mode = get(state.running, machine_id, "off")
        mode == "off" && continue
        push!(state.intervals, MachineInterval(machine_id, mode, started, horizon_hr, "horizon"))
    end

    SimResult(state.snapshots, state.intervals)
end

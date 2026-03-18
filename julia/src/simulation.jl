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

struct Snapshot
    time_hr::Float64
    levels::Dict{String, Float64}
end

struct LogEntry
    time_hr::Float64
    event::String
    machine_id::String
    mode::String
end

struct SimResult
    snapshots::Vector{Snapshot}
    log::Vector{LogEntry}
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
# Build the effects table from the Yield.jl mass-balance result and machine rates.
#
# `quantities`   — from Yield.compute(process_config): kg of each stream per kg milk
# `machines`     — machines array from site.json (any dict-like; keys are strings)
#
# Returns: Dict{ machine_id => Dict{ mode => Dict{ silo_id => Δkg/hr } } }
# Positive Δ = filling the silo, negative = draining it.

function compute_effects(
    machines,
    quantities::Dict{String, Float64},
)::Dict{String, Dict{String, Dict{String, Float64}}}

    effects = Dict{String, Dict{String, Dict{String, Float64}}}()

    for m in machines
        id = string(m["id"])
        t  = string(m["type"])

        if t == "separator"
            R       = Float64(m["rate_kg_per_hour"])
            q_milk  = quantities["milk"]
            q_skim  = get(quantities, "skim",  0.0)
            q_cream = get(quantities, "cream", 0.0)
            effects[id] = Dict("running" => Dict(
                "raw-milk" => -R,
                "skim"     => +R * q_skim  / q_milk,
                "cream"    => +R * q_cream / q_milk,
            ))

        elseif t == "butter-plant"
            R       = Float64(m["rate_kg_per_hour"])
            q_cream = get(quantities, "cream",      0.0)
            q_bm    = get(quantities, "buttermilk", 0.0)
            effects[id] = Dict("running" => Dict(
                "cream"      => -R,
                "buttermilk" => +R * (q_cream > 0 ? q_bm / q_cream : 0.0),
            ))

        elseif t == "condenser"
            R_skim = Float64(m["skim_rate_kg_per_hour"])
            R_bm   = Float64(m["buttermilk_rate_kg_per_hour"])
            q_skim = get(quantities, "skim",                 0.0)
            q_csm  = get(quantities, "condensed-skim",       0.0)
            q_bm   = get(quantities, "buttermilk",           0.0)
            q_cbm  = get(quantities, "condensed-buttermilk", 0.0)
            r_skim = q_skim > 0 ? q_csm / q_skim : 0.0
            r_bm   = q_bm   > 0 ? q_cbm / q_bm   : 0.0
            effects[id] = Dict(
                "skim"       => Dict("skim"       => -R_skim, "condensed-skim"        => +R_skim * r_skim),
                "buttermilk" => Dict("buttermilk" => -R_bm,   "condensed-buttermilk"  => +R_bm   * r_bm),
            )

        elseif t == "drier"
            R_smp = Float64(m["smp_rate_kg_per_hour"])
            R_bmp = Float64(m["bmp_rate_kg_per_hour"])
            effects[id] = Dict(
                "smp" => Dict("condensed-skim"        => -R_smp),
                "bmp" => Dict("condensed-buttermilk"  => -R_bmp),
            )
        end
    end

    effects
end

# ── Heap event ──────────────────────────────────────────────────────────────────

struct _Event
    time::Float64
    priority::Int     # 0 = end/off events, 1 = start/on events; ends fire first at equal times
    serial::Int       # tie-breaker within the same priority
    handler::Function
end
Base.isless(a::_Event, b::_Event) =
    a.time < b.time ||
    (a.time == b.time && a.priority < b.priority) ||
    (a.time == b.time && a.priority == b.priority && a.serial < b.serial)

# ── Simulation state ────────────────────────────────────────────────────────────

mutable struct _State
    time::Float64
    levels::Dict{String, Float64}           # current kg per silo
    rates::Dict{String, Float64}            # current net kg/hr per silo
    scheduled::Dict{String, String}         # what the user schedule says
    running::Dict{String, String}           # what's actually happening (may differ during clean)
    run_since::Dict{String, Float64}        # when the current run started (for max_run tracking)
    effects::Dict{String, Dict{String, Dict{String, Float64}}}
    capacity::Dict{String, Float64}
    machine_params::Dict{String, Dict{String, Any}}
    snapshots::Vector{Snapshot}
    log::Vector{LogEntry}
    heap::BinaryMinHeap{_Event}
    serial::Int
end

# ── Internal helpers ────────────────────────────────────────────────────────────

function _schedule!(st::_State, t::Float64, handler::Function, priority::Int = 1)
    st.serial += 1
    push!(st.heap, _Event(t, priority, st.serial, handler))
end

# Advance all silo levels forward to time `to` at current rates, then update clock.
function _advance!(st::_State, to::Float64)
    dt = to - st.time
    dt > 0 || return
    for (silo, rate) in st.rates
        st.levels[silo] = get(st.levels, silo, 0.0) + rate * dt
    end
    st.time = to
end

function _snapshot!(st::_State)
    push!(st.snapshots, Snapshot(st.time, copy(st.levels)))
end

function _log!(st::_State, event::String, machine_id::String = "", mode::String = "")
    push!(st.log, LogEntry(st.time, event, machine_id, mode))
end

# Switch a machine to `mode`, removing the old mode's rate contributions first.
function _apply_mode!(st::_State, machine_id::String, mode::String)
    old = get(st.running, machine_id, "off")
    if old != "off"
        for (silo, rate) in get(get(st.effects, machine_id, Dict()), old, Dict())
            st.rates[silo] = get(st.rates, silo, 0.0) - rate
        end
    end
    for (silo, rate) in get(get(st.effects, machine_id, Dict()), mode, Dict())
        st.rates[silo] = get(st.rates, silo, 0.0) + rate
    end
    st.running[machine_id] = mode
end

# Schedule a forced clean at `st.time + max_run_hours` if the machine has those params.
# When clean finishes, resume the scheduled mode and re-arm the next clean.
function _maybe_schedule_clean!(st::_State, machine_id::String)
    params = get(st.machine_params, machine_id, nothing)
    params === nothing && return
    haskey(params, "max_run_hours") || return

    max_run   = Float64(params["max_run_hours"])
    clean_dur = Float64(params["clean_hours"])
    clean_at  = st.time + max_run

    let clean_at = clean_at, machine_id = machine_id, clean_dur = clean_dur
        _schedule!(st, clean_at, function ()
            # Stale event: machine already off or mid-clean — skip.
            get(st.running, machine_id, "off") ∈ ("off", "cleaning") && return
            _advance!(st, clean_at)
            _apply_mode!(st, machine_id, "cleaning")
            _log!(st, "clean-start", machine_id)
            _snapshot!(st)

            clean_end = clean_at + clean_dur
            let clean_end = clean_end, machine_id = machine_id
                _schedule!(st, clean_end, function ()
                    _advance!(st, clean_end)
                    next = get(st.scheduled, machine_id, "off")
                    _apply_mode!(st, machine_id, next)
                    _log!(st, "clean-end", machine_id, next)
                    _snapshot!(st)
                    next != "off" && _maybe_schedule_clean!(st, machine_id)
                end)
            end
        end)
    end
end

# ── Public API ──────────────────────────────────────────────────────────────────

"""
    simulate(intakes, blocks, initial_levels, capacity, effects, machine_params, horizon_hr)

Run the event-driven simulation and return a `SimResult`.

- `intakes`        — scheduled raw-material deliveries (`Vector{Intake}`)
- `blocks`         — scheduled machine runs (`Vector{Block}`)
- `initial_levels` — `Dict{silo_id => initial_kg}`
- `capacity`       — `Dict{silo_id => max_kg}`
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

    all_silos = collect(keys(initial_levels))
    st = _State(
        0.0,
        copy(initial_levels),
        Dict{String, Float64}(s => 0.0 for s in all_silos),
        Dict{String, String}(),
        Dict{String, String}(),
        Dict{String, Float64}(),
        effects,
        capacity,
        machine_params,
        Snapshot[],
        LogEntry[],
        BinaryMinHeap{_Event}(),
        0,
    )

    # Intake events
    for intake in intakes
        let intake = intake
            _schedule!(st, intake.start_hr, function ()
                _advance!(st, intake.start_hr)
                st.rates[intake.silo_id] = get(st.rates, intake.silo_id, 0.0) + intake.rate_kg_per_hr
                _log!(st, "intake-start", intake.silo_id)
                _snapshot!(st)
            end)
            _schedule!(st, intake.end_hr, function ()
                _advance!(st, intake.end_hr)
                st.rates[intake.silo_id] = get(st.rates, intake.silo_id, 0.0) - intake.rate_kg_per_hr
                _log!(st, "intake-end", intake.silo_id)
                _snapshot!(st)
            end, 0)
        end
    end

    # Block events
    for block in blocks
        let block = block
            _schedule!(st, block.start_hr, function ()
                _advance!(st, block.start_hr)
                st.scheduled[block.machine_id] = block.mode
                _apply_mode!(st, block.machine_id, block.mode)
                _log!(st, "block-start", block.machine_id, block.mode)
                _snapshot!(st)
                _maybe_schedule_clean!(st, block.machine_id)
            end)
            _schedule!(st, block.end_hr, function ()
                _advance!(st, block.end_hr)
                st.scheduled[block.machine_id] = "off"
                # Don't interrupt a forced clean already in progress
                if get(st.running, block.machine_id, "off") != "cleaning"
                    _apply_mode!(st, block.machine_id, "off")
                    _log!(st, "block-end", block.machine_id)
                    _snapshot!(st)
                end
            end, 0)
        end
    end

    # Horizon sentinel
    _schedule!(st, horizon_hr, function ()
        _advance!(st, horizon_hr)
        _snapshot!(st)
    end)

    # t=0 snapshot
    _snapshot!(st)

    # Event loop
    while !isempty(st.heap)
        event = pop!(st.heap)
        event.time > horizon_hr + 1e-9 && break
        event.handler()
    end

    SimResult(st.snapshots, st.log)
end

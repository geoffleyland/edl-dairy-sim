# Domain: Dairy Factory Simulation

This file describes what we're building and the domain we're building it for.
Replace this file when carrying the architecture to a new project.

---

## What We're Building

A short-term (4–8 day) simulation tool for a small dairy factory. It has two
main components:

- **A Julia backend** — yield mass-balance calculations (via Yield.jl) and a
  continuous-time simulation engine
- **A Vue + Vite frontend** — an interactive yield calculator with Sankey
  diagrams, and a time-based simulation view of silo volumes

This is a demo: the backing store is read-only JSON config files. No user
changes are persisted. The frontend drives almost everything; the backend
provides two compute endpoints.

The architecture (`architecture.md`) is unchanged. The domain file is what
you're reading now.

---

## The Site

The site receives whole milk and cream by tanker. It produces butter, skim
milk powder (SMP), and buttermilk powder (BMP) as its primary solid products,
plus liquid exports of cream, condensed skim, and condensed buttermilk when
it has more liquid than it can process.

The site has four machines:

| Machine | Input(s) | Output(s) |
|---|---|---|
| Separator (milk treatment) | Whole milk | Skim, Cream |
| Butter plant | Cream | Butter, Buttermilk |
| Condenser (evaporator) | Skim *or* Condensed buttermilk | Condensed skim *or* Condensed buttermilk |
| Drier (spray dryer) | Condensed skim *or* Condensed buttermilk | SMP *or* BMP |

**On the condenser:** it processes one stream at a time — it switches between
skim and buttermilk like the drier switches between SMP and BMP. It
concentrates liquid before drying. If the condenser has more throughput than
the drier can absorb, the excess condensed liquid is available for export.
Whether the condenser is a separate machine from the drier circuit is
deliberately left configurable — the site JSON defines machines and their
stream connections, so this can be adjusted as we learn.

**On the drier:** it takes condensed skim or condensed buttermilk as input
(i.e. the condenser feeds it). It runs in one of two modes — SMP or BMP — at
possibly different rates. Switching modes takes roughly one hour of flushing;
the intermediate powder is waste or mixed grade. Cleaning breaks are required
after a configurable maximum run time. Both inputs and rates are configuration,
not code — if the factory turns out to feed the drier directly from the skim
silo (bypassing a condenser), that is a config change, not a code change.

**Liquid exports** are a release valve: when a silo would overflow, the site
can export. Cream, condensed skim, and condensed buttermilk can all be
exported; which streams are exportable is configurable.

---

## Liquid Streams and Silos

Every liquid stream that buffers between machines has a silo with a rated
volume. The simulation tracks these silos:

| Silo | Feeds from | Feeds to |
|---|---|---|
| Raw milk | Tanker intake | Separator |
| Skim | Separator | Condenser, or export |
| Cream | Separator, tanker intake | Butter plant, or export |
| Buttermilk | Butter plant | Condenser, or export |
| Condensed skim | Condenser | Drier, or export |
| Condensed buttermilk | Condenser | Drier, or export |

Which silos exist and how they connect is determined by the site config. The
list above reflects the default factory configuration.

The simulation does not enforce silo capacity — it is not an optimisation
problem. A silo that exceeds its rated volume is highlighted; it is the
planner's job to avoid that by adjusting the schedule.

---

## The Mass Balance

The mass balance is the relationship between stream quantities and compositions
as liquid passes through each machine. It is solved by **Yield.jl**
(see below), which uses JuMP/Ipopt to resolve all the equations simultaneously.

The key components tracked are **fat**, **protein**, **lactose**, and
(implicitly) **water**. The four unit operations we use:

**Separation** — one input, two outputs, one component (fat) is controlled in
both outputs. All other components are diluted or concentrated in proportion to
the fat split. Used for: milk → skim + cream; cream → butter + buttermilk.

**Dry** — concentration by evaporation plus spray drying. Input is a liquid;
output has the same composition scaled by a concentration factor. The
concentration factor is determined by the target dry composition.

**Split** — divides one stream into two streams of identical composition.
Used when a stream is partially diverted (e.g. some skim to the condenser,
some direct to the drier).

**Mix** — blends multiple input streams into one output. Composition of the
output is the mass-weighted average of inputs.

(Yield.jl also models filtration for MPC/protein concentration, but this
factory does not use that process.)

---

## Domain Objects

### Stream

A liquid flow characterised by:
- **quantity** — kg/hour at which it flows (in the yield model: kg per kg of
  input)
- **composition** — fractions of fat, protein, lactose (and by inference water)

Streams are not stored persistently. They are computed on demand by the yield
solver and used as transient results.

### Machine

A unit operation. Defined in the site config JSON.

Key fields: `id`, `type` (separator | butter-plant | condenser | drier),
`rate` (kg/hour of primary input), `inputs` (stream ids), `outputs` (stream
ids), and type-specific parameters:
- separator: `skim_fat` (target fat fraction in skim), `cream_fat` (target fat
  fraction in cream)
- condenser: `skim_rate`, `buttermilk_rate`, `changeover_hours`,
  `max_run_hours`, `clean_hours`
- drier: `smp_rate`, `bmp_rate`, `changeover_hours`,
  `max_run_hours` (before a clean is required), `clean_hours`

Both the condenser and the drier are single-mode at any point in time — each
switches between its two feed streams (condenser: skim / buttermilk; drier:
condensed skim / condensed buttermilk) with a changeover gap and requires
periodic cleaning breaks.

### Silo

Buffer storage for a liquid stream between machines.

Key fields: `id`, `stream_id`, `volume` (rated capacity in kg), `initial_level`
(kg at simulation start, from config).

### Intake

A scheduled arrival of whole milk or cream by tanker.

Key fields: `stream_id` (raw-milk or cream), `start_time`, `duration_hours`,
`total_quantity` (kg). The simulation treats this as a constant inflow rate
over the arrival window (rate = total_quantity / duration_hours).

### Schedule

The simulation input — the full set of events over the planning horizon:
- Intake arrivals
- Machine on/off switch times

The schedule is assembled in the browser from user input and posted to the
simulation endpoint. It is not persisted.

### SiteConfig

A JSON file (read-only) that describes the site: machines, silos, rated
capacities, initial silo levels, and which streams can be exported. This is the
single place where site parameters live. A "site editor" page is a possible
future feature.

---

## The Yield Calculator Page

The yield page is the configuration surface for the whole tool. It lets the
user set:
- Milk composition (fat, protein, lactose fractions) — via sliders
- Process parameters (separator fat targets, condenser concentration, etc.)
- Machine rates (kg/hour)
- Silo volumes

When any parameter changes, the frontend sends a `POST /yield` request with the
current composition and process parameters. The Julia backend calls Yield.jl and
returns stream quantities and compositions. The frontend renders the result as a
**Sankey diagram** using ECharts — updated in near-real time.

The parameters set on this page are also the parameters that flow into the
simulation. There is one set of site parameters shared across both pages; the
yield page is where you edit them.

**On latency:** Yield.jl solves a small JuMP/Ipopt problem. Ipopt is not the
fastest solver for tiny problems, but the problem size is small (< 20 streams,
< 5 components). Response times of 200–500ms are acceptable for a debounced
slider. If latency proves unacceptable, the yield equations can be solved
analytically for this simple factory (no mixing or filtration), but start with
the general solver and measure first.

---

## The Simulation Page

The simulation page shows silo volumes over the planning horizon (up to 8
days). The user specifies:
- When milk and cream arrive (tanker schedule)
- When each machine is running (on/off blocks on a timeline)

The display:
- Horizontal axis: time (hours from simulation start)
- Machine schedule: a row per machine showing on/off blocks, with cleaning
  breaks automatically inserted after `max_run_hours` of continuous operation
- Silo chart: one line per silo, volume in kg vs time; line turns red when
  volume exceeds rated capacity
- Drier mode is indicated on the drier row (SMP vs BMP, with changeover gaps)

The user edits the schedule by dragging/resizing on/off blocks (ideally), or
at minimum by editing start/end times in form fields.

When the schedule changes, the frontend posts it along with the current yield
parameters to `POST /simulate`. The Julia backend first calls Yield.jl once
to compute stream compositions and yield ratios (the mass balance is constant
for a given set of parameters — it does not change during the simulation), then
runs the simulation engine using those ratios as fixed constants. The frontend
charts the result immediately.

---

## The Simulation Engine

The simulation is a **continuous-time, event-driven** computation. Between
events, every silo level changes linearly (constant inflow and outflow rates).
The engine maintains a `PriorityQueue` (min-heap on time) of pending events.

Each entry in the queue is a `(time, handler)` pair where `handler` is a
**closure** (or function pointer). The closure captures the simulation state
it needs and, when called, mutates the state and may enqueue further events.
This generalises cleanly: auto-inserted clean starts, clean ends, and
changeover events are just closures pushed onto the queue by the preceding
event's handler — they are not special-cased anywhere.

```julia
# sketch only — names subject to naming review
enqueue!(queue, clean_end_time, state -> resume_machine!(state, machine_id))
```

At each step, the engine:
1. Pops the earliest event `(t, handler)` from the queue
2. Advances all silo levels by `(t - t_prev) × net_rate` for each silo
3. Records a snapshot `(t, silo_levels)`
4. Calls `handler(state)` — which mutates rates and may push new events
5. Repeats until the queue is empty or the horizon is reached

The result is a list of `(time, silo_levels)` snapshots — one per event. The
frontend interpolates these linearly for the chart.

**Yield ratios are pre-computed.** Yield.jl is called once before the
simulation loop. It returns the kg-output per kg-input for every stream in
the network. These ratios are constants for the duration of the simulation;
the event handlers use them to compute inflow/outflow rate changes when a
machine turns on or off.

**On roll-your-own vs. framework:** there is no Julia event-simulation
framework mature enough to justify adding it as a dependency. A heap plus
closures is fifty lines and has no moving parts. Use `DataStructures.jl`
(stable, widely used) for the `PriorityQueue`. Do not add a discrete-event
simulation framework.

---

## Yield.jl Integration

Yield.jl lives in `examples/Yield.jl/` as a git submodule. It is **not** a
registered Julia package; it is used as a local path dependency.

The approach:
- Add it to `julia/Project.toml` as a `[deps]` entry
- Add a `[sources]` entry pointing to `../examples/Yield.jl`
- Yield.jl's `Project.toml` must declare a `[uuid]` for this to work
- `using Yield` then works in the main package

**Yield.jl needs refactoring before it can be used as a library.** The
current code has several issues that are fine for a standalone script but
wrong for infrastructure:

1. **`using Test` in the main module** — test helpers (`test_mass_balance`,
   `test_composition`, etc.) are compiled into every user of the library.
   Move all test code to the `test/` directory or a `TestHelpers` submodule.
   `Test` must not appear in `[deps]` — only in `[extras]`/`[targets]`.

2. **`run()` writes to a file** — the entry point calls `open("milk.md", "w")`
   and writes a Mermaid Sankey to disk. A library function must not write to
   the filesystem. Extract the computation from the I/O.

3. **`sankey()` takes an `IO` argument** — reasonable, but it should also have
   a variant that returns data (nodes + links as a `Dict`) for callers that
   want to render with ECharts rather than emit Mermaid markdown.

4. **`Project.toml` has no `[uuid]`** — required for Julia to treat it as a
   proper package. Add one.

5. **`main.jl` is not separated from library code** — the top-level `run()`
   call should only fire when the file is run as a script, not on `using`.
   Wrap it in `if abspath(PROGRAM_FILE) == @__FILE__`.

Make these changes in Yield.jl and push them upstream. Do not accumulate
fixes in this repo. This is dairy infrastructure, not demo scaffolding.

---

## API Endpoints

Two compute endpoints and one config read. No writes to disk.

### GET /config

Returns the site config JSON — read from disk, no computation. The frontend
loads this on startup and uses it to populate the yield page controls and
the simulation machine list.

### POST /yield

Request: site config with milk composition and process parameters

Response: stream quantities and compositions for each stream in the process
graph. The frontend uses this to build the ECharts Sankey `{ nodes, links }`
payload.

### POST /simulate

Request: site config (machine rates, silo volumes, initial levels) plus a
schedule (intakes and machine on/off events with timestamps)

Response:
- `snapshots`: array of `{ time, silos: { [silo_id]: kg } }`, one per event
- `events`: array of `{ time, type, machine_id?, detail? }` — includes
  auto-inserted cleans and changeovers so the frontend can mark them on the
  timeline

---

## Pre-checks and Warnings

Before running the simulation, the backend checks:
- All machine `stream_id` references exist in the factory config
- All silo `stream_id` references exist
- No silo starts above its rated volume
- All intake stream IDs refer to receivable streams (raw-milk or cream)
- Machine on-times do not overlap for the same machine

These are reported to the frontend as structured errors (not a stack trace),
following the same error response shape as the rest of the stack.

---

## Naming Notes

**Three-level physical hierarchy: site > plant > machine.** A *site* is the
whole facility. A *plant* is a major processing section (e.g. the powder
plant, which contains the condenser and drier; the butter plant, which
contains the churn and associated equipment). A *machine* is an individual
unit operation. This version only uses site and machine — the plant level is
noted for future use as the site grows.

**"Machine" not "unit" or "equipment"** — short, unambiguous, natural in
conversation ("when the machine is running", "cleaning the machine").

**"Site" not "factory"** — consistent with the three-level hierarchy.
"Factory" is fine in prose but "site" is the struct/JSON key name.

**"Stream" not "flow" or "pipe"** — consistent with Yield.jl's vocabulary.

**"Silo" not "tank" or "vessel"** — consistent with factory floor language.

**"Intake" not "delivery" or "receipt"** — "delivery" is used in the meat
processing codebase for outgoing allocation; "intake" is unambiguous for
incoming tanker arrivals.

**"Snapshot" not "sample" or "reading"** — for the simulation time-series
output: one `(time, silo_levels)` record per event.

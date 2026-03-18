# Architecture and Engineering Standards

These decisions apply to all planning tool projects in this stack. They are
deliberately domain-agnostic. Carry this file to new projects; update the
domain file, not this one.

---

## Tech Stack

| Layer | Choice | Why |
|---|---|---|
| Database | PostgreSQL | Mature, expressive, no argument |
| Backend language | Julia | JuMP for IP/LP is genuinely superior; elegant data work without NumPy/Pandas ceremony |
| HTTP server | Oxygen.jl | Built on HTTP.jl; better routing ergonomics without meaningful overhead |
| Database access | LibPQ.jl + raw SQL | No ORM. Write SQL. ORMs create boxes you have to break out of. |
| Solver | JuMP + HiGHS | Best-in-class for integer programming; Gurobi license later if needed |
| Frontend framework | Vue 3 | Clean, learnable, good SFC model |
| Frontend build tool | Vite | Fast dev server, hot reload, clean builds |
| Auth / HTTPS | Caddy (reverse proxy) | Handle auth at the proxy layer — never in application code |
| CLI argument parsing | ArgParse.jl | More actively maintained than DocOpt; subcommand support |
| Config format | TOML (human-edited), JSON (machine-generated) | TOML supports comments and is easier to hand-edit |

**On dependencies:** Every dependency is a liability. Prefer fewer, better-chosen
ones over many. The Julia ecosystem is thin on the web side — accept that and
keep the HTTP layer genuinely thin. Don't reach for packages to solve problems
that are small enough to solve directly.

**On Node:** Required for Vite builds. It's a build-time tool only — not a
production runtime. Hide it behind `./admin`. `./admin dev`, `./admin build`. Done.

---

## What "Enterprise Scale" Means Here

Not over-engineered. Not a platform. Not a framework others will download.

It means:
- Clean enough that a competent Julia developer can understand it without the
  original author present
- Layered well enough that changing one thing doesn't break unrelated things
- Deployable without heroics
- Honest about what it is: a planning tool, not infrastructure

The previous S&OP project replaced a $2M/year vendor tool, ran faster, and was
built in under a year. That's the bar. Complexity is the enemy.

---

## Architecture: The Onion

The codebase is structured in layers. Each layer has one responsibility and does
not reach through to layers below it. The data flows inward and gets cleaner at
each stage.

```
Raw data
  └── Validation layer    (is this data well-formed? business rules)
        └── Warning layer (is this data suspicious? soft constraints)
              └── Cleaning layer (make it consistent, remove bad records)
                    └── Model construction (trust the data by here)
                          └── Solver
                                └── Result interpretation
```

**Critical rule:** The validation layer is independent of the database schema.
Validation encodes business rules and data contracts. It does not know about
Postgres tables. You can change the schema without touching validation, and
tighten a business rule without touching the model. If you find yourself
importing schema definitions into the validation layer, stop and reconsider.

---

## Code Conventions

### Unicode layer markers

Use Julia's Unicode support to make abstraction levels visually obvious in code.

- `𝓓` — data structures (post-validation, pre-model)
- `𝓜` — model structures (JuMP model / solver inputs and outputs)

These are already established in the codebase. Carry them forward. Invent new
Unicode markers for new layers if needed, but be consistent.

### Naming

Variable names use standard planning domain language. Name things what a
planner would call them, not what a software engineer would call them.

**Pick one word per concept and use it everywhere** across structs, JSON keys,
API routes, and UI labels. The goal is a vocabulary you can use without thinking
— if you find yourself remembering which file uses which word, the naming is
wrong.

**Don't abbreviate unless you are abbreviating everywhere.** One-letter names
belong in tight mathematical loops, not in struct fields or API responses.

**Names are worth discussing.** Neither side gets names right alone. Push back
on bad names even mid-review. Good names compound across the whole codebase;
bad ones are forever.

### Struct formatting

Right-align type annotations to a consistent column (around column 20), with no
spaces around `::`:

```julia
struct Allocation
    source_id       ::String
    destination_id  ::String
    item_type_id    ::String
    period_id       ::String
    quantity        ::Int
end
```

This keeps struct fields scannable and makes unusually long names stand out.

### Solver entry points

Split build and solve into separate functions:

```julia
build_model(𝓓::ProblemData)::Model
solve(𝓜::Model, 𝓓::ProblemData)::SolveResult
```

This allows inspection or modification of the model before solving — useful for
debugging, IIS extraction, and what-if scenarios that re-solve with one
parameter changed without re-reading all data.

### The `bind` pattern (JSON → structs)

Use the `bind` multiple-dispatch deserializer for mapping JSON to Julia structs.
Each struct that needs default values defines its own `computed_fields` method:

```julia
struct Shift
    max_capacity  ::Int32
    min_capacity  ::Int32
    priority      ::Float64
end

function computed_fields(::Type{Shift})
    Dict(
        :min_capacity => args -> floor(args.max_capacity / 2),
        :priority     => _ -> 1.0,
    )
end
```

This keeps defaults co-located with the type definition. When `bind` reads JSON
into a struct and a field is missing, it looks for a recipe in `computed_fields`
before failing. When it does fail, it reports which struct and which field.

The `bind` function handles the `_` ↔ `-` translation between Julia field names
and JSON keys automatically.

`bind` dispatches on `Vector{Any}` specifically — use `Any[...]` syntax when
building arrays to pass to `bind`, not `[Dict{String,Any}(...) for ...]` which
produces `Vector{Dict{String,Any}}` and won't match.

### The `mutate_reference` pattern (editing JSON reference data)

Before the database is the source of truth, reference data lives in a JSON file.
Use a `mutate_reference` helper to make edits atomic and consistent:

```julia
function mutate_reference(f::Function, data_dir::String)
    ref_f = joinpath(data_dir, "reference.json")
    isfile(ref_f) || return json(Dict("error" => "no reference file"), status = 404)
    ref = JSON3.read(read(ref_f, String), Dict{String, Any})
    f(ref)
    open(ref_f, "w") do io; JSON3.pretty(io, ref); end
    json(Dict("status" => "ok"))
end
```

Note the argument order: `f::Function` is **first** because Julia do-block syntax
passes the block as the first argument. The API handler then reads naturally:

```julia
function delete_item(::HTTP.Request, id::String, data_dir::String)
    mutate_reference(data_dir) do ref
        ref["items"] = filter(t -> t["id"] != id, get(ref, "items", Any[]))
    end
end
```

When deleting an entity, cascade: clean up all foreign-key references to it in
the same `mutate_reference` call.

Use anonymous `::HTTP.Request` (no name) for handlers that don't read the
request body — it suppresses unused-argument warnings.

### Typed exceptions

Throw structured exception types, not strings.
`throw(ValidationError("field x missing"))` not `error("field x missing")`.
Define the exception hierarchy early; it shapes how errors propagate
through the layers.

### Validation warnings with Levenshtein suggestions

Cross-reference validation (e.g. "does this item type code exist?") uses the
`complain` pattern:

```julia
function complain(known, listed, description)
    unknown = setdiff(listed, known)
    if !isempty(unknown)
        closest = map(u -> argmin(k -> Levenshtein()(u, k), known), unknown)
        @warn "Unknown $description: " *
            join(("'$u' (could be '$k')" for (u, k) in zip(unknown, closest)), ", ")
    end
end
```

"Unknown shift 'monday-dya' (could be 'monday-day')" is useful. A bare KeyError
is not. Use StringDistances.jl for the Levenshtein distance.

---

## Frontend Conventions

### Vue SFC structure

Each `.vue` file has a `<script setup lang="ts">`, a `<template>`, and a
`<style scoped>` block. Scoped styles are the default; use global styles only
in `style.css` for sitewide utilities.

### CSS design tokens

`style.css` defines all design tokens as CSS custom properties (`--color-*`,
`--radius-*`). Every component references tokens, not raw hex values. This
makes a global colour change a one-line edit.

`brand.css` (imported by `style.css`) defines Ever.Ag brand tokens separately
from the generic design system:

- `--brand-header-gradient` — header background
- `--brand-menu-bg` — dropdown background
- `--brand-font-heading` — wordmark font (DM Sans)
- `--brand-font-prose` — prose font (Noto Sans)

When carrying the stack to a new project, `brand.css` travels unchanged. Update
`style.css` for any project-specific overrides.

### `AppHeader.vue` — the Ever.Ag app shell

`AppHeader.vue` is the shared header component. It renders the Ever.Ag wordmark,
"powered by ScAIapp®", and a hamburger navigation menu. Pass nav links as a prop:

```typescript
<AppHeader :links="[
  { to: '/',          label: 'Plan'      },
  { to: '/reference', label: 'Reference' },
]" />
```

The page title is read automatically from `route.meta.title` — set `meta.title`
on each route definition in `router.ts`.

### Ghost numeric inputs

`.num-input` is a sitewide ghost-style number input: invisible until hovered,
then a border appears to signal editability. Focus gives a focus ring.

```html
<input type="number" class="num-input" v-model="value" />
```

`.num-input` inherits `font-size` and `font-weight` from its parent, so row-level
font styling (e.g. `font-weight: 900` on a total row) flows through automatically.

Wrap inputs in `.hint-wrap` with a `data-hint` attribute for instant tooltips:

```html
<span class="hint-wrap" :data-hint="tooltipText">
  <input type="number" class="num-input" v-model="value" />
</span>
```

### TokenInput — gitignore.io-style tag input

`TokenInput.vue` is the reusable many-to-many relationship editor. It shows
selected items as pills and an autocomplete dropdown for adding new ones.

Props: `selected: Item[]`, `options: Item[]` (unselected candidates only),
`placeholder?: string`. Emits: `add(id)`, `remove(id)`.

**Critical implementation detail:** use `mousedown.prevent` on dropdown items,
not `click`. Without it, the `blur` event on the text input fires first and
collapses the dropdown before the click registers. The `blur` handler uses a
150ms `setTimeout` to give `mousedown` room to fire.

### CSS gotchas to carry forward

**`position: sticky` + `z-index` creates a stacking context.** Absolutely-
positioned children (e.g. `::after` tooltips) are trapped inside it — their
`z-index` is relative to that cell, not the document root. Fix: raise the cell's
`z-index` on `:hover` (the only moment the tooltip needs to be visible). See
`.cell-avail:hover { z-index: 5; }`.

**`::after` does not work on `<input>`.** `<input>` is a replaced element;
pseudo-elements are not rendered. Wrap the input in a `<span class="hint-wrap">`
and hang the `::after` from the wrapper instead.

---

## Quality is Hard to Retrofit

Certain things are nearly free to build in at the start and expensive to add later.
Build them first, use them always, and they'll be woven through the codebase
naturally.

**Structured logging** — not println, not @show. Use Julia's Logging stdlib
(`@info`, `@warn`, `@error`) from day one, with a log level the CLI can set.

**CLI and configuration** — every entry point takes a config file (TOML for
human-edited config; JSON for machine-generated) and CLI flags (at minimum:
config path, log level). No hard-coded constants anywhere a parameter belongs.
Use ArgParse.jl. The config file is the single place where the world is described.

**Dry-run mode for batch and destructive operations** — solver runs, imports,
and bulk writes have a dry-run path. For the interactive editor, the equivalent
is explicit database transactions with a clear commit/rollback boundary.

**Request correlation IDs** — every HTTP request gets a UUID assigned at the
Oxygen.jl middleware layer. That ID flows through every log message for the
lifetime of the request. Trivial to add on day one; painful to retrofit.

**Consistent error response shape** — every API error returns the same JSON
structure. Define it in the JSON Schema. The frontend never guesses error shape.

**Typed exceptions** — throw structured exception types (see Code Conventions).

**Health endpoint** — `/health` returns 200 and confirms the database is
reachable. Always forgotten, mandatory for any real deployment.

**Frontend type checking in CI** — `vitest run` uses esbuild, which strips types
without checking them. The Docker build runs `vue-tsc && vite build`, which does.
Type errors that pass `vitest` locally will break the Docker build. The fix:
`npm test` runs `vue-tsc --noEmit && vitest run` so the type checker runs locally
before anything is pushed. This is already wired into `./admin test-ci`.

These are not nice-to-haves. They are the first things built.

---

## Delivery Philosophy: Constraints in Parallel

**Build each constraint in the editor and the solver at the same time.**

Start with the plan editor — it gives the client something working on day one
and reveals what constraints actually matter through real use. But do not finish
the editor before starting the solver. Instead, add constraints one at a time
to both:

1. Show the constraint in the editor (highlight violations, display counts)
2. Encode the same constraint in the JuMP model
3. Run the solver against real data to verify the constraint works as intended

This discipline pays off in several ways:

- **Each constraint is understood deeply before moving to the next.** Coding it
  in JuMP surfaces edge cases and interactions that UI-only development misses.
- **The solver is useful earlier.** Even with two or three constraints modelled,
  it can confirm whether a manual plan is feasible — and planners learn to trust
  it incrementally.
- **No "big bang" integration risk.** A solver written after a complete editor
  has to handle every constraint simultaneously on real data for the first time.
  That is hard. One constraint at a time is easy.
- **The IIS infeasibility story works from the start.** The structured
  infeasibility explanation (via Claude API) is useful even with a partial
  model, as long as you are clear which constraints are live.

**Caveat:** tell the planner which constraints the solver is enforcing. A
partial model that silently ignores capacity while enforcing supply is
confusing. A banner saying "Solver enforces: supply limits, shift capacity"
is not.

The editor is not throwaway scaffolding. Every decision about data structures,
API shape, and validation layers must be made with the solver in mind. The goal
is that new constraints slot in without a rewrite.

The solver, when complete, should be an "I've done the bits that matter, now
fill in the rest" button — an enhancement to the editor, not a replacement.

**Honouring existing allocations.** User-entered deliveries are pinned with
`fix()` and honoured even when they violate a constraint. The solver fills
whatever headroom remains — planners can lock any cell and let the solver
complete the rest.

---

## Testing Architecture

Tests are a ratchet: they hold what we've proven correct and never let it slip
back. Fast tests mean we don't have to look far to find mistakes. The test
architecture has four layers with deliberately different speeds.

### Layer 1 — Julia unit tests

Standard `@testset`/`@test` tests for individual functions in isolation. Fast,
no solver, no database. Run with `./admin test` or in an interactive Julia
session. Pass `-w` / `--watch` for a FileWatching loop that re-runs the suite
on every `.jl` change. Cover: business logic, validation rules, the `bind`
deserializer, API endpoint response shapes. The endpoint shape tests are half
of the contract enforcement mechanism.

### Layer 2 — JSON fixture integration tests (solver tests)

Each test is a small, hand-crafted JSON file encoding a complete problem instance
with an `expected_objective` field. The test runner binds the JSON to the model
data struct, runs the solver, and checks the objective matches.

```julia
@testset "Solver fixtures" begin
    fixture_dir = joinpath(TEST_DIR, "fixtures")
    for file in sort(readdir(fixture_dir))
        endswith(file, ".json") || continue
        @testset "$file" begin
            d        = JSON3.read(read(joinpath(fixture_dir, file), String), Dict{String, Any})
            expected = d["expected_objective"]
            data     = load_problem(d)
            result   = solve(build_model(data), data)
            @test result.status    == :optimal
            @test result.objective == expected
        end
    end
end
```

Fixtures may include a `deliveries` array to test "finish it off" behaviour
(existing user allocations that the solver must honour and build around). A
`_comment` field is ignored by `load_problem`.

**Naming convention:** `p1-s1-t1.json` is the base case (1 plant, 1 shift, 1
item type). `p1-s1-t1~distance.json` is a variant that exercises distance costs.
The `~` separator means "base case plus this variation." Each file tests one
behaviour; the file name describes it.

These tests are the living specification of solver behaviour. They are not
throwaway scaffolding. A new constraint gets a new test file before any code
is written.

### Layer 3 — Frontend fast loop (Vitest + vue-tsc)

`npm test` runs `vue-tsc --noEmit && vitest run`. Vitest runs Vue component
tests in isolation with mocked API responses — fast, no browser, no Julia
process required. `vue-tsc` runs first and enforces TypeScript types across
all `.ts` and `.vue` files. This catches type errors that Vitest misses
(Vitest uses esbuild, which strips types without checking).

`./admin watch-fe-tests` uses `watchexec` to re-run `npm test` on every
`.ts` or `.vue` change: one terminal, type check and tests together.

### Layer 4 — End-to-end (Playwright)

Playwright drives a real browser against the full running stack. Slower by nature.
Not in the hot loop — run explicitly or in CI. Tests actual user flows. Also the
final safety net for API contract drift that the fast loops missed.

### API Contract: JSON Schema

The frontend and backend must agree on JSON response shapes. JSON Schema is the
mechanism:

- Write one `.json` schema file per API response type
- Julia tests validate outgoing responses against these schemas (JSONSchema.jl)
- TypeScript types for the frontend are *generated* from the same schemas
- The schema file is the single source of truth; both sides are bound to it

**Do not hand-write TypeScript types for API responses.** Generate them.

---

## Development and Deployment Layers

There are three operating modes, each a strict superset of the previous.
Postgres is never installed locally — always run it in Docker.

### Layer 1 — Julia + JSON (no infrastructure)

Julia runs natively. No Docker, no database. JSON fixture tests and unit tests
only. Works offline. This is where most development happens.

The API server runs with `./admin julia`, which uses `julia/src/dev.jl` — a
FileWatching hot-reload loop. When any `.jl` file in `julia/src/` changes,
the server restarts automatically. Call `restart!()` at the Julia REPL to force
a restart without changing a file.

### Layer 2 — Julia native + Postgres in Docker

`docker compose -f docker/docker-compose.dev.yml up` starts a Postgres container
with its port exposed to the host (`localhost:5432`). Julia still runs natively
with the same FileWatching loop, so there is no startup overhead. DB integration
tests can run. This is the development mode for anything touching the database.

The DB host in this layer is `localhost`. Config comes from `config.local.toml`
(gitignored). A minimal example ships as `config.local.toml.example`.

### Layer 3 — Full Docker (deployment)

Everything containerised: Postgres, Julia HTTP server, Caddy, built frontend.
Deployed to DigitalOcean App Platform. The app spec lives in `.do/app.yaml`;
deploy with:

```
doctl apps create --spec .do/app.yaml   # first deploy
doctl apps update <id> --spec .do/app.yaml  # subsequent
```

`deploy_on_push: true` in the spec means every push to `main` rebuilds both
services automatically.

The DB host in this layer is `db` (Docker internal network). Config is injected
via environment variables.

### Two Compose files

```
docker/docker-compose.yml         # Layer 3: full stack, production topology
docker/docker-compose.dev.yml     # Layer 2: DB only, port exposed to host
```

Do not merge them into one file with profiles. The topologies are different
enough that keeping them separate is cleaner.

### Test suite graceful degradation

Tests skip cleanly when infrastructure is not available:

```julia
if haskey(ENV, "DATABASE_URL")
    @testset "DB integration" begin ... end
else
    @info "Skipping DB tests (no DATABASE_URL)"
end
```

Layer 1: no `DATABASE_URL`, DB tests silently skip.
Layer 2: `DATABASE_URL` in `config.local.toml`, DB tests run.
CI: Compose brings up Postgres, sets `DATABASE_URL`, everything runs.

### Data loading paths

Both the JSON path (tests) and the Postgres path (production) must produce the
same `𝓓` struct. The solver sees no difference.

```julia
load_from_json(path)            → ProblemData   # test path
load_from_db(conn, plan_id)     → ProblemData   # production path
```

Everything downstream of these two functions is identical.

---

## Database Access

Write SQL. Don't fight LibPQ.jl into behaving like an ORM.

SQLAlchemy-style ORMs shine for CRUD apps where the object model and data model
are the same thing. Production planning is not that. You will have complex
queries, aggregations, and solver-feeding transforms. Write the SQL you mean.

Migration tooling for Julia is thin — plan your schema carefully upfront and
use plain SQL migration files rather than depending on a migration framework.

---

## Security

Authentication and HTTPS live at the Caddy reverse proxy. Julia trusts the
proxy and implements neither. The best security code is code you didn't write.

---

## The `./admin` Script

A single `./admin` bash script hides all toolchain complexity:

```
./admin setup               # install all dependencies (run once after clone)
./admin julia               # Layer 1: Julia API server with hot-reload
./admin dev                 # Layer 1: Vite frontend dev server
./admin test                # Layer 1: Julia tests once
./admin watch-julia-tests   # Layer 1: Julia tests in watch mode
./admin watch-fe-tests      # Layer 1: type-check + Vitest on every .ts/.vue change
./admin test-ci             # Layer 1: all tests once (Julia + frontend), exit code for CI
./admin db                  # Layer 2: start Postgres in Docker
./admin build               # production build of frontend
./admin up                  # Layer 3: full Docker stack locally
./admin down                # Layer 3: stop Docker stack
```

`watch-fe-tests` uses `watchexec` — one terminal, type checker and component
tests together. `test-ci` runs `npm test` which includes `vue-tsc --noEmit`,
so type errors surface in CI the same way they do locally.

A developer should not need to know that Node exists. The script must remain
readable in under two minutes. Do not let it grow beyond that.

---

## What Not To Do

- Do not couple validation to the database schema
- Do not design editor data structures that foreclose solver design
- Do not use dataframes — write Julia loops, they are fast
- Do not add packages to solve problems small enough to solve directly
- Do not implement auth or HTTPS in Julia
- Do not build all constraints in the editor before adding any solver constraints
- Do not let `./admin` grow beyond what a new developer can read in two minutes
- Do not hand-write TypeScript types for API responses — generate from JSON Schema
- Do not put Playwright tests in the hot loop — they are slow by nature, accept it
- Do not use println for logging — use Julia's Logging stdlib from line one
- Do not hard-code constants that belong in config
- Do not put defaults in a global dict — use `computed_fields(::Type{T})`
- Do not throw strings — throw typed exceptions
- Do not install Postgres locally — use Docker for the DB, always
- Do not merge the dev and production Compose files — the topologies differ
- Do not rely on `vitest run` alone to catch type errors — always run `vue-tsc --noEmit` too
- Do not name a `mutate_reference` handler argument — use anonymous `::HTTP.Request`
  for unused request parameters (suppresses linter warnings cleanly)
- Do not use `click` on dropdown items in a TokenInput — use `mousedown.prevent`
  to prevent the input's blur from collapsing the dropdown first

---

## Starting Point for Any Planning Tool

When beginning work, ask: **what does a planner actually do when they edit a plan?**

What are the objects they manipulate? What constraints are they aware of? What
does a "good plan" look like to a human, before any solver is involved?

The answer to those questions defines the data model. The data model defines
everything else. Get it right before writing application code.

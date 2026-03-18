# Production Planning Tool

A livestock allocation planning tool. Farms supply animals by stock type;
processing plants receive them on scheduled shifts subject to capacity
constraints. A planner decides which farm sends how many of which stock type
to which plant on which shift. This tool provides a plan editor and a solver
that can complete or optimise a partial plan.

Replaces a GAMS-based legacy stack.

---

## Prerequisites

- [Julia](https://julialang.org/downloads/) (1.11+) — `julia` on your PATH
- [Node.js](https://nodejs.org/) (20+) — `npm` on your PATH
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) — only needed for the database (Layer 2+)

## Getting started

```
./admin setup
```

That installs all Julia and Node dependencies. Run it once after cloning.

---

## Running

Two terminals for the full dev experience:

```
./admin julia    # Julia API server — hot-reloads on src/ changes
./admin dev      # Vite frontend — hot-reloads, opens http://localhost:5173
```

To add a database (Layer 2), start Postgres in a third terminal:

```
./admin db
```

---

## Tests

```
./admin watch-julia-tests   # Julia tests in watch mode — re-runs on every .jl change
./admin watch-fe-tests      # Frontend tests in watch mode (Vitest)
./admin test-ci             # All tests once, for CI
```

---

## Further reading

- `docs/domain.md` — what this tool is and the domain it operates in
- `docs/architecture.md` — tech stack, conventions, and how to develop it

module Yield

using JuMP, Ipopt

function build_yield_model(components, streams)
    𝓜 = JuMP.Model(Ipopt.Optimizer)
    set_silent(𝓜)

    @variables 𝓜 begin
        quantity[streams] >= 0
        0 <= composition[streams, components] <= 1
    end

    𝓜
end


function solve_yield_model(𝓜, components, streams)
    optimize!(𝓜)
    @assert termination_status(𝓜) ∈ [MOI.OPTIMAL, MOI.LOCALLY_SOLVED]

    quantities = Dict(s => value(𝓜[:quantity][s]) for s in streams)
    compositions =
        Dict(s => Dict(c => value(𝓜[:composition][s, c]) for c in components)
            for s in streams)

    for (s, comp) in compositions
        total = sum(f for (_, f) in comp)
        total <= 1 + 1e-6 || throw(ArgumentError(
            "Composition for stream \"$s\" sums to $total, which exceeds 1.0"))
    end

    quantities, compositions
end


function set_stream_quantity(𝓜, stream, quantity)
    fix(𝓜[:quantity][stream], quantity, force=true)
end


function set_stream_composition(𝓜, components, stream, composition)
    for (c, v) in composition
        if c == "total-solids"
            @constraint(𝓜,
                sum(𝓜[:composition][stream, c2] for c2 in components) == v)
        else
            fix(𝓜[:composition][stream, c], v, force=true)
        end
    end
end


include("processes/separation.jl")
include("processes/mix.jl")
include("processes/split.jl")
include("processes/filter.jl")
include("processes/dry.jl")
include("orchestrate.jl")
include("build.jl")

using JSON

# Compute yield for a config dict (parsed JSON).  Returns (quantities, compositions).
# This is the primary library entry point for callers that want to drive the
# calculation programmatically.
function compute(config::Dict)
    𝓜, components, streams = build_yield_model(config)
    solve_yield_model(𝓜, components, streams)
end


# Run a config file, print results, and write a Mermaid Sankey to a given IO
# (defaults to stdout).  This is the CLI entry point; library callers should use
# compute() instead.
function run(config_file_name; sankey_io::Union{IO,Nothing} = nothing)
    println("\nRunning $(config_file_name)...")
    config = JSON.parse(open(config_file_name))
    quantities, compositions = compute(config)
    println("RESULTS")
    for (s, q) in quantities
        println("$s: $q")
        for (c, f) in compositions[s]
            println("  $c: $f")
        end
    end
    if sankey_io !== nothing
        sankey_mermaid(sankey_io, quantities, config)
    end
    quantities, compositions
end


end

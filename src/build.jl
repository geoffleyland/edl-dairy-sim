function build_separation_model(𝓜, components, config::Dict)
    inputs = read_inputs(config)
    outputs = read_outputs(config)
    separation_component = config["separation-component"]
    add_separation_model(𝓜, components, inputs, outputs, separation_component)
end


function build_mix_model(𝓜, components, config::Dict)
    inputs = read_inputs(config)
    outputs = read_outputs(config)
    add_mix_model(𝓜, components, inputs, outputs)
end


function build_split_model(𝓜, components, config::Dict)
    inputs = read_inputs(config)
    outputs = read_outputs(config)
    add_split_model(𝓜, components, inputs, outputs)
end


function build_filter_model(𝓜, components, config::Dict)
    inputs = read_inputs(config)
    outputs = read_outputs(config)
    retention_coefficients = config["retention-coefficients"]
    add_filter_model(𝓜, components, inputs, outputs, retention_coefficients)
end


function build_dry_model(𝓜, components, config::Dict)
    inputs = read_inputs(config)
    outputs = read_outputs(config)
    add_dry_model(𝓜, components, inputs, outputs)
end


OPERATION_MAP = Dict(
    "separation" => build_separation_model,
    "split"      => build_split_model,
    "mix"        => build_mix_model,
    "filter"     => build_filter_model,
    "dry"        => build_dry_model
)


#-------------------------------------------------------------------------------------------

make_vector(s) = [s]
make_vector(v::Vector) = v
function read_inputs(config::Dict)
    make_vector(get(config, "input", get(config, "inputs", [])))
end
function read_outputs(config::Dict)
    make_vector(get(config, "output", get(config, "outputs", [])))
end


function build_yield_model(config::Dict)
    streams = Set{String}()
    for op in config["operations"]
        push!.(Ref(streams), read_inputs(op))
        push!.(Ref(streams), read_outputs(op))
    end
    components = config["components"]

    𝓜 = build_yield_model(components, streams)

    for op in config["operations"]
        OPERATION_MAP[op["operation"]](𝓜, components, op)
    end

    for (s, q) in config["quantities"]
        set_stream_quantity(𝓜, s, q)
    end

    for (s, c) in config["compositions"]
        set_stream_composition(𝓜, components, s, c)
    end

    𝓜, components, streams
end


#-------------------------------------------------------------------------------------------
# Sankey output: Mermaid format (for CLI output) and ECharts format (for the frontend).
#
# Both functions derive the same node/link structure from the config operations list.
# Each operation becomes an intermediate node; streams flow into and out of it.
# Terminal source streams (no preceding operation) and terminal sink streams
# (no following operation) appear as nodes named by the stream itself.

function _sankey_nodes_and_links(config)
    sources = Dict{String,String}()
    sinks   = Dict{String,String}()
    for op in config["operations"]
        inputs  = read_inputs(op)
        outputs = read_outputs(op)
        # Name the operation node after its primary stream and type.
        name = (length(inputs) == 1 ? inputs[1] : outputs[1]) * "-" * op["operation"]
        for i in inputs;  sinks[i]   = name; end
        for o in outputs; sources[o] = name; end
    end
    sources, sinks
end


function sankey_mermaid(f::IO, quantities, config)
    sources, sinks = _sankey_nodes_and_links(config)
    println(f, "```mermaid")
    println(f, "sankey-beta")
    for (s, q) in quantities
        println(f, "$(get(sources, s, s)),$(get(sinks, s, s)),$q")
    end
    println(f, "```")
    flush(f)
end


# Returns a Dict suitable for JSON serialisation to an ECharts Sankey chart.
# Shape: { "nodes": [{"name": ...}, ...], "links": [{"source": ..., "target": ..., "value": ...}, ...] }
function sankey_data(quantities, config)
    sources, sinks = _sankey_nodes_and_links(config)

    node_names = Set{String}()
    links = Dict{String,Any}[]

    for (s, q) in quantities
        q > 1e-9 || continue   # skip zero-flow streams
        src  = get(sources, s, s)
        sink = get(sinks,   s, s)
        push!(node_names, src)
        push!(node_names, sink)
        push!(links, Dict{String,Any}("source" => src, "target" => sink, "value" => q))
    end

    Dict{String,Any}(
        "nodes" => [Dict{String,Any}("name" => n) for n in node_names],
        "links" => links,
    )
end

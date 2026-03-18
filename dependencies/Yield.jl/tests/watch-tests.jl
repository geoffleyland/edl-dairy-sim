using ArgParse, Revise

push!(LOAD_PATH, "src")
using Yield

ap = ArgParseSettings(description = "Prototype Yield model", version="0.0.1", add_version=true)

@add_arg_table! ap begin
end

args = parse_args(ap)

entr(["src", "src/processes", "tests"]) do
    try
        include(joinpath(@__DIR__, "runtests.jl"))
    catch e
        showerror(stdout, e, catch_backtrace())
    end
end

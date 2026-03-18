using Test
push!(LOAD_PATH, "src")
using Yield

include("test_helpers.jl")

@testset "Yield Tests" begin
    include("test-split.jl")
    include("test-separation.jl")
    include("test-mix.jl")
    include("test-filter.jl")
    include("test-dry.jl")
    include("test-orchestration.jl")
end

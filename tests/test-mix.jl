using LinearAlgebra

COMPOSITIONS = [
    Dict("fat" => 0.0001, "protein" => 0.0309, "lactose" => 0.0309)
    Dict("fat" => 0.42, "protein" => 0.0179, "lactose" => 0.0179)
    Dict("fat" => 0.0, "protein" => 0.0, "lactose" => 1.0)
]

TARGETS = Dict(
    "fat" => 0.015,
    "protein" => 0.34,
    "total-solids" => 0.95
)

@testset "Mix" begin
    components = keys(COMPOSITIONS[1])
    stream_count = length(COMPOSITIONS) + 1

    𝓜 = Yield.build_yield_model(components, ["skim", "cream", "lactose", "treated", "powder"])

    Yield.add_mix_model(𝓜, components, ["skim", "cream", "lactose"], ["treated"])
    Yield.add_dry_model(𝓜, components, ["treated"], ["powder"])

    Yield.set_stream_quantity(𝓜, "powder", 1)
    Yield.set_stream_composition.(𝓜, Ref(components), ["skim", "cream", "lactose"], COMPOSITIONS)
    Yield.set_stream_composition(𝓜, components, "powder", TARGETS)

    quantities, compositions = Yield.solve_yield_model(𝓜, components, ["skim", "cream", "lactose", "treated", "powder"])

    test_mix(components, quantities, compositions, ["skim", "cream", "lactose"], ["treated"])
    test_composition(components, compositions["powder"], TARGETS)
end

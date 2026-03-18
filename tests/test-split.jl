MILK_COMPOSITION = Dict("fat" => 0.03, "protein" => 0.03, "lactose" => 0.03)
STREAMS = ["milk in", "milk out 1", "milk out 2"]


@testset "Split" begin
    components = keys(MILK_COMPOSITION)

    𝓜 = Yield.build_yield_model(components, STREAMS)

    Yield.add_split_model(𝓜, components, ["milk in"], ["milk out 1", "milk out 2"])

    Yield.set_stream_quantity(𝓜, "milk in", 1)
    Yield.set_stream_composition(𝓜, components, "milk in", MILK_COMPOSITION)
    Yield.set_stream_quantity(𝓜, "milk out 1", 0.3)

    quantities, compositions = Yield.solve_yield_model(𝓜, components, STREAMS)

    test_split(components, quantities, compositions, ["milk in"], ["milk out 1", "milk out 2"])
end

MILK_COMPOSITION = Dict("fat" => 0.03, "protein" => 0.03, "lactose" => 0.03)
STREAMS = ["milk", "powder"]


@testset "Dry" begin
    components = keys(MILK_COMPOSITION)

    𝓜 = Yield.build_yield_model(components, STREAMS)

    Yield.add_dry_model(𝓜, components, ["milk"], ["powder"])

    Yield.set_stream_quantity(𝓜, "powder", 1)
    Yield.set_stream_composition(𝓜, components, "milk", MILK_COMPOSITION)
    Yield.set_stream_composition(𝓜, components, "powder", Dict("total-solids" => 0.95))

    quantities, compositions = Yield.solve_yield_model(𝓜, components, STREAMS)

    test_dry(components, quantities, compositions, ["milk"], ["powder"])
    test_composition(components, compositions["powder"], Dict("total-solids" => 0.95))
end

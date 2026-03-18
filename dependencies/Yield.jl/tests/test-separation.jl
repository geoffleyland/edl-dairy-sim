MILK_COMPOSITION = Dict("fat" => 0.03, "protein" => 0.03, "lactose" => 0.03)
SEPARATION_COMPONENT = "fat"
OUTPUT_FRACTIONS = [0.0001, 0.42]
STREAMS = ["milk", "skim", "cream"]


@testset "Separation" begin
    components = keys(MILK_COMPOSITION)

    𝓜 = Yield.build_yield_model(components, STREAMS)

    Yield.add_separation_model(𝓜, components, ["milk"], ["skim", "cream"], SEPARATION_COMPONENT)

    Yield.set_stream_quantity(𝓜, "milk", 1)
    Yield.set_stream_composition(𝓜, components, "milk", MILK_COMPOSITION)
    Yield.set_stream_composition.(𝓜, Ref(components), ["skim", "cream"], [Dict(SEPARATION_COMPONENT => f) for f in OUTPUT_FRACTIONS])

    quantities, compositions = Yield.solve_yield_model(𝓜, components, STREAMS)

    test_separation(components, quantities, compositions, ["milk"], ["skim", "cream"])
    test_composition(components, compositions["skim"], Dict(SEPARATION_COMPONENT => OUTPUT_FRACTIONS[1]))
    test_composition(components, compositions["cream"], Dict(SEPARATION_COMPONENT => OUTPUT_FRACTIONS[2]))


    𝓜 = Yield.build_yield_model(components, STREAMS)

    Yield.add_separation_model(𝓜, components, ["milk"], ["skim", "cream"], SEPARATION_COMPONENT)

    Yield.set_stream_quantity(𝓜, "milk", 1)
    Yield.set_stream_composition(𝓜, components, "milk", MILK_COMPOSITION)
    Yield.set_stream_quantity.(𝓜, ["skim", "cream"], quantities[c] for c in ["skim", "cream"])
    Yield.set_stream_composition(𝓜, components, "skim", Dict(SEPARATION_COMPONENT => OUTPUT_FRACTIONS[1]))

    quantities, compositions = Yield.solve_yield_model(𝓜, components, STREAMS)

    test_separation(components, quantities, compositions, ["milk"], ["skim", "cream"])
    test_composition(components, compositions["skim"], Dict(SEPARATION_COMPONENT => OUTPUT_FRACTIONS[1]))
    test_composition(components, compositions["cream"], Dict(SEPARATION_COMPONENT => OUTPUT_FRACTIONS[2]))
end

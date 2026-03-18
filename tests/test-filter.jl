using JuMP

SKIM_COMPOSITION = Dict("fat" => 0.0001, "protein" => 0.03, "lactose" => 0.03)
RETENTION_COEFFICIENTS = Dict("fat" => 0.95, "protein" => 0.95)
STREAMS = ["skim", "retentate", "permeate"]


@testset "Filter" begin
    components = keys(SKIM_COMPOSITION)

    𝓜 = Yield.build_yield_model(components, STREAMS)

    v = Yield.add_filter_model(𝓜, components, ["skim"], ["retentate", "permeate"], RETENTION_COEFFICIENTS)

    Yield.set_stream_quantity(𝓜, "skim", 1)
    Yield.set_stream_composition(𝓜, components, "skim", SKIM_COMPOSITION)
    Yield.set_stream_composition(𝓜, components, "retentate", Dict("protein" => 0.3))

    quantities, compositions = Yield.solve_yield_model(𝓜, components, STREAMS)

    test_filter(components, quantities, compositions,
        ["skim"], ["retentate", "permeate"], RETENTION_COEFFICIENTS)
    test_composition(components, compositions["retentate"], Dict("protein" => 0.3))
end

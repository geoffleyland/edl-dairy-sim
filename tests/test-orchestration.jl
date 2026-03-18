using LinearAlgebra

MILK_COMPOSITION = Dict("fat" => 0.03, "protein" => 0.03, "lactose" => 0.03)
COMPONENTS = keys(MILK_COMPOSITION)
LACTOSE_COMPOSITION = Dict("fat" => 0.0, "protein" => 0.0, "lactose" => 1.0)
SEPARATION_COMPONENT = "fat"
FAT_FRACTIONS = [0.0001, 0.42]
BUTTER_FAT_FRACTIONS = [0.0001, 0.8]
POWDER_TARGETS = Dict(
    "fat" => 0.015,
    "protein" => 0.34,
    "total-solids" => 0.95
)
MPC_TARGETS = Dict(
    "protein" => 0.8,
    "total-solids" => 0.95
)
RETENTION_COEFFICIENTS = Dict("fat" => 0.95, "protein" => 0.95)
RETENTATE_PROTEIN = 0.3


@testset "Orchestration" begin
    @testset "Separation Orchestration" begin
        quantities, compositions = Yield.orchestrate_separation_forwards(
            MILK_COMPOSITION, SEPARATION_COMPONENT, FAT_FRACTIONS)

        test_separation(COMPONENTS, quantities, compositions, ["milk"], ["skim", "cream"])
        test_composition(COMPONENTS, compositions["skim"], Dict("fat" => FAT_FRACTIONS[1]))
        test_composition(COMPONENTS, compositions["cream"], Dict("fat" => FAT_FRACTIONS[2]))

        quantities, compositions = Yield.orchestrate_separation_backwards(
            MILK_COMPOSITION, SEPARATION_COMPONENT, [quantities[s] for s in ["skim", "cream"]], FAT_FRACTIONS[1])

        test_separation(COMPONENTS, quantities, compositions, ["milk"], ["skim", "cream"])
        test_composition(COMPONENTS, compositions["skim"], Dict("fat" => FAT_FRACTIONS[1]))
        test_composition(COMPONENTS, compositions["cream"], Dict("fat" => FAT_FRACTIONS[2]))
    end

    @testset "Mix Orchestration" begin
        COMPOSITIONS = [
            Dict("fat" => 0.0001, "protein" => 0.0309, "lactose" => 0.0309)
            Dict("fat" => 0.42, "protein" => 0.0179, "lactose" => 0.0179)
            LACTOSE_COMPOSITION
        ]

        quantities, compositions = Yield.orchestrate_mix(
            COMPOSITIONS, POWDER_TARGETS)

        test_mix(COMPONENTS, quantities, compositions, 1:3, 4)
        test_composition(COMPONENTS, compositions[5], POWDER_TARGETS)
    end

    @testset "Separation and Mix Orchestration" begin
        quantities, compositions = Yield.orchestrate_separation_and_mix(
            MILK_COMPOSITION, LACTOSE_COMPOSITION, FAT_FRACTIONS, POWDER_TARGETS)

        test_separation(COMPONENTS, quantities, compositions,
            ["milk"], ["skim", "sep cream"])
        test_composition(COMPONENTS, compositions["skim"], Dict("fat" => FAT_FRACTIONS[1]))
        test_composition(COMPONENTS, compositions["sep cream"], Dict("fat" => FAT_FRACTIONS[2]))
        test_split(COMPONENTS, quantities, compositions,
            ["sep cream"], ["mix cream", "excess cream"])
        test_mix(COMPONENTS, quantities, compositions,
            ["lactose", "skim", "mix cream"], ["treated milk"])
        test_composition(COMPONENTS, compositions["powder"], POWDER_TARGETS)
    end

    @testset "Powder and butter Orchestration" begin
        quantities, compositions = Yield.orchestrate_powder_and_butter(
            MILK_COMPOSITION, LACTOSE_COMPOSITION, FAT_FRACTIONS, BUTTER_FAT_FRACTIONS, POWDER_TARGETS)

        test_separation(COMPONENTS, quantities, compositions,
            ["milk"], ["skim", "sep cream"])
        test_composition(COMPONENTS, compositions["skim"], Dict("fat" => FAT_FRACTIONS[1]))
        test_composition(COMPONENTS, compositions["sep cream"], Dict("fat" => FAT_FRACTIONS[2]))
        test_separation(COMPONENTS, quantities, compositions,
            ["butter cream"], ["buttermilk", "butter"])
        test_composition(COMPONENTS, compositions["buttermilk"], Dict("fat" => BUTTER_FAT_FRACTIONS[1]))
        test_composition(COMPONENTS, compositions["butter"], Dict("fat" => BUTTER_FAT_FRACTIONS[2]))
        test_split(COMPONENTS, quantities, compositions,
            ["sep cream"], ["mix cream", "butter cream"])
        test_mix(COMPONENTS, quantities, compositions,
            ["lactose", "skim", "mix cream"], ["treated milk"])
        test_composition(COMPONENTS, compositions["powder"], POWDER_TARGETS)
        end

    @testset "Powder, permeate and butter Orchestration" begin
        quantities, compositions = Yield.orchestrate_powder_permeate_and_butter(
            MILK_COMPOSITION, FAT_FRACTIONS, BUTTER_FAT_FRACTIONS, RETENTION_COEFFICIENTS, RETENTATE_PROTEIN, POWDER_TARGETS)

        test_separation(COMPONENTS, quantities, compositions,
            ["milk"], ["sep skim", "sep cream"])
        test_composition(COMPONENTS, compositions["sep skim"], Dict("fat" => FAT_FRACTIONS[1]))
        test_composition(COMPONENTS, compositions["sep cream"], Dict("fat" => FAT_FRACTIONS[2]))
        test_separation(COMPONENTS, quantities, compositions,
            ["butter cream"], ["buttermilk", "butter"])
        test_composition(COMPONENTS, compositions["buttermilk"], Dict("fat" => BUTTER_FAT_FRACTIONS[1]))
        test_composition(COMPONENTS, compositions["butter"], Dict("fat" => BUTTER_FAT_FRACTIONS[2]))
        test_split(COMPONENTS, quantities, compositions,
            ["sep cream"], ["mix cream", "butter cream"])
        test_split(COMPONENTS, quantities, compositions,
            ["sep skim"], ["mix skim", "filter skim"])
        test_filter(COMPONENTS, quantities, compositions,
            ["filter skim"], ["retentate", "permeate"], RETENTION_COEFFICIENTS)
        test_composition(COMPONENTS, compositions["retentate"], Dict("protein" => RETENTATE_PROTEIN))
        test_mix(COMPONENTS, quantities, compositions,
            ["permeate", "mix skim", "mix cream"], ["treated milk"])
        test_composition(COMPONENTS, compositions["powder"], POWDER_TARGETS)
    end

    @testset "Powder, MPC and butter Orchestration" begin
        quantities, compositions = Yield.orchestrate_powder_MPC_and_butter(
            MILK_COMPOSITION, FAT_FRACTIONS, BUTTER_FAT_FRACTIONS, RETENTION_COEFFICIENTS, POWDER_TARGETS, MPC_TARGETS)

        test_separation(COMPONENTS, quantities, compositions,
            ["milk"], ["sep skim", "sep cream"])
        test_composition(COMPONENTS, compositions["sep skim"], Dict("fat" => FAT_FRACTIONS[1]))
        test_composition(COMPONENTS, compositions["sep cream"], Dict("fat" => FAT_FRACTIONS[2]))
        test_separation(COMPONENTS, quantities, compositions,
            ["butter cream"], ["buttermilk", "butter"])
        test_composition(COMPONENTS, compositions["buttermilk"], Dict("fat" => BUTTER_FAT_FRACTIONS[1]))
        test_composition(COMPONENTS, compositions["butter"], Dict("fat" => BUTTER_FAT_FRACTIONS[2]))
        test_split(COMPONENTS, quantities, compositions,
            ["sep cream"], ["mix cream", "butter cream"])
        test_split(COMPONENTS, quantities, compositions,
            ["sep skim"], ["mix skim", "filter skim"])
        test_filter(COMPONENTS, quantities, compositions,
            ["filter skim"], ["retentate", "permeate"], RETENTION_COEFFICIENTS)
        test_mix(COMPONENTS, quantities, compositions,
            ["permeate", "mix skim", "mix cream"], ["treated milk"])
        test_composition(COMPONENTS, compositions["powder"], POWDER_TARGETS)
        test_dry(COMPONENTS, quantities, compositions,
            ["retentate"], ["MPC"])
    end

end

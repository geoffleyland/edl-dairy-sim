using Test

# ── Per-stream mass balance ───────────────────────────────────────────────────

function test_mass_balance(components, quantities, compositions, inputs, outputs)
    @test sum(quantities[s] for s in inputs) ≈ sum(quantities[s] for s in outputs)
    for c in components
        @test isapprox(sum(quantities[s] * compositions[s][c] for s in inputs),
            sum(quantities[s] * compositions[s][c] for s in outputs), atol=1e-6)
    end
end


function test_composition(components, composition, targets)
    for (component, target) in targets
        result = if component == "total-solids"
            sum(composition[c] for c in components)
        else
            composition[component]
        end
        @test isapprox(result, target, atol=1e-6)
    end
end


# ── Per-operation test helpers ────────────────────────────────────────────────

function test_separation(components, quantities, compositions, inputs, outputs)
    test_mass_balance(components, quantities, compositions, inputs, outputs)
end


function test_mix(components, quantities, compositions, inputs, outputs)
    test_mass_balance(components, quantities, compositions, inputs, outputs)
    output = outputs[1]
    for c in components
        @test isapprox(
            compositions[output][c],
            sum(quantities[s] * compositions[s][c] for s in inputs) / quantities[output],
            atol=1e-6)
    end
end


function test_split(components, quantities, compositions, inputs, outputs)
    test_mass_balance(components, quantities, compositions, inputs, outputs)
    for s in outputs, c in components
        @test compositions[s][c] ≈ compositions[inputs[1]][c]
    end
end


function test_filter(components, quantities, compositions, inputs, outputs, retention_coefficients)
    test_mass_balance(components, quantities, compositions, inputs, outputs)
    for (c, r) in retention_coefficients
        @test isapprox((compositions[outputs[1]][c] * quantities[outputs[1]]) /
                       (compositions[outputs[2]][c] * quantities[outputs[2]]),
                       r / (1-r), rtol=1e-4)
    end
end


function test_dry(components, ::Any, compositions, inputs, outputs)
    ratios = [compositions[outputs[1]][c] / compositions[inputs[1]][c] for c in components]
    @test all(isapprox(r, ratios[1], rtol=1e-6) for r in ratios)
end


# ── Config-driven test (mirrors what run() validates) ────────────────────────

TEST_OP_MAP = Dict(
    "separation" => (components, quantities, compositions, op) ->
        test_separation(components, quantities, compositions,
            Yield.read_inputs(op), Yield.read_outputs(op)),
    "mix"        => (components, quantities, compositions, op) ->
        test_mix(components, quantities, compositions,
            Yield.read_inputs(op), Yield.read_outputs(op)),
    "split"      => (components, quantities, compositions, op) ->
        test_split(components, quantities, compositions,
            Yield.read_inputs(op), Yield.read_outputs(op)),
    "filter"     => (components, quantities, compositions, op) ->
        test_filter(components, quantities, compositions,
            Yield.read_inputs(op), Yield.read_outputs(op),
            op["retention-coefficients"]),
    "dry"        => (components, quantities, compositions, op) ->
        test_dry(components, quantities, compositions,
            Yield.read_inputs(op), Yield.read_outputs(op)),
)

function test_yield_model(config, components, quantities, compositions)
    for op in config["operations"]
        fn = get(TEST_OP_MAP, op["operation"], nothing)
        fn !== nothing && fn(components, quantities, compositions, op)
    end
    for (s, q) in config["quantities"]
        @test quantities[s] ≈ q
    end
    for (s, targets) in config["compositions"]
        test_composition(components, compositions[s], targets)
    end
end

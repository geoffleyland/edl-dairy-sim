function orchestrate_separation_forwards(input_composition, separation_component, component_fractions)
    components = keys(input_composition)
    streams = ["milk", "skim", "cream"]

    𝓜 = build_yield_model(components, streams)

    add_separation_model(𝓜, components, ["milk"], ["skim", "cream"], separation_component)

    set_stream_quantity(𝓜, "milk", 1)
    set_stream_composition(𝓜, components, "milk", input_composition)
    set_stream_composition.(𝓜, Ref(components), ["skim", "cream"], [Dict(separation_component => f) for f in component_fractions])

    solve_yield_model(𝓜, components, streams)
end


function orchestrate_separation_backwards(input_composition, separation_component, output_quantities, output_1_fraction)
    components = keys(input_composition)
    streams = ["milk", "skim", "cream"]

    𝓜 = build_yield_model(components, streams)

    add_separation_model(𝓜, components, ["milk"], ["skim", "cream"], separation_component)

    set_stream_quantity(𝓜, "milk", 1)
    set_stream_composition(𝓜, components, "milk", input_composition)
    set_stream_quantity.(𝓜, ["skim", "cream"], output_quantities)
    set_stream_composition(𝓜, components, "skim", Dict(separation_component => output_1_fraction))

    solve_yield_model(𝓜, components, streams)
end


function orchestrate_mix(input_compositions, output_targets)
    components = keys(input_compositions[1])
    input_count = length(input_compositions)

    𝓜 = build_yield_model(components, 1:input_count+2)

    add_mix_model(𝓜, components, 1:input_count, [input_count+1])
    add_dry_model(𝓜, components, [input_count+1], [input_count+2])

    set_stream_quantity(𝓜, input_count+2, 1)
    set_stream_composition.(𝓜, Ref(components), 1:input_count, input_compositions)
    set_stream_composition(𝓜, components, input_count+2, output_targets)

    solve_yield_model(𝓜, components, 1:input_count+2)
end


function orchestrate_separation_and_mix(milk_composition, lactose_composition, fat_fractions, output_targets)
    components = keys(milk_composition)
    streams = ["milk", "lactose", "skim", "sep cream", "mix cream", "treated milk", "powder", "excess cream"]

    𝓜 = build_yield_model(components, streams)

    set_stream_composition(𝓜, components, "milk", milk_composition)
    set_stream_composition(𝓜, components, "lactose", lactose_composition)
    set_stream_composition.(𝓜, Ref(components), ["skim", "sep cream"], [Dict("fat" => f) for f in fat_fractions])
    set_stream_composition(𝓜, components, "powder", output_targets)
    set_stream_quantity(𝓜, "powder", 1)

    add_separation_model(𝓜, components, ["milk"], ["skim", "sep cream"], "fat")
    add_mix_model(𝓜, components, ["lactose", "skim", "mix cream"], ["treated milk"])
    add_dry_model(𝓜, components, ["treated milk"], ["powder"])
    add_split_model(𝓜, components, ["sep cream"], ["mix cream", "excess cream"])

    solve_yield_model(𝓜, components, streams)
end


function orchestrate_powder_and_butter(milk_composition, lactose_composition, fat_fractions, butter_fractions, output_targets)
    components = keys(milk_composition)
    streams = ["milk", "lactose", "skim", "sep cream", "mix cream", "treated milk", "powder", "butter cream", "butter", "buttermilk"]

    𝓜 = build_yield_model(components, streams)

    set_stream_composition(𝓜, components, "milk", milk_composition)
    set_stream_composition(𝓜, components, "lactose", lactose_composition)
    set_stream_composition.(𝓜, Ref(components), ["skim", "sep cream"], [Dict("fat" => f) for f in fat_fractions])
    set_stream_composition(𝓜, components, "powder", output_targets)
    set_stream_quantity(𝓜, "powder", 1)
    set_stream_composition.(𝓜, Ref(components), ["buttermilk", "butter"], [Dict("fat" => f) for f in butter_fractions])

    add_separation_model(𝓜, components, ["milk"], ["skim", "sep cream"], "fat")
    add_mix_model(𝓜, components, ["lactose", "skim", "mix cream"], ["treated milk"])
    add_dry_model(𝓜, components, ["treated milk"], ["powder"])
    add_split_model(𝓜, components, ["sep cream"], ["mix cream", "butter cream"])
    add_separation_model(𝓜, components, ["butter cream"], ["buttermilk", "butter"], "fat")

    solve_yield_model(𝓜, components, streams)
end


function orchestrate_powder_permeate_and_butter(milk_composition, fat_fractions, butter_fractions, retention_coefficients, retentate_protein, output_targets)
    components = keys(milk_composition)
    streams = ["milk", "sep skim", "sep cream", "mix skim", "filter skim", "retentate", "permeate", "mix cream", "treated milk", "powder", "butter cream", "butter", "buttermilk"]

    𝓜 = build_yield_model(components, streams)

    set_stream_composition(𝓜, components, "milk", milk_composition)
    set_stream_composition.(𝓜, Ref(components), ["sep skim", "sep cream"], [Dict("fat" => f) for f in fat_fractions])
    set_stream_composition(𝓜, components, "powder", output_targets)
    set_stream_composition(𝓜, components, "retentate",  Dict("protein" => retentate_protein))
    set_stream_quantity(𝓜, "powder", 1)
    set_stream_composition.(𝓜, Ref(components), ["buttermilk", "butter"], [Dict("fat" => f) for f in butter_fractions])

    add_separation_model(𝓜, components, ["milk"], ["sep skim", "sep cream"], "fat")
    add_split_model(𝓜, components, ["sep skim"], ["mix skim", "filter skim"])
    add_mix_model(𝓜, components, ["permeate", "mix skim", "mix cream"], ["treated milk"])
    add_dry_model(𝓜, components, ["treated milk"], ["powder"])
    add_filter_model(𝓜, components, ["filter skim"], ["retentate", "permeate"], retention_coefficients)
    add_split_model(𝓜, components, ["sep cream"], ["mix cream", "butter cream"])
    add_separation_model(𝓜, components, ["butter cream"], ["buttermilk", "butter"], "fat")

    solve_yield_model(𝓜, components, streams)
end


function orchestrate_powder_MPC_and_butter(milk_composition, fat_fractions, butter_fractions, retention_coefficients, powder_targets, mpc_targets)
    components = keys(milk_composition)
    streams = ["milk", "sep skim", "sep cream", "mix skim", "filter skim", "retentate", "permeate", "mix cream", "treated milk", "powder", "butter cream", "butter", "buttermilk", "MPC"]

    𝓜 = build_yield_model(components, streams)

    set_stream_composition(𝓜, components, "milk", milk_composition)
    set_stream_composition.(𝓜, Ref(components), ["sep skim", "sep cream"], [Dict("fat" => f) for f in fat_fractions])
    set_stream_composition(𝓜, components, "powder", powder_targets)
    set_stream_composition(𝓜, components, "MPC",  mpc_targets)
    set_stream_quantity(𝓜, "powder", 1)
    set_stream_composition.(𝓜, Ref(components), ["buttermilk", "butter"], [Dict("fat" => f) for f in butter_fractions])

    add_separation_model(𝓜, components, ["milk"], ["sep skim", "sep cream"], "fat")
    add_split_model(𝓜, components, ["sep skim"], ["mix skim", "filter skim"])
    add_mix_model(𝓜, components, ["permeate", "mix skim", "mix cream"], ["treated milk"])
    add_dry_model(𝓜, components, ["treated milk"], ["powder"])
    add_filter_model(𝓜, components, ["filter skim"], ["retentate", "permeate"], retention_coefficients)
    add_split_model(𝓜, components, ["sep cream"], ["mix cream", "butter cream"])
    add_separation_model(𝓜, components, ["butter cream"], ["buttermilk", "butter"], "fat")
    add_dry_model(𝓜, components, ["retentate"], ["MPC"])

    solve_yield_model(𝓜, components, streams)
end

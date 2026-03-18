function add_split_model(𝓜, components, inputs, outputs)
    input = inputs[1]
    quantity = 𝓜[:quantity]
    composition = 𝓜[:composition]

    @constraints 𝓜 begin
        # Conserve mass across the splits.
        quantity[input] == sum(quantity[s] for s in outputs)

        # All streams have the same composition.
        [s in outputs, c in components],
            composition[input, c] == composition[s, c]
    end
end



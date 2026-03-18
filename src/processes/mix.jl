function add_mix_model(𝓜, components, inputs, outputs)
    output = outputs[1]
    quantity = 𝓜[:quantity]
    composition = 𝓜[:composition]

    @constraints 𝓜 begin
        # Compute output quantity
        quantity[output] == sum(quantity[s] for s in inputs)

        # Compute output component fractions.
        [c in components],
            composition[output, c] == sum(composition[s, c] * quantity[s] for s in inputs) /
                                        sum(quantity[s] for s in inputs)
    end
end



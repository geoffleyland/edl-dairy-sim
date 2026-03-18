function add_dry_model(𝓜, components, inputs, outputs)
    input = inputs[1]
    output = outputs[1]
    quantity = 𝓜[:quantity]
    composition = 𝓜[:composition]

    v = @variable(𝓜, lower_bound = 1.0)

    @constraints 𝓜 begin
        # input quantity is output quantity * v
        quantity[input] == quantity[output] * v

        # composition is multiplied by v.
        [c in components],
            composition[output, c] == composition[input, c] * v

        # Total composition can't be greater than 1
        sum(composition[output, c] for c in components) <= 1.0
    end
end



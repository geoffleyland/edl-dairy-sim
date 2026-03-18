function add_separation_model(𝓜, components, inputs, outputs, separation_component)
    input = inputs[1]
    quantity = 𝓜[:quantity]
    composition = 𝓜[:composition]

    function other_stream(s)
        if s == outputs[1] outputs[2] else outputs[1] end
    end

    @constraints 𝓜 begin
        # Compute output stream quantities.
        [s in outputs],
            quantity[s] == quantity[input] *
                            (composition[input, separation_component] - composition[other_stream(s), separation_component]) /
                            (composition[s, separation_component] - composition[other_stream(s), separation_component])

        # Compute fractions of the not separation components in the output streams.
        [s in outputs, c in components; c ≠ separation_component],
            composition[s, c] == composition[input, c] *
                                    (1 - composition[s, separation_component]) /
                                    (1 - composition[input, separation_component])
    end
end



function add_filter_model(𝓜, components, inputs, outputs, retention_coefficients)
    input = inputs[1]
    retentate = outputs[1]
    permeate = outputs[2]
    quantity = 𝓜[:quantity]
    composition = 𝓜[:composition]

    solution_components = setdiff(components, keys(retention_coefficients))

    # volume concentration factor and inverse concentration factor
    v = @variable(𝓜, lower_bound = 1.0)
    vdash = @expression(𝓜, v / (v - 1))

    # total fraction of filtered components in the input, retentate, and permeate
    Fi = @expression(𝓜, sum(composition[input, c] for (c, _) in retention_coefficients))
    Fr = @expression(𝓜, sum(composition[input, c] * r for (c, r) in retention_coefficients))
    Fp = @expression(𝓜, sum(composition[input, c] * (1-r) for (c, r) in retention_coefficients))

    @constraints 𝓜 begin
        # Compute quantity of retentate and permeate
        quantity[retentate] == quantity[input] / v
        quantity[permeate] == quantity[input] / vdash

        # Compute retentate composition of fixed coefficient
        [c in keys(retention_coefficients)],
            composition[retentate, c] == composition[input, c] * retention_coefficients[c] * v
        [c in keys(retention_coefficients)],
            composition[permeate, c] == composition[input, c] * (1-retention_coefficients[c]) * vdash

        # Compute retentate composition a component in solution
        [c in solution_components],
            composition[retentate, c] == composition[input, c] * (1 - Fr * v) / (1 - Fi)

        [c in solution_components],
            composition[permeate, c] == composition[input, c] * (1 - Fp * vdash) / (1 - Fi)
    end
end



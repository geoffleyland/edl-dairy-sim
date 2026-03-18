# "Bind" a Dict-like object to a struct.
#
# The common use case being to read some JSON into a dict-like object (with JSON.parse or
# JSON3.read), and then directly create structs from the JSON data (provided the structure
# of the JSON and the structure match).

# A JSON vector matches a Vector...
function bind(v::Vector{Any}, ::Type{Vector{T}}) where T; [bind(e, T) for e in v] end
# ...or a Set.
function bind(v::Vector{Any}, ::Type{Set{T}}) where T; Set(bind(e, T) for e in v) end

# If the JSON we're reading is an element of a Dict A with a key K and a value B which is in
# turn a Dict, and the thing we're reading it into is a structure (C), and if the structure
# C has fields named "key", "name" or "code", then try to insert the key K from Dict A as
# into Dict B as the appropriate name(s).  This means that K can be used to initialise such
# fields of the structure C.
# Because later arguments win in `merge`, if Dict B already contains one of those fields,
# the value in B will win over the key from A, so it's a pretty low-risk thing to do.
# More clearly the JSON
# ```{ "one": { "value": 1}, "two": { "value": 2}}```
# Can become a vector of structs with fields `name` and `value``:
# [struct S(name: 'one', value: 1), struct S(name: 'two', value: 2)]
function insert_key(key, v::Dict{String, Any}, ::Type{T}) where T
    if isstructtype(T)
        key_names = ["key", "code", "name"] ∩ String.(fieldnames(T))
        merge(Dict{String, Any}(key_name => key for key_name in key_names), v)
    else
        v
    end
end
function insert_key(key, v, ::Type{T}) where T v end

# A JSON Dict can match a Dict...
function bind(d::Dict{String, Any}, ::Type{Dict{String, T}}) where T;
    Dict(k => bind(insert_key(k, v, T), T) for (k, v) in d)
end
# ...or a vector, where we add a "name" field.  This is a little dodgy, because we might
# get a spurious match (JSON has a Dict, the structure has an array), but, actually, it's
# really handy, and the chance that the user has a Dict in JSON and a vector in Julia with
# THE SAME FIELDS and doesn't want the vector to be populated is kind of low.
function bind(d::Dict{String, Any}, ::Type{Vector{T}}) where T
    [bind(insert_key(k, v, T), T) for (k, v) in d]
end

# A JSON dict can match a struct (provided the fields match)
# This will translate from "-" in JSON field names to "_". to match Julia struct fields if
# necessary.
function bind(d::Dict{String, Any}, ::Type{T}) where T
    args = NamedTuple()
    for (name, type) in zip(fieldnames(T), T.types)
        v = get(d, String(name), get(d, replace(String(name), "_" => "-"), nothing))
        if v !== nothing
            args = merge(args, NamedTuple{(name,)}((bind(v, type),)))
        end
    end
    missing_fields = setdiff(fieldnames(T), keys(args))
    if !isempty(missing_fields)
        mod = parentmodule(T)
        try
            cf = if isdefined(mod, :computed_fields) &&
                hasmethod(getfield(mod, :computed_fields), Tuple{Type{T}})
                getfield(mod, :computed_fields)
            else
                computed_fields
            end
            for field in missing_fields
                try
                    args = merge(args, NamedTuple{(field,)}((cf(T)[field](args),)))
                catch e1
                    msg = sprint(showerror, e1)
                    error("Couldn't compute the field '$field' of struct '$T':\n  $msg")
                end
            end
        catch e2
            msg = sprint(showerror, e2)
            error("Couldn't compute the missing fields ($(join(missing_fields, ",", " and "))) of struct '$T':\n  $msg")
        end
    end

    ordered_args = (getfield(args, f) for f in fieldnames(T))
    try
        T(ordered_args...)
    catch e
        kv_string = join(("$k: $v" for (k, v) in d), "\n  ")
        msg = sprint(showerror, e)
        error("Couldn't construct a '$T' from:\n  $kv_string\nThe error was:\n  $msg")
    end
end

# Lastly, just pass through scalars, string and numbers, etc.
# TODO: when this fails (the JSON and Julia types don't match) we don't get much help from
# the traceback.
function bind(v, ::Type{T}) where T; v end

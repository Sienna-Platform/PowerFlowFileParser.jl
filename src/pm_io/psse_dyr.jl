# PSS/E `.dyr` dynamic data reader.
#
# Two steps. `parse_dyr_text` reads text into bus => (model, id) => parameter vector.
# `assemble_dyr` groups the models of one (bus, id) into a `DyrRecord`: the injection kind
# and an ordered list of function blocks. Each block has a SiennaSchemas class name, a schema
# type name and a dictionary keyed by schema field names. Phase 2 turns the records into
# OpenAPI objects. It must also supply what a `.dyr` file does not hold (see `DyrRecord`).

#################################################################################
# Field sources

"Source of one schema field in a PSS/E parameter vector. Indices count from 1."
abstract type DyrSource end

struct DyrReal <: DyrSource
    index::Int
end

struct DyrInt <: DyrSource
    index::Int
end

struct DyrBool <: DyrSource
    index::Int
end

"Parameter that holds an integer code. The schema field is a string."
struct DyrString <: DyrSource
    index::Int
end

struct DyrConst <: DyrSource
    value::Float64
end

"Pair `(min, max)` read from two indices."
struct DyrMinMax <: DyrSource
    min::Int
    max::Int
end

"Pair `(up, down)` read from two indices."
struct DyrUpDown <: DyrSource
    up::Int
    down::Int
end

"Pair `(dbd1, dbd2)` read from two indices."
struct DyrDbd <: DyrSource
    dbd1::Int
    dbd2::Int
end

"Pair `(fdbd1, fdbd2)` read from two indices."
struct DyrFdbd <: DyrSource
    fdbd1::Int
    fdbd2::Int
end

"Vector of two or three values read from the given indices."
struct DyrArray <: DyrSource
    indices::Vector{Int}
end

DyrArray(indices::Int...) = DyrArray(collect(indices))

"Two points `[(t0, v0), (t1, v1)]`. Each point is a (time index, value index) pair."
struct DyrPoints <: DyrSource
    t0::Int
    v0::Int
    t1::Int
    v1::Int
end

"Quadratic saturation coefficients `(A, B)` from the pair `Se(1.0), Se(1.2)`."
struct DyrQuadraticSaturation <: DyrSource
    se1::Int
    se2::Int
end

"Exponential saturation coefficients `(A, B)` from the pair `Se(1.0), Se(1.2)`."
struct DyrExponentialSaturation <: DyrSource
    se1::Int
    se2::Int
end

"Reference to another block of the same record, given by its class name. Phase 2 replaces it with the block id."
struct DyrRef <: DyrSource
    class::String
end

Base.:(==)(a::DyrRef, b::DyrRef) = a.class == b.class

"Placeholder for the system frequency in Hz. The `.dyr` file does not hold it."
struct DyrSystemFrequency end

"One function block of a model: schema class, schema type and field sources."
struct DyrBlock
    class::String
    type::String
    fields::Vector{Pair{String, DyrSource}}
end

"A PSS/E model. The `kind` is `:generator`, `:inverter` or `:der`."
struct DyrModel
    kind::Symbol
    blocks::Vector{DyrBlock}
end

#################################################################################
# Value conversion

function _dyr_param(values::Vector{Float64}, index::Int, context::AbstractString)
    if index > length(values)
        throw(
            DataFormatError(
                "$context has $(length(values)) parameters, but the mapping needs parameter $index",
            ),
        )
    end
    return values[index]
end

function _dyr_integer(x::Float64, context::AbstractString)
    if !isinteger(x)
        throw(DataFormatError("$context: expected an integer, got $x"))
    end
    return Int(x)
end

function dyr_value(s::DyrReal, values::Vector{Float64}, context::AbstractString)
    return _dyr_param(values, s.index, context)
end

function dyr_value(s::DyrInt, values::Vector{Float64}, context::AbstractString)
    return _dyr_integer(_dyr_param(values, s.index, context), context)
end

function dyr_value(s::DyrString, values::Vector{Float64}, context::AbstractString)
    return string(_dyr_integer(_dyr_param(values, s.index, context), context))
end

function dyr_value(s::DyrBool, values::Vector{Float64}, context::AbstractString)
    x = _dyr_param(values, s.index, context)
    if iszero(x)
        return false
    elseif isone(x)
        return true
    end
    throw(DataFormatError("$context: expected a flag 0 or 1, got $x"))
end

dyr_value(s::DyrConst, ::Vector{Float64}, ::AbstractString) = s.value

dyr_value(s::DyrRef, ::Vector{Float64}, ::AbstractString) = s

function dyr_value(s::DyrMinMax, values::Vector{Float64}, context::AbstractString)
    return (
        min = _dyr_param(values, s.min, context),
        max = _dyr_param(values, s.max, context),
    )
end

function dyr_value(s::DyrUpDown, values::Vector{Float64}, context::AbstractString)
    return (
        up = _dyr_param(values, s.up, context),
        down = _dyr_param(values, s.down, context),
    )
end

function dyr_value(s::DyrDbd, values::Vector{Float64}, context::AbstractString)
    return (
        dbd1 = _dyr_param(values, s.dbd1, context),
        dbd2 = _dyr_param(values, s.dbd2, context),
    )
end

function dyr_value(s::DyrFdbd, values::Vector{Float64}, context::AbstractString)
    return (
        fdbd1 = _dyr_param(values, s.fdbd1, context),
        fdbd2 = _dyr_param(values, s.fdbd2, context),
    )
end

function dyr_value(s::DyrArray, values::Vector{Float64}, context::AbstractString)
    return [_dyr_param(values, i, context) for i in s.indices]
end

function dyr_value(s::DyrPoints, values::Vector{Float64}, context::AbstractString)
    return [
        [_dyr_param(values, s.t0, context), _dyr_param(values, s.v0, context)],
        [_dyr_param(values, s.t1, context), _dyr_param(values, s.v1, context)],
    ]
end

"""
Coefficients `(A, B)` of `Se(x) = B (x - A)^2 / x` fitted to `Se(E1)` and `Se(E2)`.
Same formula as psy5. Zero saturation data gives `(0.0, 0.0)`.
"""
function _dyr_saturation_coefficients(
    E::NTuple{2, Float64},
    Se::NTuple{2, Float64},
    context::AbstractString,
)
    if iszero(E[1]) || iszero(E[2]) || iszero(Se[1]) || iszero(Se[2])
        return [0.0, 0.0]
    end
    if (E[2] <= E[1]) || (Se[2] <= Se[1])
        throw(DataFormatError("$context: saturation data is inconsistent, Se = $Se"))
    end
    A =
        (1.0 / (Se[2] * E[2] - Se[1] * E[1])) * (
            E[1] * E[2] * (Se[2] - Se[1]) -
            sqrt(E[1] * E[2] * Se[1] * Se[2] * (E[1] - E[2])^2)
        )
    B = Se[2] * E[2] / (E[2] - A)^2
    if abs(B - Se[1] * E[1] / (E[1] - A)^2) > 1e-2
        throw(DataFormatError("$context: saturation fit failed, Se = $Se"))
    end
    return [A, B]
end

function dyr_value(
    s::DyrQuadraticSaturation,
    values::Vector{Float64},
    context::AbstractString,
)
    Se = (_dyr_param(values, s.se1, context), _dyr_param(values, s.se2, context))
    return _dyr_saturation_coefficients((1.0, 1.2), Se, context)
end

"Coefficients `(A, B)` of `Se = B x^A`. Same formula as psy5."
function dyr_value(
    s::DyrExponentialSaturation,
    values::Vector{Float64},
    context::AbstractString,
)
    Se = (_dyr_param(values, s.se1, context), _dyr_param(values, s.se2, context))
    if iszero(Se[1]) || iszero(Se[2])
        @warn "$context: Se = $Se has a zero value. Ignoring saturation."
        return [0.0, 0.0]
    end
    if Se[2] <= Se[1]
        throw(DataFormatError("$context: saturation data is inconsistent, Se = $Se"))
    end
    return [log(Se[2] / Se[1]) / log(1.2), Se[1]]
end

#################################################################################
# Reader

const DyrParameters = Dict{Int, Dict{Tuple{String, String}, Vector{Float64}}}

function _dyr_strip_comments(text::AbstractString)
    kept = String[]
    for line in split(text, '\n')
        if !startswith(strip(line), "//")
            push!(kept, line)
        end
    end
    return join(kept, "\n")
end

function _dyr_parse_record!(
    parsed::DyrParameters,
    record::AbstractString,
    location::AbstractString,
)
    tokens = split(replace(replace(record, "'" => ""), "," => " "))
    if length(tokens) < 3
        throw(DataFormatError("$location: record needs bus, model and id, got `$record`"))
    end
    bus = tryparse(Int, tokens[1])
    if isnothing(bus)
        throw(DataFormatError("$location: bus `$(tokens[1])` is not an integer"))
    end
    model = String(tokens[2])
    id = String(tokens[3])
    values = Float64[]
    for token in tokens[4:end]
        x = tryparse(Float64, token)
        if isnothing(x)
            throw(
                DataFormatError(
                    "$location: bus $bus, model $model, id $id: `$token` is not a number",
                ),
            )
        end
        push!(values, x)
    end
    models = get!(parsed, bus, Dict{Tuple{String, String}, Vector{Float64}}())
    if haskey(models, (model, id))
        throw(DataFormatError("$location: duplicate record for bus $bus, $model, id $id"))
    end
    models[(model, id)] = values
    return
end

"""
Parse `.dyr` text into a dictionary indexed by bus number. Each bus holds a dictionary
indexed by `(model, id)` with the parameter vector of the record.

A `/` ends a record. A record can span many lines. A line that starts with `//` is a comment.
"""
function parse_dyr_text(text::AbstractString; source::AbstractString = "dyr text")
    text = _dyr_strip_comments(text)
    parsed = DyrParameters()
    position = 1
    while true
        stop = findnext('/', text, position)
        if isnothing(stop)
            rest = strip(text[position:end])
            if !isempty(rest)
                throw(DataFormatError("$source: record without terminator `/`: `$rest`"))
            end
            break
        end
        record = strip(text[position:prevind(text, stop)])
        if !isempty(record)
            _dyr_parse_record!(parsed, record, source)
        end
        position = nextind(text, stop)
    end
    return parsed
end

"Parse a `.dyr` file. See [`parse_dyr_text`](@ref)."
function parse_dyr_file(file::AbstractString)
    if lowercase(splitext(file)[2]) != ".dyr"
        throw(DataFormatError("$file is not a .dyr file type"))
    end
    return parse_dyr_text(read(file, String); source = file)
end

#################################################################################
# Assembly

"A schema function block: its schema type name and field dictionary."
struct DyrComponent
    type::String
    fields::Dict{String, Any}
end

"""
Dynamic data of one (bus, id). The field `kind` is `:generator`, `:inverter` or `:der`.
The field `components` lists class => component in schema order. A generator record has
`base_machine` (when the machine type needs it), `synchronous_machine_dynamics`, `shaft`,
`excitation_system_dynamics`, `turbine_governor_dynamics` and `power_system_stabilizer_dynamics`.
An inverter record has `converter`, `active_power_control`, `reactive_power_control`,
`inner_control`, `dc_source`, `reference_frame_rotation` and `filter`. It has no
`current_limitation`: the schema allows null. A `:der` record has `dynamic_injection`.

A `.dyr` file does not hold these values. Phase 2 must set them from the static data:
`name`, `base_power` and `frequency_ref` of the injection, `R` (RSORCE) and `Xd_p` (XSORCE) of
`BaseMachine`, `R` of the base machine, and every `DyrSystemFrequency` value.
"""
struct DyrRecord
    bus::Int
    id::String
    kind::Symbol
    components::Vector{Pair{String, DyrComponent}}
end

function get_component(record::DyrRecord, class::AbstractString)
    for (c, component) in record.components
        if c == class
            return component
        end
    end
    throw(KeyError(class))
end

has_component(record::DyrRecord, class::AbstractString) =
    any(c == class for (c, _) in record.components)

const DYR_CLASS_ORDER = Dict{Symbol, Vector{String}}(
    :generator => [
        "base_machine",
        "synchronous_machine_dynamics",
        "shaft",
        "excitation_system_dynamics",
        "turbine_governor_dynamics",
        "power_system_stabilizer_dynamics",
    ],
    :inverter => [
        "converter",
        "active_power_control",
        "reactive_power_control",
        "inner_control",
        "dc_source",
        "reference_frame_rotation",
        "filter",
    ],
    :der => ["dynamic_injection"],
)

# psy5 `_assign_missing_components!`: AVRFixed(1.0), TGFixed(1.0), PSSFixed(0.0).
const DYR_GENERATOR_DEFAULTS = Dict{String, DyrComponent}(
    "excitation_system_dynamics" =>
        DyrComponent("AVRFixed", Dict{String, Any}("Vf" => 1.0)),
    "turbine_governor_dynamics" =>
        DyrComponent("TGFixed", Dict{String, Any}("efficiency" => 1.0)),
    "power_system_stabilizer_dynamics" =>
        DyrComponent("PSSFixed", Dict{String, Any}("V_pss" => 0.0)),
)

# psy5: AverageConverter(750, 2.75), RLFilter(0, 0), FixedFrequency(), FixedDCSource(750).
const DYR_INVERTER_DEFAULTS = Dict{String, DyrComponent}(
    "converter" => DyrComponent(
        "AverageConverter",
        Dict{String, Any}("rated_voltage" => 750.0, "rated_current" => 2.75),
    ),
    "filter" => DyrComponent("RLFilter", Dict{String, Any}("rf" => 0.0, "lf" => 0.0)),
    "reference_frame_rotation" => DyrComponent(
        "FixedFrequency",
        Dict{String, Any}("frequency" => DyrSystemFrequency()),
    ),
    "dc_source" => DyrComponent("FixedDCSource", Dict{String, Any}("voltage" => 750.0)),
)

dyr_defaults(::Val{:generator}) = DYR_GENERATOR_DEFAULTS
dyr_defaults(::Val{:inverter}) = DYR_INVERTER_DEFAULTS
dyr_defaults(::Val{:der}) = Dict{String, DyrComponent}()

# Models whose psy5 mapping is known to be wrong. A record with one of them is an error.
const DYR_BROKEN_MODELS = Dict{String, String}(
    "EXAC1A" => "the psy5 mapping gives 14 parameters and has no Vr_lim, which the schema requires",
)

# Union of the field names that the table gives to each (class, type).
function _dyr_block_fields()
    fields = Dict{Tuple{String, String}, Set{String}}()
    for model in values(DYR_MODEL_TABLE)
        for block in model.blocks
            union!(
                get!(fields, (block.class, block.type), Set{String}()),
                first.(block.fields),
            )
        end
    end
    return fields
end

function _dyr_merge!(
    components::Dict{String, DyrComponent},
    block::DyrBlock,
    values::Vector{Float64},
    context::AbstractString,
)
    fields = Dict{String, Any}(
        name => dyr_value(source, values, context) for (name, source) in block.fields
    )
    if !haskey(components, block.class)
        components[block.class] = DyrComponent(block.type, fields)
        return
    end
    existing = components[block.class]
    if existing.type != block.type
        throw(
            DataFormatError(
                "$context: class $(block.class) has both $(existing.type) and $(block.type)",
            ),
        )
    end
    for (name, value) in fields
        if haskey(existing.fields, name) && existing.fields[name] != value
            throw(
                DataFormatError(
                    "$context: field $name of $(block.type) has conflicting values",
                ),
            )
        end
        existing.fields[name] = value
    end
    return
end

function _dyr_finish(
    bus::Int,
    id::String,
    kind::Symbol,
    components::Dict{String, DyrComponent},
    models::Vector{String},
)
    where_ = "bus $bus, id $id ($(join(models, ", ")))"
    for (class, component) in components
        missing_fields =
            setdiff(DYR_BLOCK_FIELDS[(class, component.type)], keys(component.fields))
        if !isempty(missing_fields)
            throw(
                DataFormatError(
                    "$where_: $class $(component.type) lacks fields $(sort!(collect(missing_fields))). A companion model is missing from the .dyr file",
                ),
            )
        end
    end
    for (class, default) in dyr_defaults(Val(kind))
        if !haskey(components, class)
            components[class] = default
        end
    end
    ordered = Pair{String, DyrComponent}[]
    for class in DYR_CLASS_ORDER[kind]
        if haskey(components, class)
            push!(ordered, class => components[class])
        elseif class != "base_machine"
            throw(
                DataFormatError(
                    "$where_: no model for $class. A companion model is missing from the .dyr file",
                ),
            )
        end
    end
    return DyrRecord(bus, id, kind, ordered)
end

function _dyr_assemble_bus(bus::Int, bus_data::Dict{Tuple{String, String}, Vector{Float64}})
    kinds = Dict{String, Symbol}()
    components = Dict{String, Dict{String, DyrComponent}}()
    models = Dict{String, Vector{String}}()
    for (model, id) in sort!(collect(keys(bus_data)))
        context = "bus $bus, model $model, id $id"
        if haskey(DYR_BROKEN_MODELS, model)
            throw(
                DataFormatError(
                    "$context: $model is not supported, $(DYR_BROKEN_MODELS[model])",
                ),
            )
        end
        if !haskey(DYR_MODEL_TABLE, model)
            @warn "$model at bus $bus, id $id, not supported. Skipping data."
            continue
        end
        entry = DYR_MODEL_TABLE[model]
        if get!(kinds, id, entry.kind) != entry.kind
            throw(
                DataFormatError(
                    "$context: id is used by a $(kinds[id]) model and a $(entry.kind) model",
                ),
            )
        end
        id_components = get!(components, id, Dict{String, DyrComponent}())
        push!(get!(models, id, String[]), model)
        for block in entry.blocks
            _dyr_merge!(id_components, block, bus_data[(model, id)], context)
        end
    end
    records = Dict{String, DyrRecord}()
    for id in sort!(collect(keys(components)))
        records[id] = _dyr_finish(bus, id, kinds[id], components[id], models[id])
    end
    return records
end

"""
Group the models of each (bus, id) into a [`DyrRecord`](@ref). The input comes from
[`parse_dyr_text`](@ref). The result is indexed by bus, then by id.

A model that is not in the mapping table gives a warning and is skipped. A (bus, id) with
missing companion models gives an error: a generator needs a machine and a shaft model, an
inverter needs REECB1 and REPCA1. A missing exciter, governor or stabilizer, converter,
filter, DC source or frequency estimator takes the psy5 default.
"""
function assemble_dyr(data::DyrParameters)
    assembled = Dict{Int, Dict{String, DyrRecord}}()
    for bus in sort!(collect(keys(data)))
        assembled[bus] = _dyr_assemble_bus(bus, data[bus])
    end
    return assembled
end

"Read a `.dyr` file into records indexed by bus and id."
parse_dyr(file::AbstractString) = assemble_dyr(parse_dyr_file(file))

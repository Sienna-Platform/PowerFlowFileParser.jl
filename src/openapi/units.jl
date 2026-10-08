"""
Unit-checked assignment onto generated OpenAPI components.

Generated component types are immutable `Base.@kwdef struct`s with no common mutable
state, so a builder cannot allocate one empty and mutate it field by field the way the
pre-1.0 OpenAPI.jl runtime allowed. [`stage`](@ref) opens a mutable scratch dict typed to
the target type instead; `set_value!`/`get_value` read and write that dict, resolving unit
and compound-type information from `fieldtype` and the generated unit metadata;
[`materialize`](@ref) (called from `add_component!`/`add_supplemental_attribute!` in
`container.jl`) builds the real immutable struct once, from every field accumulated so far.

The two `set_value!` arities are the enforcement, as before: a property that declares a
unit can only be written by the 4-argument form, and one that does not can only be written
by the 3-argument form, so the check cannot be skipped by choosing the shorter call.

A property annotated `x-unit-base` (`ACBus.magnitude`/`voltage_limits`, `Source.
internal_voltage`, ...) is per-unit on a SIBLING PROPERTY'S OWN VALUE rather than a fixed
scalar factor; assigning or reading one converts through that sibling's own declared unit,
so the sibling must be staged first.
"""

"""
Mutable staging for a to-be-immutable OpenAPI model type `T`.

`stage(T)` opens one of these with an empty field dict; `set_value!`/`get_value` accumulate
into it; `materialize` builds the real `T` in one kwarg call once every field the caller
means to set has been staged. Fields are stored already coerced to the exact concrete type
`T` declares (see [`_coerce`](@ref)), so materialization is a plain, conversion-free
`T(; fields...)`.
"""
struct Staged{T}
    fields::Dict{Symbol, Any}
end

"""Open a staging area for `T`. Replaces the old empty-construct `T()`."""
stage(::Type{T}) where {T} = Staged{T}(Dict{Symbol, Any}())

"""Build the real, immutable `T` from every field staged so far."""
materialize(s::Staged{T}) where {T} = T(; s.fields...)

"""
A value already of the target type is a no-op; otherwise call the target type's own
constructor on it.

This is how a raw `String` such as `"ONLINE"` becomes the validating enum wrapper a
generated field actually declares (`OperationalStates`, `UnitSystem`, ...): there is no
generic `convert` fallback for these types, and assignment must run the same validation the
old mutable `setproperty!` path did.
"""
_coerce(::Type{T}, value::T) where {T} = value
_coerce(::Type{T}, value) where {T} = T(value)

"""Whether `Absent` is one of `u`'s member types."""
_has_absent(u::Union) = Absent in Base.uniontypes(u)
_has_absent(::Type) = false

"""The member types of `t`; a non-`Union` type is its own sole member."""
_concrete_types(u::Union) = Base.uniontypes(u)
_concrete_types(t::Type) = (t,)

"""
The single concrete type a field can actually hold, with the `Absent`/`Nothing` arms the
generator adds to every optional field stripped off.

Used both to build a compound value (`MinMax`, `UpDown`, `FromTo`, ...) and to know what
[`_coerce`](@ref) should convert a plain value into.
"""
function _concrete_field_type(::Type{T}, prop::Symbol) where {T}
    ftype = fieldtype(T, prop)
    concrete = filter(t -> t !== Nothing && t !== Absent, collect(_concrete_types(ftype)))
    if length(concrete) != 1
        throw(
            IS.DataFormatError(
                "$(nameof(T)).$prop is not a single concrete type: $ftype",
            ),
        )
    end
    return only(concrete)
end

"""A placeholder value for a required field this object has not staged yet.

Only used to complete a [`_shadow`](@ref) instance so the generated per-instance
`declared_unit`/`declared_quantity` methods have something to dispatch on; the discriminated
field they actually read is always staged first (by convention, before its dependent
fields), so a placeholder is never the value such a method consults.
"""
_placeholder(::Type{T}) where {T <: Integer} = zero(T)
_placeholder(::Type{T}) where {T <: AbstractFloat} = zero(T)
_placeholder(::Type{Bool}) = false
_placeholder(::Type{String}) = ""
_placeholder(::Type{Dict{K, V}}) where {K, V} = Dict{K, V}()
_placeholder(::Type{Vector{T}}) where {T} = T[]

"""
A placeholder for a required oneOf-wrapper field (`FunctionData`, `*OperationCost`, ...):
the first declared variant, itself placeholder-built recursively.

A shadow only needs *some* valid instance to satisfy the outer struct's required kwarg —
the generated `declared_unit`/`declared_quantity` methods it stands in for never read a
oneOf field's own contents, only a plain sibling discriminator's — so which variant is
picked is immaterial. `EnumAPIModel` gets no such case: unlike a oneOf member, an enum's
inner constructor validates against a fixed string whitelist this package cannot enumerate,
so a required enum field still falls through to the generic fallback below.
"""
function _placeholder(::Type{T}) where {T <: IC.OneOfAPIModel}
    variant = first(Base.uniontypes(fieldtype(T, :value)))
    return T(_placeholder(variant))
end

"""
Recursive fallback: a required compound "shape" type (`MinMax`, `UpDown`, `FromTo`, ...) is
plain numbers with no validation, so a zeroed instance is always constructible. A field
named for one of the [`_DEFAULT_BASIS`](@ref) discriminators (`power_units`, ...) uses that
same default, whatever struct it turns up nested in — a oneOf variant's own basis field
(`CostCurve.power_units`, say) is exactly as placeholder-able as the top-level one
`_default_bases!` defaults. A required field with no such shape and no case above (an enum
wrapper outside that known set) means a caller staged a discriminated numeric field before
the enum field its shadow needs — a genuine ordering bug, so this fails loudly rather than
guessing a value.
"""
function _placeholder(::Type{T}) where {T}
    kwargs = Dict{Symbol, Any}()
    for name in fieldnames(T)
        name === :additional_properties && continue
        ftype = fieldtype(T, name)
        _has_absent(ftype) && continue
        concrete = _concrete_field_type(T, name)
        kwargs[name] = if haskey(_DEFAULT_BASIS, name)
            _coerce(concrete, _DEFAULT_BASIS[name])
        else
            _placeholder(concrete)
        end
    end
    return T(; kwargs...)
end

"""
A throw-away, fully valid `T` built from this object's fields staged so far, standing in for
the real (not-yet-complete) component so the generated per-instance `declared_unit`/
`declared_quantity` methods — which resolve a discriminated field's unit by reading a sibling
basis field via `getproperty` — have a real `T` to dispatch on. Every field not yet staged
gets a [`_placeholder`](@ref).
"""
function _shadow(s::Staged{T}) where {T}
    kwargs = Dict{Symbol, Any}()
    for name in fieldnames(T)
        name === :additional_properties && continue
        if haskey(s.fields, name)
            kwargs[name] = s.fields[name]
        else
            ftype = fieldtype(T, name)
            _has_absent(ftype) && continue
            kwargs[name] = _placeholder(_concrete_field_type(T, name))
        end
    end
    return T(; kwargs...)
end

"""
Basis-selector fields this package leaves optional, defaulted the first time a
declared-unit lookup needs one — mirroring `add_component!`'s later restamp of `power_units`
to the run's real convention. The default per field matches the literal source-unit label
every reader in this package already passes for that field's dependents: `power_units`
defaults to `"NATURAL_UNITS"` because readers always pass natural-unit labels (`"MW"`, ...)
and `add_component!` restamps it to the run's real convention regardless; `parameter_units`
and `admittance_units` default to `"COMPONENT_BASE"` because the impedance and admittance
columns readers pass are always already per unit (`"pu"`); `energy_units` (which names the
energy unit directly, `"MWH"`/`"MWMIN"`, rather than choosing a natural-vs-per-unit basis)
defaults to `"MWH"` because readers always pass `"MWh"`.
"""
const _DEFAULT_BASIS = Dict{Symbol, String}(
    :power_units => "NATURAL_UNITS",
    :energy_units => "MWH",
    :parameter_units => "COMPONENT_BASE",
    :admittance_units => "COMPONENT_BASE",
)

function _default_bases!(s::Staged{T}) where {T}
    for (name, default) in _DEFAULT_BASIS
        if hasfield(T, name) && !haskey(s.fields, name)
            s.fields[name] = _coerce(_concrete_field_type(T, name), default)
        end
    end
    return
end

"""
Constructor for a compound property, e.g. `MinMax` for `ACBus.voltage_limits`.
"""
_compound_type(::Type{T}, prop::Symbol) where {T} = _concrete_field_type(T, prop)

"""
Whether `T.prop`'s declared unit needs a real instance to resolve.

The generator never emits a type-level `declared_unit`/`declared_quantity` method for a
discriminated property (`Line.r` on `parameter_units`, every power-family field on
`power_units`, ...) — only an instance-level one that reads the sibling discriminator via
`getproperty`. Calling the type-level form for one of these therefore raises `MethodError`,
not the schema's own `error()` call (`ErrorException`, raised by a genuinely fixed
property's instance-level method when an unexpected discriminator value reaches it). Both
mean "needs a shadow" here; PFFP's own `device_base.jl` (`_has_fixed_declared_unit`, unchanged
by this migration) already draws this same distinction for the same reason.
"""
function _declared(s::Staged{T}, prop::Symbol) where {T}
    if !IC.has_declared_unit(T, Val(prop))
        throw(
            IS.DataFormatError(
                "$(nameof(T)).$prop declares no unit; use the 3-argument set_value!",
            ),
        )
    end
    try
        return IC.declared_unit(T, Val(prop)), IC.declared_quantity(T, Val(prop))
    catch e
        (e isa ErrorException || e isa MethodError) || rethrow()
    end
    _default_bases!(s)
    shadow = _shadow(s)
    return IC.declared_unit(shadow, Val(prop)), IC.declared_quantity(shadow, Val(prop))
end

function _reject_declared(s::Staged{T}, prop::Symbol) where {T}
    if IC.has_declared_unit(T, Val(prop))
        unit = declared_unit_label(s, prop)
        throw(
            IS.DataFormatError(
                "$(nameof(T)).$prop declares unit \"$unit\"; use the 4-argument set_value!",
            ),
        )
    end
    return
end

"""Best-effort unit label for an error message: resolves through a shadow instance for a
discriminated property (mirroring `_declared`), falling back to `"?"` only if that also
fails (e.g. a required sibling discriminator has no default and is not yet staged)."""
function declared_unit_label(s::Staged{T}, prop::Symbol) where {T}
    return try
        first(_declared(s, prop))
    catch
        "?"
    end
end

function _convert_by_factor(
    ::Type{T},
    prop::Symbol,
    value::Float64,
    source_unit::AbstractString,
    target::AbstractString,
    quantity::AbstractString,
) where {T}
    if source_unit == target
        return value
    end
    if !IC.has_conversion_factor(quantity, source_unit)
        throw(
            IS.DataFormatError(
                "$(nameof(T)).$prop is $quantity in \"$target\"; " *
                "\"$source_unit\" is not a convertible $quantity unit",
            ),
        )
    end
    if !IC.has_conversion_factor(quantity, target)
        throw(
            IS.DataFormatError(
                "$(nameof(T)).$prop: the unit vocabulary records no conversion factor " *
                "for $quantity in \"$target\"",
            ),
        )
    end
    return value * IC.conversion_factor(quantity, source_unit) /
           IC.conversion_factor(quantity, target)
end

"""Whether the sibling property holding a per-unit value's base has been assigned."""
_base_is_set(s::Staged, base_prop::Symbol) = haskey(s.fields, base_prop)

"""
The assigned base, rejected unless it is positive.

A zero or negative voltage or power base is physically meaningless, and PSS/E writes
`BASKV = 0.0` for buses with no specified base. Dividing by it would store an `Inf` or
`NaN` that survives every later check and first fails inside `JSON.print`, after the
output file has been truncated.
"""
function _checked_base(s::Staged{T}, prop::Symbol, base_prop::Symbol) where {T}
    base = get_value(s, base_prop)
    if base <= 0
        throw(
            IS.DataFormatError(
                "$(nameof(T)).$prop is per-unit on $base_prop, which is $base; " *
                "the base must be positive",
            ),
        )
    end
    return base
end

"""
Convert into a per-unit property whose base lives in a sibling property.

`x-unit-base` names that sibling. The base carries its own declared unit, so the
incoming value is first brought into that unit by the factor path and then divided.
The base must already be staged, which makes staging order significant here and
nowhere else.
"""
function _convert_onto_base(
    s::Staged{T},
    prop::Symbol,
    value::Float64,
    source_unit::AbstractString,
    target::AbstractString,
    quantity::AbstractString,
) where {T}
    base_prop = IC.unit_base(T, Val(prop))
    if !_base_is_set(s, base_prop)
        throw(
            IS.DataFormatError(
                "$(nameof(T)).$prop is $quantity in \"$target\" on $base_prop, which is " *
                "unset; assign $base_prop first",
            ),
        )
    end
    base_unit, base_quantity = _declared(s, base_prop)
    natural = _convert_by_factor(T, prop, value, source_unit, base_unit, base_quantity)
    return natural / _checked_base(s, prop, base_prop)
end

function _convert(
    s::Staged{T},
    prop::Symbol,
    value::Float64,
    source_unit::AbstractString,
    target::AbstractString,
    quantity::AbstractString,
) where {T}
    if source_unit == target
        return value
    end
    if IC.has_unit_base(T, Val(prop))
        return _convert_onto_base(s, prop, value, source_unit, target, quantity)
    end
    return _convert_by_factor(T, prop, value, source_unit, target, quantity)
end

"""Convert `value` from `source_unit` into the unit `prop` declares."""
function convert_to_declared(
    s::Staged{T},
    prop::Symbol,
    value::Real,
    source_unit::AbstractString,
) where {T}
    target, quantity = _declared(s, prop)
    return _convert(s, prop, Float64(value), source_unit, target, quantity)
end

"""Assign a numeric property, converting from `source_unit` to the declared unit."""
function set_value!(
    s::Staged{T},
    prop::Symbol,
    value::Real,
    source_unit::AbstractString,
) where {T}
    converted = convert_to_declared(s, prop, value, source_unit)
    s.fields[prop] = _coerce(_concrete_field_type(T, prop), converted)
    return
end

"""
Assign a compound property such as `MinMax`, `UpDown`, `FromTo` or `InOut`.

The schemas annotate these at the object level rather than per member, so one unit applies to
every field of the tuple.
"""
function set_value!(
    s::Staged{T},
    prop::Symbol,
    value::NamedTuple,
    source_unit::AbstractString,
) where {T}
    target, quantity = _declared(s, prop)
    converted = map(
        v -> _convert(s, prop, Float64(v), source_unit, target, quantity),
        values(value),
    )
    ctor = _compound_type(T, prop)
    s.fields[prop] = ctor(; NamedTuple{keys(value)}(converted)...)
    return
end

"""
Assign a curve-valued property whose declared unit is the unit of the curve's x axis
(`ImpedanceCorrectionData`'s correction curves): every x converts from `source_unit` to the
declared unit, the y axis is a dimensionless multiplier and passes through unchanged.
"""
function set_value!(
    s::Staged{T},
    prop::Symbol,
    value::IC.PiecewiseLinearData,
    source_unit::AbstractString,
) where {T}
    target, quantity = _declared(s, prop)
    points = [
        IC.XYCoords(;
            x = _convert(s, prop, Float64(point.x), source_unit, target, quantity),
            y = point.y,
        ) for point in value.points
    ]
    s.fields[prop] = IC.PiecewiseLinearData(;
        function_type = value.function_type,
        points = points,
    )
    return
end

"""
Reject a unit supplied for something that cannot carry one.

Either the property declares no unit, or the value is neither a number nor a compound tuple.
Both are caller mistakes worth naming precisely rather than surfacing as a MethodError.
"""
function set_value!(
    s::Staged{T},
    prop::Symbol,
    value,
    source_unit::AbstractString,
) where {T}
    _reject_declared(s, prop)
    throw(
        IS.DataFormatError(
            "$(nameof(T)).$prop: a unit applies only to a number or a compound " *
            "tuple, got $(typeof(value))",
        ),
    )
end

"""Assign a property that declares no unit: names, ids, flags, enum strings."""
function set_value!(s::Staged{T}, prop::Symbol, value) where {T}
    _reject_declared(s, prop)
    s.fields[prop] = _coerce(_concrete_field_type(T, prop), value)
    return
end

"""Assign `prop` only when `value` is present; the schemas leave these fields optional and
the pm dict does not always carry one."""
function set_optional_value!(
    s::Staged{T},
    prop::Symbol,
    value,
    source_unit::AbstractString,
) where {T}
    if !isnothing(value)
        set_value!(s, prop, value, source_unit)
    end
    return
end

"""
The plain value inside an enum wrapper (`OperationalStates`, `PrimeMovers`, `UnitSystem`,
...); anything else is returned unchanged.

`get_value` reads through this rather than returning the wrapper: every comparison in this
package and its tests is against the schema's bare string constants (`"ONLINE"`, `"FIXED"`,
...), and an `EnumAPIModel` does not compare equal to the string it wraps. `OneOfAPIModel`
(a oneOf wrapper over concrete struct variants, not a string) is deliberately excluded — a
caller reading one of those wants the concrete variant, not a string.
"""
_unwrap(value::IC.EnumAPIModel) = value.value
_unwrap(value) = value

"""Return the staged value of `prop`."""
get_value(s::Staged, prop::Symbol) = _unwrap(s.fields[prop])

"""Return the stored value of `prop` on an already-materialized component."""
get_value(o::IC.APIModel, prop::Symbol) = _unwrap(getproperty(o, prop))

_declared_read(s::Staged, prop::Symbol) = _declared(s, prop)

_has_unit_base(::Staged{T}, prop::Symbol) where {T} = IC.has_unit_base(T, Val(prop))

_unit_base_of(::Staged{T}, prop::Symbol) where {T} = IC.unit_base(T, Val(prop))

_declared_type(::Staged{T}) where {T} = T

"""Return the value of `prop` expressed in `unit`. Works on a still-staged object (mid-build
reads, e.g. after a sibling field it depends on)."""
function get_value(o, prop::Symbol, unit::AbstractString)
    source, quantity = _declared_read(o, prop)
    value = get_value(o, prop)
    if source == unit
        return value
    end
    if _has_unit_base(o, prop)
        base_prop = _unit_base_of(o, prop)
        if !_base_is_set(o, base_prop)
            throw(
                IS.DataFormatError(
                    "$(nameof(_declared_type(o))).$prop is $quantity in \"$source\" on " *
                    "$base_prop, which is unset; assign $base_prop first",
                ),
            )
        end
        base_unit, base_quantity = _declared_read(o, base_prop)
        return _convert_by_factor(
            _declared_type(o),
            prop,
            value * _checked_base(o, prop, base_prop),
            base_unit,
            unit,
            base_quantity,
        )
    end
    if !IC.has_conversion_factor(quantity, unit) ||
       !IC.has_conversion_factor(quantity, source)
        throw(
            IS.DataFormatError(
                "$(nameof(_declared_type(o))).$prop is $quantity in \"$source\"; " *
                "cannot express in \"$unit\"",
            ),
        )
    end
    return value * IC.conversion_factor(quantity, source) /
           IC.conversion_factor(quantity, unit)
end

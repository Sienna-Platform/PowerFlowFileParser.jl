# Hand-written: the COMPONENT_BASE post-build conversion pass.
#
# Every reader in this directory (load.jl, generation.jl, branch.jl, ...) computes and
# assigns natural-unit values (MW/MVAr/MVA) onto the OpenAPI components it builds,
# regardless of the run's `power_units` — `set_value!` (units.jl) only converts between
# compatible physical units (kW -> MW), never into a per-unit convention. This pass closes
# that gap: when the run is COMPONENT_BASE, it walks every built component afterward and
# divides each power-family field by the component's own device base (or, for a type with
# no device base of its own, the system base) — the exact inverse of what PowerSystems' own
# `NaturalUnit` importer does (`src/openapi/import_handwritten.jl`/`src/models/generated/*.jl` there),
# so that PowerSystems' `ComponentBaseUnit` importer reading this document's numbers directly
# reproduces the same System a `NATURAL_UNITS` document produces through `NaturalUnit`.
#
# ── Field classification, mechanical path ───────────────────────────────────────
#
# A field converts when, mechanically:
#   - it declares a unit (`IC.has_declared_unit`);
#   - that unit is not relative to a sibling field (`!IC.has_unit_base` — e.g.
#     `ACBus.magnitude` is already pu on `base_voltage` regardless of document unit
#     system, so it is untouched here);
#   - its Type-level (not instance-level) `IC.declared_unit`/`IC.declared_quantity`
#     resolve without error (`_has_fixed_declared_unit`) — see the next section for what
#     happens when they do not;
#   - that unit's quantity is power-family (`ActivePower`/`ReactivePower`/`ApparentPower`/
#     `ActivePowerChangeRate` — a generator/storage `ramp_limits` in MW/min is scaled by
#     device base exactly like its MW siblings in every PowerSystems converter checked).
#
# Two cases the mechanical rule cannot see, found by diffing PowerSystems'
# `to_openapi(..., ::ComponentBaseUnit)` against `::NaturalUnit)` field-by-field in
# `export_handwritten.jl`:
#   - `Area`/`LoadZone.peak_active_power`/`peak_reactive_power` (and
#     `TransmissionInterface.active_power_flow_limits`, not reachable from this package's
#     readers today) are schema-fixed-natural: always MW/MVAr, multiplied by the SYSTEM
#     base in BOTH of PowerSystems' export methods — not document-unit-system-governed at
#     all. `_DEVICEBASE_FIXED_NATURAL` lists them explicitly.
#   - A type with no `base_power` field of its own has no anchor to read, so its power
#     fields scale by the document's system base — the same fallback PowerSystems' own
#     reserve/`TwoTerminalGenericHVDCLine` converters use. `_DEVICEBASE_SYSTEM_BASE_TYPES`
#     names them. None is reachable from this package's readers today; they are listed
#     defensively in case a future reader adds them. Types whose `base_power` records the
#     SYSTEM base rather than a device base (`Line`, `FixedAdmittance`,
#     `FACTSControlDevice`, ... — the schema's "in lieu of a system-level table" exception)
#     do NOT belong here: the generic path reads that field and reaches the same number
#     from the document instead of asserting it from a name list.
#
# ── Field classification, instance-dispatched path ──────────────────────────────
#
# A field whose Type-level `declared_unit`/`declared_quantity` throws depends on a runtime
# discriminator sibling (`parameter_units`, `admittance_units`, `energy_units`,
# `voltage_setpoint_units`, `dc_voltage_units`, `setpoint_voltage_units`, ...). That discriminator is
# used for two semantically different things in this schema, and conflating them is a bug:
# a single-bucket "instance-dispatched => skip" rule leaves
# `EnergyReservoirStorage.storage_capacity` unconverted and unflagged.
#
#   1. A **representation switch** between per-unit and natural for the SAME field
#      (`parameter_units`/`admittance_units`/`voltage_setpoint_units`/`dc_voltage_units`
#      choosing between e.g. "pu" and "ohm"/"kV"). Every reader in this package writes a
#      FIXED value for these discriminators, independent of the run's `power_units` —
#      confirmed by grepping every `set_value!(_, :*_units, ...)` call in this directory —
#      so the field's own representation never depends on the run's convention either,
#      and PowerSystems' own converters confirm it is identical between `ComponentBaseUnit`/
#      `NaturalUnit` in every case checked. These are `:skip`.
#   2. A **natural-unit choice** among sibling units of the SAME quantity
#      (`EnergyReservoirStorage.energy_units`: "MWH" vs "MWMIN", both genuine energy units).
#      This is not a pu-vs-natural switch, so it is not exempt from document-level
#      conversion on that basis. PowerSystems' own converter divides `storage_capacity` by
#      device `base_power` exactly like every other `:mva`-tagged field regardless of which
#      (implemented) `energy_units` branch is active (`export_handwritten.jl`'s
#      `EnergyReservoirStorage` section) — these are `:convert_own`.
#
# No field's quantity switches with a modeling enum any more: every such field was split
# into one field per quantity, each with a fixed unit, so the fixed-unit path classifies
# them and no per-component resolution exists.
#
# `_DEVICEBASE_INSTANCE_DISPATCHED` is the explicit registry every instance-dispatched
# `(key, prop)` this package's readers can produce must appear in, classified as one of the
# above. A pair that reaches the registry lookup and is NOT listed is a real gap — a field
# this pass has not been taught to classify — and errors by construction
# (`_devicebase_instance_dispatched`): falling through silently is not possible.

const _DEVICEBASE_POWER_QUANTITIES =
    ("ActivePower", "ReactivePower", "ApparentPower", "ActivePowerChangeRate")

const _DEVICEBASE_FIXED_NATURAL = Set{Tuple{String, Symbol}}([
    ("Area", :peak_active_power),
    ("Area", :peak_reactive_power),
    ("LoadZone", :peak_active_power),
    ("LoadZone", :peak_reactive_power),
    ("TransmissionInterface", :active_power_flow_limits),
])

const _DEVICEBASE_SYSTEM_BASE_TYPES =
    Set(["OnlineReserve", "OfflineReserve", "GroupReserve"])

const _DEVICEBASE_INSTANCE_DISPATCHED = Dict{Tuple{String, Symbol}, Symbol}(
    # parameter_units/admittance_units/voltage_setpoint_units always "COMPONENT_BASE"
    # (branch.jl, shunt.jl) -- pu on the component's own base_power (or, for the shunt
    # admittance fields, COMPONENT_MVAR, see below) already, identical in both document
    # conventions.
    ("TransformerCircuit", :r) => :skip,
    ("TransformerCircuit", :x) => :skip,
    ("Line", :r) => :skip,
    ("Line", :x) => :skip,
    ("Line", :b) => :skip,
    ("Line", :g) => :skip,
    ("ThreeWindingTransformer", :r_12) => :skip,
    ("ThreeWindingTransformer", :x_12) => :skip,
    ("ThreeWindingTransformer", :r_23) => :skip,
    ("ThreeWindingTransformer", :x_23) => :skip,
    ("ThreeWindingTransformer", :r_31) => :skip,
    ("ThreeWindingTransformer", :x_31) => :skip,
    ("TwoWindingTransformer", :magnetizing_shunt) => :skip,
    ("ThreeWindingTransformer", :magnetizing_shunt) => :skip,
    ("FACTSControlDevice", :voltage_setpoint) => :skip,
    # setpoint_voltage_units always "COMPONENT_BASE" (dc_branch.jl): the voltage setpoints
    # are pu of the converter's own rated voltage in both document conventions.
    # `TransformerCircuit`'s five control bands each carry a fixed unit and take the
    # fixed-unit path: the tap, angle and voltage bands are non-power and skip, the MW and
    # MVAr bands convert on the circuit's own base like `active_power_flow`.
    ("TwoTerminalVSCLine", :dc_voltage_setpoint_from) => :skip,
    ("TwoTerminalVSCLine", :dc_voltage_setpoint_to) => :skip,
    ("TwoTerminalVSCLine", :ac_voltage_setpoint_from) => :skip,
    ("TwoTerminalVSCLine", :ac_voltage_setpoint_to) => :skip,
    # admittance_units always "COMPONENT_MVAR" (shunt.jl) -- PowerSystems' own to_openapi
    # confirms this is fixed-natural, multiplied by the SYSTEM base in both document
    # conventions (export_handwritten.jl's FixedAdmittance section), not document-unit-
    # system-governed at all (same shape as Area/LoadZone's peak fields).
    # `FixedAdmittance.Y` is lowercase `y` now (the JSON key stays `Y`).
    ("FixedAdmittance", :y) => :skip,
    ("SwitchedAdmittance", :y_increase) => :skip,
    # BINIT (PowerSystems.jl#1774) is the same COMPONENT_MVAR-on-system-base quantity as `Y`
    # and `Y_increase` above -- PSY's own to_openapi scales it by the SYSTEM base in both
    # document conventions -- so it takes their classification, not a device-base conversion.
    # `solved_admittance` replaced SwitchedAdmittance's old fixed `Y` field entirely, sharing
    # `y_increase`'s admittance_units-discriminated unit, hence the same `:skip`.
    ("SwitchedAdmittance", :solved_admittance) => :skip,
    # parameter_units/dc_voltage_units/admittance_units always "NATURAL_UNITS" for the
    # PSS/E-native LCC/VSC fields (dc_branch.jl) -- fixed ohm/kV/S regardless of the
    # run's power_units, the mirror image of the COMPONENT_BASE cases above.
    ("TwoTerminalLCCLine", :r) => :skip,
    ("TwoTerminalLCCLine", :rectifier_rc) => :skip,
    ("TwoTerminalLCCLine", :rectifier_xc) => :skip,
    ("TwoTerminalLCCLine", :inverter_rc) => :skip,
    ("TwoTerminalLCCLine", :inverter_xc) => :skip,
    ("TwoTerminalLCCLine", :compounding_resistance) => :skip,
    ("TwoTerminalLCCLine", :rectifier_capacitor_reactance) => :skip,
    ("TwoTerminalLCCLine", :inverter_capacitor_reactance) => :skip,
    ("TwoTerminalLCCLine", :scheduled_dc_voltage) => :skip,
    ("TwoTerminalLCCLine", :switch_mode_voltage) => :skip,
    ("TwoTerminalLCCLine", :min_compounding_voltage) => :skip,
    ("TwoTerminalVSCLine", :g) => :skip,
    # energy_units is a NATURAL-UNIT CHOICE (MWh vs MWmin), not a pu-vs-natural
    # representation switch: both branches are genuine energy quantities, and PSY's own
    # converter divides storage_capacity by device base_power regardless of which
    # (implemented) branch is active.
    ("EnergyReservoirStorage", :storage_capacity) => :convert_own,
)

"""Whether `T.prop`'s declared unit is fixed — resolvable from the Type alone, rather than
depending on a runtime discriminator field only the instance-level method reads. A missing
Type-level method (every power-family field: its unit now depends on the component's own
`power_units`) raises `MethodError` rather than the schema's own `ErrorException`; both mean
"not fixed" here."""
function _has_fixed_declared_unit(::Type{T}, prop::Symbol) where {T}
    try
        IC.declared_unit(T, Val(prop))
        return true
    catch e
        (e isa ErrorException || e isa MethodError) || rethrow()
        return false
    end
end

"""
Classification for a `key.prop` whose Type-level declared unit is NOT fixed (an
instance-level discriminator governs it) — `_DEVICEBASE_INSTANCE_DISPATCHED` lookup, erroring
by name when the pair is not registered rather than silently skipping it. See this file's
header for the two kinds of discriminator and why they classify differently.
"""
function _devicebase_instance_dispatched(key::AbstractString, prop::Symbol)
    verdict = get(_DEVICEBASE_INSTANCE_DISPATCHED, (String(key), prop), nothing)
    if verdict === nothing
        error(
            "COMPONENT_BASE conversion: $key.$prop has an instance-level unit discriminator " *
            "not accounted for in _DEVICEBASE_INSTANCE_DISPATCHED — classify it as " *
            ":convert_own or :skip (see device_base.jl's header) before " *
            "building a COMPONENT_BASE document containing this type",
        )
    end
    return verdict
end

"""A copy of `o` with `power_units` set to `power_units` and every other field held
exactly as-is — probes a field's instance dispatch without mutating the real component
(see [`_power_units_only_dispatch`](@ref))."""
function _with_power_units(
    o::T,
    power_units::AbstractString,
) where {T <: IC.APIModel}
    return T(;
        (
            f => (f === :power_units ? IC.UnitSystem(power_units) : getfield(o, f))
            for f in fieldnames(T)
        )...,
    )
end

"""
Whether `prop`'s instance-level dispatch resolves consistently across both of `power_units`'
valid values, `representative`'s own fields (other than `power_units`) held exactly as the
real reader that built it set them.

Every generated component now declares `power_units` a required, enum-validated field (no
`nothing`/`ABSENT` "unset" state), unlike the pre-1.0 runtime, so this can no longer poison
it with an out-of-domain sentinel and read the schema's own error message naming the
deciding field — the technique the previous runtime supported. Resolving successfully
under BOTH valid values is the closest still-available signal: every ordinary power-family
field across the 32 power-bearing types resolves this way today (confirmed against the
current schema, and unaffected by this change — `power_units` staying required only
removes the invalid-sentinel probe, not the underlying dispatch). A field genuinely gated
by another discriminator (`setpoint_voltage_units`, `parameter_units`, ...) instead
must go through the explicit `_DEVICEBASE_INSTANCE_DISPATCHED` registry and its loud error
on a miss, never through this fallback — and since that registry is checked first
(`_devicebase_classification`'s `!haskey(...) && ...`), this function is only ever reached
for a pair already confirmed NOT to need one of those siblings, so a resolution failure
here means a real gap the registry has not been taught about yet, not a false positive.
"""
function _power_units_only_dispatch(representative::T, prop::Symbol) where {T}
    for power_units in ("NATURAL_UNITS", "COMPONENT_BASE")
        variant = _with_power_units(representative, power_units)
        try
            IC.declared_quantity(variant, Val(prop))
        catch e
            e isa ErrorException || rethrow()
            return false
        end
    end
    return true
end

"""
Classify `key.prop` (`representative`: any one instance of `key` — every component of a
given type carries the same run-wide `power_units`, stamped uniformly by
[`add_component!`](@ref)) for the COMPONENT_BASE pass: `:convert_own` (divide by the
component's own `base_power`), `:convert_system` (divide by the document's system base),
or `:skip`. See this file's header for the full rule.
"""
function _devicebase_classification(
    representative::T,
    key::AbstractString,
    prop::Symbol,
) where {T}
    # `base_power`/`base_power_12`/`base_power_23`/`base_power_31`: anchors themselves
    # (`ThreeWindingTransformer`'s three pairwise bases), never scaled by their own value.
    if startswith(string(prop), "base_power")
        return :skip
    end
    if !IC.has_declared_unit(T, Val(prop)) || IC.has_unit_base(T, Val(prop))
        return :skip
    end
    if _has_fixed_declared_unit(T, prop)
        quantity = IC.declared_quantity(T, Val(prop))
    elseif !haskey(_DEVICEBASE_INSTANCE_DISPATCHED, (String(key), prop)) &&
           _power_units_only_dispatch(representative, prop)
        quantity = IC.declared_quantity(representative, Val(prop))
    else
        return _devicebase_instance_dispatched(key, prop)
    end
    if !(quantity in _DEVICEBASE_POWER_QUANTITIES)
        return :skip
    end
    if (String(key), prop) in _DEVICEBASE_FIXED_NATURAL
        return :skip
    end
    if key in _DEVICEBASE_SYSTEM_BASE_TYPES
        return :convert_system
    end
    return :convert_own
end

_devicebase_scale(::Nothing, ::Float64) = nothing
_devicebase_scale(::Absent, ::Float64) = ABSENT
_devicebase_scale(x::Real, base::Float64) = Float64(x) / base

"""A compound field (`MinMax`/`UpDown`/`FromTo`/`FromToToFrom`, ...): every one of these PO
types holds only `Real`/`Nothing`/`Absent` leaves (plus the `additional_properties` every
generated struct carries, held as-is rather than scaled), so scaling every field
generically is exact — mirrors PowerSystems' own per-shape `_minmax_po_scaled`/
`_updown_po_scaled_optional`/... without needing one method per compound type here."""
function _devicebase_scale(x::T, base::Float64) where {T <: IC.APIModel}
    return T(;
        (
            f => (
                if f === :additional_properties
                    getfield(x, f)
                else
                    _devicebase_scale(getfield(x, f), base)
                end
            ) for f in fieldnames(T)
        )...,
    )
end

"""Own device base for `po`, naming `key`/`prop` in the error when the type has neither a
`base_power` field of its own nor a system-base fallback registered in
`_DEVICEBASE_SYSTEM_BASE_TYPES` — the loud path for a field this pass has not been taught
to classify, rather than a silent skip."""
function _devicebase_own_base(po, key::AbstractString, prop::Symbol)
    if !hasfield(typeof(po), :base_power)
        error(
            "COMPONENT_BASE conversion: $key.$prop is a power-family field with no own " *
            "base_power field and $key is not in _DEVICEBASE_SYSTEM_BASE_TYPES",
        )
    end
    return Float64(po.base_power)
end

"""
Every field-level verdict for `T.prop` (`key`'s type), classified once from `representative`
— every component of a given type shares this run's `power_units`, stamped uniformly by
[`add_component!`](@ref), so one classification pass per type is enough.
"""
function _devicebase_classifications(representative::T, key::AbstractString) where {T}
    classifications = Dict{Symbol, Symbol}()
    for prop in fieldnames(T)
        classifications[prop] = _devicebase_classification(representative, key, prop)
    end
    return classifications
end

"""
`po` rebuilt with every `:skip`-classified field held as-is and every convertible field
scaled by its resolved base — components are immutable, so a converted component replaces
rather than mutates the original."""
function _devicebase_rebuild(
    po::T,
    key::AbstractString,
    classifications::Dict{Symbol, Symbol},
    system_base::Float64,
) where {T}
    kwargs = Dict{Symbol, Any}()
    for prop in fieldnames(T)
        classification = classifications[prop]
        if classification === :skip
            kwargs[prop] = getfield(po, prop)
            continue
        end
        base = if classification === :convert_system
            system_base
        else
            _devicebase_own_base(po, key, prop)
        end
        kwargs[prop] = _devicebase_scale(getfield(po, prop), base)
    end
    return T(; kwargs...)
end

"""
    apply_device_base_conversion!(sys::OpenAPISystem)

Convert every power-family field [`build_openapi_system`](@ref)'s readers wrote in natural
units into per-unit-on-device-base, in place, when `sys`'s run is
`power_units = "COMPONENT_BASE"`. A no-op for `"NATURAL_UNITS"`. See this file's header for the
field-classification rule and its exceptions.
"""
function apply_device_base_conversion!(sys::OpenAPISystem)
    if !uses_per_unit(sys)
        return sys
    end
    system_base = get_base_power(sys)
    for key in component_type_names(sys)
        components = get_components(sys, key)
        isempty(components) && continue
        classifications = _devicebase_classifications(first(components), key)
        for (ix, po) in enumerate(components)
            components[ix] = _devicebase_rebuild(po, key, classifications, system_base)
        end
    end
    return sys
end

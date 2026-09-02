# Cost helpers live in cost.jl.
#
# Every power quantity in `data["gen"]`/`data["storage"]` arrives as system per-unit on
# baseMVA (same `_make_per_unit!` correction topology.jl documents). PSCB's own PSY
# objects store generator/storage power fields in *device-base* per-unit (per-unit on the
# component's own `mbase`), converting the raw system-pu value by `base_conversion =
# sys_mbase / mbase` — so `_natural_value` below finishes that conversion by multiplying
# the device-base-pu number PSCB would have stored by the same `mbase`, which is exactly
# what a `get_X(component, PSY.NU)` call on the oracle's real PSY component returns. This
# holds even where PSCB's own arithmetic is a documented bug (the `# Bug-compatible` sites
# below).

"""Table spellings that are not the schema's enum value for a prime mover. Reused from
PowerTableDataParser's `src/openapi/generation.jl`, which already mirrors PSCB's
`STRING2PRIMEMOVER` renames; anything absent here is uppercased and left to the generated
`validate_property` to accept or reject."""
const PRIME_MOVER_ALIASES = Dict(
    "w2" => "WT",
    "wind" => "WT",
    "pv" => "PVe",
    "pve" => "PVe",
    "solar" => "PVe",
    "rtpv" => "PVe",
    "nb" => "ST",
    "steam" => "ST",
    "hydro" => "HY",
    "ror" => "HY",
    "pump" => "PS",
    "pumped_hydro" => "PS",
    "nuclear" => "ST",
    "sync_cond" => "OT",
    "csp" => "CP",
    "un" => "OT",
    "storage" => "BA",
    "ice" => "IC",
)

"""Table spellings that are not the schema's enum value for a thermal fuel. Reused from
PowerTableDataParser's `src/openapi/generation.jl`."""
const THERMAL_FUEL_ALIASES = Dict(
    "ng" => "NATURAL_GAS",
    "gas" => "NATURAL_GAS",
    "nuc" => "NUCLEAR",
    "oil" => "DISTILLATE_FUEL_OIL",
    "dfo" => "DISTILLATE_FUEL_OIL",
    "sync_cond" => "OTHER",
)

function _enum_value(aliases::Dict{String, String}, value::AbstractString)
    key = normalize(value; casefold = true)
    if haskey(aliases, key)
        return aliases[key]
    end
    return uppercase(value)
end

prime_mover_type(unit_type::AbstractString) = _enum_value(PRIME_MOVER_ALIASES, unit_type)
thermal_fuel(fuel::AbstractString) = _enum_value(THERMAL_FUEL_ALIASES, fuel)

"""Convert a device-base per-unit quantity (PSCB's own PSY storage convention) into the
natural unit the schema wants, by multiplying by the component's own base (`mbase` for a
generator, `thermal_rating` for `make_storage!`'s bug-compatible battery)."""
_natural_value(value::Real, base::Float64) = value * base
_natural_value(limits::NamedTuple, base::Float64) = map(v -> v * base, limits)
_natural_value(::Nothing, ::Float64) = nothing

"""
Default component name from a pm dict entry. Ported verbatim from PSCB's
`_get_pm_dict_name`; the `"shunt_bus"` branch serves shunt.jl's readers, which share it.
"""
function _get_pm_dict_name(d::Dict)::String
    if haskey(d, "shunt_bus")
        return join(strip.(string.((d["shunt_bus"], d["name"]))), "-")
    elseif haskey(d, "name")
        return string(d["name"])
    elseif haskey(d, "source_id")
        return strip(join(string.(d["source_id"]), "-"))
    end
    return string(d["index"])
end

"""The generator's own base power (`"mbase"`), substituting the system base for a
generator that states zero — PSCB warns and does the same rather than dividing by zero
downstream."""
function _device_base_power(pm_gen::Dict, gen_name::AbstractString, sys_mbase::Float64)
    mbase = pm_gen["mbase"]
    if iszero(mbase)
        @warn "Generator $gen_name has base power equal to zero: $mbase. Changing it to system base: $sys_mbase"
        return sys_mbase
    end
    return mbase
end

"""
Apparent power rating from active/reactive maxima, scaled onto the device base.

Ported from PSCB's `common.jl` `calculate_gen_rating` (the 3-argument, `base_conversion`
form `power_models_data.jl` actually calls — the 2-argument `MinMax` overload in the same
file is only used by PSCB's table-data path, out of this reader's scope). A zero rating
returns bare `1.0`, *not* `1.0 * base_conversion* — PSCB's own comment reads "1.0 in the
p.u. of the device", i.e. this fallback is itself already device-base per-unit.
"""
function calculate_gen_rating(
    active_power_max::Real,
    reactive_power_max::Real,
    base_conversion::Float64,
)
    rating = sqrt(Float64(active_power_max)^2 + Float64(reactive_power_max)^2)
    if iszero(rating)
        @warn "Rating calculation returned 0.0. Changing to 1.0 in the p.u. of the device."
        return 1.0
    end
    return rating * base_conversion
end

"""
Ramp limits from whichever of `"ramp_agc"`/`"ramp_10"`/`"ramp_30"` is present, falling
back to `abs(pmax)`, or `nothing` if `pmax` is also zero.

Ported verbatim from PSCB's `calculate_ramp_limit`, including its own inconsistency: both
branches use the source value exactly as pm states it (no `base_conversion`), unlike every
other `calculate_*`/`make_*` field in this file.
"""
function calculate_ramp_limit(d::Dict, gen_name::AbstractString)
    if haskey(d, "ramp_agc")
        return (up = d["ramp_agc"], down = d["ramp_agc"])
    end
    if haskey(d, "ramp_10")
        return (up = d["ramp_10"], down = d["ramp_10"])
    end
    if haskey(d, "ramp_30")
        return (up = d["ramp_30"], down = d["ramp_30"])
    end
    if abs(d["pmax"]) > 0.0
        return (up = abs(d["pmax"]), down = abs(d["pmax"]))
    end
    @warn "Not enough information to determine ramp limit for generator $gen_name. Returning nothing"
    return nothing
end

"""
Warn about generator shapes that look like a PSS/E motor load modeled as a negative-power
generator. Ported verbatim from PSCB's `_is_likely_motor_load`: diagnostic only, no data
effect.
"""
function _is_likely_motor_load(d::Dict, gen_name::AbstractString)
    if d["pmin"] < 0 && d["pmax"] < 0 && d["pg"] < 0
        @warn "Generator $gen_name is likely a motor load with negative active power: $(d["pg"]) and negative power limits: (min = $(d["pmin"]), max = $(d["pmax"])) this component will be parsed as a thermal generator with negative active power limits. You can convert the device to a MotorLoad for more accurate modeling."
    end
    if iszero(d["pmin"]) && iszero(d["pmax"]) && d["pg"] < 0
        @warn "Generator $gen_name is likely a motor load with negative active power: $(d["pg"]) and undefined active power limits this component will be parsed as a thermal generator with negative active power injection. You can convert the device to a MotorLoad for more accurate modeling."
    end
    if d["pmin"] < 0 && iszero(d["pmax"])
        @warn "Generator $gen_name is likely something that is not a ThermalGenerators with negative power limits: (min = $(d["pmin"]), max = $(d["pmax"])) this component will be parsed as a thermal generator with negative active power limits. Check this entry for more accurate modeling."
    end
    return
end

"""Copy a generator's PSS/E `ext` blob, folding in the source-impedance fields PSCB
stashes there under `"r"`/`"x"`/`"rt"`/`"xt"` when present. Ported from the `ext`-merging
block shared by PSCB's `make_thermal_gen` and `make_synchronous_condenser`."""
function _generator_ext(pm_gen::Dict)
    extras = copy(get(pm_gen, "ext", Dict{String, Any}()))
    if haskey(pm_gen, "r_source") && haskey(pm_gen, "x_source")
        extras["r"] = pm_gen["r_source"]
        extras["x"] = pm_gen["x_source"]
    end
    if haskey(pm_gen, "rt_source") && haskey(pm_gen, "xt_source")
        extras["rt"] = pm_gen["rt_source"]
        extras["xt"] = pm_gen["xt_source"]
    end
    return extras
end

"""Device base, base conversion factor, and the active/reactive power limits, rating, and
ramp limits every per-unit generator maker derives from them — shared by
`make_thermal_generator!` and `_make_hydro_dispatch_body!`, which compute this set
identically."""
function _gen_base_and_limits(pm_gen::Dict, gen_name::AbstractString, sys_mbase::Float64)
    mbase = _device_base_power(pm_gen, gen_name, sys_mbase)
    base_conversion = sys_mbase / mbase
    active_power_limits =
        (min = pm_gen["pmin"] * base_conversion, max = pm_gen["pmax"] * base_conversion)
    reactive_power_limits =
        (min = pm_gen["qmin"] * base_conversion, max = pm_gen["qmax"] * base_conversion)
    rating = calculate_gen_rating(pm_gen["pmax"], pm_gen["qmax"], base_conversion)
    ramp_limits = calculate_ramp_limit(pm_gen, gen_name)
    return mbase, base_conversion, active_power_limits, reactive_power_limits, rating,
    ramp_limits
end

"""Thermal `:status` enum from a pm dict's `"gen_status"` flag: zero is `"OFFLINE"`,
nonzero is `"ONLINE"`. `Bool <: Integer`, so this one method also covers PSS/E's
`_determine_injector_status`, which sometimes stores a `Bool` rather than Matpower's `Int`
column (the previous `Bool(...)` coercion this replaces)."""
function _thermal_status(gen_name::AbstractString, gen_status::Integer)
    if iszero(gen_status)
        return "OFFLINE"
    else
        return "ONLINE"
    end
end

function _thermal_status(gen_name::AbstractString, gen_status)
    throw(
        IS.DataFormatError(
            "generator $gen_name has non-integer gen_status: $gen_status",
        ),
    )
end

"""Thermal generator; the cost branch lives in `make_thermal_cost` (cost.jl)."""
function make_thermal_generator!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    bus_id::Int,
    pm_gen::Dict,
    gen_name::AbstractString,
    sys_mbase::Float64,
)
    mbase, base_conversion, active_power_limits, reactive_power_limits, rating,
    ramp_limits = _gen_base_and_limits(pm_gen, gen_name, sys_mbase)
    _is_likely_motor_load(pm_gen, gen_name)
    extras = _generator_ext(pm_gen)

    component = PO.ThermalStandard()
    set_value!(component, :id, register!(reg, "ThermalStandard", gen_name))
    set_value!(component, :name, gen_name)
    set_value!(component, :available, Bool(pm_gen["gen_status"]))
    set_value!(component, :status, _thermal_status(gen_name, pm_gen["gen_status"]))
    set_value!(component, :bus, bus_id)
    set_value!(component, :active_power,
        _natural_value(pm_gen["pg"] * base_conversion, mbase),
        "MW")
    set_value!(component, :reactive_power,
        _natural_value(pm_gen["qg"] * base_conversion, mbase), "MVAr")
    set_value!(component, :rating, _natural_value(rating, mbase), "MVA")
    set_value!(component, :active_power_limits, _natural_value(active_power_limits, mbase),
        "MW")
    set_value!(component, :reactive_power_limits,
        _natural_value(reactive_power_limits, mbase), "MVAr")
    set_optional_value!(component, :ramp_limits, _natural_value(ramp_limits, mbase),
        "MW/min")
    set_value!(component, :operation_cost, make_thermal_cost(gen_name, pm_gen, sys_mbase))
    set_value!(component, :base_power, mbase, "MVA")
    set_value!(component, :prime_mover_type, prime_mover_type(get(pm_gen, "type", "OT")))
    set_value!(component, :fuel, thermal_fuel(get(pm_gen, "fuel", "OTHER")))
    add_component!(sys, component)
    set_component_ext!(sys, component, extras)
    return
end

"""
Shared body of PSCB's `make_hydro_dispatch` and `make_hydro_reservoir` — both produce a
`HydroDispatch`. PSCB's two functions are, in fact, identical (its own copy-paste, not a
divergence this port introduces); shared here instead of duplicated.
"""
function _make_hydro_dispatch_body!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    bus_id::Int,
    pm_gen::Dict,
    gen_name::AbstractString,
    sys_mbase::Float64,
)
    mbase, base_conversion, active_power_limits, reactive_power_limits, rating,
    ramp_limits = _gen_base_and_limits(pm_gen, gen_name, sys_mbase)

    component = PO.HydroDispatch()
    set_value!(component, :id, register!(reg, "HydroDispatch", gen_name))
    set_value!(component, :name, gen_name)
    set_value!(component, :available, Bool(pm_gen["gen_status"]))
    set_value!(component, :bus, bus_id)
    set_value!(component, :active_power,
        _natural_value(pm_gen["pg"] * base_conversion, mbase),
        "MW")
    set_value!(component, :reactive_power,
        _natural_value(pm_gen["qg"] * base_conversion, mbase), "MVAr")
    set_value!(component, :rating, _natural_value(rating, mbase), "MVA")
    set_value!(component, :prime_mover_type, prime_mover_type(get(pm_gen, "type", "OT")))
    set_value!(component, :active_power_limits, _natural_value(active_power_limits, mbase),
        "MW")
    set_value!(component, :reactive_power_limits,
        _natural_value(reactive_power_limits, mbase), "MVAr")
    set_optional_value!(component, :ramp_limits, _natural_value(ramp_limits, mbase),
        "MW/min")
    set_value!(component, :operation_cost, make_hydro_cost())
    set_value!(component, :base_power, mbase, "MVA")
    add_component!(sys, component)
    return
end

"""Hydro generator without a reservoir (`fuel: HYDRO, type: ROR`). Ported from PSCB's
`make_hydro_dispatch`."""
make_hydro_dispatch!(sys::OpenAPISystem, reg::IdRegistry, bus_id::Int, pm_gen::Dict,
    gen_name::AbstractString, sys_mbase::Float64) =
    _make_hydro_dispatch_body!(sys, reg, bus_id, pm_gen, gen_name, sys_mbase)

"""
Hydro generator with a reservoir (`fuel: HYDRO, type: HYDRO`/`type: null`), mapped to the
`HydroTurbine` generator class by `generator_mapping_pm.yaml`.

# Bug-compatible with PSCB — PowerModels carries no storage
parameters for a generator ("No way to define storage parameters for gens in PM", PSCB's
own comment), so `make_hydro_reservoir` there produces a plain `HydroDispatch`, silently
dropping the reservoir, instead of a `HydroTurbine`/`HydroReservoir` pair. Fix tracked
upstream; not fixed here.
"""
make_hydro_reservoir!(sys::OpenAPISystem, reg::IdRegistry, bus_id::Int, pm_gen::Dict,
    gen_name::AbstractString, sys_mbase::Float64) =
    _make_hydro_dispatch_body!(sys, reg, bus_id, pm_gen, gen_name, sys_mbase)

"""
Curtailable renewable generator.

# Bug-compatible with PSCB — `calculate_gen_rating` already
multiplies by `base_conversion`; PSCB's `RenewableDispatch(...)` call then multiplies its
own already-converted `rating` local by `base_conversion` a second time, so the stored
device-base-pu rating carries `base_conversion^2`. Fix tracked upstream; not fixed here.
"""
function make_renewable_dispatch!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    bus_id::Int,
    pm_gen::Dict,
    gen_name::AbstractString,
    sys_mbase::Float64,
)
    mbase = _device_base_power(pm_gen, gen_name, sys_mbase)
    base_conversion = sys_mbase / mbase

    reactive_power_limits =
        (min = pm_gen["qmin"] * base_conversion, max = pm_gen["qmax"] * base_conversion)

    rating = calculate_gen_rating(pm_gen["pmax"], pm_gen["qmax"], base_conversion)
    if rating > mbase
        @warn "rating is larger than base power for $gen_name, setting to $mbase"
        rating = mbase
    end
    # Bug-compatible with PSCB — `rating` above is already
    # device-base per-unit (calculate_gen_rating applied `base_conversion` once); this
    # second multiply is the double-application the docstring names.
    rating = rating * base_conversion

    component = PO.RenewableDispatch()
    set_value!(component, :id, register!(reg, "RenewableDispatch", gen_name))
    set_value!(component, :name, gen_name)
    set_value!(component, :available, Bool(pm_gen["gen_status"]))
    set_value!(component, :bus, bus_id)
    set_value!(component, :active_power,
        _natural_value(pm_gen["pg"] * base_conversion, mbase),
        "MW")
    set_value!(component, :reactive_power,
        _natural_value(pm_gen["qg"] * base_conversion, mbase), "MVAr")
    set_value!(component, :rating, _natural_value(rating, mbase), "MVA")
    set_value!(component, :prime_mover_type, prime_mover_type(get(pm_gen, "type", "OT")))
    set_value!(component, :reactive_power_limits,
        _natural_value(reactive_power_limits, mbase), "MVAr")
    set_value!(component, :power_factor, 1.0, "1")
    set_value!(component, :operation_cost, make_renewable_cost())
    set_value!(component, :base_power, mbase, "MVA")
    add_component!(sys, component)
    return
end

"""Non-curtailable renewable generator. Unlike every other rating in this file, this one
is `pmax` alone, not `calculate_gen_rating`."""
function make_renewable_nondispatch!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    bus_id::Int,
    pm_gen::Dict,
    gen_name::AbstractString,
    sys_mbase::Float64,
)
    mbase = _device_base_power(pm_gen, gen_name, sys_mbase)
    base_conversion = sys_mbase / mbase

    component = PO.RenewableNonDispatch()
    set_value!(component, :id, register!(reg, "RenewableNonDispatch", gen_name))
    set_value!(component, :name, gen_name)
    set_value!(component, :available, Bool(pm_gen["gen_status"]))
    set_value!(component, :bus, bus_id)
    set_value!(component, :active_power,
        _natural_value(pm_gen["pg"] * base_conversion, mbase),
        "MW")
    set_value!(component, :reactive_power,
        _natural_value(pm_gen["qg"] * base_conversion, mbase), "MVAr")
    set_value!(component, :rating,
        _natural_value(Float64(pm_gen["pmax"]) * base_conversion, mbase), "MVA")
    set_value!(component, :prime_mover_type, prime_mover_type(get(pm_gen, "type", "OT")))
    set_value!(component, :power_factor, 1.0, "1")
    set_value!(component, :base_power, mbase, "MVA")
    add_component!(sys, component)
    return
end

"""Synchronous condenser."""
function make_synchronous_condenser!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    bus_id::Int,
    pm_gen::Dict,
    gen_name::AbstractString,
    sys_mbase::Float64,
)
    mbase = _device_base_power(pm_gen, gen_name, sys_mbase)
    base_conversion = sys_mbase / mbase
    reactive_power_limits =
        (min = pm_gen["qmin"] * base_conversion, max = pm_gen["qmax"] * base_conversion)
    # qmax and qmin can both be negative, hence max(abs(.), abs(.)) rather than qmax alone.
    rating = max(abs(pm_gen["qmax"]), abs(pm_gen["qmin"])) * base_conversion
    extras = _generator_ext(pm_gen)

    component = PO.SynchronousCondenser()
    set_value!(component, :id, register!(reg, "SynchronousCondenser", gen_name))
    set_value!(component, :name, gen_name)
    set_value!(component, :available, Bool(pm_gen["gen_status"]))
    set_value!(component, :bus, bus_id)
    set_value!(component, :reactive_power,
        _natural_value(pm_gen["qg"] * base_conversion, mbase), "MVAr")
    set_value!(component, :rating, _natural_value(rating, mbase), "MVA")
    set_value!(component, :reactive_power_limits,
        _natural_value(reactive_power_limits, mbase), "MVAr")
    set_value!(component, :base_power, mbase, "MVA")
    add_component!(sys, component)
    set_component_ext!(sys, component, extras)
    return
end

"""
Generic battery storage from a `data["storage"]` entry.

# Bug-compatible with PSCB — `rating` and `base_power` are
both assigned the raw `"thermal_rating"` value, itself PowerModels system per-unit and
never converted. Every other field in this file uses the component's own base to reach
natural units; here that base *is* the same unconverted `thermal_rating` value, so
`rating` in particular ends up scaled by `thermal_rating` against itself. Fix tracked
upstream; not fixed here.
"""
function make_storage!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    bus_id::Int,
    d::Dict,
    storage_name::AbstractString,
    sys_mbase::Float64,
)
    energy_rating = iszero(d["energy_rating"]) ? d["energy"] : d["energy_rating"]
    # Bug-compatible: PSCB's own `base_power` for a battery is this raw, unconverted
    # per-unit value, not a true MVA base — see docstring.
    thermal_rating = Float64(d["thermal_rating"])

    component = PO.EnergyReservoirStorage()
    set_value!(component, :id, register!(reg, "EnergyReservoirStorage", storage_name))
    set_value!(component, :name, storage_name)
    set_value!(component, :available, Bool(d["status"]))
    set_value!(component, :bus, bus_id)
    set_value!(component, :prime_mover_type, "BA")
    set_value!(component, :storage_technology_type, "OTHER_CHEM")
    set_value!(component, :storage_capacity, _natural_value(energy_rating, thermal_rating),
        "MWh")
    set_value!(
        component,
        :storage_level_limits,
        IC.MinMax(; min = 0.0, max = _natural_value(energy_rating, thermal_rating)),
    )
    set_value!(component, :initial_storage_capacity_level, d["energy"] / energy_rating, "1")
    set_value!(component, :rating, _natural_value(thermal_rating, thermal_rating), "MVA")
    set_value!(component, :active_power, _natural_value(d["ps"], thermal_rating), "MW")
    set_value!(
        component,
        :input_active_power_limits,
        _natural_value((min = 0.0, max = d["charge_rating"]), thermal_rating),
        "MW",
    )
    set_value!(
        component,
        :output_active_power_limits,
        _natural_value((min = 0.0, max = d["discharge_rating"]), thermal_rating),
        "MW",
    )
    set_value!(
        component,
        :efficiency,
        IC.InOut(; in = d["charge_efficiency"], out = d["discharge_efficiency"]),
    )
    set_value!(component, :reactive_power, _natural_value(d["qs"], thermal_rating), "MVAr")
    set_value!(
        component,
        :reactive_power_limits,
        _natural_value((min = d["qmin"], max = d["qmax"]), thermal_rating),
        "MVAr",
    )
    set_value!(component, :base_power, thermal_rating, "MVA")
    set_value!(component, :operation_cost, PC.StorageCost(; start_up = 0.0))
    add_component!(sys, component)
    return
end

"""
`type name => (fuel, unit_type)` generator classification, source data for
[`GENERATOR_MAPPING_PM`](@ref). A `nothing` unit type matches any unit type for that fuel.
"""
const GENERATOR_MAPPING_ENTRIES_PM = (
    "HydroTurbine" => (("HYDRO", nothing), ("HYDRO", "HYDRO")),
    "HydroDispatch" => (("HYDRO", "ROR"),),
    "RenewableDispatch" => (
        ("SOLAR", "PV"),
        ("SOLAR", "UN"),
        ("WIND", "WIND"),
        ("WIND", nothing),
        ("SOLAR", "CSP"),  # TODO: may need a new struct
    ),
    "RenewableNonDispatch" => (("SOLAR", "RTPV"),),
    "ThermalStandard" => (
        ("OIL", nothing),
        ("COAL", nothing),
        ("NG", nothing),
        ("GAS", nothing),
        ("NUCLEAR", nothing),
        ("NUC", nothing),
        ("OTHER", "OT"),
    ),
    "SynchronousCondenser" => (("SYNC_COND", "SYNC_COND"),),
    "EnergyReservoirStorage" => (("STORAGE", nothing),),
)

"""Index [`GENERATOR_MAPPING_ENTRIES_PM`](@ref) by `(fuel, unit_type)`. Resolves to the
mapped type's bare `String` name (dispatch is on `Val(Symbol(name))` below) rather than a
`PowerSystems` `DataType`, since this reader has no PSY dependency to resolve one
against."""
function _index_generator_mapping(table)
    mappings = Dict{NamedTuple, String}()
    for (type_name, entries) in table
        for (fuel, unit_type) in entries
            key = (fuel = fuel, unit_type = unit_type)
            if haskey(mappings, key)
                throw(
                    IS.DataFormatError(
                        "duplicate generator mapping: $type_name $fuel $unit_type",
                    ),
                )
            end
            mappings[key] = type_name
        end
    end
    return mappings
end

"""`(fuel, unit_type) => generator class name`, the lookup [`get_generator_type`](@ref)
resolves against."""
const GENERATOR_MAPPING_PM = _index_generator_mapping(GENERATOR_MAPPING_ENTRIES_PM)

"""
Mapped component type name for a fuel and unit type. Ported from PSCB's
`get_generator_type`: falls back through `(unit_type, nothing) x (fuel, nothing)`, which
is what lets a thermal entry's `type: null` mapping match any unit type for that fuel.
"""
function get_generator_type(
    fuel::AbstractString,
    unit_type::AbstractString,
    mappings::Dict{NamedTuple, String},
)
    normalized_fuel = uppercase(fuel)
    normalized_unit_type = uppercase(unit_type)
    for ut in (normalized_unit_type, nothing), fu in (normalized_fuel, nothing)
        key = (fuel = fu, unit_type = ut)
        if haskey(mappings, key)
            return mappings[key]
        end
    end
    throw(IS.DataFormatError("no generator mapping for fuel=$fuel unit_type=$unit_type"))
end

function _make_generator!(::Val{T}, sys, reg, bus_id, pm_gen, gen_name, sys_mbase) where {T}
    throw(
        IS.DataFormatError(
            "no OpenAPI mapping for generator type $T (name=$gen_name)",
        ),
    )
end

_make_generator!(::Val{:ThermalStandard}, sys, reg, bus_id, pm_gen, gen_name, sys_mbase) =
    make_thermal_generator!(sys, reg, bus_id, pm_gen, gen_name, sys_mbase)
_make_generator!(::Val{:HydroDispatch}, sys, reg, bus_id, pm_gen, gen_name, sys_mbase) =
    make_hydro_dispatch!(sys, reg, bus_id, pm_gen, gen_name, sys_mbase)
_make_generator!(::Val{:HydroTurbine}, sys, reg, bus_id, pm_gen, gen_name, sys_mbase) =
    make_hydro_reservoir!(sys, reg, bus_id, pm_gen, gen_name, sys_mbase)
_make_generator!(::Val{:RenewableDispatch}, sys, reg, bus_id, pm_gen, gen_name, sys_mbase) =
    make_renewable_dispatch!(sys, reg, bus_id, pm_gen, gen_name, sys_mbase)
_make_generator!(
    ::Val{:RenewableNonDispatch},
    sys,
    reg,
    bus_id,
    pm_gen,
    gen_name,
    sys_mbase,
) = make_renewable_nondispatch!(sys, reg, bus_id, pm_gen, gen_name, sys_mbase)
_make_generator!(
    ::Val{:SynchronousCondenser},
    sys,
    reg,
    bus_id,
    pm_gen,
    gen_name,
    sys_mbase,
) = make_synchronous_condenser!(sys, reg, bus_id, pm_gen, gen_name, sys_mbase)

"""
A generator resolving to `EnergyReservoirStorage` from the pm dict's `"gen"` section is a
data shape PSCB itself calls out as wrong (`@warn "EnergyReservoirStorage should be
defined as a PowerModels storage... Skipping"`), since PowerModels models storage
separately in `"storage"`. PSCB skips it silently; this reader errors instead, per its
own no-silent-skip policy — not one of the three named bug-compatible sites.
"""
function _make_generator!(
    ::Val{:EnergyReservoirStorage},
    sys,
    reg,
    bus_id,
    pm_gen,
    gen_name,
    sys_mbase,
)
    throw(
        IS.DataFormatError(
            "generator $gen_name resolves to EnergyReservoirStorage from the pm dict's " *
            "\"gen\" section; storage entries belong in the \"storage\" section",
        ),
    )
end

"""
Create one generator per `data["gen"]` entry and one storage device per
`data["storage"]` entry.

Ported from PSCB's `read_gen!` and `read_storage!`, run together since both populate
injector components. `data["gen"]` must exist (mirrors `read_loads!`'s stance on
`data["load"]`); `data["storage"]` is genuinely optional — plain Matpower cases never
carry one — so its absence is not an error.
"""
function read_generation!(sys::OpenAPISystem, data::Dict; kwargs...)
    if !haskey(data, "gen")
        throw(IS.DataFormatError("pm_data has no generators"))
    end
    reg = get_registry(sys)
    sys_mbase = get_base_power(sys)
    _get_name = get(kwargs, :gen_name_formatter, _get_pm_dict_name)

    for (_, pm_gen) in _sorted_pm_entries(data["gen"])
        gen_name = String(_get_name(pm_gen))
        bus_id = get_bus_id(reg, Int(pm_gen["gen_bus"]))
        fuel = get(pm_gen, "fuel", "OTHER")
        unit_type = get(pm_gen, "type", "OT")
        type_name = get_generator_type(fuel, unit_type, GENERATOR_MAPPING_PM)
        _make_generator!(Val(Symbol(type_name)), sys, reg, bus_id, pm_gen, gen_name,
            sys_mbase)
    end

    for (_, pm_storage) in _sorted_pm_entries(get(data, "storage", Dict{String, Any}()))
        storage_name = String(_get_name(pm_storage))
        bus_id = get_bus_id(reg, Int(pm_storage["storage_bus"]))
        make_storage!(sys, reg, bus_id, pm_storage, storage_name, sys_mbase)
    end
    return
end

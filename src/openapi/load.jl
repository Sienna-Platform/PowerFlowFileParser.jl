# Cost helpers live in cost.jl.
#
# Every power quantity in `data["load"]` (and `data["distributed_generation"]`) arrives as
# system per-unit on baseMVA, the same `_make_per_unit!` correction topology.jl's header
# documents. Every MW/MVAr field this file writes is `raw_pu * base_power` before
# `set_value!` — mirroring topology.jl's `_zone_peak_loads`, not a PSCB peculiarity.
#
# `make_interruptible_powerload` (PSCB) is not ported: `read_loads!`'s own
# if/elseif/else never calls it, so it is unreachable dead code in the oracle.

"""
Numeric value of a pm dict section's own key, for deterministic iteration order.

PowerModels dict keys are `Int` for a Matpower-sourced case but `String` for a PSS/E-
sourced one, so normalizing to `Int` keeps `sort` order the same regardless of source.
"""
_pm_key_int(key::Integer) = Int(key)
_pm_key_int(key::AbstractString) = parse(Int, key)

"""Sort a pm dict section's `(key, value)` pairs by [`_pm_key_int`](@ref)."""
_sorted_pm_entries(dict::AbstractDict) =
    sort(collect(dict); by = pair -> _pm_key_int(first(pair)))

"""PSCB's `LoadConformity` scoped enum values: `NON_CONFORMING = 0`, `CONFORMING = 1`,
`UNDEFINED = 2`. Both pm_io parsers (PSS/E's `SCALE`, Matpower's own default-to-1) always
populate `"conformity"`, so an unrecognized code is a data error, not a gap to default
through."""
function _conformity_string(code::Integer)
    if code == 0
        return "NON_CONFORMING"
    elseif code == 1
        return "CONFORMING"
    elseif code == 2
        return "UNDEFINED"
    end
    throw(IS.DataFormatError("unsupported load conformity code=$code; expected 0, 1, or 2"))
end

"""Assign the ZIP-load fields `StandardLoad` and `InterruptibleStandardLoad` share."""
function _set_zip_fields!(component, d::Dict, base_power::Float64)
    set_value!(component, :constant_active_power, d["pd"] * base_power, "MW")
    set_value!(component, :constant_reactive_power, d["qd"] * base_power, "MVAr")
    set_value!(component, :current_active_power, d["pi"] * base_power, "MW")
    set_value!(component, :current_reactive_power, d["qi"] * base_power, "MVAr")
    set_value!(component, :impedance_active_power, d["py"] * base_power, "MW")
    set_value!(component, :impedance_reactive_power, d["qy"] * base_power, "MVAr")
    set_value!(component, :max_constant_active_power, d["pd"] * base_power, "MW")
    set_value!(component, :max_constant_reactive_power, d["qd"] * base_power, "MVAr")
    set_value!(component, :max_current_active_power, d["pi"] * base_power, "MW")
    set_value!(component, :max_current_reactive_power, d["qi"] * base_power, "MVAr")
    set_value!(component, :max_impedance_active_power, d["py"] * base_power, "MW")
    set_value!(component, :max_impedance_reactive_power, d["qy"] * base_power, "MVAr")
    return
end

"""Id, name, availability, bus, and base power — the identity fields every load maker
below sets identically, before its own type-specific fields."""
function _set_load_identity!(
    load,
    reg::IdRegistry,
    type_name::AbstractString,
    name::AbstractString,
    bus_id::Int,
    status,
    base_power::Float64,
)
    set_value!(load, :id, register!(reg, type_name, name))
    set_value!(load, :name, name)
    set_value!(load, :available, Bool(status))
    set_value!(load, :bus, bus_id)
    set_value!(load, :base_power, base_power, "MVA")
    return
end

function _make_standard_load!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    bus_id::Int,
    d::Dict,
    name::AbstractString,
    base_power::Float64,
)
    load = stage(PO.StandardLoad)
    _set_load_identity!(load, reg, "StandardLoad", name, bus_id, d["status"], base_power)
    set_value!(load, :conformity, _conformity_string(Int(d["conformity"])))
    _set_zip_fields!(load, d, base_power)
    add_component!(sys, load)
    return
end

function _make_interruptible_standardload!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    bus_id::Int,
    d::Dict,
    name::AbstractString,
    base_power::Float64,
)
    load = stage(PO.InterruptibleStandardLoad)
    _set_load_identity!(load, reg, "InterruptibleStandardLoad", name, bus_id, d["status"],
        base_power)
    set_value!(load, :operation_cost, make_load_cost())
    set_value!(load, :conformity, _conformity_string(Int(d["conformity"])))
    _set_zip_fields!(load, d, base_power)
    add_component!(sys, load)
    return
end

function _make_power_load!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    bus_id::Int,
    d::Dict,
    name::AbstractString,
    base_power::Float64,
)
    load = stage(PO.PowerLoad)
    _set_load_identity!(load, reg, "PowerLoad", name, bus_id, d["status"], base_power)
    set_value!(load, :active_power, d["pd"] * base_power, "MW")
    set_value!(load, :reactive_power, d["qd"] * base_power, "MVAr")
    set_value!(load, :max_active_power, d["pd"] * base_power, "MW")
    set_value!(load, :max_reactive_power, d["qd"] * base_power, "MVAr")
    set_value!(load, :conformity, _conformity_string(Int(d["conformity"])))
    add_component!(sys, load)
    return
end

"""
A `RenewableNonDispatch` for a load's paired distributed-generation entry.

Ported from PSCB's dgen block inside `read_loads!`: the injector mirrors the upstream
distributed-generation contract, which reports net P/Q with a unity-power-factor
placeholder rather than a true rating.
"""
function _make_dgen_renewable!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    bus_id::Int,
    dgen::Dict,
    load_name::AbstractString,
    base_power::Float64,
)
    name = string(load_name, "_dgen")
    active_power = dgen["pg"] * base_power
    reactive_power = dgen["qg"] * base_power
    component = stage(PO.RenewableNonDispatch)
    set_value!(component, :id, register!(reg, "RenewableNonDispatch", name))
    set_value!(component, :name, name)
    set_value!(component, :available, Bool(dgen["status"]))
    set_value!(component, :bus, bus_id)
    # prime_mover_type is a required enum field `_shadow` can't placeholder (see `stage`'s
    # docstring); stage it before active_power below.
    set_value!(component, :prime_mover_type, "OT")
    set_value!(component, :active_power, active_power, "MW")
    set_value!(component, :reactive_power, reactive_power, "MVAr")
    set_value!(component, :rating, hypot(dgen["pg"], dgen["qg"]) * base_power, "MVA")
    set_value!(component, :power_factor, 1.0, "1")
    set_value!(component, :base_power, base_power, "MVA")
    add_component!(sys, component)
    return
end

"""
Create one load per `data["load"]` entry, plus a `RenewableNonDispatch` for every load
whose `source_id` matches a `data["distributed_generation"]` entry. The three-way type choice mirrors PSCB exactly: PSS/E
loads (`source_type == "pti"`) split on their `"interruptible"` flag between
`StandardLoad` and `InterruptibleStandardLoad`; every other source falls through to
`PowerLoad`.

Departs from PSCB in one place: a distributed-generation entry that matches no load is an
`error`, not PSCB's `@warn`-and-skip — this reader's no-silent-skip policy.
"""
function read_loads!(sys::OpenAPISystem, data::Dict; kwargs...)
    reg = get_registry(sys)
    base_power = get_base_power(sys)
    is_pti = data["source_type"] == "pti"
    _get_name = get(kwargs, :load_name_formatter, d -> strip(join(d["source_id"])))

    dgen_lookup = Dict{Tuple{Int, String}, Dict}()
    for dgen in values(get(data, "distributed_generation", Dict{String, Any}()))
        dgen_lookup[(Int(dgen["bus"]), strip(string(dgen["source_id"][3])))] = dgen
    end
    unmatched_dgen_keys = Set(keys(dgen_lookup))

    for (_, d) in _sorted_pm_entries(data["load"])
        bus_id = get_bus_id(reg, Int(d["load_bus"]))
        name = String(_get_name(d))
        is_interruptible = haskey(d, "interruptible")
        if is_pti && is_interruptible && d["interruptible"] != 1
            _make_standard_load!(sys, reg, bus_id, d, name, base_power)
        elseif is_pti && is_interruptible && d["interruptible"] == 1
            _make_interruptible_standardload!(sys, reg, bus_id, d, name, base_power)
        else
            _make_power_load!(sys, reg, bus_id, d, name, base_power)
        end

        load_source_id = get(d, "source_id", String[])
        if length(load_source_id) >= 3 && load_source_id[1] == "load"
            dgen_key = (Int(d["load_bus"]), strip(string(load_source_id[3])))
            if haskey(dgen_lookup, dgen_key)
                _make_dgen_renewable!(sys, reg, bus_id, dgen_lookup[dgen_key], name,
                    base_power)
                delete!(unmatched_dgen_keys, dgen_key)
            end
        end
    end

    if !isempty(unmatched_dgen_keys)
        throw(
            IS.DataFormatError(
                "distributed generation entries did not match any load: $(collect(unmatched_dgen_keys))",
            ),
        )
    end
    return
end

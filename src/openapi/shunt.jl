# `_make_per_unit!` divides the shunt admittances it recognizes by the case base:
# `shunt`'s `gs`/`bs`, and `switched_shunt`'s `gs`/`bs` and `y_increment`. Those four
# arrive here as system per-unit and are multiplied back by `base_power` before
# `set_value!`, the same undo load.jl performs, because
# `ShuntAdmittanceUnitBasis.COMPONENT_MVAR` declares a natural MW/MVAr-at-unity-voltage
# value — the RAW's own GL/BL and BINIT/Bi.
#
# Every other field this file writes is outside that rescale and is used exactly as PFFP's
# own psse.jl parser wrote it: `switched_shunt`'s `admittance_limits` (a voltage band, see
# `make_switched_admittance!`) and all of `facts`.

"""Fixed admittance (PSS/E `FIXED SHUNT`)."""
function make_fixed_admittance!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    name::AbstractString,
    d::Dict,
    bus_id::Int,
)
    base_power = get_base_power(sys)

    component = stage(PO.FixedAdmittance)
    set_value!(component, :id, register!(reg, "FixedAdmittance", name))
    set_value!(component, :name, name)
    set_value!(component, :available, Bool(d["status"]))
    set_value!(component, :bus, bus_id)
    set_value!(component, :base_power, base_power, "MVA")
    set_value!(component, :admittance_units, "COMPONENT_MVAR")
    set_value!(
        component,
        :y,
        (real = d["gs"] * base_power, imag = d["bs"] * base_power),
        "MVAr",
    )
    add_component!(sys, component)
    return
end

"""PSS/E MODSW switched-shunt control-mode codes, in the schema's
`SwitchedAdmittance.control_mode` spelling. Ported from PSY's
`SwitchedAdmittanceControlMode` enum (`definitions.jl:155-163`)."""
const SWITCHED_ADMITTANCE_CONTROL_MODE_NAMES = Dict(
    -99 => "UNDEFINED",
    0 => "FIXED",
    1 => "DISCRETE_VOLTAGE",
    2 => "CONTINUOUS_VOLTAGE",
    3 => "DISCRETE_REACTIVE_PLANT",
    4 => "DISCRETE_REACTIVE_VSC",
    5 => "DISCRETE_ADMITTANCE_REMOTE",
)

function _switched_admittance_control_mode(code::Integer)
    if !haskey(SWITCHED_ADMITTANCE_CONTROL_MODE_NAMES, code)
        throw(IS.DataFormatError("unsupported switched shunt MODSW control mode=$code"))
    end
    return SWITCHED_ADMITTANCE_CONTROL_MODE_NAMES[code]
end

"""
Assign `y_increase`: an array of complex admittances sharing `admittance_units`'s
discriminated unit. `units.jl`'s generic compound-value path builds ONE compound object
per call and cannot construct a `Vector` of them; this is the only array-of-compound
shape any reader needs, so it reuses `units.jl`'s private `_declared`/`_convert` here
rather than extending `set_value!` for a single call site.
"""
function _set_y_increase!(
    component::Staged,
    values::Vector{ComplexF64},
    source_unit::AbstractString,
)
    target, quantity = _declared(component, :y_increase)
    converted = [
        IC.ComplexNumber(;
            real = _convert(component, :y_increase, real(v), source_unit, target, quantity),
            imag = _convert(component, :y_increase, imag(v), source_unit, target, quantity),
        ) for v in values
    ]
    component.fields[:y_increase] = converted
    return
end

"""
Switched admittance (PSS/E `SWITCHED SHUNT`).

`admittance_limits` mirrors PSCB's own field verbatim: PSS/E's `VSWLO`/`VSWHI` are a
controlled-voltage band, not an admittance band, despite the oracle's field name — a
pre-existing PSCB naming quirk reproduced faithfully, not fixed here. Being voltages, they
are outside `_make_per_unit!`'s admittance rescale and take no `base_power` factor, unlike
`solved_admittance` and `y_increase`.

The schema dropped `SwitchedAdmittance`'s own fixed `Y` field (the total admittance is now
`number_engaged` * `y_increase`, unless `solved_admittance` overrides it): `d["bs"]`
(PSS/E BINIT, the solved-case total) now lands on `solved_admittance` instead, and
`d["gs"]` (always `0.0` for a switched shunt) has no remaining target. `initial_status`
(already per-block Vector{Int} from `psse.jl`) is `number_engaged` now, not a bare status
flag.
"""
function make_switched_admittance!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    name::AbstractString,
    d::Dict,
    bus_id::Int,
)
    control_mode = _switched_admittance_control_mode(Int(d["control_mode"]))
    base_power = get_base_power(sys)

    component = stage(PO.SwitchedAdmittance)
    set_value!(component, :id, register!(reg, "SwitchedAdmittance", name))
    set_value!(component, :name, name)
    set_value!(component, :available, Bool(d["status"]))
    set_value!(component, :bus, bus_id)
    set_value!(component, :admittance_units, "COMPONENT_MVAR")
    set_value!(component, :number_of_steps, d["step_number"])
    _set_y_increase!(component, d["y_increment"] * base_power, "MVAr")
    admittance_limits = d["admittance_limits"]
    set_value!(component, :admittance_limits,
        (min = admittance_limits[1], max = admittance_limits[2]), "MVAr")
    set_value!(component, :control_mode, control_mode)
    # PSS/E SWREM in every control mode; the own bus (or 0) is spelled `nothing`.
    remote_number = Int(get(d, "regulated_bus_number", 0))
    _set_nullable!(
        component,
        :remote_regulated_bus_id,
        _psse_remote_bus_id(reg, remote_number, bus_id),
    )
    if haskey(d, "number_engaged")
        set_value!(component, :number_engaged, d["number_engaged"])
    end
    # PSS/E BINIT. Always present in a SWITCHED SHUNT record (pti.jl defaults it to 0.0), so
    # a parsed switched shunt always carries a solved admittance and downstream reads it
    # rather than summing blocks -- which is what PSS/E itself does with the value.
    if haskey(d, "solved_admittance")
        set_value!(
            component,
            :solved_admittance,
            d["solved_admittance"] * base_power,
            "MVAr",
        )
    end
    add_component!(sys, component)
    set_component_ext!(sys, component, get(d, "ext", Dict{String, Any}()))
    if Bool(d["status"]) && control_mode in ("DISCRETE_VOLTAGE", "CONTINUOUS_VOLTAGE")
        record_voltage_control_member!(
            sys,
            _regulated_bus_number(remote_number, Int(d["shunt_bus"])),
            component,
            _rmpct_weight(get(d, "rmpct", 100.0), "switched shunt $name"),
        )
    end
    return
end

"""PSS/E FACTS MODE codes (0/1/2 — "Unavailable"/"Normal"/"Link bypassed", per
`pm_io/psse.jl:430`), in the schema's `FACTSControlDevice.control_mode` spelling. Ported
from PSY's `FACTSOperationModes` enum (`definitions.jl:98-102`). PSCB's own
`make_facts` guards only `d["control_mode"] > 3`, a stale bound from a since-shrunk enum;
this reader's bound is 0-2, the current enum's actual domain."""
const FACTS_CONTROL_MODE_NAMES = Dict(0 => "OOS", 1 => "NML", 2 => "BYP")

function _facts_control_mode(code::Integer)
    if !haskey(FACTS_CONTROL_MODE_NAMES, code)
        throw(IS.DataFormatError("unsupported FACTS control mode=$code"))
    end
    return FACTS_CONTROL_MODE_NAMES[code]
end

"""FACTS control device. Series FACTS
(`tbus != 0`) are unsupported and only warned about, matching the oracle; this reader
still emits the STATCOM-simplified device."""
function make_facts!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    name::AbstractString,
    d::Dict,
    bus_id::Int,
)
    if d["tbus"] != 0
        @warn "Series FACTs not supported for $name."
    end
    control_mode = _facts_control_mode(Int(d["control_mode"]))

    component = stage(PO.FACTSControlDevice)
    set_value!(component, :id, register!(reg, "FACTSControlDevice", name))
    set_value!(component, :name, name)
    set_value!(component, :available, Bool(d["available"]))
    set_value!(component, :bus, bus_id)
    set_value!(component, :base_power, get_base_power(sys), "MVA")
    set_value!(component, :control_mode, control_mode)
    set_value!(component, :voltage_setpoint_units, "COMPONENT_BASE")
    set_value!(component, :voltage_setpoint, d["voltage_setpoint"], "pu")
    set_value!(component, :max_shunt_current, d["max_shunt_current"], "MVA")
    set_value!(component, :reactive_power_required, get(d, "reactive_power_required", 0.0),
        "MVAr")
    # PSS/E FCREG (REMOT before v35); the sending end bus (or 0) is spelled `nothing`.
    remote_number = Int(get(d, "regulated_bus_number", 0))
    _set_nullable!(
        component,
        :remote_regulated_bus_id,
        _psse_remote_bus_id(reg, remote_number, bus_id),
    )
    add_component!(sys, component)
    set_component_ext!(sys, component, get(d, "ext", Dict{String, Any}()))
    if Bool(d["available"]) && control_mode != "OOS"
        record_voltage_control_member!(
            sys,
            _regulated_bus_number(remote_number, Int(d["bus"])),
            component,
            _rmpct_weight(get(d, "rmpct", 100.0), "FACTS device $name"),
        )
    end
    return
end

"""
Create one `FixedAdmittance` per `data["shunt"]` entry, one `SwitchedAdmittance` per
`data["switched_shunt"]` entry, and one `FACTSControlDevice` per `data["facts"]` entry.
Ported from PSCB's `read_shunt!`/`read_switched_shunt!`/`read_facts!`, run together.

Deviates from the oracle in one place: PSCB's `read_facts!` reads its name formatter under
`:bus_name_formatter`, the same kwarg `read_bus!` uses — a copy-paste artifact, since a
real bus formatter would `KeyError` on a FACTS entry. This reader uses
`:facts_name_formatter` instead, with the same default and identical behavior for any
caller that overrides neither.
"""
function read_shunts!(sys::OpenAPISystem, data::Dict; kwargs...)
    reg = get_registry(sys)
    _get_shunt_name = get(kwargs, :shunt_name_formatter, _get_pm_dict_name)
    _get_switched_shunt_name =
        get(kwargs, :switched_shunt_name_formatter, _get_pm_dict_name)
    _get_facts_name = get(kwargs, :facts_name_formatter, _get_pm_dict_name)

    for (d_key, d) in _sorted_pm_entries(get(data, "shunt", Dict{String, Any}()))
        d["name"] = get(d, "name", string(d_key))
        name = String(_get_shunt_name(d))
        bus_id = get_bus_id(reg, Int(d["shunt_bus"]))
        make_fixed_admittance!(sys, reg, name, d, bus_id)
    end

    for (d_key, d) in _sorted_pm_entries(get(data, "switched_shunt", Dict{String, Any}()))
        d["name"] = get(d, "name", string(d_key))
        name = String(_get_switched_shunt_name(d))
        bus_id = get_bus_id(reg, Int(d["shunt_bus"]))
        make_switched_admittance!(sys, reg, name, d, bus_id)
    end

    for (d_key, d) in _sorted_pm_entries(get(data, "facts", Dict{String, Any}()))
        d["name"] = get(d, "name", string(d_key))
        name = String(_get_facts_name(d))
        bus_number = Int(d["bus"])
        full_name = "$(bus_number)_$(name)"
        bus_id = get_bus_id(reg, bus_number)
        make_facts!(sys, reg, full_name, d, bus_id)
    end
    return
end

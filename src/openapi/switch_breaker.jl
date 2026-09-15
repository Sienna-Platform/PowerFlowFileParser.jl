# "switch"/"breaker"/"generic_connector" share an identical row shape, so one reader
# covers all three.
#
# None of "switch"/"breaker"/"generic_connector" are native PowerModels sections —
# `_psse2pm_switch_breaker!` (`pm_io/psse.jl`) writes their fields directly from PSS/E
# records with no `_make_per_unit!` pass, so every value here is used exactly as parsed:
# no `sys_mbase` scaling anywhere in this file, matching the oracle.
#
# `state`'s isolated-bus zeroing already happened while parsing
# (`branch_isolated_bus_modifications!`, `pm_io/psse.jl`), so unlike `make_line!`/
# `make_transformer_2w!` this needs no `_branch_available`-style guard.
#
# MATPOWER's own native `mpc.switch` table has a different shape (`psw`/`qsw`/
# `thermal_rating`, no `r`/`x`/`rating`/`discrete_branch_type`) and is not this reader's
# target; PSCB's `read_switch_breaker!` `KeyError`s on it the same way — an existing
# oracle gap, not one this task introduces.

"""PowerModels/PSS/E discrete-branch-type codes (`0`/`1`/`2`), in the schema's
`DiscreteControlledACBranch.discrete_branch_type` spelling. Ported from PSY's own
`DiscreteControlledBranchType` enum (`SWITCH = 0`, `BREAKER = 1`, `OTHER = 2`,
`definitions.jl`)."""
const DISCRETE_BRANCH_TYPE_NAMES = Dict(0 => "SWITCH", 1 => "BREAKER", 2 => "OTHER")

function _discrete_branch_type(code::Integer)
    if !haskey(DISCRETE_BRANCH_TYPE_NAMES, code)
        throw(IS.DataFormatError("unsupported discrete branch type=$code"))
    end
    return DISCRETE_BRANCH_TYPE_NAMES[code]
end

"""PSS/E STAT/ST-style 0/1 status, in the schema's `DiscreteControlledACBranch.branch_status`
spelling. Ported from PSY's own `DiscreteControlledBranchStatus` enum (`OPEN = 0`,
`CLOSED = 1`, `definitions.jl`)."""
function _discrete_branch_status(code::Integer)
    if code == 0
        return "OPEN"
    elseif code == 1
        return "CLOSED"
    end
    throw(IS.DataFormatError("unsupported discrete branch status=$code"))
end

"""
A switch, breaker, or generic connector as a `DiscreteControlledACBranch`. Ported from
PSCB's `make_switch_breaker`. `base_power` is set explicitly here because
the oracle's constructor leaves it to PSY's `add_component!`, which back-fills the system
base for every `BasePowerKind::SystemBasePower` type.
"""
function make_switch_breaker!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    name::AbstractString,
    d::Dict,
    from_id::Int,
    to_id::Int,
    sys_mbase::Float64,
)
    arc_id = add_arc!(sys, from_id, to_id)
    state = Int(d["state"])

    component = stage(PO.DiscreteControlledACBranch)
    set_value!(component, :id, register!(reg, "DiscreteControlledACBranch", name))
    set_value!(component, :name, name)
    set_value!(component, :available, Bool(state))
    set_value!(component, :active_power_flow, d["active_power_flow"], "MW")
    set_value!(component, :reactive_power_flow, d["reactive_power_flow"], "MVAr")
    set_value!(component, :arc, arc_id)
    set_value!(component, :base_power, sys_mbase, "MVA")
    set_value!(component, :r, d["r"], "pu")
    set_value!(component, :x, d["x"], "pu")
    # Verbatim-oracle passthrough: unlike `_get_rating` (Line/TransformerCircuit), PSCB's
    # own `make_switch_breaker` never treats a zero rating as INFINITE_BOUND here.
    set_value!(component, :rating, d["rating"], "MVA")
    set_value!(
        component,
        :discrete_branch_type,
        _discrete_branch_type(Int(d["discrete_branch_type"])),
    )
    set_value!(component, :branch_status, _discrete_branch_status(state))
    add_component!(sys, component)
    set_component_ext!(sys, component, get(d, "ext", Dict{String, Any}()))
    return
end

"""
Create one `DiscreteControlledACBranch` per `data["switch"]`/`data["breaker"]`/
`data["generic_connector"]` entry.
"""
function read_switch_breaker!(sys::OpenAPISystem, data::Dict; kwargs...)
    reg = get_registry(sys)
    sys_mbase = get_base_power(sys)
    bus_lookup = _pm_bus_lookup(sys)
    _get_name = get(kwargs, :branch_name_formatter, _get_pm_branch_name)

    for device_type in ("switch", "breaker", "generic_connector")
        for (_, d) in _sorted_pm_entries(get(data, device_type, Dict{String, Any}()))
            from_number, to_number = Int(d["f_bus"]), Int(d["t_bus"])
            from_name, = bus_lookup[from_number]
            to_name, = bus_lookup[to_number]
            from_id = get_bus_id(reg, from_number)
            to_id = get_bus_id(reg, to_number)
            name = String(_get_name(d, from_name, to_name))
            make_switch_breaker!(sys, reg, name, d, from_id, to_id, sys_mbase)
        end
    end
    return
end

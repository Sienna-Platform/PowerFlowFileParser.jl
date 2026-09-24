# `data["dcline"]` IS a native PowerModels section — `_make_per_unit!` divides its power
# fields (`pf`/`qf`/`p*f`/`q*f`/`p*t`/`q*t`) by `baseMVA`. The LCC-specific fields (`r`,
# `transfer_setpoint`, `scheduled_dc_voltage`, `rectifier_*`, `inverter_*`, and the rest
# of the PSS/E-native block) have no PowerModels counterpart, so `_make_per_unit!` never
# touches them: they arrive already in the natural unit the schema's `NATURAL_UNITS`
# default expects (ohms, kV, radians, ...). `TwoTerminalGenericHVDCLine`/
# `TwoTerminalLCCLine`'s `base_power` is always the SYSTEM base (like
# `Line`/`AreaInterchange`), so every native-PM power field is multiplied by `sys_mbase`.
#
# `data["vscline"]` and `data["interarea_transfer"]` are NOT native PowerModels sections;
# see the per-maker docstrings below for how PFFP's own `psse.jl` pre-scales their fields.

"""A linear `LossCurve` with fixed `"NATURAL_UNITS"` power units, shared by every
converter/two-terminal loss curve site: loss values arrive unscaled regardless of the
run's own `power_units` convention (see this file's header), the same fixed-natural
pattern `cost.jl`'s `_zero_cost_curve` uses."""
function _loss_curve(proportional_term::Float64, constant_term::Float64)
    return PC.LossCurve(;
        power_units = IC.UnitSystem("NATURAL_UNITS"),
        value_curve = PC.LossValueCurve(
            PC.InputOutputCurve(;
                curve_type = "INPUT_OUTPUT",
                function_data = PC.InputOutputCurveFunctionData(
                    IC.LinearFunctionData(;
                        function_type = "LINEAR",
                        proportional_term = proportional_term,
                        constant_term = constant_term,
                    ),
                ),
            ),
        ),
    )
end

"""A linear `LossCurve` from a pm dict's `loss0`/`loss1` fields, shared by
`TwoTerminalLCCLine` and `TwoTerminalGenericHVDCLine`. `TwoTerminalLoss` no longer exists
(the two per-owner loss wrappers collapsed into this one shared `LossCurve`)."""
function _two_terminal_loss(d::Dict)
    return _loss_curve(d["loss1"], d["loss0"])
end

"""Two-terminal LCC HVDC line (PSS/E)."""
function make_lcc_line!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    name::AbstractString,
    d::Dict,
    from_id::Int,
    to_id::Int,
    sys_mbase::Float64,
)
    arc_id = add_arc!(sys, from_id, to_id)
    component = stage(PO.TwoTerminalLCCLine)
    set_value!(component, :id, register!(reg, "TwoTerminalLCCLine", name))
    set_value!(component, :name, name)
    set_value!(component, :available, Bool(d["available"]))
    set_value!(component, :arc, arc_id)
    set_value!(component, :active_power_flow, get(d, "pf", 0.0) * sys_mbase, "MW")
    set_value!(component, :parameter_units, "NATURAL_UNITS")
    set_value!(component, :r, d["r"], "ohm")
    set_value!(component, :power_mode, Bool(d["power_mode"]))
    if d["power_mode"]
        transfer_setpoint_unit = "MW"
    else
        transfer_setpoint_unit = "A"
    end
    set_value!(
        component,
        :transfer_setpoint,
        d["transfer_setpoint"],
        transfer_setpoint_unit,
    )
    set_value!(component, :dc_voltage_units, "NATURAL_UNITS")
    set_value!(component, :scheduled_dc_voltage, d["scheduled_dc_voltage"], "kV")
    set_value!(component, :rectifier_bridges, Int(d["rectifier_bridges"]))
    set_value!(component, :rectifier_delay_angle_limits, d["rectifier_delay_angle_limits"],
        "rad")
    set_value!(component, :rectifier_rc, d["rectifier_rc"], "ohm")
    set_value!(component, :rectifier_xc, d["rectifier_xc"], "ohm")
    set_value!(component, :rectifier_base_voltage, d["rectifier_base_voltage"], "kV")
    set_value!(component, :inverter_bridges, Int(d["inverter_bridges"]))
    set_value!(component, :inverter_extinction_angle_limits,
        d["inverter_extinction_angle_limits"], "rad")
    set_value!(component, :inverter_rc, d["inverter_rc"], "ohm")
    set_value!(component, :inverter_xc, d["inverter_xc"], "ohm")
    set_value!(component, :inverter_base_voltage, d["inverter_base_voltage"], "kV")
    set_value!(component, :switch_mode_voltage, d["switch_mode_voltage"], "kV")
    set_value!(component, :compounding_resistance, d["compounding_resistance"], "ohm")
    set_value!(component, :min_compounding_voltage, d["min_compounding_voltage"], "kV")
    set_value!(component, :rectifier_transformer_ratio, d["rectifier_transformer_ratio"],
        "1")
    set_value!(component, :rectifier_tap_setting, d["rectifier_tap_setting"], "1")
    set_value!(component, :rectifier_tap_limits, d["rectifier_tap_limits"], "1")
    set_value!(component, :rectifier_tap_step, d["rectifier_tap_step"], "1")
    set_value!(component, :rectifier_delay_angle, d["rectifier_delay_angle"], "rad")
    # ICR/ICI: the converter bus (or 0) is spelled `nothing`, like every remote bus.
    _set_nullable!(
        component,
        :rectifier_commutating_bus_id,
        _psse_remote_bus_id(
            reg,
            get(d, "rectifier_commutating_bus_number", 0),
            from_id;
            owner = "DC line $name rectifier",
        ),
    )
    _set_nullable!(
        component,
        :inverter_commutating_bus_id,
        _psse_remote_bus_id(
            reg,
            get(d, "inverter_commutating_bus_number", 0),
            to_id;
            owner = "DC line $name inverter",
        ),
    )
    _set_nullable!(
        component,
        :rectifier_tap_transformer_id,
        _psse_transformer_id(
            sys, get(d, "rectifier_tap_transformer", (0, 0, "")), "DC line $name rectifier",
        ),
    )
    _set_nullable!(
        component,
        :inverter_tap_transformer_id,
        _psse_transformer_id(
            sys, get(d, "inverter_tap_transformer", (0, 0, "")), "DC line $name inverter",
        ),
    )
    set_value!(component, :rectifier_capacitor_reactance,
        d["rectifier_capacitor_reactance"],
        "ohm")
    set_value!(component, :inverter_transformer_ratio, d["inverter_transformer_ratio"], "1")
    set_value!(component, :inverter_tap_setting, d["inverter_tap_setting"], "1")
    set_value!(component, :inverter_tap_limits, d["inverter_tap_limits"], "1")
    set_value!(component, :inverter_tap_step, d["inverter_tap_step"], "1")
    set_value!(component, :inverter_extinction_angle, d["inverter_extinction_angle"], "rad")
    set_value!(component, :inverter_capacitor_reactance, d["inverter_capacitor_reactance"],
        "ohm")
    set_value!(component, :loss, _two_terminal_loss(d))
    set_value!(component, :base_power, sys_mbase, "MVA")
    add_component!(sys, component)
    set_component_ext!(sys, component, get(d, "ext", Dict{String, Any}()))
    return
end

"""Two-terminal generic HVDC line (MATPOWER)."""
function make_generic_hvdc_line!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    name::AbstractString,
    d::Dict,
    from_id::Int,
    to_id::Int,
    sys_mbase::Float64,
)
    arc_id = add_arc!(sys, from_id, to_id)
    component = stage(PO.TwoTerminalGenericHVDCLine)
    set_value!(component, :id, register!(reg, "TwoTerminalGenericHVDCLine", name))
    set_value!(component, :name, name)
    set_value!(component, :available, d["br_status"] == 1)
    set_value!(component, :active_power_flow, get(d, "pf", 0.0) * sys_mbase, "MW")
    set_value!(component, :arc, arc_id)
    set_value!(component, :active_power_limits_from,
        (min = d["pminf"] * sys_mbase, max = d["pmaxf"] * sys_mbase), "MW")
    set_value!(component, :active_power_limits_to,
        (min = d["pmint"] * sys_mbase, max = d["pmaxt"] * sys_mbase), "MW")
    set_value!(component, :reactive_power_limits_from,
        (min = d["qminf"] * sys_mbase, max = d["qmaxf"] * sys_mbase), "MVAr")
    set_value!(component, :reactive_power_limits_to,
        (min = d["qmint"] * sys_mbase, max = d["qmaxt"] * sys_mbase), "MVAr")
    set_value!(component, :loss, _two_terminal_loss(d))
    set_value!(component, :base_power, sys_mbase, "MVA")
    add_component!(sys, component)
    return
end

"""
Dispatch a `data["dcline"]` entry to `TwoTerminalLCCLine` (PSS/E) or
`TwoTerminalGenericHVDCLine` (MATPOWER). Ported from PSCB's `make_dcline`'s source-type
dispatch, which never considers whether a PSS/E two-terminal DC line record is *actually*
an LCC converter — a finer type-selection rule is RECORDED DEBT upstream.
"""
function make_dcline!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    name::AbstractString,
    d::Dict,
    from_id::Int,
    to_id::Int,
    source_type::AbstractString,
    sys_mbase::Float64,
)
    if source_type == "pti"
        make_lcc_line!(sys, reg, name, d, from_id, to_id, sys_mbase)
    elseif source_type == "matpower"
        make_generic_hvdc_line!(sys, reg, name, d, from_id, to_id, sys_mbase)
    else
        throw(IS.DataFormatError("unsupported source_type=$source_type for dcline data"))
    end
    return
end

"""
Voltage-source-converter HVDC line (PSS/E `VOLTAGE SOURCE CONVERTER`). Ported from
PSCB's `make_vscline`.

Every numeric field `psse.jl` derives from a per-bridge PSS/E record (`rating`/
`rating_from`/`rating_to`, `active_power_limits_from`/`to`, `reactive_power_limits_from`/
`to`, `active_power_flow`) is pre-divided by `baseMVA` at parse time, the same system-pu
convention as `data["dcline"]`'s native fields, so this maker multiplies them back by
`sys_mbase` — `TwoTerminalVSCLine.base_power` is the system base.

`dc_current`("if")/`max_dc_current_from`/`to`/`power_factor_weighting_fraction_from`/`to`
are already natural (Amperes / a bare fraction) and pass through unscaled.
`dc_setpoint_from`/`to` is per-unit on `rated_dc_voltage` when the converter controls DC
voltage, or on `sys_mbase` when it controls DC power.

`setpoint_voltage_units` (decoupled from `voltage_units`, which tags only
`voltage_limits_from`/`to`) is set unconditionally to `COMPONENT_BASE`: PSS/E always reports a
voltage-controlling side's DC setpoint as p.u. of `rated_dc_voltage` (`psse.jl` pre-divides
`DCSET` by `base_voltage`) and a voltage-controlling AC setpoint (`ACSET`) as p.u. of the AC
bus's own base voltage — never kV. The `DC_POWER`/`AC_REACTIVE_POWER` branches have their own
fixed units (`MW`/`1`) and ignore this discriminator, so setting it unconditionally is safe
regardless of which sides actually control voltage.

`psse.jl` also captures each converter's own AC bus base kV as `base_voltage_from`/
`base_voltage_to`, threaded onto the document as `rated_ac_voltage_from`/
`rated_ac_voltage_to` — the AC-side counterpart of `rated_dc_voltage`.
"""
function make_vscline!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    name::AbstractString,
    d::Dict,
    from_id::Int,
    to_id::Int,
    sys_mbase::Float64,
)
    arc_id = add_arc!(sys, from_id, to_id)
    component = stage(PO.TwoTerminalVSCLine)
    set_value!(component, :id, register!(reg, "TwoTerminalVSCLine", name))
    set_value!(component, :name, name)
    set_value!(component, :available, Bool(d["available"]))
    set_value!(component, :arc, arc_id)
    set_value!(component, :active_power_flow, get(d, "pf", 0.0) * sys_mbase, "MW")
    set_value!(component, :rating, d["rating"] * sys_mbase, "MVA")
    set_value!(component, :active_power_limits_from,
        (min = d["pminf"] * sys_mbase, max = d["pmaxf"] * sys_mbase), "MW")
    set_value!(component, :active_power_limits_to,
        (min = d["pmint"] * sys_mbase, max = d["pmaxt"] * sys_mbase), "MW")
    set_value!(component, :admittance_units, "NATURAL_UNITS")
    # Ternary exception: verbatim port of the oracle's own
    # `d["r"] == 0.0 ? 0.0 : 1.0 / d["r"]` (`make_vscline`).
    set_value!(component, :g, iszero(d["r"]) ? 0.0 : 1.0 / d["r"], "S")
    set_value!(component, :dc_current, get(d, "if", 0.0), "A")
    set_value!(component, :reactive_power_from, get(d, "qf", 0.0) * sys_mbase, "MVAr")
    # See the docstring: PSS/E's voltage-controlling setpoints are always already p.u.
    set_value!(component, :setpoint_voltage_units, "COMPONENT_BASE")
    if d["dc_voltage_control_from"]
        set_value!(component, :dc_control_from, "DC_VOLTAGE")
        set_value!(component, :dc_setpoint_from, d["dc_setpoint_from"], "pu")
    else
        set_value!(component, :dc_control_from, "DC_POWER")
        set_value!(component, :dc_setpoint_from, d["dc_setpoint_from"] * sys_mbase, "MW")
    end
    if d["ac_voltage_control_from"]
        set_value!(component, :ac_control_from, "AC_VOLTAGE")
        set_value!(component, :ac_setpoint_from, d["ac_setpoint_from"], "pu")
    else
        set_value!(component, :ac_control_from, "AC_REACTIVE_POWER")
        set_value!(component, :ac_setpoint_from, d["ac_setpoint_from"], "1")
    end
    set_value!(component, :rated_ac_voltage_from, d["base_voltage_from"], "kV")
    set_value!(
        component,
        :converter_loss_from,
        _loss_curve(
            IS.get_proportional_term(d["converter_loss_from"]),
            IS.get_constant_term(d["converter_loss_from"]),
        ),
    )
    set_value!(component, :max_dc_current_from, d["max_dc_current_from"], "A")
    set_value!(component, :rating_from, d["rating_from"] * sys_mbase, "MVA")
    set_value!(component, :reactive_power_limits_from,
        (min = d["qminf"] * sys_mbase, max = d["qmaxf"] * sys_mbase), "MVAr")
    set_value!(component, :power_factor_weighting_fraction_from,
        d["power_factor_weighting_fraction_from"], "1")
    remote_from = Int(get(d, "remote_bus_number_from", 0))
    _set_nullable!(
        component,
        :remote_regulated_bus_id_from,
        _psse_remote_bus_id(
            reg,
            remote_from,
            from_id;
            owner = "VSC line $name from converter",
        ),
    )
    set_value!(component, :reactive_power_to, get(d, "qt", 0.0) * sys_mbase, "MVAr")
    if d["dc_voltage_control_to"]
        set_value!(component, :dc_control_to, "DC_VOLTAGE")
        set_value!(component, :dc_setpoint_to, d["dc_setpoint_to"], "pu")
    else
        set_value!(component, :dc_control_to, "DC_POWER")
        set_value!(component, :dc_setpoint_to, d["dc_setpoint_to"] * sys_mbase, "MW")
    end
    if d["ac_voltage_control_to"]
        set_value!(component, :ac_control_to, "AC_VOLTAGE")
        set_value!(component, :ac_setpoint_to, d["ac_setpoint_to"], "pu")
    else
        set_value!(component, :ac_control_to, "AC_REACTIVE_POWER")
        set_value!(component, :ac_setpoint_to, d["ac_setpoint_to"], "1")
    end
    set_value!(component, :rated_ac_voltage_to, d["base_voltage_to"], "kV")
    set_value!(
        component,
        :converter_loss_to,
        _loss_curve(
            IS.get_proportional_term(d["converter_loss_to"]),
            IS.get_constant_term(d["converter_loss_to"]),
        ),
    )
    set_value!(component, :max_dc_current_to, d["max_dc_current_to"], "A")
    set_value!(component, :rating_to, d["rating_to"] * sys_mbase, "MVA")
    set_value!(component, :reactive_power_limits_to,
        (min = d["qmint"] * sys_mbase, max = d["qmaxt"] * sys_mbase), "MVAr")
    set_value!(component, :power_factor_weighting_fraction_to,
        d["power_factor_weighting_fraction_to"], "1")
    remote_to = Int(get(d, "remote_bus_number_to", 0))
    _set_nullable!(
        component,
        :remote_regulated_bus_id_to,
        _psse_remote_bus_id(reg, remote_to, to_id; owner = "VSC line $name to converter"),
    )
    set_value!(component, :rated_dc_voltage, d["rated_dc_voltage"], "kV")
    set_value!(component, :base_power, sys_mbase, "MVA")
    add_component!(sys, component)
    set_component_ext!(sys, component, get(d, "ext", Dict{String, Any}()))
    if Bool(d["available"])
        if d["ac_voltage_control_from"]
            record_voltage_control_member!(
                sys,
                _regulated_bus_number(reg, remote_from, Int(d["f_bus"])),
                component,
                _rmpct_weight(get(d, "rmpct_from", 100.0), "VSC line $name from converter");
                terminal = "FROM",
            )
        end
        if d["ac_voltage_control_to"]
            record_voltage_control_member!(
                sys,
                _regulated_bus_number(reg, remote_to, Int(d["t_bus"])),
                component,
                _rmpct_weight(get(d, "rmpct_to", 100.0), "VSC line $name to converter");
                terminal = "TO",
            )
        end
    end
    return
end

"""
Create one `TwoTerminalLCCLine`/`TwoTerminalGenericHVDCLine` per `data["dcline"]` entry.
"""
function read_dc_lines!(sys::OpenAPISystem, data::Dict; kwargs...)
    if !haskey(data, "dcline")
        return
    end
    reg = get_registry(sys)
    sys_mbase = get_base_power(sys)
    source_type = data["source_type"]
    bus_lookup = _pm_bus_lookup(sys)
    _get_name = get(kwargs, :dcline_name_formatter, _get_pm_branch_name)

    for (d_key, d) in _sorted_pm_entries(data["dcline"])
        d["name"] = get(d, "name", string(d_key))
        from_number, to_number = Int(d["f_bus"]), Int(d["t_bus"])
        from_id = get_bus_id(reg, from_number)
        to_id = get_bus_id(reg, to_number)
        name = String(_get_name(d, bus_lookup[from_number][1], bus_lookup[to_number][1]))
        make_dcline!(sys, reg, name, d, from_id, to_id, source_type, sys_mbase)
    end
    return
end

"""
Create one `TwoTerminalVSCLine` per `data["vscline"]` entry. Ported from PSCB's
`read_vscline!`, including the undefined-bus warn-and-skip (a real, already
logged skip in the oracle, ported as-is — not one of this reader's own silent skips).
"""
function read_vsc_lines!(sys::OpenAPISystem, data::Dict; kwargs...)
    if !haskey(data, "vscline")
        return
    end
    reg = get_registry(sys)
    sys_mbase = get_base_power(sys)
    bus_lookup = _pm_bus_lookup(sys)
    _get_name = get(kwargs, :vsc_line_name_formatter, _get_pm_branch_name)

    for (d_key, d) in _sorted_pm_entries(data["vscline"])
        d["name"] = get(d, "name", string(d_key))
        from_number, to_number = Int(d["f_bus"]), Int(d["t_bus"])
        if !haskey(bus_lookup, from_number) || !haskey(bus_lookup, to_number)
            @warn "VSC line $d_key references undefined bus(es) (from = $from_number, to = $to_number); skipping"
            continue
        end
        from_id = get_bus_id(reg, from_number)
        to_id = get_bus_id(reg, to_number)
        name = String(_get_name(d, bus_lookup[from_number][1], bus_lookup[to_number][1]))
        make_vscline!(sys, reg, name, d, from_id, to_id, sys_mbase)
    end
    return
end

"""
Create one `AreaInterchange` per `data["interarea_transfer"]` entry. Ported from the
`interarea_transfer` block inside PSCB's `read_bus!`, grouped here with the other
DC/interchange readers rather than with `topology.jl`'s bus reader.

# Bug-compatible with PSCB — `active_power_flow =
d["power_transfer"]` assigns PFFP's raw `PTRAN` value (already natural MW, since
`interarea_transfer` is not a native PowerModels section) into a field PSY declares `SU`,
with no division by `sys_mbase` first, so a real `get_active_power_flow(interchange,
PSY.NU)` on the oracle's object multiplies an already-natural number by `sys_mbase` a
second time. This reader reproduces that inflated value. Fix tracked upstream.

`flow_limits` mirrors the oracle's hardcoded `(from_to = -INFINITE_BOUND, to_from =
INFINITE_BOUND)` sentinel verbatim.
"""
function read_area_interchanges!(sys::OpenAPISystem, data::Dict; kwargs...)
    if data["source_type"] != "pti" || !haskey(data, "interarea_transfer")
        return
    end
    reg = get_registry(sys)
    sys_mbase = get_base_power(sys)
    _get_area_name = get(kwargs, :area_name_formatter, string)

    for (k, d) in _sorted_pm_entries(data["interarea_transfer"])
        area_from_name = _get_area_name(d["area_from"])
        area_to_name = _get_area_name(d["area_to"])
        transfer_id = get(d, "transfer_id", "1")
        if !has_id(reg, "Area", area_from_name) || !has_id(reg, "Area", area_to_name)
            # Ternary exception: verbatim port of the oracle's own
            # `isnothing(from_area) ? area_from_name : nothing` pair (`read_bus!`).
            missing_areas = join(
                filter(
                    !isnothing,
                    [
                        !has_id(reg, "Area", area_from_name) ? area_from_name : nothing,
                        !has_id(reg, "Area", area_to_name) ? area_to_name : nothing,
                    ],
                ),
                ", ",
            )
            @warn "Inter-area transfer record $k references undefined area(s) $missing_areas; skipping AreaInterchange"
            continue
        end
        name = "$(area_from_name)_$(area_to_name)_$(transfer_id)"

        component = stage(PO.AreaInterchange)
        set_value!(component, :id, register!(reg, "AreaInterchange", name))
        set_value!(component, :name, name)
        set_value!(component, :available, true)
        # Bug-compatible with PSCB — see docstring.
        set_value!(component, :active_power_flow, d["power_transfer"] * sys_mbase, "MW")
        set_value!(component, :from_area, get_id(reg, "Area", area_from_name))
        set_value!(component, :to_area, get_id(reg, "Area", area_to_name))
        set_value!(component, :flow_limits,
            (from_to = -INFINITE_BOUND, to_from = INFINITE_BOUND), "MW")
        set_value!(component, :base_power, sys_mbase, "MVA")
        add_component!(sys, component)
    end
    return
end

"""
Assemble every DC-branch-adjacent reader for the "dc_branch" stage: `TwoTerminalLCCLine`/
`TwoTerminalGenericHVDCLine` (`data["dcline"]`), `TwoTerminalVSCLine` (`data["vscline"]`),
and `AreaInterchange` (`data["interarea_transfer"]`).
"""
function read_dc_branches!(sys::OpenAPISystem, data::Dict; kwargs...)
    read_dc_lines!(sys, data; kwargs...)
    read_vsc_lines!(sys, data; kwargs...)
    read_area_interchanges!(sys, data; kwargs...)
    return
end

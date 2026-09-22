# `data["branch"]` is a native PowerModels section: `_make_per_unit!` divides its power
# fields (`rate_a`/`rate_b`/`rate_c`, `pf`/`qf`) by `baseMVA`, same as every other PM power
# quantity, but leaves impedance/admittance fields (`br_r`/`br_x`/`g_fr`/`g_to`/`b_fr`/
# `b_to`) untouched — PowerModels' branch representation is impedance-native, never
# natural ohms. For a `Line`, whose `base_power` is the SYSTEM base,
# this means every field this reader multiplies by a base uses `sys_mbase`.
#
# For a PSS/E-sourced transformer, PFFP's own `psse.jl` additionally REBASES `br_r`/
# `br_x`/`g_fr`/`b_fr` from system-pu onto the transformer's own winding base
# (`d["base_power"]`, a custom key `_make_per_unit!` never touches) BEFORE this reader
# sees them. `rate_a`/`rate_b`/`rate_c`/`pf`/`qf` are NOT rebased that way, so the
# oracle's `TransformerCircuit.rating`/`*_power_flow` fields hold a SYSTEM-pu number that
# PSY's units engine reads back as DEVICE-base pu. Verified against the real oracle
# (synthetic `base_power = 50` on a 100 MVA system): `PSY.get_rating(circuit, PSY.NU)`
# multiplies by the CIRCUIT's own `base_power`, not by `sys_mbase`, and this reader
# reproduces exactly that. The two coincide whenever the winding base equals the system
# base — true in every fixture on hand, and always true for MATPOWER — so no real fixture
# can distinguish them.
#
# `data["3w_transformer"]` is NOT a native PowerModels section — `_make_per_unit!` never
# touches it. Its per-winding ratings/flows come straight from raw PSS/E fields
# (`rating_primary = min(RATA1, RATB1, RATC1)`; the flows are hardcoded `0.0`, PowerModels
# having no 3W flow data), so they are ALREADY natural units and get no further scaling.
# Its `r_primary`/`x_primary`/... and pairwise `r_12`/`x_12`/... are, like the 2W case,
# rebased by `psse.jl` onto their own winding base and passed through as device-base pu.

"""
Rating from a pm branch/transformer dict entry, matching PSCB's `_get_rating`: an absent
`"rate_a"` key means "unbounded" (`INFINITE_BOUND`); an absent `"rate_b"`/`"rate_c"`/
`"rating_primary"`/etc. means "not specified" (`nothing`, left to the schema's own
optional field). A present-but-zero value also means "unbounded" — PSS/E's own convention
for an unset rating (matpower's own zero-rating convention lands here too since PFFP's
matpower parser leaves zero rate_a in place rather than deleting the key, unlike the
PSS/E path).
"""
function _get_rating(name::AbstractString, d::Dict, key::AbstractString)
    if !haskey(d, key)
        # Ternary exception: verbatim port of the oracle's own
        # `key == "rate_a" ? INFINITE_BOUND : nothing` (`_get_rating`).
        return key == "rate_a" ? INFINITE_BOUND : nothing
    end
    if isapprox(d[key], 0.0)
        @info "$name rating $key value: $(d[key]). Unbounded value implied as per PSS/E manual."
        return INFINITE_BOUND
    end
    return d[key]
end

"""Bus name and ISOLATED status by pm bus number. Shared by the branch/transformer/
dc-line/shunt readers, all of which resolve endpoints by pm bus number rather than by
document id."""
function _pm_bus_lookup(sys::OpenAPISystem)
    lookup = Dict{Int, Tuple{String, Bool}}()
    for bus in get_components(sys, "ACBus")
        lookup[get_value(bus, :number)] =
            (get_value(bus, :name), get_value(bus, :bustype) == "ISOLATED")
    end
    return lookup
end

"""Ported from PSCB's `_get_pm_branch_name`: the branch/transformer circuit id embedded
in `source_id`, falling back to the raw pm dict index, formatted against the two
endpoints' names."""
function _get_pm_branch_name(
    d::Dict,
    bus_f_name::AbstractString,
    bus_t_name::AbstractString,
)
    source_id = get(d, "source_id", nothing)
    index = if haskey(d, "name")
        d["name"]
    elseif !isnothing(source_id) && source_id[1] == "branch" && length(source_id) > 2
        strip(string(source_id[4]))
    elseif !isnothing(source_id) &&
           source_id[1] in ("switch", "breaker", "generic_connector") &&
           length(source_id) > 2
        ckt = strip(string(source_id[4]))
        # Ternary exception: verbatim port of the oracle's own marker-strip ternary
        # (`_get_pm_branch_name`).
        (!isempty(ckt) && first(ckt) in ('@', '*')) ? ckt[2:end] : ckt
    elseif !isnothing(source_id) && source_id[1] == "transformer" && length(source_id) > 3
        strip(string(source_id[5]))
    else
        d["index"]
    end
    return "$bus_f_name-$bus_t_name-i_$index"
end

"""
Whether a `type_name` component named `name` is already in the registry. The default name is
the two endpoint bus names plus the PSS/E circuit id, so two pm dict rows on the same bus
pair with the same circuit id map to one name: duplicate TRANSFORMER records, a BRANCH record
reclassified as a transformer beside a declared one, or parallel branches flipped by
orientation correction. The row read first is kept; a later duplicate is reported with its
PSS/E record and dropped by the caller, so the build neither aborts nor invents a second
component the source file does not distinguish.
"""
function _is_duplicate_branch(
    reg::IdRegistry,
    type_name::AbstractString,
    name::AbstractString,
    d::Dict,
)
    if !has_id(reg, type_name, name)
        return false
    end
    record = get(d, "source_id", d["index"])
    @warn "$type_name $name already exists; PSS/E record $record shares its endpoint buses and circuit id. Keeping the record read first and dropping this one."
    return true
end

function _get_pm_3w_name(
    d::Dict,
    bus_primary_name::AbstractString,
    bus_secondary_name::AbstractString,
    bus_tertiary_name::AbstractString,
)
    return "$bus_primary_name-$bus_secondary_name-$bus_tertiary_name-i_$(d["circuit"])"
end

"""Whether a branch/transformer/dc-line endpoint pair keeps the pm dict's own
`br_status`/`available` flag or is forced unavailable because either terminal bus is
ISOLATED. Ported from the `available_value` guard repeated across PSCB's `make_line`/
`make_transformer_2w`/`_make_switch_from_zero_impedance_line`."""
function _branch_available(raw_status::Bool, from_isolated::Bool, to_isolated::Bool)
    return raw_status && !from_isolated && !to_isolated
end

"""matpower's own zero-rebase convention: `base_kv`/`base_power` of `0.0` means
"unspecified"; PSY's transformer winding validation requires a positive base voltage, so
`nothing` (unknown) is stored instead of a literal `0.0`. Ported from PSCB's
`_base_voltage_or_nothing`.

Ternary exception: verbatim port of the oracle's own `iszero(v) ? nothing : v`."""
_base_voltage_or_nothing(v::Real) = iszero(v) ? nothing : v

"""PSS/E COD1/COD2 transformer control-objective codes, in the schema's
`TransformerCircuit.control_objective` spelling. Ported from PSY's
`TransformerControlObjective` enum (`definitions.jl:260-273`)."""
const TRANSFORMER_CONTROL_OBJECTIVE_NAMES = Dict(
    -99 => "UNDEFINED",
    -1 => "VOLTAGE_DISABLED",
    -2 => "REACTIVE_POWER_FLOW_DISABLED",
    -3 => "ACTIVE_POWER_FLOW_DISABLED",
    -4 => "CONTROL_OF_DC_LINE_DISABLED",
    -5 => "ASYMMETRIC_ACTIVE_POWER_FLOW_DISABLED",
    0 => "FIXED",
    1 => "VOLTAGE",
    2 => "REACTIVE_POWER_FLOW",
    3 => "ACTIVE_POWER_FLOW",
    4 => "CONTROL_OF_DC_LINE",
    5 => "ASYMMETRIC_ACTIVE_POWER_FLOW",
)

"""COD values whose control objective is a phase-shift (angle) control rather than a tap
(voltage/reactive) control."""
const _PHASE_SHIFT_OBJECTIVES = (
    "ACTIVE_POWER_FLOW",
    "ACTIVE_POWER_FLOW_DISABLED",
    "ASYMMETRIC_ACTIVE_POWER_FLOW",
    "ASYMMETRIC_ACTIVE_POWER_FLOW_DISABLED",
)

"""`TransformerCircuit.control_limits`' unit per `control_objective`, read directly off
the schema's `x-units` table (`TransformerCircuit.json`)."""
const _CONTROL_LIMITS_UNIT = Dict(
    "UNDEFINED" => "1", "VOLTAGE_DISABLED" => "1",
    "REACTIVE_POWER_FLOW_DISABLED" => "1",
    "ACTIVE_POWER_FLOW_DISABLED" => "rad", "CONTROL_OF_DC_LINE_DISABLED" => "1",
    "ASYMMETRIC_ACTIVE_POWER_FLOW_DISABLED" => "rad", "FIXED" => "1", "VOLTAGE" => "1",
    "REACTIVE_POWER_FLOW" => "1", "ACTIVE_POWER_FLOW" => "rad",
    "CONTROL_OF_DC_LINE" => "1",
    "ASYMMETRIC_ACTIVE_POWER_FLOW" => "rad",
)

"""`TransformerCircuit.controlled_quantity_limits`' unit per `control_objective`, read
directly off the schema's `x-units` table."""
const _CONTROLLED_QUANTITY_LIMITS_UNIT = Dict(
    "UNDEFINED" => "pu", "VOLTAGE_DISABLED" => "pu",
    "REACTIVE_POWER_FLOW_DISABLED" => "MVAr",
    "ACTIVE_POWER_FLOW_DISABLED" => "MW", "CONTROL_OF_DC_LINE_DISABLED" => "MW",
    "ASYMMETRIC_ACTIVE_POWER_FLOW_DISABLED" => "MW", "FIXED" => "pu", "VOLTAGE" => "pu",
    "REACTIVE_POWER_FLOW" => "MVAr", "ACTIVE_POWER_FLOW" => "MW",
    "CONTROL_OF_DC_LINE" => "MW",
    "ASYMMETRIC_ACTIVE_POWER_FLOW" => "MW",
)

function _transformer_control_objective(cod::Real)
    code = Int(cod)
    if !haskey(TRANSFORMER_CONTROL_OBJECTIVE_NAMES, code)
        throw(IS.DataFormatError("unsupported transformer control objective COD=$code"))
    end
    return TRANSFORMER_CONTROL_OBJECTIVE_NAMES[code]
end

"""
Assign a `TransformerCircuit`'s flat control block from a pm transformer dict `d` for
winding `suffix` (1/2/3). Ported from PSCB's `_transformer_control_fields`: PSS/E's
`RMI`/`RMA`/`VMI`/`VMA` are already expressed in the unit `control_objective` implies, so
every value is a direct passthrough once `_CONTROL_LIMITS_UNIT`/
`_CONTROLLED_QUANTITY_LIMITS_UNIT` supply that unit. `record` names the site in the
inverted-limits warnings.
"""
function _set_transformer_control_fields!(
    circuit,
    d::Dict,
    suffix::Int,
    record::AbstractString,
)
    cod = get(d, "COD$suffix", -99)
    objective = _transformer_control_objective(cod)
    phase_shifting = objective in _PHASE_SHIFT_OBJECTIVES
    if phase_shifting
        rmi_default, rma_default = -180.0, 180.0
    else
        rmi_default, rma_default = 0.9, 1.1
    end
    rmi = get(d, "RMI$suffix", rmi_default)
    rma = get(d, "RMA$suffix", rma_default)
    if rmi > rma
        @warn "Transformer $record winding $suffix has inverted control limits RMI$suffix = $rmi > RMA$suffix = $rma; normalizing to (min = $rma, max = $rmi)."
        rmi, rma = rma, rmi
    end
    if phase_shifting
        rmi, rma = deg2rad(rmi), deg2rad(rma)
    end
    vmi = get(d, "VMI$suffix", 0.9)
    vma = get(d, "VMA$suffix", 1.1)
    if vmi > vma
        @warn "Transformer $record winding $suffix has inverted controlled-quantity limits VMI$suffix = $vmi > VMA$suffix = $vma; normalizing to (min = $vma, max = $vmi)."
        vmi, vma = vma, vmi
    end
    set_value!(circuit, :control_objective, objective)
    set_value!(circuit, :regulated_bus_number, Int(get(d, "CONT$suffix", 0)))
    set_value!(
        circuit,
        :control_limits,
        (min = rmi, max = rma),
        _CONTROL_LIMITS_UNIT[objective],
    )
    set_value!(circuit, :controlled_quantity_limits, (min = vmi, max = vma),
        _CONTROLLED_QUANTITY_LIMITS_UNIT[objective])
    set_value!(circuit, :number_of_tap_positions, Int(get(d, "NTP$suffix", 33)))
    return
end

"""
Build and register one `TransformerCircuit`, shared by the 2W maker (one circuit) and the
3W maker (three circuits). `rating`/`rating_b`/`rating_c`/`base_voltage_primary`/
`base_voltage_secondary` are passed as already-natural values (or `nothing`, matching the
schema's optional fields) — the caller resolves whichever base applies before calling in,
since 2W and 3W circuits use different bases (see the file header). `active_power_flow`/
`reactive_power_flow` are likewise pre-converted natural MW/MVAr.
"""
function _make_transformer_circuit!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    d::Dict,
    from_id::Int,
    to_id::Int,
    record::AbstractString;
    tap_key::AbstractString,
    angle_key::AbstractString,
    control_suffix::Int,
    available::Bool,
    r::Real,
    x::Real,
    rating,
    rating_b,
    rating_c,
    base_power::Real,
    base_voltage_primary,
    base_voltage_secondary,
    active_power_flow::Real,
    reactive_power_flow::Real,
)
    arc_id = add_arc!(sys, from_id, to_id)
    circuit = stage(PO.TransformerCircuit)
    set_value!(circuit, :id, next_id!(reg))
    set_value!(circuit, :available, available)
    set_value!(circuit, :arc, arc_id)
    set_value!(circuit, :tap, get(d, tap_key, 1.0), "1")
    set_value!(circuit, :alpha, d[angle_key], "rad")
    set_value!(circuit, :parameter_units, "COMPONENT_BASE")
    set_value!(circuit, :r, r, "pu")
    set_value!(circuit, :x, x, "pu")
    _set_transformer_control_fields!(circuit, d, control_suffix, record)
    set_value!(circuit, :base_power, base_power, "MVA")
    set_optional_value!(circuit, :rating, rating, "MVA")
    set_optional_value!(circuit, :rating_b, rating_b, "MVA")
    set_optional_value!(circuit, :rating_c, rating_c, "MVA")
    set_value!(circuit, :active_power_flow, active_power_flow, "MW")
    set_value!(circuit, :reactive_power_flow, reactive_power_flow, "MVAr")
    set_optional_value!(circuit, :base_voltage_primary, base_voltage_primary, "kV")
    set_optional_value!(circuit, :base_voltage_secondary, base_voltage_secondary, "kV")
    add_component!(sys, circuit)
    return get_value(circuit, :id)
end

"""AC transmission line. `r`/`x`/`b` are
per-unit BY DOCUMENT CONVENTION on `base_power` (fixed `"pu"`, no discriminator — see the
Line schema); they are never multiplied by `base_power`. `rating`/`rating_b`/`rating_c`/
`active_power_flow`/`reactive_power_flow` are power quantities and are multiplied by
`sys_mbase` (`Line.base_power` is the system base)."""
function make_line!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    name::AbstractString,
    d::Dict,
    from_id::Int,
    to_id::Int,
    from_isolated::Bool,
    to_isolated::Bool,
    sys_mbase::Float64,
)
    available = _branch_available(d["br_status"] == 1, from_isolated, to_isolated)
    arc_id = add_arc!(sys, from_id, to_id)

    line = stage(PO.Line)
    set_value!(line, :id, register!(reg, "Line", name))
    set_value!(line, :name, name)
    set_value!(line, :available, available)
    set_value!(line, :active_power_flow, get(d, "pf", 0.0) * sys_mbase, "MW")
    set_value!(line, :reactive_power_flow, get(d, "qf", 0.0) * sys_mbase, "MVAr")
    set_value!(line, :arc, arc_id)
    set_value!(line, :r, d["br_r"], "pu")
    set_value!(line, :x, d["br_x"], "pu")
    set_value!(line, :base_power, sys_mbase, "MVA")
    set_value!(line, :b, (from = d["b_fr"], to = d["b_to"]), "pu")
    set_value!(line, :rating, _get_rating(name, d, "rate_a") * sys_mbase, "MVA")
    set_optional_value!(line, :rating_b,
        _natural_value(_get_rating(name, d, "rate_b"), sys_mbase), "MVA")
    set_optional_value!(line, :rating_c,
        _natural_value(_get_rating(name, d, "rate_c"), sys_mbase), "MVA")
    set_value!(line, :angle_limits, (min = d["angmin"], max = d["angmax"]), "rad")
    add_component!(sys, line)
    set_component_ext!(sys, line, get(d, "ext", Dict{String, Any}()))
    return
end

"""A zero-impedance pm branch, converted to a `DiscreteControlledACBranch` of type
`SWITCH`. Ported from PSCB's `_make_switch_from_zero_impedance_line` — a
real PSS/E data shape (a modeled switching device recorded as a zero-r/x branch), not one
of the four named bug-compatible sites."""
function make_switch_from_zero_impedance_branch!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    name::AbstractString,
    d::Dict,
    from_id::Int,
    to_id::Int,
    from_isolated::Bool,
    to_isolated::Bool,
    sys_mbase::Float64,
)
    available = _branch_available(d["br_status"] == 1, from_isolated, to_isolated)
    arc_id = add_arc!(sys, from_id, to_id)
    if available
        status = "CLOSED"
    else
        status = "OPEN"
    end
    @warn "Branch $name has zero impedance and available = $available; converting to a DiscreteControlledACBranch of type SWITCH with available = $available and branch_status = $status"

    component = stage(PO.DiscreteControlledACBranch)
    set_value!(component, :id, register!(reg, "DiscreteControlledACBranch", name))
    set_value!(component, :name, name)
    set_value!(component, :available, available)
    set_value!(component, :active_power_flow, get(d, "pf", 0.0) * sys_mbase, "MW")
    set_value!(component, :reactive_power_flow, get(d, "qf", 0.0) * sys_mbase, "MVAr")
    set_value!(component, :arc, arc_id)
    set_value!(component, :base_power, sys_mbase, "MVA")
    set_value!(component, :r, d["br_r"], "pu")
    set_value!(component, :x, d["br_x"], "pu")
    set_value!(component, :rating, _get_rating(name, d, "rate_a") * sys_mbase, "MVA")
    set_value!(component, :discrete_branch_type, "SWITCH")
    set_value!(component, :branch_status, status)
    add_component!(sys, component)
    return
end

function _branch_type_matpower(d::Dict)
    tap = d["tap"]
    shift = d["shift"]
    is_transformer = d["transformer"]
    if !is_transformer
        is_transformer = (!iszero(tap) && tap != 1.0) || !iszero(shift)
    end
    if is_transformer
        return :transformer
    end
    return :line
end

function _branch_type_psse(d::Dict, name::AbstractString)
    # A zero-impedance TRANSFORMER record is still a transformer: only a plain branch
    # with no impedance is the modeled switching device this shortcut is looking for.
    if !d["transformer"] && iszero(d["br_r"]) && iszero(d["br_x"])
        return :switch
    end
    is_transformer = d["transformer"]
    tap = d["tap"]
    if !is_transformer
        if !iszero(tap) && tap != 1.0
            @warn "Transformer $name has tap ratio $tap, which is not 0.0 or 1.0; this is not a valid value for a Line. Parsing entry as a Transformer"
        else
            return :line
        end
    end
    return :transformer
end

"""Two-winding transformer + its `TransformerCircuit`. Ported from PSCB's
`make_transformer_2w`. See the file header for the rating/flow base
(circuit's own `base_power`, not `sys_mbase`) and the magnetizing shunt basis
(`g_fr`/`b_fr` are already device-base pu for PSS/E-origin data; identical to system base
for MATPOWER, where `base_power == sys_mbase` unconditionally)."""
function make_transformer_2w!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    name::AbstractString,
    d::Dict,
    from_id::Int,
    to_id::Int,
    from_isolated::Bool,
    to_isolated::Bool,
)
    available = _branch_available(d["br_status"] == 1, from_isolated, to_isolated)
    base_power = d["base_power"]
    rate_a = _get_rating(name, d, "rate_a")
    rate_b = _get_rating(name, d, "rate_b")
    rate_c = _get_rating(name, d, "rate_c")

    circuit_id = _make_transformer_circuit!(
        sys, reg, d, from_id, to_id, name;
        tap_key = "tap", angle_key = "shift", control_suffix = 1,
        available = available,
        r = d["br_r"], x = d["br_x"],
        rating = _natural_value(rate_a, base_power),
        rating_b = _natural_value(rate_b, base_power),
        rating_c = _natural_value(rate_c, base_power),
        base_power = base_power,
        base_voltage_primary = _base_voltage_or_nothing(d["base_voltage_from"]),
        base_voltage_secondary = _base_voltage_or_nothing(d["base_voltage_to"]),
        active_power_flow = get(d, "pf", 0.0) * base_power,
        reactive_power_flow = get(d, "qf", 0.0) * base_power,
    )

    component = stage(PO.TwoWindingTransformer)
    set_value!(component, :id, register!(reg, "TwoWindingTransformer", name))
    set_value!(component, :name, name)
    set_value!(component, :circuit, circuit_id)
    set_value!(component, :admittance_units, "COMPONENT_BASE")
    set_value!(component, :magnetizing_shunt, (real = d["g_fr"], imag = d["b_fr"]), "pu")
    add_component!(sys, component)
    set_component_ext!(sys, component, get(d, "ext", Dict{String, Any}()))
    return
end

"""Three-winding transformer + its three `TransformerCircuit`s (each connecting a
terminal bus to the star bus).
Per the file header, `rating_primary`/`active_power_flow_primary`/... are already natural
units (unlike the 2W path) and are used directly, with no scaling."""
function make_3w_transformer!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    name::AbstractString,
    d::Dict,
    primary_id::Int,
    secondary_id::Int,
    tertiary_id::Int,
    star_id::Int,
)
    primary_circuit = _make_transformer_circuit!(
        sys, reg, d, primary_id, star_id, name;
        tap_key = "primary_turns_ratio", angle_key = "primary_phase_shift_angle",
        control_suffix = 1,
        available = Bool(d["available_primary"]),
        r = d["r_primary"], x = d["x_primary"],
        rating = _get_rating(name, d, "rating_primary"), rating_b = nothing,
        rating_c = nothing,
        base_power = d["base_power_12"],
        base_voltage_primary = d["base_voltage_primary"],
        base_voltage_secondary = d["base_voltage_primary"],
        active_power_flow = d["active_power_flow_primary"],
        reactive_power_flow = d["reactive_power_flow_primary"],
    )
    secondary_circuit = _make_transformer_circuit!(
        sys, reg, d, secondary_id, star_id, name;
        tap_key = "secondary_turns_ratio", angle_key = "secondary_phase_shift_angle",
        control_suffix = 2,
        available = Bool(d["available_secondary"]),
        r = d["r_secondary"], x = d["x_secondary"],
        rating = _get_rating(name, d, "rating_secondary"), rating_b = nothing,
        rating_c = nothing,
        base_power = d["base_power_23"],
        base_voltage_primary = d["base_voltage_secondary"],
        base_voltage_secondary = d["base_voltage_secondary"],
        active_power_flow = d["active_power_flow_secondary"],
        reactive_power_flow = d["reactive_power_flow_secondary"],
    )
    tertiary_circuit = _make_transformer_circuit!(
        sys, reg, d, tertiary_id, star_id, name;
        tap_key = "tertiary_turns_ratio", angle_key = "tertiary_phase_shift_angle",
        control_suffix = 3,
        available = Bool(d["available_tertiary"]),
        r = d["r_tertiary"], x = d["x_tertiary"],
        rating = _get_rating(name, d, "rating_tertiary"), rating_b = nothing,
        rating_c = nothing,
        base_power = d["base_power_31"],
        base_voltage_primary = d["base_voltage_tertiary"],
        base_voltage_secondary = d["base_voltage_tertiary"],
        active_power_flow = d["active_power_flow_tertiary"],
        reactive_power_flow = d["reactive_power_flow_tertiary"],
    )

    component = stage(PO.ThreeWindingTransformer)
    set_value!(component, :id, register!(reg, "ThreeWindingTransformer", name))
    set_value!(component, :name, name)
    set_value!(component, :primary_circuit, primary_circuit)
    set_value!(component, :secondary_circuit, secondary_circuit)
    set_value!(component, :tertiary_circuit, tertiary_circuit)
    set_value!(component, :star_bus, star_id)
    set_value!(component, :parameter_units, "COMPONENT_BASE")
    set_value!(component, :r_12, d["r_12"], "pu")
    set_value!(component, :x_12, d["x_12"], "pu")
    set_value!(component, :r_23, d["r_23"], "pu")
    set_value!(component, :x_23, d["x_23"], "pu")
    set_value!(component, :r_31, d["r_31"], "pu")
    set_value!(component, :x_31, d["x_31"], "pu")
    set_value!(component, :base_power_12, d["base_power_12"], "MVA")
    set_value!(component, :base_power_23, d["base_power_23"], "MVA")
    set_value!(component, :base_power_31, d["base_power_31"], "MVA")
    set_value!(component, :admittance_units, "COMPONENT_BASE")
    set_value!(component, :magnetizing_shunt, (real = d["g"], imag = d["b"]), "pu")
    add_component!(sys, component)
    set_component_ext!(sys, component, get(d, "ext", Dict{String, Any}()))
    return
end

"""
Create a `Line`, `TwoWindingTransformer`, or `DiscreteControlledACBranch` per
`data["branch"]` entry. `data["branch"]` carries both untransformed lines and 2W transformers —
PowerModels represents both as "branch" rows, discriminated by `tap`/`shift`/
`"transformer"` (MATPOWER) or by zero impedance / the `"transformer"` flag (PSS/E).
"""
function read_branches!(sys::OpenAPISystem, data::Dict; kwargs...)
    if !haskey(data, "branch")
        return
    end
    reg = get_registry(sys)
    sys_mbase = get_base_power(sys)
    source_type = data["source_type"]
    bus_lookup = _pm_bus_lookup(sys)
    _get_name = get(kwargs, :branch_name_formatter, _get_pm_branch_name)

    for (_, d) in _sorted_pm_entries(data["branch"])
        from_number, to_number = Int(d["f_bus"]), Int(d["t_bus"])
        from_name, from_isolated = bus_lookup[from_number]
        to_name, to_isolated = bus_lookup[to_number]
        from_id = get_bus_id(reg, from_number)
        to_id = get_bus_id(reg, to_number)
        name = String(_get_name(d, from_name, to_name))

        branch_type = if source_type == "matpower"
            _branch_type_matpower(d)
        elseif source_type == "pti"
            _branch_type_psse(d, name)
        else
            throw(IS.DataFormatError("unsupported source_type=$source_type for branch data"))
        end

        if d["transformer"] && branch_type == :line
            throw(
                IS.DataFormatError(
                    "branch data mismatched for $name: transformer=true but detected as a Line",
                ),
            )
        elseif branch_type == :switch
            make_switch_from_zero_impedance_branch!(sys, reg, name, d, from_id, to_id,
                from_isolated, to_isolated, sys_mbase)
        elseif branch_type == :transformer
            if _is_duplicate_branch(reg, "TwoWindingTransformer", name, d)
                continue
            end
            make_transformer_2w!(sys, reg, name, d, from_id, to_id, from_isolated,
                to_isolated)
        elseif branch_type == :line
            make_line!(sys, reg, name, d, from_id, to_id, from_isolated, to_isolated,
                sys_mbase)
        else
            throw(IS.DataFormatError("unsupported branch type $branch_type for $name"))
        end
    end
    return
end

"""
Create one `ThreeWindingTransformer` per `data["3w_transformer"]` entry. Ported from
PSCB's `read_3w_transformer!`. `data["3w_transformer"]`'s star bus is a
regular pm dict bus entry (already an `ACBus` by the time this reader runs, via
`read_bus!`), not created here.
"""
function read_3w_transformers!(sys::OpenAPISystem, data::Dict; kwargs...)
    if !haskey(data, "3w_transformer")
        return
    end
    reg = get_registry(sys)
    bus_lookup = _pm_bus_lookup(sys)
    _get_name = get(kwargs, :xfrm_3w_name_formatter, _get_pm_3w_name)

    for (_, d) in _sorted_pm_entries(data["3w_transformer"])
        primary_number = Int(d["bus_primary"])
        secondary_number = Int(d["bus_secondary"])
        tertiary_number = Int(d["bus_tertiary"])
        star_number = Int(d["star_bus"])
        name = String(
            _get_name(
                d,
                bus_lookup[primary_number][1],
                bus_lookup[secondary_number][1],
                bus_lookup[tertiary_number][1],
            ),
        )
        make_3w_transformer!(
            sys, reg, name, d,
            get_bus_id(reg, primary_number), get_bus_id(reg, secondary_number),
            get_bus_id(reg, tertiary_number), get_bus_id(reg, star_number),
        )
    end
    return
end

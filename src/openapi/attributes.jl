# ImpedanceCorrectionData is a supplemental attribute, not a component: it describes one
# (table, winding) pair and links to whichever TwoWindingTransformer/ThreeWindingTransformer
# references that table via its own `correction_table`/`primary_correction_table`/
# `secondary_correction_table`/`tertiary_correction_table` field.
#
# PSCB's `_impedance_correction_table_lookup` builds exactly ONE `ImpedanceCorrectionData`
# instance per (table_number, winding) pair and reuses it for every transformer that
# references it — verified against the real oracle on `modified_14bus_system.raw`, where
# table 8 is the secondary-winding table of both 3W transformers and the built `System`
# carries 8 attributes for 9 attachments. This reader reproduces that sharing: one
# attribute id per pair, created lazily on first reference, with an extra
# `SupplementalAttributeAssociation` row on every subsequent one.
#
# `data["substation"]` becomes a `Substation` attribute; the RAW's latitude/longitude have
# no schema target and stay in the pm dict.

"""
One piecewise-linear curve and control-mode per impedance-correction table number.
Ported from PSCB's `_impedance_correction_table_lookup`, minus the per-winding
pre-expansion — [`_attach_impedance_correction!`](@ref) does that lazily, only for
(table, winding) pairs a transformer actually references.
"""
function _impedance_correction_curves(data::Dict)
    curves = Dict{Int, Tuple{IC.PiecewiseLinearData, String}}()
    for (_, d) in
        _sorted_pm_entries(get(data, "impedance_correction", Dict{String, Any}()))
        table_number = Int(d["table_number"])
        x = d["tap_or_angle"]
        y = d["scaling_factor"]
        if length(x) != length(y)
            throw(
                IS.DataFormatError(
                    "impedance correction mismatch at table $table_number: " *
                    "tap/angle ($(length(x))) and scaling factor ($(length(y))) count differs.",
                ),
            )
        end
        if length(x) < 2
            @warn "Skipping impedance correction table $table_number: insufficient data points ($(length(x)) < 2)."
            continue
        end
        curve = IC.PiecewiseLinearData(;
            function_type = "PIECEWISE_LINEAR",
            points = [IC.XYCoords(; x = x[i], y = y[i]) for i in eachindex(x)],
        )
        control_mode =
            if PSSE_PARSER_TAP_RATIO_LBOUND <= x[1] <= PSSE_PARSER_TAP_RATIO_UBOUND
                "TAP_RATIO"
            else
                "PHASE_SHIFT_ANGLE"
            end
        curves[table_number] = (curve, control_mode)
    end
    return curves
end

"""The curve field a correction table's control mode selects, with the unit PSS/E states
the table's x axis in: a tap ratio is dimensionless, a phase-shift angle is in degrees
(converted to the schema's radians on write). Exhaustive over the enum."""
function _correction_curve_field(control_mode::AbstractString)
    control_mode == "TAP_RATIO" && return (:tap_ratio_correction_curve, "1")
    control_mode == "PHASE_SHIFT_ANGLE" && return (:phase_angle_correction_curve, "deg")
    throw(IS.DataFormatError("unhandled impedance correction control mode $control_mode"))
end

"""
Build and register a new `ImpedanceCorrectionData` for `(table_number, winding)` and
attach it to `transformer_id` — the first-sighting path for a (table, winding) pair.
Returns the attribute, so later sightings of the same pair associate against it directly
(see [`_attach_impedance_correction!`](@ref)). The table's curve lands on the one field its
control mode selects; the other curve stays absent.
"""
function _new_impedance_correction_attribute!(
    sys::OpenAPISystem,
    curves::Dict{Int, Tuple{IC.PiecewiseLinearData, String}},
    table_number::Int,
    winding::AbstractString,
    transformer_id::Int,
)
    curve, control_mode = curves[table_number]
    attribute = stage(PO.ImpedanceCorrectionData)
    set_value!(attribute, :id, next_id!(get_registry(sys)))
    set_value!(attribute, :table_number, table_number)
    field, x_unit = _correction_curve_field(control_mode)
    set_value!(attribute, field, curve, x_unit)
    set_value!(attribute, :transformer_winding, winding)
    set_value!(attribute, :transformer_control_mode, control_mode)
    add_supplemental_attribute!(sys, attribute, transformer_id)
    return attribute
end

"""
Attach the `ImpedanceCorrectionData` for `(d[table_key], winding)` to `transformer_id`
(a `transformer_type` component: `"TwoWindingTransformer"` or `"ThreeWindingTransformer"`),
if `d[table_key]` names a table `curves` has an entry for. `table_key` absent, or naming
table `0` (PSS/E's "no correction table" default, per `pti.jl`'s TAB1/TAB2/TAB3
defaults), is a no-op — matching PSCB's `_attach_single_ict!`, which only ever finds a
cache hit for a real table number. `cache` remembers the attribute already created for each
`(table_number, winding)` pair, so a pair referenced by more than one transformer gets one
shared attribute and multiple associations — see the file header.
"""
function _attach_impedance_correction!(
    sys::OpenAPISystem,
    cache::Dict{Tuple{Int, String}, Staged{PO.ImpedanceCorrectionData}},
    curves::Dict{Int, Tuple{IC.PiecewiseLinearData, String}},
    d::Dict,
    table_key::AbstractString,
    winding::AbstractString,
    transformer_id::Int,
    transformer_type::AbstractString,
)
    if isempty(curves) || !haskey(d, table_key)
        return
    end
    table_number = Int(d[table_key])
    if !haskey(curves, table_number)
        return
    end
    key = (table_number, winding)
    if haskey(cache, key)
        # The attribute already exists, so only the association row is new.
        add_supplemental_attribute_association!(
            sys, cache[key], transformer_id, transformer_type,
        )
    else
        cache[key] =
            _new_impedance_correction_attribute!(sys, curves, table_number, winding,
                transformer_id)
    end
    return
end

"""
One `Substation` supplemental attribute per `data["substation"]` entry, associated with
every bus its node list places inside the substation. The schema's `Substation` keeps only
the identity and grounding resistance; the node, switching-device and terminal detail stays
in the pm dict, where `read_switch_breaker!` reads the devices it turns into components.
"""
function read_substations!(sys::OpenAPISystem, data::Dict; kwargs...)
    reg = get_registry(sys)
    for (_, d) in _sorted_pm_entries(get(data, "substation", Dict{String, Any}()))
        number = Int(d["number"])
        nodes = get(d, "nodes", Dict{String, Any}[])
        if isempty(nodes)
            throw(
                IS.DataFormatError(
                    "substation $number has no nodes, so it attaches to no bus",
                ),
            )
        end
        bus_ids = unique(get_bus_id(reg, Int(node["bus"])) for node in nodes)
        name = string(d["name"])

        attribute = stage(PO.Substation)
        set_value!(attribute, :id, register!(reg, "Substation", name))
        set_value!(attribute, :name, name)
        set_value!(attribute, :number, number)
        set_value!(attribute, :grounding_resistance, d["grounding_resistance"], "ohm")
        add_supplemental_attribute!(sys, attribute, first(bus_ids))
        for bus_id in Iterators.drop(bus_ids, 1)
            add_supplemental_attribute_association!(sys, attribute, bus_id, "ACBus")
        end
    end
    return
end

"""
Attach `ImpedanceCorrectionData` supplemental attributes to every `TwoWindingTransformer`/
`ThreeWindingTransformer` that references an impedance-correction table. Ported from
PSCB's `_attach_impedance_correction_tables!`, but driven by re-walking
`data["branch"]`/`data["3w_transformer"]` rather than called inline from the transformer
readers — so the name derivation below must match
[`read_branches!`](@ref)/[`read_3w_transformers!`](@ref) exactly, same formatter kwargs
included.
"""
function read_impedance_corrections!(sys::OpenAPISystem, data::Dict; kwargs...)
    curves = _impedance_correction_curves(data)
    if isempty(curves)
        return
    end
    reg = get_registry(sys)
    bus_lookup = _pm_bus_lookup(sys)
    _get_branch_name = get(kwargs, :branch_name_formatter, _get_pm_branch_name)
    _get_3w_name = get(kwargs, :xfrm_3w_name_formatter, _get_pm_3w_name)
    cache = Dict{Tuple{Int, String}, Staged{PO.ImpedanceCorrectionData}}()

    for (_, d) in _sorted_pm_entries(get(data, "branch", Dict{String, Any}()))
        if !haskey(d, "correction_table")
            continue
        end
        from_number, to_number = Int(d["f_bus"]), Int(d["t_bus"])
        from_name, = bus_lookup[from_number]
        to_name, = bus_lookup[to_number]
        name = String(_get_branch_name(d, from_name, to_name))
        transformer_id = get_id(reg, "TwoWindingTransformer", name)
        _attach_impedance_correction!(
            sys, cache, curves, d, "correction_table", "TR2W_WINDING", transformer_id,
            "TwoWindingTransformer",
        )
    end

    for (_, d) in _sorted_pm_entries(get(data, "3w_transformer", Dict{String, Any}()))
        primary_number = Int(d["bus_primary"])
        secondary_number = Int(d["bus_secondary"])
        tertiary_number = Int(d["bus_tertiary"])
        name = String(
            _get_3w_name(
                d,
                bus_lookup[primary_number][1],
                bus_lookup[secondary_number][1],
                bus_lookup[tertiary_number][1],
            ),
        )
        transformer_id = get_id(reg, "ThreeWindingTransformer", name)
        _attach_impedance_correction!(
            sys, cache, curves, d, "primary_correction_table", "PRIMARY_WINDING",
            transformer_id, "ThreeWindingTransformer",
        )
        _attach_impedance_correction!(
            sys, cache, curves, d, "secondary_correction_table", "SECONDARY_WINDING",
            transformer_id, "ThreeWindingTransformer",
        )
        _attach_impedance_correction!(
            sys, cache, curves, d, "tertiary_correction_table", "TERTIARY_WINDING",
            transformer_id, "ThreeWindingTransformer",
        )
    end
    return
end

"""
The supplemental-attribute stage: every attribute type this parser emits, in one place.
Runs after the component readers, since each attribute associates against a component id.
"""
function read_attributes!(sys::OpenAPISystem, data::Dict; kwargs...)
    read_substations!(sys, data; kwargs...)
    read_impedance_corrections!(sys, data; kwargs...)
    return
end

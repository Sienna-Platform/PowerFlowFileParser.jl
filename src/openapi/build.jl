"""
pm dict section names `build_openapi_system` fully consumes.

This tracks whether a section is *read*, not whether every row becomes a component:
`"load"`/`"distributed_generation"` are listed even though an unmatched
distributed-generation entry is an error, and `"area_interchange"` is folded into each
`Area`'s `ext` rather than emitted as its own component.
"""
const _CONSUMED_PM_SECTIONS = (
    "bus", "load", "distributed_generation", "gen", "storage",
    "branch", "3w_transformer", "dcline", "vscline", "interarea_transfer",
    "shunt", "switched_shunt", "facts",
    "switch", "breaker", "generic_connector", "impedance_correction",
    "area_interchange", "substation",
)

"""
pm dict sections `build_openapi_system` deliberately does not read, each with the reason
it is safe to ignore rather than a tracked gap. The only sanctioned form of silent skip.
"""
const KNOWN_UNCONSUMED_PM_SECTIONS = Dict(
    "areas" =>
        "MATPOWER's native `mpc.areas` table; PSCB's own `read_area!` for it is commented out " *
        "(\"not all matpower files define areas even when bus definitions contain area " *
        "references\") — the oracle itself never consumes this section.",
    "owner" =>
        "PSS/E OWNER records (generator/branch ownership shares); PSCB's oracle never reads " *
        "this section and no PSY/schema field represents ownership.",
    "zone" =>
        "PSS/E ZONE name records; PSCB's oracle only cross-checks it for an empty-zone " *
        "warning (`read_loadzones!`) — LoadZone identity and peaks come from each bus's own " *
        "`zone` number, never from this section's `zone_name`.",
)

"""
Error, naming every non-empty pm dict section [`build_openapi_system`](@ref) neither
reads nor has allow-listed, so a document missing whole categories of components is never
mistaken for a complete one. Scalar keys (`baseMVA`, `source_type`, ...) are excluded by
the `AbstractDict` test rather than by an explicit list.
"""
function _check_unconsumed_sections(data::Dict)
    unconsumed = Tuple{String, Int}[]
    for (key, value) in data
        if key in _CONSUMED_PM_SECTIONS || haskey(KNOWN_UNCONSUMED_PM_SECTIONS, key) ||
           !(value isa AbstractDict) || isempty(value)
            continue
        end
        push!(unconsumed, (String(key), length(value)))
    end
    if isempty(unconsumed)
        return
    end
    sort!(unconsumed; by = first)
    named = join(("$key ($count)" for (key, count) in unconsumed), ", ")
    throw(
        IS.DataFormatError(
            "build_openapi_system cannot read $(length(unconsumed)) non-empty pm dict " *
            "section(s), and none is on KNOWN_UNCONSUMED_PM_SECTIONS: $named",
        ),
    )
end

"""
Members of one bus's sharing group: a two-terminal line contributes at most one converter,
since one attribute attaches to a component once; a second converter of the same line on
the same bus is reported and left out.
"""
function _sharing_members(members::Vector{VoltageControlMember}, bus_number::Int)
    kept = VoltageControlMember[]
    seen = Set{Int}()
    for member in members
        if member.component_id in seen
            @warn "both converters of $(member.component_type) id=$(member.component_id) regulate bus $bus_number; only the first joins the bus's ReactivePowerSharing group"
            continue
        end
        push!(seen, member.component_id)
        push!(kept, member)
    end
    return kept
end

"""
One `ReactivePowerSharing` attribute per bus that two or more setpoint devices hold, from the
members every device reader recorded (`record_voltage_control_member!`): the attribute is
associated with each member and one `voltage_control_associations` row carries the member's
weight (PSS/E RMPCT / 100) and, for a VSC converter, its terminal. A bus with a single device
gets no group. Runs after every device reader, so the members are complete.
"""
function read_voltage_control!(sys::OpenAPISystem, data::Dict; kwargs...)
    reg = get_registry(sys)
    by_bus = Dict{Int, Vector{VoltageControlMember}}()
    for member in sys.voltage_control_members
        push!(get!(by_bus, member.bus_number, VoltageControlMember[]), member)
    end
    for bus_number in sort!(collect(keys(by_bus)))
        members = _sharing_members(by_bus[bus_number], bus_number)
        length(members) >= 2 || continue
        name = "bus$(bus_number)_reactive_power_sharing"
        attribute = stage(PO.ReactivePowerSharing)
        control_id = register!(reg, "ReactivePowerSharing", name)
        set_value!(attribute, :id, control_id)
        set_value!(attribute, :name, name)
        add_supplemental_attribute!(sys, attribute, first(members).component_id)
        for member in members[2:end]
            add_supplemental_attribute_association!(
                sys, attribute, member.component_id, member.component_type,
            )
        end
        for member in members
            add_voltage_control_association!(
                sys, control_id, member.component_id, member.weight, member.terminal,
            )
        end
    end
    return
end

"""
Assemble an `OpenAPISystem` from `pm_data`.

Reader order is a dependency order: load zones before buses, buses before every reader
that resolves a bus by id, and [`read_attributes!`](@ref) last since it looks up
already-registered transformer ids by name. Before returning, errors on every non-empty
pm dict section no reader touched and `KNOWN_UNCONSUMED_PM_SECTIONS` does not excuse, so
a caller never mistakes a partial document for a complete one.

`power_units` selects the convention the values are stored in, same as
[`OpenAPISystem`](@ref): `"NATURAL_UNITS"` (the default) leaves every reader's MW/MVAr/MVA
values as computed; `"COMPONENT_BASE"` additionally runs [`apply_device_base_conversion!`](@ref)
over the built document, converting every power-family field into per-unit on the
component's own device base (or the system base, for the few types with none of their own) —
the document PowerSystems' `ComponentBaseUnit` importer expects. Keyword arguments — the
`*_name_formatter`s the PSS/E metadata reimport path needs — are threaded through to every
reader unconsumed.
"""
function build_openapi_system(
    pm_data::PowerModelsData;
    power_units::AbstractString = "NATURAL_UNITS",
    kwargs...,
)
    data = pm_data.data
    if isempty(data["bus"])
        throw(IS.DataFormatError("pm_data has no buses"))
    end
    sys = OpenAPISystem(Float64(data["baseMVA"]); power_units = power_units)

    read_loadzones!(sys, data; kwargs...)
    read_bus!(sys, data; kwargs...)
    read_loads!(sys, data; kwargs...)
    read_generation!(sys, data; kwargs...)
    read_branches!(sys, data; kwargs...)
    read_3w_transformers!(sys, data; kwargs...)
    read_switch_breaker!(sys, data; kwargs...)
    read_dc_branches!(sys, data; kwargs...)
    read_shunts!(sys, data; kwargs...)
    read_voltage_control!(sys, data; kwargs...)
    read_attributes!(sys, data; kwargs...)
    apply_device_base_conversion!(sys)

    _check_unconsumed_sections(data)
    return sys
end

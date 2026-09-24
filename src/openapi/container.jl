"""
One setpoint voltage regulating device, or one converter of a two-terminal line, recorded
while its component is built so [`read_voltage_control!`](@ref) can group the devices that
hold one bus into a `ReactivePowerSharing` attribute afterwards.
"""
struct VoltageControlMember
    "PSS/E number of the bus the device resolves to"
    bus_number::Int
    component_id::Int
    component_type::String
    "positive relative reactive power share (PSS/E RMPCT / 100)"
    weight::Float64
    "converter of a two-terminal member (\"FROM\"/\"TO\"), `nothing` for a single-bus device"
    terminal::Union{Nothing, String}
end

"""
The document PowerFlowFileParser emits, a thin wrapper over `PD.SystemDocument`.

`document` carries the components, the association tables, and `ext`. `base_power`
is the system MVA base pm dict readers scale against; it is not part of the
serialized document — each component states its own `base_power`. `power_units` is
this run's chosen basis, stamped onto every emitted component whose PO type declares
the field (see [`add_component!`](@ref)); it too is not carried on the document
itself. `registry` is build-time scaffolding, holding only the lookup indices (by
name, bus number, arc) the document has no use for once built.

`time_series` mirrors PowerTableDataParser's field shape for a consistent
`OpenAPISystem` API across parsers, but stays permanently empty here — PSS/E and
Matpower carry no time series.
"""
struct OpenAPISystem
    document::PD.SystemDocument
    registry::IdRegistry
    time_series::Vector{IS.TimeSeriesData}
    base_power::Float64
    power_units::String
    "setpoint devices by build order, grouped into sharing attributes at the end of the build"
    voltage_control_members::Vector{VoltageControlMember}
    "PSS/E (I, J, CKT) of every two-winding transformer built, for the DC-line tap references"
    psse_transformer_ids::Dict{Tuple{Int, Int, String}, Int}
end

"""
Unit conventions a component's `power_units` field may take, from the schemas' enum.

The schemas offer no system-base option: per-unit data historically on the system
base records that base in the component's own `base_power` and rides as
`COMPONENT_BASE`.
"""
const UNIT_SYSTEMS = ("NATURAL_UNITS", "COMPONENT_BASE")

function OpenAPISystem(
    base_power::Float64;
    power_units::AbstractString = "NATURAL_UNITS",
)
    if !(power_units in UNIT_SYSTEMS)
        throw(
            IS.DataFormatError(
                "power_units must be one of $(join(UNIT_SYSTEMS, ", ")); got $power_units",
            ),
        )
    end
    document = PD.SystemDocument()
    return OpenAPISystem(
        document,
        IdRegistry(document),
        Vector{IS.TimeSeriesData}(),
        base_power,
        String(power_units),
        VoltageControlMember[],
        Dict{Tuple{Int, Int, String}, Int}(),
    )
end

"""
Remember that `component` (a staged device) regulates the voltage at PSS/E bus `bus_number`
to a setpoint with relative share `weight`; `terminal` names the converter of a two-terminal
member. Read back by [`read_voltage_control!`](@ref).
"""
function record_voltage_control_member!(
    sys::OpenAPISystem,
    bus_number::Int,
    component::Staged{T},
    weight::Float64;
    terminal::Union{Nothing, String} = nothing,
) where {T}
    push!(
        sys.voltage_control_members,
        VoltageControlMember(
            bus_number,
            get_value(component, :id),
            string(nameof(T)),
            weight,
            terminal,
        ),
    )
    return
end

"""
Remember the document id of the two-winding transformer built from pm dict entry `d`, under
its PSS/E `(I, J, CKT)` identity, so a DC line's `IFR`/`ITR`/`IDR` can name it. A Matpower
branch carries no PSS/E identity and is not recorded.
"""
function record_psse_transformer!(sys::OpenAPISystem, d::Dict, id::Int)
    source_id = get(d, "source_id", nothing)
    if isnothing(source_id) || first(source_id) != "transformer" || length(source_id) < 5
        return
    end
    sys.psse_transformer_ids[(
        Int(source_id[2]),
        Int(source_id[3]),
        strip(String(source_id[5])),
    )] =
        id
    return
end

"""
The document id of the two-winding transformer PSS/E names by `(I, J, CKT)`, in either bus
order, or `nothing` when `I` is 0 (no transformer named). Throws when the transformer was
never built.
"""
function _psse_transformer_id(sys::OpenAPISystem, spec, owner::AbstractString)
    from_number, to_number, ckt = Int(spec[1]), Int(spec[2]), String(spec[3])
    iszero(from_number) && return nothing
    ids = sys.psse_transformer_ids
    for key in ((from_number, to_number, ckt), (to_number, from_number, ckt))
        haskey(ids, key) && return ids[key]
    end
    throw(
        IS.DataFormatError(
            "$owner names transformer $from_number-$to_number circuit '$ckt', which the " *
            "TRANSFORMER data does not define as a two-winding transformer",
        ),
    )
end

get_document(sys::OpenAPISystem) = sys.document

"""
Record the table columns the data model has no field for, against a component.

Kept beside the components rather than inside them: the schemas describe what a
component is, and this is whatever else the source data happened to state.
"""
function set_ext!(sys::OpenAPISystem, component_id::Int, extras::Dict{String, Any})
    PD.set_ext!(get_document(sys), component_id, extras)
    return
end

"""
Record `extras` against `component`, skipping the `ext` entry entirely when there is
nothing to record. The shape every reader uses for a pm dict entry's own `"ext"` blob.
"""
function set_component_ext!(sys::OpenAPISystem, component, extras::Dict{String, Any})
    if !isempty(extras)
        set_ext!(sys, get_value(component, :id), extras)
    end
    return
end

get_ext(sys::OpenAPISystem, component_id::Int) = PD.get_ext(get_document(sys), component_id)

get_base_power(sys::OpenAPISystem) = sys.base_power
get_registry(sys::OpenAPISystem) = sys.registry

get_power_units(sys::OpenAPISystem) = sys.power_units

"""
Whether values are stored per unit rather than in the schemas' natural units.

`COMPONENT_BASE` reproduces PowerSystems' storage convention. The `x-unit` annotations
still name the natural unit either way, so a per-unit document is for comparison
against PowerSystems rather than for a consumer that reads the annotations — which is
why each component states the convention it was written in.
"""
uses_per_unit(sys::OpenAPISystem) = sys.power_units == "COMPONENT_BASE"

"""
Materialize `staged` into the document, first stamping this run's `power_units` onto it when
its PO type declares the field — the per-component wire-contract requirement every
power-bearing type carries (a component with none, e.g. a pure topology row, is
untouched).
"""
function add_component!(sys::OpenAPISystem, staged::Staged{T}) where {T <: IC.APIModel}
    if hasfield(T, :power_units)
        set_value!(staged, :power_units, sys.power_units)
    end
    PD.add_component!(get_document(sys), materialize(staged))
    return
end

"""
Record a supplemental attribute and the component it describes.

Plant-family groupings and service memberships are recorded in their own tables, not this
one — see `add_service_association!` below — so this parser only ever emits a plain
attribute row. `component_id`'s type name is resolved from the document itself, so the
caller need not know it.
"""
function add_supplemental_attribute!(
    sys::OpenAPISystem,
    attribute::Staged,
    component_id::Int,
)
    PD.add_supplemental_attribute!(get_document(sys), materialize(attribute), component_id)
    return
end

"""
Describe `component_id` with an attribute [`add_supplemental_attribute!`](@ref) already
recorded — one attribute shared across several components takes one row per extra
component.

`component_type` names `component_id`'s type (e.g. `"ACBus"`); unlike
[`add_supplemental_attribute!`](@ref), which resolves it by scanning the document for the
first component, the caller passes it directly here since it already knows it from having
looked `component_id` up.

`attribute_type` is derived from the attribute rather than passed in, matching what
`add_supplemental_attribute!` writes for the first component; a literal would let the two
disagree.
"""
function add_supplemental_attribute_association!(
    sys::OpenAPISystem,
    attribute::Staged{T},
    component_id::Int,
    component_type::AbstractString,
) where {T}
    push!(
        get_document(sys).supplemental_attribute_associations,
        IC.SupplementalAttributeAssociation(;
            component_id = component_id,
            component_type = String(component_type),
            attribute_id = get_value(attribute, :id),
            attribute_type = string(nameof(T)),
        ),
    )
    return
end

"""
Record that `entity_id` contributes to the service `service_id`.

A membership is a row in the dedicated `service_associations` table: `entity_id` may name
a Device, a Branch (TransmissionInterface), or another Service (GroupReserve), so no
member-type discriminator is needed.

Duplicate pairs are rejected rather than collapsed: eligibility rules overlap, so the
same device matching one reserve twice means a malformed rule set.
"""
function add_service_association!(
    sys::OpenAPISystem,
    service_id::Int,
    entity_id::Int,
)
    associations = get_document(sys).service_associations
    for existing in associations
        if get_value(existing, :service_id) == service_id &&
           get_value(existing, :entity_id) == entity_id
            throw(
                IS.DataFormatError(
                    "duplicate service membership: service_id=$service_id entity_id=$entity_id",
                ),
            )
        end
    end
    push!(
        associations,
        PO.ServiceAssociation(; service_id = service_id, entity_id = entity_id),
    )
    return
end

"""
Record that `entity_id`, or its `terminal` converter, is a member of the voltage control group
`control_id` with relative reactive power `weight` — one `voltage_control_associations` row.
"""
function add_voltage_control_association!(
    sys::OpenAPISystem,
    control_id::Int,
    entity_id::Int,
    weight::Float64,
    terminal::Union{Nothing, String},
)
    terminal_value = if isnothing(terminal)
        nothing
    else
        PO.VoltageControlTerminal(terminal)
    end
    PD.add_voltage_control_association!(
        get_document(sys),
        PO.VoltageControlAssociation(;
            control_id = control_id,
            entity_id = entity_id,
            weight = weight,
            terminal = terminal_value,
        ),
    )
    return
end

"""Attributes of one type, in the order they were added."""
function get_supplemental_attributes(sys::OpenAPISystem, type_name::AbstractString)
    return PD.get_supplemental_attributes(get_document(sys), type_name)
end

function get_components(sys::OpenAPISystem, type_name::AbstractString)
    return PD.get_components(get_document(sys), type_name)
end

"""Type names in sorted order, so serialized output is deterministic."""
component_type_names(sys::OpenAPISystem) = PD.component_type_names(get_document(sys))

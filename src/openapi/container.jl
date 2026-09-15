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

"""Attributes of one type, in the order they were added."""
function get_supplemental_attributes(sys::OpenAPISystem, type_name::AbstractString)
    return PD.get_supplemental_attributes(get_document(sys), type_name)
end

function get_components(sys::OpenAPISystem, type_name::AbstractString)
    return PD.get_components(get_document(sys), type_name)
end

"""Type names in sorted order, so serialized output is deterministic."""
component_type_names(sys::OpenAPISystem) = PD.component_type_names(get_document(sys))

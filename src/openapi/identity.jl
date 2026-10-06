"""
Allocates component ids and resolves the cross-references found in a PowerModels dict.

The schemas link components by integer id, but the pm dict links them other ways: by
bus number (`branch["f_bus"]`), by component name, and by area or zone number. This
translates those.

Ids come from a single counter shared by every type, matching GridDB's `entities` table
where an id identifies a component without also needing its type. This is why a bus
number cannot double as an id.

Id allocation is delegated to `document` rather than kept in a second counter that could
drift from the document's own. Not serialized: every lookup index here is recoverable
from the emitted document.
"""
struct IdRegistry
    document::PC.SystemDocument
    by_name::Dict{Tuple{String, String}, Int}
    by_bus_number::Dict{Int, Int}
    arcs::Dict{Tuple{Int, Int}, Int}
end

function IdRegistry(document::PC.SystemDocument)
    return IdRegistry(
        document,
        Dict{Tuple{String, String}, Int}(),
        Dict{Int, Int}(),
        Dict{Tuple{Int, Int}, Int}(),
    )
end

"""Allocate an id without associating it with a name. For types the schemas give
no `name` field, such as `Arc`."""
function next_id!(reg::IdRegistry)
    return PC.next_id!(reg.document)
end

"""Allocate an id for `name` within `type_name`. Throws if that pair is taken."""
function register!(reg::IdRegistry, type_name::AbstractString, name::AbstractString)
    key = (String(type_name), String(name))
    if haskey(reg.by_name, key)
        throw(
            IS.DataFormatError(
                "duplicate component: type=$type_name name=$name already has id=$(reg.by_name[key])",
            ),
        )
    end
    id = next_id!(reg)
    reg.by_name[key] = id
    return id
end

"""Register a bus under both its name and its pm dict bus number."""
function register_bus!(reg::IdRegistry, number::Int, name::AbstractString)
    if haskey(reg.by_bus_number, number)
        throw(
            IS.DataFormatError(
                "duplicate bus number=$number already has id=$(reg.by_bus_number[number])",
            ),
        )
    end
    id = register!(reg, "ACBus", name)
    reg.by_bus_number[number] = id
    return id
end

function has_id(reg::IdRegistry, type_name::AbstractString, name::AbstractString)
    return haskey(reg.by_name, (String(type_name), String(name)))
end

function get_id(reg::IdRegistry, type_name::AbstractString, name::AbstractString)
    key = (String(type_name), String(name))
    if !haskey(reg.by_name, key)
        throw(IS.DataFormatError("unknown component: type=$type_name name=$name"))
    end
    return reg.by_name[key]
end

has_bus_id(reg::IdRegistry, number::Int) = haskey(reg.by_bus_number, number)

function get_bus_id(reg::IdRegistry, number::Int)
    if !haskey(reg.by_bus_number, number)
        throw(IS.DataFormatError("unknown bus number=$number"))
    end
    return reg.by_bus_number[number]
end

"""
Return the id of the arc between two buses and whether it was created here.

Keyed on the ordered pair so parallel circuits share one `Arc`: PSS/E allows several
`CKT`s on the same bus pair.
"""
function arc_id!(reg::IdRegistry, from_id::Int, to_id::Int)
    key = (from_id, to_id)
    if haskey(reg.arcs, key)
        return reg.arcs[key], false
    end
    id = next_id!(reg)
    reg.arcs[key] = id
    return id, true
end

"""
Resolve a bare name to `(type_name, id)`, searching only `type_names`.

A name alone is not unique across every component type: an area and a load zone can
share the same pm dict number, and PSS/E allows a bus and a load to share a name.
"""
function find_by_name(reg::IdRegistry, type_names, name::AbstractString)
    matches = Tuple{String, Int}[]
    for type_name in type_names
        key = (String(type_name), String(name))
        if haskey(reg.by_name, key)
            push!(matches, (String(type_name), reg.by_name[key]))
        end
    end
    if isempty(matches)
        throw(
            IS.DataFormatError(
                "no component named $name among types [$(join(type_names, ", "))]",
            ),
        )
    end
    if length(matches) > 1
        found = join([m[1] for m in matches], ", ")
        throw(IS.DataFormatError("ambiguous name=$name matches types [$found]"))
    end
    return matches[1]
end

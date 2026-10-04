const _Target = Tuple{String, String}

_sid_bus(bus::Integer) = Int(bus)
_sid_bus(bus::AbstractString) = parse(Int, bus)

_pair(a::Integer, b::Integer) = (Int(min(a, b)), Int(max(a, b)))

function _triple(a::Integer, b::Integer, c::Integer)
    s = sort([Int(a), Int(b), Int(c)])
    return (s[1], s[2], s[3])
end

# A transformer's source_id carries a winding-3 bus slot, so its circuit sits one place later.
function _branch_ckt(sid::Vector)
    if sid[1] == "transformer"
        return _segment_ckt(sid[5])
    end
    return _segment_ckt(sid[4])
end

function _index_add!(index::Dict, key, target)
    push!(get!(index, key, valtype(index)()), target)
    return
end

"""
Lookup tables from the identity a `.con` record names to PM-dict `(section, key)` targets,
built once from `source_id` (the RAW's own bus numbers, correct under node-breaker routing).
Every value is a vector so duplicate identities surface as ambiguity instead of overwriting.
"""
struct _PsseIndex
    branch::Dict{Tuple{Tuple{Int, Int}, String}, Vector{_Target}}
    transformer3w::Dict{Tuple{NTuple{3, Int}, String}, Vector{_Target}}
    gen::Dict{Tuple{Int, String}, Vector{_Target}}
    load::Dict{Tuple{Int, String}, Vector{_Target}}
    shunt::Dict{Tuple{Int, String}, Vector{_Target}}
    switched_shunt::Dict{Tuple{Int, String}, Vector{_Target}}
    bus::Dict{Int, Int}
    multisection::Dict{Tuple{Tuple{Int, Int}, String}, Vector{Vector{_Target}}}
end

function _PsseIndex(pm::Dict)
    empty = Dict{String, Any}()
    index = _PsseIndex(
        Dict(),
        Dict(),
        Dict(),
        Dict(),
        Dict(),
        Dict(),
        Dict(),
        Dict(),
    )
    for section in ("branch", "switch", "breaker", "generic_connector")
        for (key, e) in get(pm, section, empty)
            sid = e["source_id"]
            _index_add!(
                index.branch,
                (_pair(sid[2], sid[3]), _branch_ckt(sid)),
                (section, key),
            )
        end
    end
    for (key, e) in get(pm, "3w_transformer", empty)
        sid = e["source_id"]
        _index_add!(
            index.transformer3w,
            (_triple(sid[2], sid[3], sid[4]), _segment_ckt(sid[5])),
            ("3w_transformer", key),
        )
    end
    for (section, table) in (
        ("gen", index.gen),
        ("load", index.load),
        ("shunt", index.shunt),
    )
        for (key, e) in get(pm, section, empty)
            sid = e["source_id"]
            _index_add!(table, (_sid_bus(sid[2]), _segment_ckt(sid[3])), (section, key))
        end
    end
    for (key, e) in get(pm, "switched_shunt", empty)
        sid = e["source_id"]
        _index_add!(
            index.switched_shunt,
            (_sid_bus(sid[2]), _segment_ckt(get(e, "sw_id", "1"))),
            ("switched_shunt", key),
        )
    end
    for (key, e) in get(pm, "bus", empty)
        index.bus[_sid_bus(e["source_id"][2])] = key
    end
    for e in values(get(pm, "multisection_line", empty))
        sid = e["source_id"]
        _index_add!(
            index.multisection,
            (_pair(sid[2], sid[3]), _segment_ckt(sid[4])),
            [(String(s[1]), String(s[2])) for s in e["segments"]],
        )
    end
    return index
end

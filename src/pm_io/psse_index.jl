const _Target = Tuple{String, String}

_sid_bus(bus::Integer) = Int(bus)
_sid_bus(bus::AbstractString) = parse(Int, bus)

_pair(a::Integer, b::Integer) = (Int(min(a, b)), Int(max(a, b)))

function _triple(a::Integer, b::Integer, c::Integer)
    s = sort([Int(a), Int(b), Int(c)])
    return (s[1], s[2], s[3])
end

# The source_id of a transformer has a winding-3 bus slot, so its circuit is one place later.
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
Lookup tables from the identity that a `.con` record names to PM-dict `(section, key)` targets.
The constructor builds the tables once from `source_id`. That field has the bus numbers of the
RAW, which stay correct under node-breaker routing. Every value is a vector, so a duplicate
identity gives an ambiguity and does not overwrite an entry.
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
    attached::Dict{Int, Vector{_Target}}
    blocking::Dict{Int, String}
end

# In-service branch-like elements, injectors, DC lines and FACTS devices, by RAW bus number.
# A bus outage removes them.
const _ATTACHED_BRANCH_SECTIONS = ("branch", "switch", "breaker", "generic_connector")
const _ATTACHED_INJECTOR_SECTIONS = ("gen", "load", "shunt", "switched_shunt")

function _in_service(e::Dict, section::String)
    return !iszero(e[_CON_STATUS_KEY[section]])
end

function _raw_bus(pm::Dict, key::Integer)
    return _sid_bus(pm["bus"][key]["source_id"][2])
end

function _facts_buses(pm::Dict, e::Dict)
    buses = [_raw_bus(pm, e["bus"])]
    if !iszero(e["tbus"])
        push!(buses, _raw_bus(pm, e["tbus"]))
    end
    return buses
end

function _index_attached!(index::_PsseIndex, pm::Dict)
    empty = Dict{String, Any}()
    for section in _ATTACHED_BRANCH_SECTIONS
        for (key, e) in get(pm, section, empty)
            if _in_service(e, section)
                sid = e["source_id"]
                for bus in (_sid_bus(sid[2]), _sid_bus(sid[3]))
                    _index_add!(index.attached, bus, (section, key))
                end
            end
        end
    end
    for section in _ATTACHED_INJECTOR_SECTIONS
        for (key, e) in get(pm, section, empty)
            if _in_service(e, section)
                _index_add!(index.attached, _sid_bus(e["source_id"][2]), (section, key))
            end
        end
    end
    for e in values(get(pm, "3w_transformer", empty))
        if _in_service(e, "3w_transformer")
            for bus in e["source_id"][2:4]
                get!(index.blocking, _sid_bus(bus), "a three-winding transformer")
            end
        end
    end
    for section in ("dcline", "vscline")
        for (key, e) in get(pm, section, empty)
            if _in_service(e, section)
                for bus in unique((_raw_bus(pm, e["f_bus"]), _raw_bus(pm, e["t_bus"])))
                    _index_add!(index.attached, bus, (section, key))
                end
            end
        end
    end
    for (key, e) in get(pm, "facts", empty)
        if _in_service(e, "facts")
            for bus in unique(_facts_buses(pm, e))
                _index_add!(index.attached, bus, ("facts", key))
            end
        end
    end
    return
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
        Dict(),
        Dict(),
    )
    for section in _ATTACHED_BRANCH_SECTIONS
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
    _index_attached!(index, pm)
    return index
end

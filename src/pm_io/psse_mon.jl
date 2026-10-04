const _MON_FLOAT = r"^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$"
const _SUB_FIELDS = Dict("AREA" => "area", "ZONE" => "zone", "OWNER" => "owner")
const _MON_BRANCH_SECTIONS =
    (("branch", 2), ("switch", 2), ("breaker", 2), ("generic_connector", 2),
        ("3w_transformer", 3))

_is_uint(t::String) = !isempty(t) && all(isdigit, t)

function _mon_warn(path::String, n::Int, text::String, reason::String)
    @warn "Skipping record ($path line $n): $reason: `$text`"
    return
end

# RAW bus number => PM bus key; star and node buses carry another source_id.
function _raw_buses(pm::Dict)
    out = Dict{Int, Int}()
    for (key, b) in get(pm, "bus", Dict())
        sid = b["source_id"]
        if first(sid) == "bus"
            out[_sid_bus(sid[2])] = key
        end
    end
    return out
end

# Returns (raw bus numbers, reason); reason is empty when the selector resolves.
function _sub_selector(pm::Dict, raw::Dict{Int, Int}, toks::Vector{String})
    head = first(toks)
    args = toks[2:end]
    none = Set{Int}()
    if haskey(_SUB_FIELDS, head) && !isempty(args) && all(_is_uint, args)
        field = _SUB_FIELDS[head]
        wanted = parse.(Int, args)
        hit = Set{Int}()
        for n in wanted
            found = false
            for (num, key) in raw
                b = pm["bus"][key]
                if haskey(b, field) && b[field] == n
                    push!(hit, num)
                    found = true
                end
            end
            if !found
                return none, "no bus in $head $n"
            end
        end
        return hit, ""
    elseif head == "BUS" && !isempty(args) && all(_is_uint, args)
        wanted = parse.(Int, args)
        for n in wanted
            if !haskey(raw, n)
                return none, "no bus $n in the RAW"
            end
        end
        return Set(wanted), ""
    elseif head == "KVRANGE" && length(args) == 2 && all(t -> occursin(_MON_FLOAT, t), args)
        lo, hi = parse.(Float64, args)
        return Set(num for (num, key) in raw if lo <= pm["bus"][key]["base_kv"] <= hi), ""
    end
    return none, "unsupported subsystem record"
end

# Subsystem name => RAW bus numbers. A plain block unions its selectors; a nested JOIN ... END
# intersects its own, and joins union into the subsystem like any other selector.
function _read_subsystems(pm::Dict, raw::Dict{Int, Int}, sub_path::String)
    subs = Dict{String, Set{Int}}()
    if isempty(sub_path)
        return subs
    end
    name = ""
    block_line = 0
    in_block = false
    in_join = false
    terms = Set{Int}[]
    join_terms = Set{Int}[]
    for (n, text, toks) in _con_records(sub_path)
        head = first(toks)
        if !in_block
            if toks == ["END"]
                break
            elseif head == "SUBSYSTEM" && length(toks) == 2
                name = toks[2]
                block_line = n
                in_block = true
                in_join = false
                terms = Set{Int}[]
            else
                _mon_warn(sub_path, n, text, "expected SUBSYSTEM <name> or END")
            end
        elseif toks == ["JOIN"] && !in_join
            in_join = true
            join_terms = Set{Int}[]
        elseif toks == ["END"] && in_join
            if isempty(join_terms)
                _mon_warn(sub_path, n, text, "empty JOIN")
            else
                push!(terms, reduce(intersect, join_terms))
            end
            in_join = false
        elseif toks == ["END"]
            buses = reduce(union, terms; init = Set{Int}())
            if haskey(subs, name)
                _mon_warn(
                    sub_path,
                    block_line,
                    "SUBSYSTEM $name",
                    "duplicate subsystem $name",
                )
            elseif isempty(buses)
                _mon_warn(
                    sub_path,
                    block_line,
                    "SUBSYSTEM $name",
                    "subsystem $name selects no buses",
                )
            else
                subs[name] = buses
            end
            in_block = false
        else
            set, reason = _sub_selector(pm, raw, toks)
            if !isempty(reason)
                _mon_warn(sub_path, n, text, reason)
            elseif in_join
                push!(join_terms, set)
            else
                push!(terms, set)
            end
        end
    end
    if in_block
        _mon_warn(sub_path, block_line, "SUBSYSTEM $name", "subsystem $name has no END")
    end
    return subs
end

# Returns ([section, key] of in-service branch-like elements, RAW bus numbers of each element's ends).
function _branch_ends(pm::Dict)
    keys_ = Vector{String}[]
    ends = Vector{Int}[]
    for (section, nends) in _MON_BRANCH_SECTIONS
        for key in sort!(String.(collect(keys(get(pm, section, Dict())))))
            e = pm[section][key]
            if !iszero(e[_CON_STATUS_KEY[section]])
                push!(keys_, [section, key])
                push!(ends, [_sid_bus(e["source_id"][i]) for i in 2:(1 + nends)])
            end
        end
    end
    return keys_, ends
end

function _branches_in(
    keys_::Vector{Vector{String}},
    ends::Vector{Vector{Int}},
    sub::Set{Int},
    ties::Bool,
)
    out = Vector{String}[]
    for (key, e) in zip(keys_, ends)
        inside = count(in(sub), e)
        if ties
            if inside > 0 && inside < length(e)
                push!(out, key)
            end
        elseif inside == length(e)
            push!(out, key)
        end
    end
    return out
end

function _mon_subsystem(
    subs::Dict{String, Set{Int}},
    name::String,
    path::String,
    n::Int,
    text::String,
)
    if !haskey(subs, name)
        _mon_warn(path, n, text, "subsystem $name is not defined in the .sub file")
        return Set{Int}(), false
    end
    return subs[name], true
end

"""
    add_monitored!(pm::Dict, mon_path::String; sub_path::String = "")

Read a PSS/E monitored-element (`.mon`) file, with subsystems from the `.sub` file `sub_path`,
into `pm["monitor"] = Dict("branches" => [[section, key], ...], "buses" => [PM bus keys],
"voltage_band" => (lo, hi))`. `section` is the PM section holding the element (`branch`,
`switch`, `breaker`, `generic_connector`, `3w_transformer`); keys collide across sections, so
a branch is the pair. Pairs are unique, in first-seen order. The band is `(-Inf, Inf)` without a voltage-range record.

`.mon` records: `MONITOR ALL BRANCHES`; `MONITOR BRANCHES IN SUBSYSTEM s`; `MONITOR TIES
FROM SUBSYSTEM s`; `MONITOR VOLTAGE RANGE SUBSYSTEM s lo hi` (per unit; the subsystem's buses
are monitored). `.sub` records: `SUBSYSTEM s` ... `END` holding `AREA`, `ZONE`, `OWNER` (numbers
matched to the bus entry's field), `KVRANGE lo hi` (kV, `base_kv`) and `BUS` (RAW bus numbers),
unioned; a nested `JOIN` ... `END` intersects its selectors.

No real `.mon` / `.sub` file was available, so semantics are inferred. Only in-service
branches, switching devices and three-winding transformers are considered, with ends taken from
`source_id` (RAW buses, not routed node-buses). `IN` = every end in the subsystem; `TIES` = some
but not all ends in it.

A bad record (unsupported, undefined subsystem, unknown area or bus, a voltage range that
differs from an earlier one) is skipped with a `@warn` naming file, line and record, and the
rest of the file is processed. Only an unreadable file throws.
"""
function add_monitored!(pm::Dict, mon_path::String; sub_path::String = "")
    raw = _raw_buses(pm)
    subs = _read_subsystems(pm, raw, sub_path)
    keys_, ends = _branch_ends(pm)
    branches = Vector{String}[]
    buses = Int[]
    band = (-Inf, Inf)
    has_band = false
    for (n, text, toks) in _con_records(mon_path)
        if toks == ["END"]
            break
        end
        if first(_con_match(toks, _con_pattern("MONITOR ALL BRANCHES")))
            append!(branches, keys_)
            continue
        end
        ok, _, caps = _con_match(toks, _con_pattern("MONITOR BRANCHES IN SUBSYSTEM *"))
        if ok
            sub, found = _mon_subsystem(subs, only(caps), mon_path, n, text)
            if found
                append!(branches, _branches_in(keys_, ends, sub, false))
            end
            continue
        end
        ok, _, caps = _con_match(toks, _con_pattern("MONITOR TIES FROM SUBSYSTEM *"))
        if ok
            sub, found = _mon_subsystem(subs, only(caps), mon_path, n, text)
            if found
                append!(branches, _branches_in(keys_, ends, sub, true))
            end
            continue
        end
        ok, _, caps =
            _con_match(toks, _con_pattern("MONITOR VOLTAGE RANGE SUBSYSTEM * * *"))
        if ok && all(t -> occursin(_MON_FLOAT, t), caps[2:3])
            sub, found = _mon_subsystem(subs, caps[1], mon_path, n, text)
            range = (parse(Float64, caps[2]), parse(Float64, caps[3]))
            if !found
                continue
            elseif has_band && range != band
                _mon_warn(
                    mon_path,
                    n,
                    text,
                    "voltage range $range differs from the earlier $band",
                )
                continue
            end
            band = range
            has_band = true
            append!(buses, raw[b] for b in sub)
            continue
        end
        _mon_warn(mon_path, n, text, "unsupported record")
    end
    pm["monitor"] = Dict{String, Any}(
        "branches" => unique!(branches),
        "buses" => sort!(unique!(buses)),
        "voltage_band" => band,
    )
    return
end

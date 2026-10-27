"""
One record of a PSS/E `.con` contingency block. The field `kind` is one of `:open_branch`
(two or three buses), `:open_3w_transformer`, `:open_3w_winding`, `:remove_unit`,
`:remove_load`, `:remove_shunt`, `:remove_switched_shunt`, `:open_bus`, `:close_branch`.
The field `id` is the circuit or equipment id. A quoted id keeps its case and loses its
padding. The field is empty when the record has no id.
"""
struct ConAction
    kind::Symbol
    buses::Vector{Int}
    id::String
    line::Int
    text::String
end

struct ConBlock
    label::String
    line::Int
    actions::Vector{ConAction}
end

struct ConSkipped
    label::String
    file::String
    line::Int
    reason::String
end

const _CON_TOKEN = r"'[^']*'|\"[^\"]*\"|/|[^\s'\"/]+"
const _CON_QUOTED = ('\'', '"')

# Keywords change to uppercase. A quoted token keeps its case but loses quotes and padding.
# A `/` outside quotes starts a comment.
function _con_tokens(line::AbstractString)
    toks = String[]
    for m in eachmatch(_CON_TOKEN, line)
        s = m.match
        if s == "/"
            break
        end
        if first(s) in _CON_QUOTED
            push!(toks, String(strip(s[2:(end - 1)])))
        else
            push!(toks, uppercase(s))
        end
    end
    return toks
end

# Merge each multi-word spelling into one keyword.
function _con_normalize(toks::Vector{String})
    out = String[]
    i = 1
    while i <= length(toks)
        t = toks[i]
        nxt = ""
        if i < length(toks)
            nxt = toks[i + 1]
        end
        if t == "THREE" && nxt == "WINDING"
            push!(out, "THREEWINDING")
            i += 2
        elseif t == "SWITCHED" && nxt == "SHUNT"
            push!(out, "SWSHUNT")
            i += 2
        elseif t == "TRANSFORMER" && !isempty(out) && last(out) == "THREEWINDING"
            i += 1
        else
            push!(out, t)
            i += 1
        end
    end
    return out
end

# A pattern word is a keyword, `A|B` for alternatives, `#` to capture an integer, or `*` to
# capture any token.
function _con_match(toks::Vector{String}, pattern::Vector{String})
    ints = Int[]
    strs = String[]
    if length(toks) != length(pattern)
        return false, ints, strs
    end
    for (t, p) in zip(toks, pattern)
        if p == "#"
            if isempty(t) || !all(isdigit, t)
                return false, ints, strs
            end
            push!(ints, parse(Int, t))
        elseif p == "*"
            push!(strs, t)
        elseif !(t in split(p, '|'))
            return false, ints, strs
        end
    end
    return true, ints, strs
end

_con_pattern(s::String) = String.(split(s))

# PSEB (PSS/E 35 POM) defines the default '1' for an omitted CKT. The `.con` format does not
# document it.
const _CON_FORMS = [
    (_con_pattern("OPEN|TRIP BRANCH FROM BUS # TO BUS # CKT|CIRCUIT *"), :open_branch, ""),
    (_con_pattern("OPEN|TRIP BRANCH FROM BUS # TO BUS #"), :open_branch, "1"),
    (
        _con_pattern("OPEN|TRIP BRANCH FROM BUS # TO BUS # TO BUS # CKT|CIRCUIT *"),
        :open_branch,
        "",
    ),
    (_con_pattern("OPEN|TRIP BRANCH FROM BUS # TO BUS # TO BUS #"), :open_branch, "1"),
    (
        _con_pattern(
            "OPEN|TRIP THREEWINDING FROM BUS # TO BUS # TO BUS # CKT|CIRCUIT *",
        ),
        :open_3w_transformer,
        "",
    ),
    (
        _con_pattern(
            "OPEN|TRIP THREEWINDING FROM BUS # TO BUS # TO BUS # CKT|CIRCUIT * AT BUS #",
        ),
        :open_3w_winding,
        "",
    ),
    (_con_pattern("REMOVE UNIT|MACHINE * FROM BUS #"), :remove_unit, ""),
    (_con_pattern("REMOVE LOAD * FROM BUS #"), :remove_load, ""),
    (_con_pattern("REMOVE SHUNT * FROM BUS #"), :remove_shunt, ""),
    (_con_pattern("REMOVE SWSHUNT * FROM BUS #"), :remove_switched_shunt, ""),
    (_con_pattern("DISCONNECT|OPEN BUS #"), :open_bus, ""),
    (_con_pattern("CLOSE BRANCH FROM BUS # TO BUS # CKT|CIRCUIT *"), :close_branch, ""),
    (_con_pattern("CLOSE BRANCH FROM BUS # TO BUS #"), :close_branch, "1"),
    (
        _con_pattern("CLOSE BRANCH FROM BUS # TO BUS # TO BUS # CKT|CIRCUIT *"),
        :close_branch,
        "",
    ),
    (_con_pattern("CLOSE BRANCH FROM BUS # TO BUS # TO BUS #"), :close_branch, "1"),
]

const _CON_UNSUPPORTED = [
    (
        _con_pattern("REMOVE SHUNT FROM BUS #"),
        "REMOVE SHUNT without an id is not supported",
    ),
    (
        _con_pattern("REMOVE SWSHUNT FROM BUS #"),
        "REMOVE SWITCHED SHUNT without an id is not supported",
    ),
]

function _con_unsupported_reason(toks::Vector{String})
    for (pattern, reason) in _CON_UNSUPPORTED
        if first(_con_match(toks, pattern))
            return reason
        end
    end
    return ""
end

# Returns (action, reason). The reason is empty when the record is valid.
function _parse_con_action(toks::Vector{String}, line::Int, text::String)
    for (pattern, kind, default_id) in _CON_FORMS
        ok, ints, strs = _con_match(toks, pattern)
        if ok
            id = default_id
            if !isempty(strs)
                id = only(strs)
            end
            return ConAction(kind, ints, id, line, text), ""
        end
    end
    reason = _con_unsupported_reason(toks)
    if isempty(reason)
        reason = "unrecognized record `$text`"
    end
    return ConAction(:unsupported, Int[], "", line, text), reason
end

# Returns (line number, stripped text, tokens) for each line that is not blank and not a
# comment. The function decodes bytes as latin1, because real files have non-UTF-8 bytes in
# comments.
function _con_records(path::String)
    text = String(Char.(read(path)))
    out = Tuple{Int, String, Vector{String}}[]
    for (n, raw) in enumerate(eachline(IOBuffer(text)))
        toks = _con_tokens(raw)
        if isempty(toks) || first(toks) == "COM"
            continue
        end
        push!(out, (n, String(strip(raw)), _con_normalize(toks)))
    end
    return out
end

function _skip_con!(skipped::Vector{ConSkipped}, path::String, label, line, reason)
    @warn "Skipping contingency '$label' ($path line $line): $reason"
    push!(skipped, ConSkipped(label, path, line, reason))
    return
end

"""
    _read_con(path) -> (blocks::Vector{ConBlock}, skipped::Vector{ConSkipped})

Parse a PSS/E ACCC `.con` file into blocks. Like PSS/E, a problem skips only the affected
contingency and logs a `@warn`. These problems cause a skip:

  - An unsupported or unrecognized record.
  - A label that the file repeats. The function skips the later block.
  - A missing `END`. The function skips the block when another CONTINGENCY follows or the
    file ends.
  - An unquoted multi-word label.

The function also skips content after the terminating `END`. Only an unreadable file throws an
error.
"""
function _read_con(path::String)
    blocks = ConBlock[]
    skipped = ConSkipped[]
    seen = Set{String}()
    label = ""
    block_line = 0
    actions = ConAction[]
    reason = ""
    in_block = false
    ended = false
    for (n, text, toks) in _con_records(path)
        if ended
            _skip_con!(skipped, path, "", n, "content after the terminating END: `$text`")
            break
        end
        if in_block && toks == ["END"]
            if isempty(reason)
                push!(blocks, ConBlock(label, block_line, actions))
            else
                _skip_con!(skipped, path, label, block_line, reason)
            end
            in_block = false
        elseif first(toks) == "CONTINGENCY"
            if in_block
                _skip_con!(skipped, path, label, block_line, "no END")
            end
            label = join(toks[2:end], " ")
            block_line = n
            actions = ConAction[]
            reason = ""
            if length(toks) != 2
                reason = "a label with spaces or none must be quoted: `$text`"
            elseif label in seen
                reason = "duplicate label within the file"
            end
            push!(seen, label)
            in_block = true
        elseif in_block
            action, why = _parse_con_action(toks, n, text)
            if isempty(reason)
                reason = why
            end
            push!(actions, action)
        elseif toks == ["END"]
            ended = true
        else
            _skip_con!(
                skipped,
                path,
                "",
                n,
                "expected CONTINGENCY '<label>' or END, got `$text`",
            )
        end
    end
    if in_block
        _skip_con!(skipped, path, label, block_line, "no END")
    end
    return blocks, skipped
end

const _CON_STATUS_KEY = Dict(
    "branch" => "br_status",
    "switch" => "state",
    "breaker" => "state",
    "generic_connector" => "state",
    "3w_transformer" => "available",
    "gen" => "gen_status",
    "load" => "status",
    "shunt" => "status",
    "switched_shunt" => "status",
    "dcline" => "br_status",
    "vscline" => "br_status",
    "facts" => "available",
)

function _con_element(pm::Dict, a::ConAction, action::String, section::String, key)
    e = pm[section][key]
    in_service = true
    if haskey(_CON_STATUS_KEY, section)
        in_service = !iszero(e[_CON_STATUS_KEY[section]])
    end
    return Dict{String, Any}(
        "action" => action,
        "section" => section,
        "key" => key,
        "source_id" => e["source_id"],
        "in_service" => in_service,
        "line" => a.line,
    )
end

function _con_elements(pm::Dict, a::ConAction, action::String, targets::Vector{_Target})
    return [_con_element(pm, a, action, section, key) for (section, key) in targets]
end

# Returns (targets, reason). The reason is empty when exactly one target matches.
function _con_unique(table::Dict, key, a::ConAction, what::String)
    targets = get(table, key, _Target[])
    if isempty(targets)
        return _Target[], "no $what in the RAW: `$(a.text)`"
    elseif length(targets) > 1
        return _Target[], "ambiguous, $(length(targets)) $(what)s match: `$(a.text)`"
    end
    return targets, ""
end

function _con_resolve_3w(pm::Dict, index::_PsseIndex, a::ConAction, action::String)
    key = (_triple(a.buses[1], a.buses[2], a.buses[3]), _segment_ckt(a.id))
    targets, reason = _con_unique(index.transformer3w, key, a, "three-winding transformer")
    return _con_elements(pm, a, action, targets), reason
end

function _con_resolve_2w(pm::Dict, index::_PsseIndex, a::ConAction, action::String)
    key = (_pair(a.buses[1], a.buses[2]), _segment_ckt(a.id))
    segments = get(index.multisection, key, Vector{_Target}[])
    if length(segments) > 1
        return Dict{String, Any}[],
        "ambiguous, $(length(segments)) multi-section lines match: `$(a.text)`"
    elseif isone(length(segments))
        return _con_elements(pm, a, action, only(segments)), ""
    end
    targets, reason = _con_unique(index.branch, key, a, "branch")
    return _con_elements(pm, a, action, targets), reason
end

function _con_resolve_branch(pm::Dict, index::_PsseIndex, a::ConAction, action::String)
    if length(a.buses) == 3
        return _con_resolve_3w(pm, index, a, "open_3w_transformer")
    end
    return _con_resolve_2w(pm, index, a, action)
end

function _con_resolve_injector(
    pm::Dict,
    table::Dict,
    a::ConAction,
    action::String,
    what::String,
)
    targets, reason = _con_unique(table, (only(a.buses), _segment_ckt(a.id)), a, what)
    return _con_elements(pm, a, action, targets), reason
end

function _con_resolve(::Val{:open_branch}, pm, index, a)
    return _con_resolve_branch(pm, index, a, "open_branch")
end

function _con_resolve(::Val{:close_branch}, pm, index, a)
    return _con_resolve_branch(pm, index, a, "close_branch")
end

function _con_resolve(::Val{:open_3w_transformer}, pm, index, a)
    return _con_resolve_3w(pm, index, a, "open_3w_transformer")
end

function _con_resolve(::Val{:open_3w_winding}, pm, index, a)
    return Dict{String, Any}[],
    "per-winding three-winding transformer outage is not supported: `$(a.text)`"
end

function _con_resolve(::Val{:remove_unit}, pm, index, a)
    return _con_resolve_injector(pm, index.gen, a, "remove_unit", "unit")
end

function _con_resolve(::Val{:remove_load}, pm, index, a)
    return _con_resolve_injector(pm, index.load, a, "remove_load", "load")
end

function _con_resolve(::Val{:remove_shunt}, pm, index, a)
    return _con_resolve_injector(pm, index.shunt, a, "remove_shunt", "fixed shunt")
end

function _con_resolve(::Val{:remove_switched_shunt}, pm, index, a)
    return _con_resolve_injector(
        pm,
        index.switched_shunt,
        a,
        "remove_switched_shunt",
        "switched shunt",
    )
end

const _BUS_OUTAGE_ACTION = Dict(
    "branch" => "open_branch",
    "switch" => "open_branch",
    "breaker" => "open_branch",
    "generic_connector" => "open_branch",
    "gen" => "remove_unit",
    "load" => "remove_load",
    "shunt" => "remove_shunt",
    "switched_shunt" => "remove_switched_shunt",
    "dcline" => "open_dc_line",
    "vscline" => "open_dc_line",
    "facts" => "remove_facts",
)

# The function recasts a bus disconnect as outages of each in-service element on the bus.
# PSS/E keeps the units, loads and shunts of the bus in service but dead, so the outage
# includes them.
function _con_resolve(::Val{:open_bus}, pm, index, a)
    bus = only(a.buses)
    if !haskey(index.bus, bus)
        return Dict{String, Any}[], "no bus $bus in the RAW: `$(a.text)`"
    end
    if haskey(index.blocking, bus)
        return Dict{String, Any}[],
        "bus $bus has $(index.blocking[bus]) attached; a bus outage cannot be recast as a component outage: `$(a.text)`"
    end
    targets = get(index.attached, bus, _Target[])
    if isempty(targets)
        return Dict{String, Any}[],
        "bus $bus has no in-service attached element: `$(a.text)`"
    end
    elements = Dict{String, Any}[]
    for (section, key) in sort(targets)
        e = _con_element(pm, a, _BUS_OUTAGE_ACTION[section], section, key)
        e["via_bus"] = bus
        push!(elements, e)
    end
    return elements, ""
end

_is_close(e::Dict) = e["action"] == "close_branch"
_is_open(e::Dict) = !_is_close(e)

# Returns (elements, reason). A CLOSE on an out-of-service target skips the whole contingency.
# Without the close action, the open actions alone would outage more than the file describes.
function _resolve_block(pm::Dict, index::_PsseIndex, block::ConBlock)
    resolved = Dict{String, Any}[]
    for a in block.actions
        elements, reason = _con_resolve(Val(a.kind), pm, index, a)
        if !isempty(reason)
            return Dict{String, Any}[], reason
        end
        append!(resolved, elements)
    end
    for e in filter(_is_close, resolved)
        if !e["in_service"]
            return Dict{String, Any}[],
            "CLOSE BRANCH target $(e["source_id"]) (line $(e["line"])) is out of service in the RAW; the block needs a close action that is not supported"
        end
    end
    return unique(e -> (e["section"], e["key"]), filter(_is_open, resolved)), ""
end

function _warn_flags(path::String, block::ConBlock, elements::Vector{Dict{String, Any}})
    for e in elements
        if !e["in_service"]
            @warn "Contingency '$(block.label)' ($path line $(e["line"])) targets $(e["section"]) $(e["source_id"]), which is out of service in the RAW; resolved and flagged in_service=false"
        end
    end
    return
end

function _warn_closes(path::String, block::ConBlock)
    for a in block.actions
        if a.kind == :close_branch
            @warn "Contingency '$(block.label)' ($path line $(a.line)): CLOSE BRANCH skipped, no close action is supported: `$(a.text)`"
        end
    end
    return
end

_stem(path::String) = first(splitext(basename(path)))

# A label that more than one file repeats gets the key "<file stem>:<label>" for each
# occurrence. Returns (key, reason). `_rekey_earlier!` re-keys the earlier bare entry.
function _contingency_key(
    contingencies::Dict,
    labels::Set{String},
    label::String,
    path::String,
)
    if !(label in labels)
        return label, ""
    end
    key = "$(_stem(path)):$label"
    if haskey(contingencies, key)
        return key, "identifier '$key' is already loaded from $(contingencies[key]["file"])"
    end
    if haskey(contingencies, label)
        rekey = "$(_stem(contingencies[label]["file"])):$label"
        if haskey(contingencies, rekey)
            return key,
            "identifier '$rekey' is already loaded from $(contingencies[rekey]["file"])"
        end
    end
    return key, ""
end

function _rekey_earlier!(contingencies::Dict, label::String, path::String)
    if !haskey(contingencies, label)
        return
    end
    earlier = pop!(contingencies, label)
    rekey = "$(_stem(earlier["file"])):$label"
    earlier["source_id"] = ["contingency", rekey]
    contingencies[rekey] = earlier
    @warn "Contingency label '$label' is repeated across files ($(earlier["file"]) and $path); identifiers are keyed by file stem"
    return
end

function _skip_block!(
    skipped::Vector{Dict{String, Any}},
    path::String,
    block::ConBlock,
    reason::String,
)
    @warn "Skipping contingency '$(block.label)' ($path line $(block.line)): $reason"
    push!(
        skipped,
        Dict{String, Any}(
            "label" => block.label,
            "file" => path,
            "line" => block.line,
            "reason" => reason,
        ),
    )
    return
end

function _summary_reasons(skipped::Vector{Dict{String, Any}})
    counts = Dict{String, Int}()
    for s in skipped
        reason = replace(first(split(s["reason"], '`')), r"\d+" => "N")
        counts[reason] = get(counts, reason, 0) + 1
    end
    return join(
        ["$n x $r" for (r, n) in sort!(collect(counts); by = last, rev = true)],
        "; ",
    )
end

"""
    add_contingencies!(pm::Dict, con_path::String)

Parse the PSS/E ACCC `.con` file at `con_path`. Resolve each contingency against the PM-dict
through `source_id`, and add it to `pm["contingency"]` under its identifier.

The identifier is the bare label. When a label occurs in more than one `.con` file, every
occurrence becomes `"<file stem>:<label>"`. A later call that repeats a label re-keys the
earlier entry. So the identifiers depend on which files the caller loads together.

Each entry holds `"source_id"`, `"label"`, `"file"`, `"line"` and `"elements"`. An element is
one `Dict` for one resolved target. It holds `"action"`, `"section"`, `"key"`, `"source_id"`,
`"in_service"` and `"line"`. A multi-section line gives one element for each segment. An
`OPEN BRANCH` on a switching device keeps the real section of the device.

`OPEN BUS` and `DISCONNECT BUS` become N-k outages. Each gets one element for each in-service
branch, transformer, switching device, unit, load, fixed shunt, switched shunt, DC line, VSC
line and FACTS device on the bus, with `"via_bus"` set. A DC line or VSC line has the action
`"open_dc_line"`. A FACTS device has the action `"remove_facts"`, and it attaches to its bus
and to its nonzero terminal bus. PSS/E keeps injectors in service but dead. The function keeps
an element that repeats in a block once. The function skips the block in two cases. The bus
has a three-winding transformer. Or the bus has no in-service element.

Like PSS/E, a problem skips only its contingency and logs a `@warn`. These problems cause a
skip: an unresolved record, an ambiguous record, an unsupported form, or a `CLOSE BRANCH` on
an out-of-service target. The function skips each other `CLOSE BRANCH` record with a
warning, because the function has no close action.

The function appends each skipped block to `pm["contingency_skipped"]` as
`Dict("label", "file", "line", "reason")`. It logs one summary `@warn` for each file with the
counts. The function resolves a target that is already out of service, sets
`"in_service" => false`, and logs a warning. Only an unreadable file throws an error.

The skip policy follows the alarm-and-skip handling of contingency errors in PSS/E. It differs
from a failure of the whole file that adds nothing. The upstream validation of the `.con` lists
used a different RAW. So PSS/E can skip other contingencies than this function does.

An omitted circuit id defaults to `"1"`. The author inferred the default from the PSS/E PSEB
commands, not from a `.con` format specification. Likewise, the author inferred the forms
`REMOVE LOAD`, `REMOVE SHUNT`, `REMOVE SWSHUNT` and `OPEN BUS` from data and from related
PSS/E commands (`DROP`, `DISCONNECT BUS`).
"""
function add_contingencies!(pm::Dict, con_path::String)
    blocks, read_skipped = _read_con(con_path)
    contingencies = get!(pm, "contingency", Dict{String, Any}())
    skipped = get!(pm, "contingency_skipped", Dict{String, Any}[])
    new_skipped = [
        Dict{String, Any}(
            "label" => s.label,
            "file" => s.file,
            "line" => s.line,
            "reason" => s.reason,
        ) for s in read_skipped
    ]
    index = _PsseIndex(pm)
    labels = Set{String}(c["label"] for c in values(contingencies))
    resolved = 0
    for block in blocks
        elements, reason = _resolve_block(pm, index, block)
        if !isempty(reason)
            _skip_block!(new_skipped, con_path, block, reason)
            continue
        end
        key, reason = _contingency_key(contingencies, labels, block.label, con_path)
        if !isempty(reason)
            _skip_block!(new_skipped, con_path, block, reason)
            continue
        end
        _warn_closes(con_path, block)
        _warn_flags(con_path, block, elements)
        if key != block.label
            _rekey_earlier!(contingencies, block.label, con_path)
        end
        push!(labels, block.label)
        contingencies[key] = Dict{String, Any}(
            "source_id" => ["contingency", key],
            "label" => block.label,
            "file" => con_path,
            "line" => block.line,
            "elements" => elements,
        )
        resolved += 1
    end
    append!(skipped, new_skipped)
    @warn "Contingency file summary for $con_path: $(length(blocks) + length(read_skipped)) blocks, $resolved resolved, $(length(new_skipped)) skipped. $(_summary_reasons(new_skipped))"
    return
end

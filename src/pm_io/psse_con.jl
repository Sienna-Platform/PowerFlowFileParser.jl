"""
One parsed record of a PSS/E `.con` contingency block. `kind` is one of `:open_branch`
(two or three buses), `:open_3w_transformer`, `:open_3w_winding`, `:remove_unit`,
`:remove_load`, `:remove_shunt`, `:remove_switched_shunt`, `:open_bus`, `:close_branch`.
`id` is the circuit or equipment id, stripped and not case-folded when quoted; empty when
the form has none.
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

# Keywords are uppercased; a quoted token keeps its case minus quotes and padding. `/` outside
# quotes starts a comment.
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

# Merge the multi-word spellings into one keyword each.
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

# Pattern words: a keyword, `A|B` alternatives, `#` an integer capture, `*` any-token capture.
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

# The omitted-CKT default of '1' is PSEB's (PSS/E 35 POM), not documented for `.con`.
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

# Returns (action, reason); reason is empty when the record parses.
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

# (line number, stripped text, tokens) of every non-blank, non-comment line. Bytes are
# decoded as latin1: real files hold non-UTF-8 bytes in comments.
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
contingency, with a `@warn`: an unsupported or unrecognized record, a label repeated within
the file (the later one), a missing `END` (the block, when another CONTINGENCY follows or
the file ends), an unquoted multi-word label, or content after the terminating
`END` (ignored). Only an unreadable file throws.
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

# Returns (targets, reason); reason is empty on a unique match.
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

function _con_resolve(::Val{:open_bus}, pm, index, a)
    bus = only(a.buses)
    if !haskey(index.bus, bus)
        return Dict{String, Any}[], "no bus $bus in the RAW: `$(a.text)`"
    end
    return [_con_element(pm, a, "open_bus", "bus", index.bus[bus])], ""
end

_is_close(e::Dict) = e["action"] == "close_branch"
_is_open(e::Dict) = !_is_close(e)

# Returns (elements, reason). A CLOSE on an out-of-service target blocks the whole contingency:
# opening the rest alone would outage more than the file describes.
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
    return filter(_is_open, resolved), ""
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

# Labels repeated across files are keyed "<file stem>:<label>", every occurrence. Returns
# (key, reason); the earlier bare entry is re-keyed by `_rekey_earlier!`.
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
        reason = first(split(s["reason"], '`'))
        counts[reason] = get(counts, reason, 0) + 1
    end
    return join(
        ["$n x $r" for (r, n) in sort!(collect(counts); by = last, rev = true)],
        "; ",
    )
end

"""
    add_contingencies!(pm::Dict, con_path::String)

Parse the PSS/E ACCC `.con` file at `con_path` and resolve each contingency against the
PM-dict through `source_id`, adding it to `pm["contingency"]`, keyed by identifier: the bare
label, or `"<file stem>:<label>"` for labels repeated across files (an earlier entry is re-keyed
when a later call repeats its label). Each entry holds `"source_id"`, `"label"`, `"file"`,
`"line"` and `"elements"`, one `Dict` per resolved target with `"action"`, `"section"`,
`"key"`, `"source_id"`, `"in_service"` and `"line"`. A multi-section line yields one element
per segment; an `OPEN BRANCH` on a switching device keeps its real section; `OPEN BUS` yields
an `"open_bus"` element on section `"bus"`.

Like PSS/E, a problem skips only its contingency, with a `@warn`: an unresolved or ambiguous
record, an unsupported form, or a `CLOSE BRANCH` on a target that is out of service in the RAW.
`CLOSE BRANCH` records are otherwise skipped with a warning. Skipped blocks are appended to
`pm["contingency_skipped"]` as `Dict("label", "file", "line", "reason")`, and one summary
`@warn` per file gives the counts. Targets already out of service are resolved and flagged
`"in_service" => false`, with a warning. Only an unreadable file throws.

The skip-and-continue policy follows PSS/E's alarm-and-skip handling of contingency errors;
it differs from failing the whole file and adding nothing. The `.con` lists are validated
against a different RAW upstream, so a case that PSS/E would skip can differ here.

An omitted circuit id defaults to `"1"`, inferred from the PSS/E PSEB commands rather than from
a `.con` format specification. `REMOVE LOAD`, `REMOVE SHUNT`, `REMOVE SWSHUNT` and `OPEN BUS`
are likewise inferred from data and related PSS/E commands (`DROP`, `DISCONNECT BUS`).

The contingency identifier is the bare label. Only when a label occurs in more than one `.con`
file does every occurrence become `"<file stem>:<label>"`, so identifiers depend on which files
are loaded together.
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

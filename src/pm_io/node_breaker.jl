# Node-breaker substation materialization. Expands the parsed `substation` section
# into real bus records ("node-buses") right after the BUS section is parsed, so every
# later section parser can attach its records directly to the node-bus a terminal
# assigns them to. An out-of-service NODE materializes with the same encoding a BUS
# record with IDE=4 gets, so the devices wired to it are kept rather than dropped and
# each section's own isolated-bus check decides their fate as it parses them. The one
# section without such a check is `distributed_generation`, whose availability comes
# from the LOAD record's DGENM field alone; that is the same treatment it gets on a BUS
# record with IDE=4. An out-of-service DEVICE is kept with state 0. Runs inside the PTI
# conversion, before per-unit and validation, so voltages here are in raw-file units
# (angles in degrees).

const _NB_SWITCH = NamedTuple{
    (:from, :to, :closed, :x, :dtype, :ckt, :name, :rates, :substation),
    Tuple{Int, Int, Bool, Float64, Int, String, String, Vector{Float64}, Int},
}

# The node-breaker tables `_prepare_node_breaker!` produces. Routing reads
# `terminal_node` (a PSS(R)E TERMINAL key -> the node-bus it selects), records each key
# it resolves in `matched_terminals`, and reads
# `nb_bus_numbers` (the source bus numbers that were split, a fast path that skips the
# lookup for untouched buses); `_create_node_breaker_switch_entries!` reads `switches`.
# `node_number` maps (substation index, NI) -> assigned bus number and has no
# production consumer: it exists for tests and debugging.
_new_node_breaker() = (;
    node_number = Dict{Tuple{Int, Int}, Int}(),
    terminal_node = Dict{Tuple{Int, String, Int, String}, Int}(),
    matched_terminals = Set{Tuple{Int, String, Int, String}}(),
    nb_bus_numbers = Set{Int}(),
    switches = _NB_SWITCH[],
)

# Stand-in for a case with nothing to route. Shared, so it must only ever be read:
# `_prepare_node_breaker!` returns it when there is no substation data to materialize,
# and `_create_node_breaker_switch_entries!` passes it to suppress routing.
const _NO_NODE_BREAKER = _new_node_breaker()

# Representative node for a PSS(R)E bus I within a substation: prefer a node that
# inherits or matches the BUS-record voltage (lowest NI first); if every node
# stores a differing voltage, fall back to the lowest NI. The representative keeps
# bus number I so by-number references stay valid. When it inherits, the retained
# record keeps the BUS-record solved voltage; when every node stores a differing
# voltage, the fallback node's stored voltage overwrites the BUS-record voltage.
# The caller narrows `nodes` to the in-service nodes whenever the bus has any.
function _representative_node(nodes::Vector, src::Dict)
    inherits_bus_voltage(n) =
        !haskey(n, "vm") ||
        (n["vm"] == get(src, "vm", nothing) &&
         get(n, "va", nothing) == get(src, "va", 0.0))
    pool = filter(inherits_bus_voltage, nodes)
    isempty(pool) && (pool = nodes)
    return argmin(n -> n["number"], pool)
end

# Turns on the isolated-bus bookkeeping that `_psse2pm_bus!` turns on for an IDE=4 BUS
# record, so an out-of-service node-bus is reconciled by exactly the same policy. The
# sets are created only when absent: an IDE=4 BUS record may already have populated
# them.
function _register_isolated_bus_bookkeeping!(pm_data::Dict)
    if !get(pm_data, "has_isolated_type_buses", false)
        @warn "The PSS(R)E data contains out-of-service substation nodes. The parser will check if the resulting node-buses are connected or topologically isolated."
        pm_data["has_isolated_type_buses"] = true
    end
    get!(() -> Set{Int}(), pm_data, "connected_buses")
    get!(() -> Set{Int}(), pm_data, "candidate_isolated_to_pq_buses")
    get!(() -> Set{Int}(), pm_data, "candidate_isolated_to_pv_buses")
    return
end

"""
Materializes node-buses in `pm_data["bus"]`, resolves their numbering, and builds the
terminal and switching-device tables the section parsers route with. Runs immediately
after `_psse2pm_bus!` and `_psse2pm_substation_data!`, and is a no-op unless `pm_data`
is a PTI case with a populated `substation` section.
"""
function _prepare_node_breaker!(pm_data::Dict)
    subs = get(pm_data, "substation", [])
    if get(pm_data, "source_type", "") != "pti" || isempty(subs)
        return _NO_NODE_BREAKER
    end
    nb = _new_node_breaker()

    busrec = pm_data["bus"]
    next_no = maximum(b["bus_i"] for b in values(busrec)) + 1
    for sub in sort(collect(values(subs)); by = s -> get(s, "index", 0))
        idx = get(sub, "index", 0)
        # local NI -> assigned bus number for this substation
        ni_to_no = Dict{Int, Int}()
        # Group every node by PSS(R)E bus I, in service or not: an out-of-service node
        # still materializes as a bus so the devices wired to it survive and are
        # handled by the isolated-bus policy rather than silently disappearing.
        by_bus = Dict{Int, Vector{Dict}}()
        for n in get(sub, "nodes", [])
            push!(get!(by_bus, n["bus"], Vector{Dict}()), n)
        end
        # Sorted so injected bus numbers are reproducible across runs.
        for I in sort(collect(keys(by_bus)))
            nodes = by_bus[I]
            haskey(busrec, I) || continue
            push!(nb.nb_bus_numbers, I)
            src = busrec[I]
            # An in-service node is preferred as the representative so bus number I
            # keeps its declared type and status. When every node on the bus is out of
            # service the BUS record's IDE still governs: the retained record is left
            # exactly as the file declared it rather than being reconciled here.
            in_service = filter(n -> get(n, "status", 1) == 1, nodes)
            if isempty(in_service)
                rep = _representative_node(nodes, src)
            else
                rep = _representative_node(in_service, src)
            end
            for n in nodes
                if n === rep
                    num = I
                    rec = src
                else
                    num = next_no
                    next_no += 1
                    # A shallow copy shares only immutable scalars and the name string
                    # with the source record; every mutable value a bus record can hold
                    # is replaced below.
                    rec = copy(src)
                    rec["ext"] = Dict{String, Any}()
                    rec["bus_i"] = num
                    rec["index"] = num
                    rec["source_id"] = ["bus", "$num"]
                    # A blank NAME column would give every such node the same empty
                    # name, so derive one from the source bus and the node number.
                    node_name = strip(string(get(n, "name", "")))
                    rec["name"] = if isempty(node_name)
                        "$(src["name"])_$(n["number"])"
                    else
                        String(node_name)
                    end
                    if get(n, "status", 1) == 1
                        # Out-of-service (IDE=4) buses stay out-of-service on every
                        # node-bus split off of them; everything else starts PQ and
                        # is promoted back to PV/REF only if a generator lands on it
                        # (see `_migrate_node_breaker_gen_bus_type!`).
                        rec["bus_type"] = if src["bus_type"] == PM_BUS_TYPE_ISOLATED
                            PM_BUS_TYPE_ISOLATED
                        else
                            PM_BUS_TYPE_PQ
                        end
                    else
                        # An out-of-service node gets the same encoding, and the same
                        # isolated-bus bookkeeping, as a BUS record with IDE=4.
                        rec["bus_type"] = PM_BUS_TYPE_ISOLATED
                        rec["bus_status"] = false
                        _register_isolated_bus_bookkeeping!(pm_data)
                    end
                    busrec[num] = rec
                end
                haskey(n, "vm") && (rec["vm"] = n["vm"])
                haskey(n, "va") && (rec["va"] = n["va"])
                ni_to_no[n["number"]] = num
                nb.node_number[(idx, n["number"])] = num
                rec_ext = get!(() -> Dict{String, Any}(), rec, "ext")
                rec_ext["nb_substation"] = idx
                rec_ext["nb_bus"] = I
                rec_ext["nb_node"] = n["number"]
            end
        end
        for t in get(sub, "terminals", [])
            haskey(ni_to_no, t["node"]) || continue
            # A negative bus number in the secondary-bus column marks the metered end,
            # the same convention the BRANCH and TRANSFORMER sections use; the bus is
            # its magnitude, and routing compares against those normalized endpoints.
            key = (
                t["bus"],
                String(t["type"]),
                abs(something(get(t, "secondary_bus", 0), 0)),
                String(t["id"]),
            )
            target = ni_to_no[t["node"]]
            # PSS(R)E requires a device identifier to be unique among devices of its type
            # at a bus, so two records on one key point to malformed data. The later
            # record wins, and the warning names both nodes.
            previous = get(nb.terminal_node, key, nothing)
            if previous !== nothing && previous != target
                @warn "Substation $idx has two TERMINAL records with key $key selecting different nodes (bus $previous and bus $target). The later record wins; the device matching the earlier one will be attached to bus $target."
            end
            nb.terminal_node[key] = target
        end
        for d in get(sub, "switching_devices", [])
            (haskey(ni_to_no, d["from_node"]) && haskey(ni_to_no, d["to_node"])) ||
                continue
            push!(
                nb.switches,
                (
                    from = ni_to_no[d["from_node"]],
                    to = ni_to_no[d["to_node"]],
                    closed = get(d, "status", 1) == 1,
                    x = Float64(get(d, "x", 1e-4)),
                    dtype = Int(get(d, "device_type", 0)),
                    ckt = String(strip(string(get(d, "ckt", "1")))),
                    name = String(get(d, "name", "")),
                    rates = Float64.(get(d, "rates", [0.0, 0.0, 0.0])),
                    substation = idx,
                ),
            )
        end
    end
    return nb
end

_nb_id(id) = String(strip(string(id)))

"""
The node-bus a section record attaches to, given the PSS(R)E bus number it declares,
the TERMINAL type code for its section, the opposite bus number the RAW stores in the
terminal's secondary-bus column (`nothing` for injectors), and the record's RAW
identifier. Falls back to the declared bus number when no terminal claims it.
"""
function _nb_target(nb, busno::Int, typ::String, other, id)
    busno in nb.nb_bus_numbers || return busno
    key = (busno, typ, something(other, 0), _nb_id(id))
    ni = get(nb.terminal_node, key, nothing)
    ni === nothing && return busno
    push!(nb.matched_terminals, key)
    return ni
end

# A type-"3" terminal's key carries only one of the winding's two sibling buses
# (whichever the RAW stored in its secondary-bus column); try both siblings and
# take whichever hits.
function _nb_target_3w(nb, busno::Int, ckt, others)
    busno in nb.nb_bus_numbers || return busno
    id = _nb_id(ckt)
    for other in others
        key = (busno, "3", other, id)
        ni = get(nb.terminal_node, key, nothing)
        ni === nothing && continue
        push!(nb.matched_terminals, key)
        return ni
    end
    return busno
end

# A TERMINAL record no device looked up leaves that device on its source bus, or
# belongs to a section the parser does not convert. Either way the substation wiring is
# not what the file declares, so report it once per case.
function _warn_unmatched_terminals(nb)
    unmatched = sort!(collect(setdiff(keys(nb.terminal_node), nb.matched_terminals)))
    isempty(unmatched) && return
    counts = Dict{String, Int}()
    for (_, typ, _, _) in unmatched
        counts[typ] = get(counts, typ, 0) + 1
    end
    by_type = join(("$n of type \"$typ\"" for (typ, n) in sort!(collect(counts))), ", ")
    @warn "$(length(unmatched)) substation TERMINAL records match no parsed device ($by_type), e.g. (bus, type, other bus, id) = $(first(unmatched)). Devices they describe stay on their source bus."
    return
end

"""
Appends each substation switching device to the `breaker`, `switch`, or
`generic_connector` section, in the same shape as system-level switching devices and
using the same device-type mapping (TYPE 1 generic connector, TYPE 2 breaker, TYPE 3
switch). A TYPE outside {1,2,3} is unsupported but still classified as
`generic_connector`, since dropping a substation device would disconnect node-buses;
the device type code, device name, and owning substation are preserved in ext.
Runs immediately after `_psse2pm_switch_breaker!`, which creates those three sections.
"""
function _create_node_breaker_switch_entries!(pm_data::Dict, nb)
    isempty(nb.switches) && return nothing
    for s in nb.switches
        section, discrete_branch_type = if s.dtype == 2
            ("breaker", 1)
        elseif s.dtype == 3
            ("switch", 0)
        elseif s.dtype == 1
            ("generic_connector", 2)
        else
            @warn "Substation switching device $(s.name) has unsupported TYPE=$(s.dtype). Classifying as a generic connector."
            ("generic_connector", 2)
        end
        haskey(pm_data, section) || (pm_data[section] = [])
        device = Dict{String, Any}(
            "I" => s.from,
            "J" => s.to,
            "CKT" => s.ckt,
            "X" => s.x,
            "ST" => s.closed ? 1 : 0,
            "RATE1" => s.rates[1],
            "RATE2" => s.rates[2],
            "RATE3" => s.rates[3],
        )
        sub_data = _build_switch_breaker_sub_data(
            pm_data,
            device,
            section,
            discrete_branch_type,
            length(pm_data[section]) + 1,
            # These endpoints are already node-bus numbers, so they must not be routed
            # a second time.
            _NO_NODE_BREAKER,
        )
        sub_data["ext"]["TYPE"] = s.dtype
        sub_data["ext"]["NAME"] = s.name
        sub_data["ext"]["nb_substation"] = s.substation
        branch_isolated_bus_modifications!(pm_data, sub_data)
        push!(pm_data[section], sub_data)
    end
    return nothing
end

"""
Migrates PV/REF `bus_type` along with the first generator that moved off each source
bus during `_psse2pm_generator!`: if no generator remains attached to that bus, its
voltage-control status would otherwise be stranded on a now-generator-less bus while
the node-bus that actually hosts the generator stays PQ. The move is recorded in the
source bus's `ext` so later passes keying off bus numbers (such as the per-area ISW
slack assignment) can follow the voltage-control status.
"""
function _migrate_node_breaker_gen_bus_type!(pm_data::Dict, nb)
    (haskey(pm_data, "gen") && !isempty(nb.nb_bus_numbers)) || return nothing
    gen_moves = Dict{Int, Int}()
    # Whether the recorded target hosts an IN-SERVICE machine. The type must follow a
    # live machine whenever the plant has one: an out-of-service unit's node would be
    # typed PV/REF with no live machine on it, get demoted downstream, and the plant
    # would stop regulating voltage. Only when every unit is offline may the type land
    # on a dead unit's node (where demotion is then correct).
    gen_move_live = Dict{Int, Bool}()
    gen_buses = Set{Int}()
    for d in values(pm_data["gen"])
        target = d["gen_bus"]
        push!(gen_buses, target)
        source = parse(Int, string(d["source_id"][2]))
        source == target && continue
        live = get(d, "gen_status", 1) == 1
        if !haskey(gen_moves, source) || (live && !gen_move_live[source])
            gen_moves[source] = target
            gen_move_live[source] = live
        end
    end
    for (source, target) in gen_moves
        source_bus = pm_data["bus"][source]
        bus_type = source_bus["bus_type"]
        bus_type in (PM_BUS_TYPE_PV, PM_BUS_TYPE_REF) || continue
        source in gen_buses && continue
        # An out-of-service node-bus never takes over voltage control: it would end up
        # typed PV/REF while carrying `bus_status = false`, and the generator that
        # landed on it is de-energized anyway. The source bus is still demoted, since
        # it no longer hosts a generator, and no migration is recorded because none
        # happened.
        if pm_data["bus"][target]["bus_type"] == PM_BUS_TYPE_ISOLATED
            source_bus["bus_type"] = PM_BUS_TYPE_PQ
            continue
        end
        pm_data["bus"][target]["bus_type"] = bus_type
        source_bus["bus_type"] = PM_BUS_TYPE_PQ
        get!(() -> Dict{String, Any}(), source_bus, "ext")["nb_bus_type_moved_to"] = target
    end
    return nothing
end

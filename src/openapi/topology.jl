# `PowerModelsData(file)` defaults `pm_data_corrections = true`, which runs PowerModels'
# `_make_per_unit!`: every power quantity in `data` (including load pd/qd) arrives as
# system per-unit on `baseMVA`, not natural units. The schemas' ActivePower/
# ReactivePower quantities have no "pu" row, so every power value this file writes is
# multiplied back by `baseMVA` before `set_value!` — the conversion the document
# requires, not a workaround.
#
# Two quantities need no such rescaling: `vm`/`vmin`/`vmax` are already pu on `base_kv`,
# which is exactly what `ACBus.magnitude`/`voltage_limits` (`x-unit-base`) want, and `va`
# is already radians — PowerFlowFileParser converts PSS/E degrees to radians while
# parsing (`src/pm_io/data.jl`), so no conversion runs here either. `base_kv` itself is
# a natural quantity PowerModels never rebases.

# `PM_BUS_TYPE_NAMES` (definitions.jl) spells codes 1-4 the way `ACBus.bustype` does.
# PowerModels never emits code 5; the schema's fifth option, `"SLACK"`, is reached only
# through the `area_slack` override below, matching the oracle's `set_bustype!` call.

function _bustype_name(code::Integer)
    if !(1 <= code <= length(PM_BUS_TYPE_NAMES))
        throw(
            IS.DataFormatError(
                "unsupported PowerModels bus_type=$code; expected 1-$(length(PM_BUS_TYPE_NAMES))",
            ),
        )
    end
    return PM_BUS_TYPE_NAMES[code]
end

"""
Default bus name: the pm dict's own `"name"`, `bus_i`-suffixed only when names collide
across the file. Falls back to `source_id` for a bus with no `"name"` at all (the
Matpower path never carries one).
"""
function _default_bus_name(d::Dict, unique_names::Bool)
    if haskey(d, "name")
        if unique_names
            return strip(d["name"])
        end
        return string(strip(d["name"]), "_", d["bus_i"])
    end
    return strip(join(string.(d["source_id"]), "-"))
end

"""Whether every bus carrying a `"name"` in `bus_data` has a distinct one."""
function _unique_bus_names(bus_data)
    seen = Set{String}()
    for (_, d) in bus_data
        if !haskey(d, "name")
            continue
        end
        if d["name"] in seen
            return false
        end
        push!(seen, d["name"])
    end
    return true
end

"""
Whether PSS/E AREA DATA carries per-area metadata (name, slack bus, desired/tolerance
interchange) for the `Area` named `area_name`. Matches the inline area_interchange lookup
inside PSCB's `read_bus!`, including its match rule's `area_name_formatter`-dependent
behavior: a non-default formatter makes this comparison never match, the same silent gap
the oracle has.
"""
function _has_area_interchange(data::Dict, area_name::AbstractString)
    if get(data, "source_type", nothing) != "pti" || !haskey(data, "area_interchange")
        return false
    end
    for (_, area_data) in data["area_interchange"]
        if haskey(area_data, "area_number") &&
           string(area_data["area_number"]) == area_name
            return true
        end
    end
    return false
end

"""
PSS/E AREA DATA per-area metadata for the `Area` named `area_name`, in PSCB's own `ext`
shape. Call only after [`_has_area_interchange`](@ref) confirms a match exists.
"""
function _area_interchange_ext(data::Dict, area_name::AbstractString)
    for (_, area_data) in data["area_interchange"]
        if haskey(area_data, "area_number") &&
           string(area_data["area_number"]) == area_name
            return Dict{String, Any}(
                "ARNAME" => strip(get(area_data, "area_name", "")),
                "I" => string(get(area_data, "area_number", "")),
                "ISW" => string(get(area_data, "bus_number", "")),
                "PDES" => get(area_data, "net_interchange", ""),
                "PTOL" => get(area_data, "tol_interchange", ""),
            )
        end
    end
    error("_area_interchange_ext: no area_interchange record for area $area_name")
end

"""
Return the id of the named `Area`, creating it on first sight.

The peak stays at `PO.Area`'s own zero default: PSCB never back-fills an `Area`'s peak
from load data — only `LoadZone` does, via `read_loadzones!` — an asymmetry ported rather
than fixed.
"""
function _ensure_area!(sys::OpenAPISystem, data::Dict, name::AbstractString)
    reg = get_registry(sys)
    if has_id(reg, "Area", name)
        return get_id(reg, "Area", name)
    end
    area = stage(PC.Area)
    id = register!(reg, "Area", name)
    set_value!(area, :id, id)
    set_value!(area, :name, name)
    # Area has no device base; base_power records the system base.
    set_value!(area, :base_power, get_base_power(sys), "MVA")
    add_component!(sys, area)
    if _has_area_interchange(data, name)
        set_ext!(sys, id, _area_interchange_ext(data, name))
    end
    return id
end

"""
Sum `data["load"]`'s pd/qd/pi/qi/py/qy per bus zone, converting pm's system per-unit
values to MW/MVAr. Mirrors `read_loadzones!`'s `load_zone_map`.
"""
function _zone_peak_loads(data::Dict, base_power::Float64)
    per_unit_peaks = Dict{Int, Tuple{Float64, Float64}}()
    for load in values(get(data, "load", Dict{String, Any}()))
        zone = data["bus"][load["load_bus"]]["zone"]
        active, reactive = get(per_unit_peaks, zone, (0.0, 0.0))
        active +=
            load["pd"] + get(load, "pi", 0.0) + get(load, "py", 0.0)
        reactive +=
            load["qd"] + get(load, "qi", 0.0) + get(load, "qy", 0.0)
        per_unit_peaks[zone] = (active, reactive)
    end
    return Dict(
        zone => (active * base_power, reactive * base_power) for
        (zone, (active, reactive)) in per_unit_peaks
    )
end

"""
Create one `LoadZone` per distinct bus zone, with the summed bus load as its peak.

Runs before [`read_bus!`](@ref), which resolves each bus's zone to this id.
"""
function read_loadzones!(sys::OpenAPISystem, data::Dict; kwargs...)
    reg = get_registry(sys)
    zones = sort!(collect(Set(b["zone"] for b in values(data["bus"]))))
    peaks = _zone_peak_loads(data, get_base_power(sys))
    _get_name = get(kwargs, :loadzone_name_formatter, string)
    for zone in zones
        name = _get_name(zone)
        active, reactive = get(peaks, zone, (0.0, 0.0))
        load_zone = stage(PC.LoadZone)
        set_value!(load_zone, :id, register!(reg, "LoadZone", name))
        set_value!(load_zone, :name, name)
        set_value!(load_zone, :peak_active_power, active, "MW")
        set_value!(load_zone, :peak_reactive_power, reactive, "MVAr")
        # LoadZone has no device base; base_power records the system base.
        set_value!(load_zone, :base_power, get_base_power(sys), "MVA")
        add_component!(sys, load_zone)
    end
    return
end

"""
Create an `ACBus` per pm dict bus row.

Every bus resolves its `Area` (created lazily here, per the oracle) and its `LoadZone`
(created by [`read_loadzones!`](@ref), which must run first) to an id. Iterates the pm
dict in bus-number order so id assignment — and therefore the emitted document — is
deterministic regardless of `Dict` iteration order.
"""
function read_bus!(sys::OpenAPISystem, data::Dict; kwargs...)
    reg = get_registry(sys)
    bus_data = sort(collect(data["bus"]); by = first)
    unique_names = _unique_bus_names(bus_data)
    default_naming = d -> _default_bus_name(d, unique_names)
    _get_bus_name = get(kwargs, :bus_name_formatter, default_naming)
    _get_area_name = get(kwargs, :area_name_formatter, string)
    _get_zone_name = get(kwargs, :loadzone_name_formatter, string)

    for (_, d) in bus_data
        name = strip(_get_bus_name(d))
        number = Int(d["bus_i"])
        area_id = _ensure_area!(sys, data, _get_area_name(d["area"]))
        zone_id = get_id(reg, "LoadZone", _get_zone_name(d["zone"]))

        bus = stage(PC.ACBus)
        set_value!(bus, :id, register_bus!(reg, number, name))
        set_value!(bus, :number, number)
        set_value!(bus, :name, name)
        set_value!(bus, :available, Bool(get(d, "bus_status", true)))
        set_value!(bus, :bustype, _bustype_name(Int(d["bus_type"])))
        set_value!(bus, :area, area_id)
        set_value!(bus, :load_zone, zone_id)
        set_value!(bus, :base_voltage, d["base_kv"], "kV")
        set_value!(bus, :angle, d["va"], "rad")
        set_value!(bus, :magnitude, d["vm"], "pu")
        set_value!(bus, :voltage_limits, (min = d["vmin"], max = d["vmax"]), "pu")

        # PSS/E's extended-bus-number slack convention (ISW), mapped onto "area_slack"
        # while parsing; overrides whatever bus_type said, matching the oracle. Must be
        # staged before add_component! materializes the bus — components are immutable
        # once built, so a later set_value! would no longer reach the stored copy.
        if get(d, "area_slack", false)
            set_value!(bus, :bustype, "SLACK")
        end
        add_component!(sys, bus)
        set_component_ext!(sys, bus, get(d, "ext", Dict{String, Any}()))
    end
    return
end

"""
Return the id of the `Arc` between two bus ids, creating it on first sight.

Parallel circuits (PSS/E allows several `CKT`s on one bus pair) share one arc.
"""
function add_arc!(sys::OpenAPISystem, from_id::Int, to_id::Int)
    id, created = arc_id!(get_registry(sys), from_id, to_id)
    if created
        arc = stage(PC.Arc)
        set_value!(arc, :id, id)
        set_value!(arc, :from_id, from_id)
        set_value!(arc, :to_id, to_id)
        add_component!(sys, arc)
    end
    return id
end

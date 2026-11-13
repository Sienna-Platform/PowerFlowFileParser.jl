# Dynamic injections and their function blocks, from `.dyr` records.
#
# `assemble_dyr` (pm_io/psse_dyr.jl) gives one `DyrRecord` per (bus, machine id). This file
# emits each record as function blocks plus one dynamic injection, all with ids from the
# document's single counter. The injection names its blocks by id. The static generator
# names the injection in `dynamic_injector` and has the same name. The rules for missing
# and zero-inertia machines come from psy5 `add_dyn_injectors!`.

"""Dynamic data of one system: bus number, then machine id, then record."""
const DynamicRecords = Dict{Int, Dict{String, DyrRecord}}

"""Schema property symbol for a schema field name. The generated types use lowercase names."""
function _dyr_property(::Type{T}, name::AbstractString) where {T}
    prop = Symbol(lowercase(name))
    if !hasfield(T, prop)
        throw(IS.DataFormatError("$(nameof(T)) has no field for schema property $name"))
    end
    return prop
end

_resolve_dyr_value(value, ::Dict{String, Int}, ::Float64) = value
_resolve_dyr_value(value::DyrRef, ids::Dict{String, Int}, ::Float64) = ids[value.class]
_resolve_dyr_value(::DyrSystemFrequency, ::Dict{String, Int}, frequency::Float64) =
    frequency

"""Assign a dynamics field. A field with a declared unit takes its natural unit as the source unit."""
function _set_dyr_field!(s::Staged{T}, prop::Symbol, value) where {T}
    if IC.has_declared_unit(T, Val(prop))
        set_value!(s, prop, value, declared_unit_label(s, prop))
    else
        set_value!(s, prop, value)
    end
    return
end

function _set_dyr_field!(s::Staged{T}, prop::Symbol, value::NamedTuple) where {T}
    if IC.has_declared_unit(T, Val(prop))
        set_value!(s, prop, value, declared_unit_label(s, prop))
    else
        s.fields[prop] = _compound_type(T, prop)(; value...)
    end
    return
end

function _set_dyr_fields!(
    s::Staged{T},
    component::DyrComponent,
    ids::Dict{String, Int},
    frequency::Float64,
) where {T}
    for name in sort!(collect(keys(component.fields)))
        value = _resolve_dyr_value(component.fields[name], ids, frequency)
        _set_dyr_field!(s, _dyr_property(T, name), value)
    end
    return
end

function _dyr_type(type_name::AbstractString)
    if !isdefined(PD, Symbol(type_name))
        throw(IS.DataFormatError("PowerDynamicsOpenAPIModels has no type $type_name"))
    end
    return getfield(PD, Symbol(type_name))
end

function _emit_dyr_block!(
    sys::OpenAPISystem,
    id::Int,
    component::DyrComponent,
    ids::Dict{String, Int},
    frequency::Float64,
)
    block = stage(_dyr_type(component.type))
    set_value!(block, :id, id)
    _set_dyr_fields!(block, component, ids, frequency)
    add_component!(sys, block)
    return
end

# Machine values the `.dyr` file does not hold. psy5 took them from the RAW generator:
# RSORCE goes to R. XSORCE goes to Xd_p of a classical machine.
_override_machine!(::Val, ::Dict{String, Any}, ::Float64, ::Float64, ::AbstractString) =
    nothing

function _override_machine!(
    ::Val{:RoundRotorMachine},
    fields::Dict{String, Any},
    r::Float64,
    ::Float64,
    ::AbstractString,
)
    fields["R"] = r
    return
end

function _override_machine!(
    ::Val{:SalientPoleMachine},
    fields::Dict{String, Any},
    r::Float64,
    ::Float64,
    ::AbstractString,
)
    fields["R"] = r
    return
end

function _override_machine!(
    ::Val{:BaseMachine},
    fields::Dict{String, Any},
    r::Float64,
    x::Float64,
    name::AbstractString,
)
    fields["R"] = r
    if iszero(x)
        @warn "No series reactance found for $name. Setting it to 1e-6"
        x = 1e-6
    end
    fields["Xd_p"] = x
    return
end

function _with_source_impedance(
    record::DyrRecord,
    r::Float64,
    x::Float64,
    name::AbstractString,
)
    components = Pair{String, DyrComponent}[]
    for (class, component) in record.components
        fields = copy(component.fields)
        _override_machine!(Val(Symbol(component.type)), fields, r, x, name)
        push!(components, class => DyrComponent(component.type, fields))
    end
    return components
end

"""
Whether psy5 modeled this record as a voltage source: a classical machine with zero inertia.
"""
function _dyr_is_voltage_source(::Val{:generator}, record::DyrRecord)
    machine = get_component(record, "synchronous_machine_dynamics")
    shaft = get_component(record, "shaft")
    return machine.type == "BaseMachine" && iszero(shaft.fields["H"])
end

_dyr_is_voltage_source(::Val, ::DyrRecord) = false
_dyr_is_voltage_source(record::DyrRecord) = _dyr_is_voltage_source(Val(record.kind), record)

function _emit_dynamics!(
    ::Val{:generator},
    sys::OpenAPISystem,
    components::Vector{Pair{String, DyrComponent}},
    ids::Dict{String, Int},
    name::AbstractString,
    base_power::Float64,
    frequency::Float64,
)
    injection = stage(PD.DynamicGenerator)
    set_value!(injection, :id, next_id!(get_registry(sys)))
    set_value!(injection, :name, name)
    set_value!(injection, :frequency_ref, frequency, "Hz")
    for (class, id) in ids
        if class != "base_machine"
            set_value!(injection, _dyr_property(PD.DynamicGenerator, class), id)
        end
    end
    set_value!(injection, :base_power, base_power, "MVA")
    add_component!(sys, injection)
    return get_value(injection, :id)
end

function _emit_dynamics!(
    ::Val{:inverter},
    sys::OpenAPISystem,
    components::Vector{Pair{String, DyrComponent}},
    ids::Dict{String, Int},
    name::AbstractString,
    base_power::Float64,
    frequency::Float64,
)
    injection = stage(PD.DynamicInverter)
    set_value!(injection, :id, next_id!(get_registry(sys)))
    set_value!(injection, :name, name)
    set_value!(injection, :frequency_ref, frequency, "Hz")
    for (class, id) in ids
        set_value!(injection, _dyr_property(PD.DynamicInverter, class), id)
    end
    _set_nullable!(injection, :current_limitation, nothing)
    set_value!(injection, :base_power, base_power, "MVA")
    add_component!(sys, injection)
    return get_value(injection, :id)
end

function _emit_dynamics!(
    ::Val{:der},
    sys::OpenAPISystem,
    components::Vector{Pair{String, DyrComponent}},
    ids::Dict{String, Int},
    name::AbstractString,
    base_power::Float64,
    frequency::Float64,
)
    injection = stage(PD.AggregateDistributedGenerationA)
    set_value!(injection, :id, next_id!(get_registry(sys)))
    set_value!(injection, :name, name)
    set_value!(injection, :frequency_ref, frequency, "Hz")
    set_value!(injection, :base_power, base_power, "MVA")
    _set_dyr_fields!(injection, only(components).second, ids, frequency)
    add_component!(sys, injection)
    return get_value(injection, :id)
end

# A DER record is the injection itself: it has no separate function blocks.
_dyr_block_classes(::Val, components) = components
_dyr_block_classes(::Val{:der}, components) = Pair{String, DyrComponent}[]

"""
Emit the function blocks and the dynamic injection of `record`, and return the injection id.
`name` is the static generator name, `base_power` its base in MVA, `frequency` the system
frequency in Hz, and `r`/`x` its RSORCE/XSORCE on that base.
"""
function make_dynamic_injection!(
    sys::OpenAPISystem,
    record::DyrRecord,
    name::AbstractString,
    base_power::Float64,
    frequency::Float64,
    r::Float64,
    x::Float64,
)
    reg = get_registry(sys)
    components = _with_source_impedance(record, r, x, name)
    blocks = _dyr_block_classes(Val(record.kind), components)
    ids = Dict{String, Int}(class => next_id!(reg) for (class, _) in blocks)
    for (class, component) in blocks
        _emit_dyr_block!(sys, ids[class], component, ids, frequency)
    end
    return _emit_dynamics!(
        Val(record.kind), sys, components, ids, name, base_power, frequency,
    )
end

"""
A `Source` in place of a generator: a Thevenin impedance behind the bus. psy5 used it for a
generator without dynamic data and for a zero-inertia classical machine. `r` and `x` are on
the generator base `mbase` and move to the system base.
"""
function make_source_from_generator!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    bus_id::Int,
    pm_gen::Dict,
    gen_name::AbstractString,
    sys_mbase::Float64,
    r::Float64,
    x::Float64,
)
    mbase = _device_base_power(pm_gen, gen_name, sys_mbase)
    if iszero(x)
        @warn "No series reactance found for $gen_name. Setting it to 1e-6"
        x = 1e-6
    end
    component = stage(PO.Source)
    set_value!(component, :id, register!(reg, "Source", gen_name))
    set_value!(component, :name, gen_name)
    set_value!(component, :available, Bool(pm_gen["gen_status"]))
    set_value!(component, :bus, bus_id)
    _set_remote_regulated_bus!(component, reg, pm_gen, bus_id)
    set_value!(component, :operation_cost, make_source_cost())
    set_value!(component, :active_power, pm_gen["pg"] * sys_mbase, "MW")
    set_value!(component, :reactive_power, pm_gen["qg"] * sys_mbase, "MVAr")
    set_value!(component, :parameter_units, "COMPONENT_BASE")
    set_value!(component, :r_th, r * sys_mbase / mbase, "pu")
    set_value!(component, :x_th, x * sys_mbase / mbase, "pu")
    set_value!(component, :base_power, sys_mbase, "MVA")
    add_component!(sys, component)
    set_component_ext!(sys, component, _generator_ext(pm_gen))
    return
end

_supports_dynamics(::Val) = false
_supports_dynamics(::Val{:ThermalStandard}) = true
_supports_dynamics(::Val{:SynchronousCondenser}) = true

function _machine_id(pm_gen::Dict, gen_name::AbstractString)
    if !haskey(pm_gen, "source_id")
        throw(
            IS.DataFormatError(
                "generator $gen_name has no source_id, so it cannot match a .dyr record",
            ),
        )
    end
    return String(strip(string(last(pm_gen["source_id"]))))
end

_has_dyr_record(records::DynamicRecords, bus::Int, id::AbstractString) =
    haskey(records, bus) && haskey(records[bus], id)

"""
Apply the dynamic data to one generator, before its static device is staged.

Returns `true` when the generator became a `Source`, so the caller must not build the static
device. Otherwise it emits the dynamic injection and records its id for the generator.
"""
function _apply_generator_dynamics!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    records::DynamicRecords,
    used::Set{Tuple{Int, String}},
    type_name::AbstractString,
    bus_id::Int,
    pm_gen::Dict,
    gen_name::AbstractString,
    sys_mbase::Float64,
    frequency::Float64,
)
    bus = Int(pm_gen["gen_bus"])
    id = _machine_id(pm_gen, gen_name)
    supported = _supports_dynamics(Val(Symbol(type_name)))
    if !_has_dyr_record(records, bus, id)
        if !supported
            return false
        end
        @warn "Generator at bus $bus, id $id not found in dynamic data. A voltage source models it."
        make_source_from_generator!(
            sys, reg, bus_id, pm_gen, gen_name, sys_mbase,
            Float64(pm_gen["r_source"]), Float64(pm_gen["x_source"]),
        )
        return true
    end
    if !supported
        throw(
            IS.DataFormatError(
                "generator $gen_name at bus $bus, id $id is a $type_name, which cannot carry dynamic data",
            ),
        )
    end
    push!(used, (bus, id))
    record = records[bus][id]
    r = Float64(pm_gen["r_source"])
    x = Float64(pm_gen["x_source"])
    if _dyr_is_voltage_source(record)
        @info "Machine at bus $bus, id $id has zero inertia. A voltage source models it."
        make_source_from_generator!(sys, reg, bus_id, pm_gen, gen_name, sys_mbase, r, x)
        return true
    end
    mbase = _device_base_power(pm_gen, gen_name, sys_mbase)
    reg.dynamic_injectors[gen_name] =
        make_dynamic_injection!(sys, record, gen_name, mbase, frequency, r, x)
    return false
end

"""Name the dynamic injection of `gen_name` on its staged static device, when it has one."""
function _set_dynamic_injector!(component, reg::IdRegistry, gen_name::AbstractString)
    if haskey(reg.dynamic_injectors, gen_name)
        set_value!(component, :dynamic_injector, reg.dynamic_injectors[gen_name])
    end
    return
end

"""
System frequency in Hz from the RAW case header (`BASFRQ`). Needed only when there is
dynamic data; without it the value is unused.
"""
function _dynamics_frequency(data::Dict, records::DynamicRecords)
    if isempty(records)
        return 0.0
    end
    if !haskey(data, "base_frequency")
        throw(
            IS.DataFormatError(
                "dynamic data needs the system frequency, but the case has no base_frequency (PSS/E BASFRQ)",
            ),
        )
    end
    frequency = Float64(data["base_frequency"])
    if frequency <= 0.0
        throw(IS.DataFormatError("base_frequency must be positive, got $frequency"))
    end
    return frequency
end

function _report_unused_dynamics(records::DynamicRecords, used::Set{Tuple{Int, String}})
    unused = sum(length(by_id) for by_id in values(records); init = 0) - length(used)
    if unused > 0
        @info "$unused generators provided in .dyr, without a generator in the .raw file, are skipped."
    end
    return
end

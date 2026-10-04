# The function creates one FixedForcedOutage for each contingency that has an emittable
# element. A SupplementalAttributeAssociation links the outage to the component of each
# element. It runs after the builder creates every component. So the outage ids follow the
# component ids, and a pm dict without "contingency" gives a byte-identical document.

"""The (action, pm section) pairs that map to a component that the schemas can outage. Switching
devices (sections switch/breaker/generic_connector) are DiscreteControlledACBranch
components, and the emitter treats them like branches. Bus disconnects arrive already
expanded into these pairs."""
const _EMITTABLE_CONTINGENCY_ELEMENTS = Set([
    ("open_branch", "branch"),
    ("open_branch", "switch"),
    ("open_branch", "breaker"),
    ("open_branch", "generic_connector"),
    ("open_3w_transformer", "3w_transformer"),
    ("remove_unit", "gen"),
    ("remove_load", "load"),
    ("remove_shunt", "shunt"),
    ("remove_switched_shunt", "switched_shunt"),
])

function _is_emittable_element(element::Dict)
    return (element["action"], element["section"]) in _EMITTABLE_CONTINGENCY_ELEMENTS
end

function _monitored_component_ids(reg::IdRegistry, branch_keys)
    ids = [get_source_id(reg, section, key) for (section, key) in branch_keys]
    return sort!(unique!(ids))
end

"""
Emit `data["contingency"]` into `sys`. Each contingency gets one `FixedForcedOutage`
(`outage_status = 1.0`, `identifier` = the contingency key). Each emittable element gets one
association row. A contingency with no emittable element creates no outage. One summary `@warn`
gives the counts.

When `data["monitor"]` is present with `"all_branches" => false`, every emitted outage gets
`monitored_components`. The value is the sorted unique document ids of the monitored branches.
The function resolves each `[section, key]` pair through the registry. Every outage repeats
the id list, so the document grows with contingencies x monitored branches.

With `"all_branches" => true`, the function writes no `monitored_components`, because a list
of every branch on every outage does not scale. A document without `monitored_components`
monitors all branches.

The function does not emit monitored buses and the voltage band, because PSY validates the ids
as devices. They stay in the pm dict. Without `data["monitor"]`, the field is absent.
"""
function read_contingencies!(sys::OpenAPISystem, data::Dict; kwargs...)
    contingencies = get(data, "contingency", Dict{String, Any}())
    reg = get_registry(sys)
    has_monitor = haskey(data, "monitor")
    monitored = Int[]
    write_monitored = has_monitor && !get(data["monitor"], "all_branches", false)
    if has_monitor && !write_monitored
        @info "All branches are monitored by default: monitored_components is not written. " *
              "Buses and the voltage band are parsed only, not emitted."
    elseif has_monitor
        @info "pm dict has \"monitor\" data: monitored branches go into each outage's " *
              "monitored_components; buses and the voltage band are parsed only, not emitted."
        monitored = _monitored_component_ids(reg, data["monitor"]["branches"])
    end
    document = get_document(sys)
    empty_contingencies = 0
    for identifier in sort!(collect(keys(contingencies)))
        elements = contingencies[identifier]["elements"]
        emittable = filter(_is_emittable_element, elements)
        if isempty(emittable)
            empty_contingencies += 1
            continue
        end
        component_ids = unique(
            get_source_id(reg, e["section"], e["key"]) for e in emittable
        )
        outage = stage(PO.FixedForcedOutage)
        set_value!(outage, :id, next_id!(reg))
        set_value!(outage, :outage_status, 1.0)
        set_value!(outage, :identifier, String(identifier))
        if write_monitored
            set_value!(outage, :monitored_components, monitored)
        end
        add_supplemental_attribute!(sys, outage, first(component_ids))
        for component_id in Iterators.drop(component_ids, 1)
            add_supplemental_attribute_association!(
                sys, outage, component_id, document.component_types_by_id[component_id],
            )
        end
    end
    if !iszero(empty_contingencies)
        @warn "$empty_contingencies contingencies have no emittable element and create no outage."
    end
    return
end

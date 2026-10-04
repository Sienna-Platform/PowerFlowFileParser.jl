# One FixedForcedOutage per contingency with at least one emittable element, linked to each
# element's component by a SupplementalAttributeAssociation. Runs after every component is
# built so outage ids follow component ids and a pm dict without "contingency" emits a
# byte-identical document.

"""(action, pm section) pairs that map to a component the schemas can outage. Switching
devices (sections switch/breaker/generic_connector) are DiscreteControlledACBranch
components and are emitted like branches; `open_bus` has no sink yet."""
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

function _is_bus_element(element::Dict)
    return element["action"] == "open_bus"
end

function _monitored_component_ids(reg::IdRegistry, branch_keys)
    ids = [get_source_id(reg, section, key) for (section, key) in branch_keys]
    return sort!(unique!(ids))
end

"""
Emit `data["contingency"]` into `sys`: one `FixedForcedOutage` (`outage_status = 1.0`,
`identifier` = the contingency key) per contingency, and one association row per emittable
element. `open_bus` elements are not emitted; a
contingency left with no emittable element creates no outage. One summary `@warn` gives the
counts.

When `data["monitor"]` is present, every emitted outage gets `monitored_components` = the
sorted unique document ids of the monitored branches (`[section, key]` pairs resolved through the
registry). The id list is repeated on every outage, so the document grows with contingencies x monitored branches.
Monitored buses and the voltage band are not emitted (PSY validates the ids as devices);
they stay in the pm dict. Without `data["monitor"]` the field is absent.
"""
function read_contingencies!(sys::OpenAPISystem, data::Dict; kwargs...)
    contingencies = get(data, "contingency", Dict{String, Any}())
    reg = get_registry(sys)
    has_monitor = haskey(data, "monitor")
    monitored = Int[]
    if has_monitor
        @info "pm dict has \"monitor\" data: monitored branches go into each outage's " *
              "monitored_components; buses and the voltage band are parsed only, not emitted."
        monitored = _monitored_component_ids(reg, data["monitor"]["branches"])
    end
    document = get_document(sys)
    skipped_bus = 0
    empty_contingencies = 0
    for identifier in sort!(collect(keys(contingencies)))
        elements = contingencies[identifier]["elements"]
        emittable = filter(_is_emittable_element, elements)
        skipped_bus += count(_is_bus_element, elements)
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
        if has_monitor
            set_value!(outage, :monitored_components, monitored)
        end
        add_supplemental_attribute!(sys, outage, first(component_ids))
        for component_id in Iterators.drop(component_ids, 1)
            add_supplemental_attribute_association!(
                sys, outage, component_id, document.component_types_by_id[component_id],
            )
        end
    end
    if !iszero(skipped_bus + empty_contingencies)
        @warn "Contingencies not fully emitted: $skipped_bus open_bus elements skipped, " *
              "$empty_contingencies contingencies left with no emittable element create no outage."
    end
    return
end

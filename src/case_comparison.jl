# --- Constants ---

"""Component types tracked for availability diffs."""
const DIFF_COMPONENT_TYPES = [
    "bus", "gen", "branch", "load", "shunt", "storage", "switch", "dcline",
]

"""Maps component type to the field name that indicates its status."""
const COMPONENT_STATUS_KEY = Dict{String, String}(
    "bus" => "bus_type",
    "load" => "status",
    "shunt" => "status",
    "gen" => "gen_status",
    "storage" => "status",
    "switch" => "status",
    "branch" => "br_status",
    "dcline" => "br_status",
)

"""Maps component type to the value that means inactive/unavailable."""
const COMPONENT_STATUS_INACTIVE = Dict{String, Int}(
    "bus" => 4,
    "load" => 0,
    "shunt" => 0,
    "gen" => 0,
    "storage" => 0,
    "switch" => 0,
    "branch" => 0,
    "dcline" => 0,
)

"""Default fields to ignore when computing diffs (operating-point values, not topology)."""
const DEFAULT_IGNORED_FIELDS = Set([
    "pg", "qg",       # generator active/reactive output
    "pd", "qd",       # load active/reactive demand
    "vm", "va",       # bus voltage magnitude/angle
    "index",          # positional index (not stable across files)
])

# --- Component identity helpers ---

"""
    component_key(component::Dict{String, Any}) -> String

Build a stable string key from a component's `source_id`.
This is the canonical identifier for matching components across case files.
"""
function component_key(component::Dict{String, Any})::String
    return join(string.(component["source_id"]), "_")
end

"""
    index_by_source_id(components) -> Dict{String, Dict{String, Any}}

Re-key a collection of components (Vector or Dict) by their `source_id` string key.
"""
function index_by_source_id(components)::Dict{String, Dict{String, Any}}
    result = Dict{String, Dict{String, Any}}()
    for comp in values(components)
        key = component_key(comp)
        result[key] = comp
    end
    return result
end

# --- Diff data structure ---

"""
Records how a single component differs between the base case and a specific case.

# Fields
- `source_id`: The component's `source_id` vector for traceability.
- `status_change`: `base_status => case_status` if status differs, `nothing` otherwise.
- `missing_in_case`: `true` if the component exists in the base but not in this case.
- `other_changes`: Non-ignored field differences as `field => (base_val => case_val)`.
"""
struct ComponentDiff
    source_id::Vector{Any}
    status_change::Union{Nothing, Pair{Int, Int}}
    missing_in_case::Bool
    other_changes::Dict{String, Pair{Any, Any}}
end

# --- Core algorithms ---

"""
    compile_base_case(cases, base_case_name; [ignored_fields]) -> Dict{String, Any}

Build a union dictionary from all case files. Component values come from the
reference file (`base_case_name`); components that only appear in other files
are added from those files. Component collections are re-keyed by `source_id`.
"""
function compile_base_case(
    cases::Dict{String, PowerModelsData},
    base_case_name::String,
)::Dict{String, Any}
    haskey(cases, base_case_name) ||
        error("Base case '$base_case_name' not found in cases")
    ref_data = deepcopy(cases[base_case_name].data)

    for comp_type in DIFF_COMPONENT_TYPES
        haskey(ref_data, comp_type) || continue
        ref_components = ref_data[comp_type]
        isempty(ref_components) && continue

        ref_indexed = index_by_source_id(ref_components)

        for (name, case_pm) in cases
            name == base_case_name && continue
            haskey(case_pm.data, comp_type) || continue
            for comp in values(case_pm.data[comp_type])
                key = component_key(comp)
                if !haskey(ref_indexed, key)
                    ref_indexed[key] = deepcopy(comp)
                    @info "Added $comp_type component $key to base case from $name"
                end
            end
        end

        # Replace the positional structure with a source_id–keyed dict
        ref_data[comp_type] = ref_indexed
    end

    return ref_data
end

"""
    compute_case_diff(base, case_data; [ignored_fields]) -> Dict{String, Dict{String, ComponentDiff}}

Compare a single case against the compiled base case.
Returns only components that differ (status change, missing, or other field changes).

`ignored_fields` defaults to `DEFAULT_IGNORED_FIELDS` (pg, qg, pd, qd, vm, va, index).
"""
function compute_case_diff(
    base::Dict{String, Any},
    case_data::Dict{String, Any};
    ignored_fields::Set{String}=DEFAULT_IGNORED_FIELDS,
)::Dict{String, Dict{String, ComponentDiff}}
    diff = Dict{String, Dict{String, ComponentDiff}}()

    for comp_type in DIFF_COMPONENT_TYPES
        haskey(base, comp_type) || continue
        base_components = base[comp_type]
        isempty(base_components) && continue

        case_indexed = if haskey(case_data, comp_type) && !isempty(case_data[comp_type])
            index_by_source_id(case_data[comp_type])
        else
            Dict{String, Dict{String, Any}}()
        end

        status_key = COMPONENT_STATUS_KEY[comp_type]
        inactive_val = COMPONENT_STATUS_INACTIVE[comp_type]
        comp_diffs = Dict{String, ComponentDiff}()

        for (key, base_comp) in base_components
            if !haskey(case_indexed, key)
                # Component exists in base but not in this case → unavailable
                comp_diffs[key] = ComponentDiff(
                    base_comp["source_id"],
                    get(base_comp, status_key, 1) => inactive_val,
                    true,
                    Dict{String, Pair{Any, Any}}(),
                )
                continue
            end

            case_comp = case_indexed[key]
            base_status = get(base_comp, status_key, 1)
            case_status = get(case_comp, status_key, 1)

            status_change = base_status != case_status ?
                            (base_status => case_status) : nothing

            # Collect non-ignored field differences
            other_changes = Dict{String, Pair{Any, Any}}()
            for (field, base_val) in base_comp
                field in ignored_fields && continue
                field == "source_id" && continue
                field == status_key && continue
                case_val = get(case_comp, field, nothing)
                if case_val !== nothing && base_val != case_val
                    other_changes[field] = base_val => case_val
                end
            end

            if status_change !== nothing || !isempty(other_changes)
                comp_diffs[key] = ComponentDiff(
                    base_comp["source_id"],
                    status_change,
                    false,
                    other_changes,
                )
            end
        end

        if !isempty(comp_diffs)
            diff[comp_type] = comp_diffs
        end
    end

    return diff
end

# --- Container struct ---

"""
Container for comparing multiple power flow case files against a compiled base case.

# Fields
- `cases`: All parsed cases keyed by name (typically filename).
- `base_case`: Compiled union dictionary with components keyed by `source_id`.
- `cases_diff`: Per-case diffs. `cases_diff[name][comp_type][key]` is a `ComponentDiff`.

# Constructors

    CaseComparisonData(folder; base_case_name, kwargs...)

Load all power flow files (`.raw`, `.m`) from `folder`, compile a union base case,
and compute per-case diffs.

    CaseComparisonData(cases, base_case_name; ignored_fields)

Build from a pre-populated `Dict{String, PowerModelsData}`.
"""
struct CaseComparisonData
    cases::Dict{String, PowerModelsData}
    base_case::Dict{String, Any}
    cases_diff::Dict{String, Dict{String, Dict{String, ComponentDiff}}}
end

function CaseComparisonData(
    cases::Dict{String, PowerModelsData},
    base_case_name::String;
    ignored_fields::Set{String}=DEFAULT_IGNORED_FIELDS,
)
    base_case = compile_base_case(cases, base_case_name)

    cases_diff = Dict{String, Dict{String, Dict{String, ComponentDiff}}}()
    for (name, case_pm) in cases
        name == base_case_name && continue
        cases_diff[name] = compute_case_diff(
            base_case, case_pm.data; ignored_fields=ignored_fields,
        )
    end

    return CaseComparisonData(cases, base_case, cases_diff)
end

const _SUPPORTED_EXTENSIONS = Set([".raw", ".m"])

function CaseComparisonData(
    folder::AbstractString;
    base_case_name::AbstractString,
    ignored_fields::Set{String}=DEFAULT_IGNORED_FIELDS,
    kwargs...,
)
    isdir(folder) || error("Directory not found: $folder")

    files = filter(readdir(folder)) do f
        _, ext = splitext(f)
        return ext in _SUPPORTED_EXTENSIONS
    end
    isempty(files) && error("No supported power flow files found in $folder")
    base_case_name in files ||
        error("Base case '$base_case_name' not found in $folder")

    cases = Dict{String, PowerModelsData}()
    for filename in files
        filepath = joinpath(folder, filename)
        @info "Parsing case: $filename"
        cases[filename] = PowerModelsData(filepath; kwargs...)
    end

    return CaseComparisonData(cases, base_case_name; ignored_fields=ignored_fields)
end

# --- Query helpers ---

"""
    unavailable_components(ccd, case_name) -> Dict{String, Vector{Vector{Any}}}

Return all components that are unavailable in the given case
(either missing entirely or with status set to inactive).
"""
function unavailable_components(
    ccd::CaseComparisonData,
    case_name::String,
)::Dict{String, Vector{Vector{Any}}}
    diff = get(ccd.cases_diff, case_name, nothing)
    diff === nothing && return Dict{String, Vector{Vector{Any}}}()

    result = Dict{String, Vector{Vector{Any}}}()
    for (comp_type, comp_diffs) in diff
        inactive_val = COMPONENT_STATUS_INACTIVE[comp_type]
        unavail = Vector{Any}[]
        for (_, cd) in comp_diffs
            if cd.missing_in_case
                push!(unavail, cd.source_id)
            elseif cd.status_change !== nothing && cd.status_change.second == inactive_val
                push!(unavail, cd.source_id)
            end
        end
        !isempty(unavail) && (result[comp_type] = unavail)
    end
    return result
end

"""
    diff_summary(ccd::CaseComparisonData)

Print a summary table of diff counts for each case and component type.
"""
function diff_summary(ccd::CaseComparisonData)
    for (case_name, diff) in sort(collect(ccd.cases_diff); by=first)
        println("Case: $case_name")
        for comp_type in DIFF_COMPONENT_TYPES
            haskey(diff, comp_type) || continue
            comp_diffs = diff[comp_type]
            n_missing = count(cd -> cd.missing_in_case, values(comp_diffs))
            n_status = count(
                cd -> cd.status_change !== nothing && !cd.missing_in_case,
                values(comp_diffs),
            )
            n_other = count(cd -> !isempty(cd.other_changes), values(comp_diffs))
            println("  $comp_type: $n_missing missing, $n_status status changes, $n_other other diffs")
        end
    end
end

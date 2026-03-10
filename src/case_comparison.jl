# --- Constants ---

# Reuse component type/status mappings from pm_io/data.jl
const DIFF_COMPONENT_TYPES = sort!(collect(keys(pm_component_status)))

const _EMPTY_CHANGES = Dict{String, Pair{Any, Any}}()

"""Default fields to ignore when computing diffs (operating-point values, not topology)."""
const DEFAULT_IGNORED_FIELDS = Set([
    "pg", "qg",       # generator active/reactive output
    "pd", "qd",       # load active/reactive demand
    "vm", "va",       # bus voltage magnitude/angle
    "index",          # positional index (not stable across files)
])

"""Default coefficient of variation threshold below which a load is flagged as
potentially non-conforming. A CV of 0.05 means demand varies by less than 5%
of its mean across cases."""
const DEFAULT_NONCONFORMING_CV_THRESHOLD = 0.05

"""Default minimum absolute active power (MW) for a load to be considered in
the non-conforming heuristic. Small loads are excluded since low variation on
small values is not meaningful."""
const DEFAULT_NONCONFORMING_MIN_PD = 1.0

# --- Component identity helpers ---

"""
    component_key(component::Dict{String, Any}) -> String

Build a stable string key from a component's `source_id`.
This is the canonical identifier for matching components across case files.
"""
function component_key(component::Dict{String, Any})::String
    return join(component["source_id"], "_")
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
    compile_base_case(cases, base_case_name) -> Dict{String, Any}

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
    ref_data = copy(cases[base_case_name].data)

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

        status_key = pm_component_status[comp_type]
        inactive_val = pm_component_status_inactive[comp_type]
        comp_diffs = Dict{String, ComponentDiff}()

        for (key, base_comp) in base_components
            if !haskey(case_indexed, key)
                # Component exists in base but not in this case → unavailable
                comp_diffs[key] = ComponentDiff(
                    base_comp["source_id"],
                    get(base_comp, status_key, 1) => inactive_val,
                    true,
                    _EMPTY_CHANGES,
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
        inactive_val = pm_component_status_inactive[comp_type]
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
    diff_summary(ccd::CaseComparisonData; io::IO=stdout)

Print a summary table of diff counts for each case and component type.
"""
function diff_summary(ccd::CaseComparisonData; io::IO=stdout)
    for (case_name, diff) in sort(collect(ccd.cases_diff); by=first)
        println(io, "Case: $case_name")
        for comp_type in DIFF_COMPONENT_TYPES
            haskey(diff, comp_type) || continue
            comp_diffs = diff[comp_type]
            n_missing = 0
            n_status = 0
            n_other = 0
            for cd in values(comp_diffs)
                if cd.missing_in_case
                    n_missing += 1
                elseif cd.status_change !== nothing
                    n_status += 1
                end
                !isempty(cd.other_changes) && (n_other += 1)
            end
            println(io, "  $comp_type: $n_missing missing, $n_status status changes, $n_other other diffs")
        end
    end
end

# --- Non-conforming load detection ---

"""
Reason why a load was flagged as potentially non-conforming.
"""
@enum NonConformingReason begin
    FLAGGED_IN_DATA       # conformity field == 0 in the parsed data
    LOW_VARIATION         # demand varies less than the CV threshold across cases
end

"""
A load flagged as potentially non-conforming.

# Fields
- `source_id`: The load's `source_id` vector.
- `bus`: The bus number the load is connected to.
- `reason`: Why the load was flagged ([`NonConformingReason`](@ref)).
- `mean_pd`: Mean active power demand across all cases (MW, in system base).
- `cv_pd`: Coefficient of variation of active power demand across cases
  (`NaN` when `reason == FLAGGED_IN_DATA` and the load appears in a single case).
- `pd_values`: Active power demand in each case, keyed by case name.
"""
struct NonConformingLoadFlag
    source_id::Vector{Any}
    bus::Int
    reason::NonConformingReason
    mean_pd::Float64
    cv_pd::Float64
    pd_values::Dict{String, Float64}
end

"""
    flag_nonconforming_loads(ccd; cv_threshold, min_pd) -> Vector{NonConformingLoadFlag}

Identify loads that are likely non-conforming based on two criteria:

1. **Explicit flag**: Loads with `conformity == 0` in any case file (from PSS/E `SCALE`
   field or MATPOWER annotation).
2. **Low seasonal variation**: Active loads present in at least two cases where the
   coefficient of variation (std / |mean|) of `pd` across cases falls below
   `cv_threshold` and the absolute mean demand exceeds `min_pd`.

Returns a vector of [`NonConformingLoadFlag`](@ref) sorted by descending mean demand.
Each load appears at most once; if both criteria match, the explicit flag takes priority.
"""
function flag_nonconforming_loads(
    ccd::CaseComparisonData;
    cv_threshold::Float64=DEFAULT_NONCONFORMING_CV_THRESHOLD,
    min_pd::Float64=DEFAULT_NONCONFORMING_MIN_PD,
)::Vector{NonConformingLoadFlag}
    # Collect per-load pd values and conformity flags across all cases
    # Key: source_id string, Value: (source_id, bus, conformity_zero, pd_per_case)
    load_info = Dict{String, @NamedTuple{
        source_id::Vector{Any},
        bus::Int,
        conformity_zero::Bool,
        pd_per_case::Dict{String, Float64},
    }}()

    for (case_name, case_pm) in ccd.cases
        loads = get(case_pm.data, "load", nothing)
        loads === nothing && continue
        isempty(loads) && continue

        for load in values(loads)
            key = component_key(load)
            pd = get(load, "pd", 0.0)::Float64
            bus = get(load, "load_bus", 0)::Int
            conformity = get(load, "conformity", 1)

            if haskey(load_info, key)
                info = load_info[key]
                info.pd_per_case[case_name] = pd
                if conformity == 0
                    load_info[key] = (
                        source_id=info.source_id,
                        bus=info.bus,
                        conformity_zero=true,
                        pd_per_case=info.pd_per_case,
                    )
                end
            else
                load_info[key] = (
                    source_id=load["source_id"],
                    bus=bus,
                    conformity_zero=(conformity == 0),
                    pd_per_case=Dict{String, Float64}(case_name => pd),
                )
            end
        end
    end

    flags = NonConformingLoadFlag[]

    for (_, info) in load_info
        pd_vals = collect(values(info.pd_per_case))
        n = length(pd_vals)
        mean_pd = n > 0 ? sum(pd_vals) / n : 0.0

        # Criterion 1: explicitly flagged as non-conforming
        if info.conformity_zero
            cv = if n >= 2 && abs(mean_pd) > 0.0
                std_pd = sqrt(sum((v - mean_pd)^2 for v in pd_vals) / (n - 1))
                std_pd / abs(mean_pd)
            else
                NaN
            end
            push!(flags, NonConformingLoadFlag(
                info.source_id, info.bus, FLAGGED_IN_DATA, mean_pd, cv, info.pd_per_case,
            ))
            continue
        end

        # Criterion 2: low variation heuristic (need at least 2 cases)
        n < 2 && continue
        abs(mean_pd) < min_pd && continue

        std_pd = sqrt(sum((v - mean_pd)^2 for v in pd_vals) / (n - 1))
        cv = std_pd / abs(mean_pd)
        if cv < cv_threshold
            push!(flags, NonConformingLoadFlag(
                info.source_id, info.bus, LOW_VARIATION, mean_pd, cv, info.pd_per_case,
            ))
        end
    end

    sort!(flags; by=f -> -abs(f.mean_pd))
    return flags
end

"""
    nonconforming_load_summary(flags; io=stdout)

Print a summary table of flagged non-conforming loads.
"""
function nonconforming_load_summary(
    flags::Vector{NonConformingLoadFlag};
    io::IO=stdout,
)
    isempty(flags) && (println(io, "No non-conforming loads flagged."); return)

    n_explicit = count(f -> f.reason == FLAGGED_IN_DATA, flags)
    n_heuristic = count(f -> f.reason == LOW_VARIATION, flags)
    println(io, "Non-conforming load flags: $n_explicit explicit, $n_heuristic low-variation")

    # Header
    println(io, "  $(rpad("Source ID", 30)) $(lpad("Bus", 8)) $(lpad("Mean PD", 10)) $(lpad("CV", 8))  Reason")
    println(io, "  $(repeat("─", 30)) $(repeat("─", 8)) $(repeat("─", 10)) $(repeat("─", 8))  $(repeat("─", 16))")

    for f in flags
        sid = join(f.source_id, "_")
        cv_str = isnan(f.cv_pd) ? "N/A" : @sprintf("%.4f", f.cv_pd)
        reason_str = f.reason == FLAGGED_IN_DATA ? "explicit (SCALE=0)" : "low variation"
        println(io, "  $(rpad(sid, 30)) $(lpad(string(f.bus), 8)) $(lpad(@sprintf("%.2f", f.mean_pd), 10)) $(lpad(cv_str, 8))  $reason_str")
    end
end

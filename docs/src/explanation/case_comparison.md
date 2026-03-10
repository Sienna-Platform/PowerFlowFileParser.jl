# Case Comparison

PowerFlowFileParser provides utilities for comparing multiple power flow case files against a common base case. This is useful for identifying topology changes, outage scenarios, and parameter differences across related network models.

## Overview

The comparison workflow has three steps:

 1. **Parse** all case files into `PowerModelsData` containers
 2. **Compile** a union base case that includes every component found across all files
 3. **Diff** each case against the base to identify missing components, status changes, and parameter differences

The [`CaseComparisonData`](@ref) struct orchestrates all three steps.

## How It Works

### Base Case Compilation

[`compile_base_case`](@ref) builds a union dictionary from all case files. Components are re-keyed by their `source_id` (a stable identifier from the original file) rather than positional index. The reference file provides default values; components that only appear in other files are added to ensure every component is tracked.

### Diff Computation

[`compute_case_diff`](@ref) compares each case against the compiled base. For every component it checks:

  - **Missing**: Component exists in base but not in the case (treated as unavailable)
  - **Status change**: Component status field differs (e.g., generator taken offline)
  - **Other changes**: Any non-ignored field value differs between base and case

Operating-point fields (`pg`, `qg`, `pd`, `qd`, `vm`, `va`) and the positional `index` are ignored by default since they reflect solver output rather than topology.

### Component Identity

Components are matched across files using their `source_id` field, which is set during parsing from the original file record identifiers (e.g., bus number, branch terminal buses and circuit ID). This is more stable than dictionary index keys, which can change when components are added or removed.

## Usage

### From a folder of case files

```julia
using PowerFlowFileParser

ccd = CaseComparisonData(
    "path/to/cases/";
    base_case_name="base.raw",
)
```

### From pre-parsed cases

```julia
cases = Dict(
    "base.raw" => PowerModelsData("base.raw"),
    "outage1.raw" => PowerModelsData("outage1.raw"),
    "outage2.raw" => PowerModelsData("outage2.raw"),
)
ccd = CaseComparisonData(cases, "base.raw")
```

### Querying results

```julia
# Print a summary of differences across all cases
diff_summary(ccd)

# Get unavailable components for a specific case
unavail = unavailable_components(ccd, "outage1.raw")
# Returns: Dict("gen" => [...source_ids...], "branch" => [...source_ids...])

# Access the raw diff for detailed inspection
case_diff = ccd.cases_diff["outage1.raw"]
for (comp_type, comp_diffs) in case_diff
    for (key, cd) in comp_diffs
        println("$(comp_type) $(cd.source_id): missing=$(cd.missing_in_case)")
    end
end
```

## Data Structures

### CaseComparisonData

Top-level container holding:

  - `cases`: All parsed `PowerModelsData` objects keyed by filename
  - `base_case`: Compiled union dictionary with components keyed by `source_id`
  - `cases_diff`: Per-case diffs organized as `cases_diff[name][comp_type][key]`

### ComponentDiff

Records how a single component differs from the base case:

  - `source_id::Vector{Any}` -- original file identifiers
  - `status_change::Union{Nothing, Pair{Int, Int}}` -- base status => case status, if changed
  - `missing_in_case::Bool` -- component not present in the case file
  - `other_changes::Dict{String, Pair{Any, Any}}` -- field-level differences

### Tracked Component Types

All standard PowerModels component types are tracked: `bus`, `gen`, `branch`, `load`, `shunt`, `storage`, `switch`, and `dcline`. Status field names and inactive values follow the conventions defined in `pm_component_status` and `pm_component_status_inactive`.

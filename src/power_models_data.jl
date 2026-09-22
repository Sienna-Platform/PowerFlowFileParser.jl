"""
Container for data parsed by PowerModels.

# Fields
- `data::Dict{String, Any}`: Dictionary containing the parsed power system data

# Example
```julia
pm_data = PowerModelsData("case5.m")
# Access the data dictionary
baseMVA = pm_data.data["baseMVA"]
buses = pm_data.data["bus"]
```
"""
struct PowerModelsData
    data::Dict{String, Any}
end

"""
Constructs PowerModelsData from a raw file.
Currently Supports MATPOWER and PSSE data files parsed by PowerModels.

# Arguments
- `file::Union{String, IO}`: Path to the file or IO stream to parse

# Keyword Arguments
- `pm_data_corrections::Bool=true`: Run PowerModels data corrections (validation)
- `import_all::Bool=false`: Import all fields from PTI files
- `correct_branch_rating::Bool=true`: Correct branch ratings during parsing
- `solved_case::Bool=false`: Treat a PSS(R)E .raw file as written out from a converged
  power flow, so switched shunts take BINIT as their solved admittance

# Example
```julia
pm_data = PowerModelsData("case5.m")
pm_data = PowerModelsData("system.raw"; import_all=true)
```
"""
function PowerModelsData(file::Union{String, IO}; kwargs...)
    validate = get(kwargs, :pm_data_corrections, true)
    import_all = get(kwargs, :import_all, false)
    correct_branch_rating = get(kwargs, :correct_branch_rating, true)
    solved_case = get(kwargs, :solved_case, false)
    pm_dict = parse_file(
        file;
        import_all = import_all,
        validate = validate,
        correct_branch_rating = correct_branch_rating,
        solved_case = solved_case,
    )
    pm_data = PowerModelsData(pm_dict)
    correct_pm_transformer_status!(pm_data)
    return pm_data
end

"""
Corrects transformer status in PowerModelsData based on bus voltage differences.

Identifies branches that should be transformers by comparing voltage levels at
connected buses. If the voltage difference exceeds the threshold
(BRANCH_BUS_VOLTAGE_DIFFERENCE_TOL), the branch is converted to a transformer.

# Arguments
- `pm_data::PowerModelsData`: PowerModels data object to correct
"""
function correct_pm_transformer_status!(pm_data::PowerModelsData)
    for (k, branch) in pm_data.data["branch"]
        f_bus_bvolt = pm_data.data["bus"][branch["f_bus"]]["base_kv"]
        t_bus_bvolt = pm_data.data["bus"][branch["t_bus"]]["base_kv"]
        percent_difference =
            abs(f_bus_bvolt - t_bus_bvolt) / ((f_bus_bvolt + t_bus_bvolt) / 2)
        if !branch["transformer"] &&
           percent_difference > BRANCH_BUS_VOLTAGE_DIFFERENCE_TOL
            branch["transformer"] = true
            branch["base_power"] = pm_data.data["baseMVA"]
            branch["ext"] = Dict{String, Any}()
            @warn "Branch $(branch["f_bus"]) - $(branch["t_bus"]) has different voltage levels endpoints (from: $(f_bus_bvolt)kV, to: $(t_bus_bvolt)kV) which exceed the $(BRANCH_BUS_VOLTAGE_DIFFERENCE_TOL*100)% threshold; converting to transformer."
            if !haskey(branch, "base_voltage_from")
                branch["base_voltage_from"] = f_bus_bvolt
                branch["base_voltage_to"] = t_bus_bvolt
            end
        end
    end
end

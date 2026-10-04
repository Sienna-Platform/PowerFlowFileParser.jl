"""
    parse_file(
        file;
        import_all = false,
        validate = true,
        correct_branch_rating = true,
        solved_case = false,
        con_files = String[],
        mon_file = "",
        sub_file = "",
    )

Parses a Matpower .m `file` or PTI (PSS(R)E-v33) .raw `file` into a
PowerModels data structure. All fields from PTI files will be imported if
`import_all` is true (Default: false). Set `solved_case` when a .raw file was written out
after a converged power flow: its switched shunts then take BINIT as their solved
admittance rather than reconstructing one from the engaged blocks.

PSS/E `con_files` are added with [`add_contingencies!`](@ref), once per file in order, and
`mon_file` (with the optional `sub_file`) with [`add_monitored!`](@ref). Without them the
result has no `"contingency"` or `"monitor"` key. Bad contingency or monitor records are
skipped with a warning rather than failing the file; the `.mon` / `.sub` semantics are
unverified (see [`add_monitored!`](@ref)).
"""
function parse_file(
    file::String;
    import_all = false,
    validate = true,
    correct_branch_rating = true,
    solved_case = false,
    con_files = String[],
    mon_file = "",
    sub_file = "",
)
    pm_data = open(file) do io
        pm_data = parse_file(
            io;
            import_all = import_all,
            validate = validate,
            correct_branch_rating = correct_branch_rating,
            solved_case = solved_case,
            filetype = split(lowercase(file), '.')[end],
        )
    end
    add_con_mon_files!(
        pm_data;
        con_files = con_files,
        mon_file = mon_file,
        sub_file = sub_file,
    )
    return pm_data
end

function add_con_mon_files!(pm::Dict; con_files, mon_file, sub_file)
    if isempty(mon_file) && !isempty(sub_file)
        throw(ArgumentError("sub_file $sub_file given without mon_file"))
    end
    for con_file in con_files
        add_contingencies!(pm, con_file)
    end
    if !isempty(mon_file)
        add_monitored!(pm, mon_file; sub_path = sub_file)
    end
    return
end

"Parses the iostream from a file"
function parse_file(
    io::IO;
    import_all = false,
    validate = true,
    correct_branch_rating = true,
    solved_case = false,
    filetype = "json",
)
    if filetype == "m"
        pm_data = parse_matpower(io; validate = validate)
    elseif filetype == "raw"
        pm_data = parse_psse(
            io;
            import_all = import_all,
            validate = validate,
            correct_branch_rating = correct_branch_rating,
            solved_case = solved_case,
        )
    elseif filetype == "json"
        pm_data = parse_json(io; validate = validate)
    else
        @info("Unrecognized filetype")
    end

    # TODO:  not sure if this relevant for all three file types, or only .m, JJS 3/7/19
    move_genfuel_and_gentype!(pm_data)

    return pm_data
end

"""
Runs various data quality checks on a PowerModels data dictionary.
Applies modifications in some cases.  Reports modified component ids.
"""
function correct_network_data!(data::Dict{String, <:Any}; correct_branch_rating = true)
    mod_gen = Dict{Symbol, Set{Int}}()
    mod_branch = Dict{Symbol, Set{Int}}()
    mod_dcline = Dict{Symbol, Set{Int}}()

    check_conductors(data)
    check_connectivity(data)
    check_status(data)
    check_reference_bus(data)

    make_per_unit!(data)

    mod_branch[:xfer_fix] = correct_transformer_parameters!(data)
    mod_branch[:vad_bounds] = correct_voltage_angle_differences!(data)
    mod_branch[:mva_zero] = if (correct_branch_rating)
        correct_thermal_limits!(data)
    else
        # Set rate_a as 0.0 for those branch dict entries witn no "rate_a" key
        branches = [branch for branch in values(data["branch"])]
        if haskey(data, "ne_branch")
            append!(branches, values(data["ne_branch"]))
        end

        for branch in branches
            if !haskey(branch, "rate_a")
                if haskey(data, "conductors")
                    error("Multiconductor Not Supported in PowerSystems")
                else
                    branch["rate_a"] = 0.0
                end
            end
        end

        Set{Int}()
    end

    #mod_branch[:ma_zero] = correct_current_limits!(data)
    mod_branch[:orientation] = correct_branch_directions!(data)
    check_branch_loops(data)

    mod_dcline[:losses] = correct_dcline_limits!(data)

    check_voltage_setpoints(data)

    check_storage_parameters(data)
    check_switch_parameters(data)

    gen, dcline = correct_cost_functions!(data)
    mod_gen[:cost_pwl] = gen
    mod_dcline[:cost_pwl] = dcline

    simplify_cost_terms!(data)

    return Dict(
        "gen" => mod_gen,
        "branch" => mod_branch,
        "dcline" => mod_dcline,
    )
end

UNIT_SYSTEM_MAPPING = Dict(
    "SYSTEM_BASE" => IS.UnitSystem.SYSTEM_BASE,
    "DEVICE_BASE" => IS.UnitSystem.DEVICE_BASE,
    "NATURAL_UNITS" => IS.UnitSystem.NATURAL_UNITS,
    "NA" => nothing,
)

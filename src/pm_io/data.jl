# tools for working with a PowerModels data dict structure

"maps component types to status parameters"
const pm_component_status = Dict(
    "bus" => "bus_type",
    "load" => "status",
    "shunt" => "status",
    "gen" => "gen_status",
    "storage" => "status",
    "switch" => "status",
    "branch" => "br_status",
    "dcline" => "br_status",
)

"maps component types to inactive status values"
const pm_component_status_inactive = Dict(
    "bus" => 4,
    "load" => 0,
    "shunt" => 0,
    "gen" => 0,
    "storage" => 0,
    "switch" => 0,
    "branch" => 0,
    "dcline" => 0,
)

const _pm_component_types_order = Dict(
    "bus" => 1.0,
    "load" => 2.0,
    "shunt" => 3.0,
    "gen" => 4.0,
    "storage" => 5.0,
    "switch" => 6.0,
    "branch" => 7.0,
    "dcline" => 8.0,
)

const _pm_component_parameter_order = Dict(
    "bus_i" => 1.0,
    "load_bus" => 2.0,
    "shunt_bus" => 3.0,
    "gen_bus" => 4.0,
    "storage_bus" => 5.0,
    "f_bus" => 6.0,
    "t_bus" => 7.0,
    "bus_name" => 9.1,
    "base_kv" => 9.2,
    "bus_type" => 9.3,
    "vm" => 10.0,
    "va" => 11.0,
    "pd" => 20.0,
    "qd" => 21.0,
    "gs" => 30.0,
    "bs" => 31.0,
    "ps" => 35.0,
    "qs" => 36.0,
    "psw" => 37.0,
    "qsw" => 38.0,
    "pg" => 40.0,
    "qg" => 41.0,
    "vg" => 42.0,
    "mbase" => 43.0,
    "energy" => 44.0,
    "br_r" => 50.0,
    "br_x" => 51.0,
    "g_fr" => 52.0,
    "b_fr" => 53.0,
    "g_to" => 54.0,
    "b_to" => 55.0,
    "tap" => 56.0,
    "shift" => 57.0,
    "vf" => 58.1,
    "pf" => 58.2,
    "qf" => 58.3,
    "vt" => 58.4,
    "pt" => 58.5,
    "qt" => 58.6,
    "loss0" => 58.7,
    "loss1" => 59.8,
    "vmin" => 60.0,
    "vmax" => 61.0,
    "pmin" => 62.0,
    "pmax" => 63.0,
    "qmin" => 64.0,
    "qmax" => 65.0,
    "rate_a" => 66.0,
    "rate_b" => 67.0,
    "rate_c" => 68.0,
    "pminf" => 69.0,
    "pmaxf" => 70.0,
    "qminf" => 71.0,
    "qmaxf" => 72.0,
    "pmint" => 73.0,
    "pmaxt" => 74.0,
    "qmint" => 75.0,
    "qmaxt" => 76.0,
    "energy_rating" => 77.01,
    "charge_rating" => 77.02,
    "discharge_rating" => 77.03,
    "charge_efficiency" => 77.04,
    "discharge_efficiency" => 77.05,
    "thermal_rating" => 77.06,
    "qmin" => 77.07,
    "qmax" => 77.08,
    "qmin" => 77.09,
    "qmax" => 77.10,
    "r" => 77.11,
    "x" => 77.12,
    "p_loss" => 77.13,
    "q_loss" => 77.14,
    "status" => 80.0,
    "gen_status" => 81.0,
    "br_status" => 82.0,
    "model" => 90.0,
    "ncost" => 91.0,
    "cost" => 92.0,
    "startup" => 93.0,
    "shutdown" => 94.0,
)

const _pm_component_status_parameters = Set(["status", "gen_status", "br_status"])


"""
Turns in given single network data in multinetwork data with a `count`
replicate of the given network.  Note that this function performs a deepcopy
of the network data.  Significant multinetwork space savings can often be
achieved by building application specific methods of building multinetwork
with minimal data replication.
"""
""
function _apply_func!(data::Dict{String, <:Any}, key::String, func)
    if haskey(data, key)
        data[key] = func(data[key]) # multiconductor not supported in PowerSystems
    end
end

"Transforms network data into per-unit"
function make_per_unit!(data::Dict{String, <:Any})
    if !haskey(data, "per_unit") || data["per_unit"] == false
        data["per_unit"] = true
        mva_base = data["baseMVA"]
        if ismultinetwork(data)
            for (i, nw_data) in data["nw"]
                _make_per_unit!(nw_data, mva_base)
            end
        else
            _make_per_unit!(data, mva_base)
        end
    end
end

""
function _make_per_unit!(data::Dict{String, <:Any}, mva_base::Real)
    # to be consistent with matpower's opf.flow_lim= 'I' with current magnitude
    # limit defined in MVA at 1 p.u. voltage
    ka_base = mva_base

    rescale = x -> x / mva_base
    rescale_dual = x -> x * mva_base
    rescale_ampere = x -> x / ka_base

    if haskey(data, "bus")
        for (i, bus) in data["bus"]
            _apply_func!(bus, "va", deg2rad)

            _apply_func!(bus, "lam_kcl_r", rescale_dual)
            _apply_func!(bus, "lam_kcl_i", rescale_dual)
        end
    end

    if haskey(data, "load")
        for (i, load) in data["load"]
            _apply_func!(load, "pd", rescale)
            _apply_func!(load, "qd", rescale)
            _apply_func!(load, "pi", rescale)
            _apply_func!(load, "qi", rescale)
            _apply_func!(load, "py", rescale)
            _apply_func!(load, "qy", rescale)
        end
    end

    if haskey(data, "shunt")
        for (i, shunt) in data["shunt"]
            _apply_func!(shunt, "gs", rescale)
            _apply_func!(shunt, "bs", rescale)
        end
    end

    if haskey(data, "switched_shunt")
        for (i, sw_shunt) in data["switched_shunt"]
            _apply_func!(sw_shunt, "gs", rescale)
            _apply_func!(sw_shunt, "bs", rescale)
            _apply_func!(sw_shunt, "y_increment", rescale)
        end
    end

    if haskey(data, "gen")
        for (i, gen) in data["gen"]
            _apply_func!(gen, "pg", rescale)
            _apply_func!(gen, "qg", rescale)

            _apply_func!(gen, "pmax", rescale)
            _apply_func!(gen, "pmin", rescale)

            _apply_func!(gen, "qmax", rescale)
            _apply_func!(gen, "qmin", rescale)

            _apply_func!(gen, "ramp_agc", rescale)
            _apply_func!(gen, "ramp_10", rescale)
            _apply_func!(gen, "ramp_30", rescale)
            _apply_func!(gen, "ramp_q", rescale)

            _rescale_cost_model!(gen, mva_base)
        end
    end

    if haskey(data, "storage")
        for (i, strg) in data["storage"]
            _apply_func!(strg, "energy", rescale)
            _apply_func!(strg, "energy_rating", rescale)
            _apply_func!(strg, "charge_rating", rescale)
            _apply_func!(strg, "discharge_rating", rescale)
            _apply_func!(strg, "thermal_rating", rescale)
            _apply_func!(strg, "current_rating", rescale)
            _apply_func!(strg, "qmin", rescale)
            _apply_func!(strg, "qmax", rescale)
            _apply_func!(strg, "p_loss", rescale)
            _apply_func!(strg, "q_loss", rescale)
        end
    end

    if haskey(data, "switch")
        for (i, switch) in data["switch"]
            _apply_func!(switch, "psw", rescale)
            _apply_func!(switch, "qsw", rescale)
            _apply_func!(switch, "thermal_rating", rescale)
            _apply_func!(switch, "current_rating", rescale)
        end
    end

    branches = []
    if haskey(data, "branch")
        append!(branches, values(data["branch"]))
    end

    if haskey(data, "ne_branch")
        append!(branches, values(data["ne_branch"]))
    end

    for branch in branches
        _apply_func!(branch, "rate_a", rescale)
        _apply_func!(branch, "rate_b", rescale)
        _apply_func!(branch, "rate_c", rescale)

        _apply_func!(branch, "c_rating_a", rescale_ampere)
        _apply_func!(branch, "c_rating_b", rescale_ampere)
        _apply_func!(branch, "c_rating_c", rescale_ampere)

        _apply_func!(branch, "shift", deg2rad)
        _apply_func!(branch, "angmax", deg2rad)
        _apply_func!(branch, "angmin", deg2rad)

        _apply_func!(branch, "pf", rescale)
        _apply_func!(branch, "pt", rescale)
        _apply_func!(branch, "qf", rescale)
        _apply_func!(branch, "qt", rescale)

        _apply_func!(branch, "mu_sm_fr", rescale_dual)
        _apply_func!(branch, "mu_sm_to", rescale_dual)

        _apply_func!(branch, "ta_max", deg2rad)
        _apply_func!(branch, "ta_min", deg2rad)
    end

    if haskey(data, "dcline")
        for (i, dcline) in data["dcline"]
            _apply_func!(dcline, "loss0", rescale)
            _apply_func!(dcline, "pf", rescale)
            _apply_func!(dcline, "pt", rescale)
            _apply_func!(dcline, "qf", rescale)
            _apply_func!(dcline, "qt", rescale)
            _apply_func!(dcline, "pmaxt", rescale)
            _apply_func!(dcline, "pmint", rescale)
            _apply_func!(dcline, "pmaxf", rescale)
            _apply_func!(dcline, "pminf", rescale)
            _apply_func!(dcline, "qmaxt", rescale)
            _apply_func!(dcline, "qmint", rescale)
            _apply_func!(dcline, "qmaxf", rescale)
            _apply_func!(dcline, "qminf", rescale)

            _rescale_cost_model!(dcline, mva_base)
        end
    end
end

""
function _rescale_cost_model!(comp::Dict{String, <:Any}, scale::Real)
    if "model" in keys(comp) && "cost" in keys(comp)
        if comp["model"] == 1
            for i in 1:2:length(comp["cost"])
                comp["cost"][i] = comp["cost"][i] / scale
            end
        elseif comp["model"] == 2
            degree = length(comp["cost"])
            for (i, item) in enumerate(comp["cost"])
                comp["cost"][i] = item * (scale^(degree - i))
            end
        else
            @info("Skipping cost model of type $(comp["model"]) in per unit transformation")
        end
    end
end

""
function check_conductors(data::Dict{String, <:Any})
    if ismultinetwork(data)
        for (i, nw_data) in data["nw"]
            _check_conductors(nw_data)
        end
    else
        _check_conductors(data)
    end
end

""
function _check_conductors(data::Dict{String, <:Any})
    if haskey(data, "conductors") && data["conductors"] < 1
        error("conductor values must be positive integers, given $(data["conductors"])")
    end
end

"checks that voltage angle differences are within 90 deg., if not tightens"
function correct_voltage_angle_differences!(data::Dict{String, <:Any}, default_pad = 1.0472)
    if ismultinetwork(data)
        error("check_voltage_angle_differences does not yet support multinetwork data")
    end

    @assert("per_unit" in keys(data) && data["per_unit"])
    default_pad_deg = round(rad2deg(default_pad); digits = 2)

    modified = Set{Int}()

    for c in 1:get(data, "conductors", 1)
        cnd_str = haskey(data, "conductors") ? ", conductor $(c)" : ""
        for (i, branch) in data["branch"]
            angmin = branch["angmin"][c]
            angmax = branch["angmax"][c]

            if angmin <= -pi / 2
                @info "this code only supports angmin values in -90 deg. to 90 deg., tightening the value on branch $i$(cnd_str) from $(rad2deg(angmin)) to -$(default_pad_deg) deg." maxlog =
                    PS_MAX_LOG
                if haskey(data, "conductors")
                    branch["angmin"][c] = -default_pad
                else
                    branch["angmin"] = -default_pad
                end
                push!(modified, branch["index"])
            end

            if angmax >= pi / 2
                @info "this code only supports angmax values in -90 deg. to 90 deg., tightening the value on branch $i$(cnd_str) from $(rad2deg(angmax)) to $(default_pad_deg) deg." maxlog =
                    PS_MAX_LOG
                if haskey(data, "conductors")
                    branch["angmax"][c] = default_pad
                else
                    branch["angmax"] = default_pad
                end
                push!(modified, branch["index"])
            end

            if angmin == 0.0 && angmax == 0.0
                @info "angmin and angmax values are 0, widening these values on branch $i$(cnd_str) to +/- $(default_pad_deg) deg." maxlog =
                    PS_MAX_LOG
                if haskey(data, "conductors")
                    branch["angmin"][c] = -default_pad
                    branch["angmax"][c] = default_pad
                else
                    branch["angmin"] = -default_pad
                    branch["angmax"] = default_pad
                end
                push!(modified, branch["index"])
            end
        end
    end

    return modified
end

"checks that each branch has a reasonable thermal rating-a, if not computes one"
function correct_thermal_limits!(data::Dict{String, <:Any})
    if ismultinetwork(data)
        error("correct_thermal_limits! does not yet support multinetwork data")
    end

    @assert("per_unit" in keys(data) && data["per_unit"])
    mva_base = data["baseMVA"]

    modified = Set{Int}()

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

        for c in 1:get(data, "conductors", 1)
            cnd_str = haskey(data, "conductors") ? ", conductor $(c)" : ""
            if branch["rate_a"][c] <= 0.0
                theta_max = max(abs(branch["angmin"][c]), abs(branch["angmax"][c]))

                r = branch["br_r"]
                x = branch["br_x"]
                z = r + im * x
                y = LinearAlgebra.pinv(z)
                y_mag = abs.(y[c, c])

                fr_vmax = data["bus"][branch["f_bus"]]["vmax"][c]
                to_vmax = data["bus"][branch["t_bus"]]["vmax"][c]
                m_vmax = max(fr_vmax, to_vmax)

                c_max = sqrt(fr_vmax^2 + to_vmax^2 - 2 * fr_vmax * to_vmax * cos(theta_max))

                new_rate = y_mag * m_vmax * c_max

                if haskey(branch, "c_rating_a") && branch["c_rating_a"][c] > 0.0
                    new_rate = min(new_rate, branch["c_rating_a"][c] * m_vmax)
                end

                @info "this code only supports positive rate_a values, changing the value on branch $(branch["index"])$(cnd_str) to $(round(mva_base*new_rate, digits=4))" maxlog =
                    PS_MAX_LOG

                if haskey(data, "conductors")
                    branch["rate_a"][c] = new_rate
                else
                    branch["rate_a"] = new_rate
                end

                push!(modified, branch["index"])
            end
        end
    end

    return modified
end

"checks that all parallel branches have the same orientation"
function correct_branch_directions!(data::Dict{String, <:Any})
    if ismultinetwork(data)
        error("correct_branch_directions! does not yet support multinetwork data")
    end

    modified = Set{Int}()

    orientations = Set()
    for (i, branch) in data["branch"]
        orientation = (branch["f_bus"], branch["t_bus"])
        orientation_rev = (branch["t_bus"], branch["f_bus"])

        if in(orientation_rev, orientations)
            @info(
                "reversing the orientation of branch $(i) $(orientation) to be consistent with other parallel branches"
            )
            branch_orginal = copy(branch)
            branch["f_bus"] = branch_orginal["t_bus"]
            branch["t_bus"] = branch_orginal["f_bus"]
            branch["g_to"] = branch_orginal["g_fr"] .* branch_orginal["tap"]' .^ 2
            branch["b_to"] = branch_orginal["b_fr"] .* branch_orginal["tap"]' .^ 2
            branch["g_fr"] = branch_orginal["g_to"] ./ branch_orginal["tap"]' .^ 2
            branch["b_fr"] = branch_orginal["b_to"] ./ branch_orginal["tap"]' .^ 2
            branch["tap"] = 1 ./ branch_orginal["tap"]
            branch["br_r"] = branch_orginal["br_r"] .* branch_orginal["tap"]' .^ 2
            branch["br_x"] = branch_orginal["br_x"] .* branch_orginal["tap"]' .^ 2
            branch["shift"] = -branch_orginal["shift"]
            branch["angmin"] = -branch_orginal["angmax"]
            branch["angmax"] = -branch_orginal["angmin"]

            push!(modified, branch["index"])
        else
            push!(orientations, orientation)
        end
    end

    return modified
end

"checks that all branches connect two distinct buses"
function check_branch_loops(data::Dict{String, <:Any})
    if ismultinetwork(data)
        error("check_branch_loops does not yet support multinetwork data")
    end

    for (i, branch) in data["branch"]
        if branch["f_bus"] == branch["t_bus"]
            throw(
                DataFormatError(
                    "both sides of branch $(i) connect to bus $(branch["f_bus"])",
                ),
            )
        end
    end
end

"checks that all buses are unique and other components link to valid buses"
function check_connectivity(data::Dict{String, <:Any})
    if ismultinetwork(data)
        error("check_connectivity does not yet support multinetwork data")
    end

    bus_ids = Set(bus["index"] for (i, bus) in data["bus"])
    @assert(length(bus_ids) == length(data["bus"])) # if this is not true something very bad is going on

    for (i, load) in data["load"]
        if !(load["load_bus"] in bus_ids)
            throw(DataFormatError("bus $(load["load_bus"]) in load $(i) is not defined"))
        end
    end

    for (i, shunt) in data["shunt"]
        if !(shunt["shunt_bus"] in bus_ids)
            throw(DataFormatError("bus $(shunt["shunt_bus"]) in shunt $(i) is not defined"))
        end
    end

    for (i, gen) in data["gen"]
        if !(gen["gen_bus"] in bus_ids)
            throw(DataFormatError("bus $(gen["gen_bus"]) in generator $(i) is not defined"))
        end
    end

    for (i, strg) in data["storage"]
        if !(strg["storage_bus"] in bus_ids)
            throw(
                DataFormatError(
                    "bus $(strg["storage_bus"]) in storage unit $(i) is not defined",
                ),
            )
        end
    end

    if haskey(data, "switch")
        for (i, switch) in data["switch"]
            if !(switch["f_bus"] in bus_ids)
                throw(
                    DataFormatError(
                        "from bus $(branch["f_bus"]) in switch $(i) is not defined",
                    ),
                )
            end

            if !(switch["t_bus"] in bus_ids)
                throw(
                    DataFormatError(
                        "to bus $(branch["t_bus"]) in switch $(i) is not defined",
                    ),
                )
            end
        end
    end

    for (i, branch) in data["branch"]
        if !(branch["f_bus"] in bus_ids)
            throw(
                DataFormatError(
                    "from bus $(branch["f_bus"]) in branch $(i) is not defined",
                ),
            )
        end

        if !(branch["t_bus"] in bus_ids)
            throw(
                DataFormatError("to bus $(branch["t_bus"]) in branch $(i) is not defined"),
            )
        end
    end

    for (i, dcline) in data["dcline"]
        if !(dcline["f_bus"] in bus_ids)
            throw(
                DataFormatError(
                    "from bus $(dcline["f_bus"]) in dcline $(i) is not defined",
                ),
            )
        end

        if !(dcline["t_bus"] in bus_ids)
            throw(
                DataFormatError("to bus $(dcline["t_bus"]) in dcline $(i) is not defined"),
            )
        end
    end
end

"checks that active components are not connected to inactive buses, otherwise prints warnings"
function check_status(data::Dict{String, <:Any})
    if ismultinetwork(data)
        error("check_status does not yet support multinetwork data")
    end

    active_bus_ids = Set(bus["index"] for (i, bus) in data["bus"] if bus["bus_type"] != 4)

    for (i, load) in data["load"]
        if load["status"] != 0 && !(load["load_bus"] in active_bus_ids)
            @warn("active load $(i) is connected to inactive bus $(load["load_bus"])")
        end
    end

    for (i, shunt) in data["shunt"]
        if shunt["status"] != 0 && !(shunt["shunt_bus"] in active_bus_ids)
            @warn("active shunt $(i) is connected to inactive bus $(shunt["shunt_bus"])")
        end
    end

    for (i, gen) in data["gen"]
        if gen["gen_status"] != 0 && !(gen["gen_bus"] in active_bus_ids)
            @warn("active generator $(i) is connected to inactive bus $(gen["gen_bus"])")
        end
    end

    for (i, strg) in data["storage"]
        if strg["status"] != 0 && !(strg["storage_bus"] in active_bus_ids)
            @warn(
                "active storage unit $(i) is connected to inactive bus $(strg["storage_bus"])"
            )
        end
    end

    for (i, branch) in data["branch"]
        if branch["br_status"] != 0 && !(branch["f_bus"] in active_bus_ids)
            @warn("active branch $(i) is connected to inactive bus $(branch["f_bus"])")
        end

        if branch["br_status"] != 0 && !(branch["t_bus"] in active_bus_ids)
            @warn("active branch $(i) is connected to inactive bus $(branch["t_bus"])")
        end
    end

    for (i, dcline) in data["dcline"]
        if dcline["br_status"] != 0 && !(dcline["f_bus"] in active_bus_ids)
            @warn("active dcline $(i) is connected to inactive bus $(dcline["f_bus"])")
        end

        if dcline["br_status"] != 0 && !(dcline["t_bus"] in active_bus_ids)
            @warn("active dcline $(i) is connected to inactive bus $(dcline["t_bus"])")
        end
    end
end

"checks that contains at least one refrence bus"
function check_reference_bus(data::Dict{String, <:Any})
    if ismultinetwork(data)
        error("check_reference_bus does not yet support multinetwork data")
    end

    ref_buses = Dict{Int, Any}()
    for (k, v) in data["bus"]
        if v["bus_type"] == 3
            ref_buses[k] = v
        end
    end

    if length(ref_buses) == 0
        if length(data["gen"]) > 0
            big_gen = _biggest_generator(data["gen"])
            gen_bus = big_gen["gen_bus"]
            ref_bus = data["bus"][gen_bus]
            ref_bus["bus_type"] = 3
            @warn(
                "no reference bus found, setting bus $(gen_bus) as reference based on generator $(big_gen["index"])"
            )
        else
            (bus_item, state) = Base.iterate(values(data["bus"]))
            bus_item["bus_type"] = 3
            @warn(
                "no reference bus found, setting bus $(bus_item["index"]) as reference"
            )
        end
    end
    return
end

"find the largest active generator in the network"
function _biggest_generator(gens)
    biggest_gen = nothing
    biggest_value = -Inf
    for (k, gen) in gens
        pmax = maximum(gen["pmax"])
        if pmax > biggest_value
            biggest_gen = gen
            biggest_value = pmax
        end
    end
    @assert(biggest_gen !== nothing)
    return biggest_gen
end

"""
checks that each branch has a reasonable transformer parameters

this is important because setting tap == 0.0 leads to NaN computations, which are hard to debug
"""
function correct_transformer_parameters!(data::Dict{String, <:Any})
    if ismultinetwork(data)
        error("check_transformer_parameters does not yet support multinetwork data")
    end

    @assert("per_unit" in keys(data) && data["per_unit"])

    modified = Set{Int}()

    for (i, branch) in data["branch"]
        if !haskey(branch, "tap")
            @info "branch found without tap value, setting a tap to 1.0" maxlog = PS_MAX_LOG
            if haskey(data, "conductors")
                error("Multiconductor Not Supported in PowerSystems")
            else
                branch["tap"] = 1.0
            end
            push!(modified, branch["index"])
        else
            for c in 1:get(data, "conductors", 1)
                cnd_str = haskey(data, "conductors") ? " on conductor $(c)" : ""
                if branch["tap"][c] <= 0.0
                    @info(
                        "branch found with non-positive tap value of $(branch["tap"][c]), setting a tap to 1.0$(cnd_str)"
                    )
                    if haskey(data, "conductors")
                        branch["tap"][c] = 1.0
                    else
                        branch["tap"] = 1.0
                    end
                    push!(modified, branch["index"])
                end
            end
        end
        if !haskey(branch, "shift")
            @info("branch found without shift value, setting a shift to 0.0")
            if haskey(data, "conductors")
                error("Multiconductor Not Supported in PowerSystems")
            else
                branch["shift"] = 0.0
            end
            push!(modified, branch["index"])
        end
    end

    return modified
end

"""
checks that each storage unit has a reasonable parameters
"""
function check_storage_parameters(data::Dict{String, Any})
    if ismultinetwork(data)
        error("check_storage_parameters does not yet support multinetwork data")
    end

    for (i, strg) in data["storage"]
        if strg["energy"] < 0.0
            throw(
                DataFormatError(
                    "storage unit $(strg["index"]) has a non-positive energy level $(strg["energy"])",
                ),
            )
        end
        if strg["energy_rating"] < 0.0
            throw(
                DataFormatError(
                    "storage unit $(strg["index"]) has a non-positive energy rating $(strg["energy_rating"])",
                ),
            )
        end
        if strg["charge_rating"] < 0.0
            throw(
                DataFormatError(
                    "storage unit $(strg["index"]) has a non-positive charge rating $(strg["energy_rating"])",
                ),
            )
        end
        if strg["discharge_rating"] < 0.0
            throw(
                DataFormatError(
                    "storage unit $(strg["index"]) has a non-positive discharge rating $(strg["energy_rating"])",
                ),
            )
        end

        if strg["r"] < 0.0
            throw(
                DataFormatError(
                    "storage unit $(strg["index"]) has a non-positive resistance $(strg["r"])",
                ),
            )
        end
        if strg["x"] < 0.0
            throw(
                DataFormatError(
                    "storage unit $(strg["index"]) has a non-positive reactance $(strg["x"])",
                ),
            )
        end
        if haskey(strg, "thermal_rating") && strg["thermal_rating"] < 0.0
            throw(
                DataFormatError(
                    "storage unit $(strg["index"]) has a non-positive thermal rating $(strg["thermal_rating"])",
                ),
            )
        end
        if haskey(strg, "current_rating") && strg["current_rating"] < 0.0
            throw(
                DataFormatError(
                    "storage unit $(strg["index"]) has a non-positive current rating $(strg["thermal_rating"])",
                ),
            )
        end
        if !isapprox(strg["x"], 0.0; atol = 1e-6, rtol = 1e-6)
            throw(
                DataFormatError(
                    "storage unit $(strg["index"]) has a non-zero reactance $(strg["x"]), which is currently ignored",
                ),
            )
        end

        if strg["charge_efficiency"] < 0.0
            throw(
                DataFormatError(
                    "storage unit $(strg["index"]) has a non-positive charge efficiency of $(strg["charge_efficiency"])",
                ),
            )
        end
        if strg["charge_efficiency"] <= 0.0 || strg["charge_efficiency"] > 1.0
            @info "storage unit $(strg["index"]) charge efficiency of $(strg["charge_efficiency"]) is out of the valid range (0.0. 1.0]" maxlog =
                PS_MAX_LOG
        end
        if strg["discharge_efficiency"] < 0.0
            throw(
                DataFormatError(
                    "storage unit $(strg["index"]) has a non-positive discharge efficiency of $(strg["discharge_efficiency"])",
                ),
            )
        end
        if strg["discharge_efficiency"] <= 0.0 || strg["discharge_efficiency"] > 1.0
            @info "storage unit $(strg["index"]) discharge efficiency of $(strg["discharge_efficiency"]) is out of the valid range (0.0. 1.0]" maxlog =
                PS_MAX_LOG
        end

        if strg["p_loss"] > 0.0 && strg["energy"] <= 0.0
            @info "storage unit $(strg["index"]) has positive active power losses but zero initial energy.  This can lead to model infeasiblity." maxlog =
                PS_MAX_LOG
        end
        if strg["q_loss"] > 0.0 && strg["energy"] <= 0.0
            @info "storage unit $(strg["index"]) has positive reactive power losses but zero initial energy.  This can lead to model infeasiblity." maxlog =
                PS_MAX_LOG
        end
    end
end

"""
checks that each switch has a reasonable parameters
"""
function check_switch_parameters(data::Dict{String, <:Any})
    if ismultinetwork(data)
        error("check_switch_parameters does not yet support multinetwork data")
    end

    for (i, switch) in data["switch"]
        if switch["state"] <= 0.0 &&
           (!isapprox(switch["psw"], 0.0) || !isapprox(switch["qsw"], 0.0))
            @info "switch $(switch["index"]) is open with non-zero power values $(switch["psw"]), $(switch["qsw"])" maxlog =
                PS_MAX_LOG
        end
        if haskey(switch, "thermal_rating") && switch["thermal_rating"] < 0.0
            throw(
                DataFormatError(
                    "switch $(switch["index"]) has a non-positive thermal_rating $(switch["thermal_rating"])",
                ),
            )
        end
        if haskey(switch, "current_rating") && switch["current_rating"] < 0.0
            throw(
                DataFormatError(
                    "switch $(switch["index"]) has a non-positive current_rating $(switch["current_rating"])",
                ),
            )
        end
    end
end

"checks that parameters for dc lines are reasonable"
function correct_dcline_limits!(data::Dict{String, Any})
    if ismultinetwork(data)
        error("check_dcline_limits does not yet support multinetwork data")
    end

    @assert("per_unit" in keys(data) && data["per_unit"])
    mva_base = data["baseMVA"]

    modified = Set{Int}()

    for c in 1:get(data, "conductors", 1)
        cnd_str = haskey(data, "conductors") ? ", conductor $(c)" : ""
        for (i, dcline) in data["dcline"]
            if dcline["loss0"][c] < 0.0
                new_rate = 0.0
                @info "this code only supports positive loss0 values, changing the value on dcline $(dcline["index"])$(cnd_str) from $(mva_base*dcline["loss0"][c]) to $(mva_base*new_rate)" maxlog =
                    PS_MAX_LOG
                if haskey(data, "conductors")
                    dcline["loss0"][c] = new_rate
                else
                    dcline["loss0"] = new_rate
                end
                push!(modified, dcline["index"])
            end

            if dcline["loss0"][c] >=
               dcline["pmaxf"][c] * (1 - dcline["loss1"][c]) + dcline["pmaxt"][c]
                new_rate = 0.0
                @info "this code only supports loss0 values which are consistent with the line flow bounds, changing the value on dcline $(dcline["index"])$(cnd_str) from $(mva_base*dcline["loss0"][c]) to $(mva_base*new_rate)" maxlog =
                    PS_MAX_LOG
                if haskey(data, "conductors")
                    dcline["loss0"][c] = new_rate
                else
                    dcline["loss0"] = new_rate
                end
                push!(modified, dcline["index"])
            end

            if dcline["loss1"][c] < 0.0
                new_rate = 0.0
                @info "this code only supports positive loss1 values, changing the value on dcline $(dcline["index"])$(cnd_str) from $(dcline["loss1"][c]) to $(new_rate)" maxlog =
                    PS_MAX_LOG
                if haskey(data, "conductors")
                    dcline["loss1"][c] = new_rate
                else
                    dcline["loss1"] = new_rate
                end
                push!(modified, dcline["index"])
            end

            if dcline["loss1"][c] >= 1.0
                new_rate = 0.0
                @info "this code only supports loss1 values < 1, changing the value on dcline $(dcline["index"])$(cnd_str) from $(dcline["loss1"][c]) to $(new_rate)" maxlog =
                    PS_MAX_LOG
                if haskey(data, "conductors")
                    dcline["loss1"][c] = new_rate
                else
                    dcline["loss1"] = new_rate
                end
                push!(modified, dcline["index"])
            end

            if dcline["pmint"][c] < 0.0 && dcline["loss1"][c] > 0.0
                #new_rate = 0.0
                @info "the dc line model is not meant to be used bi-directionally when loss1 > 0, be careful interpreting the results as the dc line losses can now be negative. change loss1 to 0 to avoid this warning" maxlog =
                    PS_MAX_LOG
                #dcline["loss0"] = new_rate
            end
        end
    end

    return modified
end

"throws warnings if generator and dc line voltage setpoints are not consistent with the bus voltage setpoint"
function check_voltage_setpoints(data::Dict{String, <:Any})
    if ismultinetwork(data)
        error("check_voltage_setpoints does not yet support multinetwork data")
    end

    for c in 1:get(data, "conductors", 1)
        cnd_str = haskey(data, "conductors") ? "conductor $(c) " : ""
        for (i, gen) in data["gen"]
            bus_id = gen["gen_bus"]
            bus = data["bus"][bus_id]
            if gen["vg"][c] != bus["vm"][c]
                @info "the $(cnd_str)voltage setpoint on generator $(i) does not match the value at bus $(bus_id)" maxlog =
                    PS_MAX_LOG
            end
        end

        for (i, dcline) in data["dcline"]
            bus_fr_id = dcline["f_bus"]
            bus_to_id = dcline["t_bus"]

            bus_fr = data["bus"][bus_fr_id]
            bus_to = data["bus"][bus_to_id]

            if dcline["vf"][c] != bus_fr["vm"][c]
                @info(
                    "the $(cnd_str)from bus voltage setpoint on dc line $(i) does not match the value at bus $(bus_fr_id)"
                )
            end

            if dcline["vt"][c] != bus_to["vm"][c]
                @info(
                    "the $(cnd_str)to bus voltage setpoint on dc line $(i) does not match the value at bus $(bus_to_id)"
                )
            end
        end
    end
end

"throws warnings if cost functions are malformed"
function correct_cost_functions!(data::Dict{String, <:Any})
    if ismultinetwork(data)
        error("check_cost_functions does not yet support multinetwork data")
    end

    modified_gen = Set{Int}()
    for (i, gen) in data["gen"]
        if _correct_cost_function!(i, gen, "generator")
            push!(modified_gen, gen["index"])
        end
    end

    modified_dcline = Set{Int}()
    for (i, dcline) in data["dcline"]
        if _correct_cost_function!(i, dcline, "dcline")
            push!(modified_dcline, dcline["index"])
        end
    end

    return (modified_gen, modified_dcline)
end

""
function _correct_cost_function!(id, comp, type_name)
    modified = false

    if "model" in keys(comp) && "cost" in keys(comp)
        if comp["model"] == 1
            if length(comp["cost"]) != 2 * comp["ncost"]
                error(
                    "ncost of $(comp["ncost"]) not consistent with $(length(comp["cost"])) cost values on $(type_name) $(id)",
                )
            end
            if length(comp["cost"]) < 4
                error(
                    "cost includes $(comp["ncost"]) points, but at least two points are required on $(type_name) $(id)",
                )
            end

            modified = _remove_pwl_cost_duplicates!(id, comp, type_name)

            for i in 3:2:length(comp["cost"])
                if comp["cost"][i - 2] >= comp["cost"][i]
                    error("non-increasing x values in pwl cost model on $(type_name) $(id)")
                end
            end
            if "pmin" in keys(comp) && "pmax" in keys(comp)
                pmin = sum(comp["pmin"]) # sum supports multi-conductor case
                pmax = sum(comp["pmax"])
                for i in 3:2:length(comp["cost"])
                    if comp["cost"][i] < pmin || comp["cost"][i] > pmax
                        @info(
                            "pwl x value $(comp["cost"][i]) is outside the bounds $(pmin)-$(pmax) on $(type_name) $(id)"
                        )
                    end
                end
            end
            modified |= _simplify_pwl_cost!(id, comp, type_name)
        elseif comp["model"] == 2
            if length(comp["cost"]) != comp["ncost"]
                error(
                    "ncost of $(comp["ncost"]) not consistent with $(length(comp["cost"])) cost values on $(type_name) $(id)",
                )
            end
        else
            @info "Unknown cost model of type $(comp["model"]) on $(type_name) $(id)" maxlog =
                PS_MAX_LOG
        end
    end

    return modified
end

"checks that each point in the a pwl function is unique, simplifies the function if duplicates appear"
function _remove_pwl_cost_duplicates!(id, comp, type_name, tolerance = 1e-2)
    @assert comp["model"] == 1

    unique_costs = Float64[comp["cost"][1], comp["cost"][2]]
    for i in 3:2:length(comp["cost"])
        x1 = unique_costs[end - 1]
        y1 = unique_costs[end]
        x2 = comp["cost"][i + 0]
        y2 = comp["cost"][i + 1]
        if !(isapprox(x1, x2) && isapprox(y1, y2))
            push!(unique_costs, x2)
            push!(unique_costs, y2)
        end
    end

    # in the event that all of the given points are the same
    # this code ensures that at least two of the points remain
    if length(unique_costs) <= 2
        push!(unique_costs, comp["cost"][end - 1])
        push!(unique_costs, comp["cost"][end])
    end

    if length(unique_costs) < length(comp["cost"])
        @info "removing duplicate points from pwl cost on $(type_name) $(id), $(comp["cost"]) -> $(unique_costs)" maxlog =
            PS_MAX_LOG
        comp["cost"] = unique_costs
        comp["ncost"] = length(unique_costs) / 2
        return true
    end

    return false
end

"checks the slope of each segment in a pwl function, simplifies the function if the slope changes is below a tolerance"
function _simplify_pwl_cost!(id, comp, type_name, tolerance = 1e-2)
    @assert comp["model"] == 1

    slopes = Float64[]
    smpl_cost = Float64[]
    prev_slope = nothing

    x2, y2 = 0.0, 0.0

    for i in 3:2:length(comp["cost"])
        x1 = comp["cost"][i - 2]
        y1 = comp["cost"][i - 1]
        x2 = comp["cost"][i - 0]
        y2 = comp["cost"][i + 1]

        m = (y2 - y1) / (x2 - x1)

        if prev_slope === nothing || (abs(prev_slope - m) > tolerance)
            push!(smpl_cost, x1)
            push!(smpl_cost, y1)
            prev_slope = m
        end

        push!(slopes, m)
    end

    push!(smpl_cost, x2)
    push!(smpl_cost, y2)

    if length(smpl_cost) < length(comp["cost"])
        @info "simplifying pwl cost on $(type_name) $(id), $(comp["cost"]) -> $(smpl_cost)" maxlog =
            PS_MAX_LOG
        comp["cost"] = smpl_cost
        comp["ncost"] = length(smpl_cost) / 2
        return true
    end
    return false
end

"trims zeros from higher order cost terms"
function simplify_cost_terms!(data::Dict{String, <:Any})
    if ismultinetwork(data)
        networks = data["nw"]
    else
        networks = [("0", data)]
    end

    modified_gen = Set{Int}()
    modified_dcline = Set{Int}()

    for (i, network) in networks
        if haskey(network, "gen")
            for (i, gen) in network["gen"]
                if haskey(gen, "model") && gen["model"] == 2
                    ncost = length(gen["cost"])
                    for j in 1:ncost
                        if gen["cost"][1] == 0.0
                            gen["cost"] = gen["cost"][2:end]
                        else
                            break
                        end
                    end
                    if length(gen["cost"]) != ncost
                        gen["ncost"] = length(gen["cost"])
                        @info "removing $(ncost - gen["ncost"]) cost terms from generator $(i): $(gen["cost"])" maxlog =
                            PS_MAX_LOG
                        push!(modified_gen, gen["index"])
                    end
                end
            end
        end

        if haskey(network, "dcline")
            for (i, dcline) in network["dcline"]
                if haskey(dcline, "model") && dcline["model"] == 2
                    ncost = length(dcline["cost"])
                    for j in 1:ncost
                        if dcline["cost"][1] == 0.0
                            dcline["cost"] = dcline["cost"][2:end]
                        else
                            break
                        end
                    end
                    if length(dcline["cost"]) != ncost
                        dcline["ncost"] = length(dcline["cost"])
                        @info "removing $(ncost - dcline["ncost"]) cost terms from dcline $(i): $(dcline["cost"])" maxlog =
                            PS_MAX_LOG
                        push!(modified_dcline, dcline["index"])
                    end
                end
            end
        end
    end

    return (modified_gen, modified_dcline)
end

"""
Move gentype and genfuel fields to be subfields of gen
"""
function move_genfuel_and_gentype!(data::Dict{String, Any}) # added by PSY
    ngen = length(data["gen"])

    toplevkeys = ("genfuel", "gentype")
    sublevkeys = ("fuel", "type")
    for i in range(1; stop = length(toplevkeys))
        if haskey(data, toplevkeys[i])
            # check that lengths of category and generators match
            if length(data[toplevkeys[i]]) != ngen
                str = toplevkeys[i]
                throw(
                    DataFormatError(
                        "length of $str does not equal the number of generators",
                    ),
                )
            end
            for (key, val) in data[toplevkeys[i]]
                data["gen"][key][sublevkeys[i]] = val["col_1"]
            end
            delete!(data, toplevkeys[i])
        end
    end
end

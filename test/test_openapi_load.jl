@testset "read_loads! on the 14-bus PSS/E fixture makes StandardLoad, not PowerLoad" begin
    sys = PFP.build_openapi_system(fourteen_bus_pm_data())
    @test length(PFP.get_components(sys, "StandardLoad")) == 13
    @test isempty(PFP.get_components(sys, "PowerLoad"))
    @test isempty(PFP.get_components(sys, "InterruptibleStandardLoad"))
end

@testset "StandardLoad fields convert system pu to MW/MVAr against every 14-bus load" begin
    sys = PFP.build_openapi_system(fourteen_bus_pm_data())
    data = fourteen_bus_pm_data().data
    base_power = PFP.get_base_power(sys)
    reg = PFP.get_registry(sys)
    for load in PFP.get_components(sys, "StandardLoad")
        name = PFP.get_value(load, :name)
        # Default load name formatter has no separator: strip(join(source_id)).
        d = only(
            v for v in values(data["load"]) if
            strip(join(v["source_id"])) == name
        )
        @test PFP.get_value(load, :constant_active_power) ≈ d["pd"] * base_power
        @test PFP.get_value(load, :constant_reactive_power) ≈ d["qd"] * base_power
        @test PFP.get_value(load, :current_active_power) ≈ d["pi"] * base_power
        @test PFP.get_value(load, :current_reactive_power) ≈ d["qi"] * base_power
        @test PFP.get_value(load, :impedance_active_power) ≈ d["py"] * base_power
        @test PFP.get_value(load, :impedance_reactive_power) ≈ d["qy"] * base_power
        @test PFP.get_value(load, :max_constant_active_power) ≈ d["pd"] * base_power
        @test PFP.get_value(load, :base_power) == base_power
        @test PFP.get_value(load, :available) == d["status"]
        @test PFP.get_value(load, :conformity) == "CONFORMING"
        bus = only(
            b for b in PFP.get_components(sys, "ACBus") if
            PFP.get_value(b, :id) == PFP.get_value(load, :bus)
        )
        @test PFP.get_value(bus, :number) == d["load_bus"]
    end
end

@testset "StandardLoad fields are per-unit-on-device-base under COMPONENT_BASE" begin
    # A StandardLoad's own `base_power` is always the system base (read_loads! has no
    # per-load mbase concept -- unlike a generator's `mbase`), so COMPONENT_BASE's
    # natural_MW / base_power collapses to (raw_pu * base_power) / base_power == raw_pu:
    # the document should carry PowerModels' own system-per-unit numbers back verbatim.
    sys = PFP.build_openapi_system(fourteen_bus_pm_data(); power_units = "COMPONENT_BASE")
    data = fourteen_bus_pm_data().data
    for load in PFP.get_components(sys, "StandardLoad")
        name = PFP.get_value(load, :name)
        d = only(
            v for v in values(data["load"]) if
            strip(join(v["source_id"])) == name
        )
        @test PFP.get_value(load, :constant_active_power) ≈ d["pd"]
        @test PFP.get_value(load, :constant_reactive_power) ≈ d["qd"]
        @test PFP.get_value(load, :current_active_power) ≈ d["pi"]
        @test PFP.get_value(load, :current_reactive_power) ≈ d["qi"]
        @test PFP.get_value(load, :impedance_active_power) ≈ d["py"]
        @test PFP.get_value(load, :impedance_reactive_power) ≈ d["qy"]
        @test PFP.get_value(load, :base_power) == PFP.get_base_power(sys)
    end
end

@testset "_conformity_string maps PSCB's LoadConformity codes" begin
    @test PFP._conformity_string(0) == "NON_CONFORMING"
    @test PFP._conformity_string(1) == "CONFORMING"
    @test PFP._conformity_string(2) == "UNDEFINED"
    @test_throws IS.DataFormatError PFP._conformity_string(3)
end

@testset "a distributed-generation entry matched to its load becomes a RenewableNonDispatch" begin
    # v35_dgen.raw pairs two loads (bus 2, bus 3) with two distributed_generation
    # entries with matching (bus, id) keys — real PSS/E dgen data, not synthetic.
    pm = PFP.PowerModelsData(joinpath(@__DIR__, "fixtures", "v35_dgen.raw"))
    data = pm.data
    sys = PFP.build_openapi_system(pm)
    dgen_components = PFP.get_components(sys, "RenewableNonDispatch")
    @test length(dgen_components) == 2

    dgen_by_name = Dict(PFP.get_value(c, :name) => c for c in dgen_components)
    for (_, dgen) in data["distributed_generation"]
        bus_number = dgen["bus"]
        load = only(
            v for v in values(data["load"]) if v["load_bus"] == bus_number
        )
        load_name = strip(join(load["source_id"]))
        component = dgen_by_name[string(load_name, "_dgen")]
        base_power = PFP.get_base_power(sys)
        @test PFP.get_value(component, :active_power) ≈ dgen["pg"] * base_power
        @test PFP.get_value(component, :reactive_power) ≈ dgen["qg"] * base_power
        @test PFP.get_value(component, :rating) ≈
              hypot(dgen["pg"], dgen["qg"]) * base_power
        @test PFP.get_value(component, :available) == Bool(dgen["status"])
        @test PFP.get_value(component, :prime_mover_type) == "OT"
        @test PFP.get_value(component, :power_factor) == 1.0
    end
end

@testset "an unmatched distributed-generation entry is an error, not a skip" begin
    pm = PFP.PowerModelsData(joinpath(@__DIR__, "fixtures", "v35_dgen.raw"))
    data = deepcopy(pm.data)
    # Retarget one dgen entry onto a bus/id pair no load carries.
    data["distributed_generation"]["1"]["bus"] = 999
    sys = PFP.OpenAPISystem(Float64(data["baseMVA"]))
    PFP.read_loadzones!(sys, data)
    PFP.read_bus!(sys, data)
    @test_throws IS.DataFormatError PFP.read_loads!(sys, data)
end

@testset "PSS/E interruptible = 1 makes an InterruptibleStandardLoad" begin
    pm = fourteen_bus_pm_data()
    data = deepcopy(pm.data)
    first_key = first(keys(data["load"]))
    data["load"][first_key]["interruptible"] = 1
    sys = PFP.OpenAPISystem(Float64(data["baseMVA"]))
    PFP.read_loadzones!(sys, data)
    PFP.read_bus!(sys, data)
    PFP.read_loads!(sys, data)
    @test length(PFP.get_components(sys, "InterruptibleStandardLoad")) == 1
    @test length(PFP.get_components(sys, "StandardLoad")) == 12
    load = only(PFP.get_components(sys, "InterruptibleStandardLoad"))
    # `set_value!` routes `operation_cost` through OpenAPI.jl's oneOf `setproperty!`,
    # which wraps the assigned `PC.LoadCost` in an
    # `InterruptiblePowerLoadOperationCost(value = ...)` — unwrap with `.value`.
    cost = PFP.get_value(load, :operation_cost).value
    @test cost.fixed == 0.0
end

@testset "a non-PSS/E source with no \"interruptible\" key makes a PowerLoad" begin
    # case5.m: matpower-sourced, so data["load"] entries never carry "interruptible".
    pm = PFP.PowerModelsData(joinpath(MATPOWER_DIR, "case5.m"))
    sys = PFP.build_openapi_system(pm)
    @test length(PFP.get_components(sys, "PowerLoad")) == 3
    @test isempty(PFP.get_components(sys, "StandardLoad"))
    data = pm.data
    base_power = PFP.get_base_power(sys)
    for load in PFP.get_components(sys, "PowerLoad")
        name = PFP.get_value(load, :name)
        d = only(
            v for v in values(data["load"]) if
            strip(join(v["source_id"])) == name
        )
        @test PFP.get_value(load, :active_power) ≈ d["pd"] * base_power
        @test PFP.get_value(load, :reactive_power) ≈ d["qd"] * base_power
        @test PFP.get_value(load, :max_active_power) ≈ d["pd"] * base_power
        @test PFP.get_value(load, :conformity) == "CONFORMING"
    end
end

@testset "every load type carries its pm dict entry's ext" begin
    pm = fourteen_bus_pm_data()
    data = deepcopy(pm.data)
    data["load"][first(keys(data["load"]))]["interruptible"] = 1
    for (key, d) in data["load"]
        d["ext"]["mRID"] = "load-$key"
    end
    sys = PFP.OpenAPISystem(Float64(data["baseMVA"]))
    PFP.read_loadzones!(sys, data)
    PFP.read_bus!(sys, data)
    PFP.read_loads!(sys, data)
    loads = vcat(
        PFP.get_components(sys, "StandardLoad"),
        PFP.get_components(sys, "InterruptibleStandardLoad"),
    )
    @test length(loads) == 13
    for load in loads
        d = only(
            v for v in values(data["load"]) if
            strip(join(v["source_id"])) == PFP.get_value(load, :name)
        )
        @test PFP.get_ext(sys, PFP.get_value(load, :id)) == d["ext"]
    end

    pm = PFP.PowerModelsData(joinpath(MATPOWER_DIR, "case5.m"))
    for (key, d) in pm.data["load"]
        d["ext"] = Dict{String, Any}("mRID" => "load-$key")
    end
    sys = PFP.build_openapi_system(pm)
    loads = PFP.get_components(sys, "PowerLoad")
    @test length(loads) == 3
    for load in loads
        d = only(
            v for v in values(pm.data["load"]) if
            strip(join(v["source_id"])) == PFP.get_value(load, :name)
        )
        @test PFP.get_ext(sys, PFP.get_value(load, :id)) == d["ext"]
    end
end

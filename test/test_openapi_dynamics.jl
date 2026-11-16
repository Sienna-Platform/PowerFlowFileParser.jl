const DYNAMICS_DYR_DIR = joinpath(DATA_DIR, "psse_dyr")
const DYNAMICS_ACTIVSG2000_RAW = joinpath(DATA_DIR, "ACTIVSg2000", "ACTIVSg2000.RAW")

dynamics_system(raw::AbstractString, dyr::AbstractString) = PFP.build_openapi_system(
    joinpath(PSSE_RAW_DIR, raw),
    joinpath(DYNAMICS_DYR_DIR, dyr),
)

const DYNAMIC_INJECTION_TYPES =
    ("DynamicGenerator", "DynamicInverter", "AggregateDistributedGenerationA")

dynamic_injections(sys) =
    [c for t in DYNAMIC_INJECTION_TYPES for c in PFP.get_components(sys, t)]

all_rows(sys) = [
    row for type_name in PFP.component_type_names(sys) for
    row in PFP.get_components(sys, type_name)
]

has_injector(::Int) = true
has_injector(::Any) = false

named(sys, type_name, name) =
    only(c for c in PFP.get_components(sys, type_name) if PFP.get_value(c, :name) == name)

"""Check the link rules of SiennaSchemas `dynamic_links.py` that need no schema tree: unique
ids, `dynamic_injector` naming an injection of the same name, and every function block
named by exactly one injection (through the injection, or through a machine's `base_machine`)."""
function dynamic_link_problems(sys)
    problems = String[]
    ids = [PFP.get_value(row, :id) for row in all_rows(sys)]
    allunique(ids) || push!(problems, "component ids are not unique")
    injections = Dict(PFP.get_value(i, :id) => i for i in dynamic_injections(sys))
    blocks = Dict{Int, String}()
    for row in all_rows(sys)
        type_name = string(nameof(typeof(row)))
        if parentmodule(typeof(row)) === PFP.PD && !(type_name in DYNAMIC_INJECTION_TYPES)
            blocks[PFP.get_value(row, :id)] = type_name
        end
    end
    named_by = Dict{Int, Int}()
    for (id, injection) in injections
        for field in (
            :synchronous_machine_dynamics, :shaft, :excitation_system_dynamics,
            :turbine_governor_dynamics, :power_system_stabilizer_dynamics, :converter,
            :active_power_control, :reactive_power_control, :inner_control, :dc_source,
            :reference_frame_rotation, :filter,
        )
            if hasfield(typeof(injection), field)
                block = PFP.get_value(injection, field)
                named_by[block] = get(named_by, block, 0) + 1
            end
        end
    end
    for type_name in
        ("RoundRotorQuadratic", "RoundRotorExponential", "SalientPoleQuadratic")
        for machine in PFP.get_components(sys, type_name)
            base = PFP.get_value(machine, :base_machine)
            named_by[base] = get(named_by, base, 0) + 1
        end
    end
    for id in keys(blocks)
        if get(named_by, id, 0) != 1 && !haskey(injections, id)
            push!(problems, "block $id ($(blocks[id])) named $(get(named_by, id, 0)) times")
        end
    end
    owners = Dict{Int, String}()
    for type_name in ("ThermalStandard", "SynchronousCondenser")
        for device in PFP.get_components(sys, type_name)
            target = PFP.get_value(device, :dynamic_injector)
            if has_injector(target)
                if !haskey(injections, target)
                    push!(problems, "$(PFP.get_value(device, :name)) names $target")
                elseif PFP.get_value(injections[target], :name) !=
                       PFP.get_value(device, :name)
                    push!(problems, "name mismatch for injection $target")
                elseif haskey(owners, target)
                    push!(problems, "injection $target named twice")
                end
                owners[target] = PFP.get_value(device, :name)
            end
        end
    end
    for id in keys(injections)
        haskey(owners, id) || push!(problems, "injection $id has no static device")
    end
    return problems
end

@testset "dynamics: 2-area, 11-bus, 4-generator benchmark" begin
    sys = dynamics_system("Benchmark_4ger_33_2015.RAW", "Benchmark_4ger_33_2015.dyr")
    injections = dynamic_injections(sys)
    @test length(injections) == 4
    @test isempty(dynamic_link_problems(sys))
    @test length(PFP.get_components(sys, "RoundRotorExponential")) == 4
    @test isempty(PFP.get_components(sys, "Source"))
    for injection in injections
        @test PFP.get_value(injection, :frequency_ref) == 60.0
        @test PFP.get_value(injection, :base_power) == 900.0
    end
end

@testset "dynamics: benchmark with renewables" begin
    sys = dynamics_system(
        "Benchmark_4ger_33_2015_RENA.RAW",
        "Benchmark_4ger_33_2015_RENA.dyr",
    )
    @test length(dynamic_injections(sys)) == 5
    @test isempty(dynamic_link_problems(sys))
    inverter = only(PFP.get_components(sys, "DynamicInverter"))
    @test PFP.get_value(inverter, :current_limitation) === nothing
    @test PFP.get_value(inverter, :frequency_ref) == 60.0
    plls = PFP.get_components(sys, "FixedFrequency")
    @test only(plls).frequency == 60.0
    @test only(PFP.get_components(sys, "RECurrentControlB")).id ==
          PFP.get_value(inverter, :inner_control)
    @test only(PFP.get_components(sys, "FixedDCSource")).voltage == 750.0
end

@testset "dynamics: 240 bus WECC" begin
    sys = dynamics_system("240busWECC_2018_PSS33.raw", "240busWECC_2018_PSS.dyr")
    @test length(dynamic_injections(sys)) == 146
    @test length(PFP.get_components(sys, "DynamicGenerator")) == 109
    @test length(PFP.get_components(sys, "DynamicInverter")) == 37
    @test isempty(dynamic_link_problems(sys))
end

@testset "dynamics: 2000 bus" begin
    sys = PFP.build_openapi_system(
        DYNAMICS_ACTIVSG2000_RAW,
        joinpath(DYNAMICS_DYR_DIR, "ACTIVSg2000_dynamics.dyr"),
    )
    @test length(dynamic_injections(sys)) == 435
    @test isempty(dynamic_link_problems(sys))
    statics = [
        PFP.get_components(sys, "ThermalStandard")
        PFP.get_components(sys, "SynchronousCondenser")
    ]
    @test all(typeof(PFP.get_value(g, :dynamic_injector)) == Int for g in statics)
end

@testset "dynamics: GENROE values, SEXS values, GENCLS and Source fallbacks" begin
    gencls = dynamics_system("ThreeBusNetwork.raw", "TestGENCLS.dyr")
    @test isempty(dynamic_link_problems(gencls))

    # Bus 102 has H = 0, so a voltage source replaces the machine.
    @test isempty(
        [
        g for g in PFP.get_components(gencls, "ThermalStandard") if
        PFP.get_value(g, :name) == "generator-102-1"
    ],
    )
    source = named(gencls, "Source", "generator-102-1")
    @test PFP.get_value(source, :x_th) > 0.0

    genroe = named(gencls, "ThermalStandard", "generator-101-1")
    injection = only(
        i for i in PFP.get_components(gencls, "DynamicGenerator") if
        PFP.get_value(i, :id) == PFP.get_value(genroe, :dynamic_injector)
    )
    machine = only(PFP.get_components(gencls, "RoundRotorMachine"))
    @test machine.td0_p == 8.0
    @test machine.xd_pp == 0.25
    @test machine.se == [0.0392, 0.2672]
    @test machine.r == PFP.get_ext(gencls, PFP.get_value(genroe, :id))["r"]
    shafts = Dict(s.id => s for s in PFP.get_components(gencls, "SingleMass"))
    @test shafts[PFP.get_value(injection, :shaft)].h == 6.5
    avr = only(PFP.get_components(gencls, "ESST1A"))
    @test avr.id == PFP.get_value(injection, :excitation_system_dynamics)

    # GENCLS: R and Xd_p come from RSORCE and XSORCE of the RAW generator.
    cls = named(gencls, "ThermalStandard", "generator-103-1")
    base_machine = only(PFP.get_components(gencls, "BaseMachine"))
    ext = PFP.get_ext(gencls, PFP.get_value(cls, :id))
    @test base_machine.r == ext["r"]
    @test base_machine.xd_p == ext["x"]
    @test all(a.vf == 1.0 for a in PFP.get_components(gencls, "AVRFixed"))
    @test all(g.efficiency == 1.0 for g in PFP.get_components(gencls, "TGFixed"))

    # No record for bus 102 at all: also a voltage source.
    nocls = dynamics_system("ThreeBusNetwork.raw", "Test-NoCLS.dyr")
    @test isempty(dynamic_link_problems(nocls))
    @test typeof(PFP.get_value(named(nocls, "Source", "generator-102-1"), :bus)) == Int

    sexs = dynamics_system("ThreeBusNetwork.raw", "test_SEXS.dyr")
    avr = only(PFP.get_components(sexs, "SEXS"))
    @test avr.ta_tb == 0.4
    @test avr.tb == 5.0
    @test avr.k == 20.0
    @test avr.te == 1.0
    @test avr.v_lim.min == -50.0
    @test avr.v_lim.max == 50.0
end

@testset "dynamics: needs the system frequency, DER takes the static base" begin
    pm = PFP.PowerModelsData(joinpath(PSSE_RAW_DIR, "Benchmark_4ger_33_2015.RAW"))
    @test pm.data["base_frequency"] == 60.0
    delete!(pm.data, "base_frequency")
    dyr = PFP.parse_dyr(joinpath(DYNAMICS_DYR_DIR, "Benchmark_4ger_33_2015.dyr"))
    @test_throws IS.DataFormatError PFP.build_openapi_system(pm, dyr)

    sys = dynamics_system("240_bus_new_2.raw", "240_bus_remap2_dera2.dyr")
    @test !isempty(PFP.get_components(sys, "AggregateDistributedGenerationA"))
    @test isempty(dynamic_link_problems(sys))
    for der in PFP.get_components(sys, "AggregateDistributedGenerationA")
        device = named(sys, "ThermalStandard", PFP.get_value(der, :name))
        @test PFP.get_value(device, :dynamic_injector) == PFP.get_value(der, :id)
        @test PFP.get_value(der, :base_power) == PFP.get_value(device, :base_power)
    end
end

@testset "ACBus.voltage_setpoint and remote_regulated_bus" begin
    pm = fourteen_bus_pm_data()
    sys = PFP.build_openapi_system(pm)
    bus(number) = only(
        b for b in PFP.get_components(sys, "ACBus") if PFP.get_value(b, :number) == number
    )
    # PV bus 110 and slack bus 101 hold the generator `vg`; PQ bus 111 has no regulation.
    @test PFP.get_value(bus(110), :voltage_setpoint) == 1.0
    @test PFP.get_value(bus(101), :voltage_setpoint) == 1.0
    @test PFP.get_value(bus(111), :voltage_setpoint) === nothing
    for gen in PFP.get_components(sys, "ThermalStandard")
        @test PFP.get_value(gen, :remote_regulated_bus) === nothing
    end

    # A generator regulating a remote bus holds that bus, and names it by id.
    for entry in values(pm.data["gen"])
        if entry["gen_bus"] == 110
            entry["ext"]["IREG"] = 104
            entry["vg"] = 1.02
        end
    end
    sys = PFP.build_openapi_system(pm)
    @test PFP.get_value(bus(104), :voltage_setpoint) == 1.02
    gen = named(sys, "ThermalStandard", "generator-110-1")
    @test PFP.get_value(gen, :remote_regulated_bus) == PFP.get_value(bus(104), :id)
end

@testset "TransformerCircuit regulated_bus and orientation from CONT" begin
    sys = PFP.OpenAPISystem(100.0)
    reg = PFP.get_registry(sys)
    ids = Dict(n => PFP.register_bus!(reg, n, "b$n") for n in (1, 2, 3))
    function regulated(cont, objective)
        circuit = PFP.stage(PFP.PO.TransformerCircuit)
        PFP._set_transformer_regulated_bus!(circuit, reg, cont, objective, ids[1], ids[2])
        return PFP.get_value(circuit, :regulated_bus),
        PFP.get_value(circuit, :regulated_bus_orientation)
    end
    @test regulated(0, "VOLTAGE") == (nothing, "UNDEFINED")
    @test regulated(3, "FIXED") == (nothing, "UNDEFINED")
    @test regulated(2, "VOLTAGE") == (ids[2], "UNDEFINED")
    @test regulated(-1, "VOLTAGE_DISABLED") == (ids[1], "UNDEFINED")
    @test regulated(3, "VOLTAGE") == (ids[3], "TO")
    @test regulated(-3, "VOLTAGE") == (ids[3], "FROM")
    @test_throws IS.DataFormatError regulated(9, "VOLTAGE")
end

@testset "Source operation cost is PowerSystems' default ImportExportCost" begin
    cost = PFP.make_source_cost().value
    for curves in (cost.import_offer_curves, cost.export_offer_curves)
        @test curves.variable_cost_type == "COST"
        curve = curves.value_curve.value
        @test curve.curve_type == "INCREMENTAL"
        @test curve.initial_input == 0.0
        data = curve.function_data.value
        @test data.function_type == "PIECEWISE_STEP"
        @test data.x_coords == [0.0, 0.0]
        @test data.y_coords == [0.0]
    end
    @test cost.energy_import_weekly_limit == 1.0e6
    @test cost.energy_export_weekly_limit == 1.0e6

    sys = dynamics_system("ThreeBusNetwork.raw", "TestGENCLS.dyr")
    source = named(sys, "Source", "generator-102-1")
    @test PFP.get_value(source, :operation_cost).value.energy_import_weekly_limit == 1.0e6
end

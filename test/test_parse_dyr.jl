const PSSE_DYR_DIR = joinpath(DATA_DIR, "psse_dyr")

dyr_records(file) = PFP.parse_dyr(joinpath(PSSE_DYR_DIR, file))
dyr_all(records) = [rec for bus in values(records) for rec in values(bus)]
dyr_count(records, kind) = count(rec -> rec.kind == kind, dyr_all(records))
dyr_fields(rec, class) = PFP.get_component(rec, class).fields
dyr_type(rec, class) = PFP.get_component(rec, class).type

@testset "dyr reader" begin
    text = """
    // comment line
    101 'GENCLS' 1
        3.1, 2.0 /
    102 'GENCLS' '2' 0.0 0.0 /

    103 'GENCLS' 1 1.0 2.0 /
    """
    parsed = PFP.parse_dyr_text(text)
    @test sort(collect(keys(parsed))) == [101, 102, 103]
    @test parsed[101][("GENCLS", "1")] == [3.1, 2.0]
    @test parsed[102][("GENCLS", "2")] == [0.0, 0.0]

    @test_throws DataFormatError PFP.parse_dyr_text("101 'GENCLS' 1 3.1 2.0")
    @test_throws DataFormatError PFP.parse_dyr_text("101 'GENCLS' 1 3.1 abc /")
    @test_throws DataFormatError PFP.parse_dyr_text("101 'GENCLS' /")
    @test_throws DataFormatError PFP.parse_dyr_text(
        "101 'GENCLS' 1 1.0 /\n101 'GENCLS' 1 2.0 /",
    )
    @test_throws DataFormatError PFP.parse_dyr_file(
        joinpath(PSSE_RAW_DIR, "Benchmark_4ger_33_2015.RAW"),
    )

    raw = PFP.parse_dyr_file(joinpath(PSSE_DYR_DIR, "TestGENCLS.dyr"))
    @test length(raw[101][("GENROE", "1")]) == 14
    @test raw[101][("ESST1A", "1")][1] == 1.0
    @test raw[103][("GENCLS", "1")] == [3.1, 2.0]
end

@testset "dyr assembly: unsupported, incomplete and conflicting data" begin
    gencls = "101 'GENCLS' 1 3.1 2.0 /\n"
    @test_logs (:warn, r"FOO.*not supported") PFP.assemble_dyr(
        PFP.parse_dyr_text(gencls * "101 'FOO' 1 1.0 /"),
    )
    @test_throws DataFormatError PFP.assemble_dyr(
        PFP.parse_dyr_text("101 'EXAC1A' 1 1.0 /"),
    )
    # Exciter without a machine
    @test_throws DataFormatError PFP.assemble_dyr(
        PFP.parse_dyr_text("101 'SEXS' 1 0.4 5 20 1 -50 50 /"),
    )
    # Too few parameters for the mapping
    @test_throws DataFormatError PFP.assemble_dyr(
        PFP.parse_dyr_text("101 'GENCLS' 1 3.1 /"),
    )
    # A generator model and an inverter model share an id
    @test_throws DataFormatError PFP.assemble_dyr(
        PFP.parse_dyr_text(gencls * "101 'REGCA1' 1 " * join(fill("1.0", 15), " ") * " /"),
    )
    # REGCA1 alone: no active, reactive or inner control model
    @test_throws DataFormatError PFP.assemble_dyr(
        PFP.parse_dyr_text("101 'REGCA1' 1 " * join(fill("1.0", 15), " ") * " /"),
    )
end

@testset "dyr: 2-area, 11-bus, 4-generator benchmark" begin
    records = dyr_records("Benchmark_4ger_33_2015.dyr")
    @test length(dyr_all(records)) == 4
    for rec in dyr_all(records)
        @test rec.kind == :generator
        @test dyr_type(rec, "synchronous_machine_dynamics") == "RoundRotorExponential"
        @test dyr_type(rec, "base_machine") == "RoundRotorMachine"
        @test dyr_fields(rec, "synchronous_machine_dynamics")["base_machine"] ==
              PFP.DyrRef("base_machine")
        @test first.(rec.components) == [
            "base_machine",
            "synchronous_machine_dynamics",
            "shaft",
            "excitation_system_dynamics",
            "turbine_governor_dynamics",
            "power_system_stabilizer_dynamics",
        ]
    end
end

@testset "dyr: benchmark with renewables" begin
    records = dyr_records("Benchmark_4ger_33_2015_RENA.dyr")
    @test length(dyr_all(records)) == 5
    @test dyr_count(records, :generator) == 4
    @test dyr_count(records, :inverter) == 1
    for rec in dyr_all(records)
        if rec.kind == :inverter
            @test dyr_type(rec, "inner_control") == "RECurrentControlB"
            @test dyr_type(rec, "converter") == "RenewableEnergyConverterTypeA"
            @test dyr_type(rec, "active_power_control") == "ActiveRenewableControllerAB"
            @test dyr_type(rec, "reactive_power_control") == "ReactiveRenewableControllerAB"
            @test !PFP.has_component(rec, "current_limitation")
            # psy5 defaults for the models a .dyr file does not hold
            @test dyr_type(rec, "dc_source") == "FixedDCSource"
            @test dyr_fields(rec, "dc_source")["voltage"] == 750.0
            @test dyr_type(rec, "filter") == "RLFilter"
            @test typeof(dyr_fields(rec, "reference_frame_rotation")["frequency"]) ==
                  PFP.DyrSystemFrequency
            apc = dyr_fields(rec, "active_power_control")
            @test typeof(apc["Freq_Flag"]) == Bool
            @test typeof(apc["bus_control"]) == Int
            @test typeof(dyr_fields(rec, "reactive_power_control")["branch_id_control"]) ==
                  String
            @test haskey(apc, "P_lim_inner")  # from REECB1
            @test haskey(apc, "K_pg")  # from REPCA1
        else
            @test dyr_type(rec, "synchronous_machine_dynamics") == "RoundRotorExponential"
        end
    end
end

@testset "dyr: 240 bus WECC" begin
    records = dyr_records("240busWECC_2018_PSS.dyr")
    @test length(dyr_all(records)) == 146
    for rec in dyr_all(records)
        if rec.kind == :generator
            @test dyr_type(rec, "synchronous_machine_dynamics") == "RoundRotorQuadratic"
        else
            @test dyr_type(rec, "inner_control") == "RECurrentControlB"
        end
    end
end

@testset "dyr: DERA1" begin
    records = dyr_records("240_bus_remap2_dera2.dyr")
    ders = filter(rec -> rec.kind == :der, dyr_all(records))
    @test length(ders) == 3
    fields = dyr_fields(first(ders), "dynamic_injection")
    @test dyr_type(first(ders), "dynamic_injection") == "AggregateDistributedGenerationA"
    @test fields["Pf_Flag"] === true
    @test fields["PQ_Flag"] === false
    @test fields["fl"] == 56.5
    @test fields["fdbd_pnts"] == (fdbd1 = -0.0006, fdbd2 = 0.0006)
    @test fields["vl_pnts"] == [[0.16, 0.44], [0.16, 0.94]]
    @test !haskey(fields, "name")
    @test !haskey(fields, "base_power")
end

@testset "dyr: GENCLS and GENROE parameters" begin
    gencls = dyr_records("TestGENCLS.dyr")
    nocls = dyr_records("Test-NoCLS.dyr")
    sexs = dyr_records("test_SEXS.dyr")

    rec = gencls[101]["1"]
    machine = dyr_fields(rec, "base_machine")
    shaft = dyr_fields(rec, "shaft")
    @test dyr_type(rec, "synchronous_machine_dynamics") == "RoundRotorExponential"
    @test machine["R"] == 0.0  # RAW RSORCE replaces it in phase 2
    @test machine["Td0_p"] == 8.0
    @test machine["Td0_pp"] == 0.03
    @test machine["Tq0_p"] == 0.4
    @test machine["Tq0_pp"] == 0.05
    @test machine["Xd"] == 1.8
    @test machine["Xq"] == 1.7
    @test machine["Xd_p"] == 0.3
    @test machine["Xd_pp"] == 0.25
    @test machine["Xl"] == 0.2
    @test machine["Se"] == [0.0392, 0.2672]
    @test shaft["H"] == 6.5
    @test shaft["D"] == 0.0
    A, B = dyr_fields(rec, "synchronous_machine_dynamics")["saturation_coeffs"]
    @test B ≈ 0.0392 atol = 1e-9
    @test A ≈ log(0.2672 / 0.0392) / log(1.2)

    # GENCLS: BaseMachine with the psy5 placeholders for R, Xd_p and eq_p
    for records in (gencls, nocls)
        rec = records[103]["1"]
        @test dyr_type(rec, "synchronous_machine_dynamics") == "BaseMachine"
        @test !PFP.has_component(rec, "base_machine")
        @test dyr_fields(rec, "synchronous_machine_dynamics") ==
              Dict("R" => 0.0, "Xd_p" => 1.0e-5, "eq_p" => 1.0)
        @test dyr_fields(rec, "shaft") == Dict("H" => 3.1, "D" => 2.0)
    end
    @test dyr_fields(gencls[102]["1"], "shaft")["H"] == 0.0

    # Defaults for a missing exciter, governor and stabilizer
    rec = gencls[103]["1"]
    @test dyr_type(rec, "excitation_system_dynamics") == "AVRFixed"
    @test dyr_fields(rec, "excitation_system_dynamics") == Dict("Vf" => 1.0)
    @test dyr_fields(rec, "turbine_governor_dynamics") == Dict("efficiency" => 1.0)
    @test dyr_fields(rec, "power_system_stabilizer_dynamics") == Dict("V_pss" => 0.0)

    # ESST1A on GENROE
    @test dyr_type(gencls[101]["1"], "excitation_system_dynamics") == "ESST1A"

    # SEXS
    avr = dyr_fields(sexs[101]["1"], "excitation_system_dynamics")
    @test dyr_type(sexs[101]["1"], "excitation_system_dynamics") == "SEXS"
    @test avr["Ta_Tb"] == 0.4
    @test avr["Tb"] == 5.0
    @test avr["K"] == 20.0
    @test avr["Te"] == 1.0
    @test avr["V_lim"] == (min = -50.0, max = 50.0)
end

@testset "dyr: 2000 bus" begin
    records = dyr_records("ACTIVSg2000_dynamics.dyr")
    @test length(dyr_all(records)) == 435
    @test dyr_count(records, :generator) == 435
end

@testset "dyr: every file parses" begin
    for file in readdir(PSSE_DYR_DIR)
        if endswith(file, ".dyr")
            @test !isempty(dyr_all(dyr_records(file)))
        end
    end
end

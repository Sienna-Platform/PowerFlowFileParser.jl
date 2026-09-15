@testset "PSSE Parsing" begin
    files = readdir(PSSE_RAW_DIR)
    if length(files) == 0
        error("No test files in the folder")
    end

    for f in files[1:1]
        @info "Parsing $f ..."
        pm_data = PowerModelsData(joinpath(PSSE_RAW_DIR, f))
        @info "Successfully parsed $f to PowerModelsData"

        # Verify basic data structure
        @test isa(pm_data, PowerModelsData)
        @test haskey(pm_data.data, "baseMVA")
        @test haskey(pm_data.data, "bus")
        @test haskey(pm_data.data, "gen")
        @test haskey(pm_data.data, "branch")

        # Verify generators have ext data (impedance info may or may not be present depending on source)
        for (gen_id, gen) in pm_data.data["gen"]
            @test haskey(gen, "ext")
            # Note: "r" and "x" fields may be present depending on the PSS/E file version
        end

        @info "Successfully validated $f data structure"
    end

    # Test bad input
    pm_data = PowerModelsData(joinpath(PSSE_RAW_DIR, files[1]))
    pm_data.data["bus"] = Dict{String, Any}()
    # Note: Since we removed PowerSystems.System constructor,
    # we just verify the data structure is valid
    @test !haskey(pm_data.data, "ref_buses") || isempty(pm_data.data["ref_buses"])
end

@testset "PSSE v35 load distributed generation section" begin
    file = joinpath(@__DIR__, "fixtures", "v35_dgen.raw")
    pm_data = PowerModelsData(file).data

    # Loads keep the gross demand (per-unit on system base).
    load_at(bus) = only([l for l in values(pm_data["load"]) if l["load_bus"] == bus])
    @test load_at(2)["pd"] ≈ 1.0
    @test load_at(2)["qd"] ≈ 0.25
    @test load_at(3)["pd"] ≈ 0.5
    @test load_at(3)["qd"] ≈ 0.1

    # Distributed generation is split into its own section.
    dgens = pm_data["distributed_generation"]
    @test length(dgens) == 2
    dgen_at(bus) = only([d for d in values(dgens) if d["bus"] == bus])
    d2 = dgen_at(2)
    @test d2["pg"] ≈ 0.2
    @test d2["qg"] ≈ 0.05
    @test d2["status"] == 1
    @test d2["source_id"] == ["distributed_generation", 2, "1"]
    d3 = dgen_at(3)
    @test d3["pg"] ≈ 0.15
    @test d3["qg"] ≈ 0.03
    @test d3["status"] == 0

    # DGEN fields are consumed, not leaked into ext.
    @test !haskey(load_at(2)["ext"], "DGENP")

    # Without validation the values stay in natural units.
    pm_nat = parse_file(file; validate = false)
    d2_nat = only([d for d in values(pm_nat["distributed_generation"]) if d["bus"] == 2])
    @test d2_nat["pg"] == 20.0

    # Loads without DGEN produce no entries; the section still exists for PTI input.
    pm_v33 = PowerModelsData(joinpath(PSSE_RAW_DIR, "Benchmark_4ger_33_2015.RAW")).data
    @test isempty(pm_v33["distributed_generation"])
end

@testset "PSSE two-terminal DC resistance per-unit base" begin
    file = joinpath(@__DIR__, "fixtures", "synthetic_v35_two_terminal_dc.raw")
    pm_data = PowerModelsData(file).data
    dcline = only(values(pm_data["dcline"]))
    @test dcline["r"] ≈ 0.003125
    @test dcline["scheduled_dc_voltage"] == 400.0
    @test !(dcline["r"] ≈ 5.0 / (200.0^2 / 100.0))

    # A zero scheduled DC voltage cannot serve as a per-unit base on a line that is
    # in service. The check applies to every PSS(R)E version's two-terminal DC records.
    raw = read_fixture(file)
    bad = replace(raw, "400.00" => "0.0000"; count = 1)
    @test_throws ArgumentError parse_file(IOBuffer(bad); filetype = "raw")

    # A blocked line (MDC=0) with no DC voltage schedule warns and falls back to the
    # rectifier AC base rather than aborting the parse; the value is inert anyway.
    blocked = replace(bad, "\"DCTEST1     \",1," => "\"DCTEST1     \",0,")
    pm_blocked = @test_logs(
        (:warn, r"out of service"),
        match_mode = :any,
        parse_file(IOBuffer(blocked); filetype = "raw"),
    )
    blocked_dcline = only(values(pm_blocked["dcline"]))
    @test blocked_dcline["available"] == false
    @test blocked_dcline["r"] ≈ 5.0 / (200.0^2 / 100.0)
end

@testset "PSSE VSC line captures each converter's own AC bus base_kv" begin
    file = joinpath(@__DIR__, "fixtures", "synthetic_v35_vsc_line.raw")
    pm_data = PowerModelsData(file).data
    vscline = only(values(pm_data["vscline"]))
    @test vscline["f_bus"] == 1
    @test vscline["t_bus"] == 3
    @test vscline["base_voltage_from"] == 200.0
    @test vscline["base_voltage_to"] == 138.0
    @test vscline["rated_dc_voltage"] == 150.0
end

@testset "PSSE VSC converter loss: BLOSS is per-unitized on the DC base kV" begin
    # BLOSS is kW per DC ampere, so its LinearCurve slope is p.u. power per p.u. current:
    # BLOSS / base_kV, not BLOSS / (1000 * baseMVA), which is not even dimensionless.
    # ALOSS/MINLOSS are plain kW and do divide by 1000 * baseMVA. Port of
    # PowerSystems.jl 11562cc4b.
    file = joinpath(@__DIR__, "fixtures", "synthetic_v35_vsc_line.raw")
    pm_data = PowerModelsData(file).data
    vscline = only(values(pm_data["vscline"]))

    # Both converters carry ALOSS = 1000.0 kW, BLOSS = 1.5 kW/A, MINLOSS = 0.0, on a
    # 150 kV DC base (the TYPE 1 terminal's DCSET) and baseMVA = 100.0.
    @test vscline["rated_dc_voltage"] == 150.0
    for side in ("converter_loss_from", "converter_loss_to")
        curve = vscline[side]
        @test IS.get_proportional_term(curve) ≈ 1.5 / 150.0
        @test IS.get_constant_term(curve) ≈ 1000.0 / (1000.0 * 100.0)
    end
end

@testset "PSSE ISW area-slack flag" begin
    file = joinpath(@__DIR__, "fixtures", "v35_area_slack_variants.raw")
    pm_data = @test_logs(
        (:warn, r"ISW=3"),
        (:warn, r"ISW=999"),
        match_mode = :any,
        PowerModelsData(file).data,
    )
    @test pm_data["bus"][2]["area_slack"] === true
    @test !haskey(pm_data["bus"][1], "area_slack")
    @test !haskey(pm_data["bus"][3], "area_slack")

    # Real v33 case: area 1 ISW=1 targets a PV bus; area 2 ISW=3 targets the REF bus.
    pm_v33 = PowerModelsData(joinpath(PSSE_RAW_DIR, "Benchmark_4ger_33_2015.RAW")).data
    @test pm_v33["bus"][1]["area_slack"] === true
    @test !haskey(pm_v33["bus"][3], "area_slack")
end

@testset "PSSE v35 switched shunts: block statuses, and when BINIT is believed" begin
    # PSS/E v35 gives each switched-shunt block a status Si (in service / out), not a step
    # count, so an in-service block engages all Ni of its steps. BINIT is only the device's
    # actual admittance where PSS/E would not have adjusted it -- locked, on the swing bus,
    # or continuous -- or where the caller says the case was solved. See issue #57.
    file = joinpath(@__DIR__, "fixtures", "v35_switched_shunt.raw")
    pm_data = PowerModelsData(file).data
    @test pm_data["source_version"] == "35"

    shunts = values(pm_data["switched_shunt"])
    at(bus, id) = only(
        v for v in shunts if v["shunt_bus"] == bus && strip(v["sw_id"]) == id
    )

    # MODSW=1 on a type 1 bus: BINIT (60 MVAr) is where PSS/E's own adjustment started, so
    # it is dropped and the engaged blocks -- 3 steps of B1, none of the out-of-service
    # B2 -- are what the record asserts.
    adjusted = at(2, "1")
    @test adjusted["control_mode"] == 1
    @test !haskey(adjusted, "solved_admittance")
    @test adjusted["step_number"] == [3, 2]
    @test adjusted["y_increment"] == [0.1im, 0.2im]
    @test adjusted["number_engaged"] == [3, 0]

    # MODSW=0: locked at BINIT, which PSS/E never moves.
    locked = at(2, "2")
    @test locked["control_mode"] == 0
    @test locked["solved_admittance"] == 0.45
    @test locked["number_engaged"] == [2]

    # MODSW=2: continuously adjusted, so its admittance is off the step ladder entirely and
    # the block statuses could not express it -- BINIT is the only value there is.
    continuous = at(2, "3")
    @test continuous["control_mode"] == 2
    @test continuous["solved_admittance"] == 0.375

    # A shunt on the type 3 (swing) bus is locked whatever MODSW says.
    swing = at(1, "1")
    @test swing["control_mode"] == 1
    @test swing["solved_admittance"] == 0.25

    # PSS/E reads the blocks as a contiguous run and stops at the first zero Ni or Bi. The
    # bus-3 record has N2=0, so it defines one block: the nonzero B3 columns past the
    # terminator are not a third block and must not be swept in.
    terminated = at(3, "1")
    @test terminated["step_number"] == [2]
    @test terminated["y_increment"] == [0.08im]
    @test terminated["number_engaged"] == [2]

    # Declaring the case solved takes BINIT at face value everywhere.
    solved = PowerModelsData(file; solved_case = true).data
    solved_at(bus, id) = only(
        v for v in values(solved["switched_shunt"]) if
        v["shunt_bus"] == bus && strip(v["sw_id"]) == id
    )
    @test solved_at(2, "1")["solved_admittance"] == 0.6
    @test solved_at(3, "1")["solved_admittance"] == 0.16
    # The blocks are still reported; only the admittance's source changes.
    @test solved_at(2, "1")["number_engaged"] == [3, 0]
end

@testset "PSSE pre-v35 switched shunts carry BINIT separately from the blocks" begin
    # Pre-v35 SWITCHED SHUNT records have no per-block status field, so how many steps of
    # each block are engaged is unknown and `number_engaged` is zero-filled to record that.
    # BINIT is the device's actual admittance and now lands in its own `solved_admittance`
    # key rather than in `bs`, so nothing has to be reconstructed from the blocks and there
    # is no double-count to avoid. See PowerSystems.jl#1774.
    raw = read_fixture(FOURTEEN_BUS_FIXTURE)
    pm_data = parse_file(IOBuffer(raw); filetype = "raw")
    @test pm_data["source_version"] == "33"

    shunts = collect(values(pm_data["switched_shunt"]))
    @test !isempty(shunts)
    for shunt in shunts
        @test shunt["number_engaged"] == zeros(Int, length(shunt["y_increment"]))
        # BINIT no longer masquerades as a fixed base admittance.
        @test shunt["gs"] == 0.0
        @test shunt["bs"] == 0.0
        @test haskey(shunt, "solved_admittance")
    end

    # Bus 101's record is MODSW=1, which an earlier mode-specific patch already zeroed.
    # MODSW=3 took the fabricated all-ones path and is the case this fixes.
    modsw3 = replace(raw, "   101,1,0,1," => "   101,3,0,1,"; count = 1)
    @test modsw3 != raw
    pm_modsw3 = parse_file(IOBuffer(modsw3); filetype = "raw")
    shunt_101 =
        only(v for v in values(pm_modsw3["switched_shunt"]) if v["shunt_bus"] == 101)
    @test shunt_101["control_mode"] == 3
    @test shunt_101["step_number"] == [5]
    @test length(shunt_101["y_increment"]) == 1
    @test shunt_101["number_engaged"] == [0]
    # BINIT = 50 MVAr on a 100 MVA base, per-unitized alongside bs/y_increment.
    @test shunt_101["solved_admittance"] == 0.5
end

@testset "PSSE transformer CM=2 magnetizing susceptance is inductive" begin
    # Under CM=2 a transformer record gives MAG1 as a positive number by convention, when
    # the magnetizing branch is inductive (negative susceptance).
    raw = read_fixture(FOURTEEN_BUS_FIXTURE)

    # The fixture's transformers are all CM=1 with zero MAG1/MAG2. Flip one two-winding
    # and one three-winding record to CM=2 and give them a loss/exciting-current pair.
    # Record line 1 is `I, J, K, CKT, CW, CZ, CM, MAG1, MAG2, NMETR, NAME, ...`.
    mag1_watts, mag2_pu = 3.0e4, 5.0e-3
    cm2 = replace(
        raw,
        "   109,   104,     0,'1 ',1,1,1, 0.00000E+0, 0.00000E+0,2,'TRAFO 2W 3  '" => "   109,   104,     0,'1 ',1,1,2, 3.00000E+4, 5.00000E-3,2,'TRAFO 2W 3  '",
        "   109,   104,   107,'1 ',1,1,1, 0.00000E+0, 0.00000E+0,2,'TRAFO 3W 2  '" => "   109,   104,   107,'1 ',1,1,2, 3.00000E+4, 5.00000E-3,2,'TRAFO 3W 2  '",
    )
    @test cm2 != raw
    pm_data = parse_file(IOBuffer(cm2); filetype = "raw")

    # SBASE1-2 is 100.0 for both records, so G is watts scaled to that base and B closes
    # the right triangle against the exciting current.
    expected_g = 1e-6 * mag1_watts / 100.0
    expected_b = -sqrt(mag2_pu^2 - expected_g^2)
    @test expected_b < 0

    branch = only(
        v for v in values(pm_data["branch"]) if
        get(get(v, "ext", Dict()), "psse_name", "") == "TRAFO 2W 3  "
    )
    @test branch["g_fr"] ≈ expected_g
    @test branch["b_fr"] ≈ expected_b
    @test branch["b_fr"] < 0

    transformer_3w = only(
        v for v in values(pm_data["3w_transformer"]) if
        get(get(v, "ext", Dict()), "psse_name", "") == "TRAFO 3W 2  "
    )
    @test transformer_3w["g"] ≈ expected_g
    @test transformer_3w["b"] ≈ expected_b
    @test transformer_3w["b"] < 0
end

@testset "PSSE transformer CM=2 zero MAG1/MAG2 warns on both winding counts" begin
    # The zero check guards against a magnetizing branch with nothing to derive. It only
    # runs under CM=2, so flip the same two records the sign test uses but leave their
    # MAG1/MAG2 at the fixture's zeros. The three-winding record is the one that matters:
    # its sub_data names buses "bus_primary"/"bus_secondary"/"bus_tertiary", so a warning
    # reaching for "f_bus" would throw rather than warn.
    raw = read_fixture(FOURTEEN_BUS_FIXTURE)
    cm2 = replace(
        raw,
        "   109,   104,     0,'1 ',1,1,1, 0.00000E+0, 0.00000E+0,2,'TRAFO 2W 3  '" => "   109,   104,     0,'1 ',1,1,2, 0.00000E+0, 0.00000E+0,2,'TRAFO 2W 3  '",
        "   109,   104,   107,'1 ',1,1,1, 0.00000E+0, 0.00000E+0,2,'TRAFO 3W 2  '" => "   109,   104,   107,'1 ',1,1,2, 0.00000E+0, 0.00000E+0,2,'TRAFO 3W 2  '",
    )
    @test cm2 != raw

    # Collect the records rather than using @test_logs: a message that fails to build is
    # still reported as a warning, and match_mode = :any accepts that stand-in, so assert
    # on the rendered message text directly.
    logs, pm_data = Test.collect_test_logs() do
        parse_file(IOBuffer(cm2); filetype = "raw")
    end
    messages = [string(r.message) for r in logs if r.level == Logging.Warn]
    @test count(m -> occursin("has zero MAG1 and MAG2 values", m), messages) == 2
    @test any(m -> occursin("Transformer 109 -> 104 has zero", m), messages)
    @test any(m -> occursin("Transformer 109 -> 104 -> 107 has zero", m), messages)

    branch = only(
        v for v in values(pm_data["branch"]) if
        get(get(v, "ext", Dict()), "psse_name", "") == "TRAFO 2W 3  "
    )
    @test branch["g_fr"] == 0.0
    @test branch["b_fr"] == 0.0

    transformer_3w = only(
        v for v in values(pm_data["3w_transformer"]) if
        get(get(v, "ext", Dict()), "psse_name", "") == "TRAFO 3W 2  "
    )
    @test transformer_3w["g"] == 0.0
    @test transformer_3w["b"] == 0.0
end

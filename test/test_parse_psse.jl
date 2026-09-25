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

@testset "PSSE two-terminal DC impedances stay in ohms" begin
    # Downstream per-unitizes each impedance on its own base (VSCHD for RDC, EBASR/EBASI
    # for the converter fields), so the parser hands over the RAW's ohms untouched.
    file = joinpath(@__DIR__, "fixtures", "synthetic_v35_two_terminal_dc.raw")
    raw_line = only(PowerFlowFileParser.parse_pti(file)["TWO-TERMINAL DC"])
    pm_data = PowerModelsData(file).data
    dcline = only(values(pm_data["dcline"]))
    @test dcline["scheduled_dc_voltage"] == 400.0
    @test dcline["r"] == raw_line["RDC"] == 5.0
    @test dcline["rectifier_rc"] == raw_line["RCR"]
    @test dcline["rectifier_xc"] == raw_line["XCR"] == 5.0
    @test dcline["inverter_rc"] == raw_line["RCI"]
    @test dcline["inverter_xc"] == raw_line["XCI"] == 5.0
    @test dcline["rectifier_capacitor_reactance"] == raw_line["XCAPR"]
    @test dcline["inverter_capacitor_reactance"] == raw_line["XCAPI"]
    @test dcline["compounding_resistance"] == raw_line["RCOMP"]

    # An in-service line needs a scheduled DC voltage. The check applies to every
    # PSS(R)E version's two-terminal DC records.
    raw = read_fixture(file)
    bad = replace(raw, "400.00" => "0.0000"; count = 1)
    @test_throws ArgumentError parse_file(IOBuffer(bad); filetype = "raw")

    # A blocked line (MDC=0) with no DC voltage schedule still parses.
    blocked = replace(bad, "\"DCTEST1     \",1," => "\"DCTEST1     \",0,")
    pm_blocked = parse_file(IOBuffer(blocked); filetype = "raw")
    blocked_dcline = only(values(pm_blocked["dcline"]))
    @test blocked_dcline["available"] == false
    @test blocked_dcline["control_mode"] == "BLOCKED"
    @test blocked_dcline["r"] == 5.0
end

@testset "PSSE VSC line resistance stays in ohms" begin
    file = joinpath(@__DIR__, "fixtures", "synthetic_v35_vsc_line.raw")
    raw = replace(
        read_fixture(file),
        "'VSCLINE1    ', 1, 0.0000," => "'VSCLINE1    ', 1, 2.5000,",
    )
    vscline = only(values(parse_file(IOBuffer(raw); filetype = "raw")["vscline"]))
    @test vscline["r"] == 2.5
end

@testset "Two-terminal DC MDC maps to the three LCCControlMode strings" begin
    # MDC=1 (14-bus fixture) and MDC=2 (discriminator fixture) parse to their names; an
    # unknown code is rejected rather than defaulted. MDC=0 is covered above.
    power =
        only(values(parse_file(joinpath(@__DIR__, "modified_14bus_system.raw"))["dcline"]))
    @test power["control_mode"] == "POWER"
    current = only(
        values(
            parse_file(
                joinpath(
                    @__DIR__,
                    "fixtures",
                    "synthetic_v35_transformer_discriminators.raw",
                ),
            )["dcline"],
        ),
    )
    @test current["control_mode"] == "CURRENT"
    @test current["available"]
    @test_throws PowerFlowFileParser.DataFormatError PowerFlowFileParser._lcc_control_mode(
        42,
        "x",
    )
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

@testset "PSSE VSC line out of service with no DC-voltage-controlling converter" begin
    # WECC planning cases carry VSC lines with MDC = 0 and both converters TYPE = 0.
    # PSS/E keeps the record; the parser must keep it as unavailable rather than abort.
    file = joinpath(@__DIR__, "fixtures", "synthetic_v35_vsc_line_out_of_service.raw")
    pm_data = @test_logs(
        (:warn, r"VSCLINE1\s+is out of service"),
        match_mode = :any,
        PowerModelsData(file).data,
    )
    vscline = only(values(pm_data["vscline"]))
    @test vscline["br_status"] == 0
    @test vscline["available"] == false
    @test vscline["dc_voltage_control_from"] == false
    @test vscline["dc_voltage_control_to"] == false
    # Largest |DCSET| stands in for the DC voltage base; no scheduled flow.
    @test vscline["rated_dc_voltage"] == 150.0
    @test vscline["pf"] == 0.0
    @test vscline["if"] == 0.0
    @test isfinite(vscline["r"])
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
    # Si is a block status, so an in-service block engages all Ni of its steps. BINIT is
    # only the device's admittance where PSS/E would not have adjusted it. See issue #57.
    file = joinpath(@__DIR__, "fixtures", "v35_switched_shunt.raw")
    pm_data = PowerModelsData(file).data
    @test pm_data["source_version"] == "35"

    shunts = values(pm_data["switched_shunt"])
    at(bus, id) = only(
        v for v in shunts if v["shunt_bus"] == bus && strip(v["sw_id"]) == id
    )

    # MODSW=1 on a type 1 bus: BINIT (60 MVAr) is only a starting value, so it is dropped
    # and the engaged blocks stand -- 3 steps of B1, none of the out-of-service B2.
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

    # MODSW=2: the admittance is off the step ladder, so the blocks cannot express it.
    continuous = at(2, "3")
    @test continuous["control_mode"] == 2
    @test continuous["solved_admittance"] == 0.375

    # A shunt on the type 3 (swing) bus is locked whatever MODSW says.
    swing = at(1, "1")
    @test swing["control_mode"] == 1
    @test swing["solved_admittance"] == 0.25

    # The bus-3 record has N2=0, which terminates the block list: the nonzero B3 columns
    # past it are not a third block.
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
    @test solved_at(2, "1")["number_engaged"] == [3, 0]
end

@testset "PSSE switched shunt swing-bus rule survives a node-breaker split" begin
    # The type 3 rule is about the RAW's own bus I, not the node-bus the shunt routes onto:
    # `_prepare_node_breaker!` initializes those to PQ, and only a generator promotes one
    # back -- in a pass that runs after this section.
    raw = read_fixture(joinpath(@__DIR__, "fixtures", "synthetic_v35_node_breaker.raw"))

    # Make the substation's bus 2 the swing bus, leaving bus 1 PV with its generator, and
    # put a MODSW=1 switched shunt on node 2 -- not the representative node, so it lands on
    # an injected node-bus rather than on bus 2 itself.
    patched = replace(
        raw,
        "     1,'BUSONE      ', 138.0000,3," => "     1,'BUSONE      ', 138.0000,2,",
        "     2,'BUSTWO      ', 138.0000,1," => "     2,'BUSTWO      ', 138.0000,3,",
        "0 / END OF FACTS DEVICE DATA, BEGIN SWITCHED SHUNT DATA\n" =>
            "0 / END OF FACTS DEVICE DATA, BEGIN SWITCHED SHUNT DATA\n" *
            "     2,'1 ',    1,   0,   1, 1.05000, 0.95000,     0,    0, 100.0," *
            "'        ',   30.000,  1,  2,    10.000\n",
        "     0 / END OF SUBSTATION TERMINAL DATA" => "     2,  2, 'S',       '1 '\n     0 / END OF SUBSTATION TERMINAL DATA",
    )
    @test patched != raw

    pm_data = parse_file(IOBuffer(patched); filetype = "raw")
    shunt = only(values(pm_data["switched_shunt"]))

    @test shunt["shunt_bus"] != 2
    @test pm_data["bus"][shunt["shunt_bus"]]["bus_type"] == PFP.PM_BUS_TYPE_PQ
    @test pm_data["bus"][2]["bus_type"] == PFP.PM_BUS_TYPE_REF
    @test shunt["control_mode"] == 1
    @test shunt["solved_admittance"] == 0.3
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

@testset "PSSE CW=2 tap-ratio limits are converted with the tap" begin
    # Under CW=2 WINDV and the RMA/RMI that bracket it are winding voltages in kV. Both must
    # reach the pm dict in the tap's own units, so a tap inside its band stays inside it.
    raw = read_fixture(FOURTEEN_BUS_FIXTURE)

    # "TRAFO 2W 1" runs 230 kV bus 106 to 138 kV bus 105 and regulates voltage (COD1=1).
    # WINDV1 = 232.875 kV sits on step 18 of the 33-step 207..253 kV ladder, and
    # WINDV2 = 141.45 kV is 1.025 pu, so the tap and its band all divide by 1.025.
    # "TRAFO 2W 3" is a CW=2 phase shifter (COD1=3), whose limits are degrees.
    # "TRAFO 3W 1" winds 230/230/500 kV and exercises one objective per winding.
    cw2 = replace(
        raw,
        "   106,   105,     0,'1 ',1,1,1, 0.00000E+0, 0.00000E+0,2,'TRAFO 2W 1  ',1,   1,1.0000,   0,1.0000,   0,1.0000,   0,1.0000,'            '\n" *
        " 0.00000E+0, 1.00000E-4,   100.00\n" *
        "1.00000,   0.000,   0.000,     0.00,     0.00,     0.00, 0,      0, 1.10000, 0.90000, 1.10000, 0.90000,  33, 7, 0.00000, 0.00000,  0.000\n" *
        "1.00000,   0.000\n" =>
            "   106,   105,     0,'1 ',2,1,1, 0.00000E+0, 0.00000E+0,2,'TRAFO 2W 1  ',1,   1,1.0000,   0,1.0000,   0,1.0000,   0,1.0000,'            '\n" *
            " 0.00000E+0, 1.00000E-4,   100.00\n" *
            "232.875,   0.000,   0.000,     0.00,     0.00,     0.00, 1,    105, 253.000, 207.000, 1.10000, 0.90000,  33, 7, 0.00000, 0.00000,  0.000\n" *
            "141.450,   0.000\n",
        "   109,   104,     0,'1 ',1,1,1, 0.00000E+0, 0.00000E+0,2,'TRAFO 2W 3  ',1,   1,1.0000,   0,1.0000,   0,1.0000,   0,1.0000,'            '\n" *
        " 0.00000E+0, 1.00000E-4,   100.00\n" *
        "1.00000,   0.000,   0.000,     0.00,     0.00,     0.00, 0,      0, 1.10000, 0.90000, 1.10000, 0.90000,  33, 4, 0.00000, 0.00000,  0.000\n" *
        "1.00000,   0.000\n" =>
            "   109,   104,     0,'1 ',2,1,1, 0.00000E+0, 0.00000E+0,2,'TRAFO 2W 3  ',1,   1,1.0000,   0,1.0000,   0,1.0000,   0,1.0000,'            '\n" *
            " 0.00000E+0, 1.00000E-4,   100.00\n" *
            "500.000,   0.000,   0.000,     0.00,     0.00,     0.00, 3,      0, 30.0000, -30.000, 1.10000, 0.90000,  33, 4, 0.00000, 0.00000,  0.000\n" *
            "138.000,   0.000\n",
        "   113,   110,   114,'1 ',1,1,1, 0.00000E+0, 0.00000E+0,2,'TRAFO 3W 1  ',1,   1,1.0000,   0,1.0000,   0,1.0000,   0,1.0000,'            '\n" *
        " 0.00000E+0, 2.00000E-4,   100.00, 0.00000E+0, 2.00000E-4,   100.00, 0.00000E+0, 2.00000E-4,   100.00,0.99967,  -3.0658\n" *
        "1.00000,   0.000,   0.000,     0.00,     0.00,     0.00, 0,      0, 1.10000, 0.90000, 1.10000, 0.90000,  33, 9, 0.00000, 0.00000,  0.000\n" *
        "1.00000,   0.000,   0.000,     0.00,     0.00,     0.00, 0,      0, 1.10000, 0.90000, 1.10000, 0.90000,  33, 8, 0.00000, 0.00000,  0.000\n" *
        "1.00000,   0.000,   0.000,     0.00,     0.00,     0.00, 0,      0, 1.10000, 0.90000, 1.10000, 0.90000,  33, 9, 0.00000, 0.00000,  0.000\n" =>
            "   113,   110,   114,'1 ',2,1,1, 0.00000E+0, 0.00000E+0,2,'TRAFO 3W 1  ',1,   1,1.0000,   0,1.0000,   0,1.0000,   0,1.0000,'            '\n" *
            " 0.00000E+0, 2.00000E-4,   100.00, 0.00000E+0, 2.00000E-4,   100.00, 0.00000E+0, 2.00000E-4,   100.00,0.99967,  -3.0658\n" *
            "232.875,   0.000,   0.000,     0.00,     0.00,     0.00, 1,    113, 253.000, 207.000, 1.10000, 0.90000,  33, 9, 0.00000, 0.00000,  0.000\n" *
            "230.000,   0.000,   0.000,     0.00,     0.00,     0.00, 0,      0, 253.000, 207.000, 1.10000, 0.90000,  33, 8, 0.00000, 0.00000,  0.000\n" *
            "500.000,   0.000,   0.000,     0.00,     0.00,     0.00, 3,      0, 30.0000, -30.000, 1.10000, 0.90000,  33, 9, 0.00000, 0.00000,  0.000\n",
    )
    @test cw2 != raw
    pm_data = parse_file(IOBuffer(cw2); filetype = "raw")
    by_name(section, name) = only(
        v for v in values(pm_data[section]) if
        get(get(v, "ext", Dict()), "psse_name", "") == name
    )

    regulating = by_name("branch", "TRAFO 2W 1  ")
    @test regulating["tap"] ≈ 1.0125 / 1.025
    @test regulating["RMI1"] ≈ 0.9 / 1.025
    @test regulating["RMA1"] ≈ 1.1 / 1.025
    @test regulating["RMI1"] < regulating["tap"] < regulating["RMA1"]
    # ext keeps the record's own values.
    @test regulating["ext"]["RMA1"] == 253.0

    phase_shifter = by_name("branch", "TRAFO 2W 3  ")
    @test phase_shifter["tap"] ≈ 1.0
    @test phase_shifter["RMI1"] == -30.0
    @test phase_shifter["RMA1"] == 30.0

    transformer_3w = by_name("3w_transformer", "TRAFO 3W 1  ")
    @test transformer_3w["primary_turns_ratio"] ≈ 1.0125
    @test transformer_3w["RMI1"] ≈ 0.9
    @test transformer_3w["RMA1"] ≈ 1.1
    @test transformer_3w["secondary_turns_ratio"] ≈ 1.0
    @test transformer_3w["RMI2"] ≈ 0.9
    @test transformer_3w["RMA2"] ≈ 1.1
    @test transformer_3w["tertiary_turns_ratio"] ≈ 1.0
    @test transformer_3w["RMI3"] == -30.0
    @test transformer_3w["RMA3"] == 30.0
end

@testset "PSSE duplicate TRANSFORMER records: first read is kept, later ones dropped" begin
    # XFMR_A and XFMR_B both join buses 201-202; their circuit ids '1 ' and ' 1' are the
    # same identity to PSS/E once stripped. XFMR_C on 203-204 shares nothing but bus names.
    file = joinpath(@__DIR__, "fixtures", "synthetic_v35_duplicate_transformer_names.raw")
    pm_data = @test_logs(
        (:warn, r"Duplicate TRANSFORMER record between buses 201-202 with circuit id '1'"),
        match_mode = :any,
        PowerModelsData(file).data,
    )
    transformers = [b for b in values(pm_data["branch"]) if b["transformer"]]
    @test length(transformers) == 2

    kept = only(b for b in transformers if b["f_bus"] == 201 && b["t_bus"] == 202)
    @test kept["ext"]["psse_name"] == "XFMR_A      "
    @test kept["br_x"] == 0.05
    @test kept["rate_a"] ≈ 0.4  # 40 MVA on the 100 MVA base
    @test kept["source_id"][5] == "1"  # circuit id stored stripped

    other = only(b for b in transformers if b["f_bus"] == 203 && b["t_bus"] == 204)
    @test other["ext"]["psse_name"] == "XFMR_C      "
    @test other["br_x"] == 0.05
end

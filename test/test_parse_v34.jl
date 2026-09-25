# PSS(R)E v34 keeps the v33 field order in seven records and appends its new fields at
# the end, where v35 inserts them mid-record. Fixtures copy the shapes of a real rawd34
# export: `@!` column comments, blank title lines, a SYSTEM-WIDE block with double-quoted
# RATING records, records truncated at the last non-default field, and double-quoted
# DC-line and FACTS names.

const V34_FULL_FIXTURE = joinpath(@__DIR__, "fixtures", "synthetic_v34_full.raw")
const V34_SUBSTATION_FIXTURE =
    joinpath(@__DIR__, "fixtures", "synthetic_v34_substation.raw")

@testset "PSSE v34 stage 1: section tables" begin
    pti = PowerFlowFileParser._parse_pti_data(IOBuffer(read(V34_FULL_FIXTURE, String)))

    @test pti["CASE IDENTIFICATION"][1]["REV"] == 34
    @test pti["CASE IDENTIFICATION"][1]["Comment_Line_1"] == ""
    @test length(pti["BUS"]) == 8
    @test length(pti["SWITCHING DEVICE"]) == 1

    @testset "generator: NREG is the trailing column, no BASLOD" begin
        gens = Dict(g["I"] => g for g in pti["GENERATOR"])
        @test gens[1]["NREG"] == 5
        @test gens[1]["WMOD"] == 0
        @test gens[1]["WPF"] == 1.0
        # truncated after O1/F1: trailing fields take their defaults
        @test gens[2]["NREG"] == 0
        @test gens[2]["WPF"] == 1.0
        @test !haskey(gens[1], "BASLOD")
    end

    @testset "load: DGEN fields present, no LOADTYPE" begin
        load3 = only(l for l in pti["LOAD"] if l["I"] == 3)
        @test load3["DGENP"] == 3.333
        @test load3["DGENQ"] == 0.5
        @test load3["DGENM"] == 1.0
        @test !haskey(load3, "LOADTYPE")
    end

    @testset "transformer winding line: NOD1 is the last column" begin
        xf = Dict((t["I"], t["J"]) => t for t in pti["TRANSFORMER"])
        t1 = xf[(201, 202)]
        @test t1["NOD1"] == 9
        @test t1["RMA1"] == 1.1
        @test t1["RMI1"] == 0.9
        @test t1["NTP1"] == 33
        @test t1["CNXA1"] == 0.0
        @test t1["RATE11"] == 40.0
        t3 = xf[(301, 302)]
        @test t3["NOD1"] == 11
        @test t3["NOD2"] == 12
        @test t3["NOD3"] == 13
        @test t3["RATE21"] == 150.0
        @test t3["RATE31"] == 50.0
    end

    @testset "two-terminal DC: NDR and NDI trail their converter lines" begin
        dc = only(pti["TWO-TERMINAL DC"])
        @test dc["NAME"] == "DCV34TEST   "  # double quotes removed
        @test dc["NDR"] == 4
        @test dc["NDI"] == 6
        @test dc["IFR"] == 0
        @test dc["ITR"] == 0
        @test dc["IDR"] == "1 "
        @test dc["XCAPR"] == 0.0
    end

    @testset "VSC sublines: VSREG, RMPCT, NREG order" begin
        vsc = only(pti["VOLTAGE SOURCE CONVERTER"])
        rectifier, inverter = vsc["CONVERTER BUSES"]
        @test rectifier["REMOT"] == 0
        @test rectifier["RMPCT"] == 75.0
        @test rectifier["NREG"] == 8
        @test inverter["RMPCT"] == 60.0
        @test inverter["NREG"] == 0
    end

    @testset "FACTS: FCREG, MNAME, NREG order" begin
        facts = only(pti["FACTS CONTROL DEVICE"])
        @test facts["NAME"] == "FACTSV34    "
        @test facts["FCREG"] == 3
        @test facts["MNAME"] == "            "
        @test facts["NREG"] == 0
    end

    @testset "switched shunt: v33 layout plus trailing NREG" begin
        shunts = Dict(s["I"] => s for s in pti["SWITCHED SHUNT"])
        @test !haskey(shunts[3], "ID")
        @test !haskey(shunts[3], "S1")
        @test shunts[3]["SWREM"] == 3
        @test shunts[3]["N1"] == 2
        @test shunts[3]["B1"] == 10.0
        @test shunts[3]["N2"] == 0  # truncated row, defaulted
        @test shunts[3]["NREG"] == 0
        @test shunts[2]["NREG"] == 7
        @test shunts[2]["B2"] == 250.0
    end

    @testset "impedance correction: one row per table, complex triples" begin
        tables = pti["IMPEDANCE CORRECTION"]
        @test length(tables) == 1
        @test all(haskey(t, "I") for t in tables)
        t = only(tables)
        @test t["T7"] == 1.3
        @test t["Re(F7)"] == 1.2
        @test t["Im(F1)"] == 0.0
    end
end

@testset "PSSE v34 stage 2: PowerModels dict" begin
    pm = PowerModelsData(V34_FULL_FIXTURE).data

    @test pm["source_version"] == "34"
    @test length(pm["bus"]) == 9  # 8 buses + one 3W star bus
    @test length(pm["branch"]) == 3  # two lines + one 2W transformer
    @test length(pm["3w_transformer"]) == 1
    @test length(pm["gen"]) == 4
    @test length(pm["load"]) == 4
    @test length(pm["breaker"]) == 1

    gen1 = only(g for g in values(pm["gen"]) if g["gen_bus"] == 1)
    @test gen1["ext"]["NREG"] == 5
    @test !haskey(gen1["ext"], "BASLOD")

    load3 = only(l for l in values(pm["load"]) if l["load_bus"] == 3)
    @test load3["ext"]["LOADTYPE"] == ""
    dgen = only(values(pm["distributed_generation"]))
    @test dgen["bus"] == 3
    @test dgen["pg"] ≈ 0.03333 atol = 1e-6

    # branch 2-3 spans 200 kV to 138 kV and is reclassified as a transformer too, so
    # select the declared one by its winding-1 bus
    xf = only(b for b in values(pm["branch"]) if b["f_bus"] == 201)
    @test xf["transformer"]
    @test xf["rate_a"] ≈ 0.4  # RATE1-1 = 40 MVA on the 100 MVA base

    dc = only(values(pm["dcline"]))
    @test dc["ext"] == Dict{String, Any}("NDR" => 4, "NDI" => 6)
    @test !occursin("\"", dc["source_id"][end])

    vsc = only(values(pm["vscline"]))
    @test vsc["ext"]["RMPCT_FROM"] == 75.0
    @test vsc["ext"]["NREG_FROM"] == 8
    @test vsc["ext"]["NREG_TO"] == 0

    facts = only(values(pm["facts"]))
    @test facts["regulated_bus_number"] == 3
    @test facts["ext"]["NREG"] == 0
    @test facts["ext"]["MNAME"] == "            "
    @test !occursin("\"", facts["name"])

    shunts = Dict(s["shunt_bus"] => s for s in values(pm["switched_shunt"]))
    @test !haskey(shunts[3], "sw_id")
    @test shunts[3]["number_engaged"] == zeros(Int, length(shunts[3]["y_increment"]))
    @test shunts[3]["ext"]["NREG"] == 0
    @test shunts[2]["ext"]["NREG"] == 7
    @test shunts[2]["regulated_bus_number"] == 2

    ic = only(values(pm["impedance_correction"]))
    @test ic["table_number"] == 1
    @test ic["tap_or_angle"] == [0.9, 1.0, 1.1, 1.15, 1.2, 1.25, 1.3]
    @test ic["scaling_factor"] == [1.05, 1.0, 1.05, 1.08, 1.12, 1.16, 1.2]
end

@testset "PSSE v34 substation: switched-shunt terminal without ID" begin
    pti = PowerFlowFileParser._parse_pti_data(
        IOBuffer(read(V34_SUBSTATION_FIXTURE, String)),
    )
    terminals = pti["SUBSTATION DATA"][1]["TERMINALS"]
    shunt_terminal = only(t for t in terminals if t["TYP"] == "S")
    @test shunt_terminal["I"] == 1
    @test shunt_terminal["NI"] == 3
    @test shunt_terminal["ID"] == "1"
    # the same three-field record is malformed in a v35 file
    @test_throws DataFormatError PowerFlowFileParser._parse_substation_terminal(
        ["1", "3", "'S'"], 1, 35,
    )

    pm = PowerModelsData(V34_SUBSTATION_FIXTURE).data
    @test pm["source_version"] == "34"
    @test length(pm["substation"]) == 2
end

@testset "PSSE version detection reads REV, not the @! marker" begin
    header_v31 = "@!IC,SBASE,REV\n0,100.0,31 / PSS(tm)E-31\nTITLE\nTITLE\n0 / END OF SYSTEM-WIDE DATA\nQ\n"
    @test_throws DataFormatError PowerFlowFileParser._parse_pti_data(IOBuffer(header_v31))
    @test PowerFlowFileParser._resolve_pti_version(
        ["@!IC", "0, 100.0, 34, 0, 1, 60.0"],
        2,
    ) == 34
    @test PowerFlowFileParser._resolve_pti_version(["0, 100.0, 33"], 1) == 33
    @test PowerFlowFileParser._resolve_pti_version(["0, 100.0"], 1) == 30
end

@testset "quoted strings lose either quote style, keep padding" begin
    strip_pair = PowerFlowFileParser._strip_quote_pair
    @test strip_pair("'BUS1        '") == "BUS1        "
    @test strip_pair("\"DC     51_1 \"") == "DC     51_1 "
    @test strip_pair("BARE") == "BARE"
    @test strip_pair("'") == "'"
    @test strip_pair("\"mismatch'") == "\"mismatch'"
end

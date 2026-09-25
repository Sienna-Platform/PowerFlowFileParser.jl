@testset "PSSE v30 parsing" begin
    pm = PowerModelsData(joinpath(PSSE_RAW_DIR, "synthetic_data_v30.raw"))

    @test pm.data["source_version"] == "30"
    @test pm.data["baseMVA"] == 100.0

    @test haskey(pm.data["bus"], 111)
    @test haskey(pm.data["bus"], 112)
    @test haskey(pm.data["bus"], 113)
    @test pm.data["bus"][111]["base_kv"] == 69.0
    @test isapprox(pm.data["bus"][111]["vm"], 1.09814; atol = 1e-5)

    @test length(pm.data["gen"]) == 3
    @test length(pm.data["load"]) == 2
    # 3 lines + 1 two-winding transformer are all stored under "branch"
    @test length(pm.data["branch"]) == 4
    @test length(pm.data["3w_transformer"]) == 1

    # branch 111-112 series impedance from the raw file
    b = first(
        v for v in values(pm.data["branch"])
        if Set((v["f_bus"], v["t_bus"])) == Set((111, 112)) && !v["transformer"]
    )
    @test isapprox(b["br_r"], 0.001870; atol = 1e-6)
    @test isapprox(b["br_x"], 0.004420; atol = 1e-6)

    for (_, g) in pm.data["gen"]
        @test haskey(g, "ext")
    end
end

@testset "PSSE v30 bus shunt" begin
    pm = PowerModelsData(joinpath(@__DIR__, "fixtures", "v30_bus_shunt.raw"))
    shunts = [s for (_, s) in pm.data["shunt"] if s["shunt_bus"] == 111]
    @test length(shunts) == 1
    # buses 112 and 113 carry zero GL/BL and must not produce shunts
    @test length(pm.data["shunt"]) == 1
    # gs/bs come out in system per-unit (raw GL=10.0, BL=5.0 at baseMVA=100.0),
    # matching the FIXED SHUNT conversion applied by make_per_unit!
    @test isapprox(shunts[1]["gs"], 0.1; atol = 1e-6)
    @test isapprox(shunts[1]["bs"], 0.05; atol = 1e-6)
end

@testset "Unsupported PSSE version errors clearly" begin
    @test_throws IS.DataFormatError PowerModelsData(
        joinpath(@__DIR__, "fixtures", "v31_header.raw"),
    )
    # a @! column comment does not make a file v35; REV still decides
    with_marker =
        "@!IC,SBASE,REV\n" * read(joinpath(@__DIR__, "fixtures", "v31_header.raw"), String)
    @test_throws IS.DataFormatError PowerFlowFileParser._parse_pti_data(
        IOBuffer(with_marker),
    )
end

@testset "v30 multi-terminal DC NDCLN layout" begin
    fields = first.(PowerFlowFileParser._pti_dtypes_v30["MULTI-TERMINAL DC NDCLN"])
    @test fields == ["IDC", "JDC", "DCCKT", "RDC", "LDC"]
    @test !("MET" in fields)
end

@testset "v30 real system component counts" begin
    expected = Dict(
        "11BUS_KUNDUR_30.raw" =>
            (bus = 11, load = 2, gen = 4, line = 8, xf2 = 4, xf3 = 0),
        "RTS_30.raw" =>
            (bus = 73, load = 51, gen = 160, line = 105, xf2 = 15, xf3 = 0),
    )
    for (file, e) in expected
        pm = PowerModelsData(joinpath(PSSE_RAW_DIR, file)).data
        @test pm["source_version"] == "30"
        @test length(pm["bus"]) == e.bus
        @test length(pm["load"]) == e.load
        @test length(pm["gen"]) == e.gen
        @test count(v -> !v["transformer"], values(pm["branch"])) == e.line
        @test count(v -> v["transformer"], values(pm["branch"])) == e.xf2
        @test length(get(pm, "3w_transformer", Dict())) == e.xf3
    end
end

@testset "free-format field tokenizer" begin
    sf = PowerFlowFileParser._split_fields
    # blank-delimited
    @test sf("0    100.00") == ["0", "100.00"]
    # comma-delimited with padding absorbed
    @test sf("0,   100.00, 33") == ["0", "100.00", "33"]
    # blank-delimited with a single-quoted name containing interior blanks
    @test sf("1 'ADK     ' 138.00") == ["1", "'ADK     '", "138.00"]
    # double-quoted name with interior blanks must not be split
    @test sf("\"LINE       1\",1,20.0") == ["\"LINE       1\"", "1", "20.0"]
    # consecutive commas mark a skipped field
    @test sf("1002,,  345.0") == ["1002", "", "345.0"]
end

@testset "quoted-zero section terminator" begin
    p(s) = PowerFlowFileParser._parse_pti_data(IOBuffer(s))
    header = "0, 100.0, 33 / t\ncomment1\ncomment2\n"
    bus = "1,'BUS1',138.0,3,1,1,1,1.0,0.0,1.1,0.9,1.1,0.9\n0 / end bus\n"
    fixed_shunt = "0 / end fixed shunt\n"
    gen = "1,'1',0.0,0.0,100.0,-100.0,1.0\n0 / end gen\n"
    # an empty section terminated by a quoted zero must behave like a bare zero
    bare = p(header * bus * "0 / end load\n" * fixed_shunt * gen)
    quoted = p(header * bus * "'0' / end load\n" * fixed_shunt * gen)
    @test haskey(quoted, "GENERATOR")
    @test quoted["GENERATOR"][1]["I"] == 1
    @test quoted["GENERATOR"] == bare["GENERATOR"]
    @test get(quoted, "LOAD", []) == get(bare, "LOAD", [])
end

@testset "version detection over delimiter styles" begin
    rv = PowerFlowFileParser._resolve_pti_version
    # REV must be read from both comma- and whitespace-delimited headers
    for delim in (", ", "  ")
        @test rv(["0$(delim)100.0$(delim)33 / c", "c1", "c2"], 1) == 33
        @test rv(["0$(delim)100.0$(delim)32 / c", "c1", "c2"], 1) == 32
    end
    # a missing REV field defaults to 30 in either style
    @test rv(["0, 100.00 / c", "c1", "c2"], 1) == 30
    @test rv(["0  100.00 / c", "c1", "c2"], 1) == 30
    # a @! column comment is skipped when locating the header and never implies v35;
    # v34 exports carry the same marker
    @test PowerFlowFileParser._find_header_line(["@!...", "0 100.0 33"]) == 2
    @test rv(["@!...", "0 100.0 33"], 2) == 33
    @test rv(["@!...", "0 100.0 34"], 2) == 34
end

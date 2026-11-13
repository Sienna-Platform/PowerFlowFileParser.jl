# Contract tests for 3W transformer emission.
# Each 3W record emits BOTH the pairwise impedances (winding-pair base,
# keys r_12/x_12, r_23/x_23, r_31/x_31, base_power_12/23/31) AND the
# delta->star equivalent legs (winding base, keys r_primary/x_primary,
# r_secondary/x_secondary, r_tertiary/x_tertiary). Star legs are computed
# on the system base, zero reactances are floored to
# ZERO_IMPEDANCE_REACTANCE_THRESHOLD there, then converted to the winding
# base. Characterization values below were captured from the reference
# parser pipeline and must not drift.

const STAR_LEG_KEYS =
    ("r_primary", "x_primary", "r_secondary", "x_secondary", "r_tertiary", "x_tertiary")

const PAIRWISE_3W_KEYS = (
    "r_12", "x_12", "r_23", "x_23", "r_31", "x_31",
    "base_power_12", "base_power_23", "base_power_31",
    "base_voltage_primary", "base_voltage_secondary", "base_voltage_tertiary",
    "primary_turns_ratio", "secondary_turns_ratio", "tertiary_turns_ratio",
    "rating_primary", "rating_secondary", "rating_tertiary",
    "available", "available_primary", "available_secondary", "available_tertiary",
    "g", "b", "star_bus", "COD1", "COD2", "COD3", "ext",
)

@testset "3W transformer emission: pairwise + star-leg contract (mixed case)" begin
    d = PowerFlowFileParser.parse_file(joinpath(PSSE_RAW_DIR, "case14_with_pst3w.raw"))
    @test haskey(d, "3w_transformer")
    @test length(d["3w_transformer"]) == 2
    for (_, t) in d["3w_transformer"]
        for k in STAR_LEG_KEYS
            @test haskey(t, k)
        end
        for k in PAIRWISE_3W_KEYS
            @test haskey(t, k)
        end
    end
    # characterization: exact values captured pre-refactor from "TRAFO 3W 2" (record "1")
    t = d["3w_transformer"]["1"]
    @test t["r_12"] ≈ 0.0 atol = 1e-12
    @test t["x_12"] ≈ 0.0002 atol = 1e-12
    @test t["x_23"] ≈ 0.0002 atol = 1e-12
    @test t["x_31"] ≈ 0.0002 atol = 1e-12
    @test t["base_power_12"] == 100.0
    @test t["g"] ≈ 0.0 atol = 1e-12
    # star legs: all pairs r=0, x=2e-4 on the system base (SBASE=baseMVA=100),
    # so each leg is 1/2 * (2e-4 - 2e-4 + 2e-4) = 1e-4
    for k in ("r_primary", "r_secondary", "r_tertiary")
        @test t[k] ≈ 0.0 atol = 1e-12
    end
    for k in ("x_primary", "x_secondary", "x_tertiary")
        @test t[k] ≈ 1e-4 atol = 1e-12
    end
    # star bus exists as a real hidden bus
    star = d["bus"][t["star_bus"]]
    @test star["hidden"] == true
end

@testset "2W transformer emission unchanged" begin
    d = PowerFlowFileParser.parse_file(joinpath(PSSE_RAW_DIR, "case14_with_pst3w.raw"))
    two_w = [b for (_, b) in d["branch"] if get(b, "transformer", false)]
    @test length(two_w) == 3
    # "TRAFO 2W 3", the 50-degree phase shifter. A second transformer,
    # "TRAFO 2W 2", carries an independent -60-degree shift, so selecting by
    # shift != 0.0 would be ambiguous; select by the record's own PSSE name
    # (stored in ext with trailing padding) instead of a fragile dict key.
    pst = only(
        b for (_, b) in d["branch"] if
        get(b, "transformer", false) &&
        strip(get(get(b, "ext", Dict()), "psse_name", "")) == "TRAFO 2W 3"
    )
    @test pst["shift"] ≈ 0.8726646259971648 atol = 1e-12    # 50 degrees, in radians
    @test pst["br_x"] ≈ 0.0001 atol = 1e-12
end

@testset "3W transformer emission: pairwise + star-leg contract (pure 3W case)" begin
    d = PowerFlowFileParser.parse_file(joinpath(PSSE_RAW_DIR, "case6_3w.raw"))
    @test haskey(d, "3w_transformer")
    @test length(d["3w_transformer"]) == 1
    for (_, t) in d["3w_transformer"]
        for k in STAR_LEG_KEYS
            @test haskey(t, k)
        end
        for k in PAIRWISE_3W_KEYS
            @test haskey(t, k)
        end
    end
    t = d["3w_transformer"]["1"]
    @test t["r_12"] ≈ 0.0 atol = 1e-12
    @test t["x_12"] ≈ 0.0002 atol = 1e-12
    @test t["x_23"] ≈ 0.0002 atol = 1e-12
    @test t["x_31"] ≈ 0.0002 atol = 1e-12
    @test t["base_power_12"] == 100.0
    @test t["g"] ≈ 0.0 atol = 1e-12
    # same impedance pattern as the mixed case: each star leg x = 1e-4, r = 0
    for k in ("r_primary", "r_secondary", "r_tertiary")
        @test t[k] ≈ 0.0 atol = 1e-12
    end
    for k in ("x_primary", "x_secondary", "x_tertiary")
        @test t[k] ≈ 1e-4 atol = 1e-12
    end
    star = d["bus"][t["star_bus"]]
    @test star["hidden"] == true
end

@testset "3W transformer star legs: zero-impedance flooring (CZ=2)" begin
    d = PowerFlowFileParser.parse_file(
        joinpath(PSSE_RAW_DIR, "case4_zero_impedance_3wt.raw"),
    )
    @test length(d["3w_transformer"]) == 1
    t = d["3w_transformer"]["1"]
    # CZ=2: pairwise values pass through on the winding-pair base (15 MVA)
    @test t["base_power_12"] == 15.0
    @test t["base_power_23"] == 15.0
    @test t["base_power_31"] == 15.0
    @test t["r_12"] ≈ 5.0e-3 atol = 1e-12
    @test t["x_12"] ≈ 5.0e-2 atol = 1e-12
    @test t["r_23"] ≈ 3.0e-3 atol = 1e-12
    @test t["x_23"] ≈ 3.1e-2 atol = 1e-12
    @test t["r_31"] ≈ 5.0e-3 atol = 1e-12
    @test t["x_31"] ≈ 1.9e-2 atol = 1e-12
    # Star legs, derived on the system base (x pairwise * 100/15), e.g.
    # x_p = 1/2 * (100/15) * (5.0e-2 - 3.1e-2 + 1.9e-2), then re-converted
    # to the 15 MVA winding base (* 15/100):
    @test t["r_primary"] ≈ 3.5e-3 atol = 1e-12
    @test t["x_primary"] ≈ 1.9e-2 atol = 1e-12
    @test t["r_secondary"] ≈ 1.5e-3 atol = 1e-12
    @test t["x_secondary"] ≈ 3.1e-2 atol = 1e-12
    @test t["r_tertiary"] ≈ 1.5e-3 atol = 1e-12
    # tertiary x cancels exactly: 1/2 * (1.9e-2 - 5.0e-2 + 3.1e-2) = 0, so it
    # is floored to 1e-4 on the SYSTEM base and only then converted to the
    # winding base: 1e-4 * 15/100 = 1.5e-5
    @test t["x_tertiary"] ≈ 1.5e-5 atol = 1e-12
end

const CONTROL_KEYS_2W = ("COD1", "CONT1", "RMA1", "RMI1", "VMA1", "VMI1", "NTP1")
const CONTROL_KEYS_3W = Tuple(
    "$(f)$(w)" for w in 1:3 for f in ("COD", "CONT", "RMA", "RMI", "VMA", "VMI", "NTP")
)

@testset "transformer control block is first-class" begin
    d = PowerFlowFileParser.parse_file(joinpath(PSSE_RAW_DIR, "case14_with_pst3w.raw"))
    for (_, b) in d["branch"]
        get(b, "transformer", false) || continue
        for k in CONTROL_KEYS_2W
            @test haskey(b, k)
        end
    end
    for (_, t) in d["3w_transformer"]
        for k in CONTROL_KEYS_3W
            @test haskey(t, k)
        end
    end
    # value spot-checks read directly from the "TRAFO 2W 3" raw record (v33
    # template: WINDV1,NOMV1,ANG1,RATA1,RATB1,RATC1,COD1,CONT1,RMA1,RMI1,VMA1,
    # VMI1,NTP1,TAB1,CR1,CX1,CNXA1):
    #   0.95000, 0.000, 50.000, 0.00, 0.00, 0.00, 0, 0, 1.10000, 0.90000, 1.10000, 0.90000, 33, 1, ...
    pst = only(
        b for (_, b) in d["branch"] if
        get(b, "transformer", false) &&
        strip(get(get(b, "ext", Dict()), "psse_name", "")) == "TRAFO 2W 3"
    )
    @test pst["NTP1"] == 33.0
    @test pst["RMA1"] == 1.1
    @test pst["CONT1"] == 0

    # "TRAFO 3W 2" (record "1") winding lines, same field order per winding:
    #   W1: 1.00000, 0.000, -30.000, 0.00, 0.00, 0.00, 0, 0, 1.10000, 0.90000, 1.10000, 0.90000, 33, 4, ...
    #   W2: 1.00000, 0.000, 150.000, 0.00, 0.00, 0.00, 0, 0, 1.10000, 0.90000, 1.10000, 0.90000, 33, 5, ...
    t = d["3w_transformer"]["1"]
    @test t["NTP1"] == 33.0
    @test t["RMA1"] == 1.1
    @test t["CONT1"] == 0
    @test t["NTP2"] == 33.0
end

@testset "transformer control block is first-class (v35)" begin
    # v35 regression: the ext-only TRANSFORMER3W_PARAMETER_NAMES loop in psse.jl
    # skips source_version 35 entirely; first-class emission must not.
    d = PowerFlowFileParser.parse_file(joinpath(PSSE_RAW_DIR, "case25_v35_savnwb.raw"))
    @test d["source_version"] == "35"
    two_w = [b for (_, b) in d["branch"] if get(b, "transformer", false)]
    @test !isempty(two_w)
    for b in two_w
        for k in CONTROL_KEYS_2W
            @test haskey(b, k)
        end
    end
    @test haskey(d, "3w_transformer")
    @test !isempty(d["3w_transformer"])
    for (_, t) in d["3w_transformer"]
        for k in CONTROL_KEYS_3W
            @test haskey(t, k)
        end
    end
    # spot-check against the raw "TR3W FOR TESTING V35 EXPORTER." record
    # (I=110, J=211, K=222), winding-1 line:
    #   0.99884,138.000,0.000,...,1,110,0,1.10020,0.92000,1.16000,0.93000,33,3,...
    t3w = only(
        t for (_, t) in d["3w_transformer"] if
        strip(get(get(t, "ext", Dict()), "psse_name", "")) ==
        "TR3W FOR TESTING V35 EXPORTER.         Z"
    )
    @test t3w["NTP1"] == 33.0
    @test t3w["RMA1"] == 1.1002
    @test t3w["CONT1"] == 110
end

@testset "3W winding ratings map to rating/rating_b/rating_c, and zero means unset" begin
    for (file, rate_keys) in (
        ("frankenstein_70.raw", i -> ("RATA$i", "RATB$i", "RATC$i")),
        ("case25_v35_savnwb.raw", i -> ("RATE$(i)1", "RATE$(i)2", "RATE$(i)3")),
    )
        path = joinpath(PSSE_RAW_DIR, file)
        raw = only(
            t for t in open(PowerFlowFileParser._parse_pti_data, path)["TRANSFORMER"]
            if t["K"] != 0
        )
        d = only(values(PowerFlowFileParser.parse_file(path)["3w_transformer"]))
        for (i, winding) in PowerFlowFileParser.WINDING_NAMES
            rate_a, rate_b, rate_c = (raw[k] for k in rate_keys(i))
            @test d["rating_$winding"] == rate_a
            @test get(d, "rating_b_$winding", 0.0) == rate_b
            @test get(d, "rating_c_$winding", 0.0) == rate_c
        end
    end

    # Twelve-rating versions keep ratings 4-12 in ext, as lines and 2W transformers do.
    path = joinpath(PSSE_RAW_DIR, "case25_v35_savnwb.raw")
    raw = only(
        t for t in open(PowerFlowFileParser._parse_pti_data, path)["TRANSFORMER"]
        if t["K"] != 0
    )
    ext = only(values(PowerFlowFileParser.parse_file(path)["3w_transformer"]))["ext"]
    for winding in 1:3, rating in 4:12
        key = "RATE$winding$rating"
        @test ext[key] == raw[key]
    end

    # (rating, rating_b, rating_c) on each winding's own circuit.
    function winding_ratings(file)
        pm = PowerFlowFileParser.PowerModelsData(joinpath(PSSE_RAW_DIR, file))
        sys = PowerFlowFileParser.build_openapi_system(pm; power_units = "NATURAL_UNITS")
        circuits = Dict(
            PowerFlowFileParser.get_value(c, :id) => c for
            c in PowerFlowFileParser.get_components(sys, "TransformerCircuit")
        )
        transformer = only(
            PowerFlowFileParser.get_components(sys, "ThreeWindingTransformer"),
        )
        return [
            [
                PowerFlowFileParser.get_value(
                    circuits[PowerFlowFileParser.get_value(transformer, winding)],
                    field,
                ) for field in (:rating, :rating_b, :rating_c)
            ] for winding in (:primary_circuit, :secondary_circuit, :tertiary_circuit)
        ]
    end

    # RATCn = 0 stays unset and must not erase the RATAn and RATBn limits.
    absent = PowerFlowFileParser.ABSENT
    @test winding_ratings("frankenstein_70.raw") ==
          [[336.0, 336.0, absent], [268.0, 268.0, absent], [84.0, 84.0, absent]]
    # Every rating here is distinct, so a swapped rating or winding can't pass.
    @test winding_ratings("case25_v35_savnwb.raw") == [
        [1200.0, 1202.12, 1203.13],
        [1250.0, 1252.12, 1253.13],
        [1280.0, 1282.12, 1283.13],
    ]
end

@testset "blank WINDVn defaults to its own winding's bus base voltage when CW=2" begin
    function default_windings(cw)
        transformer = Dict{String, Any}(
            "I" => 1, "J" => 2, "K" => 3, "CW" => cw,
            "WINDV1" => nothing, "WINDV2" => nothing, "WINDV3" => nothing,
        )
        PowerFlowFileParser._correct_nothing_values!(
            Dict{String, Any}(
                "CASE IDENTIFICATION" => [Dict{String, Any}("SBASE" => 100.0)],
                "BUS" => [
                    Dict{String, Any}("I" => 1, "BASKV" => 345.0),
                    Dict{String, Any}("I" => 2, "BASKV" => 138.0),
                    Dict{String, Any}("I" => 3, "BASKV" => 13.8),
                ],
                "TRANSFORMER" => [transformer],
            ),
        )
        return [transformer["WINDV$n"] for n in 1:3]
    end
    @test default_windings(2) == [345.0, 138.0, 13.8]
    @test default_windings(1) == [1.0, 1.0, 1.0]
    @test default_windings(3) == [1.0, 1.0, 1.0]
end

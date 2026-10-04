using Test
using Logging
using PowerFlowFileParser

const PFFP = PowerFlowFileParser

function mon_pm()
    pm = PFFP.PowerModelsData(joinpath(@__DIR__, "modified_14bus_system.raw")).data
    for n in (106, 200, 201, 401, 501)
        pm["bus"][n]["area"] = 2
    end
    pm["bus"][110]["zone"] = 7
    return pm
end

mon_file(body::String, ext::String) = (path = tempname() * ext; write(path, body); path)

const SUB_BODY = """
/ subsystems
SUBSYSTEM 'AREA2'
    AREA 2
END
SUBSYSTEM HV
    JOIN
        AREA 2
        KVRANGE 400.0 600.0
    END
END
SUBSYSTEM UNI
    AREA 2
    BUS 101
END
SUBSYSTEM PICK
    BUS 101 102
END
SUBSYSTEM Z
    ZONE 7
END
END
"""

function run_monitored(pm, mon::String; sub::String = "")
    mon_path = mon_file(mon, ".mon")
    sub_path = ""
    if !isempty(sub)
        sub_path = mon_file(sub, ".sub")
    end
    logger = Test.TestLogger(; min_level = Logging.Warn)
    with_logger(logger) do
        PFFP.add_monitored!(pm, mon_path; sub_path = sub_path)
    end
    return pm["monitor"], [l.message for l in logger.logs]
end

bkeys(m) = sort([k for (_, k) in m["branches"]])

has_warn(msgs, pats...) = any(m -> all(p -> occursin(p, m), pats), msgs)

@testset "PSS/E .mon and .sub" begin
    @testset "ALL BRANCHES" begin
        pm = mon_pm()
        m, msgs = run_monitored(pm, "MONITOR ALL BRANCHES\nEND\n")
        all_pairs = Set(
            [s, String(k)] for s in ("branch", "switch", "breaker", "3w_transformer")
            for
            k in keys(get(pm, s, Dict()))
        )
        @test Set(m["branches"]) == all_pairs
        @test length(m["branches"]) == length(unique(m["branches"]))
        @test Set(first.(m["branches"])) ==
              Set(["branch", "switch", "breaker", "3w_transformer"])
        @test isempty(m["buses"])
        @test m["voltage_band"] == (-Inf, Inf)
        @test isempty(msgs)
    end

    @testset "pairs are unique and in first-seen order" begin
        pm = mon_pm()
        m, _ = run_monitored(
            pm,
            "MONITOR BRANCHES IN SUBSYSTEM PICK\nMONITOR ALL BRANCHES\n";
            sub = SUB_BODY,
        )
        @test m["branches"][1] == ["branch", "1"]
        @test ["switch", "1"] in m["branches"]
        @test count(==(["branch", "1"]), m["branches"]) == 1
        @test length(unique(m["branches"])) == length(m["branches"])
    end

    @testset "IN and TIES by AREA" begin
        m, msgs = run_monitored(
            mon_pm(),
            "COM x\nMONITOR BRANCHES IN SUBSYSTEM AREA2\n";
            sub = SUB_BODY,
        )
        @test bkeys(m) == ["18", "19"]
        @test isempty(msgs)
        m, _ = run_monitored(
            mon_pm(),
            "MONITOR TIES FROM SUBSYSTEM AREA2\n";
            sub = SUB_BODY,
        )
        @test Set(bkeys(m)) ⊇ Set(["11", "12", "15", "16"])
        @test !("18" in bkeys(m)) && !("19" in bkeys(m))
    end

    @testset "BUS and out-of-service" begin
        m, _ = run_monitored(
            mon_pm(),
            "MONITOR TIES FROM SUBSYSTEM PICK\n";
            sub = SUB_BODY,
        )
        @test bkeys(m) == ["2", "3", "4", "5"]
        m, _ = run_monitored(
            mon_pm(),
            "MONITOR BRANCHES IN SUBSYSTEM PICK\n";
            sub = SUB_BODY,
        )
        @test m["branches"] == [["branch", "1"]]
        pm = mon_pm()
        pm["branch"]["1"]["br_status"] = 0
        m, _ = run_monitored(pm, "MONITOR BRANCHES IN SUBSYSTEM PICK\n"; sub = SUB_BODY)
        @test isempty(m["branches"])
    end

    @testset "endpoints are RAW buses, not star buses" begin
        pm = mon_pm()
        pm["bus"][1001]["area"] = 2
        m, _ = run_monitored(pm, "MONITOR BRANCHES IN SUBSYSTEM AREA2\n"; sub = SUB_BODY)
        @test bkeys(m) == ["18", "19"]
        sub = "SUBSYSTEM T\n BUS 109 104 107\nEND\n"
        m, _ = run_monitored(pm, "MONITOR BRANCHES IN SUBSYSTEM T\n"; sub = sub)
        @test ["3w_transformer", "1"] in m["branches"]
    end

    @testset "JOIN intersects, plain block unions" begin
        m, _ = run_monitored(
            mon_pm(),
            "MONITOR VOLTAGE RANGE SUBSYSTEM HV 0.900 1.050\n";
            sub = SUB_BODY,
        )
        @test sort(m["buses"]) == [200, 201, 401, 501]
        @test m["voltage_band"] == (0.9, 1.05)
        m, _ = run_monitored(
            mon_pm(),
            "MONITOR VOLTAGE RANGE SUBSYSTEM UNI 0.9 1.1\n";
            sub = SUB_BODY,
        )
        @test sort(m["buses"]) == [101, 106, 200, 201, 401, 501]
    end

    @testset "KVRANGE and ZONE" begin
        sub = "SUBSYSTEM K\n KVRANGE 60 70\nEND\nSUBSYSTEM Z\n ZONE 7\nEND\n"
        m, _ = run_monitored(
            mon_pm(),
            "MONITOR VOLTAGE RANGE SUBSYSTEM K 0.9 1.1\nMONITOR VOLTAGE RANGE SUBSYSTEM Z 0.9 1.1\n";
            sub = sub,
        )
        @test sort(m["buses"]) == [107, 108, 110]
    end

    @testset "bad records warn and are skipped" begin
        mon = """
        MONITOR BRANCHES IN SUBSYSTEM NOPE
        MONITOR INTERFACE FLOWS
        MONITOR VOLTAGE RANGE SUBSYSTEM PICK 0.9 1.05
        MONITOR VOLTAGE RANGE SUBSYSTEM AREA2 0.95 1.05
        MONITOR TIES FROM SUBSYSTEM PICK
        END
        """
        m, msgs = run_monitored(mon_pm(), mon; sub = SUB_BODY)
        @test has_warn(msgs, "NOPE", "line 1")
        @test has_warn(msgs, "MONITOR INTERFACE FLOWS", "line 2")
        @test has_warn(msgs, "differs", "line 4")
        @test m["voltage_band"] == (0.9, 1.05)
        @test sort(m["buses"]) == [101, 102]
        @test bkeys(m) == ["2", "3", "4", "5"]

        sub = """
        SUBSYSTEM A
         AREA 9
         BUS 101 999
         ZONE 9
         OWNER 1
         WHATEVER 1
         BUS 101
        END
        SUBSYSTEM A
         BUS 102
        END
        SUBSYSTEM E
         AREA 9
        END
        SUBSYSTEM NOEND
         BUS 101
        """
        _, msgs = run_monitored(mon_pm(), "MONITOR ALL BRANCHES\n"; sub = sub)
        @test has_warn(msgs, "line 2", "AREA 9")
        @test has_warn(msgs, "line 3", "999")
        @test has_warn(msgs, "line 4", "ZONE 9")
        @test has_warn(msgs, "line 5", "OWNER 1")
        @test has_warn(msgs, "line 6", "WHATEVER")
        @test has_warn(msgs, "line 9", "duplicate subsystem A")
        @test has_warn(msgs, "SUBSYSTEM E", "selects no buses")
        @test has_warn(msgs, "NOEND", "no END")
        m, msgs = run_monitored(
            mon_pm(),
            "MONITOR BRANCHES IN SUBSYSTEM A\nMONITOR BRANCHES IN SUBSYSTEM NOEND\nMONITOR BRANCHES IN SUBSYSTEM E\n";
            sub = sub,
        )
        @test isempty(m["branches"])
        @test count(m -> occursin("not defined", m), msgs) == 2
    end

    @testset "unreadable file throws" begin
        @test_throws SystemError PFFP.add_monitored!(mon_pm(), "/nonexistent/x.mon")
    end
end

@testset "mon_file and sub_file kwargs on PowerModelsData" begin
    raw = joinpath(@__DIR__, "modified_14bus_system.raw")
    mon = mon_file("MONITOR ALL BRANCHES\nEND\n", ".mon")
    sub = mon_file(SUB_BODY, ".sub")
    plain = PFFP.PowerModelsData(raw).data
    @test !haskey(plain, "monitor")
    @test !haskey(plain, "contingency")
    pm = PFFP.PowerModelsData(raw; mon_file = mon, sub_file = sub).data
    @test !isempty(pm["monitor"]["branches"])
    @test !haskey(pm, "contingency")
    pm = PFFP.parse_file(raw; mon_file = mon)
    @test !isempty(pm["monitor"]["branches"])
end

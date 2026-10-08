using Test
using Logging
using PowerFlowFileParser

const PFFP = PowerFlowFileParser

function con_fixture(body::Union{String, Vector{UInt8}})
    path = tempname() * ".con"
    write(path, body)
    return path
end

function read_con_quiet(body)
    path = con_fixture(body)
    result = with_logger(NullLogger()) do
        PFFP._read_con(path)
    end
    return result..., path
end

one_action(line::String) = read_con_quiet("CONTINGENCY 'A'\n$line\nEND\nEND\n")

@testset "PSS/E .con record parser" begin
    @testset "forms" begin
        cases = [
            ("OPEN BRANCH FROM BUS 1 TO BUS 2 CKT 3", :open_branch, [1, 2], "3"),
            ("TRIP BRANCH FROM BUS 1 TO BUS 2 CIRCUIT 'a1'", :open_branch, [1, 2], "a1"),
            ("open branch from bus 1 to bus 2 ckt c4", :open_branch, [1, 2], "C4"),
            ("OPEN BRANCH FROM BUS 1 TO BUS 2 CKT '&1'", :open_branch, [1, 2], "&1"),
            ("OPEN BRANCH FROM BUS 1 TO BUS 2", :open_branch, [1, 2], "1"),
            (
                "OPEN BRANCH FROM BUS 1 TO BUS 2 TO BUS 3 CKT 2",
                :open_branch,
                [1, 2, 3],
                "2",
            ),
            ("TRIP BRANCH FROM BUS 1 TO BUS 2 TO BUS 3", :open_branch, [1, 2, 3], "1"),
            (
                "OPEN THREE WINDING TRANSFORMER FROM BUS 1 TO BUS 2 TO BUS 3 CKT 1",
                :open_3w_transformer,
                [1, 2, 3],
                "1",
            ),
            (
                "TRIP THREEWINDING FROM BUS 1 TO BUS 2 TO BUS 3 CIRCUIT 1",
                :open_3w_transformer,
                [1, 2, 3],
                "1",
            ),
            (
                "OPEN THREEWINDING FROM BUS 1 TO BUS 2 TO BUS 3 CKT 1 AT BUS 2",
                :open_3w_winding,
                [1, 2, 3, 2],
                "1",
            ),
            ("REMOVE UNIT 1 FROM BUS 5", :remove_unit, [5], "1"),
            ("REMOVE MACHINE 'g 2 ' FROM BUS 5", :remove_unit, [5], "g 2"),
            ("REMOVE LOAD 1 FROM BUS 6", :remove_load, [6], "1"),
            ("REMOVE SHUNT 1 FROM BUS 7", :remove_shunt, [7], "1"),
            ("REMOVE SWSHUNT 1 FROM BUS 8", :remove_switched_shunt, [8], "1"),
            ("REMOVE SWITCHED SHUNT 2 FROM BUS 8", :remove_switched_shunt, [8], "2"),
            ("DISCONNECT BUS 9", :open_bus, [9], ""),
            ("OPEN BUS 9", :open_bus, [9], ""),
            ("CLOSE BRANCH FROM BUS 1 TO BUS 2 CKT BP", :close_branch, [1, 2], "BP"),
            ("CLOSE BRANCH FROM BUS 1 TO BUS 2", :close_branch, [1, 2], "1"),
            ("CLOSE BRANCH FROM BUS 1 TO BUS 2 TO BUS 3", :close_branch, [1, 2, 3], "1"),
            (
                "CLOSE BRANCH FROM BUS 1 TO BUS 2 TO BUS 3 CKT 2",
                :close_branch,
                [1, 2, 3],
                "2",
            ),
        ]
        for (line, kind, buses, id) in cases
            blocks, skipped, _ = one_action(line)
            @test isempty(skipped)
            @test length(blocks) == 1
            a = only(only(blocks).actions)
            @test (a.kind, a.buses, a.id) == (kind, buses, id)
            @test a.line == 2
            @test a.text == line
        end
    end

    @testset "block fields" begin
        blocks, skipped, _ = read_con_quiet(
            "CONTINGENCY 'X Y'\nOPEN BUS 1\nOPEN BUS 2\nEND\nCONTINGENCY Z\nEND\nEND\n",
        )
        @test isempty(skipped)
        @test [(b.label, b.line, length(b.actions)) for b in blocks] ==
              [("X Y", 1, 2), ("Z", 5, 0)]
    end

    @testset "comments, COM, CRLF" begin
        body = join(
            [
                "/* header",
                "COM a remark",
                "CONTINGENCY 'A' / trailing",
                "  OPEN BUS 1 /* c",
                "",
                "END",
                "END",
            ],
            "\r\n",
        )
        blocks, skipped, _ = read_con_quiet(body)
        @test isempty(skipped)
        a = only(only(blocks).actions)
        @test a.buses == [1]
        @test a.line == 4
        @test only(blocks).label == "A"
    end

    @testset "quoted label containing '/'" begin
        blocks, skipped, _ = read_con_quiet("CONTINGENCY 'A/B C'\nOPEN BUS 1\nEND\nEND\n")
        @test isempty(skipped)
        @test only(blocks).label == "A/B C"
    end

    @testset "invalid UTF-8 in a comment" begin
        body = Vector{UInt8}(codeunits("CONTINGENCY 'A'\nOPEN BUS 1 /* "))
        append!(body, UInt8[0xe9, 0xff, 0xfe])
        append!(body, codeunits("\nEND\nEND\n"))
        @test !isvalid(String(copy(body)))
        blocks, skipped, _ = read_con_quiet(body)
        @test isempty(skipped)
        @test only(only(blocks).actions).buses == [1]
    end

    @testset "terminating END" begin
        blocks, skipped, _ = read_con_quiet("CONTINGENCY 'A'\nOPEN BUS 1\nEND\nEND\n")
        @test length(blocks) == 1 && isempty(skipped)

        blocks, skipped, path = read_con_quiet(
            "CONTINGENCY 'A'\nOPEN BUS 1\nEND\nEND\nCONTINGENCY 'B'\nOPEN BUS 2\nEND\n",
        )
        @test [b.label for b in blocks] == ["A"]
        s = only(skipped)
        @test (s.file, s.line) == (path, 5)
        @test occursin("after the terminating END", s.reason)
    end

    @testset "skips, each logged" begin
        function logged(body)
            path = con_fixture(body)
            return @test_logs (:warn, r"Skipping contingency") PFFP._read_con(path)
        end

        blocks, skipped = logged(
            "CONTINGENCY 'A'\nOPEN BUS 1\nBOGUS RECORD 3\nOPEN BUS 2\nEND\n" *
            "CONTINGENCY 'B'\nOPEN BUS 3\nEND\nEND\n",
        )
        @test [b.label for b in blocks] == ["B"]
        s = only(skipped)
        @test (s.label, s.line) == ("A", 1)
        @test occursin("BOGUS RECORD 3", s.reason)

        blocks, skipped = logged(
            "CONTINGENCY 'A'\nREMOVE SHUNT FROM BUS 5\nEND\nEND\n",
        )
        @test isempty(blocks)
        @test occursin("without an id", only(skipped).reason)

        blocks, skipped = logged(
            "CONTINGENCY 'A'\nREMOVE SWITCHED SHUNT FROM BUS 5\nEND\nEND\n",
        )
        @test isempty(blocks)
        @test occursin("without an id", only(skipped).reason)

        blocks, skipped = logged(
            "CONTINGENCY 'A'\nOPEN BUS 1\nEND\nCONTINGENCY 'A'\nOPEN BUS 2\nEND\nEND\n",
        )
        @test [(b.label, only(b.actions).buses) for b in blocks] == [("A", [1])]
        s = only(skipped)
        @test (s.label, s.line) == ("A", 4)
        @test occursin("duplicate label", s.reason)

        blocks, skipped = logged(
            "CONTINGENCY 'A'\nOPEN BUS 1\nEND\nCONTINGENCY 'B'\nOPEN BUS 2\n",
        )
        @test [b.label for b in blocks] == ["A"]
        s = only(skipped)
        @test (s.label, s.line, s.reason) == ("B", 4, "no END")

        blocks, skipped = logged("OPEN BUS 1\nCONTINGENCY 'A'\nOPEN BUS 2\nEND\nEND\n")
        @test [b.label for b in blocks] == ["A"]
        @test only(skipped).line == 1

        blocks, skipped = logged(
            "CONTINGENCY 'A'\nOPEN BUS 1\nEND\nEND\nCONTINGENCY 'B'\n",
        )
        @test [b.label for b in blocks] == ["A"]
        @test occursin("after the terminating END", only(skipped).reason)
    end

    @testset "a CONTINGENCY inside an open block ends it without END" begin
        path = con_fixture(
            "CONTINGENCY 'A'\nOPEN BUS 1\nCONTINGENCY 'B'\nOPEN BUS 2\nEND\nEND\n",
        )
        blocks, skipped = @test_logs (:warn, r"Skipping contingency") PFFP._read_con(path)
        @test [(b.label, b.line) for b in blocks] == [("B", 3)]
        s = only(skipped)
        @test (s.label, s.line, s.reason) == ("A", 1, "no END")
    end

    @testset "unquoted multi-word label skips only its block" begin
        path = con_fixture(
            "CONTINGENCY A B\nOPEN BUS 1\nEND\nCONTINGENCY 'C'\nOPEN BUS 2\nEND\nEND\n",
        )
        blocks, skipped = @test_logs (:warn, r"Skipping contingency") PFFP._read_con(path)
        @test [b.label for b in blocks] == ["C"]
        s = only(skipped)
        @test s.line == 1
        @test occursin("label", s.reason)
    end

    @testset "unreadable file throws" begin
        @test_throws SystemError PFFP._read_con(tempname() * ".con")
    end
end

const CON_MULTISECTION_RAW = """
@!IC,SBASE,REV,XFRRAT,NXFRAT,BASFRQ
0,  100.00, 35,     0,     1, 60.00
Synthetic v35 case: multi-section lines over branches and a system switching device
Line &1 runs 1-2-3-4 with a switch as its middle section; &2 names a missing segment
0 / END OF SYSTEM-WIDE DATA, BEGIN BUS DATA
     1,'BUSONE      ', 138.0000,3,   1,   1,   1,1.00000,   0.0000,1.10000,0.90000,1.10000,0.90000
     2,'BUSTWO      ', 138.0000,1,   1,   1,   1,1.00000,   0.0000,1.10000,0.90000,1.10000,0.90000
     3,'BUSTHREE    ', 138.0000,1,   1,   1,   1,1.00000,   0.0000,1.10000,0.90000,1.10000,0.90000
     4,'BUSFOUR     ', 138.0000,1,   1,   1,   1,1.00000,   0.0000,1.10000,0.90000,1.10000,0.90000
0 / END OF BUS DATA, BEGIN LOAD DATA
0 / END OF LOAD DATA, BEGIN FIXED SHUNT DATA
0 / END OF FIXED SHUNT DATA, BEGIN GENERATOR DATA
0 / END OF GENERATOR DATA, BEGIN BRANCH DATA
     1,     2,'&1', 1.00000E-02, 1.00000E-01,0.02000,'SEC_1_2                                 ', 500.00, 500.00, 500.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00, 0.00000, 0.00000, 0.00000, 0.00000,1,1,  1.00,   1,1.0000
     4,     3,'&1', 1.00000E-02, 1.00000E-01,0.02000,'SEC_4_3                                 ', 500.00, 500.00, 500.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00, 0.00000, 0.00000, 0.00000, 0.00000,1,1,  1.00,   1,1.0000
0 / END OF BRANCH DATA, BEGIN SYSTEM SWITCHING DEVICE DATA
     2,     3,'&1', 0.00010, 100.00, 110.00, 120.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00,     1,     1,     1,     3,'SW_2_3                                  '
0 / END OF SYSTEM SWITCHING DEVICE DATA, BEGIN TRANSFORMER DATA
0 / END OF TRANSFORMER DATA, BEGIN AREA DATA
0 / END OF AREA DATA, BEGIN TWO-TERMINAL DC DATA
0 / END OF TWO-TERMINAL DC DATA, BEGIN VSC DC LINE DATA
0 / END OF VSC DC LINE DATA, BEGIN IMPEDANCE CORRECTION DATA
0 / END OF IMPEDANCE CORRECTION DATA, BEGIN MULTI-TERMINAL DC DATA
0 / END OF MULTI-TERMINAL DC DATA, BEGIN MULTI-SECTION LINE DATA
     1,     4,'&1',   1,     2,     3
     1,     4,'&2',   1,     3
0 / END OF MULTI-SECTION LINE DATA, BEGIN ZONE DATA
0 / END OF ZONE DATA, BEGIN INTER-AREA TRANSFER DATA
0 / END OF INTER-AREA TRANSFER DATA, BEGIN OWNER DATA
0 / END OF OWNER DATA, BEGIN FACTS DEVICE DATA
0 / END OF FACTS DEVICE DATA, BEGIN SWITCHED SHUNT DATA
0 / END OF SWITCHED SHUNT DATA, BEGIN GNE DATA
0 / END OF GNE DATA, BEGIN INDUCTION MACHINE DATA
0 / END OF INDUCTION MACHINE DATA, BEGIN SUBSTATION DATA
0 / END OF SUBSTATION DATA
Q
"""

quiet(f) = Logging.with_logger(f, Logging.NullLogger())

function fresh_pm()
    return quiet(() -> PFFP.PowerModelsData(FOURTEEN_BUS_FIXTURE).data)
end

function multisection_pm()
    return quiet(() -> PFFP.parse_file(IOBuffer(CON_MULTISECTION_RAW); filetype = "raw"))
end

# Run add_contingencies! on a fixture file. Return the file path and the captured logs.
function add_con!(pm, body::String; name = "")
    path = con_fixture(body)
    if !isempty(name)
        named = joinpath(mktempdir(), name)
        mv(path, named)
        path = named
    end
    logger = Test.TestLogger(; min_level = Logging.Warn)
    Logging.with_logger(logger) do
        PFFP.add_contingencies!(pm, path)
    end
    return path, logger.logs
end

block(label, lines...) = "CONTINGENCY '$label'\n" * join(lines, "\n") * "\nEND\n"
con_file(blocks...) = join(blocks, "") * "END\n"

function elements_of(pm, id)
    return pm["contingency"][id]["elements"]
end

skip_reasons(pm) = [s["reason"] for s in pm["contingency_skipped"]]

@testset "PSS/E .con resolver" begin
    @testset "index has no duplicate keys on the 14-bus fixture" begin
        idx = PFFP._PsseIndex(fresh_pm())
        for d in (idx.gen, idx.load, idx.shunt, idx.switched_shunt)
            @test !isempty(d)
            @test all(isone ∘ length, values(d))
        end
        @test length(idx.gen) == 7
        @test length(idx.load) == 13
        @test length(idx.shunt) == 4
        @test length(idx.switched_shunt) == 2
    end

    @testset "branches: order, padding, case, sections" begin
        pm = fresh_pm()
        add_con!(
            pm,
            con_file(
                block("fwd", "OPEN BRANCH FROM BUS 101 TO BUS 102 CKT 1"),
                block("rev", "OPEN BRANCH FROM BUS 102 TO BUS 101 CKT '1 '"),
                block("dflt", "OPEN BRANCH FROM BUS 106 TO BUS 111"),
                block("two", "OPEN BRANCH FROM BUS 111 TO BUS 106 CKT 2"),
                block("xfmr", "OPEN BRANCH FROM BUS 104 TO BUS 109 CKT 1"),
                block("sw", "OPEN BRANCH FROM BUS 105 TO BUS 104 CKT '*1'"),
                block("brk", "OPEN BRANCH FROM BUS 113 TO BUS 112 CKT '@1'"),
            ),
        )
        @test isempty(pm["contingency_skipped"])
        e = only(elements_of(pm, "fwd"))
        @test e["action"] == "open_branch"
        @test (e["section"], e["key"]) == ("branch", "1")
        @test e["source_id"] == ["branch", 101, 102, "1 "]
        @test e["in_service"] === true
        @test e["line"] == 2
        @test only(elements_of(pm, "rev"))["key"] == "1"
        @test only(elements_of(pm, "dflt"))["source_id"] == ["branch", 106, 111, "1 "]
        @test only(elements_of(pm, "two"))["source_id"] == ["branch", 106, 111, "2 "]
        x = only(elements_of(pm, "xfmr"))
        @test (x["action"], x["section"], x["key"]) == ("open_branch", "branch", "21")
        s = only(elements_of(pm, "sw"))
        @test (s["action"], s["section"], s["key"]) == ("open_branch", "switch", "1")
        b = only(elements_of(pm, "brk"))
        @test (b["action"], b["section"], b["key"]) == ("open_branch", "breaker", "1")
    end

    @testset "three-winding transformers in any bus order" begin
        pm = fresh_pm()
        add_con!(
            pm,
            con_file(
                block("a", "OPEN BRANCH FROM BUS 107 TO BUS 109 TO BUS 104 CKT 1"),
                block("b", "OPEN THREEWINDING FROM BUS 114 TO BUS 113 TO BUS 110 CKT 1"),
                block("c", "OPEN BRANCH FROM BUS 109 TO BUS 104 TO BUS 107"),
            ),
        )
        @test isempty(pm["contingency_skipped"])
        for (id, key, sid) in (
            ("a", "1", ["transformer3w", 109, 104, 107, "1 "]),
            ("b", "2", ["transformer3w", 113, 110, 114, "1 "]),
            ("c", "1", ["transformer3w", 109, 104, 107, "1 "]),
        )
            e = only(elements_of(pm, id))
            @test (e["action"], e["section"], e["key"]) ==
                  ("open_3w_transformer", "3w_transformer", key)
            @test e["source_id"] == sid
        end
    end

    @testset "units, loads, shunts, switched shunts, buses" begin
        pm = fresh_pm()
        add_con!(
            pm,
            con_file(
                block("u", "REMOVE UNIT 2 FROM BUS 101", "REMOVE MACHINE '1' FROM BUS 102"),
                block("l", "REMOVE LOAD 2 FROM BUS 110"),
                block("sh", "REMOVE SHUNT 1 FROM BUS 111"),
                block("sw1", "REMOVE SWSHUNT 1 FROM BUS 101"),
                block("sw2", "REMOVE SWITCHED SHUNT 1 FROM BUS 113"),
                block("bus", "OPEN BUS 105", "DISCONNECT BUS 112"),
            ),
        )
        @test isempty(pm["contingency_skipped"])
        u = elements_of(pm, "u")
        @test [(e["action"], e["section"], e["key"]) for e in u] ==
              [("remove_unit", "gen", "2"), ("remove_unit", "gen", "3")]
        @test u[1]["source_id"] == ["generator", "101", "2 "]
        l = only(elements_of(pm, "l"))
        @test (l["action"], l["section"], l["key"]) == ("remove_load", "load", "9")
        sh = only(elements_of(pm, "sh"))
        @test (sh["action"], sh["section"], sh["key"]) == ("remove_shunt", "shunt", "4")
        s1 = only(elements_of(pm, "sw1"))
        @test (s1["action"], s1["section"], s1["key"]) ==
              ("remove_switched_shunt", "switched_shunt", "1")
        s2 = only(elements_of(pm, "sw2"))
        @test s2["key"] == "2"
        @test s2["source_id"] == ["switched shunt", 113, 2]
        bs = elements_of(pm, "bus")
        @test [(e["via_bus"], e["action"], e["section"], e["key"]) for e in bs] == [
            (105, "open_branch", "branch", "2"),
            (105, "open_branch", "branch", "22"),
            (105, "open_branch", "branch", "5"),
            (105, "remove_load", "load", "5"),
            (105, "open_branch", "switch", "1"),
            (112, "open_branch", "branch", "9"),
            (112, "open_branch", "breaker", "1"),
            (112, "remove_load", "load", "11"),
        ]
    end

    @testset "switched shunt id is sw_id, not the counter" begin
        pm = fresh_pm()
        pm["switched_shunt"]["2"]["sw_id"] = "b"
        add_con!(
            pm,
            con_file(
                block("hit", "REMOVE SWSHUNT B FROM BUS 113"),
                block("miss", "REMOVE SWSHUNT 2 FROM BUS 113"),
            ),
        )
        @test only(elements_of(pm, "hit"))["key"] == "2"
        @test !haskey(pm["contingency"], "miss")
        @test only(pm["contingency_skipped"])["label"] == "miss"
    end

    @testset "multi-section line: one element per segment, switch segment kept" begin
        pm = multisection_pm()
        add_con!(
            pm,
            con_file(
                block("fwd", "OPEN BRANCH FROM BUS 1 TO BUS 4 CKT '&1'"),
                block("rev", "OPEN BRANCH FROM BUS 4 TO BUS 1 CKT '&1'"),
                block("gone", "OPEN BRANCH FROM BUS 1 TO BUS 4 CKT '&2'"),
            ),
        )
        for id in ("fwd", "rev")
            es = elements_of(pm, id)
            @test [e["section"] for e in es] == ["branch", "switch", "branch"]
            @test all(e -> e["action"] == "open_branch", es)
            @test [e["source_id"] for e in es] ==
                  [["branch", 1, 2, "&1"], ["switch", 2, 3, "&1"], ["branch", 4, 3, "&1"]]
        end
        @test !haskey(pm["contingency"], "gone")
        @test [s["label"] for s in pm["contingency_skipped"]] == ["gone"]
    end

    @testset "out-of-service targets are resolved, flagged, warned" begin
        pm = fresh_pm()
        pm["gen"]["2"]["gen_status"] = 0
        pm["branch"]["3"]["br_status"] = 0
        pm["3w_transformer"]["1"]["available"] = false
        pm["load"]["9"]["status"] = 0
        pm["switch"]["1"]["state"] = 0
        _, logs = add_con!(
            pm,
            con_file(
                block("g", "REMOVE UNIT 2 FROM BUS 101"),
                block("b", "OPEN BRANCH FROM BUS 102 TO BUS 103 CKT 1"),
                block("t", "OPEN BRANCH FROM BUS 109 TO BUS 104 TO BUS 107"),
                block("l", "REMOVE LOAD 2 FROM BUS 110"),
                block("s", "OPEN BRANCH FROM BUS 104 TO BUS 105 CKT '*1'"),
                block("ok", "OPEN BRANCH FROM BUS 101 TO BUS 102 CKT 1"),
            ),
        )
        for id in ("g", "b", "t", "l", "s")
            @test only(elements_of(pm, id))["in_service"] === false
        end
        @test only(elements_of(pm, "ok"))["in_service"] === true
        @test isempty(pm["contingency_skipped"])
        flagged = filter(r -> occursin("out of service", r.message), logs)
        @test length(flagged) == 5
        @test all(r -> occursin("line", r.message), flagged)
    end

    @testset "CLOSE BRANCH" begin
        pm = fresh_pm()
        _, logs = add_con!(
            pm,
            con_file(
                block(
                    "noop",
                    "OPEN BRANCH FROM BUS 101 TO BUS 102 CKT 1",
                    "CLOSE BRANCH FROM BUS 102 TO BUS 103 CKT 1",
                ),
                block("only", "CLOSE BRANCH FROM BUS 102 TO BUS 103 CKT 1"),
            ),
        )
        @test length(elements_of(pm, "noop")) == 1
        @test elements_of(pm, "noop")[1]["action"] == "open_branch"
        @test isempty(elements_of(pm, "only"))
        @test isempty(pm["contingency_skipped"])
        @test count(r -> occursin("CLOSE BRANCH", r.message), logs) >= 2

        pm = fresh_pm()
        pm["branch"]["3"]["br_status"] = 0
        _, logs = add_con!(
            pm,
            con_file(
                block(
                    "bypass",
                    "OPEN BRANCH FROM BUS 101 TO BUS 102 CKT 1",
                    "CLOSE BRANCH FROM BUS 102 TO BUS 103 CKT 1",
                ),
                block("after", "OPEN BUS 105"),
            ),
        )
        @test !haskey(pm["contingency"], "bypass")
        @test haskey(pm["contingency"], "after")
        s = only(pm["contingency_skipped"])
        @test (s["label"], s["line"]) == ("bypass", 1)
        @test occursin("CLOSE BRANCH", s["reason"])
        @test occursin("out of service", s["reason"])
        @test any(r -> occursin("bypass", r.message) && occursin("CLOSE", r.message), logs)

        pm = fresh_pm()
        add_con!(pm, con_file(block("badclose", "CLOSE BRANCH FROM BUS 1 TO BUS 2 CKT 1")))
        @test isempty(pm["contingency"])
        @test only(pm["contingency_skipped"])["label"] == "badclose"
    end

    @testset "unresolved records skip only their block, with context" begin
        pm = fresh_pm()
        path, logs = add_con!(
            pm,
            con_file(
                block("good", "OPEN BUS 105"),
                block("nobus", "OPEN BUS 999"),
                block("nockt", "OPEN BRANCH FROM BUS 101 TO BUS 102 CKT 7"),
                block("nopair", "OPEN BRANCH FROM BUS 101 TO BUS 103 CKT 1"),
                block("nounit", "REMOVE UNIT 9 FROM BUS 101"),
                block("noload", "REMOVE LOAD 1 FROM BUS 107"),
                block("noshunt", "REMOVE SHUNT 1 FROM BUS 101"),
                block("noswshunt", "REMOVE SWSHUNT 5 FROM BUS 101"),
                block("no3w", "OPEN BRANCH FROM BUS 101 TO BUS 102 TO BUS 103 CKT 1"),
                block("mixed", "OPEN BUS 105", "OPEN BUS 999"),
                block(
                    "winding",
                    "OPEN THREEWINDING FROM BUS 1 TO BUS 2 TO BUS 3 CKT 1 AT BUS 2",
                ),
            ),
        )
        @test collect(keys(pm["contingency"])) == ["good"]
        skipped = pm["contingency_skipped"]
        @test [s["label"] for s in skipped] == [
            "nobus", "nockt", "nopair", "nounit", "noload", "noshunt", "noswshunt",
            "no3w", "mixed", "winding",
        ]
        for s in skipped
            @test Set(keys(s)) == Set(["label", "file", "line", "reason"])
            @test s["file"] == path
            @test !isempty(s["reason"])
        end
        @test skipped[1]["line"] == 4
        @test occursin("999", skipped[1]["reason"])
        @test occursin("OPEN BUS 999", skipped[1]["reason"])
        warned = filter(r -> occursin("Skipping contingency", r.message), logs)
        @test length(warned) == length(skipped)
        @test occursin("nobus", warned[1].message)
        @test occursin("$path", warned[1].message)
        @test occursin("line 4", warned[1].message)
    end

    @testset "ambiguous targets skip the block" begin
        pm = fresh_pm()
        pm["branch"]["99"] = deepcopy(pm["branch"]["1"])
        pm["gen"]["99"] = deepcopy(pm["gen"]["1"])
        add_con!(
            pm,
            con_file(
                block("br", "OPEN BRANCH FROM BUS 101 TO BUS 102 CKT 1"),
                block("g", "REMOVE UNIT 1 FROM BUS 101"),
                block("fine", "OPEN BRANCH FROM BUS 101 TO BUS 105 CKT 1"),
            ),
        )
        @test collect(keys(pm["contingency"])) == ["fine"]
        @test all(r -> occursin("ambiguous", r), skip_reasons(pm))
        @test length(pm["contingency_skipped"]) == 2
    end

    @testset "reader skips are recorded and one summary warns per file" begin
        pm = fresh_pm()
        path, logs = add_con!(
            pm,
            "CONTINGENCY 'A'\nOPEN BUS 105\nEND\nCONTINGENCY 'B'\nBOGUS 1\nEND\n" *
            "CONTINGENCY 'C'\nOPEN BUS 999\nEND\nEND\n",
        )
        @test collect(keys(pm["contingency"])) == ["A"]
        @test sort([s["label"] for s in pm["contingency_skipped"]]) == ["B", "C"]
        summary = filter(r -> occursin("summary", lowercase(r.message)), logs)
        @test length(summary) == 1
        @test occursin("3 blocks", summary[1].message)
        @test occursin("1 resolved", summary[1].message)
        @test occursin("2 skipped", summary[1].message)
    end

    @testset "entry shape" begin
        pm = fresh_pm()
        path, _ = add_con!(pm, con_file(block("A", "OPEN BUS 105")))
        c = pm["contingency"]["A"]
        @test c["source_id"] == ["contingency", "A"]
        @test (c["label"], c["file"], c["line"]) == ("A", path, 1)
        @test pm["contingency_skipped"] == []
    end

    @testset "labels repeated across files are keyed by file stem" begin
        pm = fresh_pm()
        _, logs = add_con!(
            pm,
            con_file(block("A", "OPEN BUS 105"), block("U", "OPEN BUS 106"));
            name = "one.con",
        )
        @test sort(collect(keys(pm["contingency"]))) == ["A", "U"]
        @test isempty(filter(r -> occursin("repeated", r.message), logs))

        _, logs = add_con!(pm, con_file(block("A", "OPEN BUS 200")); name = "two.con")
        @test sort(collect(keys(pm["contingency"]))) == ["U", "one:A", "two:A"]
        @test pm["contingency"]["one:A"]["source_id"] == ["contingency", "one:A"]
        @test pm["contingency"]["one:A"]["label"] == "A"
        @test all(e -> e["via_bus"] == 105, elements_of(pm, "one:A"))
        @test all(e -> e["via_bus"] == 200, elements_of(pm, "two:A"))
        @test any(r -> occursin("repeated", r.message), logs)

        add_con!(pm, con_file(block("A", "OPEN BUS 201")); name = "three.con")
        @test sort(collect(keys(pm["contingency"]))) ==
              ["U", "one:A", "three:A", "two:A"]
    end
end

@testset "PSS/E .con bus disconnects are recast as N-k outages" begin
    function targets(pm, id)
        return [(e["section"], e["key"]) for e in elements_of(pm, id)]
    end

    @testset "attached branches, transformer, switch, injectors, via_bus" begin
        pm = fresh_pm()
        add_con!(pm, con_file(block("b", "OPEN BUS 105"), block("d", "DISCONNECT BUS 106")))
        @test isempty(pm["contingency_skipped"])
        @test targets(pm, "b") == [
            ("branch", "2"), ("branch", "22"), ("branch", "5"), ("load", "5"),
            ("switch", "1"),
        ]
        @test all(e -> e["via_bus"] == 105 && e["in_service"], elements_of(pm, "b"))
        actions =
            Dict((e["section"], e["key"]) => e["action"] for e in elements_of(pm, "b"))
        @test actions[("branch", "22")] == "open_branch"
        @test actions[("switch", "1")] == "open_branch"
        @test actions[("load", "5")] == "remove_load"
        d = Dict((e["section"], e["key"]) => e["action"] for e in elements_of(pm, "d"))
        @test d[("gen", "4")] == "remove_unit"
        @test d[("shunt", "2")] == "remove_shunt"
        @test all(e -> e["via_bus"] == 106, elements_of(pm, "d"))
        @test !any(e -> e["action"] == "open_bus", elements_of(pm, "d"))
        add_con!(pm, con_file(block("s", "OPEN BUS 101")); name = "s.con")
        @test ("switched_shunt", "1") in targets(pm, "s")
        @test any(e -> e["action"] == "remove_switched_shunt", elements_of(pm, "s"))
    end

    @testset "out-of-service attachments are excluded" begin
        pm = fresh_pm()
        pm["branch"]["5"]["br_status"] = 0
        pm["load"]["5"]["status"] = 0
        add_con!(pm, con_file(block("b", "OPEN BUS 105")))
        @test sort(targets(pm, "b")) ==
              [("branch", "2"), ("branch", "22"), ("switch", "1")]
    end

    @testset "a block that opens a bus and its branch has no duplicate element" begin
        pm = fresh_pm()
        add_con!(
            pm,
            con_file(
                block(
                    "dup",
                    "OPEN BRANCH FROM BUS 104 TO BUS 105 CKT '*1'",
                    "OPEN BUS 105",
                    "OPEN BUS 112",
                    "OPEN BUS 105",
                ),
            ),
        )
        ts = targets(pm, "dup")
        @test allunique(ts)
        @test count(==(("switch", "1")), ts) == 1
        @test ("breaker", "1") in ts
    end

    @testset "adjacent buses share their connecting branch once" begin
        pm = fresh_pm()
        add_con!(pm, con_file(block("adj", "OPEN BUS 105", "OPEN BUS 106")))
        ts = targets(pm, "adj")
        @test allunique(ts)
        @test ("branch", "22") in ts
    end

    @testset "three-winding transformer at the bus skips the block" begin
        pm = fresh_pm()
        _, logs =
            add_con!(pm, con_file(block("t", "OPEN BUS 104"), block("ok", "OPEN BUS 105")))
        @test collect(keys(pm["contingency"])) == ["ok"]
        s = only(pm["contingency_skipped"])
        @test s["label"] == "t"
        @test occursin("bus 104 has a three-winding transformer attached", s["reason"])
        @test occursin("cannot be recast as a component outage", s["reason"])
        @test any(r -> occursin("Skipping contingency 't'", r.message), logs)
    end

    @testset "an out-of-service three-winding transformer does not block" begin
        pm = fresh_pm()
        for e in values(pm["3w_transformer"])
            e["available"] = false
        end
        empty!(pm["dcline"])
        empty!(pm["vscline"])
        empty!(pm["facts"])
        add_con!(pm, con_file(block("t", "OPEN BUS 104")))
        @test isempty(pm["contingency_skipped"])
        @test ("branch", "21") in targets(pm, "t")
    end

    @testset "DC line, VSC line and FACTS device are attached elements" begin
        pm = fresh_pm()
        key(n) = only(k for (k, e) in pm["bus"] if e["source_id"][2] == string(n))
        pm["dcline"]["90"] = Dict{String, Any}(
            "source_id" => ["dcline", 90],
            "f_bus" => key(200), "t_bus" => key(201), "br_status" => true,
        )
        pm["vscline"]["91"] = Dict{String, Any}(
            "source_id" => ["vscline", 91],
            "f_bus" => key(301), "t_bus" => key(401), "br_status" => 1,
        )
        pm["facts"]["92"] = Dict{String, Any}(
            "source_id" => ["facts", 92],
            "bus" => key(501), "tbus" => key(601), "available" => true,
        )
        pm["facts"]["93"] = Dict{String, Any}(
            "source_id" => ["facts", 93],
            "bus" => key(103), "tbus" => 0, "available" => true,
        )
        add_con!(
            pm,
            con_file(
                block("dc", "OPEN BUS 201"),
                block("vsc", "OPEN BUS 301"),
                block("facts", "OPEN BUS 601"),
                block("shunt", "OPEN BUS 103"),
                block("both", "OPEN BUS 200", "OPEN BUS 201"),
                block("ok", "OPEN BUS 105"),
            ),
        )
        @test isempty(pm["contingency_skipped"])
        @test ("dcline", "90") in targets(pm, "dc")
        @test ("vscline", "91") in targets(pm, "vsc")
        @test ("facts", "92") in targets(pm, "facts")
        @test ("facts", "93") in targets(pm, "shunt")
        @test count(==(("dcline", "90")), targets(pm, "both")) == 1
        device(id, section) =
            only(e for e in elements_of(pm, id) if e["section"] == section)
        @test device("dc", "dcline")["action"] == "open_dc_line"
        @test device("vsc", "vscline")["action"] == "open_dc_line"
        @test device("facts", "facts")["action"] == "remove_facts"
        @test device("facts", "facts")["via_bus"] == 601
        @test device("dc", "dcline")["in_service"]
    end

    @testset "out-of-service DC line, VSC line and FACTS device are excluded" begin
        pm = fresh_pm()
        key(n) = only(k for (k, e) in pm["bus"] if e["source_id"][2] == string(n))
        pm["dcline"]["90"] = Dict{String, Any}(
            "source_id" => ["dcline", 90],
            "f_bus" => key(200), "t_bus" => key(201), "br_status" => false,
        )
        pm["vscline"]["91"] = Dict{String, Any}(
            "source_id" => ["vscline", 91],
            "f_bus" => key(301), "t_bus" => key(401), "br_status" => 0,
        )
        pm["facts"]["92"] = Dict{String, Any}(
            "source_id" => ["facts", 92],
            "bus" => key(501), "tbus" => 0, "available" => false,
        )
        add_con!(
            pm,
            con_file(
                block("dc", "OPEN BUS 201"),
                block("vsc", "OPEN BUS 301"),
                block("facts", "OPEN BUS 501"),
            ),
        )
        @test isempty(pm["contingency_skipped"])
        for id in ("dc", "vsc", "facts")
            @test !any(
                t -> t[1] in ("dcline", "vscline", "facts"),
                targets(pm, id),
            )
        end
    end

    @testset "a three-winding transformer bus with a DC line still skips" begin
        pm = fresh_pm()
        key(n) = only(k for (k, e) in pm["bus"] if e["source_id"][2] == string(n))
        pm["dcline"]["90"] = Dict{String, Any}(
            "source_id" => ["dcline", 90],
            "f_bus" => key(104), "t_bus" => key(201), "br_status" => true,
        )
        add_con!(pm, con_file(block("t", "OPEN BUS 104")))
        @test isempty(pm["contingency"])
        @test occursin("a three-winding transformer attached", only(skip_reasons(pm)))
    end

    @testset "a bus with nothing in service attached is skipped" begin
        pm = fresh_pm()
        pm["branch"]["15"]["br_status"] = 0
        pm["branch"]["18"]["br_status"] = 0
        add_con!(
            pm,
            con_file(block("none", "OPEN BUS 1001"), block("dead", "OPEN BUS 200")),
        )
        @test isempty(pm["contingency"])
        @test all(r -> occursin("has no in-service attached element", r), skip_reasons(pm))
        @test occursin("bus 1001 has no in-service attached element", skip_reasons(pm)[1])
    end

    @testset "a switching device between buses counts as attached" begin
        pm = multisection_pm()
        add_con!(pm, con_file(block("b", "OPEN BUS 2")))
        @test sort(targets(pm, "b")) == [("branch", "1"), ("switch", "1")]
        add_con!(pm, con_file(block("c", "OPEN BUS 3")); name = "x.con")
        @test sort(targets(pm, "c")) == [("branch", "2"), ("switch", "1")]
    end

    @testset "summary groups skipped bus blocks regardless of bus number" begin
        pm = fresh_pm()
        _, logs = add_con!(
            pm,
            con_file(block("a", "OPEN BUS 104"), block("b", "OPEN BUS 107")),
        )
        summary = only(filter(r -> occursin("summary", lowercase(r.message)), logs))
        @test occursin(
            "2 x bus N has a three-winding transformer attached",
            summary.message,
        )
    end
end

@testset "con_files and mon_file kwargs" begin
    raw = FOURTEEN_BUS_FIXTURE
    one = con_fixture(con_file(block("A", "OPEN BUS 105"), block("U", "OPEN BUS 106")))
    two = con_fixture(con_file(block("A", "OPEN BUS 200")))
    stem(p) = splitext(basename(p))[1]

    @testset "neither key without kwargs" begin
        for pm in (
            quiet(() -> PFFP.parse_file(raw)),
            quiet(() -> PFFP.PowerModelsData(raw).data),
        )
            @test !haskey(pm, "contingency")
            @test !haskey(pm, "monitor")
        end
    end

    @testset "con_files on parse_file and PowerModelsData, repeated labels re-keyed" begin
        keys_expected = sort(["U", "$(stem(one)):A", "$(stem(two)):A"])
        for pm in (
            quiet(() -> PFFP.parse_file(raw; con_files = [one, two])),
            quiet(() -> PFFP.PowerModelsData(raw; con_files = [one, two]).data),
        )
            @test sort(collect(keys(pm["contingency"]))) == keys_expected
            @test !haskey(pm, "monitor")
        end
    end

    @testset "a single file keeps bare labels, constructor adds once" begin
        pm = quiet(() -> PFFP.PowerModelsData(raw; con_files = [one]).data)
        @test sort(collect(keys(pm["contingency"]))) == ["A", "U"]
    end

    @testset "monitor_all_branches with a mon_file throws" begin
        mon = con_fixture("MONITOR ALL BRANCHES\nEND\n")
        @test_throws ArgumentError PFFP.parse_file(
            raw; mon_file = mon, monitor_all_branches = true,
        )
        pm = quiet(
            () -> PFFP.parse_file(raw; con_files = [one], monitor_all_branches = true),
        )
        @test pm["monitor"]["all_branches"]
        @test haskey(pm, "contingency")
    end

    @testset "sub_file without mon_file throws" begin
        sub = con_fixture("SUBSYSTEM X\nEND\nEND\n")
        @test_throws ArgumentError PFFP.parse_file(raw; sub_file = sub)
        @test_throws ArgumentError PFFP.PowerModelsData(raw; sub_file = sub)
    end

    @testset "PowerModelsData adds contingencies after transformer status correction" begin
        raw_text = replace(
            CON_MULTISECTION_RAW,
            "4,'BUSFOUR     ', 138.0000" => "4,'BUSFOUR     ', 345.0000",
        )
        path = tempname() * ".raw"
        write(path, raw_text)
        con = con_fixture(con_file(block("MISSING", "OPEN BUS 999")))
        logger = Test.TestLogger(; min_level = Logging.Warn)
        Logging.with_logger(logger) do
            PFFP.PowerModelsData(path; con_files = [con])
        end
        msgs = [l.message for l in logger.logs]
        i_xfmr = findfirst(m -> occursin("converting to transformer", m), msgs)
        i_con = findfirst(m -> occursin("MISSING", m), msgs)
        @test !isnothing(i_xfmr)
        @test !isnothing(i_con)
        @test i_xfmr < i_con
    end
end

function cc_large_case_configured()
    raw = get(ENV, "PFFP_LARGE_CASE_RAW", "")
    con_dir = get(ENV, "PFFP_LARGE_CASE_CON_DIR", "")
    if isempty(raw) != isempty(con_dir)
        error("set both PFFP_LARGE_CASE_RAW and PFFP_LARGE_CASE_CON_DIR, or neither")
    end
    return !isempty(raw)
end

@testset "large-case production data (opt-in: PFFP_LARGE_CASE_RAW, PFFP_LARGE_CASE_CON_DIR)" begin
    if !cc_large_case_configured()
        @info "PFFP_LARGE_CASE_RAW and PFFP_LARGE_CASE_CON_DIR are unset: skipping the large-case contingency check"
    else
        con_dir = ENV["PFFP_LARGE_CASE_CON_DIR"]
        cons = sort(filter(endswith(".con"), readdir(con_dir; join = true)))
        @test length(cons) == 41

        blocks = 0
        multisection = 0
        for con in cons
            read_blocks, read_skipped = with_logger(NullLogger()) do
                PFFP._read_con(con)
            end
            blocks += length(read_blocks) + length(read_skipped)
            multisection += sum(
                count(a -> startswith(a.id, "&"), b.actions) for b in read_blocks;
                init = 0,
            )
        end
        @test blocks == 36_790
        @test multisection == 193

        logger = Test.TestLogger(; min_level = Logging.Warn)
        elapsed = @elapsed pm = Logging.with_logger(logger) do
            PFFP.PowerModelsData(ENV["PFFP_LARGE_CASE_RAW"]; con_files = cons).data
        end
        println(
            "large-case parse with $(length(cons)) .con files: $(round(elapsed; digits = 1)) s",
        )

        contingencies = pm["contingency"]
        skipped = pm["contingency_skipped"]
        @test length(contingencies) + length(skipped) == blocks
        @test length(contingencies) == 36_190
        @test length(skipped) == 600
        reason_count(f) = count(s -> f(s["reason"]), skipped)
        @test reason_count(r -> occursin("has a three-winding transformer attached", r)) ==
              581
        @test reason_count(r -> occursin("has no in-service attached element", r)) == 13
        @test reason_count(r -> startswith(r, "CLOSE BRANCH target")) == 6
        @test length(pm["multisection_line"]) == 27

        by_action = Dict{String, Int}()
        for c in values(contingencies), e in c["elements"]
            by_action[e["action"]] = get(by_action, e["action"], 0) + 1
        end
        @test by_action == Dict(
            "open_branch" => 100_102,
            "open_3w_transformer" => 3_229,
            "remove_unit" => 1_841,
            "remove_load" => 11_467,
            "remove_shunt" => 380,
            "remove_switched_shunt" => 6_218,
            "open_dc_line" => 14,
            "remove_facts" => 15,
        )
        @test !haskey(by_action, "open_bus")
        @test count(
            e -> haskey(e, "via_bus"),
            (e for c in values(contingencies) for e in c["elements"]),
        ) == 60_326
        @test all(c -> !isempty(c["elements"]), values(contingencies))
        @test count(
            e -> !e["in_service"],
            (e for c in values(contingencies) for e in c["elements"]),
        ) == 558

        messages = [l.message for l in logger.logs]
        @test count(
            m -> occursin("CLOSE BRANCH", m) && occursin("Skipping", m),
            messages,
        ) == 6
        @test count(m -> occursin("CLOSE BRANCH skipped", m), messages) == 1
    end
end

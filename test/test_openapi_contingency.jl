using Logging

oc_quiet(f) = Logging.with_logger(f, Logging.NullLogger())

oc_block(label, lines...) = "CONTINGENCY '$label'\n" * join(lines, "\n") * "\nEND\n"

function oc_pm(blocks...)
    pm = oc_quiet(() -> PFP.PowerModelsData(FOURTEEN_BUS_FIXTURE).data)
    if !isempty(blocks)
        path = tempname() * ".con"
        write(path, join(blocks, "") * "END\n")
        oc_quiet(() -> PFP.add_contingencies!(pm, path))
    end
    return pm
end

function oc_build(pm)
    return oc_quiet(() -> PFP.build_openapi_system(PFP.PowerModelsData(pm)))
end

function oc_json(sys)
    path = tempname() * ".json"
    PFP.to_json(sys, path)
    return read(path, String), path
end

const OC_MIXED = oc_block(
    "MIXED",
    "OPEN BRANCH FROM BUS 101 TO BUS 102 CKT 1",
    "OPEN BUS 105",
    "OPEN BRANCH FROM BUS 104 TO BUS 105 CKT '*1'",
    "REMOVE UNIT 2 FROM BUS 101",
)
const OC_ALL = oc_block(
    "ALLKINDS",
    "OPEN BRANCH FROM BUS 109 TO BUS 104 TO BUS 107",
    "REMOVE LOAD 2 FROM BUS 110",
    "REMOVE SHUNT 1 FROM BUS 111",
    "REMOVE SWSHUNT 1 FROM BUS 101",
)
const OC_BUS_ONLY = oc_block("BUSONLY", "OPEN BUS 106")
const OC_BUS_NONE = oc_block("NOBUS", "OPEN BUS 1001")

function oc_outages(sys)
    return Dict(
        PFP.get_value(o, :identifier) => o for
        o in PFP.get_supplemental_attributes(sys, "FixedForcedOutage")
    )
end

function oc_rows(sys, outage)
    id = PFP.get_value(outage, :id)
    return [
        a for a in PFP.get_document(sys).supplemental_attribute_associations if
        PFP.get_value(a, :attribute_id) == id
    ]
end

@testset "IdRegistry by_source covers every pm dict entry the makers read" begin
    pm = oc_pm()
    sys = oc_build(pm)
    reg = PFP.get_registry(sys)
    types = PFP.get_document(sys).component_types_by_id
    for section in
        ("bus", "branch", "3w_transformer", "gen", "load", "shunt", "switched_shunt",
        "switch", "breaker")
        for key in keys(pm[section])
            @test haskey(types, PFP.get_source_id(reg, section, key))
        end
    end
    for key in keys(pm["3w_transformer"])
        @test types[PFP.get_source_id(reg, "3w_transformer", key)] ==
              "ThreeWindingTransformer"
    end
    for key in keys(pm["shunt"])
        @test types[PFP.get_source_id(reg, "shunt", key)] == "FixedAdmittance"
    end
    for key in keys(pm["switched_shunt"])
        @test types[PFP.get_source_id(reg, "switched_shunt", key)] == "SwitchedAdmittance"
    end
    for key in keys(pm["switch"])
        @test types[PFP.get_source_id(reg, "switch", key)] == "DiscreteControlledACBranch"
    end
    @test_throws IS.DataFormatError PFP.get_source_id(reg, "branch", "no-such-key")
end

@testset "contingencies emit one FixedForcedOutage each" begin
    pm = oc_pm(OC_MIXED, OC_ALL, OC_BUS_ONLY)
    @test sort(collect(keys(pm["contingency"]))) == ["ALLKINDS", "BUSONLY", "MIXED"]
    sys = oc_build(pm)
    reg = PFP.get_registry(sys)
    types = PFP.get_document(sys).component_types_by_id
    outages = oc_outages(sys)

    @test sort(collect(keys(outages))) == ["ALLKINDS", "BUSONLY", "MIXED"]
    @test length(PFP.get_supplemental_attributes(sys, "FixedForcedOutage")) == 3
    @test all(PFP.get_value(o, :outage_status) == 1.0 for o in values(outages))

    @test all(PFP.get_value(o, :id) > maximum(keys(types)) for o in values(outages))

    mixed_rows = oc_rows(sys, outages["MIXED"])
    mixed_elements = pm["contingency"]["MIXED"]["elements"]
    @test length(mixed_elements) == 7
    @test length(mixed_rows) == length(mixed_elements)
    @test all(PFP.get_value(r, :attribute_type) == "FixedForcedOutage" for r in mixed_rows)
    mixed_ids = sort([PFP.get_value(r, :component_id) for r in mixed_rows])
    @test mixed_ids == sort([
        PFP.get_source_id(reg, e["section"], e["key"]) for e in mixed_elements
    ])
    for r in mixed_rows
        @test PFP.get_value(r, :component_type) == types[PFP.get_value(r, :component_id)]
    end
    @test count(
        PFP.get_value(r, :component_type) == "DiscreteControlledACBranch" for
        r in mixed_rows
    ) == 1

    all_rows = oc_rows(sys, outages["ALLKINDS"])
    @test sort([PFP.get_value(r, :component_type) for r in all_rows]) == sort([
        "ThreeWindingTransformer",
        types[PFP.get_source_id(
            reg,
            "load",
            only(
                k for (k, v) in pm["load"] if v["source_id"][2:3] == [110, "2 "]
            ),
        )],
        "FixedAdmittance",
        "SwitchedAdmittance",
    ])
end

@testset "a bus disconnect emits one row per expanded element; switching devices are emitted" begin
    pm = oc_pm(OC_BUS_ONLY)
    elements = pm["contingency"]["BUSONLY"]["elements"]
    @test length(elements) == 7
    @test all(e["via_bus"] == 106 for e in elements)
    sys = oc_build(pm)
    outage = oc_outages(sys)["BUSONLY"]
    reg = PFP.get_registry(sys)
    @test sort([PFP.get_value(r, :component_id) for r in oc_rows(sys, outage)]) == sort([
        PFP.get_source_id(reg, e["section"], e["key"]) for e in elements
    ])

    switch_only = oc_pm(
        oc_block("SW", "OPEN BRANCH FROM BUS 104 TO BUS 105 CKT '*1'",
            "OPEN BRANCH FROM BUS 113 TO BUS 112 CKT '@1'"),
    )
    @test length(switch_only["contingency"]["SW"]["elements"]) == 2
    sys = oc_build(switch_only)
    rows = oc_rows(sys, oc_outages(sys)["SW"])
    @test length(rows) == 2
    @test all(
        PFP.get_value(r, :component_type) == "DiscreteControlledACBranch" for r in rows
    )
end

@testset "a bus outage emits DC line and FACTS device rows with their component types" begin
    pm = oc_pm(oc_block("DC", "OPEN BUS 111"), oc_block("FX", "OPEN BUS 108"))
    @test [
        e["action"] for e in pm["contingency"]["DC"]["elements"] if
        e["section"] == "dcline"
    ] == ["open_dc_line"]
    @test [
        e["action"] for e in pm["contingency"]["FX"]["elements"] if
        e["section"] == "facts"
    ] == ["remove_facts"]
    sys = oc_build(pm)
    reg = PFP.get_registry(sys)
    outages = oc_outages(sys)
    for (label, section, type) in
        (("DC", "dcline", "TwoTerminalLCCLine"), ("FX", "facts", "FACTSControlDevice"))
        id = PFP.get_source_id(reg, section, "1")
        rows = [
            r for r in oc_rows(sys, outages[label]) if
            PFP.get_value(r, :component_id) == id
        ]
        @test length(rows) == 1
        @test PFP.get_value(only(rows), :component_type) == type
    end
end

@testset "a bus outage emits a VSC line row as TwoTerminalVSCLine" begin
    raw = joinpath(@__DIR__, "fixtures", "synthetic_v35_vsc_line.raw")
    con = tempname() * ".con"
    write(con, oc_block("VSC", "OPEN BUS 3") * "END\n")
    pm = oc_quiet(() -> PFP.PowerModelsData(raw; con_files = [con]).data)
    @test ("vscline", "1") in
          [(e["section"], e["key"]) for e in pm["contingency"]["VSC"]["elements"]]
    sys = oc_build(pm)
    id = PFP.get_source_id(PFP.get_registry(sys), "vscline", "1")
    rows = [
        r for r in oc_rows(sys, oc_outages(sys)["VSC"]) if
        PFP.get_value(r, :component_id) == id
    ]
    @test PFP.get_value(only(rows), :component_type) == "TwoTerminalVSCLine"
end

@testset "a contingency with no emittable element warns once and creates no outage" begin
    pm = oc_pm(OC_MIXED)
    logger = Test.TestLogger(; min_level = Logging.Warn)
    Logging.with_logger(logger) do
        PFP.build_openapi_system(PFP.PowerModelsData(pm))
    end
    @test isempty(logger.logs)

    pm["contingency"]["EMPTY"] = Dict{String, Any}(
        "source_id" => ["contingency", "EMPTY"], "label" => "EMPTY", "elements" => [],
    )
    logger = Test.TestLogger(; min_level = Logging.Warn)
    sys = Logging.with_logger(logger) do
        PFP.build_openapi_system(PFP.PowerModelsData(pm))
    end
    summary = only(
        filter(m -> occursin("no emittable", m), string.(l.message for l in logger.logs)),
    )
    @test occursin("1 contingencies", summary)
    @test sort(collect(keys(oc_outages(sys)))) == ["MIXED"]
end

@testset "contingencies survive a JSON round trip" begin
    sys = oc_build(oc_pm(OC_MIXED, OC_ALL, OC_BUS_ONLY))
    _, path = oc_json(sys)
    doc = PFP.PD.read_document(path)
    outages = Dict(
        PFP.get_value(o, :identifier) => o for
        o in PFP.PD.get_supplemental_attributes(doc, "FixedForcedOutage")
    )
    @test sort(collect(keys(outages))) == ["ALLKINDS", "BUSONLY", "MIXED"]
    rows(name) = [
        a for a in doc.supplemental_attribute_associations if
        PFP.get_value(a, :attribute_id) == PFP.get_value(outages[name], :id)
    ]
    @test length(rows("MIXED")) == 7
    @test length(rows("BUSONLY")) == 7
    @test length(rows("ALLKINDS")) == 4
    @test all(PFP.get_value(o, :outage_status) == 1.0 for o in values(outages))
end

@testset "a pm dict without contingencies emits a byte-identical document" begin
    without, _ = oc_json(oc_build(oc_pm()))

    pm = oc_pm()
    pm["contingency"] = Dict{String, Any}()
    @test oc_json(oc_build(pm))[1] == without

    # A skipped bus disconnect gives no contingency, no outage and no used id.
    @test oc_json(oc_build(oc_pm(OC_BUS_NONE)))[1] == without

    with_outages, _ = oc_json(oc_build(oc_pm(OC_MIXED)))
    @test with_outages != without
end

@testset "monitored branches fill monitored_components on every outage; buses are not emitted" begin
    pm = oc_pm(OC_MIXED, OC_ALL)
    k1 = only(k for (k, v) in pm["branch"] if v["source_id"][2:3] == [101, 102])
    k2 = only(k for (k, v) in pm["branch"] if v["source_id"][2:3] == [102, 103])
    pm["monitor"] = Dict{String, Any}(
        "branches" => [["branch", k1], ["branch", k2]], "buses" => [101, 102],
        "voltage_band" => (0.95, 1.05), "all_branches" => false,
    )
    logger = Test.TestLogger(; min_level = Logging.Info)
    sys = Logging.with_logger(logger) do
        PFP.build_openapi_system(PFP.PowerModelsData(pm))
    end
    @test any(
        l.level == Logging.Info && occursin("parsed only", string(l.message)) for
        l in logger.logs
    )
    reg = PFP.get_registry(sys)
    expected =
        sort([PFP.get_source_id(reg, "branch", k1), PFP.get_source_id(reg, "branch", k2)])
    outages = oc_outages(sys)
    @test length(outages) == 2
    for o in values(outages)
        @test PFP.get_value(o, :monitored_components) == expected
    end
    bus_ids = [PFP.get_source_id(reg, "bus", k) for k in keys(pm["bus"])]
    @test isdisjoint(expected, bus_ids)

    _, path = oc_json(sys)
    doc = PFP.PD.read_document(path)
    for o in PFP.PD.get_supplemental_attributes(doc, "FixedForcedOutage")
        @test PFP.get_value(o, :monitored_components) == expected
    end

    @test_throws IS.DataFormatError oc_build(
        merge(
            pm,
            Dict(
                "monitor" =>
                    Dict("branches" => [["branch", "nope"]], "all_branches" => false),
            ),
        ),
    )
end

@testset "all_branches writes no monitored_components, a subset writes the list" begin
    pm = oc_pm(OC_MIXED, OC_ALL)
    PFP.monitor_all_branches!(pm)
    logger = Test.TestLogger(; min_level = Logging.Info)
    sys = Logging.with_logger(logger) do
        PFP.build_openapi_system(PFP.PowerModelsData(pm))
    end
    @test any(
        l.level == Logging.Info && occursin("monitored by default", string(l.message))
        for l in logger.logs
    )
    @test length(oc_outages(sys)) == 2
    @test !occursin("monitored_components", oc_json(sys)[1])

    pm = oc_pm(OC_MIXED, OC_ALL)
    k1 = first(keys(pm["branch"]))
    pm["monitor"] = Dict{String, Any}(
        "branches" => [["branch", k1]], "buses" => Int[],
        "voltage_band" => (-Inf, Inf), "all_branches" => false,
    )
    @test occursin("monitored_components", oc_json(oc_build(pm))[1])
end

@testset "no monitor key leaves monitored_components absent" begin
    sys = oc_build(oc_pm(OC_MIXED))
    @test !occursin("monitored_components", oc_json(sys)[1])
end

function oc_large_case_configured()
    raw = get(ENV, "PFFP_LARGE_CASE_RAW", "")
    con_dir = get(ENV, "PFFP_LARGE_CASE_CON_DIR", "")
    if isempty(raw) != isempty(con_dir)
        error("set both PFFP_LARGE_CASE_RAW and PFFP_LARGE_CASE_CON_DIR, or neither")
    end
    return !isempty(raw)
end

@testset "large-case production data emission (opt-in: PFFP_LARGE_CASE_RAW, PFFP_LARGE_CASE_CON_DIR)" begin
    if !oc_large_case_configured()
        @info "PFFP_LARGE_CASE_RAW and PFFP_LARGE_CASE_CON_DIR are unset: skipping the large-case document emission check"
    else
        con_dir = ENV["PFFP_LARGE_CASE_CON_DIR"]
        cons = sort(filter(endswith(".con"), readdir(con_dir; join = true)))
        raw = ENV["PFFP_LARGE_CASE_RAW"]
        pm = oc_quiet(() -> PFP.PowerModelsData(raw; con_files = cons).data)

        contingencies = pm["contingency"]
        elements = [e for c in values(contingencies) for e in c["elements"]]
        emittable = filter(PFP._is_emittable_element, elements)
        section_count(section) = count(e -> e["section"] == section, elements)
        emitted = filter(c -> any(PFP._is_emittable_element, c["elements"]),
            collect(values(contingencies)))
        @test section_count("switch") == 16_329
        @test section_count("breaker") == 4_947
        @test section_count("generic_connector") == 25
        @test length(elements) == 123_266
        @test length(emittable) == length(elements)
        @test length(emitted) == 36_190
        @test length(contingencies) == length(emitted)

        build_time = @elapsed sys = oc_build(pm)
        json_time = @elapsed (text, path) = oc_json(sys)
        println(
            "large-case build_openapi_system: $(round(build_time; digits = 1)) s, " *
            "to_json: $(round(json_time; digits = 1)) s",
        )
        outages = oc_outages(sys)
        @test length(outages) == length(emitted)
        @test sort(collect(keys(outages))) == sort([c["source_id"][2] for c in emitted])
        rows = [
            a for a in PFP.get_document(sys).supplemental_attribute_associations if
            PFP.get_value(a, :attribute_type) == "FixedForcedOutage"
        ]
        @test length(rows) == length(emittable)
        @test count(
            PFP.get_value(r, :component_type) == "DiscreteControlledACBranch" for r in rows
        ) == 16_329 + 4_947 + 25
        @test count(
            PFP.get_value(r, :component_type) == "TwoTerminalLCCLine" for r in rows
        ) == section_count("dcline")
        @test count(
            PFP.get_value(r, :component_type) == "FACTSControlDevice" for r in rows
        ) == section_count("facts")
        @test count("\"identifier\"", text) == length(emitted)
        rm(path)
    end
end

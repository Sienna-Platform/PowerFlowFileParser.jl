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

    @test sort(collect(keys(outages))) == ["ALLKINDS", "MIXED"]
    @test length(PFP.get_supplemental_attributes(sys, "FixedForcedOutage")) == 2
    @test all(PFP.get_value(o, :outage_status) == 1.0 for o in values(outages))

    @test all(PFP.get_value(o, :id) > maximum(keys(types)) for o in values(outages))

    mixed_rows = oc_rows(sys, outages["MIXED"])
    @test length(mixed_rows) == 3
    @test all(PFP.get_value(r, :attribute_type) == "FixedForcedOutage" for r in mixed_rows)
    mixed_ids = sort([PFP.get_value(r, :component_id) for r in mixed_rows])
    branch_key = only(
        k for (k, v) in pm["branch"] if v["source_id"][2:3] == [101, 102]
    )
    gen_key = only(
        k for (k, v) in pm["gen"] if v["source_id"][2:3] == ["101", "2 "]
    )
    switch_key = only(
        k for (k, v) in pm["switch"] if v["source_id"][2:3] == [104, 105]
    )
    @test mixed_ids == sort([
        PFP.get_source_id(reg, "branch", branch_key),
        PFP.get_source_id(reg, "switch", switch_key),
        PFP.get_source_id(reg, "gen", gen_key),
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

@testset "open_bus is not emitted; switching devices are" begin
    pm = oc_pm(OC_BUS_ONLY)
    @test length(pm["contingency"]["BUSONLY"]["elements"]) == 1
    sys = oc_build(pm)
    @test isempty(PFP.get_supplemental_attributes(sys, "FixedForcedOutage"))
    @test isempty(oc_outages(sys))

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

@testset "the skip summary is one warning with the counts" begin
    pm = oc_pm(OC_MIXED, OC_BUS_ONLY)
    logger = Test.TestLogger(; min_level = Logging.Warn)
    Logging.with_logger(logger) do
        PFP.build_openapi_system(PFP.PowerModelsData(pm))
    end
    messages = [string(l.message) for l in logger.logs]
    summary = only(filter(m -> occursin("not fully emitted", m), messages))
    @test occursin("2 open_bus", summary)
    @test !occursin("switching", summary)
    @test occursin("1 contingencies", summary)
end

@testset "contingencies survive a JSON round trip" begin
    sys = oc_build(oc_pm(OC_MIXED, OC_ALL, OC_BUS_ONLY))
    _, path = oc_json(sys)
    doc = PFP.PD.read_document(path)
    outages = Dict(
        PFP.get_value(o, :identifier) => o for
        o in PFP.PD.get_supplemental_attributes(doc, "FixedForcedOutage")
    )
    @test sort(collect(keys(outages))) == ["ALLKINDS", "MIXED"]
    rows(name) = [
        a for a in doc.supplemental_attribute_associations if
        PFP.get_value(a, :attribute_id) == PFP.get_value(outages[name], :id)
    ]
    @test length(rows("MIXED")) == 3
    @test length(rows("ALLKINDS")) == 4
    @test all(PFP.get_value(o, :outage_status) == 1.0 for o in values(outages))
end

@testset "a pm dict without contingencies emits a byte-identical document" begin
    without, _ = oc_json(oc_build(oc_pm()))

    pm = oc_pm()
    pm["contingency"] = Dict{String, Any}()
    @test oc_json(oc_build(pm))[1] == without

    # nothing emittable: no outage, no id consumed
    @test oc_json(oc_build(oc_pm(OC_BUS_ONLY)))[1] == without

    with_outages, _ = oc_json(oc_build(oc_pm(OC_MIXED)))
    @test with_outages != without
end

@testset "monitored branches fill monitored_components on every outage; buses are not emitted" begin
    pm = oc_pm(OC_MIXED, OC_ALL)
    k1 = only(k for (k, v) in pm["branch"] if v["source_id"][2:3] == [101, 102])
    k2 = only(k for (k, v) in pm["branch"] if v["source_id"][2:3] == [102, 103])
    pm["monitor"] = Dict{String, Any}(
        "branches" => [["branch", k1], ["branch", k2]], "buses" => [101, 102],
        "voltage_band" => (0.95, 1.05),
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
        merge(pm, Dict("monitor" => Dict("branches" => [["branch", "nope"]]))),
    )
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
        n_bus = count(PFP._is_bus_element, elements)
        section_count(section) = count(e -> e["section"] == section, elements)
        emitted = filter(c -> any(PFP._is_emittable_element, c["elements"]),
            collect(values(contingencies)))
        @test n_bus == 12_577
        @test section_count("switch") == 837
        @test section_count("breaker") == 1_383
        @test section_count("generic_connector") == 5
        @test length(emittable) == 63_302
        @test length(elements) - n_bus == length(emittable)
        @test length(emitted) == 26_725
        @test length(contingencies) - length(emitted) == 10_059

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
        ) == 837 + 1_383 + 5
        @test count("\"identifier\"", text) == length(emitted)
        rm(path)
    end
end

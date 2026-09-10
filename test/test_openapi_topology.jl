@testset "build_openapi_system reads topology, loads, generation, branches, transformers, switches/breakers, dc lines, shunts, and attributes" begin
    sys = PFP.build_openapi_system(fourteen_bus_pm_data())
    @test PFP.component_type_names(sys) == [
        "ACBus", "Arc", "Area", "DiscreteControlledACBranch", "FACTSControlDevice",
        "FixedAdmittance", "Line", "LoadZone", "StandardLoad", "SwitchedAdmittance",
        "ThermalStandard", "ThreeWindingTransformer", "TransformerCircuit",
        "TwoTerminalLCCLine", "TwoWindingTransformer",
    ]
    @test length(PFP.get_components(sys, "ACBus")) == 22
    @test length(PFP.get_components(sys, "Area")) == 1
    @test length(PFP.get_components(sys, "LoadZone")) == 1
    # Coefficient-level assertions live in the per-reader test files
    # (test_openapi_load.jl, test_openapi_generation.jl, test_openapi_branch.jl,
    # test_openapi_dc_shunt.jl, test_openapi_switch.jl, test_openapi_attributes.jl);
    # this just locks in the component census.
    @test length(PFP.get_components(sys, "StandardLoad")) == 13
    @test length(PFP.get_components(sys, "ThermalStandard")) == 7
    @test length(PFP.get_components(sys, "Line")) == 20
    @test length(PFP.get_components(sys, "TwoWindingTransformer")) == 3
    @test length(PFP.get_components(sys, "ThreeWindingTransformer")) == 2
    @test length(PFP.get_components(sys, "TransformerCircuit")) == 9
    @test length(PFP.get_components(sys, "TwoTerminalLCCLine")) == 1
    @test length(PFP.get_components(sys, "FixedAdmittance")) == 4
    @test length(PFP.get_components(sys, "SwitchedAdmittance")) == 2
    @test length(PFP.get_components(sys, "FACTSControlDevice")) == 1
    @test length(PFP.get_components(sys, "DiscreteControlledACBranch")) == 2
    @test length(PFP.get_supplemental_attributes(sys, "ImpedanceCorrectionData")) == 8
end

@testset "build_openapi_system errors on a genuinely unknown, non-empty pm dict section" begin
    data = fourteen_bus_pm_data().data
    data["totally_unknown_section"] = Dict{String, Any}("1" => Dict{String, Any}())
    pm_data = PFP.PowerModelsData(data)
    err = try
        PFP.build_openapi_system(pm_data)
        nothing
    catch e
        e
    end
    @test err isa IS.DataFormatError
    @test occursin("totally_unknown_section", err.msg)
    @test occursin("(1)", err.msg)
end

@testset "_check_unconsumed_sections passes for every section either consumed or on KNOWN_UNCONSUMED_PM_SECTIONS" begin
    data = fourteen_bus_pm_data().data
    only_known = Dict{String, Any}(
        (key => data[key] for key in PFP._CONSUMED_PM_SECTIONS if haskey(data, key))...,
    )
    for (key, _) in PFP.KNOWN_UNCONSUMED_PM_SECTIONS
        only_known[key] = Dict{String, Any}("1" => Dict{String, Any}())
    end
    only_known["baseMVA"] = data["baseMVA"]
    only_known["source_type"] = data["source_type"]
    only_known["per_unit"] = data["per_unit"]
    # Does not throw.
    PFP._check_unconsumed_sections(only_known)
end

@testset "_check_unconsumed_sections passes for scalar pm dict keys and empty sections" begin
    data = fourteen_bus_pm_data().data
    only_consumed = Dict{String, Any}(
        "bus" => data["bus"],
        "totally_unknown_but_empty" => Dict{String, Any}(),
        "baseMVA" => data["baseMVA"],
        "source_type" => data["source_type"],
        "per_unit" => data["per_unit"],
    )
    # Does not throw: an empty section, even an unrecognized one, carries no absent
    # components to warn about.
    PFP._check_unconsumed_sections(only_consumed)
end

@testset "every KNOWN_UNCONSUMED_PM_SECTIONS entry carries a non-empty reason" begin
    for (key, reason) in PFP.KNOWN_UNCONSUMED_PM_SECTIONS
        @test !isempty(strip(reason))
    end
end

@testset "LoadZone peak sums bus loads and converts system pu to MW/MVAr" begin
    sys = PFP.build_openapi_system(fourteen_bus_pm_data())
    zone = only(PFP.get_components(sys, "LoadZone"))
    # Cross-checked against PowerSystemCaseBuilder's oracle: 34.8 / -8.62 pu on a
    # 100 MVA base.
    @test PFP.get_value(zone, :peak_active_power) ≈ 3480.0
    @test PFP.get_value(zone, :peak_reactive_power) ≈ -862.0
    @test PFP.get_value(zone, :base_power) == 100.0
end

@testset "Area leaves peak absent, matching the oracle's asymmetry with LoadZone" begin
    # Unlike LoadZone, `_ensure_area!` never sums bus loads onto an Area, and the new
    # immutable model no longer defaults an unset optional field to zero (see "unset
    # properties are absent, not null" in test_openapi_serialize.jl) — so the field
    # this component never staged stays genuinely `Absent`, not a phantom 0.0.
    sys = PFP.build_openapi_system(fourteen_bus_pm_data())
    area = only(PFP.get_components(sys, "Area"))
    @test PFP.get_value(area, :peak_active_power) === PFP.ABSENT
    @test PFP.get_value(area, :peak_reactive_power) === PFP.ABSENT
    @test PFP.get_value(area, :base_power) == 100.0
end

@testset "ACBus fields come off the pm dict with the declared units" begin
    sys = PFP.build_openapi_system(fourteen_bus_pm_data())
    data = fourteen_bus_pm_data().data
    reg = PFP.get_registry(sys)
    for bus in PFP.get_components(sys, "ACBus")
        number = PFP.get_value(bus, :number)
        d = data["bus"][number]
        @test PFP.get_value(bus, :base_voltage) == d["base_kv"]
        @test PFP.get_value(bus, :angle) == d["va"]
        @test PFP.get_value(bus, :magnitude) == d["vm"]
        @test PFP.get_value(bus, :voltage_limits).min == d["vmin"]
        @test PFP.get_value(bus, :voltage_limits).max == d["vmax"]
        @test PFP.get_bus_id(reg, number) == PFP.get_value(bus, :id)
    end
end

@testset "ACBus resolves area and load zone to registered ids" begin
    sys = PFP.build_openapi_system(fourteen_bus_pm_data())
    reg = PFP.get_registry(sys)
    area_id = PFP.get_id(reg, "Area", "1")
    zone_id = PFP.get_id(reg, "LoadZone", "1")
    for bus in PFP.get_components(sys, "ACBus")
        @test PFP.get_value(bus, :area) == area_id
        @test PFP.get_value(bus, :load_zone) == zone_id
    end
end

@testset "bus_type 3 (REF) maps to the schema's REF string" begin
    sys = PFP.build_openapi_system(fourteen_bus_pm_data())
    data = fourteen_bus_pm_data().data
    for bus in PFP.get_components(sys, "ACBus")
        number = PFP.get_value(bus, :number)
        expected = PFP._bustype_name(Int(data["bus"][number]["bus_type"]))
        @test PFP.get_value(bus, :bustype) == expected
    end
end

@testset "an unavailable bus (bus_status = false) sets available = false" begin
    sys = PFP.build_openapi_system(fourteen_bus_pm_data())
    data = fourteen_bus_pm_data().data
    for bus in PFP.get_components(sys, "ACBus")
        number = PFP.get_value(bus, :number)
        @test PFP.get_value(bus, :available) ==
              Bool(get(data["bus"][number], "bus_status", true))
    end
end

@testset "area_slack overrides bus_type to SLACK" begin
    pm_data =
        PFP.PowerModelsData(joinpath(@__DIR__, "fixtures", "v35_area_slack_variants.raw"))
    sys = PFP.build_openapi_system(pm_data)
    reg = PFP.get_registry(sys)
    buses = PFP.get_components(sys, "ACBus")
    slack_bus = only(b for b in buses if PFP.get_value(b, :number) == 2)
    @test PFP.get_value(slack_bus, :bustype) == "SLACK"
    other = [b for b in buses if PFP.get_value(b, :number) != 2]
    @test all(b -> PFP.get_value(b, :bustype) != "SLACK", other)
end

@testset "Area.ext carries PSS/E AREA DATA metadata matched by area_number" begin
    pm_data =
        PFP.PowerModelsData(joinpath(@__DIR__, "fixtures", "v35_area_slack_variants.raw"))
    data = pm_data.data
    # Every bus in this fixture is area=1; area_interchange's area_number=1 record names
    # bus 2 as the area slack, with a zero net/tolerance interchange of 0.0/10.0.
    @test all(d -> d["area"] == 1, values(data["bus"]))
    area1_d = only(v for v in values(data["area_interchange"]) if v["area_number"] == 1)
    @test area1_d["bus_number"] == 2
    @test area1_d["area_name"] == "AREA1       "

    sys = PFP.build_openapi_system(pm_data)
    area = only(PFP.get_components(sys, "Area"))
    ext = PFP.get_ext(sys, PFP.get_value(area, :id))
    @test ext["ARNAME"] == "AREA1"  # strip()'d, unlike the raw fixed-width field
    @test ext["I"] == "1"
    @test ext["ISW"] == "2"
    @test ext["PDES"] == area1_d["net_interchange"]
    @test ext["PTOL"] == area1_d["tol_interchange"]
end

@testset "_has_area_interchange is false without a source_type/area_interchange/matching area_number" begin
    pm_data =
        PFP.PowerModelsData(joinpath(@__DIR__, "fixtures", "v35_area_slack_variants.raw"))
    data = pm_data.data
    @test !PFP._has_area_interchange(data, "999")  # no area_number == "999"
    @test !PFP._has_area_interchange(Dict{String, Any}(), "1")  # no source_type
    matpower_data = merge(data, Dict{String, Any}("source_type" => "matpower"))
    @test !PFP._has_area_interchange(matpower_data, "1")  # oracle-matched: pti only
end

@testset "_bustype_name rejects a code outside PowerModels' 1-4 range" begin
    @test PFP._bustype_name(1) == "PQ"
    @test PFP._bustype_name(4) == "ISOLATED"
    @test_throws IS.DataFormatError PFP._bustype_name(5)
    @test_throws IS.DataFormatError PFP._bustype_name(0)
end

@testset "bus_name_formatter, area_name_formatter and loadzone_name_formatter thread through" begin
    sys = PFP.build_openapi_system(
        fourteen_bus_pm_data();
        bus_name_formatter = d -> "BUS_$(d["bus_i"])",
        area_name_formatter = a -> "AREA_$a",
        loadzone_name_formatter = z -> "ZONE_$z",
    )
    reg = PFP.get_registry(sys)
    @test PFP.has_id(reg, "ACBus", "BUS_101")
    @test PFP.has_id(reg, "Area", "AREA_1")
    @test PFP.has_id(reg, "LoadZone", "ZONE_1")
end

@testset "add_arc! deduplicates a bus pair regardless of direction" begin
    # Topology only (no branches/transformers/dc lines) so the Arc census this test
    # asserts is self-contained; `build_openapi_system` creates real arcs of its own,
    # which would make a fixed expected count fragile.
    data = fourteen_bus_pm_data().data
    sys = PFP.OpenAPISystem(Float64(data["baseMVA"]))
    PFP.read_loadzones!(sys, data)
    PFP.read_bus!(sys, data)
    reg = PFP.get_registry(sys)
    from_id = PFP.get_bus_id(reg, 101)
    to_id = PFP.get_bus_id(reg, 102)
    id1 = PFP.add_arc!(sys, from_id, to_id)
    id2 = PFP.add_arc!(sys, from_id, to_id)
    id3 = PFP.add_arc!(sys, to_id, from_id)
    @test id1 == id2
    @test id1 != id3
    @test length(PFP.get_components(sys, "Arc")) == 2
    arc = first(a for a in PFP.get_components(sys, "Arc") if PFP.get_value(a, :id) == id1)
    @test PFP.get_value(arc, :from_id) == from_id
    @test PFP.get_value(arc, :to_id) == to_id
end

@testset "the emitted document round-trips through PC and validates" begin
    sys = PFP.build_openapi_system(fourteen_bus_pm_data())
    path = joinpath(mktempdir(), "fourteen_bus.json")
    PFP.to_json(sys, path)
    doc = PFP.PD.read_document(path)
    @test length(PFP.PD.get_components(doc, "ACBus")) == 22
    @test length(PFP.PD.get_components(doc, "Area")) == 1
    @test length(PFP.PD.get_components(doc, "LoadZone")) == 1
    @test length(PFP.PD.get_components(doc, "StandardLoad")) == 13
    @test length(PFP.PD.get_components(doc, "ThermalStandard")) == 7
    @test length(PFP.PD.get_components(doc, "Line")) == 20
    @test length(PFP.PD.get_components(doc, "TwoWindingTransformer")) == 3
    @test length(PFP.PD.get_components(doc, "ThreeWindingTransformer")) == 2
    @test length(PFP.PD.get_components(doc, "TwoTerminalLCCLine")) == 1
    @test length(PFP.PD.get_components(doc, "FixedAdmittance")) == 4
    @test length(PFP.PD.get_components(doc, "SwitchedAdmittance")) == 2
    @test length(PFP.PD.get_components(doc, "FACTSControlDevice")) == 1
    @test length(PFP.PD.get_components(doc, "DiscreteControlledACBranch")) == 2
    @test length(PFP.PD.get_supplemental_attributes(doc, "ImpedanceCorrectionData")) == 8
    # GeographicInfo stays empty: "substation" is allow-listed
    # (`KNOWN_UNCONSUMED_PM_SECTIONS`, build.jl), not implemented.
    @test isempty(PFP.PD.get_components(doc, "GeographicInfo"))
end

@testset "build_openapi_system rejects a pm dict with no buses" begin
    pm_data = PFP.PowerModelsData(
        Dict{String, Any}("bus" => Dict{String, Any}(), "baseMVA" => 100.0),
    )
    @test_throws IS.DataFormatError PFP.build_openapi_system(pm_data)
end

@testset "ImpedanceCorrectionData: attribute count and sharing match the oracle exactly" begin
    pm = fourteen_bus_pm_data()
    sys = PFP.build_openapi_system(pm)
    data = pm.data
    @test length(data["impedance_correction"]) == 9

    # Cross-checked directly against PSCB's oracle (`system_via_power_models`) on this
    # fixture: 9 raw impedance-correction tables produce 8 distinct
    # `ImpedanceCorrectionData` attributes, not 9 — table 8 is referenced as the
    # secondary-winding correction table by BOTH 3W transformers in this fixture
    # ("BUS 109-BUS 104-BUS 107-i_1" and "BUS 113-BUS 110-BUS 114-i_1"), and the oracle
    # shares one `ImpedanceCorrectionData` object between them rather than building two.
    icts = PFP.get_supplemental_attributes(sys, "ImpedanceCorrectionData")
    @test length(icts) == 8

    table_numbers = sort([PFP.get_value(ict, :table_number) for ict in icts])
    @test table_numbers == [1, 3, 4, 4, 7, 8, 9, 9]

    doc = PFP.get_document(sys)
    associations = [
        a for a in doc.supplemental_attribute_associations if
        PFP.get_value(a, :attribute_type) == "ImpedanceCorrectionData"
    ]
    @test length(associations) == 9  # one per transformer winding that names a table

    shared = only(
        ict for ict in icts if
        PFP.get_value(ict, :table_number) == 8 &&
        PFP.get_value(ict, :transformer_winding) == "SECONDARY_WINDING"
    )
    shared_id = PFP.get_value(shared, :id)
    shared_rows = [a for a in associations if PFP.get_value(a, :attribute_id) == shared_id]
    @test length(shared_rows) == 2
    @test all(
        PFP.get_value(a, :component_type) == "ThreeWindingTransformer" for a in shared_rows
    )
    component_ids = sort([PFP.get_value(a, :component_id) for a in shared_rows])
    primary_3w = PFP.get_value(
        only(
            t for t in PFP.get_components(sys, "ThreeWindingTransformer") if
            PFP.get_value(t, :name) == "BUS 109-BUS 104-BUS 107-i_1"
        ),
        :id,
    )
    other_3w = PFP.get_value(
        only(
            t for t in PFP.get_components(sys, "ThreeWindingTransformer") if
            PFP.get_value(t, :name) == "BUS 113-BUS 110-BUS 114-i_1"
        ),
        :id,
    )
    @test component_ids == sort([primary_3w, other_3w])
end

@testset "ImpedanceCorrectionData: table_number/curve/control_mode hand-derived from a single 2W table" begin
    pm = fourteen_bus_pm_data()
    sys = PFP.build_openapi_system(pm)
    data = pm.data

    # Three 2W transformers in this fixture carry a nonzero `correction_table` (tables 3,
    # 4, 7); table 7 belongs to "BUS 106-BUS 105-i_1" ("TRAFO 2W 1").
    branch_d = only(
        d for (_, d) in data["branch"] if get(d, "correction_table", 0) == 7,
    )
    @test branch_d["transformer"]
    table_number = branch_d["correction_table"]
    @test table_number == 7
    table_d = only(
        d for (_, d) in data["impedance_correction"] if d["table_number"] == table_number
    )
    x, y = table_d["tap_or_angle"], table_d["scaling_factor"]
    # Hand-derived: table 7's first tap/angle point is 3.0, outside
    # [PSSE_PARSER_TAP_RATIO_LBOUND, PSSE_PARSER_TAP_RATIO_UBOUND] = [0.5, 1.5], so this
    # table is a phase-shift-angle correction, not a tap-ratio one.
    @test !(PFP.PSSE_PARSER_TAP_RATIO_LBOUND <= x[1] <= PFP.PSSE_PARSER_TAP_RATIO_UBOUND)

    two_w = only(
        t for t in PFP.get_components(sys, "TwoWindingTransformer") if
        PFP.get_value(t, :name) == "BUS 106-BUS 105-i_1"
    )
    ict = only(
        ict for
        ict in PFP.get_supplemental_attributes(sys, "ImpedanceCorrectionData") if
        PFP.get_value(ict, :table_number) == table_number &&
        PFP.get_value(ict, :transformer_winding) == "TR2W_WINDING"
    )
    @test PFP.get_value(ict, :transformer_control_mode) == "PHASE_SHIFT_ANGLE"
    # A phase-shift table lands on phase_angle_correction_curve, its x axis converted
    # from PSS/E's degrees to the schema's radians; the tap-ratio curve stays absent.
    @test PFP.get_value(ict, :tap_ratio_correction_curve) === PFP.ABSENT
    curve = PFP.get_value(ict, :phase_angle_correction_curve)
    points = PFP.get_value(curve, :points)
    @test length(points) == length(x)
    for (i, point) in enumerate(points)
        @test PFP.get_value(point, :x) ≈ deg2rad(x[i])
        @test PFP.get_value(point, :y) == y[i]
    end

    doc = PFP.get_document(sys)
    row = only(
        a for a in doc.supplemental_attribute_associations if
        PFP.get_value(a, :attribute_id) == PFP.get_value(ict, :id),
    )
    @test PFP.get_value(row, :component_id) == PFP.get_value(two_w, :id)
    @test PFP.get_value(row, :component_type) == "TwoWindingTransformer"
    @test PFP.get_value(row, :attribute_type) == "ImpedanceCorrectionData"
    # A plain attribute link emits nothing in the plant-family or service tables. This used
    # to assert `group_index`/`role` were unset on the row itself; those columns are gone
    # with the un-consolidation, so the row type enforces that much structurally and what is
    # left worth checking is that no row landed in the tables that replaced them.
    @test isempty(doc.plant_associations)
    @test isempty(doc.combined_cycle_associations)
    @test isempty(doc.service_associations)
end

@testset "read_attributes! is a no-op when impedance_correction is absent" begin
    data = Dict{String, Any}(
        "bus" => Dict{String, Any}(
            "1" => Dict{String, Any}(
                "bus_i" => 1, "bus_type" => 3, "area" => 1, "zone" => 1,
                "base_kv" => 138.0, "va" => 0.0, "vm" => 1.0, "vmin" => 0.9,
                "vmax" => 1.1, "name" => "b1",
            ),
        ),
    )
    sys = PFP.OpenAPISystem(100.0)
    PFP.read_loadzones!(sys, data)
    PFP.read_bus!(sys, data)
    PFP.read_attributes!(sys, data)
    @test isempty(PFP.get_supplemental_attributes(sys, "ImpedanceCorrectionData"))
end

@testset "_impedance_correction_curves rejects a tap/angle-vs-scaling-factor length mismatch" begin
    data = Dict{String, Any}(
        "impedance_correction" => Dict{String, Any}(
            "1" => Dict{String, Any}(
                "table_number" => 1, "tap_or_angle" => [1.0, 2.0],
                "scaling_factor" => [1.0],
            ),
        ),
    )
    @test_throws IS.DataFormatError PFP._impedance_correction_curves(data)
end

@testset "the emitted document round-trips through PC with ImpedanceCorrectionData intact" begin
    sys = PFP.build_openapi_system(fourteen_bus_pm_data())
    path = joinpath(mktempdir(), "fourteen_bus_attributes.json")
    PFP.to_json(sys, path)
    doc = PFP.PD.read_document(path)
    icts = PFP.PD.get_supplemental_attributes(doc, "ImpedanceCorrectionData")
    @test length(icts) == 8
    PFP.PD.validate_document(doc)
end

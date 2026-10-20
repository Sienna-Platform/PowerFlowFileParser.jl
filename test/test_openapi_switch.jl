@testset "DiscreteControlledACBranch: switch/breaker r/x/flow passthrough, zero rating unbounded" begin
    pm = fourteen_bus_pm_data()
    sys = PFP.build_openapi_system(pm)
    data = pm.data

    switch_d = only(values(data["switch"]))
    breaker_d = only(values(data["breaker"]))
    # Cross-checked against PSCB's oracle on this fixture: two DiscreteControlledACBranch
    # components, "BUS 104-BUS 105-i_1" (SWITCH) and "BUS 112-BUS 113-i_1" (BREAKER), both
    # CLOSED and available.
    @test length(PFP.get_components(sys, "DiscreteControlledACBranch")) == 2

    switch = only(
        c for c in PFP.get_components(sys, "DiscreteControlledACBranch") if
        PFP.get_value(c, :discrete_branch_type) == "SWITCH"
    )
    @test PFP.get_value(switch, :name) == "BUS 104-BUS 105-i_1"
    @test PFP.get_value(switch, :available)
    @test PFP.get_value(switch, :branch_status) == "CLOSED"
    @test PFP.get_value(switch, :r) == switch_d["r"]
    @test PFP.get_value(switch, :x) == switch_d["x"]
    # PSS/E writes 0 for an unset rating. It becomes the same unbounded MVA placeholder a
    # Line gets (`_get_rating` returns pu, which `make_line!` scales by the system base),
    # and the unset secondary ratings stay absent.
    @test switch_d["rating"] == 0.0
    @test switch_d["rating_b"] == 0.0
    @test switch_d["rating_c"] == 0.0
    line_placeholder_mva = PFP._get_rating("line", Dict{String, Any}(), "rate_a") * 100.0
    @test PFP.get_value(switch, :rating) == PFP.INFINITE_BOUND * 100.0
    @test PFP.get_value(switch, :rating) == line_placeholder_mva
    @test PFP.get_value(switch, :rating_b) === PFP.ABSENT
    @test PFP.get_value(switch, :rating_c) === PFP.ABSENT
    @test PFP.get_value(switch, :active_power_flow) == 0.0
    @test PFP.get_value(switch, :reactive_power_flow) == 0.0
    @test PFP.get_value(switch, :base_power) == 100.0  # sys_mbase
    # OpenAPI.jl 1.x dropped the mutable-model runtime that used to auto-populate an
    # unset field from the JSON schema's own `default`; a `@kwdef` struct's field default
    # is uniformly `ABSENT`, so a field read_switch_breaker! never stages (there is no pm
    # dict source for a "normal" as-designed status, only the current one) now stays
    # genuinely absent rather than reading back the schema's documented "CLOSED" default.
    @test PFP.get_value(switch, :normal_branch_status) === PFP.ABSENT

    breaker = only(
        c for c in PFP.get_components(sys, "DiscreteControlledACBranch") if
        PFP.get_value(c, :discrete_branch_type) == "BREAKER"
    )
    @test PFP.get_value(breaker, :name) == "BUS 112-BUS 113-i_1"
    @test PFP.get_value(breaker, :available)
    @test PFP.get_value(breaker, :branch_status) == "CLOSED"
    @test PFP.get_value(breaker, :r) == breaker_d["r"]
    @test PFP.get_value(breaker, :x) == breaker_d["x"]
    @test PFP.get_value(breaker, :base_power) == 100.0
end

@testset "read_switch_breaker! is a no-op when switch/breaker/generic_connector are all absent" begin
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
    PFP.read_switch_breaker!(sys, data)
    @test isempty(PFP.get_components(sys, "DiscreteControlledACBranch"))
end

@testset "_discrete_branch_type/_discrete_branch_status reject unsupported codes" begin
    @test PFP._discrete_branch_type(0) == "SWITCH"
    @test PFP._discrete_branch_type(1) == "BREAKER"
    @test PFP._discrete_branch_type(2) == "OTHER"
    @test_throws IS.DataFormatError PFP._discrete_branch_type(3)
    @test PFP._discrete_branch_status(0) == "OPEN"
    @test PFP._discrete_branch_status(1) == "CLOSED"
    @test_throws IS.DataFormatError PFP._discrete_branch_status(2)
end

@testset "generic_connector: mapped to discrete_branch_type OTHER" begin
    pm = PFP.PowerModelsData(
        joinpath(@__DIR__, "fixtures", "synthetic_v35_generic_connector.raw"),
    )
    data = pm.data
    @test length(data["generic_connector"]) == 1
    gc_d = only(values(data["generic_connector"]))
    @test gc_d["discrete_branch_type"] == 2

    sys = PFP.OpenAPISystem(Float64(data["baseMVA"]))
    PFP.read_loadzones!(sys, data)
    PFP.read_bus!(sys, data)
    PFP.read_switch_breaker!(sys, data)
    gc = only(
        c for c in PFP.get_components(sys, "DiscreteControlledACBranch") if
        PFP.get_value(c, :discrete_branch_type) == "OTHER"
    )
    @test PFP.get_value(gc, :r) == gc_d["r"]
    @test PFP.get_value(gc, :x) == gc_d["x"]
end

@testset "v35 BRANCH-section switch/breaker keeps its R value (PSY#1702)" begin
    pm = PFP.PowerModelsData(
        joinpath(@__DIR__, "fixtures", "synthetic_v35_branch_switch_r.raw"),
    )
    data = pm.data

    # Unlike the v35 SWITCHING DEVICE section, legacy BRANCH records flagged as
    # switches/breakers (CKT starting with '*' or '@') carry an R field, which must be
    # used verbatim instead of being zeroed out.
    switch_d = only(values(data["switch"]))
    @test switch_d["r"] == 2.5e-4
    @test switch_d["x"] == 1.0e-4

    breaker_d = only(values(data["breaker"]))
    @test breaker_d["r"] == 7.5e-4
    @test breaker_d["x"] == 1.0e-4

    sys = PFP.OpenAPISystem(Float64(data["baseMVA"]))
    PFP.read_loadzones!(sys, data)
    PFP.read_bus!(sys, data)
    PFP.read_switch_breaker!(sys, data)
    switch = only(
        c for c in PFP.get_components(sys, "DiscreteControlledACBranch") if
        PFP.get_value(c, :discrete_branch_type) == "SWITCH"
    )
    @test PFP.get_value(switch, :r) == 2.5e-4
    breaker = only(
        c for c in PFP.get_components(sys, "DiscreteControlledACBranch") if
        PFP.get_value(c, :discrete_branch_type) == "BREAKER"
    )
    @test PFP.get_value(breaker, :r) == 7.5e-4
end

@testset "DiscreteControlledACBranch: PSS/E secondary ratings map to rating_b/rating_c" begin
    for fixture in ("synthetic_v34_substation.raw", "synthetic_v34_full.raw")
        pm = PFP.PowerModelsData(joinpath(@__DIR__, "fixtures", fixture))
        data = pm.data
        sys = PFP.build_openapi_system(pm)
        sys_mbase = Float64(data["baseMVA"])
        breaker_d = only(values(data["breaker"]))
        # RATE2/RATE3 are rating_b/rating_c rather than ext entries, like a line's; as for a
        # line, a zero value is unset (`nothing`).
        @test !haskey(breaker_d["ext"], "RATE2")
        @test !haskey(breaker_d["ext"], "RATE3")
        breaker = only(
            c for c in PFP.get_components(sys, "DiscreteControlledACBranch") if
            PFP.get_value(c, :discrete_branch_type) == "BREAKER"
        )
        @test PFP.get_value(breaker, :rating) == breaker_d["rating"]
        @test PFP.get_value(breaker, :rating_b) == breaker_d["rating_b"]
        @test PFP.get_value(breaker, :rating_c) == breaker_d["rating_c"]
        @test PFP.get_value(breaker, :base_power) == sys_mbase
    end

    pm = PFP.PowerModelsData(joinpath(@__DIR__, "fixtures", "synthetic_v34_substation.raw"))
    breaker_d = only(values(pm.data["breaker"]))
    @test (breaker_d["rating"], breaker_d["rating_b"], breaker_d["rating_c"]) ==
          (100.0, 110.0, 120.0)
    sys = PFP.build_openapi_system(pm)
    switch = only(
        c for c in PFP.get_components(sys, "DiscreteControlledACBranch") if
        PFP.get_value(c, :discrete_branch_type) == "SWITCH"
    )
    @test PFP.get_value(switch, :rating) ==
          PFP.INFINITE_BOUND * Float64(pm.data["baseMVA"])
    @test PFP.get_value(switch, :rating_b) === PFP.ABSENT
end

@testset "make_switch_breaker!: missing or zero ratings" begin
    bus_d(number, bus_type) = Dict{String, Any}(
        "bus_i" => number, "bus_type" => bus_type, "area" => 1, "zone" => 1,
        "base_kv" => 138.0, "va" => 0.0, "vm" => 1.0, "vmin" => 0.9, "vmax" => 1.1,
        "name" => "b$number",
    )
    data = Dict{String, Any}(
        "bus" => Dict{String, Any}("1" => bus_d(1, 3), "2" => bus_d(2, 1)),
    )
    switch_d(rating) = merge(
        Dict{String, Any}(
            "f_bus" => 1, "t_bus" => 2, "state" => 1, "r" => 0.0, "x" => 1e-4,
            "active_power_flow" => 0.0, "reactive_power_flow" => 0.0,
            "discrete_branch_type" => 0, "source_id" => ["switch", 1, 2, "1"],
            "index" => 1,
        ),
        rating,
    )
    for (rating, expected) in (
        (Dict{String, Any}(), (PFP.INFINITE_BOUND * 50.0, PFP.ABSENT, PFP.ABSENT)),
        (
            Dict{String, Any}("rating" => 0.0, "rating_b" => 0.0, "rating_c" => 75.0),
            (PFP.INFINITE_BOUND * 50.0, PFP.ABSENT, 75.0),
        ),
        (
            Dict{String, Any}("rating" => 80.0, "rating_b" => 90.0, "rating_c" => 0.0),
            (80.0, 90.0, PFP.ABSENT),
        ),
    )
        sys = PFP.OpenAPISystem(50.0)
        data["switch"] = Dict{String, Any}("1" => switch_d(rating))
        PFP.read_loadzones!(sys, data)
        PFP.read_bus!(sys, data)
        PFP.read_switch_breaker!(sys, data)
        switch = only(PFP.get_components(sys, "DiscreteControlledACBranch"))
        @test PFP.get_value(switch, :rating) == expected[1]
        @test isequal(PFP.get_value(switch, :rating_b), expected[2])
        @test isequal(PFP.get_value(switch, :rating_c), expected[3])
    end
end

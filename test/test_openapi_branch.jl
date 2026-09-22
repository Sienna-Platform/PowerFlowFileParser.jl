"""Find the `TransformerCircuit`/`Line`/dc-line-shaped component of `type_name` whose
`:arc` connects pm bus numbers `from_number`/`to_number`. `add_arc!` is idempotent — it
only registers a new arc when the pair is not already known — so calling it here is a
side-effect-free lookup for an arc a reader already created."""
function _component_between(
    sys,
    type_name::AbstractString,
    from_number::Int,
    to_number::Int,
)
    reg = PFP.get_registry(sys)
    from_id = PFP.get_bus_id(reg, from_number)
    to_id = PFP.get_bus_id(reg, to_number)
    arc_id = PFP.add_arc!(sys, from_id, to_id)
    for c in PFP.get_components(sys, type_name)
        if PFP.get_value(c, :arc) == arc_id
            return c
        end
    end
    error("no $type_name between pm bus $from_number and $to_number")
end

function _transformer_circuit_between(sys, from_number::Int, to_number::Int)
    return _component_between(sys, "TransformerCircuit", from_number, to_number)
end

"""A single registered `ACBus` at pm bus `number`, for tests that exercise a `make_*!`/
`_make_transformer_circuit!` maker directly rather than through `build_openapi_system`."""
function _register_bus!(sys::PFP.OpenAPISystem, number::Int, name::AbstractString)
    reg = PFP.get_registry(sys)
    bus = PFP.stage(PFP.PC.ACBus)
    id = PFP.register_bus!(reg, number, name)
    PFP.set_value!(bus, :id, id)
    PFP.set_value!(bus, :number, number)
    PFP.set_value!(bus, :name, name)
    PFP.set_value!(bus, :available, true)
    PFP.set_value!(bus, :bustype, "PQ")
    PFP.set_value!(bus, :base_voltage, 100.0, "kV")
    PFP.set_value!(bus, :angle, 0.0, "rad")
    PFP.set_value!(bus, :magnitude, 1.0, "pu")
    PFP.set_value!(bus, :voltage_limits, (min = 0.9, max = 1.1), "pu")
    PFP.add_component!(sys, bus)
    return id
end

"""The `TwoWindingTransformer` whose `:circuit` matches `circuit`'s id."""
function _two_winding_transformer_for(sys, circuit)
    circuit_id = PFP.get_value(circuit, :id)
    for t in PFP.get_components(sys, "TwoWindingTransformer")
        if PFP.get_value(t, :circuit) == circuit_id
            return t
        end
    end
    error("no TwoWindingTransformer references circuit id=$circuit_id")
end

@testset "Line: r/x/b are pu-by-convention passthrough, ratings/flows are ×baseMVA" begin
    pm = fourteen_bus_pm_data()
    sys = PFP.build_openapi_system(pm)
    d = only(
        v for v in values(pm.data["branch"]) if
        v["f_bus"] == 102 && v["t_bus"] == 104,
    )
    @test !d["transformer"]

    line = _component_between(sys, "Line", 102, 104)
    @test PFP.get_value(line, :available)
    @test PFP.get_value(line, :r) == d["br_r"]
    @test PFP.get_value(line, :x) == d["br_x"]
    @test _matches_nt(PFP.get_value(line, :b), (from = d["b_fr"], to = d["b_to"]))
    @test PFP.get_value(line, :base_power) == 100.0
    @test PFP.get_value(line, :rating) ≈ d["rate_a"] * 100.0
    @test _matches_nt(
        PFP.get_value(line, :angle_limits),
        (min = d["angmin"], max = d["angmax"]),
    )
    @test PFP.get_value(line, :active_power_flow) == 0.0
    @test PFP.get_value(line, :reactive_power_flow) == 0.0
end

@testset "Line: rating is per-unit-on-own-base_power under COMPONENT_BASE" begin
    # NATURAL_UNITS stores rating = d["rate_a"] * base_power (own base_power, always the
    # system base for a Line -- see `_resolve_base_power`). COMPONENT_BASE divides that back
    # by the same base_power, so the document should carry PowerModels' raw per-unit
    # `rate_a` verbatim; r/x/b are pu-by-convention and untouched either way.
    pm = fourteen_bus_pm_data()
    sys = PFP.build_openapi_system(pm; power_units = "COMPONENT_BASE")
    d = only(
        v for v in values(pm.data["branch"]) if
        v["f_bus"] == 102 && v["t_bus"] == 104,
    )
    line = _component_between(sys, "Line", 102, 104)
    @test PFP.get_value(line, :r) == d["br_r"]
    @test PFP.get_value(line, :x) == d["br_x"]
    @test PFP.get_value(line, :base_power) == 100.0
    @test PFP.get_value(line, :rating) ≈ d["rate_a"]
end

@testset "TwoWindingTransformer + TransformerCircuit: r/x device-base passthrough, rating/flow ×circuit base_power" begin
    pm = fourteen_bus_pm_data()
    sys = PFP.build_openapi_system(pm)
    d = only(
        v for v in values(pm.data["branch"]) if
        v["f_bus"] == 109 && v["t_bus"] == 104,
    )
    @test d["transformer"]
    @test d["base_power"] == 100.0  # coincides with sys_mbase in this fixture

    circuit = _transformer_circuit_between(sys, 109, 104)
    @test PFP.get_value(circuit, :available)
    @test PFP.get_value(circuit, :parameter_units) == "COMPONENT_BASE"
    @test PFP.get_value(circuit, :r) == d["br_r"]
    @test PFP.get_value(circuit, :x) == d["br_x"]
    @test PFP.get_value(circuit, :tap) == d["tap"]
    @test PFP.get_value(circuit, :alpha) == d["shift"]
    @test PFP.get_value(circuit, :base_power) == d["base_power"]
    @test PFP.get_value(circuit, :base_voltage_primary) == d["base_voltage_from"]
    @test PFP.get_value(circuit, :base_voltage_secondary) == d["base_voltage_to"]
    # rating is per-unit-on-system-base in the raw pm dict (PowerModels' generic branch
    # correction) but the circuit's rating field is component-base pu (PSY.CU); this fixture
    # cannot distinguish the two bases (base_power == sys_mbase) — the synthetic cases in
    # test_openapi_transformer_discriminators.jl do.
    @test PFP.get_value(circuit, :rating) ≈ d["rate_a"] * d["base_power"]
    @test PFP.get_value(circuit, :active_power_flow) == 0.0
    @test PFP.get_value(circuit, :reactive_power_flow) == 0.0
    # COD1 = 0 => FIXED; RMI1/RMA1/VMI1/VMA1 are the schema defaults, present verbatim.
    @test PFP.get_value(circuit, :control_objective) == "FIXED"
    @test _matches_nt(
        PFP.get_value(circuit, :control_limits),
        (min = d["RMI1"], max = d["RMA1"]),
    )
    @test _matches_nt(
        PFP.get_value(circuit, :controlled_quantity_limits),
        (min = d["VMI1"], max = d["VMA1"]),
    )
    @test PFP.get_value(circuit, :number_of_tap_positions) == Int(d["NTP1"])

    transformer = _two_winding_transformer_for(sys, circuit)
    @test PFP.get_value(transformer, :admittance_units) == "COMPONENT_BASE"
    @test _matches_nt(
        PFP.get_value(transformer, :magnetizing_shunt),
        (real = d["g_fr"], imag = d["b_fr"]),
    )
end

@testset "TransformerCircuit: rating/flow are per-unit-on-own-base_power under COMPONENT_BASE, r/x/magnetizing_shunt untouched" begin
    # NATURAL_UNITS stores rating = d["rate_a"] * d["base_power"] (the circuit's own base,
    # not necessarily sys_mbase). COMPONENT_BASE divides that back by the same base_power, so
    # the document should carry PowerModels' raw per-unit `rate_a` verbatim. r/x/
    # magnetizing_shunt are always COMPONENT_BASE pu already (their own `parameter_units`/
    # `admittance_units` discriminators, independent of the run's power_units) and
    # must not move at all between the two documents.
    pm = fourteen_bus_pm_data()
    sys_natural = PFP.build_openapi_system(pm)
    sys_device = PFP.build_openapi_system(pm; power_units = "COMPONENT_BASE")
    d = only(
        v for v in values(pm.data["branch"]) if
        v["f_bus"] == 109 && v["t_bus"] == 104,
    )

    circuit = _transformer_circuit_between(sys_device, 109, 104)
    @test PFP.get_value(circuit, :r) == d["br_r"]
    @test PFP.get_value(circuit, :x) == d["br_x"]
    @test PFP.get_value(circuit, :base_power) == d["base_power"]
    @test PFP.get_value(circuit, :rating) ≈ d["rate_a"]
    @test PFP.get_value(circuit, :active_power_flow) == 0.0

    transformer = _two_winding_transformer_for(sys_device, circuit)
    natural_circuit = _transformer_circuit_between(sys_natural, 109, 104)
    natural_transformer = _two_winding_transformer_for(sys_natural, natural_circuit)
    device_shunt = PFP.get_value(transformer, :magnetizing_shunt)
    natural_shunt = PFP.get_value(natural_transformer, :magnetizing_shunt)
    @test device_shunt.real == natural_shunt.real
    @test device_shunt.imag == natural_shunt.imag
end

@testset "ThreeWindingTransformer: three circuits, unbounded (zero) ratings become INFINITE_BOUND, no rating scaling" begin
    pm = fourteen_bus_pm_data()
    sys = PFP.build_openapi_system(pm)
    d = only(v for v in values(pm.data["3w_transformer"]) if v["bus_primary"] == 109)
    @test d["rating_primary"] == 0.0  # unbounded in the raw record

    transformer = only(
        t for t in PFP.get_components(sys, "ThreeWindingTransformer") if
        PFP.get_value(
            _component_between(sys, "TransformerCircuit", d["bus_primary"], d["star_bus"]),
            :id,
        ) == PFP.get_value(t, :primary_circuit)
    )
    primary = _component_between(sys, "TransformerCircuit", d["bus_primary"], d["star_bus"])
    secondary =
        _component_between(sys, "TransformerCircuit", d["bus_secondary"], d["star_bus"])
    tertiary =
        _component_between(sys, "TransformerCircuit", d["bus_tertiary"], d["star_bus"])

    # rating_primary/secondary/tertiary are ALREADY natural MVA in the pm dict (a custom,
    # non-PM-native section psse.jl populates directly from RATA1/RATB1/RATC1) — the
    # unbounded (zero) sentinel is used AS-IS, not multiplied by any base.
    @test PFP.get_value(primary, :rating) == PFP.INFINITE_BOUND
    @test PFP.get_value(secondary, :rating) == PFP.INFINITE_BOUND
    @test PFP.get_value(tertiary, :rating) == PFP.INFINITE_BOUND
    @test PFP.get_value(primary, :active_power_flow) == 0.0
    @test PFP.get_value(primary, :reactive_power_flow) == 0.0

    @test PFP.get_value(primary, :r) == d["r_primary"]
    @test PFP.get_value(primary, :base_power) == d["base_power_12"]
    @test PFP.get_value(primary, :base_voltage_primary) == d["base_voltage_primary"]
    @test PFP.get_value(primary, :base_voltage_secondary) == d["base_voltage_primary"]
    @test PFP.get_value(secondary, :base_voltage_primary) == d["base_voltage_secondary"]
    @test PFP.get_value(tertiary, :base_voltage_primary) == d["base_voltage_tertiary"]

    @test PFP.get_value(transformer, :star_bus) ==
          PFP.get_bus_id(PFP.get_registry(sys), d["star_bus"])
    @test PFP.get_value(transformer, :parameter_units) == "COMPONENT_BASE"
    @test PFP.get_value(transformer, :r_12) == d["r_12"]
    @test PFP.get_value(transformer, :base_power_12) == d["base_power_12"]
    @test PFP.get_value(transformer, :admittance_units) == "COMPONENT_BASE"
    @test _matches_nt(
        PFP.get_value(transformer, :magnetizing_shunt),
        (real = d["g"], imag = d["b"]),
    )
end

@testset "matpower: tap!=1/shift!=0 detects a TwoWindingTransformer; base_power always equals sys_mbase" begin
    pm = PFP.PowerModelsData(joinpath(MATPOWER_DIR, "case5.m"))
    sys = PFP.build_openapi_system(pm)
    d5 = pm.data["branch"][5]
    @test d5["transformer"] && d5["tap"] == 1.05

    circuit = _transformer_circuit_between(sys, d5["f_bus"], d5["t_bus"])
    @test PFP.get_value(circuit, :tap) == 1.05
    @test PFP.get_value(circuit, :base_power) == pm.data["baseMVA"]
    # A matpower Line: branch 4 has tap=1.0, shift=0.0, transformer=false.
    d4 = pm.data["branch"][4]
    @test !d4["transformer"] && d4["tap"] == 1.0 && d4["shift"] == 0.0
    line = _component_between(sys, "Line", d4["f_bus"], d4["t_bus"])
    @test PFP.get_value(line, :r) == d4["br_r"]
    @test length(PFP.get_components(sys, "TwoWindingTransformer")) == 2
    @test length(PFP.get_components(sys, "Line")) == 5
end

@testset "zero-impedance branch becomes a DiscreteControlledACBranch of type SWITCH" begin
    data = fourteen_bus_pm_data().data
    d = first(values(data["branch"]))
    zero_z = merge(
        Dict{String, Any}(k => v for (k, v) in d),
        Dict{String, Any}(
            "br_r" => 0.0, "br_x" => 0.0, "transformer" => false, "f_bus" => d["f_bus"],
            "t_bus" => d["t_bus"], "index" => 999, "name" => "zero_z_test",
        ),
    )
    synthetic = deepcopy(data)
    synthetic["branch"] = Dict{String, Any}("999" => zero_z)
    delete!(synthetic, "3w_transformer")
    delete!(synthetic, "dcline")
    delete!(synthetic, "vscline")
    delete!(synthetic, "interarea_transfer")
    delete!(synthetic, "shunt")
    delete!(synthetic, "switched_shunt")
    delete!(synthetic, "facts")

    sys = PFP.OpenAPISystem(Float64(synthetic["baseMVA"]))
    PFP.read_loadzones!(sys, synthetic)
    PFP.read_bus!(sys, synthetic)
    Test.@test_logs (:warn, r"zero impedance") PFP.read_branches!(sys, synthetic)

    @test isempty(PFP.get_components(sys, "Line"))
    switch = only(PFP.get_components(sys, "DiscreteControlledACBranch"))
    @test PFP.get_value(switch, :discrete_branch_type) == "SWITCH"
    @test PFP.get_value(switch, :branch_status) ==
          (PFP.get_value(switch, :available) ? "CLOSED" : "OPEN")
end

@testset "zero-impedance TRANSFORMER stays a transformer, not a switch" begin
    # The zero-impedance shortcut above must not fire on a TRANSFORMER record: a
    # transformer with R1-2 = X1-2 = 0 is still a transformer, and misrouting it to
    # `make_switch_from_zero_impedance_branch!` also slips past the `transformer=true but
    # detected as a Line` guard, which only checks for `:line`. Port of
    # PowerSystems.jl 00003f06d.
    data = fourteen_bus_pm_data().data
    d = first(v for v in values(data["branch"]) if v["transformer"])
    @test PFP._branch_type_psse(d, "as_parsed") == :transformer

    zero_z = merge(
        Dict{String, Any}(k => v for (k, v) in d),
        Dict{String, Any}("br_r" => 0.0, "br_x" => 0.0, "index" => 998),
    )
    @test PFP._branch_type_psse(zero_z, "zero_z_transformer") == :transformer

    synthetic = deepcopy(data)
    synthetic["branch"] = Dict{String, Any}("998" => zero_z)
    for key in
        ("3w_transformer", "dcline", "vscline", "interarea_transfer", "shunt",
        "switched_shunt", "facts")
        delete!(synthetic, key)
    end

    sys = PFP.OpenAPISystem(Float64(synthetic["baseMVA"]))
    PFP.read_loadzones!(sys, synthetic)
    PFP.read_bus!(sys, synthetic)
    PFP.read_branches!(sys, synthetic)

    @test isempty(PFP.get_components(sys, "DiscreteControlledACBranch"))
    circuit = only(PFP.get_components(sys, "TransformerCircuit"))
    @test PFP.get_value(circuit, :r) == 0.0
    @test PFP.get_value(circuit, :x) == 0.0
    @test !isnothing(_two_winding_transformer_for(sys, circuit))
end

@testset "TransformerCircuit.controlled_quantity_limits passes through UNSCALED under COMPONENT_BASE for a power-flow-family control_objective" begin
    # Regression: `controlled_quantity_limits`'s schema quantity DOES switch with
    # `control_objective` (pu for VOLTAGE-family objectives, MW/MVAr for ACTIVE_POWER_FLOW/
    # REACTIVE_POWER_FLOW/CONTROL_OF_DC_LINE-family ones), which made a first cut of the
    # COMPONENT_BASE registry classify it `:dynamic` (converting the power-flow-family
    # branches by the circuit's own base_power). That was wrong: PowerSystems' own
    # `to_openapi` calls the SAME unscaled `_minmax_po(get_controlled_quantity_limits(...))`
    # in BOTH `ComponentBaseUnit` and `NaturalUnit` (export_handwritten.jl:166-167, :195-196) —
    # this field never scales with the document convention, regardless of
    # `control_objective`. Invisible on the 14-bus fixture because every circuit there is
    # `control_objective = "FIXED"` (already `:skip` either way) — this test uses
    # `COD1 = 3` ("ACTIVE_POWER_FLOW", MW-declared) specifically to exercise the branch
    # the bug was in.
    #
    # base_power = 50, sys_mbase = 100 (base_conversion-sensitive, same discipline as the
    # storage/generator COMPONENT_BASE tests): active_power_flow/reactive_power_flow DO
    # convert (10.0/50.0 = 0.2, 5.0/50.0 = 0.1) so this test also proves the fix did not
    # collaterally stop scaling this circuit's other power fields. controlled_quantity_limits
    # must come out exactly (50.0, 150.0) -- if it were wrongly divided by base_power = 50
    # it would read (1.0, 3.0) instead, a clearly different and wrong number.
    sys = PFP.OpenAPISystem(100.0; power_units = "COMPONENT_BASE")
    reg = PFP.get_registry(sys)
    from_id = _register_bus!(sys, 1, "b1")
    to_id = _register_bus!(sys, 2, "b2")
    d = Dict{String, Any}(
        "tap" => 1.0, "shift" => 0.0,
        "COD1" => 3, "RMI1" => -10.0, "RMA1" => 10.0, "VMI1" => 50.0, "VMA1" => 150.0,
    )
    PFP._make_transformer_circuit!(
        sys, reg, d, from_id, to_id, "test_xfmr";
        tap_key = "tap", angle_key = "shift", control_suffix = 1, available = true,
        r = 0.01, x = 0.05, rating = 100.0, rating_b = nothing, rating_c = nothing,
        base_power = 50.0, base_voltage_primary = 100.0, base_voltage_secondary = 100.0,
        active_power_flow = 10.0, reactive_power_flow = 5.0,
    )
    PFP.apply_device_base_conversion!(sys)
    circuit = only(PFP.get_components(sys, "TransformerCircuit"))
    @test PFP.get_value(circuit, :control_objective) == "ACTIVE_POWER_FLOW"
    @test PFP.get_value(circuit, :controlled_quantity_limits).min == 50.0
    @test PFP.get_value(circuit, :controlled_quantity_limits).max == 150.0
    @test PFP.get_value(circuit, :active_power_flow) ≈ 0.2
    @test PFP.get_value(circuit, :reactive_power_flow) ≈ 0.1
    @test PFP.get_value(circuit, :base_power) == 50.0
end

@testset "TwoWindingTransformer: same buses and circuit id keep the first record, drop the rest" begin
    # Two TRANSFORMER records join buses 201-202 with CKT '1 ', so both default to the name
    # TAP_201-LOW_202-i_1. The record read first (XFMR_A, x = 0.05) is kept; the second
    # (XFMR_B, x = 0.06) is dropped with a warning. A third transformer 203-204 reuses the
    # bus names TAP/LOW but read_bus! already suffixes repeated bus names with the bus
    # number, so it never collided and must stay untouched.
    file = joinpath(@__DIR__, "fixtures", "synthetic_v35_duplicate_transformer_names.raw")
    sys = @test_logs(
        (
            :warn,
            r"TwoWindingTransformer TAP_201-LOW_202-i_1 already exists.*Keeping the record read first and dropping this one",
        ),
        match_mode = :any,
        PFP.build_openapi_system(PFP.PowerModelsData(file)),
    )
    names = sort([
        PFP.get_value(t, :name) for t in PFP.get_components(sys, "TwoWindingTransformer")
    ])
    @test names == ["TAP_201-LOW_202-i_1", "TAP_203-LOW_204-i_1"]
    # one circuit per surviving transformer, and the 201-202 survivor is the first record
    @test length(PFP.get_components(sys, "TransformerCircuit")) == 2
    kept = _transformer_circuit_between(sys, 201, 202)
    @test PFP.get_value(kept, :x) == 0.05
    @test PFP.get_value(kept, :rating) == 40.0
    @test length(PFP.get_components(sys, "Line")) == 2
end

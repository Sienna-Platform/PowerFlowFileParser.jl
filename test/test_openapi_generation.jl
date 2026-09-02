# The oracle bug-compatible sites (renewable rating double `base_conversion`, generic
# battery's raw `thermal_rating` as both `rating` and `base_power`) are invisible on every
# real fixture on hand: each states `mbase`/`thermal_rating` equal to the system base,
# making `base_conversion == 1.0` and collapsing the bug into the non-buggy answer. Both
# are instead verified against a synthetic generator with `mbase != sys_mbase`, whose
# expected numbers were cross-checked against PSCB's real oracle on identical input.

function _bus_component(sys, number::Int)
    return only(
        b for b in PFP.get_components(sys, "ACBus") if PFP.get_value(b, :number) == number
    )
end

"""A single registered `ACBus`, for tests that exercise a `make_*!`/`_make_generator!`
maker directly rather than through `build_openapi_system`."""
function _register_test_bus!(sys::PFP.OpenAPISystem)
    reg = PFP.get_registry(sys)
    bus = PFP.PO.ACBus()
    id = PFP.register_bus!(reg, 1, "b1")
    PFP.set_value!(bus, :id, id)
    PFP.set_value!(bus, :number, 1)
    PFP.set_value!(bus, :name, "b1")
    PFP.set_value!(bus, :available, true)
    PFP.set_value!(bus, :bustype, "PQ")
    PFP.set_value!(bus, :base_voltage, 100.0, "kV")
    PFP.set_value!(bus, :angle, 0.0, "rad")
    PFP.set_value!(bus, :magnitude, 1.0, "pu")
    PFP.set_value!(bus, :voltage_limits, (min = 0.9, max = 1.1), "pu")
    PFP.add_component!(sys, bus)
    return id
end

@testset "read_generation! on the 14-bus fixture makes only ThermalStandard" begin
    sys = PFP.build_openapi_system(fourteen_bus_pm_data())
    @test length(PFP.get_components(sys, "ThermalStandard")) == 7
    for t in (
        "HydroDispatch", "RenewableDispatch", "RenewableNonDispatch",
        "SynchronousCondenser", "EnergyReservoirStorage",
    )
        @test isempty(PFP.get_components(sys, t))
    end
end

@testset "ThermalStandard fields convert system pu to natural units, mbase == sys_mbase" begin
    sys = PFP.build_openapi_system(fourteen_bus_pm_data())
    data = fourteen_bus_pm_data().data
    sys_mbase = PFP.get_base_power(sys)
    for gen in PFP.get_components(sys, "ThermalStandard")
        d = only(
            v for v in values(data["gen"]) if
            PFP._get_pm_dict_name(v) == PFP.get_value(gen, :name)
        )
        mbase = d["mbase"]
        base_conversion = sys_mbase / mbase
        @test PFP.get_value(gen, :active_power) ≈ d["pg"] * base_conversion * mbase
        @test PFP.get_value(gen, :reactive_power) ≈ d["qg"] * base_conversion * mbase
        @test PFP.get_value(gen, :rating) ≈
              sqrt(d["pmax"]^2 + d["qmax"]^2) * base_conversion * mbase
        @test PFP.get_value(gen, :active_power_limits).min ≈
              d["pmin"] * base_conversion * mbase
        @test PFP.get_value(gen, :active_power_limits).max ≈
              d["pmax"] * base_conversion * mbase
        @test PFP.get_value(gen, :base_power) == mbase
        if iszero(d["gen_status"])
            @test PFP.get_value(gen, :status) == "OFFLINE"
        else
            @test PFP.get_value(gen, :status) == "ONLINE"
        end
        @test PFP.get_value(gen, :prime_mover_type) == "OT"
        @test PFP.get_value(gen, :fuel) == "OTHER"
        bus = _bus_component(sys, d["gen_bus"])
        @test PFP.get_value(gen, :bus) == PFP.get_value(bus, :id)
    end
end

@testset "ThermalStandard fields are per-unit-on-own-mbase under COMPONENT_BASE, mbase != sys_mbase" begin
    # sys_mbase=100, mbase=50: every 14-bus generator states mbase == sys_mbase (see this
    # file's header), so COMPONENT_BASE's own-base division is only distinguishable from the
    # system base on a synthetic generator, same reason the "Bug-compatible" tests below
    # build one directly rather than through build_openapi_system.
    #
    # NATURAL_UNITS would store natural_MW = pg * base_conversion * mbase, where
    # base_conversion = sys_mbase / mbase (see the mbase == sys_mbase testset above).
    # COMPONENT_BASE divides that by the generator's own mbase: pu = natural_MW / mbase =
    # pg * base_conversion = pg * (sys_mbase / mbase) -- i.e. the raw system-per-unit value
    # rescaled onto the device's own base, independent of `mbase`'s absolute value.
    sys = PFP.OpenAPISystem(100.0; power_units = "COMPONENT_BASE")
    reg = PFP.get_registry(sys)
    bus = _register_test_bus!(sys)
    d = Dict{String, Any}(
        "mbase" => 50.0, "gen_status" => true, "pg" => 0.6, "qg" => 0.1,
        "pmax" => 0.8, "pmin" => 0.0, "qmax" => 0.3, "qmin" => -0.3,
    )
    PFP.make_thermal_generator!(sys, reg, bus, d, "g1", 100.0)
    PFP.apply_device_base_conversion!(sys)
    gen = only(PFP.get_components(sys, "ThermalStandard"))
    base_conversion = 100.0 / 50.0
    @test PFP.get_value(gen, :active_power) ≈ d["pg"] * base_conversion
    @test PFP.get_value(gen, :reactive_power) ≈ d["qg"] * base_conversion
    @test PFP.get_value(gen, :active_power_limits).min ≈ d["pmin"] * base_conversion
    @test PFP.get_value(gen, :active_power_limits).max ≈ d["pmax"] * base_conversion
    @test PFP.get_value(gen, :reactive_power_limits).min ≈ d["qmin"] * base_conversion
    @test PFP.get_value(gen, :reactive_power_limits).max ≈ d["qmax"] * base_conversion
    @test PFP.get_value(gen, :base_power) == 50.0
    # ramp_limits (quantity ActivePowerChangeRate, MW/min) belongs to this pass's
    # power-family quantity set: with no ramp_agc/ramp_10/ramp_30 in `d`,
    # calculate_ramp_limit falls back to (up = down = abs(pmax)) *without* base_conversion
    # (`calculate_ramp_limit`'s own documented inconsistency) -- natural_MW = pmax * mbase,
    # so COMPONENT_BASE's pu = natural_MW / mbase collapses back to plain `pmax`.
    @test PFP.get_value(gen, :ramp_limits).up ≈ d["pmax"]
    @test PFP.get_value(gen, :ramp_limits).down ≈ d["pmax"]
end

@testset "an out-of-service Matpower generator maps to OFFLINE, an in-service one to ONLINE" begin
    base_d = Dict{String, Any}(
        "mbase" => 100.0, "pg" => 0.0, "qg" => 0.0, "pmax" => 10.0, "pmin" => 0.0,
        "qmax" => 5.0, "qmin" => -5.0,
    )
    for (gen_status, expected) in ((0, "OFFLINE"), (1, "ONLINE"))
        sys = PFP.OpenAPISystem(100.0)
        reg = PFP.get_registry(sys)
        bus = _register_test_bus!(sys)
        d = merge(base_d, Dict{String, Any}("gen_status" => gen_status))
        PFP.make_thermal_generator!(sys, reg, bus, d, "g1", 100.0)
        gen = only(PFP.get_components(sys, "ThermalStandard"))
        @test PFP.get_value(gen, :status) == expected
    end
end

@testset "every 14-bus generator's real POLYNOMIAL cost (model=2) matches the hand-derived coefficients" begin
    # Every gen has cost=[100.0, 0.0], ncost=2, mbase == sys_mbase == 100: PowerModels'
    # own per-unit correction scaled the synthetic PSS/E default (proportional_term=1.0,
    # constant_term=0.0) by mva_base, and PSCB's `/ sys_mbase^i` undoes exactly that.
    sys = PFP.build_openapi_system(fourteen_bus_pm_data())
    for gen in PFP.get_components(sys, "ThermalStandard")
        # `set_value!` routes `operation_cost` through OpenAPI.jl's oneOf `setproperty!`,
        # which wraps the assigned `PC.ThermalGenerationCost` in a
        # `ThermalStandardOperationCost(value = ...)` — unwrap with `.value`, matching
        # PowerTableDataParser's own test convention.
        cost = PFP.get_value(gen, :operation_cost).value
        @test cost.fixed == 0.0
        @test cost.start_up == 0.0
        @test cost.shut_down == 0.0
        variable = cost.variable_operation_cost
        @test variable.power_units == "COMPONENT_BASE"
        function_data = variable.value_curve.value.function_data.value
        @test function_data.quadratic_term == 0.0
        @test function_data.proportional_term == 1.0
        @test function_data.constant_term == 0.0
    end
end

@testset "a real POLYNOMIAL cost (model=2) from case5.m matches by-hand division" begin
    pm = PFP.PowerModelsData(joinpath(MATPOWER_DIR, "case5.m"))
    sys = PFP.build_openapi_system(pm)
    data = pm.data
    sys_mbase = data["baseMVA"]
    for gen in PFP.get_components(sys, "ThermalStandard")
        d = only(
            v for v in values(data["gen"]) if
            PFP._get_pm_dict_name(v) == PFP.get_value(gen, :name)
        )
        c1, c0 = d["cost"]
        expected_proportional = c1 / sys_mbase
        cost = PFP.get_value(gen, :operation_cost).value
        fd = cost.variable_operation_cost.value_curve.value.function_data.value
        @test fd.proportional_term ≈ expected_proportional
        @test fd.constant_term == 0.0
        @test cost.fixed == 0.0
    end
end

@testset "a real PIECEWISE_LINEAR cost (model=1, case5_pwlc.m) shifts points by the fixed cost" begin
    pm = PFP.PowerModelsData(joinpath(MATPOWER_DIR, "case5_pwlc.m"))
    sys = PFP.build_openapi_system(pm)
    data = pm.data
    for gen in PFP.get_components(sys, "ThermalStandard")
        d = only(
            v for v in values(data["gen"]) if
            PFP._get_pm_dict_name(v) == PFP.get_value(gen, :name)
        )
        cost_component = d["cost"]
        power_p = [c for (ix, c) in enumerate(cost_component) if isodd(ix)]
        cost_p = [c for (ix, c) in enumerate(cost_component) if iseven(ix)]
        points = collect(zip(power_p, cost_p))
        first_x, first_y = first(points)
        slope = (points[2][2] - points[1][2]) / (points[2][1] - points[1][1])
        fixed = max(0.0, first_y - slope * first_x)

        cost = PFP.get_value(gen, :operation_cost).value
        @test cost.fixed ≈ fixed
        fd = cost.variable_operation_cost.value_curve.value.function_data.value
        @test fd.function_type == "PIECEWISE_LINEAR"
        @test length(fd.points) == length(points)
        for (p, (x, y)) in zip(fd.points, points)
            @test p.x ≈ x
            @test p.y ≈ y - fixed
        end
    end
end

@testset "no \"model\" key gives a zero natural-unit cost (PSCB's own fallback)" begin
    d = Dict{String, Any}(
        "mbase" => 100.0, "gen_status" => true, "pg" => 2.0, "qg" => -0.5,
        "pmax" => 99.99, "pmin" => -99.99, "qmax" => 99.99, "qmin" => -99.99,
    )
    cost = @test_logs (:warn, r"cost data not included") PFP.make_thermal_cost(
        "g",
        d,
        100.0,
    )
    @test cost.fixed == 0.0
    @test cost.start_up == 0.0
    @test cost.shut_down == 0.0
    @test cost.variable_operation_cost.power_units == "NATURAL_UNITS"
    fd = cost.variable_operation_cost.value_curve.value.function_data.value
    @test fd.function_type == "LINEAR"
    @test fd.proportional_term == 0.0
    @test fd.constant_term == 0.0
end

@testset "a cost model above degree two throws" begin
    d = Dict{String, Any}(
        "model" => 2, "cost" => [1.0, 1.0, 1.0, 1.0, 0.0], "ncost" => 4,
        "startup" => 0.0, "shutdown" => 0.0,
    )
    @test_throws IS.DataFormatError PFP.make_thermal_cost("g", d, 100.0)
end

@testset "an unsupported cost model throws" begin
    d = Dict{String, Any}(
        "model" => 3, "cost" => [1.0, 0.0], "ncost" => 2, "startup" => 0.0,
        "shutdown" => 0.0,
    )
    @test_throws IS.DataFormatError PFP.make_thermal_cost("g", d, 100.0)
end

@testset "calculate_gen_rating scales by base_conversion, with the p.u.-of-device zero fallback" begin
    @test PFP.calculate_gen_rating(3.0, 4.0, 2.0) ≈ 5.0 * 2.0
    @test (@test_logs (:warn, r"Changing to 1.0") PFP.calculate_gen_rating(
        0.0,
        0.0,
        2.0,
    )) ==
          1.0
end

@testset "calculate_ramp_limit prefers ramp_agc, then ramp_10, then ramp_30, then pmax" begin
    @test PFP.calculate_ramp_limit(Dict("ramp_agc" => 1.0, "pmax" => 9.0), "g") ==
          (up = 1.0, down = 1.0)
    @test PFP.calculate_ramp_limit(Dict("ramp_10" => 2.0, "pmax" => 9.0), "g") ==
          (up = 2.0, down = 2.0)
    @test PFP.calculate_ramp_limit(Dict("ramp_30" => 3.0, "pmax" => 9.0), "g") ==
          (up = 3.0, down = 3.0)
    @test PFP.calculate_ramp_limit(Dict("pmax" => 9.0), "g") == (up = 9.0, down = 9.0)
    @test isnothing(
        (@test_logs (:warn, r"Returning nothing") PFP.calculate_ramp_limit(
        Dict("pmax" => 0.0),
        "g",
    )),
    )
end

@testset "prime_mover_type and thermal_fuel apply PSCB's non-identity aliases" begin
    @test PFP.prime_mover_type("wind") == "WT"
    @test PFP.prime_mover_type("solar") == "PVe"
    @test PFP.prime_mover_type("HY") == "HY"
    @test PFP.thermal_fuel("ng") == "NATURAL_GAS"
    @test PFP.thermal_fuel("OTHER") == "OTHER"
end

@testset "get_generator_type falls back from (fuel, type) to (fuel, nothing)" begin
    @test PFP.get_generator_type("HYDRO", "SOMETHING_UNMAPPED", PFP.GENERATOR_MAPPING_PM) ==
          "HydroTurbine"
    @test PFP.get_generator_type("OTHER", "OT", PFP.GENERATOR_MAPPING_PM) ==
          "ThermalStandard"
    @test_throws IS.DataFormatError PFP.get_generator_type(
        "NOT_A_FUEL",
        "NOT_A_TYPE",
        PFP.GENERATOR_MAPPING_PM,
    )
end

@testset "Bug-compatible: renewable rating's double base_conversion (power_models_data.jl:872,885)" begin
    # Cross-checked directly against PSCB's real make_renewable_dispatch with this exact
    # input (mbase=50.0, sys_mbase=100.0, pmax=40.0, qmax=20.0): raw stored `rating` field
    # comes out 100.0 (device-base pu), and `get_rating(gen, PSY.NU)` on that real PSY
    # component returns 5000.0 — reproduced below bit for bit.
    sys = PFP.OpenAPISystem(100.0)
    reg = PFP.get_registry(sys)
    bus = _register_test_bus!(sys)
    d = Dict{String, Any}(
        "mbase" => 50.0, "gen_status" => true, "pg" => 10.0, "qg" => 2.0,
        "pmax" => 40.0, "pmin" => 0.0, "qmax" => 20.0, "qmin" => -20.0, "type" => "WIND",
    )
    @test_logs (:warn, r"rating is larger than base power") PFP.make_renewable_dispatch!(
        sys,
        reg,
        bus,
        d,
        "wind1",
        100.0,
    )
    gen = only(PFP.get_components(sys, "RenewableDispatch"))
    @test PFP.get_value(gen, :rating) ≈ 5000.0
    @test PFP.get_value(gen, :active_power) ≈ 1000.0
    @test PFP.get_value(gen, :reactive_power) ≈ 200.0
    @test PFP.get_value(gen, :base_power) == 50.0
end

@testset "Bug-compatible: make_generic_battery's raw thermal_rating (power_models_data.jl:944,951)" begin
    # Cross-checked directly against PSCB's real make_generic_battery with this exact
    # input: `get_rating(storage, PSY.NU)` on the real PSY component returns 0.0225
    # (0.15 used as both the raw rating and, via base_power, the device base it is then
    # exported against — reproduced below bit for bit), not the physically-intended 0.15.
    sys = PFP.OpenAPISystem(100.0)
    reg = PFP.get_registry(sys)
    bus = _register_test_bus!(sys)
    d = Dict{String, Any}(
        "energy_rating" => 50.0, "energy" => 25.0, "status" => true,
        "thermal_rating" => 0.15, "ps" => 0.02, "charge_rating" => 0.05,
        "discharge_rating" => 0.05, "charge_efficiency" => 0.9,
        "discharge_efficiency" => 0.9, "qs" => 0.0, "qmin" => -0.05, "qmax" => 0.05,
    )
    PFP.make_storage!(sys, reg, bus, d, "bat1", 100.0)
    storage = only(PFP.get_components(sys, "EnergyReservoirStorage"))
    @test PFP.get_value(storage, :rating) ≈ 0.0225
    @test PFP.get_value(storage, :base_power) == 0.15
    @test PFP.get_value(storage, :active_power) ≈ 0.003
    @test PFP.get_value(storage, :storage_capacity) ≈ 7.5
    @test PFP.get_value(storage, :input_active_power_limits).min == 0.0
    @test PFP.get_value(storage, :input_active_power_limits).max ≈ 0.0075
    @test PFP.get_value(storage, :reactive_power_limits).min ≈ -0.0075
    @test PFP.get_value(storage, :reactive_power_limits).max ≈ 0.0075
    @test PFP.get_value(storage, :initial_storage_capacity_level) == 0.5
    @test PFP.get_value(storage, :prime_mover_type) == "BA"
    @test PFP.get_value(storage, :storage_technology_type) == "OTHER_CHEM"
end

@testset "EnergyReservoirStorage fields are per-unit-on-own-thermal_rating under COMPONENT_BASE, device base != system base" begin
    # Regression: storage_capacity's quantity (ElectricalEnergy) is only resolvable
    # through `energy_units`' instance-level discriminator. A COMPONENT_BASE pass that
    # treats every instance-dispatched field as "leave untouched" skips this conversion
    # silently instead of erroring. `own base_power` here is
    # `thermal_rating` (PSCB's bug-compatible battery convention, same as the
    # "Bug-compatible" testset above); sys_mbase = 100, thermal_rating = 50, so the two
    # bases genuinely differ and every quotient below is *not* 1.
    #
    # NATURAL_UNITS (`_natural_value(v, thermal_rating) = v * thermal_rating`, per
    # `make_storage!` above):
    #   storage_capacity = energy_rating * thermal_rating = 8.0 * 50.0 = 400.0
    #   rating            = thermal_rating * thermal_rating = 50.0 * 50.0 = 2500.0
    #   active_power      = ps * thermal_rating = 0.6 * 50.0 = 30.0
    #   input/output_active_power_limits.max = charge/discharge_rating * thermal_rating
    #   reactive_power    = qs * thermal_rating = 0.1 * 50.0 = 5.0
    #   reactive_power_limits = (qmin, qmax) .* thermal_rating
    # COMPONENT_BASE divides every one of those back by the SAME thermal_rating = 50.0,
    # collapsing each to the raw un-multiplied input value.
    sys = PFP.OpenAPISystem(100.0; power_units = "COMPONENT_BASE")
    reg = PFP.get_registry(sys)
    bus = _register_test_bus!(sys)
    d = Dict{String, Any}(
        "energy_rating" => 8.0, "energy" => 4.0, "status" => true,
        "thermal_rating" => 50.0, "ps" => 0.6, "charge_rating" => 0.3,
        "discharge_rating" => 0.4, "charge_efficiency" => 0.9,
        "discharge_efficiency" => 0.85, "qs" => 0.1, "qmin" => -0.2, "qmax" => 0.2,
    )
    PFP.make_storage!(sys, reg, bus, d, "bat1", 100.0)
    PFP.apply_device_base_conversion!(sys)
    storage = only(PFP.get_components(sys, "EnergyReservoirStorage"))
    @test PFP.get_value(storage, :base_power) == 50.0
    @test PFP.get_value(storage, :storage_capacity) ≈ d["energy_rating"]
    @test PFP.get_value(storage, :rating) ≈ d["thermal_rating"]
    @test PFP.get_value(storage, :active_power) ≈ d["ps"]
    @test PFP.get_value(storage, :input_active_power_limits).min == 0.0
    @test PFP.get_value(storage, :input_active_power_limits).max ≈ d["charge_rating"]
    @test PFP.get_value(storage, :output_active_power_limits).min == 0.0
    @test PFP.get_value(storage, :output_active_power_limits).max ≈ d["discharge_rating"]
    @test PFP.get_value(storage, :reactive_power) ≈ d["qs"]
    @test PFP.get_value(storage, :reactive_power_limits).min ≈ d["qmin"]
    @test PFP.get_value(storage, :reactive_power_limits).max ≈ d["qmax"]
    # Dimensionless / ratio fields: untouched by COMPONENT_BASE either way.
    @test PFP.get_value(storage, :initial_storage_capacity_level) == 0.5
end

@testset "COMPONENT_BASE conversion errors loudly on an unregistered instance-dispatched field" begin
    # Pins the structural guarantee: an
    # instance-level-discriminated field with no verdict in
    # `_DEVICEBASE_INSTANCE_DISPATCHED` must error, not silently fall through unconverted.
    # `TwoTerminalVSCLine.dc_setpoint_from` (governed by `dc_control_from`) is real and
    # instance-dispatched today but deliberately not registered -- this package's readers
    # never reach a document containing it without first hitting the recorded VSC
    # voltage-control gap (`_vsc_voltage_control_unsupported`), so it is exactly the kind
    # of "not yet classified" field the guard exists for.
    @test_throws ErrorException PFP._devicebase_classification(
        PFP.PO.TwoTerminalVSCLine(),
        "TwoTerminalVSCLine",
        :dc_setpoint_from,
    )
end

@testset "read_generation! on case5_strg.m builds real EnergyReservoirStorage entries" begin
    pm = PFP.PowerModelsData(joinpath(MATPOWER_DIR, "case5_strg.m"))
    sys = PFP.build_openapi_system(pm)
    data = pm.data
    @test length(PFP.get_components(sys, "EnergyReservoirStorage")) == 2
    for storage in PFP.get_components(sys, "EnergyReservoirStorage")
        d = only(
            v for v in values(data["storage"]) if
            PFP._get_pm_dict_name(v) == PFP.get_value(storage, :name)
        )
        thermal_rating = d["thermal_rating"]
        # thermal_rating == 1.0 in this real fixture, so the bug is numerically inert
        # here (1.0^2 == 1.0) — this locks in the code path runs end to end on real
        # data; the numeric distortion itself is covered by the synthetic test above.
        @test PFP.get_value(storage, :rating) ≈ thermal_rating * thermal_rating
        @test PFP.get_value(storage, :base_power) == thermal_rating
    end
end

@testset "Bug-compatible: make_hydro_reservoir produces a HydroDispatch (power_models_data.jl:814-852)" begin
    sys = PFP.OpenAPISystem(100.0)
    reg = PFP.get_registry(sys)
    bus = _register_test_bus!(sys)
    d = Dict{String, Any}(
        "mbase" => 100.0, "gen_status" => true, "pg" => 5.0, "qg" => 1.0,
        "pmax" => 20.0, "pmin" => 0.0, "qmax" => 10.0, "qmin" => -10.0,
        "type" => "HYDRO",
    )
    PFP.make_hydro_reservoir!(sys, reg, bus, d, "hy1", 100.0)
    @test isempty(PFP.get_components(sys, "HydroTurbine"))
    @test isempty(PFP.get_components(sys, "HydroReservoir"))
    hydro = only(PFP.get_components(sys, "HydroDispatch"))
    @test PFP.get_value(hydro, :name) == "hy1"
    @test PFP.get_value(hydro, :active_power) ≈ 500.0
end

@testset "get_generator_type resolving to EnergyReservoirStorage from \"gen\" is an error, not a skip" begin
    sys = PFP.OpenAPISystem(100.0)
    reg = PFP.get_registry(sys)
    bus = _register_test_bus!(sys)
    d = Dict{String, Any}("gen_status" => true, "mbase" => 100.0)
    @test_throws IS.DataFormatError PFP._make_generator!(
        Val(:EnergyReservoirStorage),
        sys,
        reg,
        bus,
        d,
        "storage_as_gen",
        100.0,
    )
end

@testset "an unmapped generator type throws" begin
    sys = PFP.OpenAPISystem(100.0)
    reg = PFP.get_registry(sys)
    bus = _register_test_bus!(sys)
    d = Dict{String, Any}()
    @test_throws IS.DataFormatError PFP._make_generator!(
        Val(:NotARealType),
        sys,
        reg,
        bus,
        d,
        "g",
        100.0,
    )
end

@testset "read_generation! requires a \"gen\" section" begin
    sys = PFP.OpenAPISystem(100.0)
    @test_throws IS.DataFormatError PFP.read_generation!(sys, Dict{String, Any}())
end

@testset "read_generation! on a source with no \"storage\" section at all does not error" begin
    sys = PFP.OpenAPISystem(100.0)
    reg = PFP.get_registry(sys)
    _register_test_bus!(sys)
    data = Dict{String, Any}("gen" => Dict{String, Any}())
    PFP.read_generation!(sys, data)
    @test isempty(PFP.get_components(sys, "ThermalStandard"))
end

@testset "a fresh 14-bus document with loads and generators round-trips through PC" begin
    sys = PFP.build_openapi_system(fourteen_bus_pm_data())
    PFP.PD.validate_document(PFP.get_document(sys))
    path = joinpath(mktempdir(), "fourteen_bus_gen.json")
    PFP.to_json(sys, path)
    doc = PFP.PD.read_document(path)
    @test length(PFP.PD.get_components(doc, "StandardLoad")) == 13
    @test length(PFP.PD.get_components(doc, "ThermalStandard")) == 7
end

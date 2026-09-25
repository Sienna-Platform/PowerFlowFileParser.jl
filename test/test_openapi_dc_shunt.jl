@testset "TwoTerminalLCCLine: custom PSS/E-native fields passthrough, native pf ×baseMVA" begin
    pm = fourteen_bus_pm_data()
    sys = PFP.build_openapi_system(pm)
    d = only(values(pm.data["dcline"]))
    line = only(PFP.get_components(sys, "TwoTerminalLCCLine"))

    @test PFP.get_value(line, :available) == d["available"]
    @test PFP.get_value(line, :active_power_flow) ≈ d["pf"] * 100.0
    @test PFP.get_value(line, :parameter_units) == "NATURAL_UNITS"
    @test PFP.get_value(line, :r) == d["r"]
    # MDC=1: POWER holds the MW schedule; the current schedule stays absent.
    @test d["control_mode"] == "POWER"
    @test PFP.get_value(line, :control_mode) == "POWER"
    @test PFP.get_value(line, :power_transfer_setpoint) == d["transfer_setpoint"]
    @test PFP.get_value(line, :current_transfer_setpoint) === PFP.ABSENT
    @test PFP.get_value(line, :scheduled_dc_voltage) == d["scheduled_dc_voltage"]
    @test PFP.get_value(line, :rectifier_bridges) == Int(d["rectifier_bridges"])
    @test _matches_nt(
        PFP.get_value(line, :rectifier_delay_angle_limits),
        d["rectifier_delay_angle_limits"],
    )
    @test PFP.get_value(line, :rectifier_rc) == d["rectifier_rc"]
    @test PFP.get_value(line, :rectifier_base_voltage) == d["rectifier_base_voltage"]
    @test _matches_nt(
        PFP.get_value(line, :inverter_extinction_angle_limits),
        d["inverter_extinction_angle_limits"],
    )
    @test _matches_nt(PFP.get_value(line, :rectifier_tap_limits), d["rectifier_tap_limits"])
    @test _matches_nt(PFP.get_value(line, :inverter_tap_limits), d["inverter_tap_limits"])
    @test PFP.get_value(line, :base_power) == 100.0
end

@testset "TwoTerminalGenericHVDCLine (matpower): native pminf/pmaxf/... ×baseMVA" begin
    pm = PFP.PowerModelsData(joinpath(MATPOWER_DIR, "case5_dc.m"))
    sys = PFP.build_openapi_system(pm)
    d = only(values(pm.data["dcline"]))
    line = only(PFP.get_components(sys, "TwoTerminalGenericHVDCLine"))
    base = pm.data["baseMVA"]

    @test PFP.get_value(line, :available) == (d["br_status"] == 1)
    @test PFP.get_value(line, :active_power_flow) ≈ d["pf"] * base
    @test _matches_nt(
        PFP.get_value(line, :active_power_limits_from),
        (min = d["pminf"] * base, max = d["pmaxf"] * base),
    )
    @test _matches_nt(
        PFP.get_value(line, :active_power_limits_to),
        (min = d["pmint"] * base, max = d["pmaxt"] * base),
    )
    @test _matches_nt(
        PFP.get_value(line, :reactive_power_limits_from),
        (min = d["qminf"] * base, max = d["qmaxf"] * base),
    )
    @test _matches_nt(
        PFP.get_value(line, :reactive_power_limits_to),
        (min = d["qmint"] * base, max = d["qmaxt"] * base),
    )
    @test PFP.get_value(line, :base_power) == base
end

@testset "FixedAdmittance: COMPONENT_MVAR Y is natural, undoing the pm dict's system per-unit" begin
    pm = fourteen_bus_pm_data()
    sys = PFP.build_openapi_system(pm)
    base = pm.data["baseMVA"]
    d = only(v for v in values(pm.data["shunt"]) if v["shunt_bus"] == 111)
    shunt = only(
        s for s in PFP.get_components(sys, "FixedAdmittance") if
        PFP.get_value(s, :bus) == PFP.get_bus_id(PFP.get_registry(sys), 111)
    )
    @test PFP.get_value(shunt, :available) == d["status"]
    @test PFP.get_value(shunt, :admittance_units) == "COMPONENT_MVAR"
    @test _matches_nt(
        PFP.get_value(shunt, :y),
        (real = d["gs"] * base, imag = d["bs"] * base),
    )
    # The fixture's bus-111 FIXED SHUNT record declares GL/BL as 100.000/200.000, so
    # COMPONENT_MVAR must read back as the RAW's own MW/MVAr, not the pm dict's 1.0/2.0 pu.
    @test _matches_nt(PFP.get_value(shunt, :y), (real = 100.0, imag = 200.0))
end

@testset "SwitchedAdmittance: control mode mapping, natural Y/Y_increase, VSWLO/VSWHI as the mode's band" begin
    pm = fourteen_bus_pm_data()
    sys = PFP.build_openapi_system(pm)
    base = pm.data["baseMVA"]
    d = only(v for v in values(pm.data["switched_shunt"]) if v["shunt_bus"] == 101)
    @test d["control_mode"] == 1

    shunt = only(
        s for s in PFP.get_components(sys, "SwitchedAdmittance") if
        PFP.get_value(s, :bus) == PFP.get_bus_id(PFP.get_registry(sys), 101)
    )
    @test PFP.get_value(shunt, :control_mode) == "DISCRETE_VOLTAGE"
    @test PFP.get_value(shunt, :number_of_steps) == d["step_number"]
    y_increase = PFP.get_value(shunt, :y_increase)
    @test length(y_increase) == length(d["y_increment"])
    @test all(
        y_increase[i].real == real(d["y_increment"][i]) * base &&
        y_increase[i].imag == imag(d["y_increment"][i]) * base for
        i in eachindex(d["y_increment"])
    )
    # The fixture's bus-101 SWITCHED SHUNT record declares BINIT = 50.00 and B1 = 100.00,
    # so both must read back in the RAW's own MVAr rather than the pm dict's 0.5/1.0 pu.
    # BINIT is the SOLVED admittance: a PSS/E switched shunt has no fixed base term
    # (#1774), so SwitchedAdmittance dropped the fixed `Y` field entirely — total
    # admittance is `number_engaged` steps of `y_increase`, with `solved_admittance`
    # overriding when present.
    @test PFP.get_value(shunt, :solved_admittance) == 50.0
    @test only(y_increase).imag == 100.0
    # MODSW=1 is a voltage mode: VSWLO/VSWHI land on voltage_limits, the reactive band
    # stays absent.
    @test _matches_nt(
        PFP.get_value(shunt, :voltage_limits),
        (min = d["admittance_limits"][1], max = d["admittance_limits"][2]),
    )
    @test PFP.get_value(shunt, :reactive_power_range_limits) === PFP.ABSENT
    @test PFP.get_value(shunt, :number_engaged) == d["number_engaged"]
end

@testset "_switched_admittance_control_mode rejects an unrecognized MODSW code" begin
    @test_throws IS.DataFormatError PFP._switched_admittance_control_mode(42)
    @test PFP._switched_admittance_control_mode(6) == "DISCRETE_REACTIVE_FACTS"
end

"""A single registered `ACBus`, for the maker-level testset below (kept local so this file
does not depend on the include order of its siblings)."""
function _dc_shunt_bus!(sys::PFP.OpenAPISystem, number::Int, name::AbstractString)
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

@testset "SwitchedAdmittance: a reactive control mode writes reactive_power_range_limits, FIXED writes no band" begin
    for (mode, band) in (
        (3, :reactive_power_range_limits), (4, :reactive_power_range_limits),
        (5, :reactive_power_range_limits), (6, :reactive_power_range_limits),
        (2, :voltage_limits), (0, nothing),
    )
        sys = PFP.OpenAPISystem(100.0)
        reg = PFP.get_registry(sys)
        bus_id = _dc_shunt_bus!(sys, 1, "b1")
        d = Dict{String, Any}(
            "status" => true, "control_mode" => mode, "step_number" => [2],
            "y_increment" => [complex(0.0, 0.5)], "admittance_limits" => (0.2, 0.8),
            "bs" => 0.0, "regulated_bus_number" => 0,
        )
        PFP.make_switched_admittance!(sys, reg, "sh$mode", d, bus_id)
        shunt = only(PFP.get_components(sys, "SwitchedAdmittance"))
        for candidate in (:voltage_limits, :reactive_power_range_limits)
            if candidate == band
                @test _matches_nt(PFP.get_value(shunt, candidate), (min = 0.2, max = 0.8))
            else
                @test PFP.get_value(shunt, candidate) === PFP.ABSENT
            end
        end
    end
end

@testset "TwoTerminalLCCLine: MDC=0 builds as BLOCKED with both setpoints absent" begin
    raw = read(joinpath(@__DIR__, "fixtures", "synthetic_v35_two_terminal_dc.raw"), String)
    blocked = replace(raw, "\"DCTEST1     \",1," => "\"DCTEST1     \",0,")
    path = joinpath(mktempdir(), "blocked.raw")
    write(path, blocked)
    sys = PFP.build_openapi_system(PFP.PowerModelsData(path))
    line = only(PFP.get_components(sys, "TwoTerminalLCCLine"))
    @test PFP.get_value(line, :control_mode) == "BLOCKED"
    @test !PFP.get_value(line, :available)
    @test PFP.get_value(line, :power_transfer_setpoint) === PFP.ABSENT
    @test PFP.get_value(line, :current_transfer_setpoint) === PFP.ABSENT
end

@testset "FACTSControlDevice: PSS/E MODE 0/1/2 maps to OOS/NML/BYP" begin
    pm = fourteen_bus_pm_data()
    sys = PFP.build_openapi_system(pm)
    d = only(values(pm.data["facts"]))
    @test d["control_mode"] == 1

    facts = only(PFP.get_components(sys, "FACTSControlDevice"))
    @test PFP.get_value(facts, :control_mode) == "NML"
    @test PFP.get_value(facts, :available) == d["available"]
    @test PFP.get_value(facts, :voltage_setpoint_units) == "COMPONENT_BASE"
    @test PFP.get_value(facts, :voltage_setpoint) == d["voltage_setpoint"]
    @test PFP.get_value(facts, :max_shunt_current) == d["max_shunt_current"]
    @test PFP.get_value(facts, :reactive_power_required) == 0.0
    @test PFP.get_value(facts, :regulated_bus_number) == d["regulated_bus_number"]
end

@testset "_facts_control_mode rejects a code outside the current 0-2 enum domain" begin
    @test_throws IS.DataFormatError PFP._facts_control_mode(3)
end

"""Minimal two-bus, two-area pm dict for the AreaInterchange bug-compatible site and its
undefined-area skip path — no fixture on hand carries `interarea_transfer` data."""
function _two_area_pm_data(; power_transfer::Float64 = 50.0, area_to::Int = 2)
    bus = Dict{String, Any}(
        "1" => Dict{String, Any}(
            "bus_i" => 1, "bus_type" => 3, "area" => 1, "zone" => 1,
            "base_kv" => 138.0,
            "va" => 0.0, "vm" => 1.0, "vmin" => 0.9, "vmax" => 1.1, "name" => "b1",
        ),
        "2" => Dict{String, Any}(
            "bus_i" => 2, "bus_type" => 1, "area" => 2, "zone" => 1,
            "base_kv" => 138.0,
            "va" => 0.0, "vm" => 1.0, "vmin" => 0.9, "vmax" => 1.1, "name" => "b2",
        ),
    )
    return Dict{String, Any}(
        "baseMVA" => 100.0,
        "source_type" => "pti",
        "bus" => bus,
        "load" => Dict{String, Any}(),
        "interarea_transfer" => Dict{String, Any}(
            "1" => Dict{String, Any}(
                "area_from" => 1, "area_to" => area_to, "transfer_id" => "1",
                "power_transfer" => power_transfer, "index" => 1,
            ),
        ),
    )
end

@testset "Bug-compatible: AreaInterchange.active_power_flow is power_transfer ×baseMVA a second time" begin
    data = _two_area_pm_data()
    sys = PFP.OpenAPISystem(Float64(data["baseMVA"]))
    PFP.read_loadzones!(sys, data)
    PFP.read_bus!(sys, data)
    PFP.read_area_interchanges!(sys, data)

    ai = only(PFP.get_components(sys, "AreaInterchange"))
    # power_transfer (50.0) is PFFP's raw, already-natural PTRAN value (psse.jl copies it
    # verbatim; "interarea_transfer" is not a native PowerModels section, so
    # `_make_per_unit!` never touches it either). PSCB's oracle assigns it directly into
    # a field PSY declares SU (system-base pu), with no division by sys_mbase first — a
    # real `get_active_power_flow(interchange, PSY.NU)` call therefore multiplies this
    # already-natural number by sys_mbase a SECOND time. This reader reproduces exactly
    # that inflated value.
    @test PFP.get_value(ai, :active_power_flow) == 50.0 * 100.0
    @test _matches_nt(
        PFP.get_value(ai, :flow_limits),
        (from_to = -1.0e6, to_from = 1.0e6),
    )
    @test PFP.get_value(ai, :base_power) == 100.0
    @test PFP.get_value(ai, :available)
end

@testset "read_area_interchanges! warns and skips a transfer referencing an undefined area" begin
    data = _two_area_pm_data(; area_to = 3)
    sys = PFP.OpenAPISystem(Float64(data["baseMVA"]))
    PFP.read_loadzones!(sys, data)
    PFP.read_bus!(sys, data)
    Test.@test_logs (:warn, r"undefined area") PFP.read_area_interchanges!(sys, data)
    @test isempty(PFP.get_components(sys, "AreaInterchange"))
end

@testset "read_area_interchanges! is a no-op for matpower source data" begin
    data = _two_area_pm_data()
    data["source_type"] = "matpower"
    sys = PFP.OpenAPISystem(Float64(data["baseMVA"]))
    PFP.read_loadzones!(sys, data)
    PFP.read_bus!(sys, data)
    PFP.read_area_interchanges!(sys, data)
    @test isempty(PFP.get_components(sys, "AreaInterchange"))
end

"""Minimal synthetic `vscline` entry for the DC_POWER/AC_REACTIVE_POWER case. No fixture
on hand carries a `vscline` section."""
function _synthetic_vscline_dict()
    return Dict{String, Any}(
        "available" => true,
        "f_bus" => 1, "t_bus" => 2,
        "pf" => 0.05, "qf" => 0.01, "qt" => -0.01,
        "rating" => 1.0,
        "pminf" => -1.0, "pmaxf" => 1.0, "pmint" => -1.0, "pmaxt" => 1.0,
        "qminf" => -0.5, "qmaxf" => 0.5, "qmint" => -0.5, "qmaxt" => 0.5,
        "r" => 0.5, "if" => 10.0,
        "dc_voltage_control_from" => false, "ac_voltage_control_from" => false,
        "dc_voltage_control_to" => false, "ac_voltage_control_to" => false,
        "dc_setpoint_from" => 0.02, "ac_setpoint_from" => 1.0,
        "dc_setpoint_to" => -0.02, "ac_setpoint_to" => 1.0,
        "converter_loss_from" => IS.LinearCurve(0.001, 0.002),
        "converter_loss_to" => IS.LinearCurve(0.001, 0.002),
        "max_dc_current_from" => 100.0, "max_dc_current_to" => 100.0,
        "rating_from" => 1.0, "rating_to" => 1.0,
        "power_factor_weighting_fraction_from" => 1.0,
        "power_factor_weighting_fraction_to" => 1.0,
        "rated_dc_voltage" => 100.0,
        "base_voltage_from" => 138.0, "base_voltage_to" => 138.0,
    )
end

@testset "TwoTerminalVSCLine: DC_POWER/AC_REACTIVE_POWER case ×sys_mbase where PFFP pre-scales" begin
    data = merge(
        Dict{String, Any}(
            "baseMVA" => 100.0, "source_type" => "pti",
            "bus" => Dict{String, Any}(
                "1" => Dict{String, Any}(
                    "bus_i" => 1, "bus_type" => 3, "area" => 1, "zone" => 1,
                    "base_kv" => 138.0, "va" => 0.0, "vm" => 1.0, "vmin" => 0.9,
                    "vmax" => 1.1, "name" => "b1",
                ),
                "2" => Dict{String, Any}(
                    "bus_i" => 2, "bus_type" => 1, "area" => 1, "zone" => 1,
                    "base_kv" => 138.0, "va" => 0.0, "vm" => 1.0, "vmin" => 0.9,
                    "vmax" => 1.1, "name" => "b2",
                ),
            ),
            "load" => Dict{String, Any}(),
        ),
    )
    sys = PFP.OpenAPISystem(Float64(data["baseMVA"]))
    PFP.read_loadzones!(sys, data)
    PFP.read_bus!(sys, data)
    reg = PFP.get_registry(sys)
    from_id = PFP.get_bus_id(reg, 1)
    to_id = PFP.get_bus_id(reg, 2)

    d = _synthetic_vscline_dict()
    PFP.make_vscline!(sys, reg, "vsc1", d, from_id, to_id, PFP.get_base_power(sys))
    vsc = only(PFP.get_components(sys, "TwoTerminalVSCLine"))
    @test PFP.get_value(vsc, :dc_control_from) == "DC_POWER"
    @test PFP.get_value(vsc, :ac_control_from) == "AC_REACTIVE_POWER"
    @test PFP.get_value(vsc, :active_power_flow) ≈ 0.05 * 100.0
    @test PFP.get_value(vsc, :rating) ≈ 1.0 * 100.0
    @test PFP.get_value(vsc, :dc_power_setpoint_from) ≈ 0.02 * 100.0
    @test PFP.get_value(vsc, :dc_voltage_setpoint_from) === PFP.ABSENT
    @test PFP.get_value(vsc, :power_factor_setpoint_from) == 1.0
    @test PFP.get_value(vsc, :ac_voltage_setpoint_from) === PFP.ABSENT
    @test PFP.get_value(vsc, :dc_current) == 10.0
    @test PFP.get_value(vsc, :g) ≈ 1.0 / 0.5
    @test PFP.get_value(vsc, :max_dc_current_from) == 100.0
    @test PFP.get_value(vsc, :rated_dc_voltage) == 100.0
    @test PFP.get_value(vsc, :rated_ac_voltage_from) == 138.0
    @test PFP.get_value(vsc, :rated_ac_voltage_to) == 138.0
end

@testset "TwoTerminalVSCLine: build_openapi_system threads each converter's AC base kV onto rated_ac_voltage_from/to" begin
    # The AC-side base kV (base_voltage_from/base_voltage_to, see test_parse_psse.jl) is
    # captured into the pm dict and threaded onto the document as
    # rated_ac_voltage_from/to (see make_vscline!'s docstring).
    file = joinpath(@__DIR__, "fixtures", "synthetic_v35_vsc_line.raw")
    sys = PFP.build_openapi_system(PFP.PowerModelsData(file))
    vsc = only(PFP.get_components(sys, "TwoTerminalVSCLine"))
    @test PFP.get_value(vsc, :rated_dc_voltage) == 150.0
    @test PFP.get_value(vsc, :rated_ac_voltage_from) == 200.0
    @test PFP.get_value(vsc, :rated_ac_voltage_to) == 138.0
end

@testset "TwoTerminalVSCLine: make_vscline! stores DC_VOLTAGE/AC_VOLTAGE setpoints as COMPONENT_BASE pu" begin
    # SiennaSchemas decouples setpoint_voltage_units (dc_voltage_setpoint_from/to,
    # ac_voltage_setpoint_from/to) from voltage_units (voltage_limits_from/to only), so tagging a
    # voltage-controlling setpoint COMPONENT_BASE no longer relabels the untouched
    # voltage_limits_from/to defaults. make_vscline! sets setpoint_voltage_units =
    # "COMPONENT_BASE" unconditionally and stores the already-p.u. PSS/E value with unit "pu" —
    # an identity conversion, so the stored value equals the input.
    data = Dict{String, Any}(
        "baseMVA" => 100.0, "source_type" => "pti",
        "bus" => Dict{String, Any}(
            "1" => Dict{String, Any}(
                "bus_i" => 1, "bus_type" => 3, "area" => 1, "zone" => 1,
                "base_kv" => 138.0, "va" => 0.0, "vm" => 1.0, "vmin" => 0.9,
                "vmax" => 1.1, "name" => "b1",
            ),
            "2" => Dict{String, Any}(
                "bus_i" => 2, "bus_type" => 1, "area" => 1, "zone" => 1,
                "base_kv" => 138.0, "va" => 0.0, "vm" => 1.0, "vmin" => 0.9,
                "vmax" => 1.1, "name" => "b2",
            ),
        ),
        "load" => Dict{String, Any}(),
    )
    sys = PFP.OpenAPISystem(Float64(data["baseMVA"]))
    PFP.read_loadzones!(sys, data)
    PFP.read_bus!(sys, data)
    reg = PFP.get_registry(sys)
    from_id = PFP.get_bus_id(reg, 1)
    to_id = PFP.get_bus_id(reg, 2)

    d_dc = _synthetic_vscline_dict()
    d_dc["dc_voltage_control_from"] = true
    d_dc["dc_setpoint_from"] = 1.03
    PFP.make_vscline!(sys, reg, "vsc2", d_dc, from_id, to_id, 100.0)
    vsc_dc = only(
        filter(
            c -> PFP.get_value(c, :name) == "vsc2",
            PFP.get_components(sys, "TwoTerminalVSCLine"),
        ),
    )
    @test PFP.get_value(vsc_dc, :dc_control_from) == "DC_VOLTAGE"
    @test PFP.get_value(vsc_dc, :setpoint_voltage_units) == "COMPONENT_BASE"
    @test PFP.get_value(vsc_dc, :dc_voltage_setpoint_from) == 1.03
    @test PFP.get_value(vsc_dc, :dc_power_setpoint_from) === PFP.ABSENT
    # make_vscline! has no pm dict source for voltage_units/voltage_limits_from — PSS/E's
    # VSC record carries no DC-bus voltage bound — so both stay genuinely unset rather than
    # defaulting to some placeholder range (see "unset properties are absent, not null" in
    # test_openapi_serialize.jl).
    @test PFP.get_value(vsc_dc, :voltage_units) === PFP.ABSENT
    @test PFP.get_value(vsc_dc, :voltage_limits_from) === PFP.ABSENT

    d_ac = _synthetic_vscline_dict()
    d_ac["ac_voltage_control_from"] = true
    d_ac["ac_setpoint_from"] = 1.02
    PFP.make_vscline!(sys, reg, "vsc3", d_ac, from_id, to_id, 100.0)
    vsc_ac = only(
        filter(
            c -> PFP.get_value(c, :name) == "vsc3",
            PFP.get_components(sys, "TwoTerminalVSCLine"),
        ),
    )
    @test PFP.get_value(vsc_ac, :ac_control_from) == "AC_VOLTAGE"
    @test PFP.get_value(vsc_ac, :setpoint_voltage_units) == "COMPONENT_BASE"
    @test PFP.get_value(vsc_ac, :ac_voltage_setpoint_from) == 1.02
    @test PFP.get_value(vsc_ac, :power_factor_setpoint_from) === PFP.ABSENT
    # See the vsc_dc case above: voltage_units/voltage_limits_to have no pm dict source.
    @test PFP.get_value(vsc_ac, :voltage_units) === PFP.ABSENT
    @test PFP.get_value(vsc_ac, :voltage_limits_to) === PFP.ABSENT
end

@testset "TwoTerminalVSCLine: dc_voltage_setpoint_from/to follow setpoint_voltage_units" begin
    # psse.jl documents the DC-voltage-controlling side's setpoint as p.u. of
    # rated_dc_voltage, computed as `DCSET / base_voltage`: 515.0 / 500.0 = 1.03 p.u.
    # Under COMPONENT_BASE that number is already in the declared unit, so "pu" is an
    # identity; under NATURAL_UNITS the field is a literal kV magnitude. The mode is
    # carried separately and no longer changes the field's unit.
    vsc = PFP.stage(PFP.PO.TwoTerminalVSCLine)
    PFP.set_value!(vsc, :power_units, "NATURAL_UNITS")
    PFP.set_value!(vsc, :dc_control_from, "DC_VOLTAGE")
    PFP.set_value!(vsc, :setpoint_voltage_units, "COMPONENT_BASE")
    PFP.set_value!(vsc, :dc_voltage_setpoint_from, 515.0 / 500.0, "pu")
    @test PFP.get_value(vsc, :dc_voltage_setpoint_from) == 1.03

    PFP.set_value!(vsc, :setpoint_voltage_units, "NATURAL_UNITS")
    PFP.set_value!(vsc, :dc_voltage_setpoint_from, 515.0, "kV")
    @test PFP.get_value(vsc, :dc_voltage_setpoint_from) == 515.0

    # DC_VOLTAGE_DROOP selects the same field.
    PFP.set_value!(vsc, :dc_control_from, "DC_VOLTAGE_DROOP")
    PFP.set_value!(vsc, :setpoint_voltage_units, "COMPONENT_BASE")
    PFP.set_value!(vsc, :dc_voltage_setpoint_from, 1.03, "pu")
    @test PFP.get_value(vsc, :dc_voltage_setpoint_from) == 1.03

    # The `to` side shares the one setpoint_voltage_units field.
    PFP.set_value!(vsc, :dc_control_to, "DC_VOLTAGE")
    PFP.set_value!(vsc, :dc_voltage_setpoint_to, 1.03, "pu")
    @test PFP.get_value(vsc, :dc_voltage_setpoint_to) == 1.03

    # The power setpoint has its own fixed unit, untouched by the basis tag.
    PFP.set_value!(vsc, :dc_power_setpoint_to, 40.0, "MW")
    @test PFP.get_value(vsc, :dc_power_setpoint_to) == 40.0
end

@testset "TwoTerminalVSCLine: ac_voltage_setpoint_from/to follow setpoint_voltage_units" begin
    # PSS/E's ACSET for a VSC converter bus is already per-unit of the AC bus's own base
    # voltage, so "pu" under COMPONENT_BASE is an identity; NATURAL_UNITS is a kV magnitude.
    vsc = PFP.stage(PFP.PO.TwoTerminalVSCLine)
    PFP.set_value!(vsc, :power_units, "NATURAL_UNITS")
    PFP.set_value!(vsc, :ac_control_from, "AC_VOLTAGE")
    PFP.set_value!(vsc, :setpoint_voltage_units, "COMPONENT_BASE")
    PFP.set_value!(vsc, :ac_voltage_setpoint_from, 1.02, "pu")
    @test PFP.get_value(vsc, :ac_voltage_setpoint_from) == 1.02

    PFP.set_value!(vsc, :setpoint_voltage_units, "NATURAL_UNITS")
    PFP.set_value!(vsc, :ac_voltage_setpoint_from, 1.02 * 138.0, "kV")
    @test PFP.get_value(vsc, :ac_voltage_setpoint_from) == 140.76

    PFP.set_value!(vsc, :ac_control_to, "AC_VOLTAGE")
    PFP.set_value!(vsc, :ac_voltage_setpoint_to, 1.02 * 138.0, "kV")
    @test PFP.get_value(vsc, :ac_voltage_setpoint_to) == 140.76

    # The power factor has its own fixed unit, untouched by the basis tag.
    PFP.set_value!(vsc, :power_factor_setpoint_to, 0.95, "1")
    @test PFP.get_value(vsc, :power_factor_setpoint_to) == 0.95
end

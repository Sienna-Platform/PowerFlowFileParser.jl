@testset "TwoTerminalLCCLine: custom PSS/E-native fields passthrough, native pf ×baseMVA" begin
    pm = fourteen_bus_pm_data()
    sys = PFP.build_openapi_system(pm)
    d = only(values(pm.data["dcline"]))
    line = only(PFP.get_components(sys, "TwoTerminalLCCLine"))

    @test PFP.get_value(line, :available) == d["available"]
    @test PFP.get_value(line, :active_power_flow) ≈ d["pf"] * 100.0
    # The pm dict's impedances are already per unit on the DC and converter bases.
    @test PFP.get_value(line, :parameter_units) == "COMPONENT_BASE"
    @test PFP.get_value(line, :r) == d["r"]
    @test PFP.get_value(line, :compounding_resistance) ==
          d["compounding_resistance"] / (d["scheduled_dc_voltage"]^2 / 100.0)
    @test PFP.get_value(line, :power_mode) == d["power_mode"]
    @test PFP.get_value(line, :transfer_setpoint) == d["transfer_setpoint"]
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

@testset "SwitchedAdmittance: control mode mapping, natural Y/Y_increase, admittance_limits passthrough" begin
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
    @test _matches_nt(
        PFP.get_value(shunt, :admittance_limits),
        (min = d["admittance_limits"][1], max = d["admittance_limits"][2]),
    )
    @test PFP.get_value(shunt, :number_engaged) == d["number_engaged"]
end

@testset "_switched_admittance_control_mode rejects an unrecognized MODSW code" begin
    @test_throws IS.DataFormatError PFP._switched_admittance_control_mode(42)
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
    @test isnothing(PFP.get_value(facts, :remote_regulated_bus_id))
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
        "r" => 0.5, "rdc" => 0.5, "if" => 10.0,
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
    @test PFP.get_value(vsc, :dc_setpoint_from) ≈ 0.02 * 100.0
    @test PFP.get_value(vsc, :ac_setpoint_from) == 1.0
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
    # SiennaSchemas decouples setpoint_voltage_units (dc_setpoint_from/to,
    # ac_setpoint_from/to) from voltage_units (voltage_limits_from/to only), so tagging a
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
    @test PFP.get_value(vsc_dc, :dc_setpoint_from) == 1.03
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
    @test PFP.get_value(vsc_ac, :ac_setpoint_from) == 1.02
    # See the vsc_dc case above: voltage_units/voltage_limits_to have no pm dict source.
    @test PFP.get_value(vsc_ac, :voltage_units) === PFP.ABSENT
    @test PFP.get_value(vsc_ac, :voltage_limits_to) === PFP.ABSENT
end

@testset "TwoTerminalVSCLine: dc_setpoint_from/to convert correctly under DC_VOLTAGE and DC_VOLTAGE_DROOP" begin
    # psse.jl's own VSC parsing (src/pm_io/psse.jl:2083-2097) documents this
    # exactly: "PSY documents dc_setpoint_from/to as p.u. of rated_dc_voltage
    # for the DC-voltage-controlling side (TYPE = 1)", computed there as
    # `from_bus["DCSET"] / base_voltage`. Hand math: DCSET = 515.0 kV,
    # base_voltage (rated_dc_voltage) = 500.0 kV => 515.0 / 500.0 = 1.03 p.u.
    # That division already produces the number PSY expects, so passing it
    # through set_value! with unit "pu" is an identity conversion: source
    # unit "pu" equals the COMPONENT_BASE-branch declared unit "pu", and "pu"
    # carries no fixed conversion factor (to_default: null in
    # Core/units.json) -- there is nothing left to scale.
    vsc = PFP.stage(PFP.PO.TwoTerminalVSCLine)
    PFP.set_value!(vsc, :power_units, "NATURAL_UNITS")
    PFP.set_value!(vsc, :dc_control_from, "DC_VOLTAGE")
    PFP.set_value!(vsc, :setpoint_voltage_units, "COMPONENT_BASE")
    PFP.set_value!(vsc, :dc_setpoint_from, 515.0 / 500.0, "pu")
    @test PFP.get_value(vsc, :dc_setpoint_from) == 1.03

    # NATURAL_UNITS is the schema's other DC-voltage basis: dc_setpoint_from
    # is then a literal kV magnitude. "kV" is both the source and the
    # DC_VOLTAGE/NATURAL_UNITS-branch declared unit (to_default 1.0 on both
    # sides), so this is also an identity conversion.
    PFP.set_value!(vsc, :setpoint_voltage_units, "NATURAL_UNITS")
    PFP.set_value!(vsc, :dc_setpoint_from, 515.0, "kV")
    @test PFP.get_value(vsc, :dc_setpoint_from) == 515.0

    # DC_VOLTAGE_DROOP shares the exact same nested setpoint_voltage_units branch as
    # DC_VOLTAGE in TwoTerminalVSCLine.json's dc_setpoint_from annotation;
    # confirm the emitter's recursive walk produced the same result for it.
    PFP.set_value!(vsc, :dc_control_from, "DC_VOLTAGE_DROOP")
    PFP.set_value!(vsc, :setpoint_voltage_units, "COMPONENT_BASE")
    PFP.set_value!(vsc, :dc_setpoint_from, 1.03, "pu")
    @test PFP.get_value(vsc, :dc_setpoint_from) == 1.03

    # dc_setpoint_to shares TwoTerminalVSCLine's one setpoint_voltage_units field with
    # dc_setpoint_from but has its own dc_control_to discriminator.
    PFP.set_value!(vsc, :dc_control_to, "DC_VOLTAGE")
    PFP.set_value!(vsc, :dc_setpoint_to, 1.03, "pu")
    @test PFP.get_value(vsc, :dc_setpoint_to) == 1.03
end

@testset "TwoTerminalVSCLine: ac_setpoint_from/to convert correctly under AC_VOLTAGE" begin
    # psse.jl: `sub_data["ac_setpoint_from"] = from_bus["ACSET"]` -- PSS/E's
    # ACSET for a VSC converter bus is already per-unit of the AC bus's own
    # base voltage (the same PSS/E convention as bus VM), so no scaling
    # happens before this value reaches PSY. Passing "pu" here is again an
    # identity: source unit "pu" equals the AC_VOLTAGE/COMPONENT_BASE-branch
    # declared unit "pu".
    vsc = PFP.stage(PFP.PO.TwoTerminalVSCLine)
    PFP.set_value!(vsc, :power_units, "NATURAL_UNITS")
    PFP.set_value!(vsc, :ac_control_from, "AC_VOLTAGE")
    PFP.set_value!(vsc, :setpoint_voltage_units, "COMPONENT_BASE")
    PFP.set_value!(vsc, :ac_setpoint_from, 1.02, "pu")
    @test PFP.get_value(vsc, :ac_setpoint_from) == 1.02

    # NATURAL_UNITS basis: ac_setpoint_from would be a literal kV magnitude
    # (e.g. 1.02 p.u. x 138.0 kV bus base = 140.76 kV); identity again since
    # source and declared units both resolve to "kV".
    PFP.set_value!(vsc, :setpoint_voltage_units, "NATURAL_UNITS")
    PFP.set_value!(vsc, :ac_setpoint_from, 1.02 * 138.0, "kV")
    @test PFP.get_value(vsc, :ac_setpoint_from) == 140.76

    # ac_setpoint_to mirrors ac_setpoint_from; setpoint_voltage_units is shared across
    # both sides of the component, ac_control_to is independent.
    PFP.set_value!(vsc, :ac_control_to, "AC_VOLTAGE")
    PFP.set_value!(vsc, :ac_setpoint_to, 1.02 * 138.0, "kV")
    @test PFP.get_value(vsc, :ac_setpoint_to) == 140.76
end

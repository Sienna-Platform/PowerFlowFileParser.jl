# PSS/E remote and shared voltage control: IREG/VS on generators, CONT/CR/CX on transformer
# circuits, ICR/ICI/IFR/ITR/IDR on the two-terminal DC line, REMOT/RMPCT on VSC converters,
# FCREG/SWREM on FACTS and switched shunts, and the ReactivePowerSharing groups built for
# every bus that two or more setpoint devices hold. The same synthetic network is exercised in
# the v33 and v35 record layouts.

"""The `TwoWindingTransformer` circuits between two pm bus numbers, keyed by control objective,
since parallel circuits between one bus pair share one arc."""
function _circuits_between_by_objective(sys, from_number::Int, to_number::Int)
    reg = PFP.get_registry(sys)
    arc_id =
        PFP.add_arc!(sys, PFP.get_bus_id(reg, from_number), PFP.get_bus_id(reg, to_number))
    circuits = Dict{String, Any}()
    for c in PFP.get_components(sys, "TransformerCircuit")
        PFP.get_value(c, :arc) == arc_id || continue
        circuits[PFP.get_value(c, :control_objective)] = c
    end
    return circuits
end

function _component_named(sys, type_name::AbstractString, name::AbstractString)
    return only(
        c for c in PFP.get_components(sys, type_name) if PFP.get_value(c, :name) == name
    )
end

"""`voltage_control_associations` rows of the sharing group attached to `component_id`."""
function _sharing_rows(sys, control_id::Int)
    doc = PFP.get_document(sys)
    return [a for a in doc.voltage_control_associations if a.control_id == control_id]
end

function _sharing_group_for(sys, component_id::Int)
    doc = PFP.get_document(sys)
    attribute_ids = Set(
        a.attribute_id for a in doc.supplemental_attribute_associations if
        a.component_id == component_id && a.attribute_type == "ReactivePowerSharing"
    )
    groups = [
        g for g in PFP.get_supplemental_attributes(sys, "ReactivePowerSharing") if
        PFP.get_value(g, :id) in attribute_ids
    ]
    return only(groups)
end

_weight_of(rows, entity_id::Int) = only(r for r in rows if r.entity_id == entity_id)

"""A single registered `ACBus` at pm bus `number`, for exercising a maker directly."""
function _vc_register_bus!(sys::PFP.OpenAPISystem, number::Int, name::AbstractString)
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

for version in ("v33", "v35")
    @testset "remote voltage control from a $version RAW file" begin
        file = joinpath(@__DIR__, "fixtures", "synthetic_$(version)_remote_control.raw")
        sys = PFP.build_openapi_system(PFP.PowerModelsData(file))
        reg = PFP.get_registry(sys)
        bus_id(number) = PFP.get_bus_id(reg, number)

        # IREG names the remote bus; 0 or the own bus is spelled nothing. VS is the setpoint.
        g21 = _component_named(sys, "ThermalStandard", "generator-2-1")
        @test PFP.get_value(g21, :remote_regulated_bus_id) == bus_id(3)
        @test PFP.get_value(g21, :voltage_setpoint_units) == "COMPONENT_BASE"
        @test PFP.get_value(g21, :voltage_setpoint) == 1.02
        g22 = _component_named(sys, "ThermalStandard", "generator-2-2")
        @test isnothing(PFP.get_value(g22, :remote_regulated_bus_id))
        @test PFP.get_value(g22, :voltage_setpoint) == 1.01
        g11 = _component_named(sys, "ThermalStandard", "generator-1-1")
        @test isnothing(PFP.get_value(g11, :remote_regulated_bus_id))
        g41 = _component_named(sys, "ThermalStandard", "generator-4-1")
        @test PFP.get_value(g41, :remote_regulated_bus_id) == bus_id(3)
        # A value that landed in a schema field is not mirrored into ext.
        for g in (g11, g21, g22, g41)
            ext = PFP.get_ext(sys, PFP.get_value(g, :id))
            @test !haskey(ext, "IREG")
            @test !haskey(ext, "RMPCT")
        end

        # CONT on the tapped winding's own bus: regulated bus without a side; CR + jCX is the
        # load drop compensation, per unit on the circuit base.
        local_circuit = only(values(_circuits_between_by_objective(sys, 3, 6)))
        @test PFP.get_value(local_circuit, :control_objective) == "VOLTAGE"
        @test PFP.get_value(local_circuit, :regulated_bus_id) == bus_id(3)
        @test isnothing(PFP.get_value(local_circuit, :regulated_bus_side))
        ldc = PFP.get_value(local_circuit, :load_drop_compensation)
        @test ldc.real ≈ 0.01
        @test ldc.imag ≈ 0.02
        @test !haskey(PFP.get_ext(sys, PFP.get_value(local_circuit, :id)), "CONT1")

        # A positive remote CONT lies beyond the other winding.
        remote_circuit = only(values(_circuits_between_by_objective(sys, 5, 6)))
        @test PFP.get_value(remote_circuit, :regulated_bus_id) == bus_id(7)
        @test PFP.get_value(remote_circuit, :regulated_bus_side) == "OPPOSITE_WINDING"
        ldc = PFP.get_value(remote_circuit, :load_drop_compensation)
        @test ldc.real == 0.0 && ldc.imag == 0.0

        # A negative remote CONT lies beyond the controlling winding; a non-voltage objective
        # carries no regulated bus.
        parallel = _circuits_between_by_objective(sys, 6, 7)
        disabled = parallel["VOLTAGE_DISABLED"]
        @test PFP.get_value(disabled, :regulated_bus_id) == bus_id(4)
        @test PFP.get_value(disabled, :regulated_bus_side) == "CONTROLLING_WINDING"
        dc_tap = parallel["CONTROL_OF_DC_LINE"]
        @test isnothing(PFP.get_value(dc_tap, :regulated_bus_id))
        @test isnothing(PFP.get_value(dc_tap, :regulated_bus_side))
        dc_tap_transformer = only(
            t for t in PFP.get_components(sys, "TwoWindingTransformer") if
            PFP.get_value(t, :circuit) == PFP.get_value(dc_tap, :id)
        )

        # ICR names the rectifier's commutating bus; IFR/ITR/IDR resolve to the tap transformer.
        lcc = only(PFP.get_components(sys, "TwoTerminalLCCLine"))
        @test PFP.get_value(lcc, :rectifier_commutating_bus_id) == bus_id(4)
        @test isnothing(PFP.get_value(lcc, :inverter_commutating_bus_id))
        @test PFP.get_value(lcc, :rectifier_tap_transformer_id) ==
              PFP.get_value(dc_tap_transformer, :id)
        @test isnothing(PFP.get_value(lcc, :inverter_tap_transformer_id))

        # REMOT per converter; RMPCT no longer rides on the line.
        vsc = only(PFP.get_components(sys, "TwoTerminalVSCLine"))
        @test PFP.get_value(vsc, :remote_regulated_bus_id_from) == bus_id(3)
        @test isnothing(PFP.get_value(vsc, :remote_regulated_bus_id_to))
        vsc_ext = PFP.get_ext(sys, PFP.get_value(vsc, :id))
        for key in ("REMOT_FROM", "REMOT_TO", "RMPCT_FROM", "RMPCT_TO")
            @test !haskey(vsc_ext, key)
        end

        # FCREG/REMOT of 0 is the own bus; SWREM is kept in every shunt control mode.
        facts = only(PFP.get_components(sys, "FACTSControlDevice"))
        @test isnothing(PFP.get_value(facts, :remote_regulated_bus_id))
        @test !haskey(PFP.get_ext(sys, PFP.get_value(facts, :id)), "RMPCT")
        shunts = Dict(
            PFP.get_value(s, :bus) => s for
            s in PFP.get_components(sys, "SwitchedAdmittance")
        )
        voltage_shunt = shunts[bus_id(6)]
        @test PFP.get_value(voltage_shunt, :control_mode) == "DISCRETE_VOLTAGE"
        @test PFP.get_value(voltage_shunt, :remote_regulated_bus_id) == bus_id(7)
        plant_shunt = shunts[bus_id(5)]
        @test PFP.get_value(plant_shunt, :control_mode) == "DISCRETE_REACTIVE_PLANT"
        @test PFP.get_value(plant_shunt, :remote_regulated_bus_id) == bus_id(2)
        @test !haskey(PFP.get_ext(sys, PFP.get_value(voltage_shunt, :id)), "RMPCT")

        # Bus 3 is held by two generators and the VSC from converter; bus 7 by the switched
        # shunt and the FACTS device. Nothing else shares a bus.
        groups = PFP.get_supplemental_attributes(sys, "ReactivePowerSharing")
        @test length(groups) == 2
        group3 = _sharing_group_for(sys, PFP.get_value(g21, :id))
        rows3 = _sharing_rows(sys, PFP.get_value(group3, :id))
        @test length(rows3) == 3
        @test _weight_of(rows3, PFP.get_value(g21, :id)).weight == 0.6
        @test _weight_of(rows3, PFP.get_value(g41, :id)).weight == 0.4
        vsc_row = _weight_of(rows3, PFP.get_value(vsc, :id))
        @test vsc_row.weight == 0.5
        @test vsc_row.terminal.value == "FROM"
        @test isnothing(_weight_of(rows3, PFP.get_value(g21, :id)).terminal)
        group7 = _sharing_group_for(sys, PFP.get_value(facts, :id))
        rows7 = _sharing_rows(sys, PFP.get_value(group7, :id))
        @test length(rows7) == 2
        @test _weight_of(rows7, PFP.get_value(voltage_shunt, :id)).weight == 1.0
        @test _weight_of(rows7, PFP.get_value(facts, :id)).weight == 1.0
        @test length(PFP.get_document(sys).voltage_control_associations) == 5
        # every group member also has its plain attribute association row
        assoc_rows = [
            a for a in PFP.get_document(sys).supplemental_attribute_associations if
            a.attribute_type == "ReactivePowerSharing"
        ]
        @test length(assoc_rows) == 5
        @test PFP.get_value(group3, :name) == "bus3_reactive_power_sharing"
    end
end

@testset "_psse_remote_bus_id spells PSS/E's zero and the own bus as nothing" begin
    sys = PFP.OpenAPISystem(100.0)
    reg = PFP.get_registry(sys)
    own = PFP.register_bus!(reg, 1, "b1")
    other = PFP.register_bus!(reg, 2, "b2")
    @test isnothing(PFP._psse_remote_bus_id(reg, 0, own))
    @test isnothing(PFP._psse_remote_bus_id(reg, 1, own))
    @test PFP._psse_remote_bus_id(reg, 2, own) == other
    @test_throws IS.DataFormatError PFP._psse_remote_bus_id(reg, 99, own)
end

@testset "a voltage-controlling CONT of 0 regulates the other winding's bus" begin
    sys = PFP.OpenAPISystem(100.0)
    reg = PFP.get_registry(sys)
    from_id = _vc_register_bus!(sys, 1, "b1")
    to_id = _vc_register_bus!(sys, 2, "b2")
    d = Dict{String, Any}(
        "COD1" => 1, "CONT1" => 0, "RMI1" => 0.9, "RMA1" => 1.1, "VMI1" => 0.95,
        "VMA1" => 1.05, "NTP1" => 33, "tap" => 1.0, "shift" => 0.0,
    )
    circuit_id = PFP._make_transformer_circuit!(
        sys, reg, d, from_id, to_id, "t"; tap_key = "tap", angle_key = "shift",
        control_suffix = 1, available = true, r = 0.01, x = 0.1, rating = 100.0,
        rating_b = nothing, rating_c = nothing, base_power = 100.0,
        base_voltage_primary = 100.0, base_voltage_secondary = 100.0,
        active_power_flow = 0.0, reactive_power_flow = 0.0,
    )
    circuit = only(
        c for c in PFP.get_components(sys, "TransformerCircuit") if
        PFP.get_value(c, :id) == circuit_id
    )
    @test PFP.get_value(circuit, :regulated_bus_id) == to_id
    @test isnothing(PFP.get_value(circuit, :regulated_bus_side))
end

@testset "an LCC tap transformer the TRANSFORMER data does not define is reported and left unset" begin
    # Real cases name transformers that are three-winding or missing; the line still imports.
    pm = PFP.PowerModelsData(
        joinpath(@__DIR__, "fixtures", "synthetic_v33_remote_control.raw"),
    )
    lcc_dict = only(values(pm.data["dcline"]))
    lcc_dict["inverter_tap_transformer"] = (6, 7, "9")
    sys = @test_logs (:warn, r"circuit '9'") match_mode = :any PFP.build_openapi_system(pm)
    lcc = only(PFP.get_components(sys, "TwoTerminalLCCLine"))
    @test isnothing(PFP.get_value(lcc, :inverter_tap_transformer_id))
    @test !isnothing(PFP.get_value(lcc, :rectifier_tap_transformer_id))
end

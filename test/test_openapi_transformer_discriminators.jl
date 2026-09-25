# `modified_14bus_system.raw`'s only 2W transformers are all CZ=1/CW=1/CM=1 with
# `base_power == sys_mbase == 100.0`, so nothing on hand exercised CZ∈{2,3}, CW∈{2,3},
# CM=2, or a 2W transformer whose device base differs from the system base — exactly the
# condition under which a completely missing device-base conversion passes silently.
# `synthetic_v35_transformer_discriminators.raw` covers it: two 2W transformers with
# SBASE1-2 != the 100 MVA system base, plus a two-terminal DC line with MDC=2
# (current-controlled, vs. every other fixture's MDC=1).
#
# The discriminator arithmetic below is transcribed from `pm_io/psse.jl`'s
# `_psse2pm_transformer!` (CZ/CW/CM branches) and `_psse2pm_dcline!` (MDC branch) — the
# SAME formulas the parser runs, evaluated independently here from the fixture's literal
# field values rather than by calling back into the parser.

const TRANSFORMER_DISCRIMINATOR_FIXTURE =
    joinpath(@__DIR__, "fixtures", "synthetic_v35_transformer_discriminators.raw")

_transformer_discriminator_pm_data() =
    PFP.PowerModelsData(TRANSFORMER_DISCRIMINATOR_FIXTURE)

@testset "T1 (CZ=2, CW=2, CM=1, SBASE1-2=50 != sys_mbase=100): hand-derived br_r/br_x/g_fr/b_fr/rating" begin
    pm = _transformer_discriminator_pm_data()
    data = pm.data
    sys_mbase = data["baseMVA"]
    @test sys_mbase == 100.0

    d = only(v for v in values(data["branch"]) if v["f_bus"] == 201 && v["t_bus"] == 202)
    @test d["transformer"]
    @test d["base_power"] == 50.0  # SBASE1-2, != sys_mbase — the discriminator condition

    # CZ=2: "resistance/reactance in pu on system MVA base and winding voltage base" —
    # the parser takes R1-2/X1-2 (0.01, 0.05) AS-IS at this step, no mva_ratio scaling.
    # CW=2: "winding voltage in kV" — Zeq is then scaled by (WINDV2 / bus_J_base_kv)^2 =
    # (21.0 / 20.0)^2 = 1.1025.
    cw2_factor = (21.0 / 20.0)^2
    @test cw2_factor ≈ 1.1025
    expected_br_r = 0.01 * cw2_factor
    expected_br_x = 0.05 * cw2_factor
    @test expected_br_r ≈ 0.011025
    @test expected_br_x ≈ 0.055125
    @test d["br_r"] ≈ expected_br_r
    @test d["br_x"] ≈ expected_br_x

    # CM=1: g_fr/b_fr = MAG1/MAG2 divided by mva_ratio_12 = base_power/sys_mbase = 0.5.
    mva_ratio_12 = d["base_power"] / sys_mbase
    @test mva_ratio_12 == 0.5
    @test d["g_fr"] ≈ 0.001 / mva_ratio_12  # MAG1 = 0.001 -> g_fr = 0.002
    @test d["b_fr"] ≈ 0.002 / mva_ratio_12  # MAG2 = 0.002 -> b_fr = 0.004
    @test d["g_fr"] ≈ 0.002
    @test d["b_fr"] ≈ 0.004

    # tap: WINDV1/WINDV2 * (bus_J_base_kv / bus_I_base_kv) = (105/21) * (20/100) = 1.0,
    # by construction (both ratios chosen to cancel) — CW=2's tap conversion itself is
    # exercised via T2 below, whose ratio does NOT cancel.
    @test d["tap"] ≈ 1.0

    # RMA1/RMI1 = 110/90 kV bracket WINDV1 and take the same CW=2 conversion as the tap:
    # (110/21) * (20/100) and (90/21) * (20/100).
    @test d["RMA1"] ≈ 110.0 / 105.0
    @test d["RMI1"] ≈ 90.0 / 105.0

    # rate_a: RATE11 = 40.0 MVA raw, divided by sys_mbase (PowerModels' generic branch
    # per-unit correction, applied uniformly to every "branch" entry) = 0.4 system-pu.
    @test d["rate_a"] ≈ 40.0 / sys_mbase

    sys = PFP.build_openapi_system(pm)
    two_w = only(
        t for t in PFP.get_components(sys, "TwoWindingTransformer") if
        PFP.get_value(t, :name) == "T1_HV-T1_LV-i_1"
    )
    circuit = only(
        c for c in PFP.get_components(sys, "TransformerCircuit") if
        PFP.get_value(c, :id) == PFP.get_value(two_w, :circuit)
    )
    # Device-base pu passthrough: circuit r/x/magnetizing_shunt equal the pm dict's
    # already-converted br_r/br_x/g_fr/b_fr verbatim, no further scaling.
    @test PFP.get_value(circuit, :r) == d["br_r"]
    @test PFP.get_value(circuit, :x) == d["br_x"]
    magnetizing = PFP.get_value(two_w, :magnetizing_shunt)
    @test PFP.get_value(magnetizing, :real) == d["g_fr"]
    @test PFP.get_value(magnetizing, :imag) == d["b_fr"]
    @test PFP.get_value(circuit, :base_power) == d["base_power"]
    # THE discriminator assertion: rating is rate_a scaled by the CIRCUIT's own base_power
    # (50.0), not sys_mbase (100.0) — these differ here, unlike every fixture on hand
    # before this task, so a reader that multiplied by sys_mbase instead would be caught:
    # 0.4*100=40.0 (wrong) vs 0.4*50=20.0 (right).
    @test PFP.get_value(circuit, :rating) ≈ d["rate_a"] * d["base_power"]
    @test PFP.get_value(circuit, :rating) ≈ 20.0
    @test _matches_nt(
        PFP.get_value(circuit, :tap_ratio_limits),
        (min = d["RMI1"], max = d["RMA1"]),
    )
end

@testset "T2 (CZ=3, CW=3, CM=2, SBASE1-2=80 != sys_mbase=100): hand-derived br_r/br_x/g_fr/b_fr/tap/rating" begin
    pm = _transformer_discriminator_pm_data()
    data = pm.data
    sys_mbase = data["baseMVA"]

    d = only(v for v in values(data["branch"]) if v["f_bus"] == 203 && v["t_bus"] == 204)
    @test d["transformer"]
    @test d["base_power"] == 80.0

    # CZ=3: "transformer load loss in watts and impedance magnitude in pu on a specified
    # MVA base and winding voltage base" — br_r = 1e-6*R1-2/base_power (R1-2=800.0 W is
    # the load loss), br_x = sqrt(X1-2^2 - br_r^2) (X1-2=0.05 is the impedance magnitude).
    br_r_cz3 = 1e-6 * 800.0 / d["base_power"]
    @test br_r_cz3 ≈ 1.0e-5
    br_x_cz3 = sqrt(0.05^2 - br_r_cz3^2)
    @test br_x_cz3 ≈ 0.05 atol = 1e-8  # sqrt(0.05^2 - (1e-5)^2), indistinguishable from 0.05

    # CW=3: "off-nominal turns ratio in pu of nominal winding voltage, NOMV1/NOMV2" — Zeq
    # scaled by (WINDV2 * NOMV2/bus_J_base_kv)^2 = (1.02 * (26.0/25.0))^2.
    cw3_factor = (1.02 * (26.0 / 25.0))^2
    @test cw3_factor ≈ 1.12529664
    expected_br_r = br_r_cz3 * cw3_factor
    expected_br_x = br_x_cz3 * cw3_factor
    @test d["br_r"] ≈ expected_br_r
    @test d["br_x"] ≈ expected_br_x
    @test d["br_r"] ≈ 1.1252966399999999e-5
    @test d["br_x"] ≈ 0.05626483087470335

    # CM=2: MAG1 (80000.0 W) is no-load loss, MAG2 (0.005 pu) is exciting current;
    # G_pu = 1e-6*MAG1/base_power, B_pu = -sqrt(MAG2^2 - G_pu^2).
    g_pu = 1e-6 * 80000.0 / d["base_power"]
    @test g_pu ≈ 0.001
    b_pu = -sqrt(0.005^2 - g_pu^2)
    @test b_pu ≈ -0.004898979485566357
    @test d["g_fr"] ≈ g_pu
    @test d["b_fr"] ≈ b_pu
    @test d["b_fr"] < 0

    # tap: WINDV1/WINDV2 * (bus_J_base_kv/bus_I_base_kv) * (winding1_nominal_voltage /
    # winding2_nominal_voltage); NOMV1=0 -> winding1_nominal_voltage = bus_I_base_kv
    # (100.0); NOMV2=26.0 (nonzero) -> winding2_nominal_voltage = 26.0.
    tap = (1.0 / 1.02) * (25.0 / 100.0) * (100.0 / 26.0)
    @test tap ≈ 0.942684766214178
    @test d["tap"] ≈ tap

    # rate_a: RATE11 = 64.0 MVA raw / sys_mbase = 0.64 system-pu.
    @test d["rate_a"] ≈ 64.0 / sys_mbase

    sys = PFP.build_openapi_system(pm)
    two_w = only(
        t for t in PFP.get_components(sys, "TwoWindingTransformer") if
        PFP.get_value(t, :name) == "T2_HV-T2_LV-i_1"
    )
    circuit = only(
        c for c in PFP.get_components(sys, "TransformerCircuit") if
        PFP.get_value(c, :id) == PFP.get_value(two_w, :circuit)
    )
    @test PFP.get_value(circuit, :r) == d["br_r"]
    @test PFP.get_value(circuit, :x) == d["br_x"]
    @test PFP.get_value(circuit, :tap) == d["tap"]
    magnetizing = PFP.get_value(two_w, :magnetizing_shunt)
    @test PFP.get_value(magnetizing, :real) == d["g_fr"]
    @test PFP.get_value(magnetizing, :imag) == d["b_fr"]
    @test PFP.get_value(circuit, :base_power) == 80.0
    # THE discriminator assertion again, on the second (CZ=3/CW=3/CM=2) transformer:
    # 0.64*100=64.0 (wrong, sys_mbase) vs 0.64*80=51.2 (right, circuit base_power).
    @test PFP.get_value(circuit, :rating) ≈ d["rate_a"] * d["base_power"]
    @test PFP.get_value(circuit, :rating) ≈ 51.2
end

@testset "two-terminal DC line MDC=2 (current-controlled): control_mode=CURRENT, hand-derived power_demand" begin
    pm = _transformer_discriminator_pm_data()
    data = pm.data
    sys_mbase = data["baseMVA"]

    d = only(values(data["dcline"]))
    # MDC=2: SETVL is a current in Amps (200.0 A), not a power in MW — power_demand =
    # abs(SETVL * VSCHD / 1000) = abs(200.0 * 400.0 / 1000) = 80.0 MW, VS. MDC=1's
    # `power_demand = abs(SETVL)` used everywhere else in this repo's fixtures.
    power_demand = abs(200.0 * 400.0 / 1000)
    @test power_demand == 80.0
    @test d["pf"] ≈ power_demand / sys_mbase  # PowerModels' generic per-unit correction
    @test d["pf"] ≈ 0.8
    @test d["control_mode"] == "CURRENT"  # MDC=2
    @test d["transfer_setpoint"] == 200.0  # raw SETVL, passed through regardless of MDC
    @test d["scheduled_dc_voltage"] == 400.0

    sys = PFP.build_openapi_system(pm)
    line = only(PFP.get_components(sys, "TwoTerminalLCCLine"))
    # MDC=2: CURRENT holds the amperes schedule; the MW schedule stays absent.
    @test PFP.get_value(line, :control_mode) == "CURRENT"
    @test PFP.get_value(line, :current_transfer_setpoint) == d["transfer_setpoint"]
    @test PFP.get_value(line, :power_transfer_setpoint) === PFP.ABSENT
    # Emit-layer scaling is uniform regardless of MDC (dc_branch.jl multiplies `pf` by
    # sys_mbase either way): 0.8 * 100.0 = 80.0 MW, matching the hand-derived power_demand
    # above — confirms MDC=2's current-based power_demand survives the full pipeline.
    @test PFP.get_value(line, :active_power_flow) ≈ d["pf"] * sys_mbase
    @test PFP.get_value(line, :active_power_flow) ≈ 80.0
end

@testset "the discriminator fixture's document round-trips through PC and validates" begin
    sys = PFP.build_openapi_system(_transformer_discriminator_pm_data())
    path = joinpath(mktempdir(), "transformer_discriminators.json")
    PFP.to_json(sys, path)
    doc = PFP.PD.read_document(path)
    # 3, not 2: bus 2 (200 kV) -> bus 3 (138 kV) is a plain `Line` record in the raw file,
    # but PFFP's own >1%-voltage-mismatch detection (`power_models_data.jl`) reclassifies
    # it as a third (CZ=1/CW=1/CM=1, unremarkable) transformer — incidental to this
    # fixture's DC-line buses, borrowed from `synthetic_v35_two_terminal_dc.raw`'s
    # template, not one of T1/T2.
    @test length(PFP.PD.get_components(doc, "TwoWindingTransformer")) == 3
    @test length(PFP.PD.get_components(doc, "TwoTerminalLCCLine")) == 1
    PFP.PD.validate_document(doc)
end

# A PSS(R)E winding line may stop before its control bands. `pti.jl` then fills RMA/RMI/
# VMA/VMI with the documented defaults, so by the time the pm dict exists a stated 0.9-1.1
# and a substituted one look the same. `RM_PRESENT<k>`/`VM_PRESENT<k>` is the only record of
# which it was, captured before the substitution. These tests enter through the RAW parse
# path on purpose: a hand-built dict can omit a key that a parsed one never lacks.

const BAND_PRESENCE_FIXTURE =
    joinpath(@__DIR__, "fixtures", "synthetic_v35_transformer_band_presence.raw")

_branch_between(data, f, t) =
    only(v for v in values(data["branch"]) if v["f_bus"] == f && v["t_bus"] == t)

@testset "Winding line truncated before its bands: flags false, defaults still filled" begin
    data = PowerFlowFileParser.parse_file(BAND_PRESENCE_FIXTURE)
    t1 = _branch_between(data, 201, 202)
    @test t1["COD1"] == 2
    @test t1["RM_PRESENT1"] === false
    @test t1["VM_PRESENT1"] === false
    # The defaults are substituted regardless; the flag is what says they were not stated.
    # (RMA/RMI are re-expressed by `apply_tap_correction!` per CW, so only VMA/VMI are
    # compared as raw values here.)
    @test haskey(t1, "RMA1") && haskey(t1, "RMI1")
    @test t1["VMA1"] == 1.1 && t1["VMI1"] == 0.9
end

@testset "Winding line stating its bands: flags true, values as written" begin
    data = PowerFlowFileParser.parse_file(BAND_PRESENCE_FIXTURE)
    t2 = _branch_between(data, 203, 204)
    @test t2["COD1"] == 1
    @test t2["RM_PRESENT1"] === true
    @test t2["VM_PRESENT1"] === true
    @test t2["VMA1"] == 1.04 && t2["VMI1"] == 0.96
end

@testset "Three-winding transformer: one flag pair per winding" begin
    data = PowerFlowFileParser.parse_file(joinpath(PSSE_RAW_DIR, "case6_3w.raw"))
    @test !isempty(data["3w_transformer"])
    for t in values(data["3w_transformer"]), k in 1:3
        @test t["RM_PRESENT$k"] isa Bool
        @test t["VM_PRESENT$k"] isa Bool
    end
end

# The same fixture through the full document build: the presence flags decide which bands
# the circuit carries, so a truncated COD=2 record yields no MVAr band and a stated COD=1
# record yields its voltage band, with no hand-built dict anywhere in the path.
function _band_circuit(sys, from_number::Int, to_number::Int)
    reg = PFP.get_registry(sys)
    arc_id = PFP.add_arc!(
        sys, PFP.get_bus_id(reg, from_number), PFP.get_bus_id(reg, to_number),
    )
    return only(
        c for c in PFP.get_components(sys, "TransformerCircuit") if
        PFP.get_value(c, :arc) == arc_id
    )
end

@testset "Document build: truncated COD=2 record carries no MVAr band, stated COD=1 record its voltage band" begin
    sys = PFP.build_openapi_system(PFP.PowerModelsData(BAND_PRESENCE_FIXTURE))
    t1 = _band_circuit(sys, 201, 202)
    @test PFP.get_value(t1, :control_objective) == "REACTIVE_POWER_FLOW"
    @test PFP.get_value(t1, :controlled_reactive_power_flow_limits) isa PFP.IC.Absent
    @test PFP.get_value(t1, :controlled_voltage_limits) isa PFP.IC.Absent
    @test !(PFP.get_value(t1, :tap_ratio_limits) isa PFP.IC.Absent)
    t2 = _band_circuit(sys, 203, 204)
    @test PFP.get_value(t2, :control_objective) == "VOLTAGE"
    band = PFP.get_value(t2, :controlled_voltage_limits)
    @test PFP.get_value(band, :min) == 0.96 && PFP.get_value(band, :max) == 1.04
    @test PFP.get_value(t2, :controlled_reactive_power_flow_limits) isa PFP.IC.Absent
end

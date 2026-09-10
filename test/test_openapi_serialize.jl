function _serialize_test_system(; power_units::AbstractString = "NATURAL_UNITS")
    sys = PFP.OpenAPISystem(100.0; power_units = power_units)
    reg = PFP.get_registry(sys)

    bus = PFP.stage(PFP.PC.ACBus)
    PFP.set_value!(bus, :id, PFP.register_bus!(reg, 101, "Abel"))
    PFP.set_value!(bus, :number, 101)
    PFP.set_value!(bus, :name, "Abel")
    PFP.set_value!(bus, :available, true)
    PFP.set_value!(bus, :bustype, "REF")
    PFP.set_value!(bus, :base_voltage, 138.0, "kV")
    PFP.add_component!(sys, bus)

    area = PFP.stage(PFP.PC.Area)
    PFP.set_value!(area, :id, PFP.register!(reg, "Area", "1"))
    PFP.set_value!(area, :name, "1")
    PFP.set_value!(area, :base_power, PFP.get_base_power(sys), "MVA")
    PFP.add_component!(sys, area)

    geo = PFP.stage(PFP.IC.GeographicInfo)
    PFP.set_value!(geo, :id, PFP.next_id!(reg))
    PFP.set_value!(geo, :geo_json, Dict{String, Any}("type" => "Point"))
    PFP.add_supplemental_attribute!(sys, geo, PFP.get_value(bus, :id))
    return sys
end

function _round_trip(sys)
    return mktempdir() do dir
        path = joinpath(dir, "case.json")
        PFP.to_json(sys, path)
        return JSON.parse(read(path, String))
    end
end

@testset "document top-level shape" begin
    doc = _round_trip(_serialize_test_system())
    @test doc["components"]["Area"][1]["base_power"] == 100.0
    @test isnothing(get(doc, "time_series_storage_file", nothing))
    @test isempty(doc["time_series_associations"])
    @test haskey(doc, "supplemental_attributes")
    @test haskey(doc, "supplemental_attribute_associations")
end

@testset "power_units defaults to NATURAL_UNITS" begin
    sys = PFP.OpenAPISystem(100.0)
    @test PFP.get_power_units(sys) == "NATURAL_UNITS"
    @test !PFP.uses_per_unit(sys)
end

@testset "power_units accepts COMPONENT_BASE" begin
    sys = PFP.OpenAPISystem(100.0; power_units = "COMPONENT_BASE")
    @test PFP.get_power_units(sys) == "COMPONENT_BASE"
    @test PFP.uses_per_unit(sys)
end

@testset "power_units rejects invalid values" begin
    @test_throws IS.DataFormatError PFP.OpenAPISystem(100.0; power_units = "PER_UNIT")
end

@testset "power_units is stamped onto every component that declares the field" begin
    # The NATURAL_UNITS side is covered by "document top-level shape" above.
    component_base = _round_trip(_serialize_test_system(; power_units = "COMPONENT_BASE"))
    @test component_base["components"]["Area"][1]["power_units"] == "COMPONENT_BASE"
    # ACBus declares no power_units field, so it carries none either way.
    @test !haskey(component_base["components"]["ACBus"][1], "power_units")
end

@testset "components are grouped by type name in sorted order" begin
    doc = _round_trip(_serialize_test_system())
    @test collect(keys(doc["components"])) == ["ACBus", "Area"]
    @test length(doc["components"]["ACBus"]) == 1
    @test length(doc["components"]["Area"]) == 1
end

@testset "unset properties are absent, not null" begin
    doc = _round_trip(_serialize_test_system())
    bus = only(doc["components"]["ACBus"])
    @test haskey(bus, "name")
    @test bus["number"] == 101
    @test !haskey(bus, "angle")
    @test !haskey(bus, "voltage_limits")
end

@testset "supplemental attribute associations serialize as id pairs" begin
    doc = _round_trip(_serialize_test_system())
    assoc = only(doc["supplemental_attribute_associations"])
    @test assoc["component_id"] == 1
    @test assoc["component_type"] == "ACBus"
    @test assoc["attribute_type"] == "GeographicInfo"
end

@testset "to_json writes a file that round-trips through JSON" begin
    sys = _serialize_test_system()
    path = joinpath(mktempdir(), "case.json")
    @test PFP.to_json(sys, path) == path
    parsed = JSON.parsefile(path)
    @test parsed["components"]["Area"][1]["base_power"] == 100.0
    @test parsed["components"]["ACBus"][1]["name"] == "Abel"
    @test parsed["components"]["ACBus"][1]["base_voltage"] == 138.0
    @test !haskey(parsed["components"]["ACBus"][1], "angle")
end

@testset "to_json refuses to overwrite without force" begin
    path = joinpath(mktempdir(), "case.json")
    PFP.to_json(_serialize_test_system(), path)
    # PD.write_document owns the "already exists" check for the JSON path now.
    @test_throws PFP.IC.DocumentFormatError PFP.to_json(_serialize_test_system(), path)
    @test PFP.to_json(_serialize_test_system(), path; force = true) == path
end

@testset "pretty = true changes bytes but not parsed content" begin
    dir = mktempdir()
    compact = joinpath(dir, "compact.json")
    pretty = joinpath(dir, "pretty.json")
    PFP.to_json(_serialize_test_system(), compact)
    PFP.to_json(_serialize_test_system(), pretty; pretty = true)
    @test read(compact, String) != read(pretty, String)
    @test JSON.parsefile(compact) == JSON.parsefile(pretty)
end

@testset "output is byte-deterministic" begin
    dir = mktempdir()
    a = joinpath(dir, "a.json")
    b = joinpath(dir, "b.json")
    PFP.to_json(_serialize_test_system(), a)
    PFP.to_json(_serialize_test_system(), b)
    @test read(a, String) == read(b, String)
end

# OpenAPI.jl 1.x dropped the mutable-model runtime `check_required` came from; a
# materialized component is a `Base.@kwdef struct` whose non-defaulted (i.e.
# schema-required) fields Julia itself refuses to leave unassigned, so there is no longer
# a separate required-field check to run after the fact. The equivalent guarantee under
# the new runtime is that `_encode` — which schema-validates the full object, not just
# field presence — succeeds on every emitted component.
@testset "every emitted component round-trips through _encode" begin
    sys = _serialize_test_system()
    for type_name in PFP.component_type_names(sys)
        for component in PFP.get_components(sys, type_name)
            @test OpenAPI.Runtime._encode(component) isa JSON.Object
        end
    end
    for association in PFP.get_document(sys).supplemental_attribute_associations
        @test OpenAPI.Runtime._encode(association) isa JSON.Object
    end
end

@testset "a written document reads back through PD.read_document" begin
    sys = _serialize_test_system()
    path = joinpath(mktempdir(), "case.json")
    PFP.to_json(sys, path)
    doc = PFP.PD.read_document(path)
    area = only(PFP.PD.get_components(doc, "Area"))
    @test PFP.get_value(area, :base_power) == 100.0
    @test length(PFP.PD.get_components(doc, "ACBus")) == 1
    @test length(PFP.PD.get_components(doc, "Area")) == 1
end

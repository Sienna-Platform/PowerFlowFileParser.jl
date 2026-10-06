@testset "IdRegistry assigns one global id space" begin
    reg = PFP.IdRegistry(PFP.PC.SystemDocument())
    @test PFP.register!(reg, "Area", "1") == 1
    @test PFP.register_bus!(reg, 101, "Abel") == 2
    @test PFP.register!(reg, "ThermalStandard", "101_STEAM_3") == 3
    @test PFP.next_id!(reg) == 4
end

@testset "IdRegistry lookups" begin
    reg = PFP.IdRegistry(PFP.PC.SystemDocument())
    PFP.register_bus!(reg, 101, "Abel")
    @test PFP.has_bus_id(reg, 101)
    @test PFP.get_bus_id(reg, 101) == 1
    @test !PFP.has_bus_id(reg, 999)
    @test_throws IS.DataFormatError PFP.get_bus_id(reg, 999)
    @test PFP.has_id(reg, "ACBus", "Abel")
    @test PFP.get_id(reg, "ACBus", "Abel") == 1
    @test !PFP.has_id(reg, "ACBus", "Nowhere")
    @test_throws IS.DataFormatError PFP.get_id(reg, "ACBus", "Nowhere")
end

@testset "IdRegistry rejects duplicates within a type" begin
    reg = PFP.IdRegistry(PFP.PC.SystemDocument())
    PFP.register!(reg, "Area", "1")
    @test_throws IS.DataFormatError PFP.register!(reg, "Area", "1")
end

@testset "IdRegistry rejects duplicate bus numbers" begin
    reg = PFP.IdRegistry(PFP.PC.SystemDocument())
    PFP.register_bus!(reg, 101, "Abel")
    @test_throws IS.DataFormatError PFP.register_bus!(reg, 101, "Adams")
end

@testset "IdRegistry allows the same name across types" begin
    reg = PFP.IdRegistry(PFP.PC.SystemDocument())
    @test PFP.register!(reg, "Area", "1") != PFP.register!(reg, "LoadZone", "1")
end

@testset "arc_id! deduplicates and respects direction" begin
    reg = PFP.IdRegistry(PFP.PC.SystemDocument())
    from = PFP.register_bus!(reg, 101, "Abel")
    to = PFP.register_bus!(reg, 102, "Adams")
    id1, created1 = PFP.arc_id!(reg, from, to)
    id2, created2 = PFP.arc_id!(reg, from, to)
    id3, created3 = PFP.arc_id!(reg, to, from)
    @test created1
    @test !created2
    @test created3
    @test id1 == id2
    @test id1 != id3
end

@testset "find_by_name narrows by candidate types" begin
    reg = PFP.IdRegistry(PFP.PC.SystemDocument())
    area = PFP.register!(reg, "Area", "1")
    zone = PFP.register!(reg, "LoadZone", "1")
    @test PFP.find_by_name(reg, ["LoadZone"], "1") == ("LoadZone", zone)
    @test PFP.find_by_name(reg, ["Area"], "1") == ("Area", area)
    @test_throws IS.DataFormatError PFP.find_by_name(reg, ["Area", "LoadZone"], "1")
    @test_throws IS.DataFormatError PFP.find_by_name(reg, ["Area"], "missing")
end

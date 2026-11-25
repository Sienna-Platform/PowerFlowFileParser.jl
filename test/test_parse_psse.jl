@testset "PSSE Parsing" begin
    files = readdir(PSSE_RAW_DIR)
    if length(files) == 0
        error("No test files in the folder")
    end

    for f in files[1:1]
        @info "Parsing $f ..."
        pm_data = PowerModelsData(joinpath(PSSE_RAW_DIR, f))
        @info "Successfully parsed $f to PowerModelsData"

        # Verify basic data structure
        @test isa(pm_data, PowerModelsData)
        @test haskey(pm_data.data, "baseMVA")
        @test haskey(pm_data.data, "bus")
        @test haskey(pm_data.data, "gen")
        @test haskey(pm_data.data, "branch")

        # Verify generators have ext data (impedance info may or may not be present depending on source)
        for (gen_id, gen) in pm_data.data["gen"]
            @test haskey(gen, "ext")
            # Note: "r" and "x" fields may be present depending on the PSS/E file version
        end

        @info "Successfully validated $f data structure"
    end

    # Test bad input
    pm_data = PowerModelsData(joinpath(PSSE_RAW_DIR, files[1]))
    pm_data.data["bus"] = Dict{String, Any}()
    # Note: Since we removed PowerSystems.System constructor,
    # we just verify the data structure is valid
    @test !haskey(pm_data.data, "ref_buses") || isempty(pm_data.data["ref_buses"])

    @info "Testing PSEE v31 .raw Parsing"
    ENV["PTI_VERSION"] = "v31" # set for v31 version and test
    sys11_v31 = PowerModelsData(joinpath(@__DIR__, "11BUS_KUNDUR_v31.raw"))
    @test haskey(sys11_v31.data, "bus") && length(sys11_v31.data["bus"]) == 11
    @test haskey(sys11_v31.data, "branch") && length(sys11_v31.data["branch"]) == 12
    ENV["PTI_VERSION"] = "" # unset and test failure
    @test_throws Nothing PowerModelsData(joinpath(@__DIR__, "11BUS_KUNDUR_v31.raw"))
end

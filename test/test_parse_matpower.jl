# TODO: Reviewers: Is this a correct list of keys to verify?
POWER_MODELS_KEYS = [
    "baseMVA",
    "branch",
    "bus",
    "dcline",
    "gen",
    "load",
    "name",
    "per_unit",
    "shunt",
    "source_type",
    "source_version",
    "storage",
]

voltage_inconsistent_files = ["RTS_GMLC_original.m", "case5_re.m", "case5_re_uc.m"]

@testset "Parse Matpower data files" begin
    files = [x for x in readdir(joinpath(MATPOWER_DIR)) if splitext(x)[2] == ".m"]
    if length(files) == 0
        @error "No test files in the folder"
    end

    for f in files
        @info "Parsing $f..."
        path = joinpath(MATPOWER_DIR, f)

        if f in voltage_inconsistent_files
            continue
        else
            pm_dict = parse_file(path)
        end

        for key in POWER_MODELS_KEYS
            @test haskey(pm_dict, key)
        end
        @info "Successfully parsed $path to PowerModels dict"

        # Verify basic data structure
        @test pm_dict["baseMVA"] > 0.0
        @test length(pm_dict["bus"]) > 0
        @test pm_dict["per_unit"] == true
    end
end

@testset "Parse PowerModelsData from Matpower files" begin
    files = [
        x for x in readdir(MATPOWER_DIR) if
        splitext(x)[2] == ".m"
    ]
    if length(files) == 0
        @error "No test files in the folder"
    end

    for f in files
        @info "Parsing $f..."
        path = joinpath(MATPOWER_DIR, f)

        if f in voltage_inconsistent_files
            continue
        end

        pm_data = PowerModelsData(path)
        @test isa(pm_data, PowerModelsData)
        @test haskey(pm_data.data, "baseMVA")
        @test haskey(pm_data.data, "bus")
        @test haskey(pm_data.data, "gen")
        @info "Successfully parsed $path to PowerModelsData"
    end
end

@testset "Parse Matpower files with voltage inconsistencies" begin
    test_parse = (path) -> begin
        pm_dict = parse_file(path)

        for key in POWER_MODELS_KEYS
            @test haskey(pm_dict, key)
        end
        @info "Successfully parsed $path to PowerModels dict"

        pm_data = PowerModelsData(pm_dict)
        @test isa(pm_data, PowerModelsData)
    end

    for f in voltage_inconsistent_files
        @info "Parsing $f..."
        path = joinpath(BAD_DATA, f)
        # These files may produce warnings or errors during parsing, but should still parse
        test_parse(path)
    end
end

@testset "_make_per_unit!/_make_mixed_units! rescale storage ps/qs" begin
    data = Dict{String, Any}(
        "baseMVA" => 100.0,
        "per_unit" => false,
        "storage" => Dict{String, Any}(
            "1" => Dict{String, Any}("ps" => 20.0, "qs" => -5.0),
        ),
    )
    PFP._make_per_unit!(data, 100.0)
    @test data["storage"]["1"]["ps"] ≈ 0.2
    @test data["storage"]["1"]["qs"] ≈ -0.05
    data["per_unit"] = true
    PFP._make_mixed_units!(data)
    @test data["storage"]["1"]["ps"] ≈ 20.0
    @test data["storage"]["1"]["qs"] ≈ -5.0
end

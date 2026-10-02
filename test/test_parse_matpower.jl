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

@testset "Out-of-service generator does not set the PV bus voltage" begin
    case = """
    function mpc = case_off_gen_vg
    mpc.version = '2';
    mpc.baseMVA = 100;
    mpc.bus = [
        1   3   0   0   0   0   1   1.0    0   230   1   1.1   0.9;
        2   2   0   0   0   0   1   1.0    0   230   1   1.1   0.9;
        3   1   50  10  0   0   1   1.0    0   230   1   1.1   0.9;
    ];
    mpc.gen = [
        1   0    0   100  -100  1.00  100  1   200  0   0   0   0   0   0   0   0   0   0   0   0;
        2   0    0   100  -100  1.10  100  0   200  0   0   0   0   0   0   0   0   0   0   0   0;
        2   40   0   100  -100  1.02  100  1   200  0   0   0   0   0   0   0   0   0   0   0   0;
    ];
    mpc.branch = [
        1   2   0.01   0.1   0   100   100   100   0   0   1   -360   360;
        2   3   0.01   0.1   0   100   100   100   0   0   1   -360   360;
    ];
    """
    pm_dict = parse_file(IOBuffer(case); filetype = "m")
    @test pm_dict["bus"][2]["vm"] == 1.02
end

using Test
using Logging
using PowerFlowFileParser

const V35_SUBSTATION_FIXTURE = joinpath(@__DIR__, "fixtures", "v35_substation.raw")

@testset "PTI v35 substation section parsing" begin
    pti_data = PowerFlowFileParser._parse_pti_data(
        IOBuffer(read(V35_SUBSTATION_FIXTURE, String)),
    )

    @test haskey(pti_data, "SUBSTATION DATA")
    substations = pti_data["SUBSTATION DATA"]
    @test length(substations) == 2

    alpha = substations[1]
    @test alpha["IS"] == 1
    @test alpha["NAME"] == "ALPHA"
    @test alpha["LATITUDE"] == 34.61
    @test alpha["LONGITUDE"] == -86.67
    @test alpha["SGR"] == 0.25

    @testset "nodes" begin
        nodes = alpha["NODES"]
        @test length(nodes) == 3
        @test nodes[1]["NI"] == 1
        @test nodes[1]["NAME"] == "ALPHA\$138\$0001"
        @test nodes[1]["I"] == 1
        @test nodes[1]["STATUS"] == 1
        @test nodes[1]["VM"] == 1.01
        @test nodes[1]["VA"] == -11.0
        @test nodes[3]["STATUS"] == 0
        # Omitted node voltages stay empty; a node with no stored voltage
        # inherits its bus voltage downstream instead of a fabricated 1.0/0.0.
        @test nodes[3]["VM"] == ""
        @test nodes[3]["VA"] == ""
    end

    @testset "switching devices" begin
        devices = alpha["SWITCHING DEVICES"]
        @test length(devices) == 3
        breaker = devices[1]
        @test breaker["NI"] == 1
        @test breaker["NJ"] == 2
        @test breaker["CKT"] == "1"
        @test breaker["NAME"] == "ALPHA\$138\$CB\$0001"
        @test breaker["TYPE"] == 2
        @test breaker["STATUS"] == 1
        @test breaker["NSTAT"] == 1
        @test breaker["X"] == 0.0001
        @test breaker["RATE1"] == 100.0
        @test breaker["RATE2"] == 110.0
        @test breaker["RATE3"] == 120.0
        disconnect = devices[2]
        @test disconnect["TYPE"] == 3
        @test disconnect["STATUS"] == 0
        @test disconnect["NSTAT"] == 1
        generic = devices[3]
        @test generic["TYPE"] == 1
        @test generic["CKT"] == "2"
    end

    @testset "terminals" begin
        terminals = alpha["TERMINALS"]
        @test length(terminals) == 6
        load_terminal = terminals[1]
        @test load_terminal["I"] == 1
        @test load_terminal["NI"] == 1
        @test load_terminal["TYP"] == "L"
        @test load_terminal["ID"] == "1"
        @test iszero(load_terminal["J"])
        @test iszero(load_terminal["K"])
        branch_terminal = terminals[4]
        @test branch_terminal["TYP"] == "B"
        @test branch_terminal["J"] == 2
        @test iszero(branch_terminal["K"])
        @test branch_terminal["ID"] == "1"
        xf2_terminal = terminals[5]
        @test xf2_terminal["TYP"] == "2"
        @test xf2_terminal["J"] == 3
        @test xf2_terminal["ID"] == "T1"
        xf3_terminal = terminals[6]
        @test xf3_terminal["TYP"] == "3"
        @test xf3_terminal["J"] == 2
        @test xf3_terminal["K"] == 3
    end

    @testset "comment-free empty-sub-block substation" begin
        bravo = substations[2]
        @test bravo["IS"] == 2
        @test bravo["NAME"] == "BRAVO"
        @test length(bravo["NODES"]) == 1
        @test bravo["NODES"][1]["I"] == 2
        @test isempty(bravo["SWITCHING DEVICES"])
        @test isempty(bravo["TERMINALS"])
    end
end

@testset "PowerModels substation conversion" begin
    pm = PowerModelsData(V35_SUBSTATION_FIXTURE)
    pm_data = pm.data

    @test haskey(pm_data, "substation")
    @test !haskey(pm_data, "substation_data")
    substations = pm_data["substation"]
    @test length(substations) == 2

    alpha = substations["1"]
    @test alpha["index"] == 1
    @test alpha["number"] == 1
    @test alpha["name"] == "ALPHA"
    @test alpha["latitude"] == 34.61
    @test alpha["longitude"] == -86.67
    @test alpha["grounding_resistance"] == 0.25
    @test alpha["source_id"] == ["substation", 1]

    @test length(alpha["nodes"]) == 3
    node1 = alpha["nodes"][1]
    @test node1["number"] == 1
    @test node1["name"] == "ALPHA\$138\$0001"
    @test node1["bus"] == 1
    @test node1["status"] == 1
    @test node1["vm"] == 1.01
    @test node1["va"] == -11.0

    node3 = alpha["nodes"][3]
    @test !haskey(node3, "vm")
    @test !haskey(node3, "va")

    @test length(alpha["switching_devices"]) == 3
    breaker = alpha["switching_devices"][1]
    @test breaker["from_node"] == 1
    @test breaker["to_node"] == 2
    @test breaker["ckt"] == "1"
    @test breaker["name"] == "ALPHA\$138\$CB\$0001"
    @test breaker["device_type"] == 2
    @test breaker["status"] == 1
    @test breaker["normal_status"] == 1
    @test breaker["x"] == 0.0001
    @test breaker["rates"] == [100.0, 110.0, 120.0]

    @test length(alpha["terminals"]) == 6
    xf3_terminal = alpha["terminals"][6]
    @test xf3_terminal["bus"] == 1
    @test xf3_terminal["node"] == 3
    @test xf3_terminal["type"] == "3"
    @test xf3_terminal["secondary_bus"] == 2
    @test xf3_terminal["tertiary_bus"] == 3
    @test xf3_terminal["id"] == "3"
    load_terminal = alpha["terminals"][1]
    @test iszero(load_terminal["secondary_bus"])
    @test iszero(load_terminal["tertiary_bus"])

    bravo = substations["2"]
    @test bravo["number"] == 2
    @test isempty(bravo["switching_devices"])
    @test isempty(bravo["terminals"])

    @testset "substation switching devices materialize into breaker/switch/generic_connector" begin
        # Buses 1-3 from the BUS records, plus the two node-buses split off bus 1:
        # node 2 (in service) and node 3 (out of service).
        @test length(pm_data["bus"]) == 5
        alpha_node(ni) = only([
            b for b in values(pm_data["bus"])
            if get(get(b, "ext", Dict{String, Any}()), "nb_substation", nothing) == 1 &&
            get(b["ext"], "nb_node", nothing) == ni
        ])
        # The out-of-service node materializes with the same encoding a BUS record with
        # IDE=4 gets, so the isolated-bus reconciliation treats it identically: two
        # substation switching devices register it as topologically connected, which
        # converts it back to PQ while its `bus_status` stays false.
        oos_bus = alpha_node(3)
        @test pm_data["has_isolated_type_buses"]
        @test oos_bus["bus_i"] in pm_data["connected_buses"]
        @test oos_bus["bus_type"] == 1
        @test oos_bus["bus_status"] == false
        # The representative node keeps bus 1 exactly as its BUS record declared it.
        @test alpha_node(1)["bus_i"] == 1
        @test alpha_node(1)["bus_type"] == 3
        @test alpha_node(1)["bus_status"] == true

        # The out-of-service node turns the isolated-bus bookkeeping on for the whole
        # case, so every other bus is checked for topological isolation too. The BRANCH
        # records connect buses 2 and 3, which therefore keep their declared treatment.
        @test pm_data["bus"][2]["bus_type"] == 1
        @test pm_data["bus"][2]["bus_status"] == true
        @test pm_data["bus"][3]["bus_type"] == 1
        @test pm_data["bus"][3]["bus_status"] == true

        breakers = collect(values(pm_data["breaker"]))
        @test length(breakers) == 1
        cb = only(breakers)
        @test cb["discrete_branch_type"] == 1
        @test cb["state"] == 1
        @test cb["ext"]["TYPE"] == 2
        @test cb["ext"]["NAME"] == "ALPHA\$138\$CB\$0001"
        @test cb["ext"]["nb_substation"] == 1
        @test cb["rating"] == 100.0

        # The TYPE 3 disconnect is already open in the RAW file.
        switches = collect(values(pm_data["switch"]))
        @test length(switches) == 1
        dsc = only(switches)
        @test dsc["discrete_branch_type"] == 0
        @test dsc["state"] == 0
        @test dsc["ext"]["NAME"] == "ALPHA\$138\$DSC\$0002"

        # The TYPE 1 generic connector is closed in the RAW file but de-energized
        # because node 3's bus is out of service.
        others = collect(values(pm_data["generic_connector"]))
        @test length(others) == 1
        gc = only(others)
        @test gc["discrete_branch_type"] == 2
        @test gc["state"] == 0
        @test gc["ext"]["NAME"] == "ALPHA\$138\$GC\$0003"
        @test oos_bus["bus_i"] in (gc["f_bus"], gc["t_bus"])
    end

    @testset "import_all" begin
        pm_all = PowerModelsData(V35_SUBSTATION_FIXTURE; import_all = true)
        subs_all = pm_all.data["substation"]
        @test length(subs_all) == 2
        @test subs_all["1"]["name"] == "ALPHA"
        @test length(subs_all["1"]["switching_devices"]) == 3
    end
end

@testset "_psse2pm_substation_node carries voltage only when stored" begin
    absent = PowerFlowFileParser._psse2pm_substation_node(
        Dict{String, Any}(
            "NI" => 5, "NAME" => "N5", "I" => 10, "STATUS" => 1, "VM" => "", "VA" => "",
        ),
    )
    @test !haskey(absent, "vm") && !haskey(absent, "va")
    @test absent["number"] == 5 && absent["bus"] == 10 && absent["status"] == 1
    present = PowerFlowFileParser._psse2pm_substation_node(
        Dict{String, Any}(
            "NI" => 6, "NAME" => "N6", "I" => 10, "STATUS" => 1, "VM" => 1.03,
            "VA" => 7.5,
        ),
    )
    @test present["vm"] == 1.03 && present["va"] == 7.5
end

@testset "_prepare_node_breaker! injects node-buses with representative keeping I" begin
    data = Dict{String, Any}(
        "source_type" => "pti",
        "bus" => Dict{Int, Any}(
            10 => Dict{String, Any}(
                "bus_i" => 10, "name" => "SUB", "base_kv" => 138.0,
                "bus_type" => 1,
                "vm" => 1.02, "va" => 0.0, "area" => 1, "zone" => 1,
                "vmin" => 0.9, "vmax" => 1.1,
            ),
        ),
        "substation" => [
            Dict{String, Any}(
                "index" => 1,
                "nodes" => [
                    Dict{String, Any}("number" => 1, "name" => "SUB\$N1",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.02, "va" => 0.0),
                    Dict{String, Any}("number" => 2, "name" => "SUB\$N2",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.01, "va" => 5.0),
                ],
                "switching_devices" => [
                    Dict{String, Any}("from_node" => 1, "to_node" => 2,
                        "status" => 1,
                        "device_type" => 2, "x" => 1e-4, "ckt" => "1",
                        "name" => "CB1",
                        "rates" => [0.0, 0.0, 0.0]),
                ],
                "terminals" => [
                    Dict{String, Any}("bus" => 10, "node" => 1, "type" => "B",
                        "secondary_bus" => 20, "id" => "1"),
                    Dict{String, Any}("bus" => 10, "node" => 2, "type" => "B",
                        "secondary_bus" => 30, "id" => "1"),
                ],
            ),
        ],
    )
    nb = PowerFlowFileParser._prepare_node_breaker!(data)
    @test 10 in nb.nb_bus_numbers
    @test length(data["bus"]) == 2
    @test nb.node_number[(1, 1)] == 10
    @test nb.node_number[(1, 2)] != 10
    new_no = nb.node_number[(1, 2)]
    # This pass runs before per-unit conversion, so angles stay in degrees.
    @test data["bus"][new_no]["va"] == 5.0
    @test data["bus"][new_no]["bus_type"] == 1
    @test nb.terminal_node[(10, "B", 30, "1")] == new_no
    @test length(nb.switches) == 1 && nb.switches[1].closed
    @test nb.switches[1].from == 10 && nb.switches[1].to == new_no
end

@testset "_prepare_node_breaker! materializes an out-of-service node as an out-of-service bus" begin
    data = Dict{String, Any}(
        "source_type" => "pti",
        "bus" => Dict{Int, Any}(
            10 => Dict{String, Any}(
                "bus_i" => 10, "name" => "SUB", "base_kv" => 138.0,
                "bus_type" => 1, "bus_status" => true,
                "vm" => 1.02, "va" => 0.0, "area" => 1, "zone" => 1,
                "vmin" => 0.9, "vmax" => 1.1,
            ),
        ),
        "substation" => [
            Dict{String, Any}(
                "index" => 1,
                "nodes" => [
                    Dict{String, Any}("number" => 1, "name" => "SUB\$N1",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.02, "va" => 0.0),
                    Dict{String, Any}("number" => 2, "name" => "SUB\$N2",
                        "bus" => 10,
                        "status" => 0),
                ],
                "switching_devices" => [
                    Dict{String, Any}("from_node" => 1, "to_node" => 2,
                        "status" => 1,
                        "device_type" => 2, "x" => 1e-4, "ckt" => "1",
                        "name" => "CB1",
                        "rates" => [0.0, 0.0, 0.0]),
                ],
                "terminals" => [
                    Dict{String, Any}("bus" => 10, "node" => 2, "type" => "L",
                        "id" => "1"),
                ],
            ),
        ],
        "load" =>
            [Dict{String, Any}("load_bus" => 10, "source_id" => ["load", 10, "1"])],
    )
    nb = PowerFlowFileParser._prepare_node_breaker!(data)
    new_no = nb.node_number[(1, 2)]
    @test new_no != 10
    @test data["bus"][new_no]["bus_type"] == 4
    @test data["bus"][new_no]["bus_status"] == false
    # The out-of-service node turns on exactly the bookkeeping an IDE=4 BUS record does.
    @test data["has_isolated_type_buses"]
    @test data["connected_buses"] isa Set{Int}
    @test data["candidate_isolated_to_pq_buses"] isa Set{Int}
    @test data["candidate_isolated_to_pv_buses"] isa Set{Int}
    # The in-service node is the representative, so bus 10 keeps its declared type.
    @test nb.node_number[(1, 1)] == 10
    @test data["bus"][10]["bus_type"] == 1
    @test data["bus"][10]["bus_status"] == true
    # The device wired to the out-of-service node is kept, not dropped.
    @test length(nb.switches) == 1
    @test nb.switches[1].from == 10 && nb.switches[1].to == new_no
    # A load with that terminal's id is routed onto the out-of-service node-bus.
    @test PowerFlowFileParser._nb_target(nb, 10, "L", nothing, "1") == new_no
end

@testset "_prepare_node_breaker! copies the source record without sharing mutable state" begin
    data = Dict{String, Any}(
        "source_type" => "pti",
        "bus" => Dict{Int, Any}(
            10 => Dict{String, Any}(
                "bus_i" => 10, "name" => "SUB", "base_kv" => 138.0,
                "bus_type" => 2, "bus_status" => true,
                "vm" => 1.02, "va" => 0.0, "area" => 1, "zone" => 1,
                "vmin" => 0.9, "vmax" => 1.1,
                "source_id" => ["bus", "10"],
            ),
        ),
        "substation" => [
            Dict{String, Any}(
                "index" => 1,
                "nodes" => [
                    Dict{String, Any}("number" => 1, "name" => "SUB\$N1",
                        "bus" => 10, "status" => 1, "vm" => 1.02, "va" => 0.0),
                    Dict{String, Any}("number" => 2, "name" => "SUB\$N2",
                        "bus" => 10, "status" => 1, "vm" => 1.02, "va" => 0.0),
                ],
                "switching_devices" => Dict{String, Any}[],
                "terminals" => Dict{String, Any}[],
            ),
        ],
    )
    nb = PowerFlowFileParser._prepare_node_breaker!(data)
    source = data["bus"][10]
    injected = data["bus"][nb.node_number[(1, 2)]]
    @test injected["source_id"] !== source["source_id"]
    @test injected["source_id"] == ["bus", "11"]
    @test source["source_id"] == ["bus", "10"]
    @test injected["ext"] !== source["ext"]
    @test injected["ext"]["nb_node"] == 2
    @test source["ext"]["nb_node"] == 1
    # Scalars are shared by value, so the copy carries the source bus attributes.
    @test injected["base_kv"] == 138.0
    @test injected["area"] == 1
end

const OOS_NODE_DEVICE_RAW = """
@!IC,SBASE,REV,XFRRAT,NXFRAT,BASFRQ
0,  100.00, 35,     0,     1, 60.00
Synthetic v35 case: one routable device of every kind wired to an out-of-service node
Bus 2 hosts substation nodes 1 and 2; node 2 is out of service and carries the devices
0 / END OF SYSTEM-WIDE DATA, BEGIN BUS DATA
     1,'BUSONE      ', 138.0000,3,   1,   1,   1,1.00000,   0.0000,1.10000,0.90000,1.10000,0.90000
     2,'BUSTWO      ', 138.0000,2,   1,   1,   1,1.00000,   0.0000,1.10000,0.90000,1.10000,0.90000
     3,'BUSTHREE    ', 138.0000,1,   1,   1,   1,1.00000,   0.0000,1.10000,0.90000,1.10000,0.90000
     4,'BUSFOUR     ', 138.0000,1,   1,   1,   1,1.00000,   0.0000,1.10000,0.90000,1.10000,0.90000
     5,'BUSFIVE     ', 138.0000,1,   1,   1,   1,1.00000,   0.0000,1.10000,0.90000,1.10000,0.90000
0 / END OF BUS DATA, BEGIN LOAD DATA
     2,'1 ',   1,   1,   1,   100.000,    25.000,     0.000,     0.000,     0.000,     0.000,   1,    1,  0,    20.000,     5.000,    1,'           V'
0 / END OF LOAD DATA, BEGIN FIXED SHUNT DATA
     2,'1 ',   1,   0.000,  20.000
0 / END OF FIXED SHUNT DATA, BEGIN GENERATOR DATA
     1,'1 ',    80.000,     0.000,    80.000,   -80.000,1.00000,   0,   0,   100.000, 0.00000E+0, 1.00000E-1, 0.00000E+0, 0.00000E+0,1.00000,1,  100.0,   120.000,     0.000, 0,1,1.0000
     2,'1 ',    30.000,     0.000,    50.000,   -50.000,1.00000,   0,   0,   100.000, 0.00000E+0, 1.00000E-1, 0.00000E+0, 0.00000E+0,1.00000,1,  100.0,   120.000,     0.000, 0,1,1.0000
0 / END OF GENERATOR DATA, BEGIN BRANCH DATA
     1,     2,'1 ', 1.00000E-02, 1.00000E-01,0.02000,'BRANCH_1_2                              ', 500.00, 500.00, 500.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00, 0.00000, 0.00000, 0.00000, 0.00000,1,1,  1.00,   1,1.0000
     1,     3,'1 ', 1.00000E-02, 1.00000E-01,0.02000,'BRANCH_1_3                              ', 500.00, 500.00, 500.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00, 0.00000, 0.00000, 0.00000, 0.00000,1,1,  1.00,   1,1.0000
     2,     3,'1 ', 1.00000E-02, 1.00000E-01,0.02000,'BRANCH_2_3                              ', 500.00, 500.00, 500.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00, 0.00000, 0.00000, 0.00000, 0.00000,1,1,  1.00,   1,1.0000
0 / END OF BRANCH DATA, BEGIN SYSTEM SWITCHING DEVICE DATA
0 / END OF SYSTEM SWITCHING DEVICE DATA, BEGIN TRANSFORMER DATA
     2,     3,     0,'T1', 1, 1, 1, 0.00000E+00, 0.00000E+00,2,'XF_2_3                                  ',1,   1,1.0000,   0,1.0000,   0,1.0000,   0,1.0000,'            '
 2.30000E-3, 2.00000E-2, 100.00
1.00000,  0.000,  0.000,  400.00,  510.00,  600.00,    0.00,    0.00,    0.00,    0.00,    0.00,    0.00,    0.00,    0.00,    0.00, 0,      0,   0,1.05000,0.95000,1.10000,0.90000,  17, 0,0.00000,0.00000, 0.000
1.00000,   0.00
     2,     4,     5,'W1', 1, 1, 1, 0.00000E+00, 0.00000E+00,2,'TR3W_2_4_5                              ',1,   1,1.0000,   0,1.0000,   0,1.0000,   0,1.0000,'            ', 0
 1.00000E-03, 1.00000E-02, 100.00, 1.00000E-03, 1.00000E-02, 100.00, 1.00000E-03, 1.00000E-02, 100.00,1.00000,   0.0000
1.00000,  0.000,  0.000,  400.00,  410.00,  420.00,    0.00,    0.00,    0.00,    0.00,    0.00,    0.00,    0.00,    0.00,    0.00, 0,      0,   0,1.10000,0.90000,1.10000,0.90000,  33, 0,0.00000,0.00000, 0.000
1.00000,  0.000,  0.000,  400.00,  410.00,  420.00,    0.00,    0.00,    0.00,    0.00,    0.00,    0.00,    0.00,    0.00,    0.00, 0,      0,   0,1.10000,0.90000,1.10000,0.90000,  33, 0,0.00000,0.00000, 0.000
1.00000,  0.000,  0.000,  400.00,  410.00,  420.00,    0.00,    0.00,    0.00,    0.00,    0.00,    0.00,    0.00,    0.00,    0.00, 0,      0,   0,1.10000,0.90000,1.10000,0.90000,  33, 0,0.00000,0.00000, 0.000
0 / END OF TRANSFORMER DATA, BEGIN AREA DATA
0 / END OF AREA DATA, BEGIN TWO-TERMINAL DC DATA
0 / END OF TWO-TERMINAL DC DATA, BEGIN VSC DC LINE DATA
0 / END OF VSC DC LINE DATA, BEGIN IMPEDANCE CORRECTION DATA
0 / END OF IMPEDANCE CORRECTION DATA, BEGIN MULTI-TERMINAL DC DATA
0 / END OF MULTI-TERMINAL DC DATA, BEGIN MULTI-SECTION LINE DATA
0 / END OF MULTI-SECTION LINE DATA, BEGIN ZONE DATA
0 / END OF ZONE DATA, BEGIN INTER-AREA TRANSFER DATA
0 / END OF INTER-AREA TRANSFER DATA, BEGIN OWNER DATA
0 / END OF OWNER DATA, BEGIN FACTS DEVICE DATA
0 / END OF FACTS DEVICE DATA, BEGIN SWITCHED SHUNT DATA
     2,'A ',1,0,1,1.05000,0.95000,     0,     0,  100.0,'            ',   0.000,   1,   1,  10.000
0 / END OF SWITCHED SHUNT DATA, BEGIN GNE DATA
0 / END OF GNE DATA, BEGIN INDUCTION MACHINE DATA
0 / END OF INDUCTION MACHINE DATA, BEGIN SUBSTATION DATA
     1,'SYNTHSUB                                ',   0.0000000,   0.0000000, 0.0000
     1,'SYNTHSUB\$NODE1                          ',     2,     1
     2,'SYNTHSUB\$NODE2                          ',     2,     0
     0 / END OF SUBSTATION NODE DATA, BEGIN SUBSTATION SWITCHING DEVICE DATA
     0 / END OF SUBSTATION SWITCHING DEVICE DATA, BEGIN SUBSTATION TERMINAL DATA
     2,  2, 'L',              '1 '
     2,  2, 'S',              '1 '
     2,  2, 'S',              'A '
     2,  2, 'M',              '1 '
     2,  2, 'B',     3,       '1 '
     2,  2, '2',     3,       'T1'
     2,  2, '3',     4,     5, 'W1'
     0 / END OF SUBSTATION TERMINAL DATA
0 / END OF SUBSTATION DATA
Q
"""

@testset "every routable section attaches its record to the terminal's node-bus" begin
    pm_data = PowerFlowFileParser.parse_file(
        IOBuffer(OOS_NODE_DEVICE_RAW);
        filetype = "raw",
    )
    # Buses 1-5 from the BUS records, the one node-bus split off bus 2, and the star bus
    # the three-winding transformer creates.
    @test length(pm_data["bus"]) == 7
    oos_bus = only([
        b for b in values(pm_data["bus"])
        if get(get(b, "ext", Dict{String, Any}()), "nb_node", nothing) == 2
    ])
    oos_no = oos_bus["bus_i"]
    @test oos_no != 2

    # No switching device ties the out-of-service node to a live node, so it stays
    # topologically isolated and out of service through the reconciliation.
    @test pm_data["has_isolated_type_buses"]
    @test !(oos_no in pm_data["connected_buses"])
    @test oos_bus["bus_type"] == 4
    @test oos_bus["bus_status"] == false

    @testset "load and its distributed generation" begin
        load = only(values(pm_data["load"]))
        @test load["load_bus"] == oos_no
        @test load["status"] == false
        # The PSS(R)E identity keeps the bus number the RAW file declared.
        @test load["source_id"][2] == 2
        dgen = only(values(pm_data["distributed_generation"]))
        @test dgen["bus"] == oos_no
        @test dgen["source_id"][2] == 2
    end

    @testset "fixed and switched shunts" begin
        shunt = only(values(pm_data["shunt"]))
        @test shunt["shunt_bus"] == oos_no
        @test shunt["status"] == false
        @test shunt["source_id"][2] == 2
        sw_shunt = only(values(pm_data["switched_shunt"]))
        @test sw_shunt["shunt_bus"] == oos_no
        @test sw_shunt["status"] == false
        @test strip(sw_shunt["sw_id"]) == "A"
        @test sw_shunt["source_id"][2] == 2
    end

    @testset "generator and the voltage-control demotion it leaves behind" begin
        gen = only([g for g in values(pm_data["gen"]) if g["source_id"][2] == "2"])
        @test gen["gen_bus"] == oos_no
        @test gen["gen_status"] == false
        # An out-of-service node-bus never takes over voltage control, but bus 2 is
        # still demoted because it no longer hosts a generator.
        @test pm_data["bus"][2]["bus_type"] == 1
        @test !haskey(
            get(pm_data["bus"][2], "ext", Dict{String, Any}()),
            "nb_bus_type_moved_to",
        )
    end

    @testset "branch and two-winding transformer" begin
        branch_by_id(f, t) = only([
            b for b in values(pm_data["branch"])
            if b["source_id"][1] == "branch" && b["source_id"][2] == f &&
            b["source_id"][3] == t
        ])
        br23 = branch_by_id(2, 3)
        @test br23["f_bus"] == oos_no
        @test br23["t_bus"] == 3
        @test br23["br_status"] == 0
        # The branches that never touch the out-of-service node stay in service.
        @test branch_by_id(1, 2)["br_status"] == 1
        @test branch_by_id(1, 3)["br_status"] == 1

        xf = only([
            b for b in values(pm_data["branch"]) if b["source_id"][1] == "transformer"
        ])
        @test xf["f_bus"] == oos_no
        @test xf["t_bus"] == 3
        @test xf["br_status"] == 0
        @test xf["source_id"][2] == 2
    end

    @testset "three-winding transformer" begin
        xf3 = only(values(pm_data["3w_transformer"]))
        # The TERMINAL record stores only the secondary bus, so matching has to probe
        # both siblings of the primary winding.
        @test xf3["bus_primary"] == oos_no
        @test xf3["bus_secondary"] == 4
        @test xf3["bus_tertiary"] == 5
        @test xf3["source_id"] == ["transformer3w", 2, 4, 5, "W1"]
        # `transformer3W_isolated_bus_modifications!` writes an Int into this field while
        # the parser initializes it as a Bool, so the winding on the dead bus reads 0
        # next to siblings that are still `true`.
        @test xf3["available_primary"] == 0
        @test xf3["available_secondary"] === true
        @test xf3["available_tertiary"] === true
        @test xf3["available"] === true
        # The star bus is synthetic and always stays in service.
        star = pm_data["bus"][xf3["star_bus"]]
        @test star["bus_type"] == 1
        @test star["bus_status"] == true
        @test star["bus_i"] in pm_data["connected_buses"]
    end
end

@testset "_nb_target_3w probes both sibling buses of a 3W winding terminal" begin
    data = Dict{String, Any}(
        "source_type" => "pti",
        "bus" => Dict{Int, Any}(
            10 => Dict{String, Any}(
                "bus_i" => 10, "name" => "SUB", "base_kv" => 138.0,
                "bus_type" => 1, "bus_status" => true,
                "vm" => 1.02, "va" => 0.0, "area" => 1, "zone" => 1,
                "vmin" => 0.9, "vmax" => 1.1,
            ),
            20 => Dict{String, Any}(
                "bus_i" => 20, "name" => "SEC", "base_kv" => 138.0,
                "bus_type" => 1, "bus_status" => true,
                "vm" => 1.0, "va" => 0.0, "area" => 1, "zone" => 1,
                "vmin" => 0.9, "vmax" => 1.1,
            ),
            30 => Dict{String, Any}(
                "bus_i" => 30, "name" => "TER", "base_kv" => 138.0,
                "bus_type" => 1, "bus_status" => true,
                "vm" => 1.0, "va" => 0.0, "area" => 1, "zone" => 1,
                "vmin" => 0.9, "vmax" => 1.1,
            ),
        ),
        "substation" => [
            Dict{String, Any}(
                "index" => 1,
                "nodes" => [
                    Dict{String, Any}("number" => 1, "name" => "SUB\$N1",
                        "bus" => 10, "status" => 1, "vm" => 1.02, "va" => 0.0),
                    Dict{String, Any}("number" => 2, "name" => "SUB\$N2",
                        "bus" => 10, "status" => 0),
                ],
                "switching_devices" => Dict{String, Any}[],
                # The RAW stored only the tertiary bus in this terminal's secondary-bus
                # column, so matching has to try both siblings.
                "terminals" => [
                    Dict{String, Any}("bus" => 10, "node" => 2, "type" => "3",
                        "secondary_bus" => 30, "tertiary_bus" => 20,
                        "id" => "3W1"),
                ],
            ),
        ],
    )
    nb = PowerFlowFileParser._prepare_node_breaker!(data)
    oos_no = nb.node_number[(1, 2)]
    @test PowerFlowFileParser._nb_target_3w(nb, 10, "3W1", (20, 30)) == oos_no
    # The sibling windings are on buses no terminal claims, so they stay put.
    @test PowerFlowFileParser._nb_target_3w(nb, 20, "3W1", (10, 30)) == 20
    @test PowerFlowFileParser._nb_target_3w(nb, 30, "3W1", (10, 20)) == 30

    xf = Dict{String, Any}(
        "bus_primary" => oos_no, "bus_secondary" => 20, "bus_tertiary" => 30,
        "available" => 1, "available_primary" => 1,
        "available_secondary" => 1, "available_tertiary" => 1,
    )
    PowerFlowFileParser.transformer3W_isolated_bus_modifications!(data, xf)
    @test xf["available_primary"] == 0
    # The windings on live buses, and so the transformer overall, stay available.
    @test xf["available_secondary"] == 1
    @test xf["available_tertiary"] == 1
    @test xf["available"] == 1
end

@testset "_prepare_node_breaker! node without stored voltage inherits bus voltage" begin
    data = Dict{String, Any}(
        "source_type" => "pti",
        "bus" => Dict{Int, Any}(
            10 => Dict{String, Any}(
                "bus_i" => 10, "name" => "SUB", "base_kv" => 138.0,
                "bus_type" => 1,
                "vm" => 1.04277, "va" => 23.04, "area" => 1, "zone" => 1,
                "vmin" => 0.9, "vmax" => 1.1,
            ),
        ),
        "substation" => [
            Dict{String, Any}(
                "index" => 1,
                "nodes" => [
                    Dict{String, Any}("number" => 1, "name" => "SUB\$N1",
                        "bus" => 10,
                        "status" => 1),
                    Dict{String, Any}("number" => 2, "name" => "SUB\$N2",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.015, "va" => 21.9),
                ],
                "switching_devices" => [
                    Dict{String, Any}("from_node" => 1, "to_node" => 2,
                        "status" => 0,
                        "device_type" => 3, "x" => 1e-4, "ckt" => "1",
                        "name" => "DSC1",
                        "rates" => [0.0, 0.0, 0.0]),
                ],
                "terminals" => Dict{String, Any}[],
            ),
        ],
    )
    nb = PowerFlowFileParser._prepare_node_breaker!(data)
    @test nb.node_number[(1, 1)] == 10
    @test data["bus"][10]["vm"] == 1.04277
    @test data["bus"][10]["va"] == 23.04
    new_no = nb.node_number[(1, 2)]
    @test new_no != 10
    @test data["bus"][new_no]["vm"] == 1.015
    @test data["bus"][new_no]["va"] == 21.9
    @test length(nb.switches) == 1 && !nb.switches[1].closed
end

@testset "_prepare_node_breaker! derives a name for blank-named nodes" begin
    data = Dict{String, Any}(
        "source_type" => "pti",
        "bus" => Dict{Int, Any}(
            10 => Dict{String, Any}(
                "bus_i" => 10, "name" => "SUB", "base_kv" => 138.0,
                "bus_type" => 1,
                "vm" => 1.02, "va" => 0.0, "area" => 1, "zone" => 1,
                "vmin" => 0.9, "vmax" => 1.1,
            ),
        ),
        "substation" => [
            Dict{String, Any}(
                "index" => 1,
                "nodes" => [
                    Dict{String, Any}("number" => 1, "name" => "SUB\$N1",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.02, "va" => 0.0),
                    Dict{String, Any}("number" => 2, "name" => "   ",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.01, "va" => 5.0),
                    Dict{String, Any}("number" => 3, "bus" => 10,
                        "status" => 1, "vm" => 1.0, "va" => 6.0),
                ],
                "switching_devices" => Dict{String, Any}[],
                "terminals" => Dict{String, Any}[],
            ),
        ],
    )
    nb = PowerFlowFileParser._prepare_node_breaker!(data)
    blank = data["bus"][nb.node_number[(1, 2)]]
    missing_name = data["bus"][nb.node_number[(1, 3)]]
    @test blank["name"] == "SUB_2"
    @test missing_name["name"] == "SUB_3"
    @test blank["name"] isa String && missing_name["name"] isa String
end

@testset "_prepare_node_breaker! warns when two terminals collide on one key" begin
    make_data(second_node::Int) = Dict{String, Any}(
        "source_type" => "pti",
        "bus" => Dict{Int, Any}(
            10 => Dict{String, Any}(
                "bus_i" => 10, "name" => "SUB", "base_kv" => 138.0,
                "bus_type" => 1, "bus_status" => true,
                "vm" => 1.02, "va" => 0.0, "area" => 1, "zone" => 1,
                "vmin" => 0.9, "vmax" => 1.1,
            ),
        ),
        "substation" => [
            Dict{String, Any}(
                "index" => 7,
                "nodes" => [
                    Dict{String, Any}("number" => 1, "name" => "SUB\$N1",
                        "bus" => 10, "status" => 1, "vm" => 1.02, "va" => 0.0),
                    Dict{String, Any}("number" => 2, "name" => "SUB\$N2",
                        "bus" => 10, "status" => 1, "vm" => 1.02, "va" => 0.0),
                ],
                "switching_devices" => Dict{String, Any}[],
                # A fixed shunt and a switched shunt sharing terminal type "S" are only
                # told apart by their RAW identifier, so the same id on both collides.
                "terminals" => [
                    Dict{String, Any}("bus" => 10, "node" => 1, "type" => "S",
                        "id" => "1"),
                    Dict{String, Any}("bus" => 10, "node" => second_node,
                        "type" => "S",
                        "id" => "1"),
                ],
            ),
        ],
    )

    conflicting = make_data(2)
    nb = @test_logs (:warn, r"Substation 7 has two TERMINAL records with key") min_level =
        Logging.Warn PowerFlowFileParser._prepare_node_breaker!(conflicting)
    # The later record wins.
    @test PowerFlowFileParser._nb_target(nb, 10, "S", nothing, "1") ==
          nb.node_number[(7, 2)]

    # Two terminals that agree on the node are not a conflict and stay silent.
    agreeing = make_data(1)
    nb_quiet =
        @test_logs min_level = Logging.Warn PowerFlowFileParser._prepare_node_breaker!(
            agreeing,
        )
    @test PowerFlowFileParser._nb_target(nb_quiet, 10, "S", nothing, "1") == 10
end

@testset "_prepare_node_breaker! normalizes a metered-end terminal bus number" begin
    data = Dict{String, Any}(
        "source_type" => "pti",
        "bus" => Dict{Int, Any}(
            10 => Dict{String, Any}(
                "bus_i" => 10, "name" => "SUB", "base_kv" => 138.0,
                "bus_type" => 1, "bus_status" => true,
                "vm" => 1.02, "va" => 0.0, "area" => 1, "zone" => 1,
                "vmin" => 0.9, "vmax" => 1.1,
            ),
        ),
        "substation" => [
            Dict{String, Any}(
                "index" => 1,
                "nodes" => [
                    Dict{String, Any}("number" => 1, "name" => "SUB\$N1",
                        "bus" => 10, "status" => 1, "vm" => 1.02, "va" => 0.0),
                    Dict{String, Any}("number" => 2, "name" => "SUB\$N2",
                        "bus" => 10, "status" => 1, "vm" => 1.02, "va" => 0.0),
                ],
                "switching_devices" => Dict{String, Any}[],
                "terminals" => [
                    Dict{String, Any}("bus" => 10, "node" => 2, "type" => "B",
                        "secondary_bus" => -20, "id" => "1"),
                ],
            ),
        ],
    )
    nb = PowerFlowFileParser._prepare_node_breaker!(data)
    # The section parsers normalize a negative (metered-end) endpoint to its magnitude
    # before routing, so the terminal key has to be normalized the same way.
    @test PowerFlowFileParser._nb_target(nb, 10, "B", 20, "1") == nb.node_number[(1, 2)]
end

@testset "_prepare_node_breaker! is a no-op without substation data" begin
    data = Dict{String, Any}(
        "source_type" => "pti",
        "bus" => Dict{Int, Any}(10 => Dict{String, Any}("bus_i" => 10)),
    )
    nb = PowerFlowFileParser._prepare_node_breaker!(data)
    @test isempty(nb.nb_bus_numbers) && length(data["bus"]) == 1
end

@testset "_nb_target resolves each section's terminal type onto the node-bus" begin
    make_data() = Dict{String, Any}(
        "source_type" => "pti",
        "bus" => Dict{Int, Any}(
            10 => Dict{String, Any}(
                "bus_i" => 10, "name" => "SUB", "base_kv" => 138.0,
                "bus_type" => 1,
                "vm" => 1.02, "va" => 0.0, "area" => 1, "zone" => 1,
                "vmin" => 0.9, "vmax" => 1.1,
            ),
        ),
        "substation" => [
            Dict{String, Any}(
                "index" => 1,
                "nodes" => [
                    Dict{String, Any}("number" => 1, "name" => "SUB\$N1",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.02, "va" => 0.0),
                    Dict{String, Any}("number" => 2, "name" => "SUB\$N2",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.01, "va" => 5.0),
                ],
                "switching_devices" => [
                    Dict{String, Any}("from_node" => 1, "to_node" => 2,
                        "status" => 1,
                        "device_type" => 2, "x" => 1e-4, "ckt" => "1",
                        "name" => "CB1",
                        "rates" => [0.0, 0.0, 0.0]),
                ],
                "terminals" => [
                    Dict{String, Any}("bus" => 10, "node" => 2, "type" => "B",
                        "secondary_bus" => 40, "id" => "1"),
                    Dict{String, Any}("bus" => 10, "node" => 2, "type" => "2",
                        "secondary_bus" => 50, "id" => "1"),
                    Dict{String, Any}("bus" => 10, "node" => 2, "type" => "L",
                        "id" => "1"),
                    Dict{String, Any}("bus" => 10, "node" => 2, "type" => "3",
                        "secondary_bus" => 20, "tertiary_bus" => 30,
                        "id" => "3W1"),
                ],
            ),
        ],
    )

    data = make_data()
    nb = PowerFlowFileParser._prepare_node_breaker!(data)
    new_no = nb.node_number[(1, 2)]
    # A switching device and a branch both key on terminal type "B" and the opposite
    # endpoint the RAW stored in the terminal's secondary-bus column.
    @test PowerFlowFileParser._nb_target(nb, 10, "B", 40, "1") == new_no
    # A two-winding transformer keys on terminal type "2".
    @test PowerFlowFileParser._nb_target(nb, 10, "2", 50, "1") == new_no
    # Loads (and the distributed generation co-located with them) key on type "L".
    @test PowerFlowFileParser._nb_target(nb, 10, "L", nothing, "1") == new_no
    # A three-winding winding keys on type "3", matched through either sibling bus.
    @test PowerFlowFileParser._nb_target_3w(nb, 10, "3W1", (20, 30)) == new_no
    @test PowerFlowFileParser._nb_target_3w(nb, 20, "3W1", (10, 30)) == 20
    @test PowerFlowFileParser._nb_target_3w(nb, 30, "3W1", (10, 20)) == 30
    # An endpoint no terminal claims keeps the bus number the RAW file declared.
    @test PowerFlowFileParser._nb_target(nb, 10, "B", 99, "1") == 10
    @test PowerFlowFileParser._nb_target(nb, 40, "B", 10, "1") == 40
end

@testset "_migrate_node_breaker_gen_bus_type! migrates PV/REF bus_type when a generator moves off the representative bus" begin
    data = Dict{String, Any}(
        "source_type" => "pti",
        "bus" => Dict{Int, Any}(
            10 => Dict{String, Any}(
                "bus_i" => 10, "name" => "SUB", "base_kv" => 138.0,
                "bus_type" => 2,
                "vm" => 1.02, "va" => 0.0, "area" => 1, "zone" => 1,
                "vmin" => 0.9, "vmax" => 1.1,
            ),
        ),
        "substation" => [
            Dict{String, Any}(
                "index" => 1,
                "nodes" => [
                    Dict{String, Any}("number" => 1, "name" => "SUB\$N1",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.02, "va" => 0.0),
                    Dict{String, Any}("number" => 2, "name" => "SUB\$N2",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.01, "va" => 5.0),
                ],
                "switching_devices" => [
                    Dict{String, Any}("from_node" => 1, "to_node" => 2,
                        "status" => 1,
                        "device_type" => 2, "x" => 1e-4, "ckt" => "1",
                        "name" => "CB1",
                        "rates" => [0.0, 0.0, 0.0]),
                ],
                "terminals" => [
                    Dict{String, Any}("bus" => 10, "node" => 2, "type" => "M", "id" => "1"),
                ],
            ),
        ],
    )
    nb = PowerFlowFileParser._prepare_node_breaker!(data)
    new_no = nb.node_number[(1, 2)]
    # The generator section attaches the machine to its terminal's node-bus while it is
    # parsed; only the voltage-control migration is left to run afterwards.
    data["gen"] = [
        Dict{String, Any}(
            "gen_bus" => PowerFlowFileParser._nb_target(nb, 10, "M", nothing, "1"),
            "source_id" => ["generator", "10", "1"],
        ),
    ]
    @test data["gen"][1]["gen_bus"] == new_no
    PowerFlowFileParser._migrate_node_breaker_gen_bus_type!(data, nb)
    @test data["bus"][new_no]["bus_type"] == 2
    @test data["bus"][10]["bus_type"] == 1
    @test data["bus"][10]["ext"]["nb_bus_type_moved_to"] == new_no
end

@testset "area slack follows the bus_type migrated onto a node-bus" begin
    data = Dict{String, Any}(
        "source_type" => "pti",
        "source_version" => "35",
        "bus" => Dict{Int, Any}(
            10 => Dict{String, Any}(
                "bus_i" => 10, "name" => "SUB", "base_kv" => 138.0,
                "bus_type" => 2,
                "vm" => 1.02, "va" => 0.0, "area" => 1, "zone" => 1,
                "vmin" => 0.9, "vmax" => 1.1,
            ),
        ),
        "area_interchange" => [
            Dict{String, Any}("area_number" => 1, "bus_number" => 10),
        ],
        "gen" => [
            Dict{String, Any}("gen_bus" => 10,
                "source_id" => ["generator", "10", "1"]),
        ],
        "substation" => [
            Dict{String, Any}(
                "index" => 1,
                "nodes" => [
                    Dict{String, Any}("number" => 1, "name" => "SUB\$N1",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.02, "va" => 0.0),
                    Dict{String, Any}("number" => 2, "name" => "SUB\$N2",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.01, "va" => 5.0),
                ],
                "switching_devices" => Dict{String, Any}[],
                "terminals" => [
                    Dict{String, Any}("bus" => 10, "node" => 2, "type" => "M", "id" => "1"),
                ],
            ),
        ],
    )
    nb = PowerFlowFileParser._prepare_node_breaker!(data)
    new_no = nb.node_number[(1, 2)]
    data["gen"][1]["gen_bus"] = PowerFlowFileParser._nb_target(nb, 10, "M", nothing, "1")
    PowerFlowFileParser._migrate_node_breaker_gen_bus_type!(data, nb)
    @test data["bus"][new_no]["bus_type"] == 2
    @test data["bus"][10]["ext"]["nb_bus_type_moved_to"] == new_no
    # No warning: the ISW bus's voltage control moved with its generator.
    @test_logs PowerFlowFileParser._psse2pm_area_slack!(data)
    @test data["bus"][new_no]["area_slack"] === true
    @test !haskey(data["bus"][10], "area_slack")
end

@testset "substation switch entries are de-energized on an isolated (IDE=4) node-bus" begin
    data = Dict{String, Any}(
        "source_type" => "pti",
        "source_version" => "35",
        "has_isolated_type_buses" => true,
        "connected_buses" => Set{Int}(),
        "candidate_isolated_to_pq_buses" => Set{Int}(),
        "candidate_isolated_to_pv_buses" => Set{Int}(),
        "bus" => Dict{Int, Any}(
            10 => Dict{String, Any}(
                "bus_i" => 10, "name" => "SUB", "base_kv" => 138.0,
                "bus_type" => 4,
                "vm" => 1.02, "va" => 0.0, "area" => 1, "zone" => 1,
                "vmin" => 0.9, "vmax" => 1.1, "bus_status" => false,
            ),
        ),
        "substation" => [
            Dict{String, Any}(
                "index" => 1,
                "nodes" => [
                    Dict{String, Any}("number" => 1, "name" => "SUB\$N1",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.02, "va" => 0.0),
                    Dict{String, Any}("number" => 2, "name" => "SUB\$N2",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.02, "va" => 0.0),
                ],
                "switching_devices" => [
                    Dict{String, Any}("from_node" => 1, "to_node" => 2,
                        "status" => 1,
                        "device_type" => 2, "x" => 1e-4, "ckt" => "1",
                        "name" => "CB1",
                        "rates" => [0.0, 0.0, 0.0]),
                ],
                "terminals" => Dict{String, Any}[],
            ),
        ],
    )
    nb = PowerFlowFileParser._prepare_node_breaker!(data)
    new_no = nb.node_number[(1, 2)]
    PowerFlowFileParser._create_node_breaker_switch_entries!(data, nb)
    @test data["bus"][new_no]["bus_type"] == 4
    cb = only(data["breaker"])
    @test cb["state"] == 0
    @test cb["discrete_branch_type"] == 1
    # The substation device endpoints are already node-bus numbers, so appending the
    # entry must not route them a second time.
    @test cb["f_bus"] == 10 && cb["t_bus"] == new_no
end

@testset "switched shunts route by RAW ID, not by their running source_id index" begin
    make_data() = Dict{String, Any}(
        "source_type" => "pti",
        "bus" => Dict{Int, Any}(
            10 => Dict{String, Any}(
                "bus_i" => 10, "name" => "SUB", "base_kv" => 138.0,
                "bus_type" => 1,
                "vm" => 1.02, "va" => 0.0, "area" => 1, "zone" => 1,
                "vmin" => 0.9, "vmax" => 1.1,
            ),
        ),
        "substation" => [
            Dict{String, Any}(
                "index" => 1,
                "nodes" => [
                    Dict{String, Any}("number" => 1, "name" => "SUB\$N1",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.02, "va" => 0.0),
                    Dict{String, Any}("number" => 2, "name" => "SUB\$N2",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.01, "va" => 5.0),
                ],
                "switching_devices" => [
                    Dict{String, Any}("from_node" => 1, "to_node" => 2,
                        "status" => 1,
                        "device_type" => 2, "x" => 1e-4, "ckt" => "1",
                        "name" => "CB1",
                        "rates" => [0.0, 0.0, 0.0]),
                ],
                "terminals" => [
                    Dict{String, Any}("bus" => 10, "node" => 2, "type" => "S", "id" => "2"),
                ],
            ),
        ],
    )
    data = make_data()
    nb = PowerFlowFileParser._prepare_node_breaker!(data)
    new_no = nb.node_number[(1, 2)]
    # The terminal names switched shunt "2", which is the second record's running
    # source_id index but the first record's PSS(R)E ID.
    @test PowerFlowFileParser._nb_target(nb, 10, "S", nothing, "2") == new_no
    @test PowerFlowFileParser._nb_target(nb, 10, "S", nothing, "9") == 10
end

@testset "v35 node-breaker case materializes node-buses and switches" begin
    file = joinpath(@__DIR__, "fixtures", "synthetic_v35_node_breaker.raw")
    pm_data = PowerModelsData(file).data
    @test length(pm_data["bus"]) == 6

    # Two TYPE 2 circuit breakers land in the breaker table; the TYPE 3 disconnect
    # lands in the switch table.
    breakers = collect(values(pm_data["breaker"]))
    @test length(breakers) == 2
    @test all(b["discrete_branch_type"] == 1 for b in breakers)
    @test all(b["state"] == 1 for b in breakers)
    @test all(b["ext"]["TYPE"] == 2 for b in breakers)
    switches = collect(values(pm_data["switch"]))
    @test length(switches) == 1
    o = only(switches)
    @test o["discrete_branch_type"] == 0
    @test o["state"] == 0
    @test o["f_bus"] != o["t_bus"]
    @test o["ext"]["NAME"] == "NBFCSUB\$DSC\$23"
    @test o["ext"]["TYPE"] == 3
    @test o["ext"]["nb_substation"] == 1

    node_bus(ni) = only([
        b for b in values(pm_data["bus"])
        if get(get(b, "ext", Dict{String, Any}()), "nb_node", nothing) == ni
    ])["bus_i"]
    @test node_bus(1) == 2

    branches = collect(values(pm_data["branch"]))
    br21 = only([b for b in branches if b["source_id"][2] == 2 && b["source_id"][3] == 1])
    br23 = only([b for b in branches if b["source_id"][2] == 2 && b["source_id"][3] == 3])
    @test br21["f_bus"] == 2
    @test br23["f_bus"] == node_bus(4)
    @test br23["f_bus"] != 2

    nb_buses = [
        b for b in values(pm_data["bus"])
        if haskey(get(b, "ext", Dict{String, Any}()), "nb_node")
    ]
    @test length(nb_buses) == 4
    @test all(b["ext"]["nb_bus"] == 2 for b in nb_buses)
    @test all(b["ext"]["nb_substation"] == 1 for b in nb_buses)
end

@testset "v35 populated SUBSTATION section materializes" begin
    file = joinpath(@__DIR__, "fixtures", "synthetic_v35_substation.raw")
    pm_data = PowerModelsData(file).data
    @test length(pm_data["bus"]) == 4
    # One TYPE 2 breaker and one TYPE 3 switch, so the device chain spans both sections.
    devices = vcat(
        collect(values(pm_data["breaker"])),
        collect(values(pm_data["switch"])),
    )
    @test length(pm_data["breaker"]) == 1
    @test length(pm_data["switch"]) == 1
    @test all(s["state"] == 1 for s in devices)
    ends = [Set((s["f_bus"], s["t_bus"])) for s in devices]
    touched = union(ends...)
    @test 1 in touched && 2 in touched
    @test !(Set((1, 2)) in ends)
end

@testset "v35 substation TYPE 1 generic connector materializes into the generic_connector table" begin
    file = joinpath(@__DIR__, "fixtures", "synthetic_v35_generic_connector.raw")
    pm_data = PowerModelsData(file).data
    @test length(pm_data["bus"]) == 4

    @test length(pm_data["breaker"]) == 1
    @test isempty(pm_data["switch"])
    @test length(pm_data["generic_connector"]) == 1

    other = only(values(pm_data["generic_connector"]))
    @test other["discrete_branch_type"] == 2
    @test other["state"] == 1
    @test other["ext"]["TYPE"] == 1
end

@testset "v35 substation switching device with unsupported TYPE warns and lands in generic_connector" begin
    raw = read_fixture(V35_SUBSTATION_FIXTURE)
    unsupported = replace(
        raw,
        "     2,  3, '2 ','ALPHA\$138\$GC\$0003                       ',     1,     1,     1, 0.00010,   0.00,   0.00,   0.00\n" => "     2,  3, '2 ','ALPHA\$138\$GC\$0003                       ',     9,     1,     1, 0.00010,   0.00,   0.00,   0.00\n",
    )
    pm_data = @test_logs(
        (:warn, r"ALPHA\$138\$GC\$0003.*unsupported TYPE=9"),
        match_mode = :any,
        parse_file(IOBuffer(unsupported); filetype = "raw"),
    )
    @test length(pm_data["breaker"]) == 1
    @test length(pm_data["switch"]) == 1
    gc = only(values(pm_data["generic_connector"]))
    @test gc["ext"]["TYPE"] == 9
    @test gc["ext"]["NAME"] == "ALPHA\$138\$GC\$0003"
end

@testset "system-level SWITCHING DEVICE with unsupported STYPE warns and is skipped" begin
    # V35_SUBSTATION_FIXTURE's own substation switching devices (one breaker, one
    # switch, one generic connector) materialize regardless, so the counts below are
    # that fixture's baseline; the point of this test is that the injected bad
    # system-level record adds nothing on top of it.
    raw = read_fixture(V35_SUBSTATION_FIXTURE)
    unsupported = replace(
        raw,
        "0 / END OF BRANCH DATA, BEGIN SYSTEM SWITCHING DEVICE DATA\n0 / END OF SYSTEM SWITCHING DEVICE DATA, BEGIN TRANSFORMER DATA\n" => "0 / END OF BRANCH DATA, BEGIN SYSTEM SWITCHING DEVICE DATA\n     1,     2,'1 ', 0.00010, 100.00, 110.00, 120.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00,   0.00,     1,     1,     1,     9,'SW_UNKNOWN                              '\n0 / END OF SYSTEM SWITCHING DEVICE DATA, BEGIN TRANSFORMER DATA\n",
    )
    pm_data = @test_logs(
        (:warn, r"Unsupported SWITCHING DEVICE STYPE=9"),
        match_mode = :any,
        parse_file(IOBuffer(unsupported); filetype = "raw"),
    )
    @test length(pm_data["breaker"]) == 1
    @test length(pm_data["switch"]) == 1
    @test length(pm_data["generic_connector"]) == 1
end

@testset "an out-of-service node survives the isolated-bus reconciliation" begin
    # This case has an IDE=4 BUS record (bus 4, carrying no devices), so
    # `has_isolated_type_buses` is true and the end-of-pipeline isolated-bus
    # reconciliation runs. The out-of-service node must come through it still out of
    # service, even though an in-service switching device ties it to a live node.
    file = joinpath(@__DIR__, "fixtures", "synthetic_v35_oos_node_isolated_bus.raw")
    pm_data = PowerModelsData(file).data
    @test pm_data["has_isolated_type_buses"]

    node_bus(ni) = only([
        b for b in values(pm_data["bus"])
        if get(get(b, "ext", Dict{String, Any}()), "nb_node", nothing) == ni
    ])

    # An in-service breaker ties the out-of-service node to a live node, so it is
    # topologically connected and the reconciliation converts it back to PQ, exactly as
    # it would a BUS record with IDE=4 in the same position. Its `bus_status` stays
    # false, and everything wired to it is out of service.
    oos_bus = node_bus(4)
    @test oos_bus["bus_i"] in pm_data["connected_buses"]
    @test oos_bus["bus_type"] == 1
    @test oos_bus["bus_status"] == false

    # The in-service node-buses keep their normal treatment.
    @test node_bus(1)["bus_i"] == 1
    @test node_bus(1)["bus_type"] == 3
    @test node_bus(2)["bus_type"] == 1
    @test node_bus(2)["bus_status"] == true

    # The IDE=4 file bus carries no devices, so it keeps its declared treatment.
    @test pm_data["bus"][4]["bus_type"] == 4
    @test pm_data["bus"][4]["bus_status"] == false

    # The device tying the out-of-service node to a live node is kept and de-energized.
    breakers = collect(values(pm_data["breaker"]))
    @test length(breakers) == 2
    oos_cb = only([b for b in breakers if b["ext"]["NAME"] == "SYNTHSUB\$CB\$2"])
    @test oos_cb["state"] == 0
    @test oos_bus["bus_i"] in (oos_cb["f_bus"], oos_cb["t_bus"])
    live_cb = only([b for b in breakers if b["ext"]["NAME"] == "SYNTHSUB\$CB\$1"])
    @test live_cb["state"] == 1
    @test only(values(pm_data["switch"]))["state"] == 1

    # BRANCH_1_3's bus-1 endpoint is terminal-wired to the out-of-service node, so the
    # record is created on that bus and `branch_isolated_bus_modifications!` sees the
    # dead endpoint while the BRANCH section is still being parsed.
    branches = collect(values(pm_data["branch"]))
    br13 = only([b for b in branches if b["source_id"][2] == 1 && b["source_id"][3] == 3])
    @test br13["f_bus"] == oos_bus["bus_i"]
    @test br13["br_status"] == 0
    # The branches that never touch the out-of-service node stay in service.
    for (f, t) in ((1, 2), (2, 3))
        br = only([b for b in branches
                   if b["source_id"][2] == f && b["source_id"][3] == t])
        @test br["br_status"] == 1
    end
end

@testset "node-buses inherit the bus voltage when the RAW stores none" begin
    file = joinpath(@__DIR__, "fixtures", "synthetic_v35_node_voltage_inherit.raw")
    pm_data = PowerModelsData(file).data
    nb_buses = [
        b for b in values(pm_data["bus"])
        if haskey(get(b, "ext", Dict{String, Any}()), "nb_node")
    ]
    @test length(nb_buses) == 3
    for b in nb_buses
        @test isapprox(b["vm"], 1.05; atol = 1e-6)
        # Validation converts bus angles to radians after materialization.
        @test isapprox(b["va"], deg2rad(3.0); atol = 1e-6)
    end
end

@testset "materialization is a no-op without substation nodes" begin
    file = joinpath(@__DIR__, "fixtures", "synthetic_v35_two_terminal_dc.raw")
    pm_data = PowerModelsData(file).data
    @test length(pm_data["bus"]) == 3
    @test isempty(pm_data["switch"])
end

@testset "switching device declaring a line shunt" begin
    # A BRANCH row with a '@' or '*' CKT is a breaker or switch, and the RAW
    # System Switching Device record has no GI/BI/GJ/BJ columns at all -- such a
    # row is malformed input. The admittance is relocated to the bus at the end
    # it was declared on rather than dropped or hung off the switching device.
    file = joinpath(PSSE_RAW_DIR, "psse_v35_switching_device_line_shunt.raw")
    pm_data = PowerModelsData(file).data

    @test length(pm_data["breaker"]) == 1
    @test length(pm_data["branch"]) == 2

    shunts = collect(values(pm_data["shunt"]))
    # Only the I end carried non-zero values; the all-zero J end adds nothing.
    @test length(shunts) == 1
    salvaged = only(shunts)
    @test salvaged["shunt_bus"] == 1
    @test salvaged["gs"] == 0.001
    @test salvaged["bs"] == -0.025
    @test salvaged["status"] == 1
    @test salvaged["source_id"] == ["branch shunt", 1, 3, "@1", "I"]

    # The relocation must be announced, not silent.
    @test_logs(
        (:warn, r"declares a line-connected shunt at its I end"),
        match_mode = :any,
        PowerModelsData(file)
    )
end

@testset "a substation declaring no nodes has no PowerModels representation" begin
    # A SUBSTATION record whose node block is empty attaches to no bus. pti.jl keeps it,
    # but it has nothing to contribute to the pm dict, so the conversion drops it.
    raw = read_fixture(V35_SUBSTATION_FIXTURE)
    nodeless =
        "@! BEGIN SUBSTATION DATA BLOCK\n" *
        "     3,'CHARLIE                                 ',   0.0000000,   0.0000000, 0.0000\n" *
        "     0 / END OF SUBSTATION NODE DATA, BEGIN SUBSTATION SWITCHING DEVICE DATA\n" *
        "     0 / END OF SUBSTATION SWITCHING DEVICE DATA, BEGIN SUBSTATION TERMINAL DATA\n" *
        "     0 / END OF SUBSTATION TERMINAL DATA\n"
    patched = replace(
        raw,
        "0 / END OF SUBSTATION DATA\n" => nodeless * "0 / END OF SUBSTATION DATA\n",
    )
    @test patched != raw
    path = joinpath(mktempdir(), "nodeless_substation.raw")
    write(path, patched)

    @test length(PFP.parse_pti(path)["SUBSTATION DATA"]) == 3

    pm = @test_logs(
        (:info, r"Dropped 1 PSS\(R\)E substation\(s\) that declare no nodes"),
        match_mode = :any,
        PowerModelsData(path)
    )
    substations = pm.data["substation"]
    @test sort([s["number"] for s in values(substations)]) == [1, 2]
    @test sort([s["index"] for s in values(substations)]) == [1, 2]

    sys = PFP.build_openapi_system(pm)
    @test sort([
        PFP.get_value(s, :number) for
        s in PFP.get_supplemental_attributes(sys, "Substation")
    ]) == [1, 2]

    # Switching devices between nodes that do not exist are malformed rather than a
    # placeholder, so dropping that record is announced on its own.
    with_devices =
        "@! BEGIN SUBSTATION DATA BLOCK\n" *
        "     4,'DELTA                                   ',   0.0000000,   0.0000000, 0.0000\n" *
        "     0 / END OF SUBSTATION NODE DATA, BEGIN SUBSTATION SWITCHING DEVICE DATA\n" *
        "     1,  2, '1 ','DELTA\$138\$CB\$0001                       ',     2,     1,     1, 0.00010,   0.00,   0.00,   0.00\n" *
        "     0 / END OF SUBSTATION SWITCHING DEVICE DATA, BEGIN SUBSTATION TERMINAL DATA\n" *
        "     0 / END OF SUBSTATION TERMINAL DATA\n"
    write(
        path,
        replace(
            patched,
            "0 / END OF SUBSTATION DATA\n" => with_devices * "0 / END OF SUBSTATION DATA\n",
        ),
    )
    pm = @test_logs(
        (:warn, r"Substation 4 declares no nodes but has 1 switching device\(s\)"),
        (:info, r"Dropped 2 PSS\(R\)E substation\(s\) that declare no nodes"),
        match_mode = :any,
        PowerModelsData(path)
    )
    @test sort([s["number"] for s in values(pm.data["substation"])]) == [1, 2]
end

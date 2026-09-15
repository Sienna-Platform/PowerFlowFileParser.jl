isdefined(Base, :__precompile__) && __precompile__()

module PowerFlowFileParser

#################################################################################
# Exports

export PowerModelsData
export parse_file
export OpenAPISystem
export to_json
export build_openapi_system

#################################################################################
# Imports

import LinearAlgebra
import DataStructures: SortedDict
import Unicode: normalize
import JSON
import OpenAPI
import InfrastructureCoreOpenAPIModels
import PowerCoreOpenAPIModels
import PowerOpenAPIModels
import PowerOperationsOpenAPIModels
const IC = InfrastructureCoreOpenAPIModels
const PC = PowerCoreOpenAPIModels
const PD = PowerOpenAPIModels
const PO = PowerOperationsOpenAPIModels

import OpenAPI.Runtime: Absent, ABSENT

import InfrastructureSystems
const IS = InfrastructureSystems

import InfrastructureSystems:
    DataFormatError,
    LinearCurve

#################################################################################
# Includes

include("definitions.jl")
include("power_models_data.jl")
include("im_io.jl")
include("pm_io.jl")
include("openapi/units.jl")
include("openapi/identity.jl")
include("openapi/container.jl")
include("openapi/serialize.jl")
include("openapi/topology.jl")
include("openapi/cost.jl")
include("openapi/load.jl")
include("openapi/generation.jl")
include("openapi/branch.jl")
include("openapi/switch_breaker.jl")
include("openapi/dc_branch.jl")
include("openapi/shunt.jl")
include("openapi/attributes.jl")
include("openapi/device_base.jl")
include("openapi/build.jl")

#################################################################################

using DocStringExtensions

@template (FUNCTIONS, METHODS) = """
                                 $(TYPEDSIGNATURES)
                                 $(DOCSTRING)
                                 """

#################################################################################

end

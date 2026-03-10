isdefined(Base, :__precompile__) && __precompile__()

module PowerFlowFileParser

#################################################################################
# Exports

export PowerModelsData
export PowerFlowDataNetwork
export parse_file
export CaseComparisonData
export ComponentDiff
export NonConformingLoadFlag
export NonConformingReason
export FLAGGED_IN_DATA
export LOW_VARIATION
export compile_base_case
export compute_case_diff
export unavailable_components
export diff_summary
export flag_nonconforming_loads
export nonconforming_load_summary

#################################################################################
# Imports

import PowerFlowData
import LinearAlgebra
import DataStructures: SortedDict
import Unicode: normalize
import YAML
import Printf: @sprintf

import InfrastructureSystems
const IS = InfrastructureSystems

import InfrastructureSystems:
    DataFormatError

#################################################################################
# Includes

include("definitions.jl")
include("powerflowdata_data.jl")
include("power_models_data.jl")
include("im_io.jl")
include("pm_io.jl")
include("case_comparison.jl")

#################################################################################

using DocStringExtensions

@template (FUNCTIONS, METHODS) = """
                                 $(TYPEDSIGNATURES)
                                 $(DOCSTRING)
                                 """

#################################################################################

end

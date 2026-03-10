const SKIP_PM_VALIDATION = false

const PSSE_PARSER_TAP_RATIO_UBOUND = 1.5
const PSSE_PARSER_TAP_RATIO_LBOUND = 0.5
const INFINITE_BOUND = 1e6

const PS_MAX_LOG = parse(Int, get(ENV, "PS_MAX_LOG", "50"))

const BRANCH_BUS_VOLTAGE_DIFFERENCE_TOL = 0.01
const PARSER_TAP_RATIO_CORRECTION_TOL = 1e-4
const ZERO_IMPEDANCE_REACTANCE_THRESHOLD = 1e-6

# Winding names for three-winding transformers
const WINDING_NAMES = Dict(
    1 => "primary",
    2 => "secondary",
    3 => "tertiary",
)

const TRANSFORMER3W_PARAMETER_NAMES = [
    "COD", "CONT", "NOMV", "WINDV", "RMA", "RMI",
    "NTP", "VMA", "VMI", "RATA", "RATB", "RATC",
]

const SKIP_PM_VALIDATION = false
const PS_MAX_LOG = parse(Int, get(ENV, "PS_MAX_LOG", "50"))

const DEFAULT_BASE_MVA = 100.0

const DEFAULT_SYSTEM_FREQUENCY = 60.0

const INFINITE_TIME = 1e4
const START_COST = 1e8
const INFINITE_COST = 1e8
const INFINITE_BOUND = 1e6
const BRANCH_BUS_VOLTAGE_DIFFERENCE_TOL = 0.01

const PSSE_PARSER_TAP_RATIO_UBOUND = 1.5
const PSSE_PARSER_TAP_RATIO_LBOUND = 0.5
const PARSER_TAP_RATIO_CORRECTION_TOL = 1e-5

const ZERO_IMPEDANCE_REACTANCE_THRESHOLD = 1e-4

# PSS/E bus type codes (RAW bus record IDE field), carried through the pm dict's
# "bus_type" unchanged. Matpower uses the same encoding. The codes index
# PM_BUS_TYPE_NAMES, so the two cannot drift.
const PM_BUS_TYPE_PQ = 1
const PM_BUS_TYPE_PV = 2
const PM_BUS_TYPE_REF = 3
const PM_BUS_TYPE_ISOLATED = 4
const PM_BUS_TYPE_NAMES = ("PQ", "PV", "REF", "ISOLATED")

# PSS/E states transformer magnetizing admittance and the impedance of a CZ=3 winding in
# micro-units (micromho, micro-ohm); every such field scales by this to reach base units.
const PSSE_MICRO_UNIT_SCALE = 1e-6

# Winding names for three-winding transformers
const WINDING_NAMES = Dict(
    1 => "primary",
    2 => "secondary",
    3 => "tertiary",
)

const TRANSFORMER3W_PARAMETER_NAMES = [
    "COD", "NOMV", "WINDV", "RMA", "RMI",
    "NTP", "VMA", "VMI", "RATA", "RATB", "RATC",
]

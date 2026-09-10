# PowerModels' PIECEWISE_LINEAR / POLYNOMIAL cost
# models already describe a $/hr curve directly (MATPOWER Table B-4), so unlike PTDP's
# table-driven cost.jl there is no fuel-price/heat-rate separation here: a MATPOWER-shaped
# generator cost becomes a `CostCurve`, never a `FuelCurve`.

"""The schema's declared `vom_cost` default for `CostCurve`/`FuelCurve`: a zero
linear input-output curve (Core/common.json defs.CostCurve.properties.vom_cost.default).
`vom_cost` is schema-`required`, so every emitted curve must carry it explicitly —
the generated `CostCurve`/`FuelCurve` constructors default it to `nothing`."""
function _zero_vom_cost()
    return PC.InputOutputCurve(;
        function_data = PC.InputOutputCurveFunctionData(
            IC.LinearFunctionData(;
                proportional_term = 0.0,
                constant_term = 0.0,
            ),
        ),
    )
end

"""A `CostCurve` with a zero linear value curve, matching PSCB's `zero(CostCurve)`
(`NaturalUnit`, not `ComponentBaseUnit`) — the fallback for every generator/load type that
has no cost data to read from a PowerModels dict."""
function _zero_cost_curve()
    return PC.CostCurve(;
        power_units = "NATURAL_UNITS",
        value_curve = PC.ValueCurve(
            PC.InputOutputCurve(;
                function_data = PC.InputOutputCurveFunctionData(
                    IC.LinearFunctionData(;
                        proportional_term = 0.0,
                        constant_term = 0.0,
                    ),
                ),
            ),
        ),
        vom_cost = _zero_vom_cost(),
    )
end

"""
Piecewise-linear cost from MATPOWER's alternating (MW, \$/hr) pairs (cost model `1`).

Ported from PSCB's PIECEWISE_LINEAR branch: the fixed cost is the y-intercept of the
first segment's slope, and the variable cost is the same points shifted down by that
fixed cost — PSCB's own comment expects a future update to fold the two together
instead of separating them here.
"""
function _piecewise_linear_cost(cost_component::Vector{Float64})
    power_p = [c for (ix, c) in enumerate(cost_component) if isodd(ix)]
    cost_p = [c for (ix, c) in enumerate(cost_component) if iseven(ix)]
    points = collect(zip(power_p, cost_p))
    (first_x, first_y), (second_x, second_y) = points[1], points[2]
    first_slope = (second_y - first_y) / (second_x - first_x)
    fixed = max(0.0, first_y - first_slope * first_x)
    shifted = [IC.XYCoords(; x = x, y = y - fixed) for (x, y) in points]
    return IC.PiecewiseLinearData(; points = shifted), fixed
end

"""
Polynomial cost from MATPOWER's coefficients, highest degree first (cost model `2`).

Ported from PSCB's POLYNOMIAL branch: coefficients divide by `sys_mbase^i` (`i` counted
from the lowest degree up), undoing PowerModels' own per-unit correction back onto a
device-base representation — exact when `mbase == sys_mbase`, PSCB's implicit assumption.
Only linear and quadratic polynomials are supported; anything higher throws, matching
PSCB.
"""
function _polynomial_cost(gen_name::AbstractString, cost_component::Vector{Float64},
    sys_mbase::Float64)
    coeffs = Dict(
        i => c / sys_mbase^i for
        (i, c) in enumerate(reverse(cost_component[1:(end - 1)]))
    )
    quadratic_degrees = (2, 1, 0)
    if !(keys(coeffs) <= Set(quadratic_degrees))
        throw(
            IS.DataFormatError(
                "$gen_name: can only handle polynomials up to degree two; given coefficients $coeffs",
            ),
        )
    end
    quadratic_term, proportional_term, constant_term =
        (get(coeffs, deg, 0.0) for deg in quadratic_degrees)
    return IC.QuadraticFunctionData(;
        quadratic_term = quadratic_term,
        proportional_term = proportional_term,
        constant_term = constant_term,
    )
end

"""
Thermal generation cost from a MATPOWER-shaped `pm_gen`'s `"model"`/`"cost"` fields.

Model `1` is PIECEWISE_LINEAR, `2` is POLYNOMIAL (MATPOWER manual Table B-4). A generator
carrying neither key gets a zero natural-unit cost curve, matching PSCB's own fallback
(and its warning). The resulting variable cost is `COMPONENT_BASE` per-unit — PSCB's
`CostCurve(_, IS.DU)` — never natural units, unlike the zero-cost fallback.
"""
function make_thermal_cost(gen_name::AbstractString, pm_gen::Dict, sys_mbase::Float64)
    if !haskey(pm_gen, "model")
        @warn "Generator cost data not included for Generator: $gen_name"
        return PC.ThermalGenerationCost(;
            variable_operation_cost = _zero_cost_curve(),
            fixed = 0.0,
            start_up = 0.0,
            shut_down = 0.0,
        )
    end
    cost_component = Float64.(pm_gen["cost"])
    model = pm_gen["model"]
    if model == 1
        function_data, fixed = _piecewise_linear_cost(cost_component)
    elseif model == 2
        function_data = _polynomial_cost(gen_name, cost_component, sys_mbase)
        fixed = pm_gen["ncost"] >= 1 ? last(cost_component) : 0.0
    else
        throw(IS.DataFormatError("$gen_name: unsupported generator cost model=$model"))
    end
    return PC.ThermalGenerationCost(;
        variable_operation_cost = PC.CostCurve(;
            power_units = "COMPONENT_BASE",
            value_curve = PC.ValueCurve(
                PC.InputOutputCurve(;
                    function_data = PC.InputOutputCurveFunctionData(function_data),
                ),
            ),
            vom_cost = _zero_vom_cost(),
        ),
        fixed = fixed,
        start_up = pm_gen["startup"],
        shut_down = pm_gen["shutdown"],
    )
end

"""Curtailment cost for a hydro generator: PSCB never derives one from pm data."""
make_hydro_cost() =
    PC.HydroGenerationCost(; variable_operation_cost = _zero_cost_curve(), fixed = 0.0)

"""Operating cost for a renewable generator: PSCB never derives one from pm data."""
make_renewable_cost() =
    PC.RenewableGenerationCost(; variable_operation_cost = _zero_cost_curve())

"""Operating cost for an interruptible load: PSCB never derives one from pm data."""
make_load_cost() =
    PC.LoadCost(; variable_operation_cost = _zero_cost_curve(), fixed = 0.0)

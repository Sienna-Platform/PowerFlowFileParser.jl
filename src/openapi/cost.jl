# MATPOWER cost models (manual Table B-4) are $/h curves, so a generator cost becomes a
# `CostCurve`, never a `FuelCurve`. Every cost curve is in natural units: MW on x, $/h on y.
# Values of oneOf fields (`ProductionVariableCostCurve`, `*CostStartUp`) are wrapped by hand:
# these kwarg constructors bypass `set_value!`'s coercion.

"""The schema's declared `vom_cost` default for `CostCurve`/`FuelCurve`: a zero
linear input-output curve (Core/common.json defs.CostCurve.properties.vom_cost.default).
`vom_cost` is schema-`required`, so every emitted curve must carry it explicitly —
the generated `CostCurve`/`FuelCurve` constructors default it to `nothing`."""
function _zero_vom_cost()
    return PC.InputOutputCurve(;
        curve_type = "INPUT_OUTPUT",
        function_data = PC.InputOutputCurveFunctionData(
            IC.LinearFunctionData(;
                function_type = "LINEAR",
                proportional_term = 0.0,
                constant_term = 0.0,
            ),
        ),
    )
end

"""A `CostCurve` with a zero linear value curve, matching PSCB's `zero(CostCurve)`: the
fallback for every generator/load type that has no cost data to read from a PowerModels dict."""
function _zero_cost_curve()
    return PC.CostCurve(;
        variable_cost_type = "COST",
        value_curve = PC.ValueCurve(
            PC.InputOutputCurve(;
                curve_type = "INPUT_OUTPUT",
                function_data = PC.InputOutputCurveFunctionData(
                    IC.LinearFunctionData(;
                        function_type = "LINEAR",
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
Piecewise-linear cost from the pm dict's alternating (x, \$/h) pairs (cost model `1`), with
x per-unit on `sys_mbase` (`_make_per_unit!`); the points are emitted in MW.

Ported from PSCB's PIECEWISE_LINEAR branch: the fixed cost is the y-intercept of the
first segment's slope, and the variable cost is the same points shifted down by that
fixed cost.
"""
function _piecewise_linear_cost(cost_component::Vector{Float64}, sys_mbase::Float64)
    power_p = [c * sys_mbase for (ix, c) in enumerate(cost_component) if isodd(ix)]
    cost_p = [c for (ix, c) in enumerate(cost_component) if iseven(ix)]
    points = collect(zip(power_p, cost_p))
    (first_x, first_y), (second_x, second_y) = points[1], points[2]
    first_slope = (second_y - first_y) / (second_x - first_x)
    fixed = max(0.0, first_y - first_slope * first_x)
    shifted = [IC.XYCoords(; x = x, y = y - fixed) for (x, y) in points]
    return IC.PiecewiseLinearData(; function_type = "PIECEWISE_LINEAR", points = shifted),
    fixed
end

"""
Polynomial cost from MATPOWER's coefficients, highest degree first (cost model `2`).

`_make_per_unit!` multiplied the degree-`i` coefficient by `sys_mbase^i`; dividing it back
gives \$/h against MW. `make_thermal_cost` carries the constant term as the fixed cost.
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
        function_type = "QUADRATIC",
        quadratic_term = quadratic_term,
        proportional_term = proportional_term,
        constant_term = constant_term,
    )
end

"""
Thermal generation cost from a MATPOWER-shaped `pm_gen`'s `"model"`/`"cost"` fields.

Model `1` is PIECEWISE_LINEAR, `2` is POLYNOMIAL (MATPOWER manual Table B-4). A generator
carrying neither key gets a zero cost curve, matching PSCB's own fallback (and its warning).
"""
function make_thermal_cost(gen_name::AbstractString, pm_gen::Dict, sys_mbase::Float64)
    if !haskey(pm_gen, "model")
        @warn "Generator cost data not included for Generator: $gen_name"
        return PC.ThermalGenerationCost(;
            cost_type = "THERMAL",
            variable_operation_cost = PC.ProductionVariableCostCurve(_zero_cost_curve()),
            fixed = 0.0,
            start_up = PC.ThermalGenerationCostStartUp(0.0),
            shut_down = 0.0,
        )
    end
    cost_component = Float64.(pm_gen["cost"])
    model = pm_gen["model"]
    if model == 1
        function_data, fixed = _piecewise_linear_cost(cost_component, sys_mbase)
    elseif model == 2
        function_data = _polynomial_cost(gen_name, cost_component, sys_mbase)
        fixed = pm_gen["ncost"] >= 1 ? last(cost_component) : 0.0
    else
        throw(IS.DataFormatError("$gen_name: unsupported generator cost model=$model"))
    end
    return PC.ThermalGenerationCost(;
        cost_type = "THERMAL",
        variable_operation_cost = PC.ProductionVariableCostCurve(
            PC.CostCurve(;
                variable_cost_type = "COST",
                value_curve = PC.ValueCurve(
                    PC.InputOutputCurve(;
                        curve_type = "INPUT_OUTPUT",
                        function_data = PC.InputOutputCurveFunctionData(function_data),
                    ),
                ),
                vom_cost = _zero_vom_cost(),
            ),
        ),
        fixed = fixed,
        start_up = PC.ThermalGenerationCostStartUp(pm_gen["startup"]),
        shut_down = pm_gen["shutdown"],
    )
end

"""Curtailment cost for a hydro generator: PSCB never derives one from pm data."""
make_hydro_cost() =
    PC.HydroGenerationCost(;
        cost_type = "HYDRO_GEN",
        variable_operation_cost = PC.ProductionVariableCostCurve(_zero_cost_curve()),
        fixed = 0.0,
    )

"""Operating cost for a renewable generator: PSCB never derives one from pm data."""
make_renewable_cost() =
    PC.RenewableGenerationCost(;
        cost_type = "RENEWABLE",
        variable_operation_cost = _zero_cost_curve(),
    )

"""Operating cost for an interruptible load: PSCB never derives one from pm data."""
make_load_cost() =
    PC.LoadCost(;
        cost_type = "LOAD",
        variable_operation_cost = _zero_cost_curve(),
        fixed = 0.0,
    )

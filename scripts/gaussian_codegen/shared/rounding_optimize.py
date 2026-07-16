"""Rounding-aware refinement for fixed-degree rational approximations.

AAA is an excellent near-minimax seed, but its continuous worst-error objective does
not minimize the number of representable inputs that round to the wrong output
integer.  When the approximation is already comfortably below one output ULP,
that population closely tracks mean absolute error in output-ULP units.  This
module therefore refines an AAA seed with a deterministic soft-L1 objective over
uniformly sampled raw inputs.

Optimization happens in a Chebyshev basis on the fitted interval.  This keeps
the nonlinear least-squares problem well conditioned; coefficients are converted
back to the ascending monomial basis expected by the Move Horner evaluator only
after convergence.  The denominator's Chebyshev constant is fixed to one to
remove the rational's arbitrary scale factor, and the final monomial form is
renormalized to ``D(0) = 1`` before serialization.

This is a candidate generator, not the final proof.  Callers must quantize the
result and run the exact integer mirror, monotonicity, overflow, and error gates
before accepting a table.
"""
from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Sequence

import numpy as np
from numpy.polynomial import Chebyshev, Polynomial
from scipy.optimize import least_squares, minimize
from scipy.special import expit

from gaussian_codegen.shared.arithmetic import horner_eval, mul_div_nearest
from gaussian_codegen.shared.move_emit import quantize


@dataclass(frozen=True)
class RoundingScore:
    """Proxy score against correctly rounded outputs on a fixed raw-input grid."""

    samples: int
    correctly_rounded: int
    correctly_rounded_fraction: float
    mean_absolute_error_ulp: float


@dataclass(frozen=True)
class QuantizedRoundingScore:
    """Sample score through quantized coefficients and the exact integer mirror."""

    samples: int
    correctly_rounded: int
    correctly_rounded_fraction: float


@dataclass(frozen=True)
class OptimizationResult:
    """Refined monomial coefficients and solver status."""

    numerator: np.ndarray
    denominator: np.ndarray
    success: bool
    termination_message: str


@dataclass(frozen=True)
class SoftL1Settings:
    """Configuration for one soft-L1 refinement stage."""

    scale_ulp: float
    max_function_evaluations: int


@dataclass(frozen=True)
class RoundingCellSettings:
    """Configuration for the final rounding-cell refinement stage."""

    temperature_ulp: float
    max_iterations: int
    parameter_step_ulp: float | None = None
    relative_tolerance: float = 1e-14
    smooth_abs_epsilon: float = 1e-12
    max_line_search_steps: int = 30


@dataclass(frozen=True)
class RefinementResult:
    """Chosen coefficient strings and the scores used to accept them."""

    numerator: list[str]
    denominator: list[str]
    seed_score: RoundingScore
    refined_score: RoundingScore
    validation_score: QuantizedRoundingScore


def refinement_holdout_grid(
    raw_stop: int,
    train_size: int,
    score_size: int,
    validation_size: int,
    basin_start: int = 0,
) -> np.ndarray:
    """Rebuild the exact-evaluator holdout used by ``refine_rational``."""
    train_raw = uniform_raw_grid(0, raw_stop, train_size)
    score_raw = uniform_raw_grid(0, raw_stop, score_size)
    excluded_grids = [train_raw, score_raw]
    if basin_start != 0:
        excluded_grids.insert(0, uniform_raw_grid(basin_start, raw_stop, train_size))
    return midpoint_raw_holdout_grid(
        0,
        raw_stop,
        validation_size,
        np.unique(np.concatenate(excluded_grids)),
    )


def uniform_raw_grid(start: int, stop: int, size: int) -> np.ndarray:
    """Return ``size`` deterministic raw integers sampled from ``[start, stop)``."""
    if start < 0 or stop <= start:
        raise ValueError(f"invalid raw interval [{start}, {stop})")
    if size < 2:
        raise ValueError("grid size must be at least two")
    if size > stop - start:
        raise ValueError("grid size cannot exceed the number of raw inputs")
    return np.linspace(start, stop - 1, size, dtype=np.int64)


def midpoint_raw_holdout_grid(
    start: int,
    stop: int,
    size: int,
    excluded: Sequence[int],
) -> np.ndarray:
    """Return deterministic equal-bin midpoints disjoint from ``excluded``.

    Integer flooring can place a nominal midpoint on an excluded input. Such
    collisions are shifted by one raw unit per repair step, then uniqueness,
    bounds, and zero intersection are asserted. The intervals used by the
    Gaussian generators contain hundreds of raw inputs per bin, so these small
    repairs do not materially disturb the sampling distribution.
    """
    if start < 0 or stop <= start:
        raise ValueError(f"invalid raw interval [{start}, {stop})")
    if size < 2:
        raise ValueError("holdout size must be at least two")
    width = stop - start
    if size > width // 3:
        raise ValueError("holdout bins must contain at least three raw inputs")
    if (2 * size - 1) * width > np.iinfo(np.int64).max:
        raise ValueError("holdout construction exceeds int64 arithmetic")

    excluded_array = np.asarray(excluded, dtype=np.int64)
    if excluded_array.ndim != 1:
        raise ValueError("excluded raw inputs must be one-dimensional")
    if np.any((excluded_array < start) | (excluded_array >= stop)):
        raise ValueError("excluded raw inputs must lie inside the holdout interval")
    excluded_array = np.unique(excluded_array)

    indices = np.arange(size, dtype=np.int64)
    grid = start + ((2 * indices + 1) * width) // (2 * size)
    if len(excluded_array) > 0:
        max_repair_rounds = width // size - 1
        for repair_round in range(max_repair_rounds + 1):
            positions = np.searchsorted(excluded_array, grid)
            bounded_positions = np.minimum(positions, len(excluded_array) - 1)
            collisions = (positions < len(excluded_array)) & (
                excluded_array[bounded_positions] == grid
            )
            if not np.any(collisions):
                break
            if repair_round == max_repair_rounds:
                raise RuntimeError("could not repair holdout collisions inside each bin")
            grid[collisions] += 1

    if np.any(grid >= stop) or np.any(np.diff(grid) <= 0):
        raise RuntimeError("holdout collision repair broke bounds or uniqueness")
    if len(excluded_array) > 0:
        positions = np.searchsorted(excluded_array, grid)
        in_range = positions < len(excluded_array)
        if np.any(excluded_array[positions[in_range]] == grid[in_range]):
            raise RuntimeError("holdout grid still intersects excluded raw inputs")
    return grid


def score_rational(
    numerator: Sequence[float],
    denominator: Sequence[float],
    x: np.ndarray,
    reference: np.ndarray,
    output_scale: int,
) -> RoundingScore:
    """Score a continuous rational against nearest-rounded oracle integers.

    The score is a fast float64 proxy used to select candidates.  The emitted
    fixed-point coefficients and exact Move arithmetic still require the
    family-specific validators.
    """
    approx = (
        np.polynomial.polynomial.polyval(x, numerator)
        / np.polynomial.polynomial.polyval(x, denominator)
    )
    approx_scaled = approx * output_scale
    reference_scaled = reference * output_scale
    rounded = np.floor(approx_scaled + 0.5)
    expected = np.floor(reference_scaled + 0.5)
    error_ulp = approx_scaled - reference_scaled
    correctly_rounded = int(np.count_nonzero(rounded == expected))
    samples = len(x)
    return RoundingScore(
        samples=samples,
        correctly_rounded=correctly_rounded,
        correctly_rounded_fraction=correctly_rounded / samples,
        mean_absolute_error_ulp=float(np.mean(np.abs(error_ulp))),
    )


def score_quantized_rational(
    numerator: Sequence[str],
    denominator: Sequence[str],
    raw_inputs: np.ndarray,
    reference: np.ndarray,
    wad: int,
    output_scale: int,
) -> QuantizedRoundingScore:
    """Score the emitted coefficient precision through the exact integer mirror.

    The oracle array may still be float64, so this is an exact *evaluator* sample,
    not an exhaustive high-precision proof. Family validators remain the final
    error, monotonicity, and overflow acceptance gates.
    """
    if len(numerator) == 0 or len(denominator) == 0:
        raise ValueError("rational coefficient lists cannot be empty")
    if len(raw_inputs) != len(reference):
        raise ValueError("input and reference grids must have equal length")
    if wad <= 0 or output_scale <= 0 or wad % output_scale != 0:
        raise ValueError("wad must be a positive multiple of the output scale")

    num = [quantize(value, wad) for value in numerator]
    den = [quantize(value, wad) for value in denominator]
    wad_per_raw = wad // output_scale

    def evaluate(raw: int) -> int:
        x = (raw * wad_per_raw, False)
        n = horner_eval(x, num, wad)
        d = horner_eval(x, den, wad)
        if n[1]:
            raise RuntimeError(f"quantized numerator is negative at raw input {raw}")
        if d[1] or d[0] == 0:
            raise RuntimeError(f"quantized denominator is non-positive at raw input {raw}")
        return mul_div_nearest(n[0], output_scale, d[0])

    output = np.fromiter(
        (evaluate(int(raw)) for raw in raw_inputs),
        dtype=np.int64,
        count=len(raw_inputs),
    )
    expected = np.floor(reference * output_scale + 0.5).astype(np.int64)
    correctly_rounded = int(np.count_nonzero(output == expected))
    samples = len(raw_inputs)
    return QuantizedRoundingScore(
        samples=samples,
        correctly_rounded=correctly_rounded,
        correctly_rounded_fraction=correctly_rounded / samples,
    )


def optimize_soft_l1(
    seed_numerator: Sequence[float],
    seed_denominator: Sequence[float],
    x: np.ndarray,
    reference: np.ndarray,
    domain_max: float,
    output_scale: int,
    soft_l1_scale_ulp: float,
    max_function_evaluations: int,
) -> OptimizationResult:
    """Refine a fixed-degree rational with a soft-L1 error objective.

    ``x`` must be uniformly sampled in the raw input variable.  Residuals are
    expressed in output ULP so ``soft_l1_scale_ulp`` has an intuitive and
    family-independent meaning.
    """
    numerator_degree = len(seed_numerator) - 1
    denominator_degree = len(seed_denominator) - 1
    if numerator_degree < 0 or denominator_degree < 0:
        raise ValueError("rational coefficient lists cannot be empty")
    if len(x) != len(reference):
        raise ValueError("input and reference grids must have equal length")
    if soft_l1_scale_ulp <= 0:
        raise ValueError("soft-L1 scale must be positive")

    params = _power_to_chebyshev_params(
        seed_numerator,
        seed_denominator,
        domain_max,
        numerator_degree,
        denominator_degree,
    )
    basis = _chebyshev_basis(x, domain_max, numerator_degree, denominator_degree)

    def residuals(current: np.ndarray) -> np.ndarray:
        values, _, denominator = _values_and_jacobian(
            current,
            basis,
            numerator_degree,
            denominator_degree,
        )
        if np.min(denominator) <= 0:
            return np.full_like(reference, 1e6)
        return (values - reference) * output_scale

    def jacobian(current: np.ndarray) -> np.ndarray:
        _, jac, denominator = _values_and_jacobian(
            current,
            basis,
            numerator_degree,
            denominator_degree,
        )
        if np.min(denominator) <= 0:
            return np.zeros_like(jac)
        return jac * output_scale

    fit = least_squares(
        residuals,
        params,
        jac=jacobian,
        loss="soft_l1",
        f_scale=soft_l1_scale_ulp,
        max_nfev=max_function_evaluations,
        xtol=1e-13,
        ftol=1e-13,
        gtol=1e-13,
    )
    numerator, denominator = _chebyshev_params_to_power(
        fit.x,
        domain_max,
        numerator_degree,
        denominator_degree,
    )
    return OptimizationResult(
        numerator=numerator,
        denominator=denominator,
        success=fit.success,
        termination_message=fit.message,
    )


def optimize_rounding_cells(
    seed_numerator: Sequence[float],
    seed_denominator: Sequence[float],
    x: np.ndarray,
    reference: np.ndarray,
    domain_max: float,
    output_scale: int,
    temperature_ulp: float,
    max_iterations: int,
    parameter_step_ulp: float | None = None,
    relative_tolerance: float = 1e-14,
    smooth_abs_epsilon: float = 1e-12,
    max_line_search_steps: int = 30,
) -> OptimizationResult:
    """Minimize a smooth penalty for leaving the oracle's rounding cell.

    For an oracle output integer ``k``, the candidate is correctly rounded when
    its pre-rounded output lies in ``[k - 0.5, k + 0.5)``. This objective is a
    softplus approximation of the distance outside that cell. It operates on a
    deterministic raw-input sample; emitted coefficients still require exact
    integer scoring and the family-specific acceptance gates.
    """
    _validate_cell_inputs(
        seed_numerator,
        seed_denominator,
        x,
        reference,
        temperature_ulp,
        max_iterations,
    )
    if relative_tolerance <= 0:
        raise ValueError("relative tolerance must be positive")
    if smooth_abs_epsilon <= 0:
        raise ValueError("smooth absolute-value epsilon must be positive")
    if max_line_search_steps < 1:
        raise ValueError("line-search step budget must be positive")
    numerator_degree = len(seed_numerator) - 1
    denominator_degree = len(seed_denominator) - 1
    params = _power_to_chebyshev_params(
        seed_numerator,
        seed_denominator,
        domain_max,
        numerator_degree,
        denominator_degree,
    )
    basis = _chebyshev_basis(x, domain_max, numerator_degree, denominator_degree)
    target = np.floor(reference * output_scale + 0.5)
    if parameter_step_ulp is None:
        initial = params
        parameter_step = None
    else:
        if parameter_step_ulp <= 0:
            raise ValueError("parameter step must be positive")
        _, initial_jacobian, _ = _values_and_jacobian(
            params,
            basis,
            numerator_degree,
            denominator_degree,
        )
        column_rms = np.sqrt(np.mean((initial_jacobian * output_scale) ** 2, axis=0))
        parameter_step = parameter_step_ulp / np.maximum(column_rms, 1e-30)
        initial = np.zeros_like(params)

    def objective(optimizer_params: np.ndarray) -> tuple[float, np.ndarray]:
        current = (
            optimizer_params
            if parameter_step is None
            else params + parameter_step * optimizer_params
        )
        values, jacobian, denominator = _values_and_jacobian(
            current,
            basis,
            numerator_degree,
            denominator_degree,
        )
        if np.min(denominator) <= 0:
            return 1e6, np.zeros_like(current)
        centered = values * output_scale - target
        magnitude = np.sqrt(centered * centered + smooth_abs_epsilon)
        outside = (magnitude - 0.5) / temperature_ulp
        loss = np.logaddexp(0.0, outside) * temperature_ulp
        derivative = expit(outside) * centered / magnitude
        gradient = np.mean(
            (derivative * output_scale)[:, None] * jacobian,
            axis=0,
        )
        if parameter_step is not None:
            gradient *= parameter_step
        return float(np.mean(loss)), gradient

    fit = minimize(
        objective,
        initial,
        method="L-BFGS-B",
        jac=True,
        options={
            "maxiter": max_iterations,
            "ftol": relative_tolerance,
            "gtol": 1e-10,
            "maxls": max_line_search_steps,
        },
    )
    final_params = fit.x if parameter_step is None else params + parameter_step * fit.x
    numerator, denominator = _chebyshev_params_to_power(
        final_params,
        domain_max,
        numerator_degree,
        denominator_degree,
    )
    return OptimizationResult(
        numerator=numerator,
        denominator=denominator,
        success=fit.success,
        termination_message=str(fit.message),
    )


def refine_rational(
    seed_numerator: Sequence[float],
    seed_denominator: Sequence[float],
    reference_values: Callable[[np.ndarray], np.ndarray],
    *,
    domain_max: float,
    raw_stop: int,
    wad: int,
    output_scale: int,
    train_size: int,
    score_size: int,
    validation_size: int,
    minimum_validation_fraction: float,
    basin: SoftL1Settings,
    fine: SoftL1Settings,
    cells: RoundingCellSettings,
    basin_start: int = 0,
) -> RefinementResult:
    """Run and accept the shared CDF/PDF refinement pipeline."""
    train_raw = uniform_raw_grid(0, raw_stop, train_size)
    train_x = train_raw.astype(np.float64) / output_scale
    train_reference = reference_values(train_x)
    if basin_start == 0:
        basin_raw = train_raw
        basin_x = train_x
        basin_reference = train_reference
    else:
        basin_raw = uniform_raw_grid(basin_start, raw_stop, train_size)
        basin_x = basin_raw.astype(np.float64) / output_scale
        basin_reference = reference_values(basin_x)

    seed_num = [float(coefficient) for coefficient in seed_numerator]
    seed_den = [float(coefficient) for coefficient in seed_denominator]
    basin_result = optimize_soft_l1(
        seed_num,
        seed_den,
        basin_x,
        basin_reference,
        domain_max,
        output_scale,
        basin.scale_ulp,
        basin.max_function_evaluations,
    )
    fine_result = optimize_soft_l1(
        basin_result.numerator,
        basin_result.denominator,
        train_x,
        train_reference,
        domain_max,
        output_scale,
        fine.scale_ulp,
        fine.max_function_evaluations,
    )
    refined = optimize_rounding_cells(
        fine_result.numerator,
        fine_result.denominator,
        train_x,
        train_reference,
        domain_max,
        output_scale,
        cells.temperature_ulp,
        cells.max_iterations,
        cells.parameter_step_ulp,
        cells.relative_tolerance,
        cells.smooth_abs_epsilon,
        cells.max_line_search_steps,
    )
    for name, result in (
        ("basin soft-L1", basin_result),
        ("fine soft-L1", fine_result),
        ("rounding cells", refined),
    ):
        if not result.success:
            raise RuntimeError(f"{name} did not converge: {result.termination_message}")

    numerator = coefficient_strings(refined.numerator)
    denominator = coefficient_strings(refined.denominator)
    fine_numerator = coefficient_strings(fine_result.numerator)
    fine_denominator = coefficient_strings(fine_result.denominator)

    score_raw = uniform_raw_grid(0, raw_stop, score_size)
    score_x = score_raw.astype(np.float64) / output_scale
    score_reference = reference_values(score_x)
    seed_score = score_rational(seed_num, seed_den, score_x, score_reference, output_scale)
    fine_score = score_rational(
        fine_result.numerator,
        fine_result.denominator,
        score_x,
        score_reference,
        output_scale,
    )
    refined_score = score_rational(
        refined.numerator,
        refined.denominator,
        score_x,
        score_reference,
        output_scale,
    )
    validation_raw = refinement_holdout_grid(
        raw_stop,
        train_size,
        score_size,
        validation_size,
        basin_start,
    )
    validation_x = validation_raw.astype(np.float64) / output_scale
    validation_reference = reference_values(validation_x)
    fine_validation_score = score_quantized_rational(
        fine_numerator,
        fine_denominator,
        validation_raw,
        validation_reference,
        wad,
        output_scale,
    )
    validation_score = score_quantized_rational(
        numerator=numerator,
        denominator=denominator,
        raw_inputs=validation_raw,
        reference=validation_reference,
        wad=wad,
        output_scale=output_scale,
    )
    if (
        refined_score.correctly_rounded <= fine_score.correctly_rounded
        or refined_score.mean_absolute_error_ulp >= seed_score.mean_absolute_error_ulp
        or validation_score.correctly_rounded <= fine_validation_score.correctly_rounded
        or validation_score.correctly_rounded_fraction < minimum_validation_fraction
    ):
        raise RuntimeError("staged refinement did not improve its acceptance metrics")
    return RefinementResult(
        numerator=numerator,
        denominator=denominator,
        seed_score=seed_score,
        refined_score=refined_score,
        validation_score=validation_score,
    )


def _validate_cell_inputs(
    seed_numerator: Sequence[float],
    seed_denominator: Sequence[float],
    x: np.ndarray,
    reference: np.ndarray,
    temperature_ulp: float,
    max_iterations: int,
) -> None:
    if len(seed_numerator) == 0 or len(seed_denominator) == 0:
        raise ValueError("rational coefficient lists cannot be empty")
    if len(x) != len(reference):
        raise ValueError("input and reference grids must have equal length")
    if temperature_ulp <= 0:
        raise ValueError("rounding-cell temperature must be positive")
    if max_iterations < 1:
        raise ValueError("maximum iterations must be positive")


def coefficient_strings(coefficients: Sequence[float]) -> list[str]:
    """Serialize float64 optimizer output without inventing extra precision."""
    return [format(float(coefficient), ".17g") for coefficient in coefficients]


def _power_to_chebyshev_params(
    numerator: Sequence[float],
    denominator: Sequence[float],
    domain_max: float,
    numerator_degree: int,
    denominator_degree: int,
) -> np.ndarray:
    x_of_t = Polynomial([domain_max / 2, domain_max / 2])
    numerator_cheb = Polynomial(numerator)(x_of_t).convert(kind=Chebyshev).coef
    denominator_cheb = Polynomial(denominator)(x_of_t).convert(kind=Chebyshev).coef
    numerator_cheb = np.pad(
        numerator_cheb,
        (0, numerator_degree + 1 - len(numerator_cheb)),
    )
    denominator_cheb = np.pad(
        denominator_cheb,
        (0, denominator_degree + 1 - len(denominator_cheb)),
    )
    numerator_cheb /= denominator_cheb[0]
    denominator_cheb /= denominator_cheb[0]
    return np.concatenate([numerator_cheb, denominator_cheb[1:]])


def _chebyshev_params_to_power(
    params: np.ndarray,
    domain_max: float,
    numerator_degree: int,
    denominator_degree: int,
) -> tuple[np.ndarray, np.ndarray]:
    numerator = Chebyshev(
        params[: numerator_degree + 1],
        domain=[0, domain_max],
    ).convert(kind=Polynomial).coef
    denominator = Chebyshev(
        np.concatenate([[1.0], params[numerator_degree + 1 :]]),
        domain=[0, domain_max],
    ).convert(kind=Polynomial).coef
    numerator /= denominator[0]
    denominator /= denominator[0]
    return numerator, denominator


def _chebyshev_basis(
    x: np.ndarray,
    domain_max: float,
    numerator_degree: int,
    denominator_degree: int,
) -> np.ndarray:
    transformed = 2 * x / domain_max - 1
    return np.polynomial.chebyshev.chebvander(
        transformed,
        max(numerator_degree, denominator_degree),
    )


def _values_and_jacobian(
    params: np.ndarray,
    basis: np.ndarray,
    numerator_degree: int,
    denominator_degree: int,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    numerator_coefficients = params[: numerator_degree + 1]
    denominator_coefficients = np.concatenate(
        [[1.0], params[numerator_degree + 1 :]]
    )
    numerator = basis[:, : numerator_degree + 1] @ numerator_coefficients
    denominator = basis[:, : denominator_degree + 1] @ denominator_coefficients
    values = numerator / denominator
    numerator_jacobian = basis[:, : numerator_degree + 1] / denominator[:, None]
    denominator_jacobian = (
        -(numerator / (denominator * denominator))[:, None]
        * basis[:, 1 : denominator_degree + 1]
    )
    return (
        values,
        np.concatenate([numerator_jacobian, denominator_jacobian], axis=1),
        denominator,
    )

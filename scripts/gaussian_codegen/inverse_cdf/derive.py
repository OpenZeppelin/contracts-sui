"""Derive rational coefficients for the standard-normal quantile Φ⁻¹(p).

Unlike `cdf`/`pdf` - smooth, bounded functions a single rational fits - the
quantile blows up as `p → 0, 1`. A single rational `N(p)/D(p)` looks fine in
float but *dies in the fixed-point evaluator*: as `p → 1` both `N` and `D`
collapse toward zero (`D ≈ 1e-85`), underflow the WAD granularity, and return
garbage. So we split the domain, exactly like the Acklam/AS241 algorithms, and
fit two well-conditioned rationals on the upper half `p ∈ [0.5, 1)` (the signed
API reflects `p < 0.5` via `Φ⁻¹(p) = −Φ⁻¹(1−p)`):

- **Central** `p ∈ [0.5, SPLIT)`: `z` as a rational in `u = p − 0.5`.
- **Tail** `p ∈ [SPLIT, 1 − TAIL_MIN_P]`: `z` as a rational in the Acklam change
  of variable `r = sqrt(−2·ln(1−p))`, which linearizes the tail's growth.

Each region sweeps AAA `max_terms` upward and picks the smallest degree whose
worst-case absolute error in `z` vs the mpmath `erfinv` oracle stays at or below
TARGET_ERROR. The central-region AAA seed is then refined with staged soft-L1
continuous-error objectives sampled uniformly over representable probabilities.
The tail candidate is optimized for the deployed integer pipeline, which carries
the transformed variable at WAD and rounds the logarithm conversion and square
root to nearest.

Both `D`s are checked to stay comfortably away from zero
(`|D| ≥ MIN_ABS_D`) - the guard that would have caught the single-rational
failure. AAA seed and tail coefficients retain their high-precision decimal
conversion; the float64-refined central coefficients serialize 17 significant
digits without inventing precision. They go to a JSON intermediate consumed by
`emit_coefficients.py`, in ascending power order, normalized so `D(0) = 1`.

Oracle note: SciPy's float64 inverse-normal function can be wrong by up to
~5e-9 in the deep tail, so it is not the authoritative continuous fit/error
oracle. The AAA sweep and continuous error gate use `shared.reference.ppf`
(`sqrt(2)·erfinv(2p−1)` at 100 dps). `scipy.special.ndtri` is used for central
optimization and the sampled exact-integer validation regression; the latter is
an exact evaluator score against a float64 oracle.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys
import warnings
from typing import Callable, Sequence

import numpy as np
from mpmath import exp, ln, mp, mpf, sqrt
from scipy.interpolate import AAA
from scipy.special import ndtri

from gaussian_codegen.shared import constants
from gaussian_codegen.shared.aaa import aaa_to_rational_polys, evaluate_rational, horner_eval_mpf
from gaussian_codegen.shared.reference import DPS, ppf
from gaussian_codegen.shared.rounding_optimize import (
    coefficient_strings,
    midpoint_raw_holdout_grid,
    optimize_soft_l1,
    score_quantized_rational,
    score_rational,
    uniform_raw_grid,
)

# AAA emits a RuntimeWarning when it hits `max_terms` before satisfying `rtol`.
# Our sweep deliberately caps `max_terms`, so the warning is expected noise.
warnings.filterwarnings(
    "ignore",
    message=r"AAA failed to converge within \d+ iterations\.",
    category=RuntimeWarning,
)

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]

MIN_DEG = 2
MAX_DEG = 15
# The on-chain accuracy contract is ≤ 5×10⁻⁹ (5 ULP) on the *quantized* output.
# We drive the float fit well below that so the final nearest-rounding to 10^9
# scale (± ~0.5 ULP) still lands comfortably inside the budget - the same sub-ULP
# empirical accuracy cdf/pdf achieve. `validate.py` re-checks the actual quantized
# error against the full 5-ULP contract. (The central quantile meets 5×10⁻⁹ only
# at a tight degree, so an explicit headroom target is what buys the margin.)
TARGET_ERROR = 1e-9
# Anti-underflow gate: the fixed-point evaluator divides by D at WAD scale
# (D_wad = D_real * 1e18), so a catastrophically small denominator (the failure
# mode of a single rational in p, where D_real ≈ 1e-85 → D_wad rounds to 0) would
# produce garbage. `1e-9` keeps D_wad ≥ 1e9 (ample integer precision) while
# admitting every healthy region-split fit, whose |D| stays ≥ ~1e-5.
MIN_ABS_D = 1e-9
N_FIT_GRID = 4000
N_VALIDATE_GRID = 8000
ROUNDING_TRAIN_SIZE = 1_000_000
ROUNDING_SCORE_SIZE = 2_000_000
ROUNDING_EXACT_SCORE_SIZE = 1_000_000
MIN_EXACT_HOLDOUT_CORRECT_FRACTION = 0.9885
ROUNDING_BASIN_SOFT_L1_SCALE_ULP = 0.02
ROUNDING_BASIN_MAX_FUNCTION_EVALUATIONS = 240
ROUNDING_FINE_SOFT_L1_SCALE_ULP = 0.003
ROUNDING_FINE_MAX_FUNCTION_EVALUATIONS = 120

# Tail candidate optimized for the correctly-rounded output count after the
# WAD-scale, nearest-rounded change of variable. The strings are exact at WAD
# and reproduce the stored u128 magnitudes without a float conversion.
DEPLOYED_TAIL_NUMERATOR = [
    "-3.0943397105617336",
    "-6.207376019943557",
    "3.075018098279669",
    "3.306509139927573",
    "0.38680465651912765",
]
DEPLOYED_TAIL_DENOMINATOR = [
    "1",
    "4.664193128006789",
    "3.324846871342176",
    "0.38644130209389493",
    "0.000004952204793303",
]

OUTPUT_PATH = pathlib.Path(__file__).parent / ".derive_output.json"

# Domain bounds, from the single source of truth in `shared/constants.py`.
HALF = mpf(1) / 2
SPLIT = mpf(constants.INVERSE_CDF_SPLIT)  # 0.975
U_MAX = SPLIT - HALF  # central upper bound in u = p - 0.5  → 0.475
TAIL_MIN_P = mpf(constants.INVERSE_CDF_TAIL_MIN_P)  # 1e-9


def _r_of_p(p: mpf) -> mpf:
    """Tail change of variable r = sqrt(-2 ln(1 - p))."""
    return sqrt(-2 * ln(1 - p))


R_MIN = _r_of_p(SPLIT)  # ≈ 2.7162 at p = 0.975
R_MAX = _r_of_p(1 - TAIL_MIN_P)  # ≈ 6.4379 at p = 1 - 1e-9


def _central_z(u: mpf) -> mpf:
    """Quantile as a function of the central variable u = p - 0.5."""
    return ppf(HALF + u)


def _tail_z(r: mpf) -> mpf:
    """Quantile as a function of the tail variable r = sqrt(-2 ln(1 - p)).

    Invert the change of variable: 1 - p = exp(-r^2 / 2), so p = 1 - exp(-r^2/2)
    and z = Φ⁻¹(p). Evaluated at 100 dps, exact far beyond the 5e-9 budget."""
    q = exp(-(r * r) / 2)  # 1 - p
    return ppf(1 - q)


class Region:
    """One fit region: a variable grid and the true z on it."""

    def __init__(self, name: str, lo: mpf, hi: mpf, z_of_x: Callable[[mpf], mpf]):
        self.name = name
        self.lo = float(lo)
        self.hi = float(hi)
        self.z_of_x = z_of_x
        self.fit_x = np.linspace(self.lo, self.hi, N_FIT_GRID)
        self.val_x = np.linspace(self.lo, self.hi, N_VALIDATE_GRID)
        mp.dps = DPS
        self.fit_z = np.array([float(z_of_x(mpf(float(x)))) for x in self.fit_x])
        self.val_z = [z_of_x(mpf(float(x))) for x in self.val_x]  # mpf, high precision


def measure_error(num: Sequence[mpf], den: Sequence[mpf], region: Region) -> tuple[float, float, float]:
    """Worst-case absolute error of N(x)/D(x) vs the oracle over the region's
    validation grid, plus the minimum |D| seen. Evaluation is high precision; the
    error is the float64 difference."""
    mp.dps = DPS
    worst_err = 0.0
    worst_x = region.lo
    min_abs_d = None
    for x, z_true in zip(region.val_x, region.val_z):
        x_mpf = mpf(float(x))
        d = horner_eval_mpf(den, x_mpf)
        abs_d = abs(float(d))
        if min_abs_d is None or abs_d < min_abs_d:
            min_abs_d = abs_d
        approx = evaluate_rational(num, den, x_mpf)
        err = abs(float(approx) - float(z_true))
        if err > worst_err:
            worst_err = err
            worst_x = float(x)
    return worst_err, worst_x, float(min_abs_d)


def assert_signs(num: Sequence[mpf], den: Sequence[mpf], region: Region) -> None:
    """On the region's domain: D(x) > 0, N(x) ≥ 0 (z ≥ 0 on the upper half), and
    D(x) stays clear of zero (|D| ≥ MIN_ABS_D). The last check is what disqualifies
    a would-be single-rational fit whose denominator underflows in the tail."""
    mp.dps = DPS
    for x in region.val_x:
        x_mpf = mpf(float(x))
        d = horner_eval_mpf(den, x_mpf)
        n = horner_eval_mpf(num, x_mpf)
        if d <= 0:
            raise RuntimeError(f"[{region.name}] D(x) ≤ 0 at x={x}: D={d}")
        if float(d) < MIN_ABS_D:
            raise RuntimeError(f"[{region.name}] |D(x)| < {MIN_ABS_D} at x={x}: D={d}")
        if n < 0:
            raise RuntimeError(f"[{region.name}] N(x) < 0 at x={x}: N={n}")


def fit_region(region: Region, report: bool) -> dict:
    print(f"[{region.name}] target {TARGET_ERROR:.2e} on x ∈ [{region.lo:.5g}, {region.hi:.5g}]")
    chosen = None
    for max_terms in range(MIN_DEG + 1, MAX_DEG + 2):
        aaa = AAA(region.fit_x, region.fit_z, max_terms=max_terms, rtol=1e-15, clean_up_tol=0)
        actual_terms = len(aaa.support_points)
        actual_degree = actual_terms - 1
        num, den = aaa_to_rational_polys(aaa)
        err, worst_x, min_abs_d = measure_error(num, den, region)
        print(
            f"  [{region.name}] max_terms={max_terms:2d}: support={actual_terms:2d} "
            f"(deg {actual_degree:2d}), err={err:.3e} at x={worst_x:.4f}, min|D|={min_abs_d:.3g}"
        )
        if err <= TARGET_ERROR and min_abs_d >= MIN_ABS_D and chosen is None:
            chosen = (actual_degree, aaa, num, den, err, worst_x, min_abs_d)
            if not report:
                break

    if chosen is None:
        raise RuntimeError(f"[{region.name}] no degree ≤ {MAX_DEG} met the target")

    degree, aaa, num, den, err, worst_x, min_abs_d = chosen
    assert_signs(num, den, region)

    # Coefficient magnitude check at WAD scale before serialization.
    wad = mpf(constants.WAD)
    max_mag = max(abs(c) * wad for c in num + den)
    print(
        f"[{region.name}] chosen degree {degree} (n_coeffs={degree + 1}), "
        f"err {err:.3e}, min|D| {min_abs_d:.3g}, max |coeff|×WAD {float(max_mag):.3e}"
    )
    if max_mag >= mpf(2) ** 128:
        raise RuntimeError(f"[{region.name}] a coefficient does not fit u128 at WAD scale")

    return {
        "degree": degree,
        "n_coeffs": len(num),
        "max_error": err,
        "worst_x": worst_x,
        "min_abs_d": min_abs_d,
        "num_coeffs_str": [mp.nstr(c, 30) for c in num],
        "den_coeffs_str": [mp.nstr(c, 30) for c in den],
    }


def refine_central_fit(fit: dict, region: Region) -> dict:
    """Refine the central AAA seed against uniformly weighted raw probabilities."""
    central_width_raw = constants.INVERSE_CDF_SPLIT_RAW - constants.HALF_RAW
    # Include u=0 as a stabilizing anchor even though the on-chain dispatcher
    # special-cases p=0.5 to zero before consulting the rational.
    train_raw = uniform_raw_grid(0, central_width_raw, ROUNDING_TRAIN_SIZE)
    train_x = train_raw.astype(np.float64) / constants.SCALE_DECIMAL
    train_reference = ndtri(0.5 + train_x)

    basin = optimize_soft_l1(
        [float(c) for c in fit["num_coeffs_str"]],
        [float(c) for c in fit["den_coeffs_str"]],
        train_x,
        train_reference,
        float(U_MAX),
        constants.SCALE_DECIMAL,
        ROUNDING_BASIN_SOFT_L1_SCALE_ULP,
        ROUNDING_BASIN_MAX_FUNCTION_EVALUATIONS,
    )
    fine = optimize_soft_l1(
        basin.numerator,
        basin.denominator,
        train_x,
        train_reference,
        float(U_MAX),
        constants.SCALE_DECIMAL,
        ROUNDING_FINE_SOFT_L1_SCALE_ULP,
        ROUNDING_FINE_MAX_FUNCTION_EVALUATIONS,
    )

    num_strings = coefficient_strings(fine.numerator)
    den_strings = coefficient_strings(fine.denominator)

    score_raw = uniform_raw_grid(1, central_width_raw, ROUNDING_SCORE_SIZE)
    score_x = score_raw.astype(np.float64) / constants.SCALE_DECIMAL
    score_reference = ndtri(0.5 + score_x)
    seed_score = score_rational(
        [float(c) for c in fit["num_coeffs_str"]],
        [float(c) for c in fit["den_coeffs_str"]],
        score_x,
        score_reference,
        constants.SCALE_DECIMAL,
    )
    refined_score = score_rational(
        fine.numerator,
        fine.denominator,
        score_x,
        score_reference,
        constants.SCALE_DECIMAL,
    )
    num = [mpf(c) for c in num_strings]
    den = [mpf(c) for c in den_strings]
    err, worst_x, min_abs_d = measure_error(num, den, region)
    if err > TARGET_ERROR:
        raise RuntimeError(
            f"[central] refined error {err:.3e} exceeds target {TARGET_ERROR:.2e} "
            f"at x={worst_x:.4f}"
        )
    assert_signs(num, den, region)

    wad = mpf(constants.WAD)
    max_mag = max(abs(c) * wad for c in num + den)
    if max_mag >= mpf(2) ** 128:
        raise RuntimeError("[central] a refined coefficient does not fit u128 at WAD scale")

    excluded_raw = np.unique(np.concatenate([train_raw[train_raw >= 1], score_raw]))
    exact_raw = midpoint_raw_holdout_grid(
        1,
        central_width_raw,
        ROUNDING_EXACT_SCORE_SIZE,
        excluded_raw,
    )
    exact_x = exact_raw.astype(np.float64) / constants.SCALE_DECIMAL
    exact_reference = ndtri(0.5 + exact_x)
    seed_exact_score = score_quantized_rational(
        fit["num_coeffs_str"],
        fit["den_coeffs_str"],
        exact_raw,
        exact_reference,
        constants.WAD,
        constants.SCALE_DECIMAL,
    )
    refined_exact_score = score_quantized_rational(
        num_strings,
        den_strings,
        exact_raw,
        exact_reference,
        constants.WAD,
        constants.SCALE_DECIMAL,
    )
    if not basin.success or not fine.success:
        raise RuntimeError("[central] at least one rounding-refinement stage did not converge")
    if (
        refined_score.correctly_rounded <= seed_score.correctly_rounded
        or refined_score.mean_absolute_error_ulp >= seed_score.mean_absolute_error_ulp
        or refined_exact_score.correctly_rounded <= seed_exact_score.correctly_rounded
        or (
            refined_exact_score.correctly_rounded_fraction
            < MIN_EXACT_HOLDOUT_CORRECT_FRACTION
        )
    ):
        raise RuntimeError("[central] staged refinement did not improve its acceptance metrics")
    print(
        f"[central] AAA seed: {seed_score.correctly_rounded_fraction:.4%}; "
        f"refined: {refined_score.correctly_rounded_fraction:.4%} correctly rounded "
        f"on {score_raw.size:,} proxy samples"
    )
    print(
        f"[central] validation: {refined_exact_score.correctly_rounded_fraction:.4%} "
        f"correct through the exact integer mirror on {refined_exact_score.samples:,} samples"
    )

    return {
        "degree": fit["degree"],
        "n_coeffs": fit["n_coeffs"],
        "max_error": err,
        "worst_x": worst_x,
        "min_abs_d": min_abs_d,
        "num_coeffs_str": num_strings,
        "den_coeffs_str": den_strings,
    }


def deployed_tail_fit(seed: dict, region: Region) -> dict:
    """Validate and select the WAD-transform tail candidate."""
    num = [mpf(c) for c in DEPLOYED_TAIL_NUMERATOR]
    den = [mpf(c) for c in DEPLOYED_TAIL_DENOMINATOR]
    err, worst_x, min_abs_d = measure_error(num, den, region)
    if err > TARGET_ERROR:
        raise RuntimeError(
            f"[tail] deployed error {err:.3e} exceeds target {TARGET_ERROR:.2e} "
            f"at x={worst_x:.4f}"
        )
    assert_signs(num, den, region)

    max_mag = max(abs(c) * mpf(constants.WAD) for c in num + den)
    if max_mag >= mpf(2) ** 128:
        raise RuntimeError("[tail] a deployed coefficient does not fit u128 at WAD scale")
    if len(num) != seed["n_coeffs"] or len(den) != seed["n_coeffs"]:
        raise RuntimeError("[tail] deployed candidate changed the pinned rational degree")
    print(
        f"[tail] deployed degree {seed['degree']} (n_coeffs={seed['n_coeffs']}), "
        f"err {err:.3e}, min|D| {min_abs_d:.3g}, max |coeff|×WAD {float(max_mag):.3e}"
    )
    return {
        "degree": seed["degree"],
        "n_coeffs": seed["n_coeffs"],
        "max_error": err,
        "worst_x": worst_x,
        "min_abs_d": min_abs_d,
        "num_coeffs_str": DEPLOYED_TAIL_NUMERATOR,
        "den_coeffs_str": DEPLOYED_TAIL_DENOMINATOR,
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Derive inverse-CDF rational coefficients.")
    parser.add_argument(
        "--report",
        action="store_true",
        help="Show the full per-degree sweep for each region instead of stopping early.",
    )
    args = parser.parse_args(argv)

    central = Region("central", mpf(0), U_MAX, _central_z)
    tail = Region("tail", R_MIN, R_MAX, _tail_z)

    try:
        central_fit = fit_region(central, args.report)
        central_fit = refine_central_fit(central_fit, central)
        print()
        tail_seed = fit_region(tail, args.report)
        tail_fit = deployed_tail_fit(tail_seed, tail)
    except RuntimeError as exc:
        print(f"\nFAIL: {exc}", file=sys.stderr)
        return 1

    output = {
        "central": central_fit,
        "tail": tail_fit,
        "target_error": TARGET_ERROR,
        "min_abs_d": MIN_ABS_D,
        "split": constants.INVERSE_CDF_SPLIT,
        "split_raw": constants.INVERSE_CDF_SPLIT_RAW,
        "max_z": constants.INVERSE_CDF_MAX_Z,
        "max_z_raw": constants.INVERSE_CDF_MAX_Z_RAW,
        "half_raw": constants.HALF_RAW,
        "tail_min_p": constants.INVERSE_CDF_TAIL_MIN_P,
        "r_min": float(R_MIN),
        "r_max": float(R_MAX),
        "wad": str(constants.WAD),
        "scale_decimal": str(constants.SCALE_DECIMAL),
    }
    OUTPUT_PATH.write_text(json.dumps(output, indent=2), encoding="utf-8")
    print(f"\nWrote {OUTPUT_PATH.relative_to(REPO_ROOT)}")
    print(
        f"  central: degree {central_fit['degree']} err {central_fit['max_error']:.3e}; "
        f"tail: degree {tail_fit['degree']} err {tail_fit['max_error']:.3e}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

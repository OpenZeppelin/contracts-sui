"""Derive rounding-aware rational coefficients for the standard-normal CDF.

Fits an AAA rational at the pinned shipped degree, then refines that seed in a
conditioned Chebyshev basis. Broad and near-L1 stages first lower continuous
output-ULP error; a direct rounding-cell stage then penalizes candidates that
leave the oracle output integer's half-ULP cell. A count-optimized candidate is
accepted only when it improves the refined seed on a disjoint exact-integer
holdout and satisfies the same continuous error, sign, storage, monotonicity,
and overflow gates.

Saves the refined coefficients and compact fit metadata to a JSON
intermediate consumed by `emit_coefficients.py`. Pass `--report` to print the
full per-degree AAA sweep (informational only; the shipped degree stays pinned).

Polynomial form is N(z)/D(z) with coefficients in **ascending power order**
(constant term first). The fit is normalized so that D(0) = 1 - this keeps
constant terms near `(0.5, 1)` and higher-order terms close to O(1), which
makes them comfortably fit u128 after WAD scaling.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys
import warnings
from typing import Sequence

import numpy as np
from mpmath import mp, mpf
from scipy.interpolate import AAA
from scipy.stats import norm

from gaussian_codegen.shared import constants
from gaussian_codegen.shared.aaa import aaa_to_rational_polys, evaluate_rational, horner_eval_mpf
from gaussian_codegen.shared.reference import DPS
from gaussian_codegen.shared.rounding_optimize import (
    RoundingCellSettings,
    SoftL1Settings,
    refinement_holdout_grid,
    refine_rational,
    score_quantized_rational,
)

# AAA emits a RuntimeWarning when it hits `max_terms` before satisfying `rtol`.
# Our sweep deliberately caps `max_terms`, so the warning is expected noise.
warnings.filterwarnings(
    "ignore",
    message=r"AAA failed to converge within \d+ iterations\.",
    category=RuntimeWarning,
)

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]

MAX_Z = mpf(constants.MAX_Z)
MAX_Z_FLOAT = float(constants.MAX_Z)
MIN_DEG = 4
MAX_DEG = 13
TARGET_DEGREE = 9  # shipped CDF degree; pinned (not swept) so it stays fixed across regenerations
TARGET_ERROR = 5e-9
N_FIT_GRID = 5000
N_VALIDATE_GRID = 10000
ROUNDING_TRAIN_SIZE = 1_000_000
ROUNDING_SCORE_SIZE = 2_000_000
ROUNDING_EXACT_SCORE_SIZE = 1_000_000
MIN_EXACT_HOLDOUT_CORRECT_FRACTION = 0.993
ROUNDING_BASIN = SoftL1Settings(scale_ulp=0.004, max_function_evaluations=240)
ROUNDING_FINE = SoftL1Settings(scale_ulp=0.0001, max_function_evaluations=100)
ROUNDING_CELLS = RoundingCellSettings(temperature_ulp=0.005, max_iterations=200)

OUTPUT_PATH = pathlib.Path(__file__).parent / ".derive_output.json"

# Fixed-degree candidate optimized for the deployed correctly-rounded output
# count. Decimal strings are exact at CDF_WAD and therefore reproduce the
# stored u128 magnitudes without a float conversion.
DEPLOYED_NUMERATOR = [
    "0.4999999999316276",
    "0.20134463365768993",
    "-0.018142911236019663",
    "0.01341587098877386",
    "0.011356372246199778",
    "-0.0006622568610475781",
    "-0.00011001350215688407",
    "0.00029658396351067457",
    "-0.00005317186477440753",
    "0.000008767949922896122",
]
DEPLOYED_DENOMINATOR = [
    "1",
    "-0.39519530222724436",
    "0.2790345662896135",
    "-0.06282620473394744",
    "0.020293781568698408",
    "-0.000376473797332801",
    "-0.00035345442913827305",
    "0.0003304794337604282",
    "-0.00005534597363213167",
    "0.000008824023536977782",
]


def fit_grid() -> np.ndarray:
    return np.linspace(0.0, MAX_Z_FLOAT, N_FIT_GRID)


def validate_grid() -> np.ndarray:
    return np.linspace(0.0, MAX_Z_FLOAT, N_VALIDATE_GRID)


def reference_values_float(grid: np.ndarray) -> np.ndarray:
    """Φ values at the grid points (float64 - sufficient for AAA training; the
    article's nominal error is 3.35e-9, three orders of magnitude above float64
    precision). mpmath at 100 dps is reserved for validation and quantization."""
    return norm.cdf(grid)


def measure_error(num: Sequence[mpf], den: Sequence[mpf], grid: np.ndarray) -> tuple[float, float]:
    """Worst-case absolute error of N(z)/D(z) vs scipy.stats.norm.cdf over the grid.
    Evaluation happens at high precision; the error is the float64 difference.
    """
    mp.dps = DPS
    worst_err = 0.0
    worst_z = 0.0
    for z in grid:
        approx = float(evaluate_rational(num, den, mpf(float(z))))
        ref = float(norm.cdf(float(z)))
        err = abs(approx - ref)
        if err > worst_err:
            worst_err = err
            worst_z = float(z)
    return worst_err, worst_z


def assert_signs_central(num: Sequence[mpf], den: Sequence[mpf], grid: np.ndarray) -> None:
    """Verify that on the central domain D(z) > 0 and N(z) ≥ 0 - the runtime
    invariants INV-7 and INV-8. Healthy fits to a non-negative monotone increasing
    function should satisfy these, but we check explicitly so a degenerate fit
    fails the codegen rather than silently producing a broken module."""
    mp.dps = DPS
    for z in grid:
        z_mpf = mpf(float(z))
        d = horner_eval_mpf(den, z_mpf)
        n = horner_eval_mpf(num, z_mpf)
        if d <= 0:
            raise RuntimeError(f"D(z) ≤ 0 at z={z}: D={d}")
        if n < 0:
            raise RuntimeError(f"N(z) < 0 at z={z}: N={n}")


def fit_at(max_terms: int) -> AAA:
    grid = fit_grid()
    fvals = reference_values_float(grid)
    return AAA(grid, fvals, max_terms=max_terms, rtol=1e-15, clean_up_tol=0)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Derive CDF rational coefficients.")
    parser.add_argument(
        "--report",
        action="store_true",
        help="Show the per-degree error sweep before stopping at the chosen degree.",
    )
    args = parser.parse_args(argv)

    print(f"Target error: {TARGET_ERROR:.2e} on [0, {MAX_Z_FLOAT}]")
    print(f"Pinned degree: {TARGET_DEGREE} (n_coeffs = {TARGET_DEGREE + 1})")
    print()

    val_grid = validate_grid()

    if args.report:
        # Informational only: the full per-degree error sweep. The shipped degree
        # is pinned below, not chosen from this sweep, so precision/domain changes
        # never silently move it.
        for max_terms in range(MIN_DEG + 1, MAX_DEG + 2):
            aaa_r = fit_at(max_terms)
            num_r, den_r = aaa_to_rational_polys(aaa_r)
            err_r, worst_z_r = measure_error(num_r, den_r, val_grid)
            print(
                f"  max_terms={max_terms:2d}: support={len(aaa_r.support_points):2d} "
                f"(deg {len(aaa_r.support_points) - 1:2d}), err={err_r:.3e} at z={worst_z_r:.4f}"
            )
        print()

    # Fit at the pinned degree. rtol is far below what this degree can reach and
    # clean_up_tol=0, so AAA keeps all TARGET_DEGREE + 1 support points and the
    # explicit-polynomial degree is exactly TARGET_DEGREE.
    aaa = fit_at(TARGET_DEGREE + 1)
    degree = len(aaa.support_points) - 1
    if degree != TARGET_DEGREE:
        print(
            f"\nFAIL: AAA produced degree {degree}, expected pinned {TARGET_DEGREE} "
            "(support points were cleaned up below the pin)",
            file=sys.stderr,
        )
        return 1
    seed_num, seed_den = aaa_to_rational_polys(aaa)
    seed_err, seed_worst_z = measure_error(seed_num, seed_den, val_grid)
    if seed_err > TARGET_ERROR:
        print(
            f"\nFAIL: degree {degree} AAA error {seed_err:.3e} exceeds target "
            f"{TARGET_ERROR:.2e} at z={seed_worst_z:.4f}",
            file=sys.stderr,
        )
        return 1

    # Include z=0 in the fine stages as a stabilizing endpoint anchor even
    # though the on-chain dispatcher returns Φ(0)=0.5 before the rational.
    try:
        refinement = refine_rational(
            seed_num,
            seed_den,
            reference_values_float,
            domain_max=MAX_Z_FLOAT,
            raw_stop=constants.MAX_Z_RAW,
            wad=constants.CDF_WAD,
            output_scale=constants.SCALE_DECIMAL,
            train_size=ROUNDING_TRAIN_SIZE,
            score_size=ROUNDING_SCORE_SIZE,
            validation_size=ROUNDING_EXACT_SCORE_SIZE,
            minimum_validation_fraction=MIN_EXACT_HOLDOUT_CORRECT_FRACTION,
            basin=ROUNDING_BASIN,
            fine=ROUNDING_FINE,
            cells=ROUNDING_CELLS,
            basin_start=1,
        )
    except RuntimeError as exc:
        print(f"\nFAIL: {exc}", file=sys.stderr)
        return 1
    validation_raw = refinement_holdout_grid(
        constants.MAX_Z_RAW,
        ROUNDING_TRAIN_SIZE,
        ROUNDING_SCORE_SIZE,
        ROUNDING_EXACT_SCORE_SIZE,
        basin_start=1,
    )
    validation_x = validation_raw.astype(np.float64) / constants.SCALE_DECIMAL
    candidate_score = score_quantized_rational(
        DEPLOYED_NUMERATOR,
        DEPLOYED_DENOMINATOR,
        validation_raw,
        reference_values_float(validation_x),
        constants.CDF_WAD,
        constants.SCALE_DECIMAL,
    )
    if (
        candidate_score.correctly_rounded <= refinement.validation_score.correctly_rounded
        or candidate_score.correctly_rounded_fraction < MIN_EXACT_HOLDOUT_CORRECT_FRACTION
    ):
        print("\nFAIL: deployed candidate did not improve the exact-integer holdout", file=sys.stderr)
        return 1
    num_strings = DEPLOYED_NUMERATOR
    den_strings = DEPLOYED_DENOMINATOR
    num = [mpf(c) for c in num_strings]
    den = [mpf(c) for c in den_strings]

    err, worst_z = measure_error(num, den, val_grid)
    if err > TARGET_ERROR:
        print(
            f"\nFAIL: refined degree {degree} error {err:.3e} exceeds target "
            f"{TARGET_ERROR:.2e} at z={worst_z:.4f}",
            file=sys.stderr,
        )
        return 1

    # INV-7 / INV-8 pre-flight: N ≥ 0 and D > 0 on the central domain.
    assert_signs_central(num, den, val_grid)

    print()
    print(
        f"AAA seed: {refinement.seed_score.correctly_rounded_fraction:.4%} correctly rounded "
        f"on {refinement.seed_score.samples:,} deterministic proxy samples"
    )
    print(
        f"Refined:  {refinement.refined_score.correctly_rounded_fraction:.4%} correctly rounded "
        f"on the same samples"
    )
    print(
        "Refined validation: "
        f"{refinement.validation_score.correctly_rounded_fraction:.4%} correctly rounded "
        f"through the exact integer mirror on {refinement.validation_score.samples:,} samples"
    )
    print(
        "Deployed candidate:  "
        f"{candidate_score.correctly_rounded_fraction:.4%} correctly rounded "
        f"on the same exact-integer holdout"
    )
    print(
        f"Chosen: degree {degree} (n_coeffs = {degree + 1}), max error "
        f"{err:.3e} at z={worst_z:.4f}"
    )

    # Coefficient magnitude check at the CDF accumulation scale before serialization.
    wad = mpf(constants.CDF_WAD)
    max_mag = mpf(0)
    for c in num + den:
        m = abs(c) * wad
        if m > max_mag:
            max_mag = m
    print(f"Max |coeff| × CDF_WAD = {float(max_mag):.3e} (must be < 2^128 ≈ 3.4e38)")
    if max_mag >= mpf(2) ** 128:
        print("FAIL: at least one coefficient does not fit u128 at CDF_WAD scale", file=sys.stderr)
        return 1

    output = {
        "degree": degree,
        "n_coeffs": len(num),
        "max_error": err,
        "worst_z": worst_z,
        "target_error": TARGET_ERROR,
        "max_z": constants.MAX_Z,
        "wad": str(constants.CDF_WAD),
        "scale_decimal": str(constants.SCALE_DECIMAL),
        "num_coeffs_str": num_strings,
        "den_coeffs_str": den_strings,
    }
    OUTPUT_PATH.write_text(json.dumps(output, indent=2), encoding="utf-8")
    print(f"\nWrote {OUTPUT_PATH.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""Derive AAA-rational coefficients for the standard-normal CDF on [0, MAX_Z].

Fits the AAA rational at a pinned degree (TARGET_DEGREE - the shipped degree, held
fixed across regenerations so precision/domain changes never silently move it),
then checks its worst-case absolute error vs scipy on a N_VALIDATE_GRID-point grid
stays at or below TARGET_ERROR. Saves the fit's coefficients (mpmath at 100 dps,
decimal-string serialized) to a JSON intermediate consumed by
`emit_coefficients.py` and `emit_test_vectors.py`. Pass `--report` to print the
full per-degree error sweep (informational only; does not affect the pinned fit).

Polynomial form is N(z)/D(z) with coefficients in **ascending power order**
(constant term first). The fit is normalized so that D(0) = 1 - this keeps
constant terms near `(0.5, 1)` and higher-order terms close to O(1), which
makes them comfortably fit u128 after scaling to the accumulation scale.
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

OUTPUT_PATH = pathlib.Path(__file__).parent / ".derive_output.json"


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
    invariants INV-7 and INV-8. AAA fits to a non-negative monotone increasing
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
    parser = argparse.ArgumentParser(description="Derive CDF AAA coefficients.")
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
    num, den = aaa_to_rational_polys(aaa)
    err, worst_z = measure_error(num, den, val_grid)
    if err > TARGET_ERROR:
        print(
            f"\nFAIL: degree {degree} error {err:.3e} exceeds target {TARGET_ERROR:.2e} "
            f"at z={worst_z:.4f}",
            file=sys.stderr,
        )
        return 1

    # INV-7 / INV-8 pre-flight: N ≥ 0 and D > 0 on the central domain.
    assert_signs_central(num, den, val_grid)

    print()
    print(f"Chosen: degree {degree} (n_coeffs = {degree + 1}), max error {err:.3e} at z={worst_z:.4f}")

    # Coefficient magnitude check at the CDF accumulation scale before serialization.
    acc_scale = mpf(constants.CDF_ACC_SCALE)
    max_mag = mpf(0)
    for c in num + den:
        m = abs(c) * acc_scale
        if m > max_mag:
            max_mag = m
    print(f"Max |coeff| x CDF_ACC_SCALE = {float(max_mag):.3e} (must be < 2^128 ≈ 3.4e38)")
    if max_mag >= mpf(2) ** 128:
        print("FAIL: at least one coefficient does not fit u128 at CDF_ACC_SCALE", file=sys.stderr)
        return 1

    output = {
        "degree": degree,
        "n_coeffs": len(num),
        "max_error": err,
        "worst_z": worst_z,
        "target_error": TARGET_ERROR,
        "max_z": constants.MAX_Z,
        "acc_scale": str(constants.CDF_ACC_SCALE),
        "scale_decimal": str(constants.SCALE_DECIMAL),
        "num_coeffs_str": [mp.nstr(c, 30) for c in num],
        "den_coeffs_str": [mp.nstr(c, 30) for c in den],
        "support_points": [float(z) for z in aaa.support_points],
        "support_values": [float(y) for y in aaa.support_values],
        "weights": [float(w) for w in aaa.weights],
    }
    OUTPUT_PATH.write_text(json.dumps(output, indent=2), encoding="utf-8")
    print(f"\nWrote {OUTPUT_PATH.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""Derive AAA-rational coefficients for the standard-normal quantile Φ⁻¹(p).

Unlike `cdf`/`pdf` - smooth, bounded functions a single rational fits - the
quantile blows up as `p → 0, 1`. A single rational `N(p)/D(p)` looks fine in
float but *dies in the fixed-point evaluator*: as `p → 1` both `N` and `D`
collapse toward zero (`D ≈ 1e-85`), underflow the WAD granularity, and return
garbage. So we split the domain, taking after the Acklam/AS241 algorithms (the
split point and the fits are our own), and fit two well-conditioned rationals on
the upper half `p ∈ [0.5, 1)` (the signed API reflects `p < 0.5` via
`Φ⁻¹(p) = −Φ⁻¹(1−p)`):

- **Central** `p ∈ [0.5, SPLIT]`: `z` as a rational in `u = p − 0.5`.
- **Tail** `p ∈ [SPLIT, 1 − TAIL_MIN_P]`: `z` as a rational in the Acklam change
  of variable `r = sqrt(−2·ln(1−p))`, which linearizes the tail's growth.

Each region sweeps AAA `max_terms` upward and picks the smallest degree whose
worst-case absolute error in `z` vs the mpmath `erfinv` oracle stays at or below
TARGET_ERROR. Both `D`s are checked to stay comfortably away from zero
(`|D| ≥ MIN_ABS_D`) - the guard that would have caught the single-rational
failure. Coefficients (mpmath at 100 dps, decimal-string serialized) go to a JSON
intermediate consumed by `emit_coefficients.py` and `emit_test_vectors.py`, in
ascending power order, normalized so `D(0) = 1`.

Oracle note: `scipy.stats.norm.ppf` is float64 and wrong by up to ~5e-9 in the
deep tail, so it is **not** used here - the reference is `shared.reference.ppf`
(`sqrt(2)·erfinv(2p−1)` at 100 dps).
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

from gaussian_codegen.shared import constants
from gaussian_codegen.shared.aaa import aaa_to_rational_polys, evaluate_rational, horner_eval_mpf
from gaussian_codegen.shared.reference import DPS, ppf

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
        "support_points": [float(z) for z in aaa.support_points],
        "support_values": [float(y) for y in aaa.support_values],
        "weights": [float(w) for w in aaa.weights],
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Derive inverse-CDF AAA coefficients.")
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
        print()
        tail_fit = fit_region(tail, args.report)
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

"""Re-validate the committed `inverse_cdf_coefficients.move` against the oracle.

Reads the two-region (u128, bool) coefficient tables out of the committed Move
source and re-runs the on-chain quantile computation in Python using **integer
arithmetic that mirrors the Move implementation exactly**:

  - Upper-half dispatch (`inverse_cdf::inverse_cdf_upper_raw`): saturate `p ≥ 1`
    to MAX_Z, special-case `p = 0.5 → 0`, else the central rational in
    `u = p - 0.5` (`p < threshold`) or the tail rational in
    `r = sqrt(-2 ln(1 - p))` (`p ≥ threshold`).
  - The tail variable `r` is built with `shared.arithmetic.tail_r_wad` - at the
    WAD (10^18) accumulation scale, not the 10^9 output scale - which mirrors
    `common::raw_log2` + `u256::mul_div(..., Nearest)` + `u256::sqrt(..., Nearest)`.
  - Each rational: WAD-scale Horner (sign-magnitude, floor-div `mul_wad`) then
    the final `mul_div(N, 10^9, D, Nearest)` half-up ratio, clamped to MAX_Z.
  - Signed reflection (`sd29x9_base::inverse_cdf`): `p < 0.5 → -Φ⁻¹(1 - p)`.

Asserts, over a ~41k-point grid - a uniform interior sweep plus exhaustive
consecutive-input windows where the rounding is most delicate (just above
`p = 0.5`, across the central/tail seam, and the deepest tail), log-spaced
coverage of the tail complement `1 - p`, and the deep-tail anchor points - that
the worst-case absolute error in `z` vs the mpmath `erfinv` oracle stays within
`TARGET_ERROR_ULP × 10^-9`, that the signed output is monotone non-decreasing in
`p` (true adjacent-input monotonicity inside the exhaustive windows), and that
the reflection identity holds bit-exactly. Non-zero exit on failure, suitable
for CI.

Oracle note: `scipy.stats.norm.ppf` is float64 and wrong by up to ~5e-9 in the
deep tail, so the reference is the mpmath `erfinv`-based `shared.reference.ppf`.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys
from typing import Sequence

import numpy as np

from gaussian_codegen.shared import constants
from gaussian_codegen.shared.arithmetic import SignedInt, horner_eval, mul_div_nearest, tail_r_wad
from gaussian_codegen.shared.reference import ppf

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]

SCALE = constants.SCALE_DECIMAL
HALF_RAW = constants.HALF_RAW  # 5e8, Φ⁻¹(0.5) = 0
ONE_RAW = SCALE  # 1e9, p = 1.0
TARGET_ERROR_ULP = 5

COEFF_PATH = (
    REPO_ROOT
    / "math"
    / "fixed_point"
    / "sources"
    / "internal"
    / "inverse_cdf_coefficients.move"
)


def _parse_u128_vector(text: str, name: str) -> list[int]:
    m = re.search(rf"const {name}: vector<u128>\s*=\s*vector\[(.*?)\];", text, re.DOTALL)
    if not m:
        raise RuntimeError(f"could not find vector constant {name}")
    return [int(s.replace("_", "")) for s in re.findall(r"[\d_]+", m.group(1)) if s.replace("_", "")]


def _parse_bool_vector(text: str, name: str) -> list[bool]:
    m = re.search(rf"const {name}: vector<bool>\s*=\s*vector\[(.*?)\];", text, re.DOTALL)
    if not m:
        raise RuntimeError(f"could not find vector constant {name}")
    return [b == "true" for b in re.findall(r"\b(true|false)\b", m.group(1))]


def _parse_u128_const(text: str, name: str) -> int:
    m = re.search(rf"const {name}: u128\s*=\s*([\d_]+);", text)
    if not m:
        raise RuntimeError(f"could not find u128 constant {name}")
    return int(m.group(1).replace("_", ""))


Region = tuple[list[SignedInt], list[SignedInt]]  # (num, den)


def _parse_region(text: str, prefix: str) -> Region:
    num_mags = _parse_u128_vector(text, f"{prefix}_NUM_MAGS")
    num_negs = _parse_bool_vector(text, f"{prefix}_NUM_NEGS")
    den_mags = _parse_u128_vector(text, f"{prefix}_DEN_MAGS")
    den_negs = _parse_bool_vector(text, f"{prefix}_DEN_NEGS")
    if len(num_mags) != len(num_negs) or len(den_mags) != len(den_negs):
        raise RuntimeError(f"{prefix} coefficient length mismatch")
    return list(zip(num_mags, num_negs)), list(zip(den_mags, den_negs))


class Coeffs:
    def __init__(self, text: str):
        self.central = _parse_region(text, "CENTRAL")
        self.tail = _parse_region(text, "TAIL")
        self.threshold = _parse_u128_const(text, "CENTRAL_THRESHOLD_RAW")
        self.max_z = _parse_u128_const(text, "MAX_Z_RAW")


def _eval_rational(x_wad_mag: int, region: Region, max_z: int) -> int:
    """Mirror `inverse_cdf::eval_rational` for a transformed argument already at
    the WAD (10^18) accumulation scale."""
    num, den = region
    x_wad: SignedInt = (x_wad_mag, False)
    n = horner_eval(x_wad, num)
    d = horner_eval(x_wad, den)
    if n[1]:
        raise RuntimeError(f"N negative at x_wad={x_wad_mag}")
    if d[1] or d[0] == 0:
        raise RuntimeError(f"D non-positive at x_wad={x_wad_mag}")
    z = mul_div_nearest(n[0], SCALE, d[0])
    return min(z, max_z)  # last-ULP overshoot / defense-in-depth clamp


def upper_raw(p_raw: int, c: Coeffs) -> int:
    """Mirror `inverse_cdf::inverse_cdf_upper_raw` (p_raw in [HALF_RAW, ONE_RAW])."""
    if p_raw >= ONE_RAW:
        return c.max_z  # Φ⁻¹(1) saturates
    if p_raw == HALF_RAW:
        return 0  # Φ⁻¹(0.5)
    if p_raw < c.threshold:
        # u = p - 0.5, exact at 10^9, promoted losslessly to 10^18.
        return _eval_rational((p_raw - HALF_RAW) * SCALE, c.central, c.max_z)
    return _eval_rational(tail_r_wad(p_raw), c.tail, c.max_z)  # r = sqrt(-2 ln(1 - p)) at 10^18


def inverse_cdf_signed(p_raw: int, c: Coeffs) -> int:
    """Mirror `sd29x9_base::inverse_cdf`: signed z at 10^9 for p in [0, 1]."""
    if p_raw >= HALF_RAW:
        return upper_raw(p_raw, c)
    return -upper_raw(ONE_RAW - p_raw, c)  # Φ⁻¹(p) = -Φ⁻¹(1 - p)


def build_grid(n: int, threshold: int) -> list[int]:
    """A dense interior grid plus the region boundaries and deep-tail points on
    both sides, exhaustive consecutive-input windows where quantization error
    concentrates (just above p = 0.5, across the central/tail seam, and the
    deepest tail), and log-spaced coverage of the tail complement 1 - p, as
    integer p_raw in [1, ONE_RAW - 1]."""
    pts: set[int] = {int(round(x)) for x in np.linspace(1, ONE_RAW - 1, n)}
    pts.add(HALF_RAW)
    for k in (1, 2, 3, 5, 10, 50, 100, 500, 1000, 10**4, 10**5, 10**6, 10**7, 25 * 10**6):
        pts.add(ONE_RAW - k)  # near p = 1
        pts.add(k)  # near p = 0 (reflected)
    for d in (-3, -2, -1, 0, 1, 2, 3):
        pts.add(threshold + d)  # central/tail seam
        pts.add(ONE_RAW - threshold + d)  # reflected seam (p ≈ 0.025)
    pts.update(range(HALF_RAW + 1, HALF_RAW + 1_001))  # first central inputs
    pts.update(range(threshold - 10_000, threshold + 10_001))  # across the seam
    pts.update(range(ONE_RAW - 10_000, ONE_RAW))  # deepest tail
    # Log-spaced complement j: p = 1 - j / 10^9 across the whole tail region.
    for e in np.linspace(0.0, np.log10(25 * 10**6), 2_000):
        pts.add(ONE_RAW - int(round(10.0**e)))
    return sorted(p for p in pts if 1 <= p <= ONE_RAW - 1)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate quantized inverse-CDF coefficients.")
    parser.add_argument("--n", type=int, default=8000, help="interior validation grid size")
    parser.add_argument("--coeffs", type=pathlib.Path, default=COEFF_PATH)
    args = parser.parse_args(argv)

    if args.n < 2:
        print("FAIL: --n must be at least 2", file=sys.stderr)
        return 1
    if not args.coeffs.exists():
        print(f"FAIL: missing {args.coeffs}", file=sys.stderr)
        return 1

    text = args.coeffs.read_text(encoding="utf-8")
    c = Coeffs(text)
    try:
        coeffs_path = args.coeffs.relative_to(REPO_ROOT)
    except ValueError:
        coeffs_path = args.coeffs
    print(
        f"Parsed central ({len(c.central[0])}) + tail ({len(c.tail[0])}) coefficient pairs "
        f"(threshold={c.threshold}, MAX_Z_RAW={c.max_z}) from {coeffs_path}"
    )

    # Saturation endpoints (outside the open-interval grid).
    if upper_raw(ONE_RAW, c) != c.max_z:
        print("FAIL: Φ⁻¹(1) does not saturate to MAX_Z", file=sys.stderr)
        return 1
    if inverse_cdf_signed(0, c) != -c.max_z:
        print("FAIL: Φ⁻¹(0) does not saturate to -MAX_Z", file=sys.stderr)
        return 1

    grid = build_grid(args.n, c.threshold)
    worst_err = 0.0
    worst_p = 0.0
    prev_z = None
    for p_raw in grid:
        z = inverse_cdf_signed(p_raw, c)

        # Monotonicity: Φ⁻¹ is strictly increasing, so z must be non-decreasing.
        if prev_z is not None and z < prev_z:
            print(
                f"FAIL: monotonicity broken at p_raw={p_raw}: z={z} < previous {prev_z}",
                file=sys.stderr,
            )
            return 1
        prev_z = z

        # Reflection identity: Φ⁻¹(p) == -Φ⁻¹(1 - p), bit-exact.
        z_refl = inverse_cdf_signed(ONE_RAW - p_raw, c)
        if z != -z_refl:
            print(
                f"FAIL: reflection broken at p_raw={p_raw}: z={z} != -({z_refl})",
                file=sys.stderr,
            )
            return 1

        # Error vs the erfinv oracle at the exact quantized input.
        z_true = ppf(mpf_ratio(p_raw, SCALE))
        err = abs(z / SCALE - float(z_true))
        if err > worst_err:
            worst_err = err
            worst_p = p_raw / SCALE

    err_ulp = round(worst_err * SCALE)
    target_abs = TARGET_ERROR_ULP * 1e-9
    print(f"Monotonicity: non-decreasing across all {len(grid)} grid points ✓")
    print("Reflection:   Φ⁻¹(p) == -Φ⁻¹(1 - p) bit-exact across the grid ✓")
    print("Saturation:   Φ⁻¹(1) = +MAX_Z, Φ⁻¹(0) = -MAX_Z ✓")
    print(f"Worst error:  {worst_err:.3e} = {err_ulp} ULP at p={worst_p:.9f}")
    print(f"Target:       {target_abs:.3e} = {TARGET_ERROR_ULP} ULP")
    if worst_err <= target_abs:
        print(f"PASS: max_error_quantized = {worst_err:.3e} ≤ {target_abs:.3e} ✓")
        return 0
    print(f"FAIL: max_error_quantized = {worst_err:.3e} > {target_abs:.3e}", file=sys.stderr)
    return 1


def mpf_ratio(numerator: int, denominator: int):
    """Exact p = numerator / denominator as an mpf, for the oracle."""
    from mpmath import mpf

    return mpf(numerator) / mpf(denominator)


if __name__ == "__main__":
    sys.exit(main())

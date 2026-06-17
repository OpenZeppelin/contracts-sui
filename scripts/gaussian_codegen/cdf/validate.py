"""Re-validate the committed `cdf_coefficients.move` against scipy.

Reads the (u128, bool) coefficient tables out of the committed Move source and
runs the on-chain CDF computation in Python using **integer arithmetic that
mirrors the Move implementation exactly**:

  - z_raw at 10^9 → z_wad at 10^18 (multiply by 10^9).
  - Horner inner step: `acc = (acc.mag * z_wad) // 10^18 + c_i`, with
    sign-magnitude tracking and floor-division on the magnitude (matches
    `mul_div(..., Down)` in `math/core/sources/u256.move`).
  - Final ratio: `phi_raw = round(N.mag * 10^9 / D.mag)` with half-up
    (ties away from zero) nearest rounding, mirroring the on-chain
    `u256::mul_div(..., Nearest)` from `math/core/sources/u256.move`.

Asserts, over a 10,000-point grid, that the worst-case absolute error vs
`scipy.stats.norm.cdf` stays within `TARGET_ERROR_ULP` × 10^-9 and that the
outputs are monotone non-decreasing. Returns non-zero exit on failure,
suitable for CI.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys
from typing import Sequence

import numpy as np
from scipy.stats import norm

from gaussian_codegen.shared import constants

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]

WAD = constants.WAD
SCALE = constants.SCALE_DECIMAL
MAX_Z_RAW = constants.MAX_Z_RAW  # 6.3 at 10^9 — default; the gate parses the committed value
HALF_SCALE = SCALE // 2  # Φ(0) bit-exact
U256_MAX = 2**256 - 1  # on-chain Move intermediates must fit u256

COEFF_PATH = (
    REPO_ROOT / "math" / "fixed_point" / "sources" / "internal" / "cdf_coefficients.move"
)
TARGET_ERROR_ULP = 5  # ≤ 5 ULP at 10^-9 (== INV-17 contract)


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


def parse_coefficients(text: str) -> tuple[list[tuple[int, bool]], list[tuple[int, bool]]]:
    num_mags = _parse_u128_vector(text, "NUM_MAGS")
    num_negs = _parse_bool_vector(text, "NUM_NEGS")
    den_mags = _parse_u128_vector(text, "DEN_MAGS")
    den_negs = _parse_bool_vector(text, "DEN_NEGS")
    if len(num_mags) != len(num_negs):
        raise RuntimeError(f"NUM length mismatch: mags={len(num_mags)} vs negs={len(num_negs)}")
    if len(den_mags) != len(den_negs):
        raise RuntimeError(f"DEN length mismatch: mags={len(den_mags)} vs negs={len(den_negs)}")
    return list(zip(num_mags, num_negs)), list(zip(den_mags, den_negs))


# --- Sign-magnitude integer arithmetic mirroring the on-chain Move code ----
SignedInt = tuple[int, bool]  # (magnitude, is_negative)


def _canonicalize(sm: SignedInt) -> SignedInt:
    """Zero is always (0, False)."""
    return (0, False) if sm[0] == 0 else sm


def add(a: SignedInt, b: SignedInt) -> SignedInt:
    am, an = a
    bm, bn = b
    if am == 0:
        return _canonicalize(b)
    if bm == 0:
        return _canonicalize(a)
    if an == bn:
        s = am + bm
        if s > U256_MAX:
            raise RuntimeError(f"u256 overflow in add: {am} + {bm}")
        return (s, an)
    if am > bm:
        return (am - bm, an)
    if bm > am:
        return (bm - am, bn)
    return (0, False)  # exact cancellation


def mul_wad(a: SignedInt, b: SignedInt) -> SignedInt:
    """`(a * b) / WAD` with floor-division on magnitudes (== mul_div with Down rounding)."""
    am, an = a
    bm, bn = b
    prod = am * bm
    if prod > U256_MAX:
        raise RuntimeError(f"u256 overflow in mul_wad: {am} * {bm}")
    mag = prod // WAD
    return _canonicalize((mag, an ^ bn))


def horner_eval(z: SignedInt, coeffs: list[SignedInt]) -> SignedInt:
    if not coeffs:
        raise RuntimeError("empty polynomial")
    acc = _canonicalize(coeffs[-1])
    for c in reversed(coeffs[:-1]):
        acc = mul_wad(acc, z)
        acc = add(acc, c)
    return acc


def mul_div_nearest(a: int, b: int, d: int) -> int:
    """`(a * b) / d` rounded half-up (ties away from zero), mirroring the
    on-chain `u256::mul_div(..., Nearest)` from `math/core` (round up iff
    `rem >= d - rem`). Caller guarantees `d > 0`."""
    prod = a * b
    if prod > U256_MAX:
        raise RuntimeError(f"u256 overflow in mul_div_nearest: {a} * {b}")
    quot = prod // d
    rem = prod - quot * d
    return quot + 1 if rem >= d - rem else quot


def cdf_simulate(
    z_raw: int,
    neg: bool,
    num: list[SignedInt],
    den: list[SignedInt],
    max_z_raw: int = MAX_Z_RAW,
) -> int:
    """Mirror the on-chain `sd29x9_base::cdf` for a (z_raw at 10^9, neg) input.

    `max_z_raw` is the saturation cutoff; the CI gate passes the value parsed
    from the committed `cdf_coefficients.move` so the simulation tracks the
    on-chain bound instead of a Python copy that could silently drift from it."""
    if z_raw >= max_z_raw:
        return 0 if neg else SCALE
    if z_raw == 0:
        return HALF_SCALE  # Φ(0) bit-exact special case (INV-12)

    z_wad: SignedInt = (z_raw * SCALE, False)  # 10^9 → 10^18
    n_acc = horner_eval(z_wad, num)
    d_acc = horner_eval(z_wad, den)
    if n_acc[1]:
        raise RuntimeError(f"N negative at z_raw={z_raw} — INV-8 violation")
    if d_acc[1] or d_acc[0] == 0:
        raise RuntimeError(f"D non-positive at z_raw={z_raw} — INV-7 violation")

    # Final ratio: phi_raw = round(N * 10^9 / D) with Nearest (half-up) rounding.
    phi_raw = mul_div_nearest(n_acc[0], SCALE, d_acc[0])
    if phi_raw > SCALE:
        phi_raw = SCALE  # last-ULP overshoot guard (INV-9)

    if neg:
        # INV-14: cdf_nonneg ≥ 5e8 on [0, 6.3], so this never underflows
        if phi_raw < HALF_SCALE:
            raise RuntimeError(
                f"cdf_nonneg returned {phi_raw} < {HALF_SCALE} at z_raw={z_raw} — INV-14 violation"
            )
        phi_raw = SCALE - phi_raw
    return phi_raw


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate quantized CDF coefficients.")
    parser.add_argument("--n", type=int, default=10000, help="validation grid size")
    parser.add_argument("--coeffs", type=pathlib.Path, default=COEFF_PATH)
    args = parser.parse_args(argv)

    if not args.coeffs.exists():
        print(f"FAIL: missing {args.coeffs}", file=sys.stderr)
        return 1

    text = args.coeffs.read_text(encoding="utf-8")
    num, den = parse_coefficients(text)
    max_z_raw = _parse_u128_const(text, "MAX_Z_RAW")
    print(
        f"Parsed {len(num)} numerator + {len(den)} denominator coefficients "
        f"(MAX_Z_RAW = {max_z_raw}) from {args.coeffs.relative_to(REPO_ROOT)}"
    )

    grid = np.linspace(0.0, max_z_raw / SCALE, args.n)
    worst_err = 0.0
    worst_z = 0.0
    worst_neg = False
    prev_phi_pos = 0
    for z in grid:
        # Quantize first and measure against Φ at the quantized input, so the
        # gate scores the on-chain function at its own representable inputs
        # rather than folding input-quantization skew into the error.
        z_raw = int(round(float(z) * SCALE))
        zf = z_raw / SCALE
        phi_pos = cdf_simulate(z_raw, False, num, den, max_z_raw)
        # Also drive the negative branch: this exercises the reflection and the
        # INV-14 underflow guard inside cdf_simulate, neither of which the
        # positive path reaches.
        phi_neg = cdf_simulate(z_raw, True, num, den, max_z_raw)
        if phi_neg != SCALE - phi_pos:
            print(
                f"FAIL: reflection broken at z_raw={z_raw}: "
                f"Φ(-z)={phi_neg} != {SCALE} - {phi_pos}",
                file=sys.stderr,
            )
            return 1
        # Monotonicity: Φ is non-decreasing, and in the far tail its true
        # increment falls below the 10^-9 output resolution, so the fit's
        # error wiggle could in principle invert neighboring outputs. Gate
        # against any inversion at grid resolution.
        if phi_pos < prev_phi_pos:
            print(
                f"FAIL: monotonicity broken at z_raw={z_raw}: "
                f"Φ(z)={phi_pos} < previous {prev_phi_pos}",
                file=sys.stderr,
            )
            return 1
        prev_phi_pos = phi_pos
        for neg, phi_raw in ((False, phi_pos), (True, phi_neg)):
            ref = float(norm.cdf(-zf if neg else zf))
            err = abs(phi_raw / SCALE - ref)
            if err > worst_err:
                worst_err = err
                worst_z = zf
                worst_neg = neg

    err_ulp = round(worst_err * SCALE)
    target_abs = TARGET_ERROR_ULP * 1e-9
    sign = "-" if worst_neg else "+"
    print(f"Monotonicity: non-decreasing across all {args.n} grid points ✓")
    print(f"Worst error: {worst_err:.3e} = {err_ulp} ULP at z={sign}{worst_z:.5f}")
    print(f"Target:      {target_abs:.3e} = {TARGET_ERROR_ULP} ULP")
    if worst_err <= target_abs:
        print(f"PASS: max_error_quantized = {worst_err:.3e} ≤ {target_abs:.3e} ✓")
        return 0
    print(
        f"FAIL: max_error_quantized = {worst_err:.3e} > {target_abs:.3e}",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())

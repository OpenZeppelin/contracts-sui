"""Re-validate the committed `cdf_coefficients.move` against scipy.

Reads the (u128, bool) coefficient tables out of the committed Move source and
runs the on-chain CDF computation in Python using **integer arithmetic that
mirrors the Move implementation exactly**:

  - z_raw at 10^9 → z_wad at 10^18 (multiply by 10^9).
  - Horner inner step: `acc = (acc.mag * z_wad) // 10^18 + c_i`, with
    sign-magnitude tracking and floor-division on the magnitude (matches
    `mul_div(..., Down)` in `math/core/sources/u256.move`).
  - Final ratio: `phi_raw = round(N.mag * 10^9 / D.mag)` with banker's-style
    nearest rounding (mirrors the Move `Nearest` mode).

Asserts that the worst-case absolute error vs `scipy.stats.norm.cdf` over a
10,000-point grid stays within `TARGET_ERROR_ULP` × 10^-9. Returns non-zero
exit on failure, suitable for CI.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys
from typing import Sequence

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

import numpy as np  # noqa: E402
from scipy.stats import norm  # noqa: E402

WAD = 10**18
SCALE = 10**9
MAX_Z_RAW = 6_300_000_000  # 6.3 at 10^9
HALF_SCALE = SCALE // 2  # Φ(0) bit-exact

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


def signed_add(a: SignedInt, b: SignedInt) -> SignedInt:
    am, an = a
    bm, bn = b
    if am == 0:
        return _canonicalize(b)
    if bm == 0:
        return _canonicalize(a)
    if an == bn:
        return (am + bm, an)
    if am > bm:
        return (am - bm, an)
    if bm > am:
        return (bm - am, bn)
    return (0, False)  # exact cancellation


def signed_mul_wad(a: SignedInt, b: SignedInt) -> SignedInt:
    """`(a * b) / WAD` with floor-division on magnitudes (== mul_div with Down rounding)."""
    am, an = a
    bm, bn = b
    mag = (am * bm) // WAD
    return _canonicalize((mag, an ^ bn))


def horner_eval(z: SignedInt, coeffs: list[SignedInt]) -> SignedInt:
    if not coeffs:
        raise RuntimeError("empty polynomial")
    acc = coeffs[-1]
    for c in reversed(coeffs[:-1]):
        acc = signed_mul_wad(acc, z)
        acc = signed_add(acc, c)
    return acc


def cdf_simulate(z_raw: int, neg: bool, num: list[SignedInt], den: list[SignedInt]) -> int:
    """Mirror the on-chain `sd29x9_base::cdf` for a (z_raw at 10^9, neg) input."""
    if z_raw >= MAX_Z_RAW:
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
    num_prod = n_acc[0] * SCALE
    phi_raw = (num_prod + d_acc[0] // 2) // d_acc[0]
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
    print(
        f"Parsed {len(num)} numerator + {len(den)} denominator coefficients from "
        f"{args.coeffs.relative_to(REPO_ROOT)}"
    )

    grid = np.linspace(0.0, 6.3, args.n)
    worst_err = 0.0
    worst_z = 0.0
    for z in grid:
        z_raw = int(round(float(z) * SCALE))
        ref = float(norm.cdf(float(z)))
        phi_raw = cdf_simulate(z_raw, False, num, den)
        approx = phi_raw / SCALE
        err = abs(approx - ref)
        if err > worst_err:
            worst_err = err
            worst_z = float(z)

    err_ulp = round(worst_err * SCALE)
    target_abs = TARGET_ERROR_ULP * 1e-9
    print(f"Worst error: {worst_err:.3e} = {err_ulp} ULP at z={worst_z:.5f}")
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

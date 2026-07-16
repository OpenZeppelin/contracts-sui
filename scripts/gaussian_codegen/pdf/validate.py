"""Re-validate the committed `pdf_coefficients.move` against scipy.

Mirrors `cdf/validate.py`. Reads the (u128, bool) coefficient tables out of the
committed Move source and re-runs the on-chain PDF computation in Python using
the shared sign-magnitude integer arithmetic (the exact mirror of the Move
`horner` module):

  - z_raw at 10^9 → z_wad at 10^36 (multiply by 10^27 = PDF_WAD / 10^9).
  - Horner inner step via `shared.arithmetic` (floor-division mul_wad, sign-
    magnitude add).
  - Final ratio: `phi_raw = round(N.mag * 10^9 / D.mag)` with half-up nearest
    rounding.

Asserts, over a 10,000-point grid, that the worst-case absolute error vs
`scipy.stats.norm.pdf` stays within `TARGET_ERROR_ULP` × 10^-9. Two exhaustive
tail gates (`shared.gates`) then prove neighbor-resolution monotonicity (no 1-ULP
inversion between adjacent raw inputs - φ non-increasing - which the 10^36 scale
guarantees) and u256 overflow margin. Returns non-zero exit on failure, suitable
for CI.

φ is even, so the signed `sd29x9_base::pdf` path just evaluates `pdf_nonneg_raw`
on |z| (no reflection, no z=0 special case); there is no extra signed branch to
mirror here. The on-chain evenness is covered by the Move test vectors.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys
from typing import Sequence

import numpy as np
from scipy.stats import norm

from gaussian_codegen.shared import constants, gates
from gaussian_codegen.shared.arithmetic import SignedInt, horner_eval, mul_div_nearest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]

SCALE = constants.SCALE_DECIMAL
WAD = constants.PDF_WAD  # PDF Horner-accumulation scale (10^36)
MAX_Z_RAW = constants.PDF_MAX_Z_RAW  # 6.402729806 at 10^9 - default; the gate parses the committed value
MONO_ONSET_RAW = 4_000_000_000  # z=4.0: below the z≈4.42 point where even the old 10^18 noise floor (~1.9e-5 ULP) first reached the per-step φ increment; nothing inverts lower

COEFF_PATH = (
    REPO_ROOT / "math" / "fixed_point" / "sources" / "internal" / "pdf_coefficients.move"
)
TARGET_ERROR_ULP = 5  # ≤ 5 ULP at 10^-9


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


def pdf_simulate(
    z_raw: int,
    num: list[SignedInt],
    den: list[SignedInt],
    max_z_raw: int = MAX_Z_RAW,
) -> int:
    """Mirror the on-chain `pdf::pdf_nonneg_raw` for a z_raw (at 10^9) input.

    `max_z_raw` is the saturation cutoff; the CI gate passes the value parsed
    from the committed `pdf_coefficients.move` so the simulation tracks the
    on-chain bound instead of a Python copy that could silently drift from it.

    Bit-for-bit fidelity to the Move pipeline is asserted by the Move test
    `sd29x9_pdf_tests::pdf_matches_offline_mirror`, so this mirror is a faithful
    stand-in for the on-chain path in the validation gates."""
    if z_raw >= max_z_raw:
        return 0  # tail saturates to 0

    z_wad: SignedInt = (z_raw * (WAD // SCALE), False)  # 10^9 → 10^36
    n_acc = horner_eval(z_wad, num, WAD)
    d_acc = horner_eval(z_wad, den, WAD)
    if n_acc[1]:
        raise RuntimeError(f"N negative at z_raw={z_raw} - pdf::EInternalNumNegative")
    if d_acc[1] or d_acc[0] == 0:
        raise RuntimeError(f"D non-positive at z_raw={z_raw} - pdf::EInternalDenNonPositive")

    # Final ratio: phi_raw = round(N * 10^9 / D) with Nearest (half-up) rounding.
    return mul_div_nearest(n_acc[0], SCALE, d_acc[0])


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate quantized PDF coefficients.")
    parser.add_argument("--n", type=int, default=10000, help="validation grid size")
    parser.add_argument("--coeffs", type=pathlib.Path, default=COEFF_PATH)
    args = parser.parse_args(argv)

    if args.n < 2:
        print("FAIL: --n must be at least 2", file=sys.stderr)
        return 1

    if not args.coeffs.exists():
        print(f"FAIL: missing {args.coeffs}", file=sys.stderr)
        return 1

    text = args.coeffs.read_text(encoding="utf-8")
    num, den = parse_coefficients(text)
    max_z_raw = _parse_u128_const(text, "MAX_Z_RAW")
    try:
        coeffs_path = args.coeffs.relative_to(REPO_ROOT)
    except ValueError:
        coeffs_path = args.coeffs  # a --coeffs path outside the repo stays absolute
    print(
        f"Parsed {len(num)} numerator + {len(den)} denominator coefficients "
        f"(MAX_Z_RAW = {max_z_raw}) from {coeffs_path}"
    )

    grid = np.linspace(0.0, max_z_raw / SCALE, args.n)
    worst_err = 0.0
    worst_z = 0.0
    for z in grid:
        # Quantize first and measure against φ at the quantized input, so the
        # gate scores the on-chain function at its own representable inputs.
        z_raw = int(round(float(z) * SCALE))
        zf = z_raw / SCALE
        phi = pdf_simulate(z_raw, num, den, max_z_raw)
        # φ is even, so the signed path returns this same value for ±z; one
        # measurement per |z| suffices (norm.pdf(-zf) == norm.pdf(zf)).
        ref = float(norm.pdf(zf))
        err = abs(phi / SCALE - ref)
        if err > worst_err:
            worst_err = err
            worst_z = zf

    # Exhaustive tail gates the coarse error grid above cannot see: 1-ULP neighbor
    # inversions and the peak u256 Horner intermediate.
    pairs, rechecks = gates.check_neighbor_monotonicity(
        num, den, WAD, SCALE, MONO_ONSET_RAW, max_z_raw, increasing=False
    )
    peak_bits, headroom = gates.check_overflow_margin(num, den, WAD, SCALE, max_z_raw)

    err_ulp = round(worst_err * SCALE)
    target_abs = TARGET_ERROR_ULP * 1e-9
    print(
        f"Monotonicity: non-increasing across all {pairs:,} neighbor pairs in "
        f"[{MONO_ONSET_RAW / SCALE:.1f}, {max_z_raw / SCALE:.9f}] "
        f"({rechecks} exact re-checks) ✓"
    )
    print(f"Overflow: peak Horner product {peak_bits} bits, {headroom} bits under 2^256 ✓")
    print(f"Worst error: {worst_err:.3e} = {err_ulp} ULP at z=±{worst_z:.5f}")
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

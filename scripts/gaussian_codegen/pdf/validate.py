"""Re-validate the committed `pdf_coefficients.move` against scipy.

Mirrors `cdf/validate.py`. Reads the (u128, bool) coefficient tables out of the
committed Move source and re-runs the on-chain PDF computation in Python using
the shared sign-magnitude integer arithmetic (the exact mirror of the Move
`horner` module):

  - z_raw at 10^9 → z_wad at 10^18 (multiply by 10^9).
  - Horner inner step via `shared.arithmetic` (floor-division mul_wad, sign-
    magnitude add).
  - Final ratio: `phi_raw = round(N.mag * 10^9 / D.mag)` with half-up nearest
    rounding.

Asserts, over a 10,000-point grid, that the worst-case absolute error vs
`scipy.stats.norm.pdf` stays within `TARGET_ERROR_ULP` × 10^-9 and that the
outputs are monotone non-increasing on [0, PDF_MAX_Z]. Returns non-zero exit on
failure, suitable for CI.

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

from gaussian_codegen.shared import constants
from gaussian_codegen.shared.arithmetic import SignedInt, horner_eval, mul_div_nearest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]

SCALE = constants.SCALE_DECIMAL
MAX_Z_RAW = constants.PDF_MAX_Z_RAW  # 6.5 at 10^9 - default; the gate parses the committed value

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
    on-chain bound instead of a Python copy that could silently drift from it."""
    if z_raw >= max_z_raw:
        return 0  # tail saturates to 0

    z_wad: SignedInt = (z_raw * SCALE, False)  # 10^9 → 10^18
    n_acc = horner_eval(z_wad, num)
    d_acc = horner_eval(z_wad, den)
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
    print(
        f"Parsed {len(num)} numerator + {len(den)} denominator coefficients "
        f"(MAX_Z_RAW = {max_z_raw}) from {args.coeffs.relative_to(REPO_ROOT)}"
    )

    grid = np.linspace(0.0, max_z_raw / SCALE, args.n)
    worst_err = 0.0
    worst_z = 0.0
    prev_phi: int | None = None  # φ is monotone non-increasing on [0, PDF_MAX_Z]
    for z in grid:
        # Quantize first and measure against φ at the quantized input, so the
        # gate scores the on-chain function at its own representable inputs.
        z_raw = int(round(float(z) * SCALE))
        zf = z_raw / SCALE
        phi = pdf_simulate(z_raw, num, den, max_z_raw)
        if prev_phi is not None and phi > prev_phi:
            print(
                f"FAIL: monotonicity broken at z_raw={z_raw}: "
                f"φ(z)={phi} > previous {prev_phi}",
                file=sys.stderr,
            )
            return 1
        prev_phi = phi
        # φ is even, so the signed path returns this same value for ±z; one
        # measurement per |z| suffices (norm.pdf(-zf) == norm.pdf(zf)).
        ref = float(norm.pdf(zf))
        err = abs(phi / SCALE - ref)
        if err > worst_err:
            worst_err = err
            worst_z = zf

    err_ulp = round(worst_err * SCALE)
    target_abs = TARGET_ERROR_ULP * 1e-9
    print(f"Monotonicity: non-increasing across all {args.n} grid points ✓")
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

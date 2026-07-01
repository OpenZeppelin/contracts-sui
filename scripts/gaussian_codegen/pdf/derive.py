"""Derive the standard-normal PDF rational by optimizing the exact integer
pipeline (PR2), not a continuous float64 fit. Mirrors `cdf/derive.py`; see it for
the full rationale.

Two PDF-specific differences from the CDF:

- The density is monotone *non-increasing* on `[0, MAX_Z]`, so candidates are
  screened for `R'(z) <= 0` (INCREASING = False).
- phi is even, so phi'(0) = 0. A free fit tends to overshoot the peak into a
  sub-ULP `R'(0) > 0` bump - continuously non-monotone at the single point z=0.
  PIN_ZERO_SLOPE pins `R'(0) = 0` (the natural even-peak condition), keeping the
  fit monotone through the peak at a small cost in correctly-rounded count.

Degree is pinned to TARGET_DEGREE. Coefficients are ascending power order,
`D(0) = 1`. Pass `--report` for the full candidate table.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys
import warnings
from typing import Sequence

from mpmath import mp, mpf, npdf

from gaussian_codegen.shared import constants, refit
from gaussian_codegen.shared.aaa import aaa_to_rational_polys, horner_eval_mpf
from gaussian_codegen.shared.reference import DPS

warnings.filterwarnings(
    "ignore",
    message=r"AAA failed to converge within \d+ iterations\.",
    category=RuntimeWarning,
)

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]

MAX_Z = mpf(constants.PDF_MAX_Z)
MAX_Z_RAW = constants.PDF_MAX_Z_RAW
WAD = constants.PDF_WAD
SCALE = constants.SCALE_DECIMAL
TARGET_DEGREE = 10  # shipped PDF degree; pinned (not swept) so it stays fixed across regenerations
TARGET_ERROR = 5e-9  # continuous-fit sanity ceiling (the shipped budget is the ULP count, below)
N_FIT_GRID = 5000
P_SCHEDULE = [1.0, 0.85, 0.72, 0.6, 0.5, 0.42]
PIN_ZERO_SLOPE = True  # phi'(0) = 0: pin R'(0) = 0 so the fit stays monotone through the peak
INCREASING = False

OUTPUT_PATH = pathlib.Path(__file__).parent / ".derive_output.json"


def target(z) -> mpf:
    mp.dps = DPS
    return npdf(mpf(z))


def aaa_seed() -> tuple[list[mpf], list[mpf]]:
    """AAA rational at the pinned degree, converted to explicit N(z)/D(z). Used
    as the IRLS seed and as an independent cross-check of the shape/degree."""
    import numpy as np
    from scipy.interpolate import AAA
    from scipy.stats import norm

    grid = np.linspace(0.0, float(constants.PDF_MAX_Z), N_FIT_GRID)
    aaa = AAA(grid, norm.pdf(grid), max_terms=TARGET_DEGREE + 1, rtol=1e-15, clean_up_tol=0)
    degree = len(aaa.support_points) - 1
    if degree != TARGET_DEGREE:
        raise RuntimeError(f"AAA seed produced degree {degree}, expected pinned {TARGET_DEGREE}")
    return aaa_to_rational_polys(aaa)


def assert_signs_central(num: Sequence[mpf], den: Sequence[mpf], n: int = 10000) -> None:
    """Verify D(z) > 0 and N(z) >= 0 on the central domain (pdf::eval_rational)."""
    mp.dps = DPS
    for i in range(n + 1):
        z = MAX_Z * mpf(i) / n
        if horner_eval_mpf(den, z) <= 0:
            raise RuntimeError(f"D(z) <= 0 at z={mp.nstr(z, 8)}")
        if horner_eval_mpf(num, z) < 0:
            raise RuntimeError(f"N(z) < 0 at z={mp.nstr(z, 8)}")


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Derive PDF rational (exact-pipeline objective).")
    parser.add_argument("--report", action="store_true", help="Print the full candidate table.")
    args = parser.parse_args(argv)

    print(f"Pinned degree: {TARGET_DEGREE} (n_coeffs = {TARGET_DEGREE + 1}) on [0, {float(MAX_Z)}]")
    best, scored = refit.refit(
        target=target, max_z=MAX_Z, max_z_raw=MAX_Z_RAW, deg=TARGET_DEGREE,
        increasing=INCREASING, wad=WAD, scale=SCALE, aaa_seed=aaa_seed(),
        p_schedule=P_SCHEDULE, pin_zero_slope=PIN_ZERO_SLOPE,
    )

    if args.report:
        print("\n  candidate      miss / total       rate     max|R-phi|   mono?  bits")
        for c in scored:
            mono = "mono" if c.mono_margin > -refit.MONO_TOL else "NON "
            print(
                f"  {c.tag:12s} {c.grid_miss:6,}/{c.grid_total:<8,} {c.grid_rate*100:8.4f}%  "
                f"{float(c.sup_err)*1e9:8.4f}ULP  {mono}  {c.max_bits}"
            )
        print()

    if float(best.sup_err) > TARGET_ERROR:
        print(f"FAIL: selected fit sup error {float(best.sup_err):.3e} exceeds {TARGET_ERROR:.1e}", file=sys.stderr)
        return 1
    assert_signs_central(best.num, best.den)

    print(
        f"Selected {best.tag}: {best.grid_miss:,}/{best.grid_total:,} misses on the scoring grid "
        f"({best.grid_rate*100:.4f}% correctly rounded), max|R-phi|={float(best.sup_err)*1e9:.4f} ULP, "
        f"max coeff {best.max_bits}/128 bits"
    )

    output = {
        "degree": TARGET_DEGREE,
        "n_coeffs": TARGET_DEGREE + 1,
        "method": "AAA seed + descending-p IRLS homotopy (R'(0)=0 pinned), selected by exact-pipeline correctly-rounded count",
        "selected": best.tag,
        "p_schedule": P_SCHEDULE,
        "pin_zero_slope": PIN_ZERO_SLOPE,
        "max_z": constants.PDF_MAX_Z,
        "wad": str(WAD),
        "scale_decimal": str(SCALE),
        "num_coeffs_str": [refit.coeff_str(c) for c in best.num],
        "den_coeffs_str": [refit.coeff_str(c) for c in best.den],
        "max_coeff_bits": best.max_bits,
        "sup_error": float(best.sup_err),
        "sup_error_z": float(best.sup_z),
        "grid_correctly_rounded": best.grid_total - best.grid_miss,
        "grid_total": best.grid_total,
        "grid_correct_rate": best.grid_rate,
    }
    OUTPUT_PATH.write_text(json.dumps(output, indent=2), encoding="utf-8")
    print(f"\nWrote {OUTPUT_PATH.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

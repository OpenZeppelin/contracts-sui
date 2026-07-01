"""Selects the shipped rational by scoring candidates through the exact integer
pipeline - PR2's core: optimize the function that ships, not a continuous proxy.

Pipeline shared by `cdf/derive.py` and `pdf/derive.py`:

1. Seed from two independent fits: the SciPy AAA rational (`shared/aaa.py`, a
   strong near-minimax start and a cross-check that the result is not an IRLS
   artifact) and the linearized-minimax `remez_seed` (`shared/fit.py`).
2. From each seed, run the descending-`p` IRLS homotopy (`fit.irls_candidates`),
   walking toward the correctly-rounded-count (L0) objective.
3. Quantize every candidate to `(u128 magnitude, bool sign)` at WAD and score it
   with `accuracy.grid_miscount` - the count of representable inputs whose *exact
   integer output* misses the mpmath oracle's nearest-integer value.
4. Keep only candidates that fit u128 and are (continuously) monotone in the
   required direction, then pick the fewest misses. Monotonicity is a hard gate;
   the correctly-rounded count is the objective - exactly the PR2 selection rule.

At WAD = 10^36 the Horner floor-truncation perturbs an output by ~10^-26 ULP, far
below the smallest true per-step increment anywhere in the domain, so a
continuously-monotone rational yields a monotone quantized output; the shipped
`validate.py` re-checks that continuous monotonicity and spot-checks the tail.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from mpmath import mp, mpf

from gaussian_codegen.shared import fit, gates
from gaussian_codegen.shared.accuracy import grid_miscount
from gaussian_codegen.shared.arithmetic import SignedInt
from gaussian_codegen.shared.move_emit import quantize

# A candidate is admitted as monotone if its worst wrong-direction slope stays
# below this. It comfortably admits the even-peak pin's R'(0) ~ 0 (PDF) while
# rejecting a genuine sub-ULP bump (~10^-9). A slope this small integrates to a
# < 10^-5 ULP excursion across the whole domain - far too little to move any
# quantized output - so a passing candidate is monotone once quantized.
MONO_TOL = mpf("1e-12")


@dataclass
class Candidate:
    tag: str
    num: list[mpf]
    den: list[mpf]
    num_q: list[SignedInt]
    den_q: list[SignedInt]
    grid_miss: int
    grid_total: int
    max_bits: int
    mono_margin: mpf
    sup_err: mpf
    sup_z: mpf

    @property
    def grid_rate(self) -> float:
        return 1.0 - self.grid_miss / self.grid_total if self.grid_total else 0.0


# Significant digits used to serialize coefficients. Well above what pins the
# u128 (~36 digits) so scoring, the emitted JSON, and `emit_coefficients.py` all
# quantize to the identical integer (keeps the drift guard exact).
COEFF_DIGITS = 50


def coeff_str(c: mpf) -> str:
    return mp.nstr(c, COEFF_DIGITS)


def quantize_coeffs(coeffs: list[mpf], wad: int) -> list[SignedInt]:
    """Quantize ascending-power `mpf` coefficients to sign-magnitude u128 at WAD -
    the same rounding `emit_coefficients.py` applies, so a candidate is scored on
    the exact numbers that would ship."""
    return [quantize(coeff_str(c), wad) for c in coeffs]


def _oracle_round(grid_raw: np.ndarray, target, scale: int) -> np.ndarray:
    return np.array(
        [int(mp.floor(target(mpf(int(z)) / scale) * scale + mpf("0.5"))) for z in grid_raw],
        dtype=object,
    )


def refit(
    *,
    target,
    max_z: mpf,
    max_z_raw: int,
    deg: int,
    increasing: bool,
    wad: int,
    scale: int,
    aaa_seed: tuple[list[mpf], list[mpf]],
    p_schedule,
    pin_zero_slope: bool = False,
    n_score: int = 300_000,
) -> tuple[Candidate, list[Candidate]]:
    """Return `(selected, all_scored)`. `selected` minimizes exact-pipeline
    misses among monotone, u128-fitting candidates; `all_scored` is every scored
    candidate (for `--report`). Raises if none pass, or if the winner fails the
    u256 overflow gate."""
    grid = np.unique(np.linspace(1, max_z_raw - 1, n_score).astype(np.int64))
    oracle = _oracle_round(grid, target, scale)

    seeds = [("aaa", aaa_seed), ("remez", fit.remez_seed(target, max_z, deg))]
    scored: list[Candidate] = []
    rejected: list[Candidate] = []
    for sname, seed in seeds:
        raw = [(f"{sname}-seed", seed[0], seed[1])]
        raw += [
            (f"{sname}/{tag}", num, den)
            for tag, num, den in fit.irls_candidates(
                target, max_z, deg, seed, p_schedule, pin_zero_slope=pin_zero_slope
            )
        ]
        for tag, num, den in raw:
            nq = quantize_coeffs(num, wad)
            dq = quantize_coeffs(den, wad)
            max_bits = max(m.bit_length() for m, _ in nq + dq)
            margin = fit.monotonicity_margin(num, den, max_z, increasing)
            miss = grid_miscount(nq, dq, wad, scale, grid, oracle)
            cand = Candidate(tag, num, den, nq, dq, miss, len(grid), max_bits, margin, *fit.sup_error(num, den, target, max_z))
            (scored if (max_bits < 128 and margin > -MONO_TOL) else rejected).append(cand)

    if not scored:
        raise RuntimeError("no candidate passed the u128 + monotonicity filters")
    scored.sort(key=lambda c: (c.grid_miss, -float(c.mono_margin)))

    # The n=4000 `monotonicity_margin` above is only a fast ranking pre-filter.
    # Confirm the winner with the *exact same* gates `validate.py` runs - the
    # dense-grid continuous-monotonicity check and the overflow margin - so
    # `make regen` can never emit a table the CI gate would then reject. Fall
    # through to the next-best candidate on the rare failure.
    for cand in scored:
        try:
            gates.check_continuous_monotonicity(cand.num_q, cand.den_q, wad, scale, max_z_raw, increasing)
            gates.check_overflow_margin(cand.num_q, cand.den_q, wad, scale, max_z_raw)
        except RuntimeError:
            continue
        return cand, scored + rejected
    raise RuntimeError("no candidate passed the continuous-monotonicity + overflow gates")

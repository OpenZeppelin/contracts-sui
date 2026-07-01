"""Exact-pipeline accuracy metrics for the quantized gaussian evaluators.

Where `gates.py` answers the pass/fail CI questions (is the quantized output
monotone? does the Horner product clear `2^256`?), this module answers the
"how good is the fit?" question that PR2's re-fit optimizes: over the
representable inputs, how many quantized outputs are **correctly rounded**
(equal to the nearest-integer oracle value at the `10^9` output scale), how many
land within 1 ULP, and what is the worst-case ULP error.

Two entry points, both scoring the *exact* integer pipeline (the function that
ships), never a continuous rational:

- `grid_miscount(...)` - exact big-int pipeline over a bounded, dense grid of
  representable inputs against a pre-computed oracle. Cheap enough to call once
  per candidate, so `<family>/derive.py` uses it to *select* among fits.
- `exhaustive_stats(...)` - exact over *every* representable input in the central
  domain, made tractable by the same float64-proxy + exact-recheck trick the
  monotonicity gate uses: a vectorised float64 pass classifies each input, and
  only the few inputs whose rounding the proxy cannot resolve are re-evaluated
  through the exact big-int pipeline (and, rarer still, the mpmath oracle). Used
  by `validate.py --report` for the authoritative correctly-rounded percentage
  quoted in the docs.

Both take the family's quantized `(magnitude, is_negative)` coefficient tables -
identical to what `validate.py` parses from the committed Move - so they measure
the shipped numbers, not the pre-quantization fit.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Sequence

import numpy as np

from gaussian_codegen.shared.arithmetic import SignedInt, horner_eval, mul_div_nearest

# Float64 evaluation of the rational is accurate to a few x10^-5 ULP after
# scaling to 10^9 (worst-case cancellation in the degree-10 Horner sum), and a
# float64 Phi/phi is good to ~10^-7 ULP. An input whose proxy value sits farther
# than these margins from a rounding boundary cannot round differently under the
# exact pipeline / mpmath oracle, so only nearer inputs are re-checked exactly.
_PIPELINE_MARGIN = 1e-3
_ORACLE_MARGIN = 1e-5


@dataclass(frozen=True)
class AccuracyStats:
    """Correctly-rounded / within-1-ULP tallies over a set of inputs."""

    total: int
    correct: int
    within_one: int
    max_ulp: int
    worst_z_raw: int
    rechecks: int

    @property
    def correct_rate(self) -> float:
        return self.correct / self.total if self.total else 0.0

    @property
    def within_one_rate(self) -> float:
        return self.within_one / self.total if self.total else 0.0

    @property
    def miss(self) -> int:
        return self.total - self.correct


def _float_coeffs(coeffs: Sequence[SignedInt], wad: int) -> np.ndarray:
    """Ascending-power real coefficients (signed magnitude / wad) as float64."""
    return np.array([(-m if neg else m) / wad for m, neg in coeffs], dtype=np.float64)


def _eval_central(z_raw: int, num, den, wad: int, scale: int) -> int:
    """Exact integer central-domain output `round(N(z)/D(z) * scale)`, half-up.

    Mirrors the on-chain Horner + final `mul_div(..., Nearest)` on `[0, max_z_raw)`.
    Saturation and the CDF z=0 special case are the caller's job (`special_outputs`);
    the CDF last-ULP-overshoot clamp (`phi_raw > SCALE -> SCALE`) is also omitted -
    it never fires on a validated fit (the >0.5-ULP overshoot it guards exceeds the
    fit error), so scoring the raw rational here matches what ships."""
    z_wad: SignedInt = (z_raw * (wad // scale), False)  # 10^9 -> wad
    n = horner_eval(z_wad, num, wad)
    d = horner_eval(z_wad, den, wad)
    return mul_div_nearest(n[0], scale, d[0])


def grid_miscount(
    num: list[SignedInt],
    den: list[SignedInt],
    wad: int,
    scale: int,
    grid_raw: np.ndarray,
    oracle_round: np.ndarray,
    special_outputs: dict[int, int] | None = None,
) -> int:
    """Number of inputs on `grid_raw` whose exact pipeline output differs from
    the pre-computed nearest-integer `oracle_round`. `grid_raw[i]` pairs with
    `oracle_round[i]`. `special_outputs` forces the output at listed raw inputs
    (e.g. the CDF `z=0 -> scale/2` special case).

    The scoring objective for `derive.py`: minimize this over candidate fits."""
    special = special_outputs or {}
    miss = 0
    for z_raw, target in zip(grid_raw.tolist(), oracle_round.tolist()):
        out = special.get(z_raw)
        if out is None:
            out = _eval_central(z_raw, num, den, wad, scale)
        if out != target:
            miss += 1
    return miss


def exhaustive_stats(
    num: list[SignedInt],
    den: list[SignedInt],
    wad: int,
    scale: int,
    max_z_raw: int,
    oracle_float: Callable[[np.ndarray], np.ndarray],
    oracle_round: Callable[[int], int],
    special_outputs: dict[int, int] | None = None,
    chunk: int = 5_000_000,
    pipeline_margin: float = _PIPELINE_MARGIN,
    oracle_margin: float = _ORACLE_MARGIN,
) -> AccuracyStats:
    """Exact correctly-rounded / within-1-ULP tally over every representable
    input in `[0, max_z_raw)` (the central domain; inputs at or beyond
    `max_z_raw` saturate to the correctly-rounded endpoint by construction and
    are excluded).

    Tractable via a vectorised float64 proxy: an input is resolved by the proxy
    unless its pipeline value or its oracle value sits within a rounding-boundary
    margin, in which case it is re-evaluated through the exact big-int pipeline
    (and mpmath oracle). The margins sit far above the float64 error, so the
    tally is exact, not sampled.

    `oracle_float` is a vectorised float64 truth (e.g. `scipy.stats.norm.cdf`);
    `oracle_round(z_raw)` is the exact nearest-integer oracle (mpmath) used only
    for the handful of oracle-boundary re-checks."""
    special = special_outputs or {}
    num_f = _float_coeffs(num, wad)[::-1]  # np.polyval wants highest-power first
    den_f = _float_coeffs(den, wad)[::-1]

    total = max_z_raw
    correct = 0
    within_one = 0
    max_ulp = 0
    worst_z_raw = 0
    rechecks = 0

    for lo in range(0, max_z_raw, chunk):
        hi = min(lo + chunk, max_z_raw)
        z_raw = np.arange(lo, hi, dtype=np.int64)
        z = z_raw / scale

        pv = np.polyval(num_f, z) / np.polyval(den_f, z) * scale
        ov = oracle_float(z) * scale
        p_round = np.floor(pv + 0.5)
        o_round = np.floor(ov + 0.5)

        # Force the special-case outputs (e.g. CDF z=0) into the proxy so they
        # are scored like any other input.
        for z0, out0 in special.items():
            if lo <= z0 < hi:
                p_round[z0 - lo] = out0

        p_amb = np.abs((pv - np.floor(pv)) - 0.5) < pipeline_margin
        o_amb = np.abs((ov - np.floor(ov)) - 0.5) < oracle_margin
        # A forced special-case output is exact - never ambiguous on the pipeline side.
        for z0 in special:
            if lo <= z0 < hi:
                p_amb[z0 - lo] = False
        ambiguous = p_amb | o_amb

        diff = np.abs(p_round - o_round)
        confident = ~ambiguous
        correct += int(np.count_nonzero(confident & (diff == 0)))
        within_one += int(np.count_nonzero(confident & (diff <= 1)))

        # Worst-case ULP among confident inputs (proxy diff is exact off-boundary).
        conf_diff = np.where(confident, diff, 0)
        idx = int(np.argmax(conf_diff))
        if conf_diff[idx] > max_ulp:
            max_ulp = int(conf_diff[idx])
            worst_z_raw = lo + idx

        # Exact re-check for the few unresolved inputs.
        for i in np.nonzero(ambiguous)[0]:
            zr = lo + int(i)
            out = special.get(zr)
            if out is None:
                out = _eval_central(zr, num, den, wad, scale)
            ideal = oracle_round(zr) if o_amb[i] else int(o_round[i])
            rechecks += 1
            d = abs(out - ideal)
            if d == 0:
                correct += 1
            if d <= 1:
                within_one += 1
            if d > max_ulp:
                max_ulp = d
                worst_z_raw = zr

    return AccuracyStats(
        total=total,
        correct=correct,
        within_one=within_one,
        max_ulp=max_ulp,
        worst_z_raw=worst_z_raw,
        rechecks=rechecks,
    )

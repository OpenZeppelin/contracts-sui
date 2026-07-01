"""Unit tests for the PR2 re-fit machinery: the exact-pipeline accuracy metrics
(`shared/accuracy.py`), the rational fitter (`shared/fit.py`), and the
coefficient quantization used by the selector (`shared/refit.py`)."""
from __future__ import annotations

import numpy as np
from mpmath import mp, mpf, ncdf

from gaussian_codegen.shared import fit, refit
from gaussian_codegen.shared.accuracy import (
    AccuracyStats,
    _eval_central,
    exhaustive_stats,
    grid_miscount,
)
from gaussian_codegen.shared.move_emit import quantize

WAD = 10**36
SCALE = 10**9


def _q(reals: list[str]) -> list[tuple[int, bool]]:
    return [quantize(s, WAD) for s in reals]


# --- accuracy: exact pipeline vs a brute-force reference --------------------


def _brute_force(num, den, max_z_raw, oracle_round, special):
    """Reference tally over every input, no float64 proxy - the ground truth
    `exhaustive_stats` must reproduce."""
    total = max_z_raw
    correct = within = max_ulp = worst = 0
    for zr in range(max_z_raw):
        out = special.get(zr) if special else None
        if out is None:
            out = _eval_central(zr, num, den, WAD, SCALE)
        d = abs(out - oracle_round(zr))
        if d == 0:
            correct += 1
        if d <= 1:
            within += 1
        if d > max_ulp:
            max_ulp, worst = d, zr
    return correct, within, max_ulp, worst, total


def test_exhaustive_stats_matches_brute_force():
    # Pipeline R(z) = 0.5 + 0.35 z; oracle line 0.5 + 0.30 z. The 0.05 z gap
    # grows with z, producing correct, 1-ULP, and multi-ULP outcomes plus
    # rounding-boundary inputs that exercise the proxy's exact re-check path.
    num, den = _q(["0.5", "0.35"]), _q(["1.0"])
    max_z_raw = 60_000

    def oracle_round(zr: int) -> int:
        return int(mp.floor(mpf("0.5") * SCALE + mpf("0.30") * zr + mpf("0.5")))

    def oracle_float(z: np.ndarray) -> np.ndarray:
        return 0.5 + 0.30 * z

    stats = exhaustive_stats(num, den, WAD, SCALE, max_z_raw, oracle_float, oracle_round)
    correct, within, max_ulp, worst, total = _brute_force(num, den, max_z_raw, oracle_round, None)

    assert isinstance(stats, AccuracyStats)
    assert stats.total == total
    assert stats.correct == correct
    assert stats.within_one == within
    assert stats.max_ulp == max_ulp
    # the reported worst location genuinely carries the max error
    d = abs(_eval_central(stats.worst_z_raw, num, den, WAD, SCALE) - oracle_round(stats.worst_z_raw))
    assert d == max_ulp


def test_exhaustive_stats_honors_special_outputs():
    # Pipeline rational R(0) = 0.5 -> 5e8, but the oracle line is 0.4 + 0.3 z so
    # the true value at z=0 is 4e8: without the special case z=0 is a 1e8-ULP
    # miss. Forcing the output to 4e8 (the CDF z=0 -> HALF_RAW analogue, which
    # agrees with the oracle) must make it correctly rounded. The forced value
    # matches what oracle_float rounds to at z=0, exactly as in real usage.
    num, den = _q(["0.5", "0.35"]), _q(["1.0"])
    special = {0: 400_000_000}

    def oracle_round(zr: int) -> int:
        return int(mp.floor(mpf("0.4") * SCALE + mpf("0.30") * zr + mpf("0.5")))

    def oracle_float(z: np.ndarray) -> np.ndarray:
        return 0.4 + 0.30 * z

    # Sanity: without the special case, z=0 is a gross miss.
    assert _eval_central(0, num, den, WAD, SCALE) != oracle_round(0)

    stats = exhaustive_stats(num, den, WAD, SCALE, 40_000, oracle_float, oracle_round, special_outputs=special)
    correct, within, max_ulp, _, total = _brute_force(num, den, 40_000, oracle_round, special)
    assert (stats.total, stats.correct, stats.within_one, stats.max_ulp) == (total, correct, within, max_ulp)


def test_grid_miscount_counts_exact_misses():
    num, den = _q(["0.5", "0.35"]), _q(["1.0"])
    grid = np.array([1, 100, 5_000, 20_000], dtype=np.int64)

    def oracle_round(zr):
        return int(mp.floor(mpf("0.5") * SCALE + mpf("0.30") * zr + mpf("0.5")))

    oracle = np.array([oracle_round(int(z)) for z in grid], dtype=object)
    expected = sum(_eval_central(int(z), num, den, WAD, SCALE) != o for z, o in zip(grid, oracle))
    assert grid_miscount(num, den, WAD, SCALE, grid, oracle) == expected


def test_accuracy_stats_rates():
    s = AccuracyStats(total=1000, correct=990, within_one=1000, max_ulp=1, worst_z_raw=7, rechecks=3)
    assert s.miss == 10
    assert s.correct_rate == 0.99
    assert s.within_one_rate == 1.0


# --- fit: primitives and shape ----------------------------------------------


def test_polyder():
    # d/dz (2 + 3z + 4z^2) = 3 + 8z
    assert fit._polyder([mpf(2), mpf(3), mpf(4)]) == [mpf(3), mpf(8)]


def test_monotonicity_margin_sign():
    # R(z) = z is strictly increasing: margin (min R') > 0 for `increasing`.
    assert fit.monotonicity_margin([mpf(0), mpf(1)], [mpf(1)], mpf(1), increasing=True) > 0
    # R(z) = z - z^2 has R'(z) = 1 - 2z < 0 for z > 0.5, so it is NOT increasing
    # on [0, 1]: the worst slope is negative.
    assert fit.monotonicity_margin([mpf(0), mpf(1), mpf(-1)], [mpf(1)], mpf(1), increasing=True) < 0


def test_remez_seed_fits_and_is_monotone():
    mp.dps = 50
    max_z = mpf("3.0")
    num, den = fit.remez_seed(lambda z: ncdf(mpf(z)), max_z, deg=5)
    err, _ = fit.sup_error(num, den, lambda z: ncdf(mpf(z)), max_z, n=800)
    assert err < mpf("1e-6")  # a degree-5 minimax seed easily clears this on [0,3]
    assert fit.monotonicity_margin(num, den, max_z, increasing=True) > 0
    assert abs(num[0] - mpf("0.5")) < mpf("1e-6")  # R(0) ~ Phi(0) = 1/2


def test_irls_pin_zero_slope_flattens_the_peak():
    # An even target (here a Gaussian-like bump) fit without the pin overshoots
    # R'(0) > 0; with the pin it is driven to ~0.
    mp.dps = 40
    max_z = mpf("2.0")
    target = lambda z: mp.e ** (-(mpf(z) ** 2) / 2)
    seed = fit.remez_seed(target, max_z, deg=6)
    unpinned = fit.irls_candidates(target, max_z, 6, seed, [0.6], pin_zero_slope=False)[0]
    pinned = fit.irls_candidates(target, max_z, 6, seed, [0.6], pin_zero_slope=True)[0]

    def slope0(num, den):  # R'(0) = a1 - a0 b1
        return abs(num[1] - num[0] * den[1])

    assert slope0(pinned[1], pinned[2]) < slope0(unpinned[1], unpinned[2])
    assert slope0(pinned[1], pinned[2]) < mpf("1e-12")


# --- refit: quantization matches the emitter --------------------------------


def test_quantize_coeffs_matches_emitter():
    coeffs = [mpf("0.5"), mpf("-0.0181606598622506879226"), mpf("0.00000912918656694736")]
    got = refit.quantize_coeffs(coeffs, WAD)
    expected = [quantize(refit.coeff_str(c), WAD) for c in coeffs]
    assert got == expected
    # a negative coefficient keeps its sign; magnitude is |c| * WAD rounded
    assert got[1][1] is True and got[0][1] is False

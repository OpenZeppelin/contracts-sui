"""Exhaustive tail gates for the quantized gaussian evaluators.

Each family's `validate.py` measures error on a coarse `linspace` grid whose
points are ~10^5-10^6 raw ULPs apart. That grid cannot see two things this module
adds, both of which run in CI (`make validate`):

- `check_neighbor_monotonicity` proves the integer output never reverses direction
  between *consecutive* representable inputs across the transitioning tail - the
  1-ULP inversions that the `10^36` accumulation scale exists to eliminate. It
  scans every neighbor pair with a vectorised float64 proxy of the shipped
  rational and falls back to the exact big-integer pipeline (`shared.arithmetic`)
  only for the few pairs the proxy cannot resolve (a wrong-direction proxy step,
  or a value within `_BOUNDARY_MARGIN` of a rounding boundary). So it is
  exhaustive over the tail yet fast.

- `check_overflow_margin` proves the peak full-width `acc.mag * z.mag` product the
  Horner loop forms stays clear of `2^256` at the family's WAD, with a required
  safety headroom (the `10^36` scale leaves only ~8-10 bits, so this is
  load-bearing - a future degree bump or domain widening trips it here).
"""
from __future__ import annotations

import numpy as np
from mpmath import mp, mpf

from gaussian_codegen.shared.arithmetic import (
    SignedInt,
    horner_eval,
    horner_peak_product,
    mul_div_nearest,
)
from gaussian_codegen.shared.constants import DPS

# Float64 evaluation of the rational is accurate to a few x10^-6 ULP after
# scaling to 10^9, so a pair whose proxy value sits farther than this from a
# rounding boundary cannot flip under the exact pipeline. Comfortably above the
# float error, comfortably below the density of near-boundary points.
_BOUNDARY_MARGIN = 1e-4

# Required clearance below 2^256 for the peak Horner product. The 10^36 scale
# leaves ~8 (PDF) - 10 (CDF) bits today; this guards against silently eroding it.
MIN_HEADROOM_BITS = 4

# Largest wrong-direction slope tolerated by the continuous-monotonicity gate.
# Comfortably admits the PDF even-peak R'(0) ~ 0 (phi'(0) = 0) while catching a
# real sub-ULP bump (~10^-9). A slope this small integrates to a < 10^-5 ULP
# excursion over the whole domain - far too little to move any quantized output.
MONO_SLOPE_TOL = 1e-12


def _float_coeffs(coeffs: list[SignedInt], wad: int) -> np.ndarray:
    """Ascending-power real coefficients (signed magnitude / wad) as float64."""
    return np.array([(-m if neg else m) / wad for m, neg in coeffs], dtype=np.float64)


def _proxy_output(z: np.ndarray, num_f: np.ndarray, den_f: np.ndarray, scale: int):
    """Vectorised float64 proxy of the integer output `round(N(z)/D(z) * scale)`.

    Returns `(rounded, dist)` where `dist[i]` is the distance of the unrounded
    value to the nearest half-integer (the round-half-up flip boundary); a small
    `dist` means the proxy's rounding could disagree with the exact pipeline."""
    # np.polyval wants highest-power-first; our coefficients are ascending.
    val = (np.polyval(num_f[::-1], z) / np.polyval(den_f[::-1], z)) * scale
    frac = val - np.floor(val)
    return np.floor(val + 0.5), np.abs(frac - 0.5)


def _eval_int(z_raw: int, num, den, wad: int, scale: int) -> int:
    """Exact integer central-domain output `round(N(z)/D(z) * scale)` at the
    family WAD. No saturation or reflection - callers scan strictly inside the
    central domain, so the raw rational is what ships there."""
    z_wad: SignedInt = (z_raw * (wad // scale), False)  # 10^9 -> wad
    n = horner_eval(z_wad, num, wad)
    d = horner_eval(z_wad, den, wad)
    return mul_div_nearest(n[0], scale, d[0])


def check_neighbor_monotonicity(
    num,
    den,
    wad: int,
    scale: int,
    onset_raw: int,
    max_z_raw: int,
    increasing: bool,
    chunk: int = 5_000_000,
) -> tuple[int, int]:
    """Scan every consecutive raw pair `(k, k+1)` for `k` in `[onset_raw, max_z_raw - 1)`
    and prove the integer output is monotone (non-decreasing if `increasing`, else
    non-increasing). Returns `(pairs_scanned, exact_rechecks)`. Raises RuntimeError
    on a confirmed inversion.

    `onset_raw` starts well below the tail where the true per-step increment first
    approaches the output resolution; below it the increment dwarfs any truncation
    noise, so an inversion is impossible there."""
    num_f = _float_coeffs(num, wad)
    den_f = _float_coeffs(den, wad)
    last_k = max_z_raw - 2  # largest k with k+1 still strictly inside the central domain
    pairs = 0
    rechecks = 0
    k = onset_raw
    while k <= last_k:
        stop = min(k + chunk, last_k + 1)
        idx = np.arange(k, stop + 1, dtype=np.int64)  # values at k..stop -> pairs (k,k+1)..(stop-1,stop)
        rounded, dist = _proxy_output(idx.astype(np.float64) / scale, num_f, den_f, scale)
        step = np.diff(rounded)
        bad = step < 0 if increasing else step > 0
        ambiguous = (dist[:-1] < _BOUNDARY_MARGIN) | (dist[1:] < _BOUNDARY_MARGIN)
        for i in np.nonzero(bad | ambiguous)[0]:
            kk = int(idx[i])
            a = _eval_int(kk, num, den, wad, scale)
            b = _eval_int(kk + 1, num, den, wad, scale)
            rechecks += 1
            if (increasing and b < a) or (not increasing and b > a):
                raise RuntimeError(
                    f"neighbor monotonicity broken at z_raw={kk}->{kk + 1}: "
                    f"{a} {'>' if increasing else '<'} {b}"
                )
        pairs += stop - k
        k = stop
    return pairs, rechecks


def check_overflow_margin(
    num,
    den,
    wad: int,
    scale: int,
    max_z_raw: int,
    n: int = 100_000,
    min_headroom_bits: int = MIN_HEADROOM_BITS,
) -> tuple[int, int]:
    """Prove the peak full-width `acc.mag * z.mag` Horner product over `[0, max_z_raw]`
    clears `2^256` with at least `min_headroom_bits` to spare. The product grows
    smoothly with z (peak near `max_z_raw`), so a coarse grid plus the top input
    captures it. Returns `(peak_bits, headroom_bits)`; raises on insufficient
    headroom."""
    step = max(1, max_z_raw // n)
    peak = 0
    for z_raw in list(range(0, max_z_raw, step)) + [max_z_raw - 1]:
        z_wad: SignedInt = (z_raw * (wad // scale), False)
        p = max(horner_peak_product(z_wad, num, wad), horner_peak_product(z_wad, den, wad))
        if p > peak:
            peak = p
    bits = peak.bit_length()
    headroom = 256 - bits
    if headroom < min_headroom_bits:
        raise RuntimeError(
            f"u256 overflow margin too small: peak product is {bits} bits "
            f"(headroom {headroom} bits < required {min_headroom_bits})"
        )
    return bits, headroom


def _real_coeffs(coeffs, wad: int) -> list[mpf]:
    """Reconstruct the shipped rational's real coefficients from the quantized
    sign-magnitude pairs (magnitude / wad) as mpf."""
    return [(-mpf(m) if neg else mpf(m)) / mpf(wad) for m, neg in coeffs]


def _horner(coeffs, x: mpf) -> mpf:
    acc = mpf(0)
    for c in reversed(coeffs):
        acc = acc * x + c
    return acc


def check_continuous_monotonicity(
    num,
    den,
    wad: int,
    scale: int,
    max_z_raw: int,
    increasing: bool,
    n: int = 200_000,
    tol: float = MONO_SLOPE_TOL,
) -> mpf:
    """Prove the shipped rational `R(z) = N(z)/D(z)` (reconstructed from the
    committed quantized coefficients) is monotone in the required direction on
    the whole central domain `[0, max_z]`.

    This is the load-bearing monotonicity guarantee. At `wad = 10^36` the Horner
    floor-truncation perturbs an output by ~`10^-26` ULP - far below the smallest
    true per-step increment anywhere in the domain (~`10^-9` ULP even at the PDF
    peak) - so a continuously-monotone `R` yields a quantized output that is
    monotone across *every* adjacent representable pair, including the near-zero
    region the tail `check_neighbor_monotonicity` scan does not reach. `R'` is
    sampled on a dense grid - a verification, not an interval-arithmetic proof,
    but `R'` varies smoothly and its curvature is small wherever the slope itself
    is small (the far tail), so a between-sample sign change is not a realistic
    risk; the exact tail neighbor scan corroborates.

    Returns the worst wrong-direction slope (>= 0 means the tolerance is spent);
    raises if it exceeds `tol`. `tol` admits the even target's `R'(0) ~ 0`."""
    mp.dps = DPS
    num_r = _real_coeffs(num, wad)
    den_r = _real_coeffs(den, wad)
    dnum = [mpf(k) * num_r[k] for k in range(1, len(num_r))] or [mpf(0)]
    dden = [mpf(k) * den_r[k] for k in range(1, len(den_r))] or [mpf(0)]
    max_z = mpf(max_z_raw) / scale
    worst = mpf("-inf")  # worst wrong-direction slope
    worst_z = mpf(0)
    for i in range(n + 1):
        z = max_z * mpf(i) / n
        d = _horner(den_r, z)
        rp = (_horner(dnum, z) * d - _horner(num_r, z) * _horner(dden, z)) / (d * d)
        wrong = -rp if increasing else rp  # positive => monotonicity violated
        if wrong > worst:
            worst = wrong
            worst_z = z
    if worst > tol:
        direction = "non-decreasing" if increasing else "non-increasing"
        raise RuntimeError(
            f"continuous rational not {direction}: worst wrong-direction slope "
            f"{mp.nstr(worst, 4)} at z={mp.nstr(worst_z, 6)} exceeds tol {tol:.1e}"
        )
    return worst

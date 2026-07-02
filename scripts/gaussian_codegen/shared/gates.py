"""Exhaustive gates for the quantized gaussian evaluators.

Each family's `validate.py` measures error on a coarse `linspace` grid whose
points are ~10^5-10^6 raw ULPs apart. That grid cannot see what this module
adds, all of which runs in CI (`make validate`):

- `check_continuous_monotonicity` proves the shipped rational itself is monotone
  across the whole central domain (an R'-sign scan at 100 dps) - which at the
  `10^36` accumulation scale implies the quantized output is monotone between
  every adjacent representable pair, including the near-zero region the tail
  scan below does not reach.

- `check_neighbor_monotonicity` proves the integer output never reverses direction
  between *consecutive* representable inputs across the transitioning tail - the
  1-ULP inversions that the `10^36` accumulation scale exists to eliminate. It
  scans every neighbor pair with a vectorised float64 proxy of the shipped
  rational and falls back to the exact big-integer pipeline (`shared.arithmetic`)
  for the few pairs the proxy flags: a wrong-direction proxy step, or a value
  within `_BOUNDARY_MARGIN` of a rounding boundary. So it is exhaustive over the
  tail yet fast.

  The flagging is only *sound* if the proxy's float error stays below the margin
  (otherwise a genuine near-boundary inversion could go unflagged). Rather than
  assume that, the gate measures the proxy-vs-exact deviation at every rechecked
  pair and fails if the largest deviation reaches the margin - so the margin is
  validated by evidence, and a future fit whose tail is worse-conditioned trips
  the gate instead of silently weakening it.

- `check_overflow_margin` proves the peak full-width `acc.mag * z.mag` product the
  Horner loop forms stays clear of `2^256` at the family's WAD, with a required
  safety headroom (the `10^36` scale leaves only ~8-10 bits, so this is
  load-bearing - a future degree bump or domain widening trips it here).
"""
from __future__ import annotations

import numpy as np
from mpmath import mp, mpf

from gaussian_codegen.shared.arithmetic import SignedInt, horner_eval, horner_peak_product
from gaussian_codegen.shared.constants import DPS

# A neighbor pair whose proxy value sits within this many output ULPs of a
# rounding boundary is re-checked exactly. It must exceed the proxy's own float
# error, or a near-boundary inversion could go unflagged; the scan asserts that
# (measured `max_proxy_dev` stays below the margin), so the choice self-checks.
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


def _proxy(z: np.ndarray, num_f: np.ndarray, den_f: np.ndarray, scale: int) -> np.ndarray:
    """Vectorised float64 proxy of the unrounded output `N(z)/D(z) * scale`.
    `np.polyval` wants highest-power-first; our coefficients are ascending."""
    return (np.polyval(num_f[::-1], z) / np.polyval(den_f[::-1], z)) * scale


def _exact(z_raw: int, num, den, wad: int, scale: int) -> tuple[float, int]:
    """Exact central-domain result at the family WAD: `(unrounded ratio as float,
    half-up-rounded integer output)`.

    The ratio is formed from the big-integer Horner accumulators via `divmod`, so
    it carries full float precision at the `~scale` magnitude (Python `int / int`
    is correctly rounded) - which lets the caller measure the float proxy's error
    against ground truth. No saturation or reflection: callers scan strictly inside
    the central domain, where the raw rational is what ships."""
    z_wad: SignedInt = (z_raw * (wad // scale), False)  # 10^9 -> wad
    n_mag, n_neg = horner_eval(z_wad, num, wad)
    d_mag, d_neg = horner_eval(z_wad, den, wad)
    # Mirror the on-chain integrity aborts (N ≥ 0, D > 0): the scan visits every
    # input in its range, so a sign flip anywhere there - which would abort
    # on-chain - fails the gate even if the sparse error grid never lands on it.
    if n_neg:
        raise RuntimeError(f"N negative at z_raw={z_raw} - the on-chain evaluator would abort")
    if d_neg or d_mag == 0:
        raise RuntimeError(f"D non-positive at z_raw={z_raw} - the on-chain evaluator would abort")
    q, rem = divmod(n_mag * scale, d_mag)
    ratio = q + rem / d_mag  # exact ratio as a float, precise to ~1 output ULP
    out = q + (1 if 2 * rem >= d_mag else 0)  # half-up nearest, == mul_div_nearest for n, d > 0
    return ratio, out


def check_neighbor_monotonicity(
    num,
    den,
    wad: int,
    scale: int,
    onset_raw: int,
    max_z_raw: int,
    increasing: bool,
    chunk: int = 5_000_000,
) -> tuple[int, int, float]:
    """Scan every consecutive raw pair `(k, k+1)` for `k` in `[onset_raw, max_z_raw - 1)`
    and prove the integer output is monotone (non-decreasing if `increasing`, else
    non-increasing). Returns `(pairs_scanned, exact_rechecks, max_proxy_dev)`, where
    `max_proxy_dev` is the largest |proxy - exact| deviation (in output ULPs)
    observed at a rechecked pair.

    Raises RuntimeError on a confirmed inversion, or if `max_proxy_dev` reaches
    `_BOUNDARY_MARGIN` - which would mean the proxy could have hidden a
    near-boundary inversion, so the flagging is no longer proven exhaustive.

    `onset_raw` starts well below the tail where the true per-step increment first
    approaches the output resolution; below it the increment dwarfs any truncation
    noise, so an inversion is impossible there."""
    num_f = _float_coeffs(num, wad)
    den_f = _float_coeffs(den, wad)
    last_k = max_z_raw - 2  # largest k with k+1 still strictly inside the central domain
    pairs = 0
    rechecks = 0
    max_dev = 0.0
    # Right endpoint of the last rechecked pair. Flags cluster in consecutive runs
    # (the value crawls along a rounding boundary), so pair (k, k+1) usually
    # follows (k-1, k) and reuses its endpoint instead of recomputing ~half the evals.
    prev_right: tuple[int, float, int] | None = None
    k = onset_raw
    while k <= last_k:
        stop = min(k + chunk, last_k + 1)
        idx = np.arange(k, stop + 1, dtype=np.int64)  # values k..stop -> pairs (k,k+1)..(stop-1,stop)
        val = _proxy(idx.astype(np.float64) / scale, num_f, den_f, scale)
        rounded = np.floor(val + 0.5)
        boundary_dist = np.abs((val - np.floor(val)) - 0.5)  # distance to the half-up flip
        step = np.diff(rounded)
        bad = step < 0 if increasing else step > 0
        ambiguous = (boundary_dist[:-1] < _BOUNDARY_MARGIN) | (boundary_dist[1:] < _BOUNDARY_MARGIN)
        for i in np.nonzero(bad | ambiguous)[0]:
            kk = int(idx[i])
            if prev_right is not None and prev_right[0] == kk:
                _, ra, a = prev_right
            else:
                ra, a = _exact(kk, num, den, wad, scale)
            rb, b = _exact(kk + 1, num, den, wad, scale)
            prev_right = (kk + 1, rb, b)
            rechecks += 1
            dev = max(abs(float(val[i]) - ra), abs(float(val[i + 1]) - rb))
            if dev > max_dev:
                max_dev = dev
            if (increasing and b < a) or (not increasing and b > a):
                raise RuntimeError(
                    f"neighbor monotonicity broken at z_raw={kk}->{kk + 1}: "
                    f"{a} {'>' if increasing else '<'} {b}"
                )
        pairs += stop - k
        k = stop
    if max_dev >= _BOUNDARY_MARGIN:
        raise RuntimeError(
            f"float64 proxy deviated {max_dev:.2e} output ULP from the exact pipeline, "
            f"reaching the {_BOUNDARY_MARGIN} boundary margin: a near-boundary inversion "
            "could have gone unflagged. Widen _BOUNDARY_MARGIN (expect more re-checks)."
        )
    return pairs, rechecks, max_dev


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

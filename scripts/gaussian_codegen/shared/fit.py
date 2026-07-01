"""Rational fitting aimed at the integer pipeline that ships, not a float64
continuous rational.

Replaces the AAA objective (`shared/aaa.py`) used through PR1. Two stages, both
in mpmath at high precision so the ill-conditioned high-degree normal equations
stay accurate:

1. `remez_seed` - a minimax (equioscillation) seed for `N(z)/D(z)` via a
   linearized exchange: at `2*deg + 2` Chebyshev-spaced references we solve the
   square system `N(x) - f(x) D(x) = (-1)^i E` for the coefficients and the
   leveled error `E`, re-linearizing `D` a few times. This gives a robust,
   pole-free, near-minimax starting point (no barycentric form, no float64).

2. `irls_candidates` - a descending-`p` IRLS homotopy that walks the fit from
   `L2`/`L1` down toward the `L0` (correctly-rounded-count) objective the shipped
   function actually cares about, reweighting `w = 1/D(x)^2 * (|r| + eps)^(p-2)`.
   Each `p` step is emitted as a candidate; `<family>/derive.py` quantizes each,
   filters to the strictly-monotone ones, and selects by exact-pipeline miscount
   (`shared/accuracy.py`). The seed is also a candidate.

Everything is generic over the target `f` (an mpmath callable) and the
monotonicity direction, so `cdf` (increasing) and `pdf` (decreasing) share it.
Coefficients are ascending-power `mpf` lists normalized to `D(0) = 1`.
"""
from __future__ import annotations

from typing import Callable, Sequence

from mpmath import cos, matrix, mpf, lu_solve, pi

from gaussian_codegen.shared.aaa import horner_eval_mpf

Target = Callable[[object], object]  # mpf -> mpf


def _polyder(coeffs: Sequence[mpf]) -> list[mpf]:
    """Ascending-power derivative: d/dz sum_k c_k z^k = sum_k k c_k z^(k-1)."""
    return [mpf(k) * coeffs[k] for k in range(1, len(coeffs))] or [mpf(0)]


def _chebyshev_refs(max_z: mpf, k: int) -> list[mpf]:
    """`k` Chebyshev-extrema-spaced points on `[0, max_z]` (denser near the
    endpoints, where a minimax rational's error peaks)."""
    return [(max_z / 2) * (1 - cos(pi * mpf(i) / (k - 1))) for i in range(k)]


def remez_seed(target: Target, max_z: mpf, deg: int, inner: int = 8) -> tuple[list[mpf], list[mpf]]:
    """Minimax seed for `N/D` (both degree `deg`, `D(0)=1`) by linearized
    exchange at fixed Chebyshev references. `inner` re-linearizations of `D`."""
    k = 2 * deg + 2  # unknowns: (deg+1) num + deg den + 1 leveled error
    refs = _chebyshev_refs(max_z, k)
    fvals = [mpf(target(x)) for x in refs]
    den = [mpf(1)] + [mpf(0)] * deg  # D = 1 to start

    num: list[mpf] = [mpf(0)] * (deg + 1)
    for _ in range(inner):
        rows: list[list[mpf]] = []
        rhs: list[mpf] = []
        for i, x in enumerate(refs):
            sign = mpf(-1) ** i
            row = [x**j for j in range(deg + 1)]  # a_0..a_deg
            row += [-fvals[i] * x**kk for kk in range(1, deg + 1)]  # b_1..b_deg
            row.append(-sign * horner_eval_mpf(den, x))  # leveled error E, scaled by D
            rows.append(row)
            rhs.append(fvals[i])
        u = lu_solve(matrix(rows), matrix(rhs))
        num = [u[j] for j in range(deg + 1)]
        den = [mpf(1)] + [u[deg + 1 + j] for j in range(deg)]
    return num, den


def _solve_weighted(
    grid: Sequence[mpf],
    fvals: Sequence[mpf],
    weights: Sequence[mpf],
    deg: int,
    pin_zero_slope: tuple[mpf, mpf] | None = None,
) -> tuple[list[mpf], list[mpf]]:
    """One weighted-least-squares step of the linearized rational fit: minimize
    sum_i w_i (N(x_i) - f_i D(x_i))^2 over a_0..a_deg, b_1..b_deg (b_0=1), solved
    via the (2deg+1)x(2deg+1) normal equations. Returns (num, den).

    `pin_zero_slope`, if given as the previous iterate's `(a0, b1)`, adds a
    heavily-weighted constraint linearizing `R'(0) = a_1 - a_0 b_1 = 0` - the
    natural condition for an even target (`phi'(0) = 0`), which keeps the fit
    strictly monotone through the peak instead of overshooting into a sub-ULP
    bump at `z = 0`."""
    nunk = 2 * deg + 1
    m = [[mpf(0)] * nunk for _ in range(nunk)]
    v = [mpf(0)] * nunk
    wsum = mpf(0)
    for x, f, w in zip(grid, fvals, weights):
        wsum += w
        powers = [x**j for j in range(deg + 1)]
        row = powers + [-f * powers[kk] for kk in range(1, deg + 1)]  # length nunk
        for r in range(nunk):
            wr = w * row[r]
            v[r] += wr * f
            mr = m[r]
            for c in range(r, nunk):
                mr[c] += wr * row[c]
    for r in range(nunk):  # symmetrize
        for c in range(r):
            m[r][c] = m[c][r]
    if pin_zero_slope is not None:
        # a_1 - a_0 b_1 = 0, linearized about (a0*, b1*):
        #   a_1 - b1*·a_0 - a0*·b_1 = -a0*·b1*
        a0s, b1s = pin_zero_slope
        crow = [mpf(0)] * nunk
        crow[0] = -b1s
        crow[1] = mpf(1)
        crow[deg + 1] = -a0s
        rhs = -a0s * b1s
        cw = wsum  # scale the constraint to dominate the data normal equations
        for r in range(nunk):
            v[r] += cw * crow[r] * rhs
            for c in range(nunk):
                m[r][c] += cw * crow[r] * crow[c]
    u = lu_solve(matrix(m), matrix(v))
    num = [u[j] for j in range(deg + 1)]
    den = [mpf(1)] + [u[deg + 1 + j] for j in range(deg)]
    return num, den


def irls_candidates(
    target: Target,
    max_z: mpf,
    deg: int,
    seed: tuple[list[mpf], list[mpf]],
    p_schedule: Sequence[float],
    n_grid: int = 1500,
    eps: str = "1e-22",
    pin_zero_slope: bool = False,
) -> list[tuple[str, list[mpf], list[mpf]]]:
    """Descending-`p` IRLS homotopy seeded by `seed`. Emits one `(tag, num, den)`
    candidate per `p`. The grid is uniform on `[0, max_z]` (matching the uniform
    measure of the representable inputs the pipeline is scored on).

    `pin_zero_slope` pins `R'(0) = 0` each step (see `_solve_weighted`); set it
    for even targets (PDF) so the fit stays monotone through the peak."""
    grid = [max_z * mpf(i) / (n_grid - 1) for i in range(n_grid)]
    fvals = [mpf(target(x)) for x in grid]
    floor = mpf(eps)
    num, den = seed
    out: list[tuple[str, list[mpf], list[mpf]]] = []
    for p in p_schedule:
        weights = []
        for x, f in zip(grid, fvals):
            d = horner_eval_mpf(den, x)
            resid = horner_eval_mpf(num, x) / d - f
            weights.append((abs(resid) + floor) ** (mpf(p) - 2) / (d * d))
        pin = (num[0], den[1]) if pin_zero_slope else None
        num, den = _solve_weighted(grid, fvals, weights, deg, pin)
        out.append((f"p={p:.2f}", num, den))
    return out


def monotonicity_margin(
    num: Sequence[mpf],
    den: Sequence[mpf],
    max_z: mpf,
    increasing: bool,
    n: int = 4000,
) -> mpf:
    """Signed worst-case slope of `R(z)=N/D` on `[0, max_z]`, oriented so a
    positive result means strictly monotone in the required direction:
    `min R'` for increasing (CDF), `min (-R')` for decreasing (PDF). A
    non-positive return means the continuous rational is not monotone and the
    candidate must be rejected (the on-chain neighbor-monotonicity gate would
    fail)."""
    nd = _polyder(list(num))
    dd = _polyder(list(den))
    worst = None
    for i in range(n + 1):
        x = max_z * mpf(i) / n
        d = horner_eval_mpf(den, x)
        rp = (horner_eval_mpf(nd, x) * d - horner_eval_mpf(num, x) * horner_eval_mpf(dd, x)) / (d * d)
        signed = rp if increasing else -rp
        if worst is None or signed < worst:
            worst = signed
    return worst


def sup_error(num: Sequence[mpf], den: Sequence[mpf], target: Target, max_z: mpf, n: int = 4000) -> tuple[mpf, mpf]:
    """Worst-case |R(z) - f(z)| on a uniform grid, and where it occurs. Reported
    as the continuous fit's max error (informational; the shipped metric is the
    exact-pipeline correctly-rounded count)."""
    worst = mpf(0)
    worst_z = mpf(0)
    for i in range(n + 1):
        x = max_z * mpf(i) / n
        e = abs(horner_eval_mpf(num, x) / horner_eval_mpf(den, x) - mpf(target(x)))
        if e > worst:
            worst = e
            worst_z = x
    return worst, worst_z

"""AAA barycentric → explicit polynomial conversion and high-precision evaluation.

Function-agnostic primitives shared by every gaussian function family (`cdf`,
`pdf`, `inverse_cdf`): each family's `derive.py` fits with `scipy.interpolate.AAA`,
converts the barycentric form to explicit `N(z) / D(z)` polynomials here, and
measures error with `evaluate_rational`.
"""
from __future__ import annotations

from typing import Sequence

from mpmath import mp, mpf

from gaussian_codegen.shared.constants import DPS


def aaa_to_rational_polys(aaa_obj) -> tuple[list[mpf], list[mpf]]:
    """Convert a scipy AAA barycentric form into explicit polynomials N(z), D(z)
    with coefficients in *ascending power order*. Both polynomials have degree
    `m - 1` where `m = len(support_points)`.

    The transformation is:

        N(z) = Σ_j w_j y_j Π_{k≠j} (z − z_k)
        D(z) = Σ_j w_j Π_{k≠j} (z − z_k)

    Then we rescale by D(0) so that the constant term of D is exactly 1.
    """
    mp.dps = DPS
    sp = [mpf(float(z)) for z in aaa_obj.support_points]
    sv = [mpf(float(y)) for y in aaa_obj.support_values]
    w = [mpf(float(wj)) for wj in aaa_obj.weights]
    m = len(sp)

    num: list[mpf] = [mpf(0)] * m
    den: list[mpf] = [mpf(0)] * m

    for j in range(m):
        # build Π_{k≠j} (z − z_k) as ascending-order coefficients
        prod: list[mpf] = [mpf(1)]
        for k in range(m):
            if k == j:
                continue
            scaled: list[mpf] = [mpf(0)] * (len(prod) + 1)
            for i, c in enumerate(prod):
                scaled[i] += c * (-sp[k])
                scaled[i + 1] += c
            prod = scaled
        for i in range(m):
            num[i] += w[j] * sv[j] * prod[i]
            den[i] += w[j] * prod[i]

    d0 = den[0]
    if d0 == 0:
        raise RuntimeError("AAA produced a denominator with zero constant term - cannot normalize")
    num = [c / d0 for c in num]
    den = [c / d0 for c in den]
    return num, den


def horner_eval_mpf(coeffs: Sequence[mpf], z) -> mpf:
    """Evaluate a polynomial in ascending-power coefficients via Horner."""
    z_mpf = mpf(z)
    acc = mpf(0)
    for c in reversed(list(coeffs)):
        acc = acc * z_mpf + c
    return acc


def evaluate_rational(num: Sequence[mpf], den: Sequence[mpf], z) -> mpf:
    return horner_eval_mpf(num, z) / horner_eval_mpf(den, z)

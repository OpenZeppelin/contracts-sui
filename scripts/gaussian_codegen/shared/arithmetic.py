"""Sign-magnitude integer arithmetic mirroring the on-chain Move evaluator.

The single Python source of truth for re-running the on-chain gaussian integer
arithmetic offline. Mirrors `math/fixed_point/sources/internal/horner.move`
exactly — floor-division `mul_wad`, sign-magnitude `add`, canonical zero — plus
the `u256::mul_div(..., Nearest)` half-up rounding (from `math/core`) used for
each family's final ratio. Every `<family>/validate.py` re-runs through these, so
one tested copy stays in lock-step with the Move primitives.
"""
from __future__ import annotations

from gaussian_codegen.shared import constants

WAD = constants.WAD
U256_MAX = 2**256 - 1  # on-chain Move intermediates must fit u256

SignedInt = tuple[int, bool]  # (magnitude, is_negative)


def _canonicalize(sm: SignedInt) -> SignedInt:
    """Zero is always (0, False)."""
    return (0, False) if sm[0] == 0 else sm


def add(a: SignedInt, b: SignedInt) -> SignedInt:
    am, an = a
    bm, bn = b
    if am == 0:
        return _canonicalize(b)
    if bm == 0:
        return _canonicalize(a)
    if an == bn:
        s = am + bm
        if s > U256_MAX:
            raise RuntimeError(f"u256 overflow in add: {am} + {bm}")
        return (s, an)
    if am > bm:
        return (am - bm, an)
    if bm > am:
        return (bm - am, bn)
    return (0, False)  # exact cancellation


def mul_wad(a: SignedInt, b: SignedInt) -> SignedInt:
    """`(a * b) / WAD` with floor-division on magnitudes (== mul_div with Down rounding)."""
    am, an = a
    bm, bn = b
    prod = am * bm
    if prod > U256_MAX:
        raise RuntimeError(f"u256 overflow in mul_wad: {am} * {bm}")
    mag = prod // WAD
    return _canonicalize((mag, an ^ bn))


def horner_eval(z: SignedInt, coeffs: list[SignedInt]) -> SignedInt:
    if not coeffs:
        raise RuntimeError("empty polynomial")
    acc = _canonicalize(coeffs[-1])
    for c in reversed(coeffs[:-1]):
        acc = mul_wad(acc, z)
        acc = add(acc, c)
    return acc


def mul_div_nearest(a: int, b: int, d: int) -> int:
    """`(a * b) / d` rounded half-up (ties away from zero), mirroring the
    on-chain `u256::mul_div(..., Nearest)` from `math/core` (round up iff
    `rem >= d - rem`). Caller guarantees `d > 0`."""
    prod = a * b
    if prod > U256_MAX:
        raise RuntimeError(f"u256 overflow in mul_div_nearest: {a} * {b}")
    quot = prod // d
    rem = prod - quot * d
    return quot + 1 if rem >= d - rem else quot

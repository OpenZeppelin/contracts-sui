"""Sign-magnitude integer arithmetic mirroring the on-chain Move evaluator.

The single Python source of truth for re-running the on-chain gaussian integer
arithmetic offline. Mirrors `math/fixed_point/sources/internal/horner.move`
exactly - floor-division `mul_wad`, sign-magnitude `add`, canonical zero - plus
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


def mul_wad(a: SignedInt, b: SignedInt, wad: int = WAD) -> SignedInt:
    """`(a * b) / wad` with floor-division on magnitudes (== mul_div with Down
    rounding). `wad` is the accumulation scale (default the generic `10^18`; the
    CDF and PDF families pass `10^36`), mirroring the per-call `wad` parameter on
    the Move `horner::mul_wad`."""
    am, an = a
    bm, bn = b
    prod = am * bm
    if prod > U256_MAX:
        raise RuntimeError(f"u256 overflow in mul_wad: {am} * {bm}")
    mag = prod // wad
    return _canonicalize((mag, an ^ bn))


def horner_eval(z: SignedInt, coeffs: list[SignedInt], wad: int = WAD) -> SignedInt:
    if not coeffs:
        raise RuntimeError("empty polynomial")
    acc = _canonicalize(coeffs[-1])
    for c in reversed(coeffs[:-1]):
        acc = mul_wad(acc, z, wad)
        acc = add(acc, c)
    return acc


def horner_peak_product(z: SignedInt, coeffs: list[SignedInt], wad: int) -> int:
    """Largest full-width magnitude product `acc.mag * z.mag` fed into a `// wad`
    step over one Horner evaluation - i.e. the peak `u256` intermediate the
    on-chain evaluator must hold. Used by `validate.check_overflow_margin` to prove
    the accumulation stays clear of `2^256` at the chosen `wad`."""
    if not coeffs:
        raise RuntimeError("empty polynomial")
    acc = _canonicalize(coeffs[-1])
    peak = 0
    for c in reversed(coeffs[:-1]):
        prod = acc[0] * z[0]
        if prod > peak:
            peak = prod
        acc = _canonicalize((prod // wad, acc[1] ^ z[1]))
        acc = add(acc, c)
    return peak


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

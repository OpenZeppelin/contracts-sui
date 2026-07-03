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


# --- Logarithm / square-root kernels (for inverse_cdf's tail transform) ---------
#
# These mirror the on-chain `common::raw_log2` + `common::apply_log2_factor`
# (`math/fixed_point/sources/internal/common.move`) and `u256::sqrt(..., Down)`
# (`math/core`) so `inverse_cdf/validate.py` can re-run the tail change of
# variable `r = sqrt(-2 * ln(1 - p))` in Python integer arithmetic, exactly as
# the Move `inverse_cdf::tail_variable_raw` does.

SCALE = constants.SCALE_DECIMAL  # 10^9
INTERNAL_LOG_SCALE = 10**18
LN2_E18 = 693_147_180_559_945_309  # floor(ln(2) * 10^18), == common::ln2_e18!()
LOG_FACTOR_DENOM_E27 = 10**27


def raw_log2(x_raw: int) -> tuple[bool, int]:
    """Mirror `common::raw_log2`: base-2 log of `x_raw / 10^9` as
    `(is_negative, magnitude_at_1e18)`. `x_raw` must be strictly positive."""
    if x_raw <= 0:
        raise RuntimeError("raw_log2 of non-positive value")
    scale = SCALE
    internal = INTERNAL_LOG_SCALE
    if x_raw >= scale:
        n = (x_raw // scale).bit_length() - 1  # floor(log2(floor(x_raw/scale)))
        neg = False
        n_abs = n
        y_at_scale = x_raw >> n
    else:
        # msb(v) == v.bit_length() - 1
        shift = (scale.bit_length() - 1) - (x_raw.bit_length() - 1)
        shifted = x_raw << shift
        if shifted < scale:
            shift += 1
            shifted <<= 1
        neg = True
        n_abs = shift
        y_at_scale = shifted

    y = y_at_scale * scale
    internal_x2 = 2 * internal
    frac = 0
    delta = internal // 2
    while delta > 0:
        y = y * y // internal
        if y >= internal_x2:
            frac += delta
            y >>= 1
        delta >>= 1

    n_x_internal = n_abs * internal
    magnitude = (n_x_internal - frac) if neg else (n_x_internal + frac)
    return neg, magnitude


def apply_log2_factor(log2_mag_e18: int, factor_e18: int = LN2_E18) -> int:
    """Mirror `common::apply_log2_factor`: `floor(log2_mag_e18 * factor_e18 / 10^27)`
    at the `10^9` scale (Down rounding). Default factor converts `log2` to `ln`."""
    return (log2_mag_e18 * factor_e18) // LOG_FACTOR_DENOM_E27


def isqrt_scaled(value_raw: int) -> int:
    """Mirror `ud30x9_base::sqrt` / `u256::sqrt(value_raw * 10^9, Down)`: the
    square root of a `10^9`-scaled value, returned at the `10^9` scale, truncated
    down. Python's `math.isqrt` is exact floor-sqrt, matching `Down`."""
    from math import isqrt

    return isqrt(value_raw * SCALE)


def tail_r_raw(p_raw: int) -> int:
    """On-chain tail variable `r = sqrt(-2 * ln(1 - p))` at the `10^9` scale,
    mirroring `inverse_cdf::tail_variable_raw`. `p_raw` is `p` at `10^9` scale
    with `0 < p < 1`.

    Bit-for-bit fidelity to the Move kernel is asserted by the Move test
    `sd29x9_inverse_cdf_tests::tail_transform_matches_offline_mirror`, so this
    mirror is a faithful stand-in for the on-chain path in `validate.py`."""
    complement_raw = SCALE - p_raw  # 1 - p at 10^9, exact
    _, log2_mag = raw_log2(complement_raw)  # |log2(1 - p)| at 1e18 (1-p < 1)
    ln_mag_raw = apply_log2_factor(log2_mag, LN2_E18)  # |ln(1 - p)| at 1e9
    arg_raw = 2 * ln_mag_raw  # -2 * ln(1 - p) at 1e9
    return isqrt_scaled(arg_raw)

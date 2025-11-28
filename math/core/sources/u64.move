module openzeppelin_math::u64;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::RoundingMode;

const BIT_WIDTH: u8 = 64;

/// Compute the arithmetic mean of two `u64` values with configurable rounding.
public fun average(a: u64, b: u64, rounding_mode: RoundingMode): u64 {
    macros::average!(a, b, rounding_mode)
}

/// Shift the value left by the given number of bits.
///
/// Returns `None` for the following cases:
/// - the shift consumes a non-zero bit when shifting left.
public fun checked_shl(value: u64, shift: u8): Option<u64> {
    if (value == 0) {
        option::some(0)
    } else if (shift >= BIT_WIDTH) {
        option::none()
    } else {
        macros::checked_shl!(value, shift)
    }
}

/// Shift the value right by the given number of bits.
///
/// Returns `None` for the following cases:
/// - the shift consumes a non-zero bit when shifting right.
public fun checked_shr(value: u64, shift: u8): Option<u64> {
    if (value == 0) {
        option::some(0)
    } else if (shift >= BIT_WIDTH) {
        option::none()
    } else {
        macros::checked_shr!(value, shift)
    }
}

/// Multiply `a` and `b`, divide by `denominator`, and round according to `rounding_mode`.
///
/// Returns `None` for the following cases:
/// - the rounded quotient cannot be represented as `u64`
public fun mul_div(a: u64, b: u64, denominator: u64, rounding_mode: RoundingMode): Option<u64> {
    let (_, result) = macros::mul_div!(a, b, denominator, rounding_mode);
    result.try_as_u64()
}

/// Multiply `a` and `b`, shift the product right by `shift`, and round according to `rounding_mode`.
///
/// Returns `None` for the following cases:
/// - the rounded quotient cannot be represented as `u64`
public fun mul_shr(a: u64, b: u64, shift: u8, rounding_mode: RoundingMode): Option<u64> {
    let (_, result) = macros::mul_shr!(a, b, shift, rounding_mode);
    result.try_as_u64()
}

/// Count the number of leading zero bits in the value.
public fun clz(value: u64): u8 {
    macros::clz!(value, BIT_WIDTH as u16) as u8
}

/// Return the position of the most significant bit in the value.
///
/// Returns 0 if given 0.
public fun msb(value: u64): u8 {
    macros::msb!(value, BIT_WIDTH as u16)
}

/// Compute the log in base 2 of a positive value with configurable rounding.
///
/// Returns 0 if given 0.
public fun log2(value: u64, rounding_mode: RoundingMode): u8 {
    macros::log2!(value, BIT_WIDTH as u16, rounding_mode) as u8
}

/// Compute the log in base 256 of a positive value with configurable rounding.
///
/// Returns 0 if given 0.
public fun log256(value: u64, rounding_mode: RoundingMode): u8 {
    macros::log256!(value, BIT_WIDTH as u16, rounding_mode)
}

/// Compute the log in base 10 of a positive value with configurable rounding.
///
/// Returns 0 if given 0.
public fun log10(value: u64, rounding_mode: RoundingMode): u8 {
    macros::log10!(value, rounding_mode)
}

/// Compute the square root of a value with configurable rounding.
///
/// Returns 0 if given 0.
public fun sqrt(value: u64, rounding_mode: RoundingMode): u64 {
    macros::sqrt!(value, rounding_mode)
}

/// Compute the modular multiplicative inverse of `value` in `Z / modulus`.
///
/// If `value` and `modulus` are co-prime, returns the unique element `x` such that
/// `value * x ≡ 1 (mod modulus)`. Otherwise returns `None`. Aborts for a zero modulus.
public fun inv_mod(value: u64, modulus: u64): Option<u64> {
    macros::inv_mod!(value, modulus)
}

/// Multiply `a` and `b` modulo `modulus`. Aborts if `modulus` is zero.
public fun mul_mod(a: u64, b: u64, modulus: u64): u64 {
    macros::mul_mod!(a, b, modulus)
}

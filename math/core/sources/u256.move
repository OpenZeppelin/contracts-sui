module openzeppelin_math::u256;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::RoundingMode;

/// Compute the arithmetic mean of two `u256` values with configurable rounding.
public fun average(a: u256, b: u256, rounding_mode: RoundingMode): u256 {
    macros::average!(a, b, rounding_mode)
}

/// Shift the value left by the given number of bits.
///
/// Returns `None` for the following cases:
/// - the shift consumes a non-zero bit when shifting left.
public fun checked_shl(value: u256, shift: u8): Option<u256> {
    macros::checked_shl!(value, shift)
}

/// Shift the value right by the given number of bits.
///
/// Returns `None` for the following cases:
/// - the shift consumes a non-zero bit when shifting right.
public fun checked_shr(value: u256, shift: u8): Option<u256> {
    macros::checked_shr!(value, shift)
}

/// Multiply `a` and `b`, divide by `denominator`, and round according to `rounding_mode`.
/// Returns `(overflow, result)` where `overflow` signals that the rounded quotient cannot be
/// represented as `u256`.
public fun mul_div(a: u256, b: u256, denominator: u256, rounding_mode: RoundingMode): (bool, u256) {
    macros::mul_div!(a, b, denominator, rounding_mode)
}

/// Multiply `a` and `b`, shift the product right by `shift`, and round according to `rounding_mode`.
///
/// Returns None for the following cases:
/// - the rounded quotient cannot be represented as `u256`
public fun mul_shr(a: u256, b: u256, shift: u8, rounding_mode: RoundingMode): Option<u256> {
    let (overflow, result) = macros::mul_shr!(a, b, shift, rounding_mode);

    if (overflow) {
        option::none()
    } else {
        option::some(result)
    }
}

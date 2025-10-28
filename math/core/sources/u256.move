module openzeppelin_math::u256;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::RoundingMode;

/// Multiply `a` and `b`, divide by `denominator`, and round according to `rounding_mode`.
/// Returns `(overflow, result)` where `overflow` signals that the rounded quotient cannot be
/// represented as `u256`.
public fun mul_div(a: u256, b: u256, denominator: u256, rounding_mode: RoundingMode): (bool, u256) {
    macros::mul_div!(a, b, denominator, rounding_mode)
}

/// Shift the value right by the given number of bits.
/// Returns `None` if the shift consumes a non-zero bit.
public fun checked_shr(value: u256, shift: u8): Option<u256> {
    macros::checked_shr!(value, shift)
}

/// Shift the value left by the given number of bits.
/// Returns `None` if the shift consumes a non-zero bit.
public fun checked_shl(value: u256, shift: u8): Option<u256> {
    macros::checked_shl!(value, shift)
}

module openzeppelin_math::u256;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::RoundingMode;

const BIT_WIDTH: u16 = 256;

/// Compute the arithmetic mean of two `u256` values with configurable rounding.
public fun average(a: u256, b: u256, rounding_mode: RoundingMode): u256 {
    macros::average!(a, b, rounding_mode)
}

/// Shift the value left by the given number of bits.
///
/// Returns `None` for the following cases:
/// - the shift consumes a non-zero bit when shifting left.
public fun checked_shl(value: u256, shift: u8): Option<u256> {
    if (value == 0) {
        option::some(0)
    } else {
        macros::checked_shl!(value, shift)
    }
}

/// Shift the value right by the given number of bits.
///
/// Returns `None` for the following cases:
/// - the shift consumes a non-zero bit when shifting right.
public fun checked_shr(value: u256, shift: u8): Option<u256> {
    if (value == 0) {
        option::some(0)
    } else {
        macros::checked_shr!(value, shift)
    }
}

/// Multiply `a` and `b`, divide by `denominator`, and round according to `rounding_mode`.
/// Returns `(overflow, result)` where `overflow` signals that the rounded quotient cannot be
/// represented as `u256`.
public fun mul_div(a: u256, b: u256, denominator: u256, rounding_mode: RoundingMode): (bool, u256) {
    macros::mul_div!(a, b, denominator, rounding_mode)
}

/// Count the number of leading zero bits in the value.
/// Returns the full bit width (256) if the value is 0.
public fun clz(value: u256): u16 {
    macros::clz!(value, BIT_WIDTH)
}

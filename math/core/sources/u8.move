module openzeppelin_math::u8;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::RoundingMode;
use std::u256::try_as_u8;

const BIT_WIDTH: u8 = 8;

/// Compute the arithmetic mean of two `u8` values with configurable rounding.
public fun average(a: u8, b: u8, rounding_mode: RoundingMode): u8 {
    macros::average!(a, b, rounding_mode)
}

/// Shift the value left by the given number of bits.
///
/// Returns `None` for the following cases:
/// - the shift consumes a non-zero bit when shifting left.
public fun checked_shl(value: u8, shift: u8): Option<u8> {
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
public fun checked_shr(value: u8, shift: u8): Option<u8> {
    if (value == 0) {
        option::some(0)
    } else if (shift >= BIT_WIDTH) {
        option::none()
    } else {
        macros::checked_shr!(value, shift)
    }
}

/// Multiply `a` and `b`, divide by `denominator`, and round according to `rounding_mode`.
/// Returns `(overflow, result)` where `overflow` signals that the rounded quotient cannot be
/// represented as `u8`.
public fun mul_div(a: u8, b: u8, denominator: u8, rounding_mode: RoundingMode): (bool, u8) {
    let (_, result) = macros::mul_div!(a, b, denominator, rounding_mode);

    // Check if the result fits in u8
    if (result > (std::u8::max_value!() as u256)) {
        (true, 0)
    } else {
        (false, result as u8)
    }
}

/// Multiply `a` and `b`, shift the product right by `shift`, and round according to `rounding_mode`.
///
/// Returns None for the following cases:
/// - the rounded quotient cannot be represented as `u8`
public fun mul_shr(a: u8, b: u8, shift: u8, rounding_mode: RoundingMode): Option<u8> {
    let (_, result) = macros::mul_shr!(a, b, shift, rounding_mode);
    result.try_as_u8()
}

/// Count the number of leading zero bits in the value.
public fun clz(value: u8): u8 {
    macros::clz!(value, BIT_WIDTH as u16) as u8
}

/// Compute the log in base 2 of a positive value rounded towards zero.
///
/// Returns 0 if given 0.
public fun log2(value: u8): u8 {
    macros::log2!(value, BIT_WIDTH as u16)
}

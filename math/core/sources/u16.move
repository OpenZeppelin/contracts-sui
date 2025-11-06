module openzeppelin_math::u16;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::RoundingMode;

/// Compute the arithmetic mean of two `u16` values with configurable rounding.
public fun average(a: u16, b: u16, rounding_mode: RoundingMode): u16 {
    macros::average!(a, b, rounding_mode)
}

/// Shift the value left by the given number of bits.
///
/// Returns `None` for the following cases:
/// - the shift consumes a non-zero bit when shifting left.
public fun checked_shl(value: u16, shift: u8): Option<u16> {
    if (value == 0) {
        option::some(0)
    } else if (shift >= 16) {
        option::none()
    } else {
        macros::checked_shl!(value, shift)
    }
}

/// Shift the value right by the given number of bits.
///
/// Returns `None` for the following cases:
/// - the shift consumes a non-zero bit when shifting right.
public fun checked_shr(value: u16, shift: u8): Option<u16> {
    if (value == 0) {
        option::some(0)
    } else if (shift >= 16) {
        option::none()
    } else {
        macros::checked_shr!(value, shift)
    }
}

/// Multiply `a` and `b`, divide by `denominator`, and round according to `rounding_mode`.
/// Returns `(overflow, result)` where `overflow` signals that the rounded quotient cannot be
/// represented as `u16`.
public fun mul_div(a: u16, b: u16, denominator: u16, rounding_mode: RoundingMode): (bool, u16) {
    let (_, result) = macros::mul_div!(a, b, denominator, rounding_mode);

    // Check if the result fits in u16
    if (result > (std::u16::max_value!() as u256)) {
        (true, 0)
    } else {
        (false, result as u16)
    }
}

/// Multiply `a` and `b`, shift the product right by `shift`, and round according to `rounding_mode`.
///
/// Returns None for the following cases:
/// - the rounded quotient cannot be represented as `u16`
public fun mul_shr(a: u16, b: u16, shift: u8, rounding_mode: RoundingMode): Option<u16> {
    let (_, result) = macros::mul_shr!(a, b, shift, rounding_mode);
    result.try_as_u16()
}

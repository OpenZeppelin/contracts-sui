module openzeppelin_math::u32;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::RoundingMode;

/// Compute the arithmetic mean of two `u32` values with configurable rounding.
public fun average(a: u32, b: u32, rounding_mode: RoundingMode): u32 {
    macros::average!(a, b, rounding_mode)
}

/// Shift the value left by the given number of bits.
///
/// Returns `None` for the following cases:
/// - the shift is greater than or equal to 32 bits.
/// - the shift consumes a non-zero bit when shifting left.
public fun checked_shl(value: u32, shift: u8): Option<u32> {
    if (shift >= 32) {
        return option::none()
    };
    macros::checked_shl!(value, shift)
}

/// Shift the value right by the given number of bits.
///
/// Returns `None` for the following cases:
/// - the shift is greater than or equal to 32 bits.
/// - the shift consumes a non-zero bit when shifting right.
public fun checked_shr(value: u32, shift: u8): Option<u32> {
    if (shift >= 32) {
        return option::none()
    };
    macros::checked_shr!(value, shift)
}

/// Multiply `a` and `b`, divide by `denominator`, and round according to `rounding_mode`.
/// Returns `(overflow, result)` where `overflow` signals that the rounded quotient cannot be
/// represented as `u32`.
public fun mul_div(a: u32, b: u32, denominator: u32, rounding_mode: RoundingMode): (bool, u32) {
    let (_, result) = macros::mul_div!(a, b, denominator, rounding_mode);

    // Check if the result fits in u32
    if (result > (std::u32::max_value!() as u256)) {
        (true, 0)
    } else {
        (false, result as u32)
    }
}

/// Multiply `a` and `b`, shift the product right by `shift`, and round according to `rounding_mode`.
///
/// Returns None for the following cases:
/// - the rounded quotient cannot be represented as `u32`
public fun mul_shr(a: u32, b: u32, shift: u8, rounding_mode: RoundingMode): Option<u32> {
    let (_, result) = macros::mul_shr!(a, b, shift, rounding_mode);
    result.try_as_u32()
}

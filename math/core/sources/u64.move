module openzeppelin_math::u64;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::RoundingMode;

/// Multiply `a` and `b`, divide by `denominator`, and round according to `rounding_mode`.
/// Returns `(overflow, result)` where `overflow` signals that the rounded quotient cannot be
/// represented as `u64`.
public fun mul_div(a: u64, b: u64, denominator: u64, rounding_mode: RoundingMode): (bool, u64) {
    let (_, result) = macros::mul_div!(a, b, denominator, rounding_mode);

    // Check if the result fits in u64
    if (result > (std::u64::max_value!() as u256)) {
        (true, 0)
    } else {
        (false, result as u64)
    }
}

/// Shift the value right by the given number of bits.
///
/// Returns `None` for the following cases:
/// - the shift is greater than or equal to 64 bits.
/// - the shift consumes a non-zero bit when shifting right.
public fun checked_shr(value: u64, shift: u8): Option<u64> {
    if (shift >= 64) {
        return option::none()
    };
    macros::checked_shr!(value, shift)
}

/// Shift the value left by the given number of bits.
///
/// Returns `None` for the following cases:
/// - the shift is greater than or equal to 64 bits.
/// - the shift consumes a non-zero bit when shifting left.
public fun checked_shl(value: u64, shift: u8): Option<u64> {
    if (shift >= 64) {
        return option::none()
    };
    macros::checked_shl!(value, shift)
}

/// Compute the arithmetic mean of two `u64` values with configurable rounding.
public fun average(a: u64, b: u64, rounding_mode: RoundingMode): u64 {
    macros::average!(a, b, rounding_mode)
}

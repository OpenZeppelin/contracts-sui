module openzeppelin_math::u8;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::RoundingMode;

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

/// Shift the value right by the given number of bits.
/// Returns `None` if the shift consumes a non-zero bit.
public fun checked_shr(value: u8, shift: u8): Option<u8> {
    if (shift >= 8) {
        return option::none()
    };
    macros::checked_shr!(value, shift)
}

/// Shift the value left by the given number of bits.
/// Returns `None` if the shift consumes a non-zero bit.
public fun checked_shl(value: u8, shift: u8): Option<u8> {
    if (shift >= 8) {
        return option::none()
    };
    macros::checked_shl!(value, shift)
}

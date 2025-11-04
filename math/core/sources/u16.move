module openzeppelin_math::u16;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::RoundingMode;

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

/// Shift the value right by the given number of bits.
///
/// Returns `None` for the following cases:
/// - the shift is greater than or equal to 16 bits.
/// - the shift consumes a non-zero bit when shifting right.
public fun checked_shr(value: u16, shift: u8): Option<u16> {
    if (shift >= 16) {
        return option::none()
    };
    macros::checked_shr!(value, shift)
}

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

/// Compute the arithmetic mean of two `u16` values with configurable rounding.
public fun average(a: u16, b: u16, rounding_mode: RoundingMode): u16 {
    macros::average!(a, b, rounding_mode)
}

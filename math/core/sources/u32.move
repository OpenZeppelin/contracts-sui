module openzeppelin_math::u32;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::RoundingMode;

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

/// Compute the arithmetic mean of two `u32` values with configurable rounding.
public fun average(a: u32, b: u32, rounding_mode: RoundingMode): u32 {
    macros::average!(a, b, rounding_mode)
}

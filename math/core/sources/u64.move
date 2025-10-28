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

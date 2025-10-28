module openzeppelin_math::u128;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::RoundingMode;

/// Multiply `a` and `b`, divide by `denominator`, and round according to `rounding_mode`.
/// Returns `(overflow, result)` where `overflow` signals that the rounded quotient cannot be
/// represented as `u128`.
public fun mul_div(
    a: u128,
    b: u128,
    denominator: u128,
    rounding_mode: RoundingMode,
): (bool, u128) {
    let (_, result) = macros::mul_div!(a, b, denominator, rounding_mode);

    // Check if the result fits in u128
    if (result > (std::u128::max_value!() as u256)) {
        (true, 0)
    } else {
        (false, result as u128)
    }
}

module openzeppelin_math::u256;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::RoundingMode;

/// Multiply `a` and `b`, divide by `denominator`, and round according to `rounding_mode`.
public fun mul_div(a: u256, b: u256, denominator: u256, rounding_mode: RoundingMode): u256 {
    macros::mul_div!(a, b, denominator, rounding_mode)
}

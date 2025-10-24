module openzeppelin_math::u64;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::RoundingMode;

#[error(code = 0)]
const EArithmeticOverflow: vector<u8> = b"Result does not fit in the u64 type";

/// Multiply `a` and `b`, divide by `denominator`, and round according to `rounding_mode`.
public fun mul_div(a: u64, b: u64, denominator: u64, rounding_mode: RoundingMode): u64 {
    let result = macros::mul_div!(a, b, denominator, rounding_mode);
    assert!(result <= std::u64::max_value!() as u256, EArithmeticOverflow);
    result as u64
}

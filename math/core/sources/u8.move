module openzeppelin_math::u8;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::RoundingMode;

#[error(code = 0)]
const EArithmeticOverflow: vector<u8> = b"Result does not fit in the u8 type";

/// Multiply `a` and `b`, divide by `denominator`, and round according to `rounding_mode`.
public fun mul_div(a: u8, b: u8, denominator: u8, rounding_mode: RoundingMode): u8 {
    let result = macros::mul_div!(a, b, denominator, rounding_mode);
    assert!(result <= std::u8::max_value!() as u256, EArithmeticOverflow);
    result as u8
}

module openzeppelin_math::u128;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::RoundingMode;

#[error(code = 0)]
const EArithmeticOverflow: vector<u8> = b"Result does not fit in the u128 type";

public fun mul_div(a: u128, b: u128, denominator: u128, rounding_mode: RoundingMode): u128 {
    let result = macros::mul_div!(a, b, denominator, rounding_mode);
    assert!(result <= std::u128::max_value!() as u256, EArithmeticOverflow);
    result as u128
}

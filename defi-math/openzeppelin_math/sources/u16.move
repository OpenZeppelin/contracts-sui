module openzeppelin_math::u16;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::RoundingMode;

#[error(code = 0)]
const EArithmeticOverflow: vector<u8> = b"Result does not fit in the u16 type";

public fun mul_div(a: u16, b: u16, denominator: u16, rounding_mode: RoundingMode): u16 {
    let result = macros::mul_div!(a, b, denominator, rounding_mode);
    assert!(result <= std::u16::max_value!() as u256, EArithmeticOverflow);
    result as u16
}

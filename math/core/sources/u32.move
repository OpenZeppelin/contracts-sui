module openzeppelin_math::u32;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::RoundingMode;

#[error(code = 0)]
const EArithmeticOverflow: vector<u8> = b"Result does not fit in the u32 type";

public fun mul_div(a: u32, b: u32, denominator: u32, rounding_mode: RoundingMode): u32 {
    let result = macros::mul_div!(a, b, denominator, rounding_mode);
    assert!(result <= std::u32::max_value!() as u256, EArithmeticOverflow);
    result as u32
}

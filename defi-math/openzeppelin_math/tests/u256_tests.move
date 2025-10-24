module openzeppelin_math::u256_tests;

use openzeppelin_math::macros;
use openzeppelin_math::rounding;
use openzeppelin_math::u256;
use std::unit_test::assert_eq;

// At the top level, the wrapper should mirror the macro’s behaviour.
#[test]
fun rounding_modes() {
    let down = u256::mul_div(70, 10, 4, rounding::down());
    assert_eq!(down, 175);

    let up = u256::mul_div(5, 3, 4, rounding::up());
    assert_eq!(up, 4);

    let nearest = u256::mul_div(7, 10, 4, rounding::nearest());
    assert_eq!(nearest, 18);
}

// Verify the wrapper delegates to the wide path when required.
#[test]
fun handles_wide_operands() {
    let large = (std::u128::max_value!() as u256) + 1;
    let result = u256::mul_div(large, large, 7, rounding::down());
    let expected = macros::mul_div_u256_wide(large, large, 7, rounding::down());
    assert_eq!(result, expected);
}

// Division-by-zero guard enforced at the macro layer.
#[test, expected_failure(abort_code = macros::EDivideByZero)]
fun rejects_zero_denominator() {
    u256::mul_div(1, 1, 0, rounding::down());
}

// Even u256 should fail when the macro’s output overflows 256 bits.
#[test, expected_failure(abort_code = macros::EArithmeticOverflow)]
fun detects_overflow() {
    let max = std::u256::max_value!();
    u256::mul_div(max, max, 1, rounding::down());
}

module openzeppelin_math::u64_tests;

use openzeppelin_math::macros;
use openzeppelin_math::rounding;
use openzeppelin_math::u64;
use std::unit_test::assert_eq;

// Larger inputs continue to follow the same rounding contract.
#[test]
fun rounding_modes() {
    let down = u64::mul_div(70, 10, 4, rounding::down());
    assert_eq!(down, 175);

    let up = u64::mul_div(5, 3, 4, rounding::up());
    assert_eq!(up, 4);

    let nearest = u64::mul_div(7, 10, 4, rounding::nearest());
    assert_eq!(nearest, 18);
}

// Perfect division should remain unaffected by rounding mode choice.
#[test]
fun exact_division() {
    let exact = u64::mul_div(8_000, 2, 4, rounding::up());
    assert_eq!(exact, 4_000);
}

// Guard against missing macro errors during integration.
#[test, expected_failure(abort_code = macros::EDivideByZero)]
fun rejects_zero_denominator() {
    u64::mul_div(1, 1, 0, rounding::down());
}

// Downstream overflow is still surfaced with the wrapper’s specific code.
#[test, expected_failure(abort_code = u64::EArithmeticOverflow)]
fun detects_overflow() {
    u64::mul_div(std::u64::max_value!(), 2, 1, rounding::down());
}

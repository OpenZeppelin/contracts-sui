module openzeppelin_math::u128_tests;

use openzeppelin_math::macros;
use openzeppelin_math::rounding;
use openzeppelin_math::u128;
use std::unit_test::assert_eq;

// Sanity-check rounding before we switch to the wide helper.
#[test]
fun rounding_modes() {
    let down = u128::mul_div(70, 10, 4, rounding::down());
    assert_eq!(down, 175);

    let up = u128::mul_div(5, 3, 4, rounding::up());
    assert_eq!(up, 4);

    let nearest = u128::mul_div(7, 10, 4, rounding::nearest());
    assert_eq!(nearest, 18);
}

// Straightforward division should not be perturbed by rounding.
#[test]
fun exact_division() {
    let exact = u128::mul_div(8_000, 2, 4, rounding::up());
    assert_eq!(exact, 4_000);
}

// Keep coverage over the shared macro guard.
#[test, expected_failure(abort_code = macros::EDivideByZero)]
fun rejects_zero_denominator() {
    u128::mul_div(1, 1, 0, rounding::down());
}

// Casting down from u256 must still abort when values exceed u128’s range.
#[test, expected_failure(abort_code = u128::EArithmeticOverflow)]
fun detects_overflow() {
    u128::mul_div(std::u128::max_value!(), 2, 1, rounding::down());
}

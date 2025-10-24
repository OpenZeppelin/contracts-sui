module openzeppelin_math::u16_tests;

use openzeppelin_math::macros;
use openzeppelin_math::rounding;
use openzeppelin_math::u16;
use std::unit_test::assert_eq;

// Mirror the u8 suite but at the wider width.
#[test]
fun rounding_modes() {
    let down = u16::mul_div(70, 10, 4, rounding::down());
    assert_eq!(down, 175);

    let up = u16::mul_div(5, 3, 4, rounding::up());
    assert_eq!(up, 4);

    let nearest = u16::mul_div(7, 10, 4, rounding::nearest());
    assert_eq!(nearest, 18);
}

// Ensure exact division returns the intuitive quotient.
#[test]
fun exact_division() {
    let exact = u16::mul_div(800, 2, 4, rounding::up());
    assert_eq!(exact, 400);
}

// Macro-level guard still fires.
#[test, expected_failure(abort_code = macros::EDivideByZero)]
fun rejects_zero_denominator() {
    u16::mul_div(1, 1, 0, rounding::down());
}

// Downcast overflow must be intercepted.
#[test, expected_failure(abort_code = u16::EArithmeticOverflow)]
fun detects_overflow() {
    u16::mul_div(std::u16::max_value!(), 2, 1, rounding::down());
}

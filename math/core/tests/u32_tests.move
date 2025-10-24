module openzeppelin_math::u32_tests;

use openzeppelin_math::macros;
use openzeppelin_math::rounding;
use openzeppelin_math::u32;
use std::unit_test::assert_eq;

// Exercise rounding logic now that values comfortably stay in the fast path.
#[test]
fun rounding_modes() {
    let down = u32::mul_div(70, 10, 4, rounding::down());
    assert_eq!(down, 175);

    let up = u32::mul_div(5, 3, 4, rounding::up());
    assert_eq!(up, 4);

    let nearest = u32::mul_div(7, 10, 4, rounding::nearest());
    assert_eq!(nearest, 18);
}

// Basic exact-case regression.
#[test]
fun exact_division() {
    let exact = u32::mul_div(8_000, 2, 4, rounding::up());
    assert_eq!(exact, 4_000);
}

// Division by zero still bubbles the macro error.
#[test, expected_failure(abort_code = macros::EDivideByZero)]
fun rejects_zero_denominator() {
    u32::mul_div(1, 1, 0, rounding::down());
}

// Cast back to u32 must trip when the result no longer fits.
#[test, expected_failure(abort_code = u32::EArithmeticOverflow)]
fun detects_overflow() {
    u32::mul_div(std::u32::max_value!(), 2, 1, rounding::down());
}

module openzeppelin_math::u8_tests;

use openzeppelin_math::macros;
use openzeppelin_math::rounding;
use openzeppelin_math::u8;
use std::unit_test::assert_eq;

// === mul_div ===

// Confirm the helper honours each rounding flavour.
#[test]
fun mul_div_rounding_modes() {
    let (down_overflow, down) = u8::mul_div(7, 10, 4, rounding::down());
    assert_eq!(down_overflow, false);
    assert_eq!(down, 17);

    let (up_overflow, up) = u8::mul_div(5, 3, 4, rounding::up());
    assert_eq!(up_overflow, false);
    assert_eq!(up, 4);

    let (nearest_overflow, nearest) = u8::mul_div(7, 10, 4, rounding::nearest());
    assert_eq!(nearest_overflow, false);
    assert_eq!(nearest, 18);
}

// Baseline sanity check: no rounding tweak required.
#[test]
fun mul_div_exact_division() {
    let (overflow, exact) = u8::mul_div(8, 2, 4, rounding::up());
    assert_eq!(overflow, false);
    assert_eq!(exact, 4);
}

// Division by zero should still surface the shared macro error.
#[test, expected_failure(abort_code = macros::EDivideByZero)]
fun mul_div_rejects_zero_denominator() {
    u8::mul_div(1, 1, 0, rounding::down());
}

// Wrappers must flag when the macro’s result no longer fits in u8.
#[test]
fun mul_div_detects_overflow() {
    let (overflow, result) = u8::mul_div(20, 20, 1, rounding::down());
    assert_eq!(overflow, true);
    assert_eq!(result, 0);
}

// === average ===

#[test]
fun average_rounding_modes() {
    let down = u8::average(4, 7, rounding::down());
    assert_eq!(down, 5);

    let up = u8::average(4, 7, rounding::up());
    assert_eq!(up, 6);

    let nearest = u8::average(1, 2, rounding::nearest());
    assert_eq!(nearest, 2);
}

#[test]
fun average_is_commutative() {
    let left = u8::average(10, 3, rounding::nearest());
    let right = u8::average(3, 10, rounding::nearest());
    assert_eq!(left, right);
}

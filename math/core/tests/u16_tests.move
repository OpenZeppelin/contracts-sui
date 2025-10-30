module openzeppelin_math::u16_tests;

use openzeppelin_math::macros;
use openzeppelin_math::rounding;
use openzeppelin_math::u16;
use std::unit_test::assert_eq;

// === mul_div ===

// Mirror the u8 suite but at the wider width.
#[test]
fun mul_div_rounding_modes() {
    let (down_overflow, down) = u16::mul_div(70, 10, 4, rounding::down());
    assert_eq!(down_overflow, false);
    assert_eq!(down, 175);

    let (up_overflow, up) = u16::mul_div(5, 3, 4, rounding::up());
    assert_eq!(up_overflow, false);
    assert_eq!(up, 4);

    let (nearest_overflow, nearest) = u16::mul_div(
        7,
        10,
        4,
        rounding::nearest(),
    );
    assert_eq!(nearest_overflow, false);
    assert_eq!(nearest, 18);
}

// Ensure exact division returns the intuitive quotient.
#[test]
fun mul_div_exact_division() {
    let (overflow, exact) = u16::mul_div(800, 2, 4, rounding::up());
    assert_eq!(overflow, false);
    assert_eq!(exact, 400);
}

// Macro-level guard still fires.
#[test, expected_failure(abort_code = macros::EDivideByZero)]
fun mul_div_rejects_zero_denominator() {
    u16::mul_div(1, 1, 0, rounding::down());
}

// Downcast overflow must be intercepted.
#[test]
fun detects_overflow() {
    let (overflow, result) = u16::mul_div(
        std::u16::max_value!(),
        2,
        1,
        rounding::down(),
    );
    assert_eq!(overflow, true);
    assert_eq!(result, 0);
}

// === average ===

#[test]
fun average_rounding_modes() {
    let down = u16::average(400, 401, rounding::down());
    assert_eq!(down, 400);

    let up = u16::average(400, 401, rounding::up());
    assert_eq!(up, 401);

    let nearest = u16::average(1, 2, rounding::nearest());
    assert_eq!(nearest, 2);
}

#[test]
fun average_is_commutative() {
    let left = u16::average(500, 100, rounding::nearest());
    let right = u16::average(100, 500, rounding::nearest());
    assert_eq!(left, right);
}

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
fun mul_div_detects_overflow() {
    let (overflow, result) = u16::mul_div(
        std::u16::max_value!(),
        2,
        1,
        rounding::down(),
    );
    assert_eq!(overflow, true);
    assert_eq!(result, 0);
}

// === checked_shr ===

#[test]
fun checked_shr_returns_some() {
    // 0b1_0000_0000 >> 8 yields 0b0000_0001 with no information loss.
    let result = u16::checked_shr(256, 8);
    assert_eq!(result, option::some(1));
}

#[test]
fun checked_shr_detects_set_bits() {
    // Low bit set, shifting by one would drop it.
    let result = u16::checked_shr(5, 1);
    assert_eq!(result, option::none());
}

#[test]
fun checked_shr_rejects_large_shift() {
    // Reject width-sized shift to prevent narrowing to zero implicitly.
    let result = u16::checked_shr(1, 16);
    assert_eq!(result, option::none());
}

module openzeppelin_math::u32_tests;

use openzeppelin_math::macros;
use openzeppelin_math::rounding;
use openzeppelin_math::u32;
use std::unit_test::assert_eq;

// === mul_div ===

// Exercise rounding logic now that values comfortably stay in the fast path.
#[test]
fun mul_div_rounding_modes() {
    let (down_overflow, down) = u32::mul_div(70, 10, 4, rounding::down());
    assert_eq!(down_overflow, false);
    assert_eq!(down, 175);

    let (up_overflow, up) = u32::mul_div(5, 3, 4, rounding::up());
    assert_eq!(up_overflow, false);
    assert_eq!(up, 4);

    let (nearest_overflow, nearest) = u32::mul_div(7, 10, 4, rounding::nearest());
    assert_eq!(nearest_overflow, false);
    assert_eq!(nearest, 18);
}

// Basic exact-case regression.
#[test]
fun mul_div_exact_division() {
    let (overflow, exact) = u32::mul_div(8_000, 2, 4, rounding::up());
    assert_eq!(overflow, false);
    assert_eq!(exact, 4_000);
}

// Division by zero still bubbles the macro error.
#[test, expected_failure(abort_code = macros::EDivideByZero)]
fun mul_div_rejects_zero_denominator() {
    u32::mul_div(1, 1, 0, rounding::down());
}

// Cast back to u32 must trip when the result no longer fits.
#[test]
fun mul_div_detects_overflow() {
    let (overflow, result) = u32::mul_div(std::u32::max_value!(), 2, 1, rounding::down());
    assert_eq!(overflow, true);
    assert_eq!(result, 0);
}

// === checked_shr ===

#[test]
fun checked_shr_returns_some() {
    // Shifting 0x0001_0000 right by 16 yields 0x0000_0001.
    let result = u32::checked_shr(1u32 << 16, 16);
    assert_eq!(result, option::some(1));
}

#[test]
fun checked_shr_detects_set_bits() {
    // Mask ensures we spot the dropped LSB.
    let result = u32::checked_shr(5, 1);
    assert_eq!(result, option::none());
}

#[test]
fun checked_shr_rejects_large_shift() {
    // Width-sized shift should be rejected.
    let result = u32::checked_shr(1, 32);
    assert_eq!(result, option::none());
}

// === checked_shl ===

#[test]
fun checked_shl_returns_some() {
    // 0x0000_0001 << 31 lands exactly on the sign bit.
    let result = u32::checked_shl(1, 31);
    assert_eq!(result, option::some(0x8000_0000));
}

#[test]
fun checked_shl_returns_same_for_zero_shift() {
    // Shifting by zero should return the same value.
    let result = u32::checked_shl(0x9000_0000, 0);
    assert_eq!(result, option::some(0x9000_0000));
}

#[test]
fun checked_shl_detects_high_bits() {
    // 0x9000_0000 already uses the top bits; shifting would overflow.
    let result = u32::checked_shl(0x9000_0000, 1);
    assert_eq!(result, option::none());
}

#[test]
fun checked_shl_rejects_large_shift() {
    // Guard against the width-sized shift.
    let result = u32::checked_shl(1, 32);
    assert_eq!(result, option::none());
}

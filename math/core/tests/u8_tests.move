module openzeppelin_math::u8_tests;

use openzeppelin_math::macros;
use openzeppelin_math::rounding;
use openzeppelin_math::u8;
use std::unit_test::assert_eq;

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

// === checked_shl ===

#[test]
fun checked_shl_returns_some() {
    // 0b0000_0001 << 7 reaches the top bit exactly.
    let result = u8::checked_shl(1, 7);
    assert_eq!(result, option::some(128));
}

#[test]
fun checked_shl_zero_input_returns_zero_for_overshift() {
    assert_eq!(u8::checked_shl(0, 9), option::some(0));
}

#[test]
fun checked_shl_returns_same_for_zero_shift() {
    // Shifting by zero should return the same value.
    let result = u8::checked_shl(129, 0);
    assert_eq!(result, option::some(129));
}

#[test]
fun checked_shl_detects_high_bits() {
    // 0b1000_0001 << 1 would overflow the type.
    let result = u8::checked_shl(129, 1);
    assert_eq!(result, option::none());
}

#[test]
fun checked_shl_rejects_large_shift() {
    // Disallow width-sized shifts that would abort at runtime.
    let result = u8::checked_shl(1, 8);
    assert_eq!(result, option::none());
}

// === checked_shr ===

#[test]
fun checked_shr_returns_some() {
    // 0b1000_0000 >> 7 keeps the high bit and yields 0b0000_0001.
    let result = u8::checked_shr(128, 7);
    assert_eq!(result, option::some(1));
}

#[test]
fun checked_shr_zero_input_returns_zero_for_overshift() {
    assert_eq!(u8::checked_shr(0, 9), option::some(0));
}

#[test]
fun checked_shr_detects_set_bits() {
    // 0b0000_0101 would lose the low bit if shifted by one.
    let result = u8::checked_shr(5, 1);
    assert_eq!(result, option::none());
}

#[test]
fun checked_shr_rejects_large_shift() {
    // Shifting by the width or more is treated as invalid.
    let result = u8::checked_shr(1, 8);
    assert_eq!(result, option::none());
}

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

    let (nearest_overflow, nearest) = u8::mul_div(
        7,
        10,
        4,
        rounding::nearest(),
    );
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

// === mul_shr ===

#[test]
fun mul_shr_returns_some_when_in_range() {
    let result = u8::mul_shr(6, 4, 1, rounding::down());
    assert_eq!(result, option::some(12));
}

#[test]
fun mul_shr_respects_rounding_modes() {
    // 5*3 = 15; 15 >> 1 = 7.5
    let down = u8::mul_shr(5, 3, 1, rounding::down());
    assert_eq!(down, option::some(7));

    let up = u8::mul_shr(5, 3, 1, rounding::up());
    assert_eq!(up, option::some(8));

    let nearest = u8::mul_shr(5, 3, 1, rounding::nearest());
    assert_eq!(nearest, option::some(8));

    // 7*4 = 28; 28 >> 2 = 7.0
    let exact = u8::mul_shr(7, 4, 2, rounding::nearest());
    assert_eq!(exact, option::some(7));

    // 13*3 = 39; 39 >> 2 = 9.75
    let down2 = u8::mul_shr(13, 3, 2, rounding::down());
    assert_eq!(down2, option::some(9));

    let up2 = u8::mul_shr(13, 3, 2, rounding::up());
    assert_eq!(up2, option::some(10));

    let nearest2 = u8::mul_shr(13, 3, 2, rounding::nearest());
    assert_eq!(nearest2, option::some(10));

    // 7*3 = 21; 21 >> 2 = 5.25
    let down3 = u8::mul_shr(7, 3, 2, rounding::down());
    assert_eq!(down3, option::some(5));

    let up3 = u8::mul_shr(7, 3, 2, rounding::up());
    assert_eq!(up3, option::some(6));

    let nearest3 = u8::mul_shr(7, 3, 2, rounding::nearest());
    assert_eq!(nearest3, option::some(5));
}

#[test]
fun mul_shr_detects_overflow() {
    let overflow = u8::mul_shr(std::u8::max_value!(), std::u8::max_value!(), 0, rounding::down());
    assert_eq!(overflow, option::none());
}

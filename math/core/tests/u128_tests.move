module openzeppelin_math::u128_tests;

use openzeppelin_math::macros;
use openzeppelin_math::rounding;
use openzeppelin_math::u128;
use std::unit_test::assert_eq;

// === average ===

#[test]
fun average_rounding_modes() {
    let down = u128::average(7, 10, rounding::down());
    assert_eq!(down, 8);

    let up = u128::average(7, 10, rounding::up());
    assert_eq!(up, 9);

    let nearest = u128::average(1, 2, rounding::nearest());
    assert_eq!(nearest, 2);
}

#[test]
fun average_is_commutative() {
    let left = u128::average(1_000, 100, rounding::nearest());
    let right = u128::average(100, 1_000, rounding::nearest());
    assert_eq!(left, right);
}

// === checked_shl ===

#[test]
fun checked_shl_returns_some() {
    // Shift a single 1 into the most-significant bit.
    let result = u128::checked_shl(1, 127);
    assert_eq!(result, option::some(1u128 << 127));
}

#[test]
fun checked_shl_zero_input_returns_zero_for_overshift() {
    assert_eq!(u128::checked_shl(0, 129), option::some(0));
}

#[test]
fun checked_shl_returns_same_for_zero_shift() {
    // Shifting by zero should return the same value.
    let value = 1u128 << 127;
    let result = u128::checked_shl(value, 0);
    assert_eq!(result, option::some(value));
}

#[test]
fun checked_shl_detects_high_bits() {
    // Highest bit already set — shifting would overflow.
    let result = u128::checked_shl(1u128 << 127, 1);
    assert_eq!(result, option::none());
}

#[test]
fun checked_shl_rejects_large_shift() {
    // Prevent width-sized shift that would abort.
    let result = u128::checked_shl(1, 128);
    assert_eq!(result, option::none());
}

// === checked_shr ===

#[test]
fun checked_shr_returns_some() {
    // 1 << 64 leaves a zeroed lower half that can be shifted out safely.
    let value = 1u128 << 64;
    let result = u128::checked_shr(value, 64);
    assert_eq!(result, option::some(1));
}

#[test]
fun checked_shr_zero_input_returns_zero_for_overshift() {
    assert_eq!(u128::checked_shr(0, 129), option::some(0));
}

#[test]
fun checked_shr_detects_set_bits() {
    // Detect loss when the LSB is still set.
    let result = u128::checked_shr(5, 1);
    assert_eq!(result, option::none());
}

#[test]
fun checked_shr_rejects_large_shift() {
    // Guard against shifting by the width.
    let result = u128::checked_shr(1, 128);
    assert_eq!(result, option::none());
}

// === mul_div ===

// Sanity-check rounding before we switch to the wide helper.
#[test]
fun mul_div_rounding_modes() {
    let (down_overflow, down) = u128::mul_div(70, 10, 4, rounding::down());
    assert_eq!(down_overflow, false);
    assert_eq!(down, 175);

    let (up_overflow, up) = u128::mul_div(5, 3, 4, rounding::up());
    assert_eq!(up_overflow, false);
    assert_eq!(up, 4);

    let (nearest_overflow, nearest) = u128::mul_div(
        7,
        10,
        4,
        rounding::nearest(),
    );
    assert_eq!(nearest_overflow, false);
    assert_eq!(nearest, 18);
}

// Straightforward division should not be perturbed by rounding.
#[test]
fun mul_div_exact_division() {
    let (overflow, exact) = u128::mul_div(8_000, 2, 4, rounding::up());
    assert_eq!(overflow, false);
    assert_eq!(exact, 4_000);
}

// Keep coverage over the shared macro guard.
#[test, expected_failure(abort_code = macros::EDivideByZero)]
fun mul_div_rejects_zero_denominator() {
    u128::mul_div(1, 1, 0, rounding::down());
}

// Casting down from u256 must still flag when values exceed u128’s range.
#[test]
fun mul_div_detects_overflow() {
    let (overflow, result) = u128::mul_div(
        std::u128::max_value!(),
        2,
        1,
        rounding::down(),
    );
    assert_eq!(overflow, true);
    assert_eq!(result, 0);
}

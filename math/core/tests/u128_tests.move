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

// === clz ===

// clz(0) should return 128 (all bits are leading zeros).
#[test]
fun clz_returns_bit_width_for_zero() {
    let result = u128::clz(0);
    assert_eq!(result, 128);
}

// When the most significant bit is set, there are no leading zeros.
#[test]
fun clz_returns_zero_for_top_bit_set() {
    let value = 1u128 << 127;
    let result = u128::clz(value);
    assert_eq!(result, 0);
}

// Max value has the top bit set, so no leading zeros.
#[test]
fun clz_returns_zero_for_max_value() {
    let max = std::u128::max_value!();
    let result = u128::clz(max);
    assert_eq!(result, 0);
}

// Test all possible bit positions from 0 to 127.
#[test]
fun clz_handles_all_bit_positions() {
    let mut bit_pos: u8 = 0;
    while (bit_pos < 128) {
        let value = 1u128 << bit_pos;
        let expected_clz = 127 - bit_pos;
        assert_eq!(u128::clz(value), expected_clz);
        bit_pos = bit_pos + 1;
    };
}

// Test that lower bits have no effect on the result.
#[test]
fun clz_lower_bits_have_no_effect() {
    let mut bit_pos: u8 = 0;
    while (bit_pos < 128) {
        let mut value = 1u128 << bit_pos;
        // Set all bits below bit_pos to 1
        value = value | (value - 1);
        let expected_clz = 127 - bit_pos;
        assert_eq!(u128::clz(value), expected_clz);
        bit_pos = bit_pos + 1;
    };
}

// When multiple bits are set, clz counts from the highest bit.
#[test]
fun clz_counts_from_highest_bit() {
    // 0b11 (bits 0 and 1 set) - highest is bit 1, so clz = 126
    assert_eq!(u128::clz(3), 126);

    // 0b1111 (bits 0-3 set) - highest is bit 3, so clz = 124
    assert_eq!(u128::clz(15), 124);

    // 0xff (bits 0-7 set) - highest is bit 7, so clz = 120
    assert_eq!(u128::clz(255), 120);
}

// Test values near power-of-2 boundaries.
#[test]
fun clz_handles_values_near_boundaries() {
    // 2^64 has bit 64 set, clz = 63
    assert_eq!(u128::clz(1 << 64), 63);

    // 2^64 - 1 has bit 63 set, clz = 64
    assert_eq!(u128::clz((1 << 64) - 1), 64);

    // 2^100 has bit 100 set, clz = 27
    assert_eq!(u128::clz(1 << 100), 27);

    // 2^100 - 1 has bit 99 set, clz = 28
    assert_eq!(u128::clz((1 << 100) - 1), 28);
}

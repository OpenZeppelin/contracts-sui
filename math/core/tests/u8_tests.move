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

// === clz ===

#[test]
fun clz_returns_bit_width_for_zero() {
    // clz(0) should return 8 (all bits are leading zeros).
    let result = u8::clz(0);
    assert_eq!(result, 8);
}

#[test]
fun clz_returns_zero_for_top_bit_set() {
    // when the most significant bit is set, there are no leading zeros.
    let value = 1u8 << 7;
    let result = u8::clz(value);
    assert_eq!(result, 0);
}

#[test]
fun clz_returns_zero_for_max_value() {
    // max value has the top bit set, so no leading zeros.
    let max = std::u8::max_value!();
    let result = u8::clz(max);
    assert_eq!(result, 0);
}

// Test all possible bit positions from 0 to 7.
#[test]
fun clz_handles_all_bit_positions() {
    let mut bit_pos: u8 = 0;
    while (bit_pos < 8) {
        let value = 1u8 << bit_pos;
        let expected_clz = 7 - bit_pos;
        assert_eq!(u8::clz(value), expected_clz);
        bit_pos = bit_pos + 1;
    };
}

// Test that lower bits have no effect on the result.
#[test]
fun clz_lower_bits_have_no_effect() {
    let mut bit_pos: u8 = 0;
    while (bit_pos < 8) {
        let mut value = 1u8 << bit_pos;
        // set all bits below bit_pos to 1
        value = value | (value - 1);
        let expected_clz = 7 - bit_pos;
        assert_eq!(u8::clz(value), expected_clz);
        bit_pos = bit_pos + 1;
    };
}

#[test]
fun clz_counts_from_highest_bit() {
    // when multiple bits are set, clz counts from the highest bit.
    // 0b11 (bits 0 and 1 set) - highest is bit 1, so clz = 6
    assert_eq!(u8::clz(3), 6);

    // 0b1111 (bits 0-3 set) - highest is bit 3, so clz = 4
    assert_eq!(u8::clz(15), 4);

    // 0xff (bits 0-7 set) - highest is bit 7, so clz = 0
    assert_eq!(u8::clz(255), 0);
}

// Test values near power-of-2 boundaries.
#[test]
fun clz_handles_values_near_boundaries() {
    // 16 has bit 4 set, clz = 3
    assert_eq!(u8::clz(16), 3);

    // 15 has bit 3 set, clz = 4
    assert_eq!(u8::clz(15), 4);

    // 32 has bit 5 set, clz = 2
    assert_eq!(u8::clz(32), 2);

    // 31 has bit 4 set, clz = 3
    assert_eq!(u8::clz(31), 3);
}

// === log2 ===

#[test]
fun log2_returns_zero_for_zero() {
    // log2(0) should return 0 by convention
    assert_eq!(u8::log2(0), 0);
}

#[test]
fun log2_returns_zero_for_one() {
    // log2(1) = 0 since 2^0 = 1
    assert_eq!(u8::log2(1), 0);
}

#[test]
fun log2_handles_powers_of_two() {
    // for powers of 2, log2 returns the exponent
    assert_eq!(u8::log2(1 << 0), 0); // 2^0 = 1
    assert_eq!(u8::log2(1 << 1), 1); // 2^1 = 2
    assert_eq!(u8::log2(1 << 2), 2); // 2^2 = 4
    assert_eq!(u8::log2(1 << 3), 3); // 2^3 = 8
    assert_eq!(u8::log2(1 << 4), 4); // 2^4 = 16
    assert_eq!(u8::log2(1 << 5), 5); // 2^5 = 32
    assert_eq!(u8::log2(1 << 6), 6); // 2^6 = 64
    assert_eq!(u8::log2(1 << 7), 7); // 2^7 = 128
}

#[test]
fun log2_rounds_down() {
    // log2 rounds down to the nearest integer
    assert_eq!(u8::log2(3), 1); // log2(3) ≈ 1.58 → 1
    assert_eq!(u8::log2(5), 2); // log2(5) ≈ 2.32 → 2
    assert_eq!(u8::log2(7), 2); // log2(7) ≈ 2.81 → 2
    assert_eq!(u8::log2(15), 3); // log2(15) ≈ 3.91 → 3
    assert_eq!(u8::log2(127), 6); // log2(127) ≈ 6.99 → 6
}

#[test]
fun log2_handles_values_near_boundaries() {
    // test values just before and at power-of-2 boundaries
    // 2^4 - 1 = 15
    assert_eq!(u8::log2((1 << 4) - 1), 3);
    // 2^4 = 16
    assert_eq!(u8::log2(1 << 4), 4);

    // 2^6 - 1 = 63
    assert_eq!(u8::log2((1 << 6) - 1), 5);
    // 2^6 = 64
    assert_eq!(u8::log2(1 << 6), 6);
}

#[test]
fun log2_handles_max_value() {
    // max value has all bits set, so log2 = 7
    let max = std::u8::max_value!();
    assert_eq!(u8::log2(max), 7);
}

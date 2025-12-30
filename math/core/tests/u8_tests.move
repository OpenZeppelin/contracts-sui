#[test_only]
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
    let down = u8::mul_div(7, 10, 4, rounding::down());
    assert_eq!(down, option::some(17));

    let up = u8::mul_div(5, 3, 4, rounding::up());
    assert_eq!(up, option::some(4));

    let nearest = u8::mul_div(
        7,
        10,
        4,
        rounding::nearest(),
    );
    assert_eq!(nearest, option::some(18));
}

// Baseline sanity check: no rounding tweak required.
#[test]
fun mul_div_exact_division() {
    let exact = u8::mul_div(8, 2, 4, rounding::up());
    assert_eq!(exact, option::some(4));
}

// Division by zero should still surface the shared macro error.
#[test, expected_failure(abort_code = macros::EDivideByZero)]
fun mul_div_rejects_zero_denominator() {
    u8::mul_div(1, 1, 0, rounding::down());
}

// Wrappers must flag when the macro's result no longer fits in u8.
#[test]
fun mul_div_detects_overflow() {
    let result = u8::mul_div(20, 20, 1, rounding::down());
    assert_eq!(result, option::none());
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
    8u8.do!(|bit_pos| {
        let value = 1u8 << bit_pos;
        let expected_clz = 7 - bit_pos;
        assert_eq!(u8::clz(value), expected_clz);
    });
}

// Test that lower bits have no effect on the result.
#[test]
fun clz_lower_bits_have_no_effect() {
    8u8.do!(|bit_pos| {
        let mut value = 1u8 << bit_pos;
        // set all bits below bit_pos to 1
        value = value | (value - 1);
        let expected_clz = 7 - bit_pos;
        assert_eq!(u8::clz(value), expected_clz);
    });
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

// === msb ===

#[test]
fun msb_returns_zero_for_zero() {
    // msb(0) should return 0 by convention
    let result = u8::msb(0);
    assert_eq!(result, 0);
}

#[test]
fun msb_returns_correct_position_for_top_bit_set() {
    // when the most significant bit is set, msb returns 7
    let value = 1u8 << 7;
    let result = u8::msb(value);
    assert_eq!(result, 7);
}

#[test]
fun msb_returns_correct_position_for_max_value() {
    // max value has the top bit set, so msb returns 7
    let max = std::u8::max_value!();
    let result = u8::msb(max);
    assert_eq!(result, 7);
}

// Test all possible bit positions from 0 to 7.
#[test]
fun msb_handles_all_bit_positions() {
    8u8.do!(|bit_pos| {
        let value = 1u8 << bit_pos;
        assert_eq!(u8::msb(value), bit_pos);
    });
}

// Test that lower bits have no effect on the result.
#[test]
fun msb_lower_bits_have_no_effect() {
    8u8.do!(|bit_pos| {
        let mut value = 1u8 << bit_pos;
        // set all bits below bit_pos to 1
        value = value | (value - 1);
        assert_eq!(u8::msb(value), bit_pos);
    });
}

#[test]
fun msb_returns_highest_bit_position() {
    // when multiple bits are set, msb returns the position of the highest bit.
    // 0b11 (bits 0 and 1 set) - highest is bit 1, so msb = 1
    assert_eq!(u8::msb(3), 1);

    // 0b1111 (bits 0-3 set) - highest is bit 3, so msb = 3
    assert_eq!(u8::msb(15), 3);

    // 0xff (bits 0-7 set) - highest is bit 7, so msb = 7
    assert_eq!(u8::msb(255), 7);
}

// Test values near power-of-2 boundaries.
#[test]
fun msb_handles_values_near_boundaries() {
    // 16 has bit 4 set, msb = 4
    assert_eq!(u8::msb(16), 4);

    // 15 has bit 3 set, msb = 3
    assert_eq!(u8::msb(15), 3);

    // 32 has bit 5 set, msb = 5
    assert_eq!(u8::msb(32), 5);

    // 31 has bit 4 set, msb = 4
    assert_eq!(u8::msb(31), 4);
}

// === log2 ===

#[test]
fun log2_returns_zero_for_zero() {
    // log2(0) should return 0 by convention
    assert_eq!(u8::log2(0, rounding::down()), 0);
    assert_eq!(u8::log2(0, rounding::up()), 0);
    assert_eq!(u8::log2(0, rounding::nearest()), 0);
}

#[test]
fun log2_returns_zero_for_one() {
    // log2(1) = 0 since 2^0 = 1
    assert_eq!(u8::log2(1, rounding::down()), 0);
    assert_eq!(u8::log2(1, rounding::up()), 0);
    assert_eq!(u8::log2(1, rounding::nearest()), 0);
}

#[test]
fun log2_handles_powers_of_two() {
    let rounding_modes = vector[rounding::down(), rounding::up(), rounding::nearest()];
    rounding_modes.destroy!(|rounding| {
        assert_eq!(u8::log2(1 << 0, rounding), 0);
        assert_eq!(u8::log2(1 << 1, rounding), 1);
        assert_eq!(u8::log2(1 << 2, rounding), 2);
        assert_eq!(u8::log2(1 << 3, rounding), 3);
        assert_eq!(u8::log2(1 << 4, rounding), 4);
        assert_eq!(u8::log2(1 << 5, rounding), 5);
        assert_eq!(u8::log2(1 << 6, rounding), 6);
        assert_eq!(u8::log2(1 << 7, rounding), 7);
    });
}

#[test]
fun log2_rounds_down() {
    // log2 with Down mode truncates to floor
    let down = rounding::down();
    assert_eq!(u8::log2(3, down), 1); // 1.58 → 1
    assert_eq!(u8::log2(5, down), 2); // 2.32 → 2
    assert_eq!(u8::log2(7, down), 2); // 2.81 → 2
    assert_eq!(u8::log2(15, down), 3); // 3.91 → 3
    assert_eq!(u8::log2(127, down), 6); // 6.99 → 6
}

#[test]
fun log2_rounds_up() {
    // log2 with Up mode rounds to ceiling
    let up = rounding::up();
    assert_eq!(u8::log2(3, up), 2); // 1.58 → 2
    assert_eq!(u8::log2(5, up), 3); // 2.32 → 3
    assert_eq!(u8::log2(7, up), 3); // 2.81 → 3
    assert_eq!(u8::log2(15, up), 4); // 3.91 → 4
    assert_eq!(u8::log2(127, up), 7); // 6.99 → 7
}

#[test]
fun log2_rounds_to_nearest() {
    // log2 with Nearest mode rounds to closest integer
    let nearest = rounding::nearest();
    assert_eq!(u8::log2(3, nearest), 2); // 1.58 → 2
    assert_eq!(u8::log2(5, nearest), 2); // 2.32 → 2
    assert_eq!(u8::log2(7, nearest), 3); // 2.81 → 3
    assert_eq!(u8::log2(15, nearest), 4); // 3.91 → 4
    assert_eq!(u8::log2(127, nearest), 7); // 6.99 → 7
}

#[test]
fun log2_handles_max_value() {
    // max value has all bits set, so log2 = 7
    let max = std::u8::max_value!();
    assert_eq!(u8::log2(max, rounding::down()), 7);
    assert_eq!(u8::log2(max, rounding::up()), 8);
    assert_eq!(u8::log2(max, rounding::nearest()), 8);
}

// === log256 ===

#[test]
fun log256_returns_zero_for_zero() {
    // log256(0) should return 0 by convention
    assert_eq!(u8::log256(0, rounding::down()), 0);
    assert_eq!(u8::log256(0, rounding::up()), 0);
    assert_eq!(u8::log256(0, rounding::nearest()), 0);
}

#[test]
fun log256_returns_zero_for_one() {
    // log256(1) = 0 since 256^0 = 1
    assert_eq!(u8::log256(1, rounding::down()), 0);
    assert_eq!(u8::log256(1, rounding::up()), 0);
    assert_eq!(u8::log256(1, rounding::nearest()), 0);
}

#[test]
fun log256_rounds_down() {
    // log256 with Down mode truncates to floor
    // For u8, all values are < 256, so log256(x) is in range [0, 1)
    let down = rounding::down();
    assert_eq!(u8::log256(2, down), 0); // 0.125 → 0
    assert_eq!(u8::log256(15, down), 0); // 0.488 → 0
    assert_eq!(u8::log256(16, down), 0); // 0.5 → 0
    assert_eq!(u8::log256(100, down), 0); // 0.830 → 0
    assert_eq!(u8::log256(127, down), 0); // 0.874 → 0
    assert_eq!(u8::log256(200, down), 0); // 0.955 → 0
    assert_eq!(u8::log256(255, down), 0); // 0.999 → 0
}

#[test]
fun log256_rounds_up() {
    // log256 with Up mode rounds to ceiling
    // For non-power-of-256 values, this rounds up to 1
    let up = rounding::up();
    assert_eq!(u8::log256(2, up), 1); // 0.125 → 1
    assert_eq!(u8::log256(15, up), 1); // 0.488 → 1
    assert_eq!(u8::log256(16, up), 1); // 0.5 → 1
    assert_eq!(u8::log256(100, up), 1); // 0.830 → 1
    assert_eq!(u8::log256(127, up), 1); // 0.874 → 1
    assert_eq!(u8::log256(200, up), 1); // 0.955 → 1
    assert_eq!(u8::log256(255, up), 1); // 0.999 → 1
}

#[test]
fun log256_rounds_to_nearest() {
    // log256 with Nearest mode rounds to closest integer
    // Midpoint is at √256 = 16
    // Values < 16 round down to 0, values >= 16 round up to 1
    let nearest = rounding::nearest();
    assert_eq!(u8::log256(2, nearest), 0); // 0.125 < midpoint → 0
    assert_eq!(u8::log256(15, nearest), 0); // 0.488 < midpoint → 0
    assert_eq!(u8::log256(16, nearest), 1); // 0.5 >= midpoint → 1
    assert_eq!(u8::log256(17, nearest), 1); // 0.515 > midpoint → 1
    assert_eq!(u8::log256(100, nearest), 1); // 0.830 → 1
    assert_eq!(u8::log256(127, nearest), 1); // 0.874 → 1
    assert_eq!(u8::log256(200, nearest), 1); // 0.955 → 1
    assert_eq!(u8::log256(255, nearest), 1); // 0.999 → 1
}

#[test]
fun log256_handles_max_value() {
    // max value (255) is less than 256, so log256 is less than 1
    let max = std::u8::max_value!();
    assert_eq!(u8::log256(max, rounding::down()), 0);
    assert_eq!(u8::log256(max, rounding::up()), 1);
    assert_eq!(u8::log256(max, rounding::nearest()), 1);
}

// === log10 ===

#[test]
fun log10_returns_zero_for_zero() {
    // log10(0) should return 0 by convention
    assert_eq!(u8::log10(0, rounding::down()), 0);
    assert_eq!(u8::log10(0, rounding::up()), 0);
    assert_eq!(u8::log10(0, rounding::nearest()), 0);
}

#[test]
fun log10_handles_powers_of_10() {
    // for powers of 10, log10 returns the exponent regardless of rounding mode
    let rounding_modes = vector[rounding::down(), rounding::up(), rounding::nearest()];
    rounding_modes.destroy!(|rounding| {
        assert_eq!(u8::log10(1, rounding), 0); // 10^0
        assert_eq!(u8::log10(10, rounding), 1); // 10^1
        assert_eq!(u8::log10(100, rounding), 2); // 10^2
    });
}

#[test]
fun log10_rounds_down() {
    // log10 with Down mode truncates to floor
    let down = rounding::down();
    assert_eq!(u8::log10(2, down), 0); // ≈ 0.301 → 0
    assert_eq!(u8::log10(9, down), 0); // ≈ 0.954 → 0
    assert_eq!(u8::log10(11, down), 1); // ≈ 1.041 → 1
    assert_eq!(u8::log10(50, down), 1); // ≈ 1.699 → 1
    assert_eq!(u8::log10(99, down), 1); // ≈ 1.996 → 1
    assert_eq!(u8::log10(101, down), 2); // ≈ 2.004 → 2
    assert_eq!(u8::log10(200, down), 2); // ≈ 2.301 → 2
    assert_eq!(u8::log10(255, down), 2); // ≈ 2.407 → 2
}

#[test]
fun log10_rounds_up() {
    // log10 with Up mode rounds to ceiling
    let up = rounding::up();
    assert_eq!(u8::log10(2, up), 1); // ≈ 0.301 → 1
    assert_eq!(u8::log10(9, up), 1); // ≈ 0.954 → 1
    assert_eq!(u8::log10(11, up), 2); // ≈ 1.041 → 2
    assert_eq!(u8::log10(50, up), 2); // ≈ 1.699 → 2
    assert_eq!(u8::log10(99, up), 2); // ≈ 1.996 → 2
    assert_eq!(u8::log10(101, up), 3); // ≈ 2.004 → 3
    assert_eq!(u8::log10(200, up), 3); // ≈ 2.301 → 3
    assert_eq!(u8::log10(255, up), 3); // ≈ 2.407 → 3
}

#[test]
fun log10_rounds_to_nearest() {
    let nearest = rounding::nearest();

    // Between 10^0 and 10^1: midpoint at √10 ≈ 3.162
    assert_eq!(u8::log10(3, nearest), 0); // < 3.162, rounds down
    assert_eq!(u8::log10(4, nearest), 1); // > 3.162, rounds up

    // Between 10^1 and 10^2: midpoint at 10 × √10 ≈ 31.62
    assert_eq!(u8::log10(31, nearest), 1); // < 31.62, rounds down
    assert_eq!(u8::log10(32, nearest), 2); // > 31.62, rounds up
}

#[test]
fun log10_handles_edge_cases_near_powers() {
    // Test values just before and after powers of 10
    let down = rounding::down();
    let up = rounding::up();
    let nearest = rounding::nearest();

    // Around 10^1 = 10
    assert_eq!(u8::log10(9, down), 0);
    assert_eq!(u8::log10(10, down), 1);
    assert_eq!(u8::log10(11, down), 1);

    assert_eq!(u8::log10(9, up), 1);
    assert_eq!(u8::log10(10, up), 1);
    assert_eq!(u8::log10(11, up), 2);

    assert_eq!(u8::log10(9, nearest), 1);
    assert_eq!(u8::log10(10, nearest), 1);
    assert_eq!(u8::log10(11, nearest), 1);

    // Around 10^2 = 100
    assert_eq!(u8::log10(99, down), 1);
    assert_eq!(u8::log10(100, down), 2);
    assert_eq!(u8::log10(101, down), 2);

    assert_eq!(u8::log10(99, up), 2);
    assert_eq!(u8::log10(100, up), 2);
    assert_eq!(u8::log10(101, up), 3);

    assert_eq!(u8::log10(99, nearest), 2);
    assert_eq!(u8::log10(100, nearest), 2);
    assert_eq!(u8::log10(101, nearest), 2);
}

#[test]
fun log10_handles_max_value() {
    // max value (255) has log10 ≈ 2.407
    let max = std::u8::max_value!();
    assert_eq!(u8::log10(max, rounding::down()), 2);
    assert_eq!(u8::log10(max, rounding::up()), 3);
    assert_eq!(u8::log10(max, rounding::nearest()), 2);
}

// === sqrt ===

#[test]
fun sqrt_returns_zero_for_zero() {
    // sqrt(0) = 0 by definition
    assert_eq!(u8::sqrt(0, rounding::down()), 0);
    assert_eq!(u8::sqrt(0, rounding::up()), 0);
    assert_eq!(u8::sqrt(0, rounding::nearest()), 0);
}

#[test]
fun sqrt_handles_perfect_squares() {
    // Perfect squares should return exact result regardless of rounding mode
    let rounding_modes = vector[rounding::down(), rounding::up(), rounding::nearest()];
    rounding_modes.destroy!(|rounding| {
        assert_eq!(u8::sqrt(1, rounding), 1);
        assert_eq!(u8::sqrt(4, rounding), 2);
        assert_eq!(u8::sqrt(9, rounding), 3);
        assert_eq!(u8::sqrt(16, rounding), 4);
        assert_eq!(u8::sqrt(25, rounding), 5);
        assert_eq!(u8::sqrt(36, rounding), 6);
        assert_eq!(u8::sqrt(49, rounding), 7);
        assert_eq!(u8::sqrt(64, rounding), 8);
        assert_eq!(u8::sqrt(81, rounding), 9);
        assert_eq!(u8::sqrt(100, rounding), 10);
        assert_eq!(u8::sqrt(121, rounding), 11);
        assert_eq!(u8::sqrt(144, rounding), 12);
        assert_eq!(u8::sqrt(169, rounding), 13);
        assert_eq!(u8::sqrt(196, rounding), 14);
        assert_eq!(u8::sqrt(225, rounding), 15);
    });
}

#[test]
fun sqrt_rounds_down() {
    // sqrt with Down mode truncates to floor
    let down = rounding::down();
    assert_eq!(u8::sqrt(2, down), 1); // 1.414 → 1
    assert_eq!(u8::sqrt(3, down), 1); // 1.732 → 1
    assert_eq!(u8::sqrt(5, down), 2); // 2.236 → 2
    assert_eq!(u8::sqrt(8, down), 2); // 2.828 → 2
    assert_eq!(u8::sqrt(10, down), 3); // 3.162 → 3
    assert_eq!(u8::sqrt(15, down), 3); // 3.873 → 3
    assert_eq!(u8::sqrt(24, down), 4); // 4.899 → 4
    assert_eq!(u8::sqrt(99, down), 9); // 9.950 → 9
    assert_eq!(u8::sqrt(255, down), 15); // 15.969 → 15
}

#[test]
fun sqrt_rounds_up() {
    // sqrt with Up mode rounds to ceiling
    let up = rounding::up();
    assert_eq!(u8::sqrt(2, up), 2); // 1.414 → 2
    assert_eq!(u8::sqrt(3, up), 2); // 1.732 → 2
    assert_eq!(u8::sqrt(5, up), 3); // 2.236 → 3
    assert_eq!(u8::sqrt(8, up), 3); // 2.828 → 3
    assert_eq!(u8::sqrt(10, up), 4); // 3.162 → 4
    assert_eq!(u8::sqrt(15, up), 4); // 3.873 → 4
    assert_eq!(u8::sqrt(24, up), 5); // 4.899 → 5
    assert_eq!(u8::sqrt(99, up), 10); // 9.950 → 10
    assert_eq!(u8::sqrt(255, up), 16); // 15.969 → 16
}

#[test]
fun sqrt_rounds_to_nearest() {
    // sqrt with Nearest mode rounds to closest integer
    let nearest = rounding::nearest();
    assert_eq!(u8::sqrt(2, nearest), 1); // 1.414 → 1
    assert_eq!(u8::sqrt(3, nearest), 2); // 1.732 → 2
    assert_eq!(u8::sqrt(5, nearest), 2); // 2.236 → 2
    assert_eq!(u8::sqrt(7, nearest), 3); // 2.646 → 3
    assert_eq!(u8::sqrt(8, nearest), 3); // 2.828 → 3
    assert_eq!(u8::sqrt(10, nearest), 3); // 3.162 → 3
    assert_eq!(u8::sqrt(13, nearest), 4); // 3.606 → 4
    assert_eq!(u8::sqrt(15, nearest), 4); // 3.873 → 4
    assert_eq!(u8::sqrt(24, nearest), 5); // 4.899 → 5
    assert_eq!(u8::sqrt(99, nearest), 10); // 9.950 → 10
    assert_eq!(u8::sqrt(255, nearest), 16); // 15.969 → 16
}

#[test]
fun sqrt_handles_powers_of_four() {
    // Powers of 4 (perfect squares of powers of 2)
    let rounding_modes = vector[rounding::down(), rounding::up(), rounding::nearest()];
    rounding_modes.destroy!(|rounding| {
        assert_eq!(u8::sqrt(1, rounding), 1);
        assert_eq!(u8::sqrt(4, rounding), 2);
        assert_eq!(u8::sqrt(16, rounding), 4);
        assert_eq!(u8::sqrt(64, rounding), 8);
    });
}

#[test]
fun sqrt_midpoint_behavior() {
    // Test values exactly between two perfect squares
    // Between 4 (2^2) and 9 (3^2): midpoint is around 6.5 (since 2.5^2 = 6.25)
    let nearest = rounding::nearest();
    assert_eq!(u8::sqrt(5, nearest), 2); // 2.236, closer to 2
    assert_eq!(u8::sqrt(6, nearest), 2); // 2.449, closer to 2
    assert_eq!(u8::sqrt(7, nearest), 3); // 2.646, closer to 3
    assert_eq!(u8::sqrt(8, nearest), 3); // 2.828, closer to 3

    // Between 9 (3^2) and 16 (4^2): midpoint at 12.5
    assert_eq!(u8::sqrt(12, nearest), 3); // 3.464, closer to 3
    assert_eq!(u8::sqrt(13, nearest), 4); // 3.606, closer to 4
}

#[test]
fun sqrt_handles_max_value() {
    let max = std::u8::max_value!();
    assert_eq!(u8::sqrt(max, rounding::down()), 15);
    assert_eq!(u8::sqrt(max, rounding::up()), 16);
    assert_eq!(u8::sqrt(max, rounding::nearest()), 16);
}

// === inv_mod ===

#[test]
fun inv_mod_returns_some() {
    let result = u8::inv_mod(3, 5);
    assert_eq!(result, option::some(2));
}

#[test]
fun inv_mod_returns_none_when_not_coprime() {
    let result = u8::inv_mod(6, 15);
    assert_eq!(result, option::none());
}

#[test, expected_failure(abort_code = macros::EZeroModulus)]
fun inv_mod_rejects_zero_modulus() {
    u8::inv_mod(1, 0);
}

// === mul_mod ===

#[test]
fun mul_mod_fast_path() {
    let result = u8::mul_mod(7, 9, 11);
    assert_eq!(result, 8);
}

#[test, expected_failure(abort_code = macros::EZeroModulus)]
fun mul_mod_rejects_zero_modulus() {
    u8::mul_mod(2, 3, 0);
}

#[test_only]
module openzeppelin_math::u32_tests;

use openzeppelin_math::macros;
use openzeppelin_math::rounding;
use openzeppelin_math::u32;
use std::unit_test::assert_eq;

// === average ===

#[test]
fun average_rounding_modes() {
    let down = u32::average(4000, 4005, rounding::down());
    assert_eq!(down, 4002);

    let up = u32::average(4000, 4005, rounding::up());
    assert_eq!(up, 4003);

    let nearest = u32::average(1, 2, rounding::nearest());
    assert_eq!(nearest, 2);
}

#[test]
fun average_is_commutative() {
    let left = u32::average(10_000, 1_000, rounding::nearest());
    let right = u32::average(1_000, 10_000, rounding::nearest());
    assert_eq!(left, right);
}

// === checked_shl ===

#[test]
fun checked_shl_returns_some() {
    // 0x0000_0001 << 31 lands exactly on the sign bit.
    let result = u32::checked_shl(1, 31);
    assert_eq!(result, option::some(0x8000_0000));
}

#[test]
fun checked_shl_zero_input_returns_zero_for_overshift() {
    assert_eq!(u32::checked_shl(0, 33), option::some(0));
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

// === checked_shr ===

#[test]
fun checked_shr_returns_some() {
    // Shifting 0x0001_0000 right by 16 yields 0x0000_0001.
    let result = u32::checked_shr(1u32 << 16, 16);
    assert_eq!(result, option::some(1));
}

#[test]
fun checked_shr_zero_input_returns_zero_for_overshift() {
    assert_eq!(u32::checked_shr(0, 33), option::some(0));
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

// === mul_div ===

// Exercise rounding logic now that values comfortably stay in the fast path.
#[test]
fun mul_div_rounding_modes() {
    let down = u32::mul_div(70, 10, 4, rounding::down());
    assert_eq!(down, option::some(175));

    let up = u32::mul_div(5, 3, 4, rounding::up());
    assert_eq!(up, option::some(4));

    let nearest = u32::mul_div(
        7,
        10,
        4,
        rounding::nearest(),
    );
    assert_eq!(nearest, option::some(18));
}

// Basic exact-case regression.
#[test]
fun mul_div_exact_division() {
    let exact = u32::mul_div(8_000, 2, 4, rounding::up());
    assert_eq!(exact, option::some(4_000));
}

// Division by zero still bubbles the macro error.
#[test, expected_failure(abort_code = macros::EDivideByZero)]
fun mul_div_rejects_zero_denominator() {
    u32::mul_div(1, 1, 0, rounding::down());
}

// Cast back to u32 must trip when the result no longer fits.
#[test]
fun mul_div_detects_overflow() {
    let result = u32::mul_div(
        std::u32::max_value!(),
        2,
        1,
        rounding::down(),
    );
    assert_eq!(result, option::none());
}

// === mul_shr ===

#[test]
fun mul_shr_returns_some_when_in_range() {
    let result = u32::mul_shr(1_000, 200, 3, rounding::down());
    assert_eq!(result, option::some(25_000));
}

#[test]
fun mul_shr_respects_rounding_modes() {
    // 5*3 = 15; 15 >> 1 = 7.5
    let down = u32::mul_shr(5, 3, 1, rounding::down());
    assert_eq!(down, option::some(7));

    let up = u32::mul_shr(5, 3, 1, rounding::up());
    assert_eq!(up, option::some(8));

    let nearest = u32::mul_shr(5, 3, 1, rounding::nearest());
    assert_eq!(nearest, option::some(8));

    // 7*4 = 28; 28 >> 2 = 7.0
    let exact = u32::mul_shr(7, 4, 2, rounding::nearest());
    assert_eq!(exact, option::some(7));

    // 13*3 = 39; 39 >> 2 = 9.75
    let down2 = u32::mul_shr(13, 3, 2, rounding::down());
    assert_eq!(down2, option::some(9));

    let up2 = u32::mul_shr(13, 3, 2, rounding::up());
    assert_eq!(up2, option::some(10));

    let nearest2 = u32::mul_shr(13, 3, 2, rounding::nearest());
    assert_eq!(nearest2, option::some(10));

    // 7*3 = 21; 21 >> 2 = 5.25
    let down3 = u32::mul_shr(7, 3, 2, rounding::down());
    assert_eq!(down3, option::some(5));

    let up3 = u32::mul_shr(7, 3, 2, rounding::up());
    assert_eq!(up3, option::some(6));

    let nearest3 = u32::mul_shr(7, 3, 2, rounding::nearest());
    assert_eq!(nearest3, option::some(5));
}

#[test]
fun mul_shr_detects_overflow() {
    let overflow = u32::mul_shr(
        std::u32::max_value!(),
        std::u32::max_value!(),
        0,
        rounding::down(),
    );
    assert_eq!(overflow, option::none());
}

// === clz ===

#[test]
fun clz_returns_bit_width_for_zero() {
    // clz(0) should return 32 (all bits are leading zeros).
    let result = u32::clz(0);
    assert_eq!(result, 32);
}

#[test]
fun clz_returns_zero_for_top_bit_set() {
    // when the most significant bit is set, there are no leading zeros.
    let value = 1u32 << 31;
    let result = u32::clz(value);
    assert_eq!(result, 0);
}

#[test]
fun clz_returns_zero_for_max_value() {
    // max value has the top bit set, so no leading zeros.
    let max = std::u32::max_value!();
    let result = u32::clz(max);
    assert_eq!(result, 0);
}

// Test all possible bit positions from 0 to 31.
#[test]
fun clz_handles_all_bit_positions() {
    32u8.do!(|bit_pos| {
        let value = 1u32 << bit_pos;
        let expected_clz = 31 - bit_pos;
        assert_eq!(u32::clz(value), expected_clz);
    });
}

// Test that lower bits have no effect on the result.
#[test]
fun clz_lower_bits_have_no_effect() {
    32u8.do!(|bit_pos| {
        let mut value = 1u32 << bit_pos;
        // set all bits below bit_pos to 1
        value = value | (value - 1);
        let expected_clz = 31 - bit_pos;
        assert_eq!(u32::clz(value), expected_clz);
    });
}

#[test]
fun clz_counts_from_highest_bit() {
    // when multiple bits are set, clz counts from the highest bit.
    // 0b11 (bits 0 and 1 set) - highest is bit 1, so clz = 30
    assert_eq!(u32::clz(3), 30);

    // 0b1111 (bits 0-3 set) - highest is bit 3, so clz = 28
    assert_eq!(u32::clz(15), 28);

    // 0xff (bits 0-7 set) - highest is bit 7, so clz = 24
    assert_eq!(u32::clz(255), 24);
}

// Test values near power-of-2 boundaries.
#[test]
fun clz_handles_values_near_boundaries() {
    // 0x10000 (65536) has bit 16 set, clz = 15
    assert_eq!(u32::clz(65536), 15);

    // 0xffff (65535) has bit 15 set, clz = 16
    assert_eq!(u32::clz(65535), 16);

    // 0x0100_0000 (16777216) has bit 24 set, clz = 7
    assert_eq!(u32::clz(16777216), 7);

    // 0x00ff_ffff (16777215) has bit 23 set, clz = 8
    assert_eq!(u32::clz(16777215), 8);
}

// === msb ===

#[test]
fun msb_returns_zero_for_zero() {
    // msb(0) should return 0 by convention
    let result = u32::msb(0);
    assert_eq!(result, 0);
}

#[test]
fun msb_returns_correct_position_for_top_bit_set() {
    // when the most significant bit is set, msb returns 31
    let value = 1u32 << 31;
    let result = u32::msb(value);
    assert_eq!(result, 31);
}

#[test]
fun msb_returns_correct_position_for_max_value() {
    // max value has the top bit set, so msb returns 31
    let max = std::u32::max_value!();
    let result = u32::msb(max);
    assert_eq!(result, 31);
}

// Test all possible bit positions from 0 to 31.
#[test]
fun msb_handles_all_bit_positions() {
    32u8.do!(|bit_pos| {
        let value = 1u32 << bit_pos;
        assert_eq!(u32::msb(value), bit_pos);
    });
}

// Test that lower bits have no effect on the result.
#[test]
fun msb_lower_bits_have_no_effect() {
    32u8.do!(|bit_pos| {
        let mut value = 1u32 << bit_pos;
        // set all bits below bit_pos to 1
        value = value | (value - 1);
        assert_eq!(u32::msb(value), bit_pos);
    });
}

#[test]
fun msb_returns_highest_bit_position() {
    // when multiple bits are set, msb returns the position of the highest bit.
    // 0b11 (bits 0 and 1 set) - highest is bit 1, so msb = 1
    assert_eq!(u32::msb(3), 1);

    // 0b1111 (bits 0-3 set) - highest is bit 3, so msb = 3
    assert_eq!(u32::msb(15), 3);

    // 0xff (bits 0-7 set) - highest is bit 7, so msb = 7
    assert_eq!(u32::msb(255), 7);
}

// Test values near power-of-2 boundaries.
#[test]
fun msb_handles_values_near_boundaries() {
    // 0x10000 (65536) has bit 16 set, msb = 16
    assert_eq!(u32::msb(65536), 16);

    // 0xffff (65535) has bit 15 set, msb = 15
    assert_eq!(u32::msb(65535), 15);

    // 0x0100_0000 (16777216) has bit 24 set, msb = 24
    assert_eq!(u32::msb(16777216), 24);

    // 0x00ff_ffff (16777215) has bit 23 set, msb = 23
    assert_eq!(u32::msb(16777215), 23);
}

// === log2 ===

#[test]
fun log2_returns_zero_for_zero() {
    // log2(0) should return 0 by convention
    assert_eq!(u32::log2(0, rounding::down()), 0);
    assert_eq!(u32::log2(0, rounding::up()), 0);
    assert_eq!(u32::log2(0, rounding::nearest()), 0);
}

#[test]
fun log2_returns_zero_for_one() {
    // log2(1) = 0 since 2^0 = 1
    assert_eq!(u32::log2(1, rounding::down()), 0);
    assert_eq!(u32::log2(1, rounding::up()), 0);
    assert_eq!(u32::log2(1, rounding::nearest()), 0);
}

#[test]
fun log2_handles_powers_of_two() {
    let rounding_modes = vector[rounding::down(), rounding::up(), rounding::nearest()];
    rounding_modes.destroy!(|rounding| {
        // for powers of 2, log2 returns the exponent regardless of rounding mode
        assert_eq!(u32::log2(1 << 0, rounding), 0);
        assert_eq!(u32::log2(1 << 1, rounding), 1);
        assert_eq!(u32::log2(1 << 8, rounding), 8);
        assert_eq!(u32::log2(1 << 16, rounding), 16);
        assert_eq!(u32::log2(1 << 24, rounding), 24);
        assert_eq!(u32::log2(1 << 31, rounding), 31);
    });
}

#[test]
fun log2_rounds_down() {
    // log2 with Down mode truncates to floor
    let down = rounding::down();
    assert_eq!(u32::log2(3, down), 1); // 1.58 → 1
    assert_eq!(u32::log2(5, down), 2); // 2.32 → 2
    assert_eq!(u32::log2(7, down), 2); // 2.81 → 2
    assert_eq!(u32::log2(15, down), 3); // 3.91 → 3
    assert_eq!(u32::log2(255, down), 7); // 7.99 → 7
}

#[test]
fun log2_rounds_up() {
    // log2 with Up mode rounds to ceiling
    let up = rounding::up();
    assert_eq!(u32::log2(3, up), 2); // 1.58 → 2
    assert_eq!(u32::log2(5, up), 3); // 2.32 → 3
    assert_eq!(u32::log2(7, up), 3); // 2.81 → 3
    assert_eq!(u32::log2(15, up), 4); // 3.91 → 4
    assert_eq!(u32::log2(255, up), 8); // 7.99 → 8
}

#[test]
fun log2_rounds_to_nearest() {
    // log2 with Nearest mode rounds to closest integer
    let nearest = rounding::nearest();
    assert_eq!(u32::log2(3, nearest), 2); // 1.58 → 2
    assert_eq!(u32::log2(5, nearest), 2); // 2.32 → 2
    assert_eq!(u32::log2(7, nearest), 3); // 2.81 → 3
    assert_eq!(u32::log2(15, nearest), 4); // 3.91 → 4
    assert_eq!(u32::log2(255, nearest), 8); // 7.99 → 8
}

#[test]
fun log2_handles_values_near_boundaries() {
    // test values just before and at power-of-2 boundaries
    let down = rounding::down();

    // 2^8 - 1 = 255
    assert_eq!(u32::log2((1 << 8) - 1, down), 7);
    // 2^8 = 256
    assert_eq!(u32::log2(1 << 8, down), 8);

    // 2^16 - 1 = 65535
    assert_eq!(u32::log2((1 << 16) - 1, down), 15);
    // 2^16 = 65536
    assert_eq!(u32::log2(1 << 16, down), 16);
}

#[test]
fun log2_handles_max_value() {
    // max value has all bits set, so log2 = 31
    let max = std::u32::max_value!();
    assert_eq!(u32::log2(max, rounding::down()), 31);
    assert_eq!(u32::log2(max, rounding::up()), 32);
    assert_eq!(u32::log2(max, rounding::nearest()), 32);
}

// === log256 ===

#[test]
fun log256_returns_zero_for_zero() {
    // log256(0) should return 0 by convention
    assert_eq!(u32::log256(0, rounding::down()), 0);
    assert_eq!(u32::log256(0, rounding::up()), 0);
    assert_eq!(u32::log256(0, rounding::nearest()), 0);
}

#[test]
fun log256_returns_zero_for_one() {
    // log256(1) = 0 since 256^0 = 1
    assert_eq!(u32::log256(1, rounding::down()), 0);
    assert_eq!(u32::log256(1, rounding::up()), 0);
    assert_eq!(u32::log256(1, rounding::nearest()), 0);
}

#[test]
fun log256_handles_powers_of_256() {
    // Test exact powers of 256
    let rounding_modes = vector[rounding::down(), rounding::up(), rounding::nearest()];
    rounding_modes.destroy!(|rounding| {
        assert_eq!(u32::log256(1 << 8, rounding), 1); // 256^1 = 256
        assert_eq!(u32::log256(1 << 16, rounding), 2); // 256^2 = 65536
        assert_eq!(u32::log256(1 << 24, rounding), 3); // 256^3 = 16777216
    });
}

#[test]
fun log256_rounds_down() {
    // log256 with Down mode truncates to floor
    let down = rounding::down();
    assert_eq!(u32::log256(15, down), 0); // 0.488 → 0
    assert_eq!(u32::log256(16, down), 0); // 0.5 → 0
    assert_eq!(u32::log256(255, down), 0); // 0.999 → 0
    assert_eq!(u32::log256(1 << 8, down), 1); // 1 exactly
    assert_eq!(u32::log256((1 << 8) + 1, down), 1); // 1.001 → 1
    assert_eq!(u32::log256((1 << 16) - 1, down), 1); // 1.9999 → 1
    assert_eq!(u32::log256(1 << 16, down), 2); // 2 exactly
    assert_eq!(u32::log256((1 << 16) + 1, down), 2); // 2.0001 → 2
    assert_eq!(u32::log256((1 << 24) - 1, down), 2); // 2.9999 → 2
    assert_eq!(u32::log256(1 << 24, down), 3); // 3 exactly
}

#[test]
fun log256_rounds_up() {
    // log256 with Up mode rounds to ceiling
    let up = rounding::up();
    assert_eq!(u32::log256(15, up), 1); // 0.488 → 1
    assert_eq!(u32::log256(16, up), 1); // 0.5 → 1
    assert_eq!(u32::log256(255, up), 1); // 0.999 → 1
    assert_eq!(u32::log256(1 << 8, up), 1); // 1 exactly
    assert_eq!(u32::log256((1 << 8) + 1, up), 2); // 1.001 → 2
    assert_eq!(u32::log256((1 << 16) - 1, up), 2); // 1.9999 → 2
    assert_eq!(u32::log256(1 << 16, up), 2); // 2 exactly
    assert_eq!(u32::log256((1 << 16) + 1, up), 3); // 2.0001 → 3
    assert_eq!(u32::log256((1 << 24) - 1, up), 3); // 2.9999 → 3
    assert_eq!(u32::log256(1 << 24, up), 3); // 3 exactly
}

#[test]
fun log256_rounds_to_nearest() {
    // log256 with Nearest mode rounds to closest integer
    // Midpoint between 256^k and 256^(k+1) is 256^k × 16
    let nearest = rounding::nearest();
    // Between 256^0 and 256^1: midpoint is 16
    assert_eq!(u32::log256(15, nearest), 0); // 0.488 < 0.5 → 0
    assert_eq!(u32::log256(16, nearest), 1); // 0.5 → 1
    assert_eq!(u32::log256(255, nearest), 1); // 0.999 → 1
    // Between 256^1 and 256^2: midpoint is 4096
    assert_eq!(u32::log256((1 << 12) - 1, nearest), 1); // 1.4999 < 1.5 → 1
    assert_eq!(u32::log256(1 << 12, nearest), 2); // 1.5 → 2
    assert_eq!(u32::log256((1 << 16) - 1, nearest), 2); // 1.9999 → 2
    // Between 256^2 and 256^3: midpoint is 1048576
    assert_eq!(u32::log256((1 << 20) - 1, nearest), 2); // 2.4999 < 2.5 → 2
    assert_eq!(u32::log256(1 << 20, nearest), 3); // 2.5 → 3
    assert_eq!(u32::log256((1 << 24) - 1, nearest), 3); // 2.9999 → 3
}

#[test]
fun log256_handles_max_value() {
    // max value (4294967295) is less than 256^4 = 4294967296, so log256 is less than 4
    let max = std::u32::max_value!();
    assert_eq!(u32::log256(max, rounding::down()), 3);
    assert_eq!(u32::log256(max, rounding::up()), 4);
    assert_eq!(u32::log256(max, rounding::nearest()), 4);
}

// === log10 ===

#[test]
fun log10_returns_zero_for_zero() {
    // log10(0) should return 0 by convention
    assert_eq!(u32::log10(0, rounding::down()), 0);
    assert_eq!(u32::log10(0, rounding::up()), 0);
    assert_eq!(u32::log10(0, rounding::nearest()), 0);
}

#[test]
fun log10_handles_powers_of_10() {
    // for powers of 10, log10 returns the exponent regardless of rounding mode
    let rounding_modes = vector[rounding::down(), rounding::up(), rounding::nearest()];
    rounding_modes.destroy!(|rounding| {
        assert_eq!(u32::log10(1, rounding), 0); // 10^0
        assert_eq!(u32::log10(10, rounding), 1); // 10^1
        assert_eq!(u32::log10(100, rounding), 2); // 10^2
        assert_eq!(u32::log10(1000, rounding), 3); // 10^3
        assert_eq!(u32::log10(10000, rounding), 4); // 10^4
        assert_eq!(u32::log10(100000, rounding), 5); // 10^5
        assert_eq!(u32::log10(1000000, rounding), 6); // 10^6
        assert_eq!(u32::log10(1000000000, rounding), 9); // 10^9
    });
}

#[test]
fun log10_rounds_down() {
    // log10 with Down mode truncates to floor
    let down = rounding::down();
    assert_eq!(u32::log10(9, down), 0); // ≈ 0.954 → 0
    assert_eq!(u32::log10(99, down), 1); // ≈ 1.996 → 1
    assert_eq!(u32::log10(999, down), 2); // ≈ 2.9996 → 2
    assert_eq!(u32::log10(9999, down), 3); // ≈ 3.9999 → 3
    assert_eq!(u32::log10(4294967295, down), 9); // ≈ 9.633 → 9
}

#[test]
fun log10_rounds_up() {
    // log10 with Up mode rounds to ceiling
    let up = rounding::up();
    assert_eq!(u32::log10(9, up), 1); // ≈ 0.954 → 1
    assert_eq!(u32::log10(99, up), 2); // ≈ 1.996 → 2
    assert_eq!(u32::log10(999, up), 3); // ≈ 2.9996 → 3
    assert_eq!(u32::log10(9999, up), 4); // ≈ 3.9999 → 4
    assert_eq!(u32::log10(4294967295, up), 10); // ≈ 9.633 → 10
}

#[test]
fun log10_rounds_to_nearest() {
    let nearest = rounding::nearest();

    // Between 10^0 and 10^1: midpoint at √10 ≈ 3.162
    assert_eq!(u32::log10(3, nearest), 0); // < 3.162, rounds down
    assert_eq!(u32::log10(4, nearest), 1); // > 3.162, rounds up

    // Between 10^4 and 10^5: midpoint at 10000 × √10 ≈ 31622
    assert_eq!(u32::log10(31622, nearest), 4); // ≈ 31622, rounds down
    assert_eq!(u32::log10(31623, nearest), 5); // > 31622, rounds up
}

#[test]
fun log10_handles_edge_cases_near_powers() {
    // Test values just before and after powers of 10
    let down = rounding::down();
    let up = rounding::up();
    let nearest = rounding::nearest();

    // Around 10^1 = 10
    assert_eq!(u32::log10(9, down), 0);
    assert_eq!(u32::log10(10, down), 1);
    assert_eq!(u32::log10(11, down), 1);

    assert_eq!(u32::log10(9, up), 1);
    assert_eq!(u32::log10(10, up), 1);
    assert_eq!(u32::log10(11, up), 2);

    assert_eq!(u32::log10(9, nearest), 1);
    assert_eq!(u32::log10(10, nearest), 1);
    assert_eq!(u32::log10(11, nearest), 1);

    // Around 10^6 = 1000000
    assert_eq!(u32::log10(999999, down), 5);
    assert_eq!(u32::log10(1000000, down), 6);
    assert_eq!(u32::log10(1000001, down), 6);

    assert_eq!(u32::log10(999999, up), 6);
    assert_eq!(u32::log10(1000000, up), 6);
    assert_eq!(u32::log10(1000001, up), 7);

    assert_eq!(u32::log10(999999, nearest), 6);
    assert_eq!(u32::log10(1000000, nearest), 6);
    assert_eq!(u32::log10(1000001, nearest), 6);
}

#[test]
fun log10_handles_max_value() {
    // max value has log10 ≈ 9.633
    let max = std::u32::max_value!();
    assert_eq!(u32::log10(max, rounding::down()), 9);
    assert_eq!(u32::log10(max, rounding::up()), 10);
    assert_eq!(u32::log10(max, rounding::nearest()), 10);
}

// === sqrt ===

#[test]
fun sqrt_returns_zero_for_zero() {
    // sqrt(0) = 0 by definition
    assert_eq!(u32::sqrt(0, rounding::down()), 0);
    assert_eq!(u32::sqrt(0, rounding::up()), 0);
    assert_eq!(u32::sqrt(0, rounding::nearest()), 0);
}

#[test]
fun sqrt_handles_perfect_squares() {
    // Perfect squares should return exact result regardless of rounding mode
    let rounding_modes = vector[rounding::down(), rounding::up(), rounding::nearest()];
    rounding_modes.destroy!(|rounding| {
        assert_eq!(u32::sqrt(1, rounding), 1);
        assert_eq!(u32::sqrt(4, rounding), 2);
        assert_eq!(u32::sqrt(9, rounding), 3);
        assert_eq!(u32::sqrt(16, rounding), 4);
        assert_eq!(u32::sqrt(100, rounding), 10);
        assert_eq!(u32::sqrt(256, rounding), 16);
        assert_eq!(u32::sqrt(65536, rounding), 256);
        assert_eq!(u32::sqrt(1000000, rounding), 1000);
        assert_eq!(u32::sqrt(4194304, rounding), 2048); // 2048^2 = 4194304
        assert_eq!(u32::sqrt(4294836225, rounding), 65535); // 65535^2 = 4294836225
    });
}

#[test]
fun sqrt_rounds_down() {
    // sqrt with Down mode truncates to floor
    let down = rounding::down();
    assert_eq!(u32::sqrt(2, down), 1); // 1.414 → 1
    assert_eq!(u32::sqrt(3, down), 1); // 1.732 → 1
    assert_eq!(u32::sqrt(5, down), 2); // 2.236 → 2
    assert_eq!(u32::sqrt(8, down), 2); // 2.828 → 2
    assert_eq!(u32::sqrt(99, down), 9); // 9.950 → 9
    assert_eq!(u32::sqrt(10000, down), 100); // 100.0 → 100
    assert_eq!(u32::sqrt(1000000, down), 1000); // 1000.0 → 1000
    assert_eq!(u32::sqrt(4294967295, down), 65535); // 65535.999999 → 65535
}

#[test]
fun sqrt_rounds_up() {
    // sqrt with Up mode rounds to ceiling
    let up = rounding::up();
    assert_eq!(u32::sqrt(2, up), 2); // 1.414 → 2
    assert_eq!(u32::sqrt(3, up), 2); // 1.732 → 2
    assert_eq!(u32::sqrt(5, up), 3); // 2.236 → 3
    assert_eq!(u32::sqrt(8, up), 3); // 2.828 → 3
    assert_eq!(u32::sqrt(99, up), 10); // 9.950 → 10
    assert_eq!(u32::sqrt(10001, up), 101); // 100.005 → 101
    assert_eq!(u32::sqrt(1000001, up), 1001); // 1000.0005 → 1001
    assert_eq!(u32::sqrt(4294967295, up), 65536); // 65535.999999 → 65536
}

#[test]
fun sqrt_rounds_to_nearest() {
    // sqrt with Nearest mode rounds to closest integer
    let nearest = rounding::nearest();
    assert_eq!(u32::sqrt(2, nearest), 1); // 1.414 → 1
    assert_eq!(u32::sqrt(3, nearest), 2); // 1.732 → 2
    assert_eq!(u32::sqrt(5, nearest), 2); // 2.236 → 2
    assert_eq!(u32::sqrt(7, nearest), 3); // 2.646 → 3
    assert_eq!(u32::sqrt(99, nearest), 10); // 9.950 → 10
    assert_eq!(u32::sqrt(10000, nearest), 100); // 100.0 → 100
    assert_eq!(u32::sqrt(1002000, nearest), 1001); // 1000.999 → 1001
    assert_eq!(u32::sqrt(4294967295, nearest), 65536); // 65535.999999 → 65536
}

#[test]
fun sqrt_handles_powers_of_four() {
    // Powers of 4 (perfect squares of powers of 2)
    let rounding_modes = vector[rounding::down(), rounding::up(), rounding::nearest()];
    rounding_modes.destroy!(|rounding| {
        assert_eq!(u32::sqrt(1, rounding), 1);
        assert_eq!(u32::sqrt(4, rounding), 2);
        assert_eq!(u32::sqrt(16, rounding), 4);
        assert_eq!(u32::sqrt(64, rounding), 8);
        assert_eq!(u32::sqrt(256, rounding), 16);
        assert_eq!(u32::sqrt(1024, rounding), 32);
        assert_eq!(u32::sqrt(4096, rounding), 64);
        assert_eq!(u32::sqrt(65536, rounding), 256);
        assert_eq!(u32::sqrt(1 << 20, rounding), 1024);
        assert_eq!(u32::sqrt(1 << 30, rounding), 1 << 15);
    });
}

#[test]
fun sqrt_midpoint_behavior() {
    // Test values exactly between two perfect squares
    let nearest = rounding::nearest();
    assert_eq!(u32::sqrt(5, nearest), 2); // 2.236, closer to 2
    assert_eq!(u32::sqrt(6, nearest), 2); // 2.449, closer to 2
    assert_eq!(u32::sqrt(7, nearest), 3); // 2.646, closer to 3
    assert_eq!(u32::sqrt(8, nearest), 3); // 2.828, closer to 3

    // Between 9 (3^2) and 16 (4^2): midpoint at 12.5
    assert_eq!(u32::sqrt(12, nearest), 3); // 3.464, closer to 3
    assert_eq!(u32::sqrt(13, nearest), 4); // 3.606, closer to 4
}

#[test]
fun sqrt_handles_max_value() {
    let max = std::u32::max_value!();
    assert_eq!(u32::sqrt(max, rounding::down()), 65535);
    assert_eq!(u32::sqrt(max, rounding::up()), 65536);
    assert_eq!(u32::sqrt(max, rounding::nearest()), 65536);
}

// === inv_mod ===

#[test]
fun inv_mod_returns_some() {
    let result = u32::inv_mod(1_234_567, 1_000_003);
    assert_eq!(result, option::some(678_286));
}

#[test]
fun inv_mod_returns_none_when_not_coprime() {
    let result = u32::inv_mod(100, 250);
    assert_eq!(result, option::none());
}

#[test, expected_failure(abort_code = macros::EZeroModulus)]
fun inv_mod_rejects_zero_modulus() {
    u32::inv_mod(1, 0);
}

// === mul_mod ===

#[test]
fun mul_mod_handles_large_values() {
    let result = u32::mul_mod(123_456_789, 400_000_001, 1_000_000_007);
    assert_eq!(result, 377_777_784);
}

#[test, expected_failure(abort_code = macros::EZeroModulus)]
fun mul_mod_rejects_zero_modulus() {
    u32::mul_mod(10, 10, 0);
}

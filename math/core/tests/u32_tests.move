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
    let (down_overflow, down) = u32::mul_div(70, 10, 4, rounding::down());
    assert_eq!(down_overflow, false);
    assert_eq!(down, 175);

    let (up_overflow, up) = u32::mul_div(5, 3, 4, rounding::up());
    assert_eq!(up_overflow, false);
    assert_eq!(up, 4);

    let (nearest_overflow, nearest) = u32::mul_div(
        7,
        10,
        4,
        rounding::nearest(),
    );
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
    let (overflow, result) = u32::mul_div(
        std::u32::max_value!(),
        2,
        1,
        rounding::down(),
    );
    assert_eq!(overflow, true);
    assert_eq!(result, 0);
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

// === from_u256 ===

#[test]
fun ai_from_u256_downcasts_zero() {
    let result = u32::from_u256(0u256);
    assert_eq!(result, 0u32);
}

#[test]
fun ai_from_u256_downcasts_one() {
    let result = u32::from_u256(1u256);
    assert_eq!(result, 1u32);
}

#[test]
fun ai_from_u256_downcasts_max_value() {
    let max_value = std::u32::max_value!() as u256;
    let result = u32::from_u256(max_value);
    assert_eq!(result, std::u32::max_value!());
}

#[test, expected_failure(abort_code = u32::ESafeCastOverflowedIntDowncast)]
fun ai_from_u256_reverts_when_downcasting_2_to_32() {
    // 2^32 = 4294967296, which exceeds u32 max value (4294967295)
    let overflow_value = 4294967296u256;
    let _unused = u32::from_u256(overflow_value);
}

#[test, expected_failure(abort_code = u32::ESafeCastOverflowedIntDowncast)]
fun ai_from_u256_reverts_when_downcasting_2_to_32_plus_1() {
    // 2^32 + 1 = 4294967297, which exceeds u32 max value (4294967295)
    let overflow_value = 4294967297u256;
    let _unused = u32::from_u256(overflow_value);
}

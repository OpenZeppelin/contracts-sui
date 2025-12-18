#[test_only]
module openzeppelin_math::u256_tests;

use openzeppelin_math::macros;
use openzeppelin_math::rounding;
use openzeppelin_math::u256;
use openzeppelin_math::u512;
use std::unit_test::assert_eq;

// === average ===

#[test]
fun average_rounding_modes() {
    let down = u256::average(4, 7, rounding::down());
    assert_eq!(down, 5);

    let up = u256::average(4, 7, rounding::up());
    assert_eq!(up, 6);

    let nearest = u256::average(1, 2, rounding::nearest());
    assert_eq!(nearest, 2);
}

#[test]
fun average_is_commutative() {
    let left = u256::average(std::u256::max_value!(), 0, rounding::nearest());
    let right = u256::average(0, std::u256::max_value!(), rounding::nearest());
    assert_eq!(left, right);
}

// === checked_shl ===

#[test]
fun checked_shl_returns_some() {
    // Shift to the top bit while staying within range.
    let value: u256 = 1;
    let result = u256::checked_shl(value, 255);
    assert_eq!(result, option::some(1u256 << 255));
}

#[test]
fun checked_shl_zero_input_returns_zero() {
    assert_eq!(u256::checked_shl(0, 120), option::some(0));
}

#[test]
fun checked_shl_returns_same_for_zero_shift() {
    // Shifting by zero should return the same value.
    let value = 1u256 << 255;
    let result = u256::checked_shl(value, 0);
    assert_eq!(result, option::some(value));
}

#[test]
fun checked_shl_detects_high_bits() {
    // Highest bit already set — shifting again should fail.
    let result = u256::checked_shl(1u256 << 255, 1);
    assert_eq!(result, option::none());
}

#[test]
fun checked_shl_rejects_large_shift() {
    // Disallow shifting when the value would overflow after a large shift.
    let result = u256::checked_shl(2, 255);
    assert_eq!(result, option::none());
}

// === checked_shr ===

#[test]
fun checked_shr_returns_some() {
    // Shift a high limb filled with zeros: 1 << 200 >> 200 == 1.
    let value = 1u256 << 200;
    let result = u256::checked_shr(value, 200);
    assert_eq!(result, option::some(1));
}

#[test]
fun checked_shr_zero_input_returns_zero() {
    assert_eq!(u256::checked_shr(0, 120), option::some(0));
}

#[test]
fun checked_shr_handles_top_bit() {
    // The very top bit (1 << 255) can move to the least-significant position.
    let value = 1u256 << 255;
    let result = u256::checked_shr(value, 255);
    assert_eq!(result, option::some(1));
}

#[test]
fun checked_shr_detects_set_bits() {
    // LSB set — shifting by one would drop it.
    let result = u256::checked_shr(5, 1);
    assert_eq!(result, option::none());
}

#[test]
fun checked_shr_detects_large_shift_loss() {
    // Reject when shifting by 255 would drop non-zero bits.
    let value = 3u256 << 254;
    let result = u256::checked_shr(value, 255);
    assert_eq!(result, option::none());
}

// === mul_div ===

// At the top level, the wrapper should mirror the macro's behaviour.
#[test]
fun mul_div_rounding_modes() {
    let down = u256::mul_div(70, 10, 4, rounding::down());
    assert_eq!(down, option::some(175));

    let up = u256::mul_div(5, 3, 4, rounding::up());
    assert_eq!(up, option::some(4));

    let nearest = u256::mul_div(
        7,
        10,
        4,
        rounding::nearest(),
    );
    assert_eq!(nearest, option::some(18));
}

// Verify the wrapper delegates to the wide path when required.
#[test]
fun mul_div_handles_wide_operands() {
    let large = (std::u128::max_value!() as u256) + 1;
    let result = u256::mul_div(
        large,
        large,
        7,
        rounding::down(),
    );
    let (wide_overflow, expected) = macros::mul_div_u256_wide(
        large,
        large,
        7,
        rounding::down(),
    );
    assert_eq!(wide_overflow, false);
    assert_eq!(result, option::some(expected));
}

// Division-by-zero guard enforced at the macro layer.
#[test, expected_failure(abort_code = macros::EDivideByZero)]
fun mul_div_rejects_zero_denominator() {
    u256::mul_div(1, 1, 0, rounding::down());
}

// Even u256 should flag when the macro's output overflows 256 bits.
#[test]
fun mul_div_detects_overflow() {
    let max = std::u256::max_value!();
    let result = u256::mul_div(
        max,
        max,
        1,
        rounding::down(),
    );
    assert_eq!(result, option::none());
}

// === mul_shr ===

#[test]
fun mul_shr_returns_some_when_in_range() {
    let result = u256::mul_shr(6, 4, 1, rounding::down());
    assert_eq!(result, option::some(12));
}

#[test]
fun mul_shr_respects_rounding_modes() {
    // 5*3 = 15; 15 >> 1 = 7.5
    let down = u256::mul_shr(5, 3, 1, rounding::down());
    assert_eq!(down, option::some(7));

    let up = u256::mul_shr(5, 3, 1, rounding::up());
    assert_eq!(up, option::some(8));

    let nearest = u256::mul_shr(5, 3, 1, rounding::nearest());
    assert_eq!(nearest, option::some(8));

    // 7*4 = 28; 28 >> 2 = 7.0
    let exact = u256::mul_shr(7, 4, 2, rounding::nearest());
    assert_eq!(exact, option::some(7));

    // 13*3 = 39; 39 >> 2 = 9.75
    let down2 = u256::mul_shr(13, 3, 2, rounding::down());
    assert_eq!(down2, option::some(9));

    let up2 = u256::mul_shr(13, 3, 2, rounding::up());
    assert_eq!(up2, option::some(10));

    let nearest2 = u256::mul_shr(13, 3, 2, rounding::nearest());
    assert_eq!(nearest2, option::some(10));

    // 7*3 = 21; 21 >> 2 = 5.25
    let down3 = u256::mul_shr(7, 3, 2, rounding::down());
    assert_eq!(down3, option::some(5));

    let up3 = u256::mul_shr(7, 3, 2, rounding::up());
    assert_eq!(up3, option::some(6));

    let nearest3 = u256::mul_shr(7, 3, 2, rounding::nearest());
    assert_eq!(nearest3, option::some(5));
}

#[test]
fun mul_shr_handles_large_operands() {
    let large = std::u256::max_value!();
    let result = u256::mul_shr(large, 16, 4, rounding::down());
    assert_eq!(result, option::some(large));
}

#[test]
fun mul_shr_detects_overflow() {
    let overflow = u256::mul_shr(
        std::u256::max_value!(),
        std::u256::max_value!(),
        0,
        rounding::down(),
    );
    assert_eq!(overflow, option::none());
}

// === clz ===

#[test]
fun clz_returns_bit_width_for_zero() {
    // clz(0) should return 256 (all bits are leading zeros).
    let result = u256::clz(0);
    assert_eq!(result, 256);
}

#[test]
fun clz_returns_zero_for_top_bit_set() {
    // when the most significant bit is set, there are no leading zeros.
    let value = 1u256 << 255;
    let result = u256::clz(value);
    assert_eq!(result, 0);
}

#[test]
fun clz_returns_zero_for_max_value() {
    // max value has the top bit set, so no leading zeros.
    let max = std::u256::max_value!();
    let result = u256::clz(max);
    assert_eq!(result, 0);
}

// Test all possible bit positions from 0 to 255.
#[test]
fun clz_handles_all_bit_positions() {
    256u16.do!(|bit_pos| {
        let value = 1u256 << (bit_pos as u8);
        let expected_clz = 255 - (bit_pos as u8);
        assert_eq!(u256::clz(value), expected_clz as u16);
    });
}

// Test that lower bits have no effect on the result.
#[test]
fun clz_lower_bits_have_no_effect() {
    256u16.do!(|bit_pos| {
        let mut value = 1u256 << (bit_pos as u8);
        // set all bits below bit_pos to 1
        value = value | (value - 1);
        let expected_clz = 255 - (bit_pos as u8);
        assert_eq!(u256::clz(value), expected_clz as u16);
    });
}

#[test]
fun clz_counts_from_highest_bit() {
    // when multiple bits are set, clz counts from the highest bit.
    // 0b11 (bits 0 and 1 set) - highest is bit 1, so clz = 254
    assert_eq!(u256::clz(3), 254);

    // 0b1111 (bits 0-3 set) - highest is bit 3, so clz = 252
    assert_eq!(u256::clz(15), 252);

    // 0xff (bits 0-7 set) - highest is bit 7, so clz = 248
    assert_eq!(u256::clz(255), 248);
}

// Test values near power-of-2 boundaries.
#[test]
fun clz_handles_values_near_boundaries() {
    // 0x100 (256) has bit 8 set, clz = 247
    assert_eq!(u256::clz(1 << 8), 247);

    // 0xff (255) has bit 7 set, clz = 248
    assert_eq!(u256::clz((1 << 8) - 1), 248);

    // 0x1_0000 (65536) has bit 16 set, clz = 239
    assert_eq!(u256::clz(1 << 16), 239);

    // 0xffff (65535) has bit 15 set, clz = 240
    assert_eq!(u256::clz((1 << 16) - 1), 240);

    // 0x1_0000_0000_0000_0000 (2^64) has bit 64 set, clz = 191
    assert_eq!(u256::clz(1 << 64), 191);

    // 0xffff_ffff_ffff_ffff (2^64 - 1) has bit 63 set, clz = 192
    assert_eq!(u256::clz((1 << 64) - 1), 192);
}

// === msb ===

#[test]
fun msb_returns_zero_for_zero() {
    // msb(0) should return 0 by convention
    let result = u256::msb(0);
    assert_eq!(result, 0);
}

#[test]
fun msb_returns_correct_position_for_top_bit_set() {
    // when the most significant bit is set, msb returns 255
    let value = 1u256 << 255;
    let result = u256::msb(value);
    assert_eq!(result, 255);
}

#[test]
fun msb_returns_correct_position_for_max_value() {
    // max value has the top bit set, so msb returns 255
    let max = std::u256::max_value!();
    let result = u256::msb(max);
    assert_eq!(result, 255);
}

// Test all possible bit positions from 0 to 255.
#[test]
fun msb_handles_all_bit_positions() {
    256u16.do!(|bit_pos| {
        let value = 1u256 << (bit_pos as u8);
        assert_eq!(u256::msb(value), bit_pos as u8);
    });
}

// Test that lower bits have no effect on the result.
#[test]
fun msb_lower_bits_have_no_effect() {
    256u16.do!(|bit_pos| {
        let mut value = 1u256 << (bit_pos as u8);
        // set all bits below bit_pos to 1
        value = value | (value - 1);
        assert_eq!(u256::msb(value), bit_pos as u8);
    });
}

#[test]
fun msb_returns_highest_bit_position() {
    // when multiple bits are set, msb returns the position of the highest bit.
    // 0b11 (bits 0 and 1 set) - highest is bit 1, so msb = 1
    assert_eq!(u256::msb(3), 1);

    // 0b1111 (bits 0-3 set) - highest is bit 3, so msb = 3
    assert_eq!(u256::msb(15), 3);

    // 0xff (bits 0-7 set) - highest is bit 7, so msb = 7
    assert_eq!(u256::msb(255), 7);
}

// Test values near power-of-2 boundaries.
#[test]
fun msb_handles_values_near_boundaries() {
    // 0x100 (256) has bit 8 set, msb = 8
    assert_eq!(u256::msb(1 << 8), 8);

    // 0xff (255) has bit 7 set, msb = 7
    assert_eq!(u256::msb((1 << 8) - 1), 7);

    // 0x1_0000 (65536) has bit 16 set, msb = 16
    assert_eq!(u256::msb(1 << 16), 16);

    // 0xffff (65535) has bit 15 set, msb = 15
    assert_eq!(u256::msb((1 << 16) - 1), 15);

    // 0x1_0000_0000_0000_0000 (2^64) has bit 64 set, msb = 64
    assert_eq!(u256::msb(1 << 64), 64);

    // 0xffff_ffff_ffff_ffff (2^64 - 1) has bit 63 set, msb = 63
    assert_eq!(u256::msb((1 << 64) - 1), 63);
}

// === log2 ===

#[test]
fun log2_returns_zero_for_zero() {
    // log2(0) should return 0 by convention
    assert_eq!(u256::log2(0, rounding::down()), 0);
    assert_eq!(u256::log2(0, rounding::up()), 0);
    assert_eq!(u256::log2(0, rounding::nearest()), 0);
}

#[test]
fun log2_returns_zero_for_one() {
    // log2(1) = 0 since 2^0 = 1
    assert_eq!(u256::log2(1, rounding::down()), 0);
    assert_eq!(u256::log2(1, rounding::up()), 0);
    assert_eq!(u256::log2(1, rounding::nearest()), 0);
}

#[test]
fun log2_handles_powers_of_two() {
    let rounding_modes = vector[rounding::down(), rounding::up(), rounding::nearest()];
    rounding_modes.destroy!(|rounding| {
        // for powers of 2, log2 returns the exponent regardless of rounding mode
        assert_eq!(u256::log2(1 << 0, rounding), 0);
        assert_eq!(u256::log2(1 << 1, rounding), 1);
        assert_eq!(u256::log2(1 << 7, rounding), 7);
        assert_eq!(u256::log2(1 << 8, rounding), 8);
        assert_eq!(u256::log2(1 << 16, rounding), 16);
        assert_eq!(u256::log2(1 << 63, rounding), 63);
        assert_eq!(u256::log2(1 << 64, rounding), 64);
        assert_eq!(u256::log2(1 << 127, rounding), 127);
        assert_eq!(u256::log2(1 << 128, rounding), 128);
        assert_eq!(u256::log2(1 << 255, rounding), 255);
    });
}

#[test]
fun log2_rounds_down() {
    // log2 with Down mode truncates to floor
    let down = rounding::down();
    assert_eq!(u256::log2(3, down), 1); // 1.58 → 1
    assert_eq!(u256::log2(5, down), 2); // 2.32 → 2
    assert_eq!(u256::log2(7, down), 2); // 2.81 → 2
    assert_eq!(u256::log2(15, down), 3); // 3.91 → 3
    assert_eq!(u256::log2(255, down), 7); // 7.99 → 7
}

#[test]
fun log2_rounds_up() {
    // log2 with Up mode rounds to ceiling
    let up = rounding::up();
    assert_eq!(u256::log2(3, up), 2); // 1.58 → 2
    assert_eq!(u256::log2(5, up), 3); // 2.32 → 3
    assert_eq!(u256::log2(7, up), 3); // 2.81 → 3
    assert_eq!(u256::log2(15, up), 4); // 3.91 → 4
    assert_eq!(u256::log2(255, up), 8); // 7.99 → 8
}

#[test]
fun log2_rounds_to_nearest() {
    // log2 with Nearest mode rounds to closest integer
    let nearest = rounding::nearest();
    assert_eq!(u256::log2(3, nearest), 2); // 1.58 → 2
    assert_eq!(u256::log2(5, nearest), 2); // 2.32 → 2
    assert_eq!(u256::log2(7, nearest), 3); // 2.81 → 3
    assert_eq!(u256::log2(15, nearest), 4); // 3.91 → 4
    assert_eq!(u256::log2(255, nearest), 8); // 7.99 → 8
}

#[test]
fun log2_handles_values_near_boundaries() {
    // test values just before and at power-of-2 boundaries
    let down = rounding::down();

    // 2^8 - 1 = 255
    assert_eq!(u256::log2((1 << 8) - 1, down), 7);
    // 2^8 = 256
    assert_eq!(u256::log2(1 << 8, down), 8);

    // 2^16 - 1 = 65535
    assert_eq!(u256::log2((1 << 16) - 1, down), 15);
    // 2^16 = 65536
    assert_eq!(u256::log2(1 << 16, down), 16);

    // 2^64 - 1
    assert_eq!(u256::log2((1 << 64) - 1, down), 63);
    // 2^64
    assert_eq!(u256::log2(1 << 64, down), 64);
}

#[test]
fun log2_rounding_mode_nearest_high_values() {
    let val_1 = 0xB504F261779BF7325BF8F7DB0AAFE8F8227AE7E69797296F9526CCD8BBF32000u256;
    assert_eq!(u256::log2(val_1, rounding::nearest()), 255); // 255.4999 -> 255
    let val_2 = 0xB504FB6D10AAFE26CC0E4F709AB10D92CEBF3593218E22304000000000000000u256;
    assert_eq!(u256::log2(val_2, rounding::nearest()), 256); // 255.500001 -> 256
}

#[test]
fun log2_handles_max_value() {
    // max value has all bits set, so log2 = 255
    let max = std::u256::max_value!();
    assert_eq!(u256::log2(max, rounding::down()), 255);
    assert_eq!(u256::log2(max, rounding::up()), 256);
    assert_eq!(u256::log2(max, rounding::nearest()), 256);
}

// === log256 ===

#[test]
fun log256_returns_zero_for_zero() {
    // log256(0) should return 0 by convention
    assert_eq!(u256::log256(0, rounding::down()), 0);
    assert_eq!(u256::log256(0, rounding::up()), 0);
    assert_eq!(u256::log256(0, rounding::nearest()), 0);
}

#[test]
fun log256_returns_zero_for_one() {
    // log256(1) = 0 since 256^0 = 1
    assert_eq!(u256::log256(1, rounding::down()), 0);
    assert_eq!(u256::log256(1, rounding::up()), 0);
    assert_eq!(u256::log256(1, rounding::nearest()), 0);
}

#[test]
fun log256_handles_powers_of_256() {
    // Test exact powers of 256
    let rounding_modes = vector[rounding::down(), rounding::up(), rounding::nearest()];
    rounding_modes.destroy!(|rounding| {
        assert_eq!(u256::log256(1 << 8, rounding), 1);
        assert_eq!(u256::log256(1 << 16, rounding), 2);
        assert_eq!(u256::log256(1 << 24, rounding), 3);
        assert_eq!(u256::log256(1 << 32, rounding), 4);
        assert_eq!(u256::log256(1 << 64, rounding), 8);
        assert_eq!(u256::log256(1 << 128, rounding), 16);
        assert_eq!(u256::log256(1 << 248, rounding), 31);
    });
}

#[test]
fun log256_rounds_down() {
    // log256 with Down mode truncates to floor
    let down = rounding::down();
    assert_eq!(u256::log256(15, down), 0); // 0.488 → 0
    assert_eq!(u256::log256(16, down), 0); // 0.5 → 0
    assert_eq!(u256::log256(255, down), 0); // 0.999 → 0
    assert_eq!(u256::log256(1 << 8, down), 1); // 1 exactly
    assert_eq!(u256::log256((1 << 8) + 1, down), 1); // 1.001 → 1
    assert_eq!(u256::log256((1 << 16) - 1, down), 1); // 1.9999 → 1
    assert_eq!(u256::log256(1 << 16, down), 2); // 2 exactly
    assert_eq!(u256::log256((1 << 128) - 1, down), 15); // 15.9999 → 15
    assert_eq!(u256::log256(1 << 128, down), 16); // 16 exactly
    assert_eq!(u256::log256((1 << 248) - 1, down), 30); // 30.9999 → 30
    assert_eq!(u256::log256(1 << 248, down), 31); // 31 exactly
}

#[test]
fun log256_rounds_up() {
    // log256 with Up mode rounds to ceiling
    let up = rounding::up();
    assert_eq!(u256::log256(15, up), 1); // 0.488 → 1
    assert_eq!(u256::log256(16, up), 1); // 0.5 → 1
    assert_eq!(u256::log256(255, up), 1); // 0.999 → 1
    assert_eq!(u256::log256(1 << 8, up), 1); // 1 exactly
    assert_eq!(u256::log256((1 << 8) + 1, up), 2); // 1.001 → 2
    assert_eq!(u256::log256((1 << 16) - 1, up), 2); // 1.9999 → 2
    assert_eq!(u256::log256(1 << 16, up), 2); // 2 exactly
    assert_eq!(u256::log256((1 << 128) - 1, up), 16); // 15.9999 → 16
    assert_eq!(u256::log256(1 << 128, up), 16); // 16 exactly
    assert_eq!(u256::log256((1 << 248) - 1, up), 31); // 30.9999 → 31
    assert_eq!(u256::log256(1 << 248, up), 31); // 31 exactly
}

#[test]
fun log256_rounds_to_nearest() {
    // log256 with Nearest mode rounds to closest integer
    // Midpoint between 256^k and 256^(k+1) is 256^k × 16
    let nearest = rounding::nearest();
    // Between 256^0 and 256^1: midpoint is 16
    assert_eq!(u256::log256(15, nearest), 0); // 0.488 < 0.5 → 0
    assert_eq!(u256::log256(16, nearest), 1); // 0.5 → 1
    assert_eq!(u256::log256(255, nearest), 1); // 0.999 → 1
    // Between 256^1 and 256^2: midpoint is 4096
    assert_eq!(u256::log256((1 << 12) - 1, nearest), 1); // 1.4999 < 1.5 → 1
    assert_eq!(u256::log256(1 << 12, nearest), 2); // 1.5 → 2
    assert_eq!(u256::log256((1 << 16) - 1, nearest), 2); // 1.9999 → 2
    // Between 256^15 and 256^16: midpoint is 1 << 124
    assert_eq!(u256::log256((1 << 124) - 1, nearest), 15); // 15.4999 < 15.5 → 15
    assert_eq!(u256::log256(1 << 124, nearest), 16); // 15.5 → 16
    assert_eq!(u256::log256((1 << 128) - 1, nearest), 16); // 15.9999 → 16
}

#[test]
fun log256_handles_max_value() {
    // max value is less than 256^32 = 2^256, so log256 is less than 32
    let max = std::u256::max_value!();
    assert_eq!(u256::log256(max, rounding::down()), 31);
    assert_eq!(u256::log256(max, rounding::up()), 32);
    assert_eq!(u256::log256(max, rounding::nearest()), 32);
}

// === log10 ===

#[test]
fun log10_returns_zero_for_zero() {
    // log10(0) should return 0 by convention
    assert_eq!(u256::log10(0, rounding::down()), 0);
    assert_eq!(u256::log10(0, rounding::up()), 0);
    assert_eq!(u256::log10(0, rounding::nearest()), 0);
}

#[test]
fun log10_handles_powers_of_10() {
    // for powers of 10, log10 returns the exponent regardless of rounding mode
    let rounding_modes = vector[rounding::down(), rounding::up(), rounding::nearest()];
    rounding_modes.destroy!(|rounding| {
        assert_eq!(u256::log10(1, rounding), 0); // 10^0
        assert_eq!(u256::log10(10, rounding), 1); // 10^1
        assert_eq!(u256::log10(100, rounding), 2); // 10^2
        assert_eq!(u256::log10(1000, rounding), 3); // 10^3
        assert_eq!(u256::log10(std::u256::pow(10, 38), rounding), 38); // 10^38
        assert_eq!(u256::log10(std::u256::pow(10, 44), rounding), 44); // 10^44
    });
}

#[test]
fun log10_rounds_down() {
    // log10 with Down mode truncates to floor
    let down = rounding::down();
    assert_eq!(u256::log10(9, down), 0); // ≈ 0.954 → 0
    assert_eq!(u256::log10(99, down), 1); // ≈ 1.996 → 1
    assert_eq!(u256::log10(999, down), 2); // ≈ 2.9996 → 2
    assert_eq!(u256::log10(9999, down), 3); // ≈ 3.9999 → 3
}

#[test]
fun log10_rounds_up() {
    // log10 with Up mode rounds to ceiling
    let up = rounding::up();
    assert_eq!(u256::log10(9, up), 1); // ≈ 0.954 → 1
    assert_eq!(u256::log10(99, up), 2); // ≈ 1.996 → 2
    assert_eq!(u256::log10(999, up), 3); // ≈ 2.9996 → 3
    assert_eq!(u256::log10(9999, up), 4); // ≈ 3.9999 → 4
}

#[test]
fun log10_rounds_to_nearest() {
    let nearest = rounding::nearest();

    // Between 10^0 and 10^1: midpoint at √10 ≈ 3.162
    assert_eq!(u256::log10(3, nearest), 0); // < 3.162, rounds down
    assert_eq!(u256::log10(4, nearest), 1); // > 3.162, rounds up

    // Between 10^1 and 10^2: midpoint at 10 × √10 ≈ 31.62
    assert_eq!(u256::log10(31, nearest), 1); // < 31.62, rounds down
    assert_eq!(u256::log10(32, nearest), 2); // > 31.62, rounds up
}

#[test]
fun log10_handles_edge_cases_near_powers() {
    // Test values just before and after powers of 10
    let down = rounding::down();
    let up = rounding::up();
    let nearest = rounding::nearest();

    // Around 10^1 = 10
    assert_eq!(u256::log10(9, down), 0);
    assert_eq!(u256::log10(10, down), 1);
    assert_eq!(u256::log10(11, down), 1);

    assert_eq!(u256::log10(9, up), 1);
    assert_eq!(u256::log10(10, up), 1);
    assert_eq!(u256::log10(11, up), 2);

    assert_eq!(u256::log10(9, nearest), 1);
    assert_eq!(u256::log10(10, nearest), 1);
    assert_eq!(u256::log10(11, nearest), 1);

    // Around 10^38
    let pow38 = std::u256::pow(10, 38);
    assert_eq!(u256::log10(pow38 - 1, down), 37);
    assert_eq!(u256::log10(pow38, down), 38);
    assert_eq!(u256::log10(pow38 + 1, down), 38);

    assert_eq!(u256::log10(pow38 - 1, up), 38);
    assert_eq!(u256::log10(pow38, up), 38);
    assert_eq!(u256::log10(pow38 + 1, up), 39);

    assert_eq!(u256::log10(pow38 - 1, nearest), 38);
    assert_eq!(u256::log10(pow38, nearest), 38);
    assert_eq!(u256::log10(pow38 + 1, nearest), 38);
}

#[test]
fun log10_handles_max_value() {
    // max value has log10 ≈ 77.064
    let max = std::u256::max_value!();
    assert_eq!(u256::log10(max, rounding::down()), 77);
    assert_eq!(u256::log10(max, rounding::up()), 78);
    assert_eq!(u256::log10(max, rounding::nearest()), 77);
}

#[test]
fun log10_large_values() {
    // Test with very large u256 values that require u512 arithmetic
    let up = rounding::up();
    let down = rounding::down();
    let nearest = rounding::nearest();

    // 10^38 is around the threshold for the fast/slow path
    let value = std::u256::pow(10, 38) + 1;
    assert_eq!(u256::log10(value, up), 39);
    assert_eq!(u256::log10(value, down), 38);
    assert_eq!(u256::log10(value, nearest), 38);

    // Test larger values that require u512 arithmetic
    let value = std::u256::pow(10, 77) + 1; // 10^77 + 1
    assert_eq!(u256::log10(value, up), 78);
    assert_eq!(u256::log10(value, down), 77);
    assert_eq!(u256::log10(value, nearest), 77);
}

// === sqrt ===

#[test]
fun sqrt_returns_zero_for_zero() {
    // sqrt(0) = 0 by definition
    assert_eq!(u256::sqrt(0, rounding::down()), 0);
    assert_eq!(u256::sqrt(0, rounding::up()), 0);
    assert_eq!(u256::sqrt(0, rounding::nearest()), 0);
}

#[test]
fun sqrt_handles_perfect_squares() {
    // Perfect squares should return exact result regardless of rounding mode
    let rounding_modes = vector[rounding::down(), rounding::up(), rounding::nearest()];
    rounding_modes.destroy!(|rounding| {
        assert_eq!(u256::sqrt(1, rounding), 1);
        assert_eq!(u256::sqrt(4, rounding), 2);
        assert_eq!(u256::sqrt(9, rounding), 3);
        assert_eq!(u256::sqrt(16, rounding), 4);
        assert_eq!(u256::sqrt(100, rounding), 10);
        assert_eq!(u256::sqrt(65536, rounding), 256);
        assert_eq!(u256::sqrt(1 << 64, rounding), 1 << 32);
        assert_eq!(u256::sqrt(1 << 128, rounding), 1 << 64);
        assert_eq!(u256::sqrt(1 << 254, rounding), 1 << 127); // (2^127)^2 = 2^254
    });
}

#[test]
fun sqrt_rounds_down() {
    // sqrt with Down mode truncates to floor
    let down = rounding::down();
    assert_eq!(u256::sqrt(2, down), 1); // 1.414 → 1
    assert_eq!(u256::sqrt(3, down), 1); // 1.732 → 1
    assert_eq!(u256::sqrt(5, down), 2); // 2.236 → 2
    assert_eq!(u256::sqrt(99, down), 9); // 9.950 → 9
    assert_eq!(u256::sqrt(1000000, down), 1000);
    assert_eq!(u256::sqrt(1 << 128, down), 1 << 64);
    assert_eq!(u256::sqrt(std::u256::max_value!(), down), std::u128::max_value!() as u256);
}

#[test]
fun sqrt_rounds_up() {
    // sqrt with Up mode rounds to ceiling
    let up = rounding::up();
    assert_eq!(u256::sqrt(2, up), 2); // 1.414 → 2
    assert_eq!(u256::sqrt(3, up), 2); // 1.732 → 2
    assert_eq!(u256::sqrt(5, up), 3); // 2.236 → 3
    assert_eq!(u256::sqrt(99, up), 10); // 9.950 → 10
    assert_eq!(u256::sqrt(1000001, up), 1001);
    assert_eq!(u256::sqrt((1 << 128) + 1, up), (1 << 64) + 1);
    assert_eq!(u256::sqrt(std::u256::max_value!(), up), (std::u128::max_value!() as u256) + 1);
}

#[test]
fun sqrt_rounds_to_nearest() {
    // sqrt with Nearest mode rounds to closest integer
    let nearest = rounding::nearest();
    assert_eq!(u256::sqrt(2, nearest), 1); // 1.414 → 1
    assert_eq!(u256::sqrt(3, nearest), 2); // 1.732 → 2
    assert_eq!(u256::sqrt(5, nearest), 2); // 2.236 → 2
    assert_eq!(u256::sqrt(7, nearest), 3); // 2.646 → 3
    assert_eq!(u256::sqrt(99, nearest), 10); // 9.950 → 10
    assert_eq!(u256::sqrt(1002000, nearest), 1001);
    assert_eq!(u256::sqrt(std::u256::max_value!(), nearest), (std::u128::max_value!() as u256) + 1); // sqrt(u256::MAX) = 2^128
}

#[test]
fun sqrt_handles_powers_of_four() {
    // Powers of 4 (perfect squares of powers of 2)
    let rounding_modes = vector[rounding::down(), rounding::up(), rounding::nearest()];
    rounding_modes.destroy!(|rounding| {
        assert_eq!(u256::sqrt(1, rounding), 1);
        assert_eq!(u256::sqrt(4, rounding), 2);
        assert_eq!(u256::sqrt(16, rounding), 4);
        assert_eq!(u256::sqrt(64, rounding), 8);
        assert_eq!(u256::sqrt(256, rounding), 16);
        assert_eq!(u256::sqrt(1 << 20, rounding), 1024);
        assert_eq!(u256::sqrt(1 << 64, rounding), 1 << 32);
        assert_eq!(u256::sqrt(1 << 128, rounding), 1 << 64);
        assert_eq!(u256::sqrt(1 << 200, rounding), 1 << 100);
        assert_eq!(u256::sqrt(1 << 254, rounding), 1 << 127);
    });
}

#[test]
fun sqrt_midpoint_behavior() {
    // Test values exactly between two perfect squares
    let nearest = rounding::nearest();
    assert_eq!(u256::sqrt(5, nearest), 2); // 2.236, closer to 2
    assert_eq!(u256::sqrt(6, nearest), 2); // 2.449, closer to 2
    assert_eq!(u256::sqrt(7, nearest), 3); // 2.646, closer to 3
    assert_eq!(u256::sqrt(8, nearest), 3); // 2.828, closer to 3

    // Between 9 (3^2) and 16 (4^2): midpoint at 12.5
    assert_eq!(u256::sqrt(12, nearest), 3); // 3.464, closer to 3
    assert_eq!(u256::sqrt(13, nearest), 4); // 3.606, closer to 4
}

#[test]
fun sqrt_handles_max_value() {
    let max = std::u256::max_value!();
    let max_u128 = std::u128::max_value!() as u256;
    assert_eq!(u256::sqrt(max, rounding::down()), max_u128);
    assert_eq!(u256::sqrt(max, rounding::up()), max_u128 + 1);
    assert_eq!(u256::sqrt(max, rounding::nearest()), max_u128 + 1);
}

// === inv_mod ===

#[test]
fun inv_mod_returns_some() {
    let result = u256::inv_mod(19, 1_000_000_007);
    assert_eq!(result, option::some(157_894_738));
}

#[test]
fun inv_mod_returns_none_when_not_coprime() {
    let result = u256::inv_mod(50, 100);
    assert_eq!(result, option::none());
}

#[test, expected_failure(abort_code = macros::EZeroModulus)]
fun inv_mod_rejects_zero_modulus() {
    u256::inv_mod(1, 0);
}

// === mul_mod ===

#[test]
fun mul_mod_handles_wide_operands() {
    let a = 1u256 << 200;
    let b = (1u256 << 180) + 12345;
    let modulus = (1u256 << 201) - 109;
    let wide_product = u512::mul_u256(a, b);
    let (_, _, expected) = u512::div_rem_u256(wide_product, modulus);
    let result = u256::mul_mod(a, b, modulus);
    assert_eq!(result, expected);
}

#[test, expected_failure(abort_code = macros::EZeroModulus)]
fun mul_mod_rejects_zero_modulus() {
    u256::mul_mod(2, 3, 0);
}

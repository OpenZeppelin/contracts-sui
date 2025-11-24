module openzeppelin_math::u16_tests;

use openzeppelin_math::macros;
use openzeppelin_math::rounding;
use openzeppelin_math::u16;
use std::unit_test::assert_eq;

// === average ===

#[test]
fun average_rounding_modes() {
    let down = u16::average(400, 401, rounding::down());
    assert_eq!(down, 400);

    let up = u16::average(400, 401, rounding::up());
    assert_eq!(up, 401);

    let nearest = u16::average(1, 2, rounding::nearest());
    assert_eq!(nearest, 2);
}

#[test]
fun average_is_commutative() {
    let left = u16::average(500, 100, rounding::nearest());
    let right = u16::average(100, 500, rounding::nearest());
    assert_eq!(left, right);
}

// === checked_shl ===

#[test]
fun checked_shl_returns_some() {
    // 0x0001 << 8 is the highest safe power of two.
    let result = u16::checked_shl(1, 8);
    assert_eq!(result, option::some(256));
}

#[test]
fun checked_shl_zero_input_returns_zero_for_overshift() {
    assert_eq!(u16::checked_shl(0, 17), option::some(0));
}

#[test]
fun checked_shl_returns_same_for_zero_shift() {
    // Shifting by zero should return the same value.
    let result = u16::checked_shl(0x8001, 0);
    assert_eq!(result, option::some(0x8001));
}

#[test]
fun checked_shl_detects_high_bits() {
    // 0x8001 << 1 would overflow the 16-bit range.
    let result = u16::checked_shl(0x8001, 1);
    assert_eq!(result, option::none());
}

#[test]
fun checked_shl_rejects_large_shift() {
    // Shift of 16 would trigger a Move abort; guard it instead.
    let result = u16::checked_shl(1, 16);
    assert_eq!(result, option::none());
}

// === checked_shr ===

#[test]
fun checked_shr_returns_some() {
    // 0b1_0000_0000 >> 8 yields 0b0000_0001 with no information loss.
    let result = u16::checked_shr(256, 8);
    assert_eq!(result, option::some(1));
}

#[test]
fun checked_shr_zero_input_returns_zero_for_overshift() {
    assert_eq!(u16::checked_shr(0, 17), option::some(0));
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

// === mul_shr ===

#[test]
fun mul_shr_returns_some_when_in_range() {
    let result = u16::mul_shr(600, 10, 2, rounding::down());
    assert_eq!(result, option::some(1500));
}

#[test]
fun mul_shr_respects_rounding_modes() {
    // 5*3 = 15; 15 >> 1 = 7.5
    let down = u16::mul_shr(5, 3, 1, rounding::down());
    assert_eq!(down, option::some(7));

    let up = u16::mul_shr(5, 3, 1, rounding::up());
    assert_eq!(up, option::some(8));

    let nearest = u16::mul_shr(5, 3, 1, rounding::nearest());
    assert_eq!(nearest, option::some(8));

    // 7*4 = 28; 28 >> 2 = 7.0
    let exact = u16::mul_shr(7, 4, 2, rounding::nearest());
    assert_eq!(exact, option::some(7));

    // 13*3 = 39; 39 >> 2 = 9.75
    let down2 = u16::mul_shr(13, 3, 2, rounding::down());
    assert_eq!(down2, option::some(9));

    let up2 = u16::mul_shr(13, 3, 2, rounding::up());
    assert_eq!(up2, option::some(10));

    let nearest2 = u16::mul_shr(13, 3, 2, rounding::nearest());
    assert_eq!(nearest2, option::some(10));

    // 7*3 = 21; 21 >> 2 = 5.25
    let down3 = u16::mul_shr(7, 3, 2, rounding::down());
    assert_eq!(down3, option::some(5));

    let up3 = u16::mul_shr(7, 3, 2, rounding::up());
    assert_eq!(up3, option::some(6));

    let nearest3 = u16::mul_shr(7, 3, 2, rounding::nearest());
    assert_eq!(nearest3, option::some(5));
}

#[test]
fun mul_shr_detects_overflow() {
    let overflow = u16::mul_shr(
        std::u16::max_value!(),
        std::u16::max_value!(),
        0,
        rounding::down(),
    );
    assert_eq!(overflow, option::none());
}

// === clz ===

#[test]
fun clz_returns_bit_width_for_zero() {
    // clz(0) should return 16 (all bits are leading zeros).
    let result = u16::clz(0);
    assert_eq!(result, 16);
}

#[test]
fun clz_returns_zero_for_top_bit_set() {
    // when the most significant bit is set, there are no leading zeros.
    let value = 1u16 << 15;
    let result = u16::clz(value);
    assert_eq!(result, 0);
}

#[test]
fun clz_returns_zero_for_max_value() {
    // max value has the top bit set, so no leading zeros.
    let max = std::u16::max_value!();
    let result = u16::clz(max);
    assert_eq!(result, 0);
}

// Test all possible bit positions from 0 to 15.
#[test]
fun clz_handles_all_bit_positions() {
    16u8.do!(|bit_pos| {
        let value = 1u16 << bit_pos;
        let expected_clz = 15 - bit_pos;
        assert_eq!(u16::clz(value), expected_clz);
    });
}

// Test that lower bits have no effect on the result.
#[test]
fun clz_lower_bits_have_no_effect() {
    16u8.do!(|bit_pos| {
        let mut value = 1u16 << bit_pos;
        // set all bits below bit_pos to 1
        value = value | (value - 1);
        let expected_clz = 15 - bit_pos;
        assert_eq!(u16::clz(value), expected_clz);
    });
}

#[test]
fun clz_counts_from_highest_bit() {
    // when multiple bits are set, clz counts from the highest bit.
    // 0b11 (bits 0 and 1 set) - highest is bit 1, so clz = 14
    assert_eq!(u16::clz(3), 14);

    // 0b1111 (bits 0-3 set) - highest is bit 3, so clz = 12
    assert_eq!(u16::clz(15), 12);

    // 0xff (bits 0-7 set) - highest is bit 7, so clz = 8
    assert_eq!(u16::clz(255), 8);
}

// Test values near power-of-2 boundaries.
#[test]
fun clz_handles_values_near_boundaries() {
    // 0x100 (256) has bit 8 set, clz = 7
    assert_eq!(u16::clz(256), 7);

    // 0xff (255) has bit 7 set, clz = 8
    assert_eq!(u16::clz(255), 8);

    // 0x1000 (4096) has bit 12 set, clz = 3
    assert_eq!(u16::clz(4096), 3);

    // 0x0fff (4095) has bit 11 set, clz = 4
    assert_eq!(u16::clz(4095), 4);
}

// === msb ===

#[test]
fun msb_returns_zero_for_zero() {
    // msb(0) should return 0 by convention
    let result = u16::msb(0);
    assert_eq!(result, 0);
}

#[test]
fun msb_returns_correct_position_for_top_bit_set() {
    // when the most significant bit is set, msb returns 15
    let value = 1u16 << 15;
    let result = u16::msb(value);
    assert_eq!(result, 15);
}

#[test]
fun msb_returns_correct_position_for_max_value() {
    // max value has the top bit set, so msb returns 15
    let max = std::u16::max_value!();
    let result = u16::msb(max);
    assert_eq!(result, 15);
}

// Test all possible bit positions from 0 to 15.
#[test]
fun msb_handles_all_bit_positions() {
    16u8.do!(|bit_pos| {
        let value = 1u16 << bit_pos;
        assert_eq!(u16::msb(value), bit_pos);
    });
}

// Test that lower bits have no effect on the result.
#[test]
fun msb_lower_bits_have_no_effect() {
    16u8.do!(|bit_pos| {
        let mut value = 1u16 << bit_pos;
        // set all bits below bit_pos to 1
        value = value | (value - 1);
        assert_eq!(u16::msb(value), bit_pos);
    });
}

#[test]
fun msb_returns_highest_bit_position() {
    // when multiple bits are set, msb returns the position of the highest bit.
    // 0b11 (bits 0 and 1 set) - highest is bit 1, so msb = 1
    assert_eq!(u16::msb(3), 1);

    // 0b1111 (bits 0-3 set) - highest is bit 3, so msb = 3
    assert_eq!(u16::msb(15), 3);

    // 0xff (bits 0-7 set) - highest is bit 7, so msb = 7
    assert_eq!(u16::msb(255), 7);
}

// Test values near power-of-2 boundaries.
#[test]
fun msb_handles_values_near_boundaries() {
    // 0x100 (256) has bit 8 set, msb = 8
    assert_eq!(u16::msb(256), 8);

    // 0xff (255) has bit 7 set, msb = 7
    assert_eq!(u16::msb(255), 7);

    // 0x1000 (4096) has bit 12 set, msb = 12
    assert_eq!(u16::msb(4096), 12);

    // 0x0fff (4095) has bit 11 set, msb = 11
    assert_eq!(u16::msb(4095), 11);
}

// === log2 ===

#[test]
fun log2_returns_zero_for_zero() {
    // log2(0) should return 0 by convention
    assert_eq!(u16::log2(0, rounding::down()), 0);
    assert_eq!(u16::log2(0, rounding::up()), 0);
    assert_eq!(u16::log2(0, rounding::nearest()), 0);
}

#[test]
fun log2_returns_zero_for_one() {
    // log2(1) = 0 since 2^0 = 1
    assert_eq!(u16::log2(1, rounding::down()), 0);
    assert_eq!(u16::log2(1, rounding::up()), 0);
    assert_eq!(u16::log2(1, rounding::nearest()), 0);
}

#[test]
fun log2_handles_powers_of_two() {
    let rounding_modes = vector[rounding::down(), rounding::up(), rounding::nearest()];
    rounding_modes.destroy!(|rounding| {
        // for powers of 2, log2 returns the exponent regardless of rounding mode
        assert_eq!(u16::log2(1 << 0, rounding), 0);
        assert_eq!(u16::log2(1 << 1, rounding), 1);
        assert_eq!(u16::log2(1 << 4, rounding), 4);
        assert_eq!(u16::log2(1 << 8, rounding), 8);
        assert_eq!(u16::log2(1 << 12, rounding), 12);
        assert_eq!(u16::log2(1 << 15, rounding), 15);
    });
}

#[test]
fun log2_rounds_down() {
    // log2 with Down mode truncates to floor
    let down = rounding::down();
    assert_eq!(u16::log2(3, down), 1); // 1.58 → 1
    assert_eq!(u16::log2(5, down), 2); // 2.32 → 2
    assert_eq!(u16::log2(7, down), 2); // 2.81 → 2
    assert_eq!(u16::log2(15, down), 3); // 3.91 → 3
    assert_eq!(u16::log2(255, down), 7); // 7.99 → 7
}

#[test]
fun log2_rounds_up() {
    // log2 with Up mode rounds to ceiling
    let up = rounding::up();
    assert_eq!(u16::log2(3, up), 2); // 1.58 → 2
    assert_eq!(u16::log2(5, up), 3); // 2.32 → 3
    assert_eq!(u16::log2(7, up), 3); // 2.81 → 3
    assert_eq!(u16::log2(15, up), 4); // 3.91 → 4
    assert_eq!(u16::log2(255, up), 8); // 7.99 → 8
}

#[test]
fun log2_rounds_to_nearest() {
    // log2 with Nearest mode rounds to closest integer
    let nearest = rounding::nearest();
    assert_eq!(u16::log2(3, nearest), 2); // 1.58 → 2
    assert_eq!(u16::log2(5, nearest), 2); // 2.32 → 2
    assert_eq!(u16::log2(7, nearest), 3); // 2.81 → 3
    assert_eq!(u16::log2(15, nearest), 4); // 3.91 → 4
    assert_eq!(u16::log2(255, nearest), 8); // 7.99 → 8
}

#[test]
fun log2_handles_values_near_boundaries() {
    // test values just before and at power-of-2 boundaries
    let down = rounding::down();

    // 2^8 - 1 = 255
    assert_eq!(u16::log2((1 << 8) - 1, down), 7);
    // 2^8 = 256
    assert_eq!(u16::log2(1 << 8, down), 8);

    // 2^12 - 1 = 4095
    assert_eq!(u16::log2((1 << 12) - 1, down), 11);
    // 2^12 = 4096
    assert_eq!(u16::log2(1 << 12, down), 12);
}

#[test]
fun log2_handles_max_value() {
    // max value has all bits set, so log2 = 15
    let max = std::u16::max_value!();
    assert_eq!(u16::log2(max, rounding::down()), 15);
    assert_eq!(u16::log2(max, rounding::up()), 16);
    assert_eq!(u16::log2(max, rounding::nearest()), 16);
}

// === log256 ===

#[test]
fun log256_returns_zero_for_zero() {
    // log256(0) should return 0 by convention
    assert_eq!(u16::log256(0, rounding::down()), 0);
    assert_eq!(u16::log256(0, rounding::up()), 0);
    assert_eq!(u16::log256(0, rounding::nearest()), 0);
}

#[test]
fun log256_returns_zero_for_one() {
    // log256(1) = 0 since 256^0 = 1
    assert_eq!(u16::log256(1, rounding::down()), 0);
    assert_eq!(u16::log256(1, rounding::up()), 0);
    assert_eq!(u16::log256(1, rounding::nearest()), 0);
}

#[test]
fun log256_rounds_down() {
    // log256 with Down mode truncates to floor
    let down = rounding::down();
    assert_eq!(u16::log256(15, down), 0); // 0.488 → 0
    assert_eq!(u16::log256(16, down), 0); // 0.5 → 0
    assert_eq!(u16::log256(100, down), 0); // 0.830 → 0
    assert_eq!(u16::log256(255, down), 0); // 0.999 → 0
    assert_eq!(u16::log256(256, down), 1); // 1 exactly
    assert_eq!(u16::log256(257, down), 1); // 1.0001 → 1
    assert_eq!(u16::log256(4095, down), 1); // 1.4999 → 1
    assert_eq!(u16::log256(65535, down), 1); // 1.9999 → 1
}

#[test]
fun log256_rounds_up() {
    // log256 with Up mode rounds to ceiling
    let up = rounding::up();
    assert_eq!(u16::log256(15, up), 1); // 0.488 → 1
    assert_eq!(u16::log256(16, up), 1); // 0.5 → 1
    assert_eq!(u16::log256(100, up), 1); // 0.830 → 1
    assert_eq!(u16::log256(255, up), 1); // 0.999 → 1
    assert_eq!(u16::log256(256, up), 1); // 1 exactly
    assert_eq!(u16::log256(257, up), 2); // 1.0001 → 2
    assert_eq!(u16::log256(4095, up), 2); // 1.4999 → 2
    assert_eq!(u16::log256(65535, up), 2); // 1.9999 → 2
}

#[test]
fun log256_rounds_to_nearest() {
    // log256 with Nearest mode rounds to closest integer
    let nearest = rounding::nearest();
    // Midpoint between 256^0 and 256^1 is √256 = 16
    assert_eq!(u16::log256(15, nearest), 0); // 0.488 < 0.5 → 0
    assert_eq!(u16::log256(16, nearest), 1); // 0.5 → 1
    assert_eq!(u16::log256(100, nearest), 1); // 0.830 → 1
    assert_eq!(u16::log256(255, nearest), 1); // 0.999 → 1
    assert_eq!(u16::log256(256, nearest), 1); // 1 exactly
    // Midpoint between 256^1 and 256^2 is 256 × 16 = 4096
    assert_eq!(u16::log256(4095, nearest), 1); // 1.4999 < 1.5 → 1
    assert_eq!(u16::log256(4096, nearest), 2); // 1.5 → 2
    assert_eq!(u16::log256(4097, nearest), 2); // 1.5001 → 2
    assert_eq!(u16::log256(65535, nearest), 2); // 1.9999 → 2
}

#[test]
fun log256_handles_max_value() {
    // max value (65535) is less than 256^2 = 65536, so log256 is less than 2
    let max = std::u16::max_value!();
    assert_eq!(u16::log256(max, rounding::down()), 1);
    assert_eq!(u16::log256(max, rounding::up()), 2);
    assert_eq!(u16::log256(max, rounding::nearest()), 2);
}

// === inv_mod ===

#[test]
fun inv_mod_returns_some() {
    let result = u16::inv_mod(17, 3125);
    assert_eq!(result, option::some(1103));
}

#[test]
fun inv_mod_returns_none_when_not_coprime() {
    let result = u16::inv_mod(18, 30);
    assert_eq!(result, option::none());
}

#[test, expected_failure(abort_code = macros::EZeroModulus)]
fun inv_mod_rejects_zero_modulus() {
    u16::inv_mod(1, 0);
}

// === mul_mod ===

#[test]
fun mul_mod_basic() {
    let result = u16::mul_mod(1234, 5678, 9973);
    assert_eq!(result, 5606);
}

#[test, expected_failure(abort_code = macros::EZeroModulus)]
fun mul_mod_rejects_zero_modulus() {
    u16::mul_mod(5, 7, 0);
}

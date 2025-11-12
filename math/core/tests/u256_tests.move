module openzeppelin_math::u256_tests;

use openzeppelin_math::macros;
use openzeppelin_math::rounding;
use openzeppelin_math::u256;
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
    let value = 1u256;
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

// At the top level, the wrapper should mirror the macro’s behaviour.
#[test]
fun mul_div_rounding_modes() {
    let (down_overflow, down) = u256::mul_div(70, 10, 4, rounding::down());
    assert_eq!(down_overflow, false);
    assert_eq!(down, 175);

    let (up_overflow, up) = u256::mul_div(5, 3, 4, rounding::up());
    assert_eq!(up_overflow, false);
    assert_eq!(up, 4);

    let (nearest_overflow, nearest) = u256::mul_div(
        7,
        10,
        4,
        rounding::nearest(),
    );
    assert_eq!(nearest_overflow, false);
    assert_eq!(nearest, 18);
}

// Verify the wrapper delegates to the wide path when required.
#[test]
fun mul_div_handles_wide_operands() {
    let large = (std::u128::max_value!() as u256) + 1;
    let (overflow, result) = u256::mul_div(
        large,
        large,
        7,
        rounding::down(),
    );
    assert_eq!(overflow, false);
    let (wide_overflow, expected) = macros::mul_div_u256_wide(
        large,
        large,
        7,
        rounding::down(),
    );
    assert_eq!(wide_overflow, false);
    assert_eq!(result, expected);
}

// Division-by-zero guard enforced at the macro layer.
#[test, expected_failure(abort_code = macros::EDivideByZero)]
fun mul_div_rejects_zero_denominator() {
    u256::mul_div(1, 1, 0, rounding::down());
}

// Even u256 should flag when the macro’s output overflows 256 bits.
#[test]
fun mul_div_detects_overflow() {
    let max = std::u256::max_value!();
    let (overflow, result) = u256::mul_div(
        max,
        max,
        1,
        rounding::down(),
    );
    assert_eq!(overflow, true);
    assert_eq!(result, 0);
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
    let mut bit_pos: u8 = 0;
    loop {
        let value = 1u256 << bit_pos;
        let expected_clz = 255 - bit_pos;
        assert_eq!(u256::clz(value), expected_clz as u16);
        if (bit_pos == 255) {
            break
        } else {
            bit_pos = bit_pos + 1;
        }
    };
}

// Test that lower bits have no effect on the result.
#[test]
fun clz_lower_bits_have_no_effect() {
    let mut bit_pos: u8 = 0;
    loop {
        let mut value = 1u256 << bit_pos;
        // set all bits below bit_pos to 1
        value = value | (value - 1);
        let expected_clz = 255 - bit_pos;
        assert_eq!(u256::clz(value), expected_clz as u16);
        if (bit_pos == 255) {
            break
        } else {
            bit_pos = bit_pos + 1;
        }
    };
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
    let mut i = 0;
    while (i < rounding_modes.length()) {
        // for powers of 2, log2 returns the exponent regardless of rounding mode
        let rounding = rounding_modes[i];
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
        i = i + 1;
    }
}

#[test]
fun log2_rounds_down() {
    // log2 with Down mode truncates to floor
    let down = rounding::down();
    assert_eq!(u256::log2(3, down), 1); // log2(3) ≈ 1.58 → 1
    assert_eq!(u256::log2(5, down), 2); // log2(5) ≈ 2.32 → 2
    assert_eq!(u256::log2(7, down), 2); // log2(7) ≈ 2.81 → 2
    assert_eq!(u256::log2(15, down), 3); // log2(15) ≈ 3.91 → 3
    assert_eq!(u256::log2(255, down), 7); // log2(255) ≈ 7.99 → 7
}

#[test]
fun log2_rounds_up() {
    // log2 with Up mode rounds to ceiling
    let up = rounding::up();
    assert_eq!(u256::log2(3, up), 2); // log2(3) ≈ 1.58 → 2
    assert_eq!(u256::log2(5, up), 3); // log2(5) ≈ 2.32 → 3
    assert_eq!(u256::log2(7, up), 3); // log2(7) ≈ 2.81 → 3
    assert_eq!(u256::log2(15, up), 4); // log2(15) ≈ 3.91 → 4
    assert_eq!(u256::log2(255, up), 8); // log2(255) ≈ 7.99 → 8
}

#[test]
fun log2_rounds_to_nearest() {
    // log2 with Nearest mode rounds to closest integer
    let nearest = rounding::nearest();
    assert_eq!(u256::log2(3, nearest), 2); // log2(3) ≈ 1.58 → 2
    assert_eq!(u256::log2(5, nearest), 2); // log2(5) ≈ 2.32 → 2
    assert_eq!(u256::log2(7, nearest), 3); // log2(7) ≈ 2.81 → 3
    assert_eq!(u256::log2(15, nearest), 4); // log2(15) ≈ 3.91 → 4
    assert_eq!(u256::log2(255, nearest), 8); // log2(255) ≈ 7.99 → 8
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
fun log2_handles_max_value() {
    // max value has all bits set, so log2 = 255
    let max = std::u256::max_value!();
    assert_eq!(u256::log2(max, rounding::down()), 255);
    assert_eq!(u256::log2(max, rounding::up()), 256);
    assert_eq!(u256::log2(max, rounding::nearest()), 256);
}

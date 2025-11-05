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
    let mut bit_pos: u8 = 0;
    while (bit_pos < 32) {
        let value = 1u32 << bit_pos;
        let expected_clz = 31 - bit_pos;
        assert_eq!(u32::clz(value), expected_clz);
        bit_pos = bit_pos + 1;
    };
}

// Test that lower bits have no effect on the result.
#[test]
fun clz_lower_bits_have_no_effect() {
    let mut bit_pos: u8 = 0;
    while (bit_pos < 32) {
        let mut value = 1u32 << bit_pos;
        // set all bits below bit_pos to 1
        value = value | (value - 1);
        let expected_clz = 31 - bit_pos;
        assert_eq!(u32::clz(value), expected_clz);
        bit_pos = bit_pos + 1;
    };
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

// === log2 ===

#[test]
fun log2_returns_zero_for_zero() {
    // log2(0) should return 0 by convention
    assert_eq!(u32::log2(0), 0);
}

#[test]
fun log2_returns_zero_for_one() {
    // log2(1) = 0 since 2^0 = 1
    assert_eq!(u32::log2(1), 0);
}

#[test]
fun log2_handles_powers_of_two() {
    // for powers of 2, log2 returns the exponent
    assert_eq!(u32::log2(1 << 0), 0);  // 2^0 = 1
    assert_eq!(u32::log2(1 << 1), 1);  // 2^1 = 2
    assert_eq!(u32::log2(1 << 8), 8);  // 2^8 = 256
    assert_eq!(u32::log2(1 << 16), 16); // 2^16 = 65536
    assert_eq!(u32::log2(1 << 24), 24); // 2^24 = 16777216
    assert_eq!(u32::log2(1 << 31), 31); // 2^31
}

#[test]
fun log2_rounds_down() {
    // log2 rounds down to the nearest integer
    assert_eq!(u32::log2(3), 1);   // log2(3) ≈ 1.58 → 1
    assert_eq!(u32::log2(5), 2);   // log2(5) ≈ 2.32 → 2
    assert_eq!(u32::log2(7), 2);   // log2(7) ≈ 2.81 → 2
    assert_eq!(u32::log2(15), 3);  // log2(15) ≈ 3.91 → 3
    assert_eq!(u32::log2(255), 7); // log2(255) ≈ 7.99 → 7
}

#[test]
fun log2_handles_values_near_boundaries() {
    // test values just before and at power-of-2 boundaries
    // 2^8 - 1 = 255
    assert_eq!(u32::log2((1 << 8) - 1), 7);
    // 2^8 = 256
    assert_eq!(u32::log2(1 << 8), 8);
    
    // 2^16 - 1 = 65535
    assert_eq!(u32::log2((1 << 16) - 1), 15);
    // 2^16 = 65536
    assert_eq!(u32::log2(1 << 16), 16);
}

#[test]
fun log2_handles_max_value() {
    // max value has all bits set, so log2 = 31
    let max = std::u32::max_value!();
    assert_eq!(u32::log2(max), 31);
}

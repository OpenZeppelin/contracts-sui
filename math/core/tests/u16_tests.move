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
    let mut bit_pos: u8 = 0;
    while (bit_pos < 16) {
        let value = 1u16 << bit_pos;
        let expected_clz = 15 - bit_pos;
        assert_eq!(u16::clz(value), expected_clz);
        bit_pos = bit_pos + 1;
    };
}

// Test that lower bits have no effect on the result.
#[test]
fun clz_lower_bits_have_no_effect() {
    let mut bit_pos: u8 = 0;
    while (bit_pos < 16) {
        let mut value = 1u16 << bit_pos;
        // set all bits below bit_pos to 1
        value = value | (value - 1);
        let expected_clz = 15 - bit_pos;
        assert_eq!(u16::clz(value), expected_clz);
        bit_pos = bit_pos + 1;
    };
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

// === log2 ===

#[test]
fun log2_returns_zero_for_zero() {
    // log2(0) should return 0 by convention
    assert_eq!(u16::log2(0), 0);
}

#[test]
fun log2_returns_zero_for_one() {
    // log2(1) = 0 since 2^0 = 1
    assert_eq!(u16::log2(1), 0);
}

#[test]
fun log2_handles_powers_of_two() {
    // for powers of 2, log2 returns the exponent
    assert_eq!(u16::log2(1 << 0), 0);  // 2^0 = 1
    assert_eq!(u16::log2(1 << 1), 1);  // 2^1 = 2
    assert_eq!(u16::log2(1 << 4), 4);  // 2^4 = 16
    assert_eq!(u16::log2(1 << 8), 8);  // 2^8 = 256
    assert_eq!(u16::log2(1 << 12), 12); // 2^12 = 4096
    assert_eq!(u16::log2(1 << 15), 15); // 2^15 = 32768
}

#[test]
fun log2_rounds_down() {
    // log2 rounds down to the nearest integer
    assert_eq!(u16::log2(3), 1);   // log2(3) ≈ 1.58 → 1
    assert_eq!(u16::log2(5), 2);   // log2(5) ≈ 2.32 → 2
    assert_eq!(u16::log2(7), 2);   // log2(7) ≈ 2.81 → 2
    assert_eq!(u16::log2(15), 3);  // log2(15) ≈ 3.91 → 3
    assert_eq!(u16::log2(255), 7); // log2(255) ≈ 7.99 → 7
}

#[test]
fun log2_handles_values_near_boundaries() {
    // test values just before and at power-of-2 boundaries
    // 2^8 - 1 = 255
    assert_eq!(u16::log2((1 << 8) - 1), 7);
    // 2^8 = 256
    assert_eq!(u16::log2(1 << 8), 8);
    
    // 2^12 - 1 = 4095
    assert_eq!(u16::log2((1 << 12) - 1), 11);
    // 2^12 = 4096
    assert_eq!(u16::log2(1 << 12), 12);
}

#[test]
fun log2_handles_max_value() {
    // max value has all bits set, so log2 = 15
    let max = std::u16::max_value!();
    assert_eq!(u16::log2(max), 15);
}

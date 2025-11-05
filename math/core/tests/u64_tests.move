module openzeppelin_math::u64_tests;

use openzeppelin_math::macros;
use openzeppelin_math::rounding;
use openzeppelin_math::u64;
use std::unit_test::assert_eq;

// === average ===

#[test]
fun average_rounding_modes() {
    let down = u64::average(10, 15, rounding::down());
    assert_eq!(down, 12);

    let up = u64::average(10, 15, rounding::up());
    assert_eq!(up, 13);

    let nearest = u64::average(1, 2, rounding::nearest());
    assert_eq!(nearest, 2);
}

#[test]
fun average_is_commutative() {
    let left = u64::average(1_000, 50, rounding::nearest());
    let right = u64::average(50, 1_000, rounding::nearest());
    assert_eq!(left, right);
}

// === checked_shl ===

#[test]
fun checked_shl_returns_some() {
    // Shift into the highest bit safely.
    let result = u64::checked_shl(1, 63);
    assert_eq!(result, option::some(1 << 63));
}

#[test]
fun checked_shl_returns_same_for_zero_shift() {
    // Shifting by zero should return the same value.
    let value = 1 << 63;
    let result = u64::checked_shl(value, 0);
    assert_eq!(result, option::some(value));
}

#[test]
fun checked_shl_detects_high_bits() {
    // Top bit already set — shifting would overflow.
    let result = u64::checked_shl(1 << 63, 1);
    assert_eq!(result, option::none());
}

#[test]
fun checked_shl_rejects_large_shift() {
    // Guard against the width-sized shift.
    let result = u64::checked_shl(1, 64);
    assert_eq!(result, option::none());
}

// === checked_shr ===

#[test]
fun checked_shr_returns_some() {
    // 1 << 32 leaves a clean trailing zero region to drop.
    let value = 1u64 << 32;
    let result = u64::checked_shr(value, 32);
    assert_eq!(result, option::some(1));
}

#[test]
fun checked_shr_detects_set_bits() {
    // LSB is set, shifting by one would remove it.
    let result = u64::checked_shr(5, 1);
    assert_eq!(result, option::none());
}

#[test]
fun checked_shr_rejects_large_shift() {
    // Disallow shifting by the full width to avoid runtime aborts.
    let result = u64::checked_shr(1, 64);
    assert_eq!(result, option::none());
}

// === mul_div ===

// Larger inputs continue to follow the same rounding contract.
#[test]
fun mul_div_rounding_modes() {
    let (down_overflow, down) = u64::mul_div(70, 10, 4, rounding::down());
    assert_eq!(down_overflow, false);
    assert_eq!(down, 175);

    let (up_overflow, up) = u64::mul_div(5, 3, 4, rounding::up());
    assert_eq!(up_overflow, false);
    assert_eq!(up, 4);

    let (nearest_overflow, nearest) = u64::mul_div(
        7,
        10,
        4,
        rounding::nearest(),
    );
    assert_eq!(nearest_overflow, false);
    assert_eq!(nearest, 18);
}

// Perfect division should remain unaffected by rounding mode choice.
#[test]
fun mul_div_exact_division() {
    let (overflow, exact) = u64::mul_div(8_000, 2, 4, rounding::up());
    assert_eq!(overflow, false);
    assert_eq!(exact, 4_000);
}

// Guard against missing macro errors during integration.
#[test, expected_failure(abort_code = macros::EDivideByZero)]
fun mul_div_rejects_zero_denominator() {
    u64::mul_div(1, 1, 0, rounding::down());
}

// Downstream overflow is still surfaced via the overflow flag.
#[test]
fun mul_div_detects_overflow() {
    let (overflow, result) = u64::mul_div(
        std::u64::max_value!(),
        2,
        1,
        rounding::down(),
    );
    assert_eq!(overflow, true);
    assert_eq!(result, 0);
}

// === clz ===

// clz(0) should return 64 (all bits are leading zeros).
#[test]
fun clz_returns_bit_width_for_zero() {
    let result = u64::clz(0);
    assert_eq!(result, 64);
}

// When the most significant bit is set, there are no leading zeros.
#[test]
fun clz_returns_zero_for_top_bit_set() {
    let value = 1u64 << 63;
    let result = u64::clz(value);
    assert_eq!(result, 0);
}

// Max value has the top bit set, so no leading zeros.
#[test]
fun clz_returns_zero_for_max_value() {
    let max = std::u64::max_value!();
    let result = u64::clz(max);
    assert_eq!(result, 0);
}

// Test all possible bit positions from 0 to 63.
#[test]
fun clz_handles_all_bit_positions() {
    let mut bit_pos: u8 = 0;
    while (bit_pos < 64) {
        let value = 1u64 << bit_pos;
        let expected_clz = 63 - bit_pos;
        assert_eq!(u64::clz(value), expected_clz);
        bit_pos = bit_pos + 1;
    };
}

// Test that lower bits have no effect on the result.
#[test]
fun clz_lower_bits_have_no_effect() {
    let mut bit_pos: u8 = 0;
    while (bit_pos < 64) {
        let mut value = 1u64 << bit_pos;
        // Set all bits below bit_pos to 1
        value = value | (value - 1);
        let expected_clz = 63 - bit_pos;
        assert_eq!(u64::clz(value), expected_clz);
        bit_pos = bit_pos + 1;
    };
}

// When multiple bits are set, clz counts from the highest bit.
#[test]
fun clz_counts_from_highest_bit() {
    // 0b11 (bits 0 and 1 set) - highest is bit 1, so clz = 62
    assert_eq!(u64::clz(3), 62);
    
    // 0b1111 (bits 0-3 set) - highest is bit 3, so clz = 60
    assert_eq!(u64::clz(15), 60);
    
    // 0xFF (bits 0-7 set) - highest is bit 7, so clz = 56
    assert_eq!(u64::clz(255), 56);
}

// Test values near power-of-2 boundaries.
#[test]
fun clz_handles_values_near_boundaries() {
    // 0x100000000 (2^32) has bit 32 set, clz = 31
    assert_eq!(u64::clz(0x100000000), 31);
    
    // 0xFFFFFFFF (2^32 - 1) has bit 31 set, clz = 32
    assert_eq!(u64::clz(0xFFFFFFFF), 32);
    
    // 0x10000000000000 (2^52) has bit 52 set, clz = 11
    assert_eq!(u64::clz(0x10000000000000), 11);
    
    // 0xFFFFFFFFFFFFF (2^52 - 1) has bit 51 set, clz = 12
    assert_eq!(u64::clz(0xFFFFFFFFFFFFF), 12);
}

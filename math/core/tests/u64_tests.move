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
fun checked_shl_zero_input_returns_zero_for_overshift() {
    assert_eq!(u64::checked_shl(0, 65), option::some(0));
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
fun checked_shr_zero_input_returns_zero_for_overshift() {
    assert_eq!(u64::checked_shr(0, 65), option::some(0));
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

// === mul_shr ===

#[test]
fun mul_shr_returns_some_when_in_range() {
    let result = u64::mul_shr(1_000_000, 3_000, 4, rounding::down());
    assert_eq!(result, option::some(187_500_000));
}

#[test]
fun mul_shr_respects_rounding_modes() {
    // 5*3 = 15; 15 >> 1 = 7.5
    let down = u64::mul_shr(5, 3, 1, rounding::down());
    assert_eq!(down, option::some(7));

    let up = u64::mul_shr(5, 3, 1, rounding::up());
    assert_eq!(up, option::some(8));

    let nearest = u64::mul_shr(5, 3, 1, rounding::nearest());
    assert_eq!(nearest, option::some(8));

    // 7*4 = 28; 28 >> 2 = 7.0
    let exact = u64::mul_shr(7, 4, 2, rounding::nearest());
    assert_eq!(exact, option::some(7));

    // 13*3 = 39; 39 >> 2 = 9.75
    let down2 = u64::mul_shr(13, 3, 2, rounding::down());
    assert_eq!(down2, option::some(9));

    let up2 = u64::mul_shr(13, 3, 2, rounding::up());
    assert_eq!(up2, option::some(10));

    let nearest2 = u64::mul_shr(13, 3, 2, rounding::nearest());
    assert_eq!(nearest2, option::some(10));

    // 7*3 = 21; 21 >> 2 = 5.25
    let down3 = u64::mul_shr(7, 3, 2, rounding::down());
    assert_eq!(down3, option::some(5));

    let up3 = u64::mul_shr(7, 3, 2, rounding::up());
    assert_eq!(up3, option::some(6));

    let nearest3 = u64::mul_shr(7, 3, 2, rounding::nearest());
    assert_eq!(nearest3, option::some(5));
}

#[test]
fun mul_shr_detects_overflow() {
    let overflow = u64::mul_shr(
        std::u64::max_value!(),
        std::u64::max_value!(),
        0,
        rounding::down(),
    );
    assert_eq!(overflow, option::none());
}

// === clz ===

#[test]
fun clz_returns_bit_width_for_zero() {
    // clz(0) should return 64 (all bits are leading zeros).
    let result = u64::clz(0);
    assert_eq!(result, 64);
}

#[test]
fun clz_returns_zero_for_top_bit_set() {
    // when the most significant bit is set, there are no leading zeros.
    let value = 1u64 << 63;
    let result = u64::clz(value);
    assert_eq!(result, 0);
}

#[test]
fun clz_returns_zero_for_max_value() {
    // max value has the top bit set, so no leading zeros.
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
        // set all bits below bit_pos to 1
        value = value | (value - 1);
        let expected_clz = 63 - bit_pos;
        assert_eq!(u64::clz(value), expected_clz);
        bit_pos = bit_pos + 1;
    };
}

#[test]
fun clz_counts_from_highest_bit() {
    // when multiple bits are set, clz counts from the highest bit.
    // 0b11 (bits 0 and 1 set) - highest is bit 1, so clz = 62
    assert_eq!(u64::clz(3), 62);

    // 0b1111 (bits 0-3 set) - highest is bit 3, so clz = 60
    assert_eq!(u64::clz(15), 60);

    // 0xff (bits 0-7 set) - highest is bit 7, so clz = 56
    assert_eq!(u64::clz(255), 56);
}

// Test values near power-of-2 boundaries.
#[test]
fun clz_handles_values_near_boundaries() {
    // 0x0001_0000_0000 (2^32) has bit 32 set, clz = 31
    assert_eq!(u64::clz(1 << 32), 31);

    // 0xffff_ffff (2^32 - 1) has bit 31 set, clz = 32
    assert_eq!(u64::clz((1 << 32) - 1), 32);

    // 0x0010_0000_0000_0000 (2^52) has bit 52 set, clz = 11
    assert_eq!(u64::clz(1 << 52), 11);

    // 0x000f_ffff_ffff_ffff (2^52 - 1) has bit 51 set, clz = 12
    assert_eq!(u64::clz((1 << 52) - 1), 12);
}

// === log2 ===

#[test]
fun log2_returns_zero_for_zero() {
    // log2(0) should return 0 by convention
    assert_eq!(u64::log2(0, rounding::down()), 0);
    assert_eq!(u64::log2(0, rounding::up()), 0);
    assert_eq!(u64::log2(0, rounding::nearest()), 0);
}

#[test]
fun log2_returns_zero_for_one() {
    // log2(1) = 0 since 2^0 = 1
    assert_eq!(u64::log2(1, rounding::down()), 0);
    assert_eq!(u64::log2(1, rounding::up()), 0);
    assert_eq!(u64::log2(1, rounding::nearest()), 0);
}

#[test]
fun log2_handles_powers_of_two() {
    let rounding_modes = vector[rounding::down(), rounding::up(), rounding::nearest()];
    let mut i = 0;
    while (i < rounding_modes.length()) {
        // for powers of 2, log2 returns the exponent regardless of rounding mode
        let rounding = rounding_modes[i];
        assert_eq!(u64::log2(1 << 0, rounding), 0);
        assert_eq!(u64::log2(1 << 1, rounding), 1);
        assert_eq!(u64::log2(1 << 8, rounding), 8);
        assert_eq!(u64::log2(1 << 16, rounding), 16);
        assert_eq!(u64::log2(1 << 32, rounding), 32);
        assert_eq!(u64::log2(1 << 52, rounding), 52);
        assert_eq!(u64::log2(1 << 63, rounding), 63);
        i = i + 1;
    }
}

#[test]
fun log2_rounds_down() {
    // log2 with Down mode truncates to floor
    let down = rounding::down();
    assert_eq!(u64::log2(3, down), 1); // 1.58 → 1
    assert_eq!(u64::log2(5, down), 2); // 2.32 → 2
    assert_eq!(u64::log2(7, down), 2); // 2.81 → 2
    assert_eq!(u64::log2(15, down), 3); // 3.91 → 3
    assert_eq!(u64::log2(255, down), 7); // 7.99 → 7
}

#[test]
fun log2_rounds_up() {
    // log2 with Up mode rounds to ceiling
    let up = rounding::up();
    assert_eq!(u64::log2(3, up), 2); // 1.58 → 2
    assert_eq!(u64::log2(5, up), 3); // 2.32 → 3
    assert_eq!(u64::log2(7, up), 3); // 2.81 → 3
    assert_eq!(u64::log2(15, up), 4); // 3.91 → 4
    assert_eq!(u64::log2(255, up), 8); // 7.99 → 8
}

#[test]
fun log2_rounds_to_nearest() {
    // log2 with Nearest mode rounds to closest integer
    let nearest = rounding::nearest();
    assert_eq!(u64::log2(3, nearest), 2); // 1.58 → 2
    assert_eq!(u64::log2(5, nearest), 2); // 2.32 → 2
    assert_eq!(u64::log2(7, nearest), 3); // 2.81 → 3
    assert_eq!(u64::log2(15, nearest), 4); // 3.91 → 4
    assert_eq!(u64::log2(255, nearest), 8); // 7.99 → 8
}

#[test]
fun log2_handles_values_near_boundaries() {
    // test values just before and at power-of-2 boundaries
    let down = rounding::down();

    // 2^8 - 1 = 255
    assert_eq!(u64::log2((1 << 8) - 1, down), 7);
    // 2^8 = 256
    assert_eq!(u64::log2(1 << 8, down), 8);

    // 2^32 - 1
    assert_eq!(u64::log2((1 << 32) - 1, down), 31);
    // 2^32
    assert_eq!(u64::log2(1 << 32, down), 32);
}

#[test]
fun log2_handles_max_value() {
    // max value has all bits set, so log2 = 63
    let max = std::u64::max_value!();
    assert_eq!(u64::log2(max, rounding::down()), 63);
    assert_eq!(u64::log2(max, rounding::up()), 64);
    assert_eq!(u64::log2(max, rounding::nearest()), 64);
}

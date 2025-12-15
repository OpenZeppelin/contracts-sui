#[test_only]
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
    let down = u64::mul_div(70, 10, 4, rounding::down());
    assert_eq!(down, option::some(175));

    let up = u64::mul_div(5, 3, 4, rounding::up());
    assert_eq!(up, option::some(4));

    let nearest = u64::mul_div(
        7,
        10,
        4,
        rounding::nearest(),
    );
    assert_eq!(nearest, option::some(18));
}

// Perfect division should remain unaffected by rounding mode choice.
#[test]
fun mul_div_exact_division() {
    let exact = u64::mul_div(8_000, 2, 4, rounding::up());
    assert_eq!(exact, option::some(4_000));
}

// Guard against missing macro errors during integration.
#[test, expected_failure(abort_code = macros::EDivideByZero)]
fun mul_div_rejects_zero_denominator() {
    u64::mul_div(1, 1, 0, rounding::down());
}

// Downstream overflow is still surfaced via the overflow flag.
#[test]
fun mul_div_detects_overflow() {
    let result = u64::mul_div(
        std::u64::max_value!(),
        2,
        1,
        rounding::down(),
    );
    assert_eq!(result, option::none());
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
    64u8.do!(|bit_pos| {
        let value = 1u64 << bit_pos;
        let expected_clz = 63 - bit_pos;
        assert_eq!(u64::clz(value), expected_clz);
    });
}

// Test that lower bits have no effect on the result.
#[test]
fun clz_lower_bits_have_no_effect() {
    64u8.do!(|bit_pos| {
        let mut value = 1u64 << bit_pos;
        // set all bits below bit_pos to 1
        value = value | (value - 1);
        let expected_clz = 63 - bit_pos;
        assert_eq!(u64::clz(value), expected_clz);
    });
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

// === msb ===

#[test]
fun msb_returns_zero_for_zero() {
    // msb(0) should return 0 by convention
    let result = u64::msb(0);
    assert_eq!(result, 0);
}

#[test]
fun msb_returns_correct_position_for_top_bit_set() {
    // when the most significant bit is set, msb returns 63
    let value = 1u64 << 63;
    let result = u64::msb(value);
    assert_eq!(result, 63);
}

#[test]
fun msb_returns_correct_position_for_max_value() {
    // max value has the top bit set, so msb returns 63
    let max = std::u64::max_value!();
    let result = u64::msb(max);
    assert_eq!(result, 63);
}

// Test all possible bit positions from 0 to 63.
#[test]
fun msb_handles_all_bit_positions() {
    64u8.do!(|bit_pos| {
        let value = 1u64 << bit_pos;
        assert_eq!(u64::msb(value), bit_pos);
    });
}

// Test that lower bits have no effect on the result.
#[test]
fun msb_lower_bits_have_no_effect() {
    64u8.do!(|bit_pos| {
        let mut value = 1u64 << bit_pos;
        // set all bits below bit_pos to 1
        value = value | (value - 1);
        assert_eq!(u64::msb(value), bit_pos);
    });
}

#[test]
fun msb_returns_highest_bit_position() {
    // when multiple bits are set, msb returns the position of the highest bit.
    // 0b11 (bits 0 and 1 set) - highest is bit 1, so msb = 1
    assert_eq!(u64::msb(3), 1);

    // 0b1111 (bits 0-3 set) - highest is bit 3, so msb = 3
    assert_eq!(u64::msb(15), 3);

    // 0xff (bits 0-7 set) - highest is bit 7, so msb = 7
    assert_eq!(u64::msb(255), 7);
}

// Test values near power-of-2 boundaries.
#[test]
fun msb_handles_values_near_boundaries() {
    // 0x0001_0000_0000 (2^32) has bit 32 set, msb = 32
    assert_eq!(u64::msb(1 << 32), 32);

    // 0xffff_ffff (2^32 - 1) has bit 31 set, msb = 31
    assert_eq!(u64::msb((1 << 32) - 1), 31);

    // 0x0010_0000_0000_0000 (2^52) has bit 52 set, msb = 52
    assert_eq!(u64::msb(1 << 52), 52);

    // 0x000f_ffff_ffff_ffff (2^52 - 1) has bit 51 set, msb = 51
    assert_eq!(u64::msb((1 << 52) - 1), 51);
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
    rounding_modes.destroy!(|rounding| {
        // for powers of 2, log2 returns the exponent regardless of rounding mode
        assert_eq!(u64::log2(1 << 0, rounding), 0);
        assert_eq!(u64::log2(1 << 1, rounding), 1);
        assert_eq!(u64::log2(1 << 8, rounding), 8);
        assert_eq!(u64::log2(1 << 16, rounding), 16);
        assert_eq!(u64::log2(1 << 32, rounding), 32);
        assert_eq!(u64::log2(1 << 52, rounding), 52);
        assert_eq!(u64::log2(1 << 63, rounding), 63);
    });
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

// === log256 ===

#[test]
fun log256_returns_zero_for_zero() {
    // log256(0) should return 0 by convention
    assert_eq!(u64::log256(0, rounding::down()), 0);
    assert_eq!(u64::log256(0, rounding::up()), 0);
    assert_eq!(u64::log256(0, rounding::nearest()), 0);
}

#[test]
fun log256_returns_zero_for_one() {
    // log256(1) = 0 since 256^0 = 1
    assert_eq!(u64::log256(1, rounding::down()), 0);
    assert_eq!(u64::log256(1, rounding::up()), 0);
    assert_eq!(u64::log256(1, rounding::nearest()), 0);
}

#[test]
fun log256_handles_powers_of_256() {
    // Test exact powers of 256
    let rounding_modes = vector[rounding::down(), rounding::up(), rounding::nearest()];
    rounding_modes.destroy!(|rounding| {
        assert_eq!(u64::log256(1 << 8, rounding), 1);
        assert_eq!(u64::log256(1 << 16, rounding), 2);
        assert_eq!(u64::log256(1 << 24, rounding), 3);
        assert_eq!(u64::log256(1 << 32, rounding), 4);
        assert_eq!(u64::log256(1 << 40, rounding), 5);
        assert_eq!(u64::log256(1 << 48, rounding), 6);
        assert_eq!(u64::log256(1 << 56, rounding), 7);
    });
}

#[test]
fun log256_rounds_down() {
    // log256 with Down mode truncates to floor
    let down = rounding::down();
    assert_eq!(u64::log256(15, down), 0); // 0.488 → 0
    assert_eq!(u64::log256(16, down), 0); // 0.5 → 0
    assert_eq!(u64::log256(255, down), 0); // 0.999 → 0
    assert_eq!(u64::log256(1 << 8, down), 1); // 1 exactly
    assert_eq!(u64::log256((1 << 8) + 1, down), 1); // 1.001 → 1
    assert_eq!(u64::log256((1 << 16) - 1, down), 1); // 1.9999 → 1
    assert_eq!(u64::log256(1 << 16, down), 2); // 2 exactly
    assert_eq!(u64::log256((1 << 32) - 1, down), 3); // 3.9999 → 3
    assert_eq!(u64::log256(1 << 32, down), 4); // 4 exactly
    assert_eq!(u64::log256((1 << 56) - 1, down), 6); // 6.9999 → 6
    assert_eq!(u64::log256(1 << 56, down), 7); // 7 exactly
}

#[test]
fun log256_rounds_up() {
    // log256 with Up mode rounds to ceiling
    let up = rounding::up();
    assert_eq!(u64::log256(15, up), 1); // 0.488 → 1
    assert_eq!(u64::log256(16, up), 1); // 0.5 → 1
    assert_eq!(u64::log256(255, up), 1); // 0.999 → 1
    assert_eq!(u64::log256(1 << 8, up), 1); // 1 exactly
    assert_eq!(u64::log256((1 << 8) + 1, up), 2); // 1.001 → 2
    assert_eq!(u64::log256((1 << 16) - 1, up), 2); // 1.9999 → 2
    assert_eq!(u64::log256(1 << 16, up), 2); // 2 exactly
    assert_eq!(u64::log256((1 << 32) - 1, up), 4); // 3.9999 → 4
    assert_eq!(u64::log256(1 << 32, up), 4); // 4 exactly
    assert_eq!(u64::log256((1 << 56) - 1, up), 7); // 6.9999 → 7
    assert_eq!(u64::log256(1 << 56, up), 7); // 7 exactly
}

#[test]
fun log256_rounds_to_nearest() {
    // log256 with Nearest mode rounds to closest integer
    // Midpoint between 256^k and 256^(k+1) is 256^k × 16
    let nearest = rounding::nearest();
    // Between 256^0 and 256^1: midpoint is 16
    assert_eq!(u64::log256(15, nearest), 0); // 0.488 < 0.5 → 0
    assert_eq!(u64::log256(16, nearest), 1); // 0.5 → 1
    assert_eq!(u64::log256(255, nearest), 1); // 0.999 → 1
    // Between 256^1 and 256^2: midpoint is 4096
    assert_eq!(u64::log256((1 << 12) - 1, nearest), 1); // 1.4999 < 1.5 → 1
    assert_eq!(u64::log256(1 << 12, nearest), 2); // 1.5 → 2
    assert_eq!(u64::log256((1 << 16) - 1, nearest), 2); // 1.9999 → 2
    // Between 256^3 and 256^4: midpoint is 1 << 28
    assert_eq!(u64::log256((1 << 28) - 1, nearest), 3); // 3.4999 < 3.5 → 3
    assert_eq!(u64::log256(1 << 28, nearest), 4); // 3.5 → 4
    assert_eq!(u64::log256((1 << 32) - 1, nearest), 4); // 3.9999 → 4
}

#[test]
fun log256_handles_max_value() {
    // max value is less than 256^8 = 2^64, so log256 is less than 8
    let max = std::u64::max_value!();
    assert_eq!(u64::log256(max, rounding::down()), 7);
    assert_eq!(u64::log256(max, rounding::up()), 8);
    assert_eq!(u64::log256(max, rounding::nearest()), 8);
}

// === log10 ===

#[test]
fun log10_returns_zero_for_zero() {
    // log10(0) should return 0 by convention
    assert_eq!(u64::log10(0, rounding::down()), 0);
    assert_eq!(u64::log10(0, rounding::up()), 0);
    assert_eq!(u64::log10(0, rounding::nearest()), 0);
}

#[test]
fun log10_handles_powers_of_10() {
    // for powers of 10, log10 returns the exponent regardless of rounding mode
    let rounding_modes = vector[rounding::down(), rounding::up(), rounding::nearest()];
    rounding_modes.destroy!(|rounding| {
        assert_eq!(u64::log10(1, rounding), 0); // 10^0
        assert_eq!(u64::log10(10, rounding), 1); // 10^1
        assert_eq!(u64::log10(100, rounding), 2); // 10^2
        assert_eq!(u64::log10(1000, rounding), 3); // 10^3
        assert_eq!(u64::log10(1000000, rounding), 6); // 10^6
        assert_eq!(u64::log10(1000000000, rounding), 9); // 10^9
        assert_eq!(u64::log10(1000000000000, rounding), 12); // 10^12
        assert_eq!(u64::log10(10000000000000000, rounding), 16); // 10^16
    });
}

#[test]
fun log10_rounds_down() {
    // log10 with Down mode truncates to floor
    let down = rounding::down();
    assert_eq!(u64::log10(9, down), 0); // ≈ 0.954 → 0
    assert_eq!(u64::log10(99, down), 1); // ≈ 1.996 → 1
    assert_eq!(u64::log10(999, down), 2); // ≈ 2.9996 → 2
    assert_eq!(u64::log10(9999, down), 3); // ≈ 3.9999 → 3
    assert_eq!(u64::log10(18446744073709551615, down), 19); // ≈ 19.266 → 19
}

#[test]
fun log10_rounds_up() {
    // log10 with Up mode rounds to ceiling
    let up = rounding::up();
    assert_eq!(u64::log10(9, up), 1); // ≈ 0.954 → 1
    assert_eq!(u64::log10(99, up), 2); // ≈ 1.996 → 2
    assert_eq!(u64::log10(999, up), 3); // ≈ 2.9996 → 3
    assert_eq!(u64::log10(9999, up), 4); // ≈ 3.9999 → 4
    assert_eq!(u64::log10(18446744073709551615, up), 20); // ≈ 19.266 → 20
}

#[test]
fun log10_rounds_to_nearest() {
    let nearest = rounding::nearest();

    // Between 10^0 and 10^1: midpoint at √10 ≈ 3.162
    assert_eq!(u64::log10(3, nearest), 0); // < 3.162, rounds down
    assert_eq!(u64::log10(4, nearest), 1); // > 3.162, rounds up

    // Between 10^1 and 10^2: midpoint at 10 × √10 ≈ 31.62
    assert_eq!(u64::log10(31, nearest), 1); // < 31.62, rounds down
    assert_eq!(u64::log10(32, nearest), 2); // > 31.62, rounds up
}

#[test]
fun log10_handles_edge_cases_near_powers() {
    // Test values just before and after powers of 10
    let down = rounding::down();
    let up = rounding::up();
    let nearest = rounding::nearest();

    // Around 10^1 = 10
    assert_eq!(u64::log10(9, down), 0);
    assert_eq!(u64::log10(10, down), 1);
    assert_eq!(u64::log10(11, down), 1);

    assert_eq!(u64::log10(9, up), 1);
    assert_eq!(u64::log10(10, up), 1);
    assert_eq!(u64::log10(11, up), 2);

    assert_eq!(u64::log10(9, nearest), 1);
    assert_eq!(u64::log10(10, nearest), 1);
    assert_eq!(u64::log10(11, nearest), 1);

    // Around 10^12 = 1000000000000
    assert_eq!(u64::log10(999999999999, down), 11);
    assert_eq!(u64::log10(1000000000000, down), 12);
    assert_eq!(u64::log10(1000000000001, down), 12);

    assert_eq!(u64::log10(999999999999, up), 12);
    assert_eq!(u64::log10(1000000000000, up), 12);
    assert_eq!(u64::log10(1000000000001, up), 13);

    assert_eq!(u64::log10(999999999999, nearest), 12);
    assert_eq!(u64::log10(1000000000000, nearest), 12);
    assert_eq!(u64::log10(1000000000001, nearest), 12);
}

#[test]
fun log10_handles_max_value() {
    // max value has log10 ≈ 19.266
    let max = std::u64::max_value!();
    assert_eq!(u64::log10(max, rounding::down()), 19);
    assert_eq!(u64::log10(max, rounding::up()), 20);
    assert_eq!(u64::log10(max, rounding::nearest()), 19);
}

// === sqrt ===

#[test]
fun sqrt_returns_zero_for_zero() {
    // sqrt(0) = 0 by definition
    assert_eq!(u64::sqrt(0, rounding::down()), 0);
    assert_eq!(u64::sqrt(0, rounding::up()), 0);
    assert_eq!(u64::sqrt(0, rounding::nearest()), 0);
}

#[test]
fun sqrt_handles_perfect_squares() {
    // Perfect squares should return exact result regardless of rounding mode
    let rounding_modes = vector[rounding::down(), rounding::up(), rounding::nearest()];
    rounding_modes.destroy!(|rounding| {
        assert_eq!(u64::sqrt(1, rounding), 1);
        assert_eq!(u64::sqrt(4, rounding), 2);
        assert_eq!(u64::sqrt(9, rounding), 3);
        assert_eq!(u64::sqrt(16, rounding), 4);
        assert_eq!(u64::sqrt(100, rounding), 10);
        assert_eq!(u64::sqrt(65536, rounding), 256);
        assert_eq!(u64::sqrt(1000000, rounding), 1000);
        assert_eq!(u64::sqrt(1 << 32, rounding), 1 << 16); // (2^16)^2 = 2^32
    });
}

#[test]
fun sqrt_rounds_down() {
    // sqrt with Down mode truncates to floor
    let down = rounding::down();
    assert_eq!(u64::sqrt(2, down), 1); // 1.414 → 1
    assert_eq!(u64::sqrt(3, down), 1); // 1.732 → 1
    assert_eq!(u64::sqrt(5, down), 2); // 2.236 → 2
    assert_eq!(u64::sqrt(99, down), 9); // 9.950 → 9
    assert_eq!(u64::sqrt(1000000, down), 1000);
    assert_eq!(u64::sqrt(100000000, down), 10000);
    assert_eq!(u64::sqrt(18446744073709551615, down), 4294967295); // sqrt(u64::MAX) → 4294967295
}

#[test]
fun sqrt_rounds_up() {
    // sqrt with Up mode rounds to ceiling
    let up = rounding::up();
    assert_eq!(u64::sqrt(2, up), 2); // 1.414 → 2
    assert_eq!(u64::sqrt(3, up), 2); // 1.732 → 2
    assert_eq!(u64::sqrt(5, up), 3); // 2.236 → 3
    assert_eq!(u64::sqrt(99, up), 10); // 9.950 → 10
    assert_eq!(u64::sqrt(1000001, up), 1001);
    assert_eq!(u64::sqrt(100000001, up), 10001);
    assert_eq!(u64::sqrt(18446744073709551615, up), 4294967296); // sqrt(u64::MAX) → 4294967296
}

#[test]
fun sqrt_rounds_to_nearest() {
    // sqrt with Nearest mode rounds to closest integer
    let nearest = rounding::nearest();
    assert_eq!(u64::sqrt(2, nearest), 1); // 1.414 → 1
    assert_eq!(u64::sqrt(3, nearest), 2); // 1.732 → 2
    assert_eq!(u64::sqrt(5, nearest), 2); // 2.236 → 2
    assert_eq!(u64::sqrt(7, nearest), 3); // 2.646 → 3
    assert_eq!(u64::sqrt(99, nearest), 10); // 9.950 → 10
    assert_eq!(u64::sqrt(1002000, nearest), 1001);
    assert_eq!(u64::sqrt(18446744073709551615, nearest), 4294967296); // sqrt(u64::MAX) → 4294967296
}

#[test]
fun sqrt_handles_powers_of_four() {
    // Powers of 4 (perfect squares of powers of 2)
    let rounding_modes = vector[rounding::down(), rounding::up(), rounding::nearest()];
    rounding_modes.destroy!(|rounding| {
        assert_eq!(u64::sqrt(1, rounding), 1);
        assert_eq!(u64::sqrt(4, rounding), 2);
        assert_eq!(u64::sqrt(16, rounding), 4);
        assert_eq!(u64::sqrt(64, rounding), 8);
        assert_eq!(u64::sqrt(256, rounding), 16);
        assert_eq!(u64::sqrt(1024, rounding), 32);
        assert_eq!(u64::sqrt(1 << 20, rounding), 1024);
        assert_eq!(u64::sqrt(1 << 32, rounding), 1 << 16);
        assert_eq!(u64::sqrt(1 << 40, rounding), 1 << 20);
        assert_eq!(u64::sqrt(1 << 62, rounding), 1 << 31);
    });
}

#[test]
fun sqrt_midpoint_behavior() {
    // Test values exactly between two perfect squares
    let nearest = rounding::nearest();
    assert_eq!(u64::sqrt(5, nearest), 2); // 2.236, closer to 2
    assert_eq!(u64::sqrt(6, nearest), 2); // 2.449, closer to 2
    assert_eq!(u64::sqrt(7, nearest), 3); // 2.646, closer to 3
    assert_eq!(u64::sqrt(8, nearest), 3); // 2.828, closer to 3

    // Between 9 (3^2) and 16 (4^2): midpoint at 12.5
    assert_eq!(u64::sqrt(12, nearest), 3); // 3.464, closer to 3
    assert_eq!(u64::sqrt(13, nearest), 4); // 3.606, closer to 4
}

#[test]
fun sqrt_handles_max_value() {
    let max = std::u64::max_value!();
    assert_eq!(u64::sqrt(max, rounding::down()), 4294967295);
    assert_eq!(u64::sqrt(max, rounding::up()), 4294967296);
    assert_eq!(u64::sqrt(max, rounding::nearest()), 4294967296);
}

// === inv_mod ===

#[test]
fun inv_mod_returns_some() {
    let result = u64::inv_mod(19, 1_000_000_007);
    assert_eq!(result, option::some(157_894_738));
}

#[test]
fun inv_mod_returns_none_when_not_coprime() {
    let result = u64::inv_mod(20, 100);
    assert_eq!(result, option::none());
}

#[test, expected_failure(abort_code = macros::EZeroModulus)]
fun inv_mod_rejects_zero_modulus() {
    u64::inv_mod(1, 0);
}

// === mul_mod ===

#[test]
fun mul_mod_handles_large_values() {
    let result = u64::mul_mod(987_654_321, 123_456_789, 1_000_000_007);
    assert_eq!(result, 259_106_859);
}

#[test, expected_failure(abort_code = macros::EZeroModulus)]
fun mul_mod_rejects_zero_modulus() {
    u64::mul_mod(3, 4, 0);
}

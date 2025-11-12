module openzeppelin_math::u128_tests;

use openzeppelin_math::macros;
use openzeppelin_math::rounding;
use openzeppelin_math::u128;
use std::unit_test::assert_eq;

// === average ===

#[test]
fun average_rounding_modes() {
    let down = u128::average(7, 10, rounding::down());
    assert_eq!(down, 8);

    let up = u128::average(7, 10, rounding::up());
    assert_eq!(up, 9);

    let nearest = u128::average(1, 2, rounding::nearest());
    assert_eq!(nearest, 2);
}

#[test]
fun average_is_commutative() {
    let left = u128::average(1_000, 100, rounding::nearest());
    let right = u128::average(100, 1_000, rounding::nearest());
    assert_eq!(left, right);
}

// === checked_shl ===

#[test]
fun checked_shl_returns_some() {
    // Shift a single 1 into the most-significant bit.
    let result = u128::checked_shl(1, 127);
    assert_eq!(result, option::some(1u128 << 127));
}

#[test]
fun checked_shl_zero_input_returns_zero_for_overshift() {
    assert_eq!(u128::checked_shl(0, 129), option::some(0));
}

#[test]
fun checked_shl_returns_same_for_zero_shift() {
    // Shifting by zero should return the same value.
    let value = 1u128 << 127;
    let result = u128::checked_shl(value, 0);
    assert_eq!(result, option::some(value));
}

#[test]
fun checked_shl_detects_high_bits() {
    // Highest bit already set — shifting would overflow.
    let result = u128::checked_shl(1u128 << 127, 1);
    assert_eq!(result, option::none());
}

#[test]
fun checked_shl_rejects_large_shift() {
    // Prevent width-sized shift that would abort.
    let result = u128::checked_shl(1, 128);
    assert_eq!(result, option::none());
}

// === checked_shr ===

#[test]
fun checked_shr_returns_some() {
    // 1 << 64 leaves a zeroed lower half that can be shifted out safely.
    let value = 1u128 << 64;
    let result = u128::checked_shr(value, 64);
    assert_eq!(result, option::some(1));
}

#[test]
fun checked_shr_zero_input_returns_zero_for_overshift() {
    assert_eq!(u128::checked_shr(0, 129), option::some(0));
}

#[test]
fun checked_shr_detects_set_bits() {
    // Detect loss when the LSB is still set.
    let result = u128::checked_shr(5, 1);
    assert_eq!(result, option::none());
}

#[test]
fun checked_shr_rejects_large_shift() {
    // Guard against shifting by the width.
    let result = u128::checked_shr(1, 128);
    assert_eq!(result, option::none());
}

// === mul_div ===

// Sanity-check rounding before we switch to the wide helper.
#[test]
fun mul_div_rounding_modes() {
    let (down_overflow, down) = u128::mul_div(70, 10, 4, rounding::down());
    assert_eq!(down_overflow, false);
    assert_eq!(down, 175);

    let (up_overflow, up) = u128::mul_div(5, 3, 4, rounding::up());
    assert_eq!(up_overflow, false);
    assert_eq!(up, 4);

    let (nearest_overflow, nearest) = u128::mul_div(
        7,
        10,
        4,
        rounding::nearest(),
    );
    assert_eq!(nearest_overflow, false);
    assert_eq!(nearest, 18);
}

// Straightforward division should not be perturbed by rounding.
#[test]
fun mul_div_exact_division() {
    let (overflow, exact) = u128::mul_div(8_000, 2, 4, rounding::up());
    assert_eq!(overflow, false);
    assert_eq!(exact, 4_000);
}

// Keep coverage over the shared macro guard.
#[test, expected_failure(abort_code = macros::EDivideByZero)]
fun mul_div_rejects_zero_denominator() {
    u128::mul_div(1, 1, 0, rounding::down());
}

// Casting down from u256 must still flag when values exceed u128’s range.
#[test]
fun mul_div_detects_overflow() {
    let (overflow, result) = u128::mul_div(
        std::u128::max_value!(),
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
    let result = u128::mul_shr(1_000_000_000_000, 10_000, 5, rounding::down());
    assert_eq!(result, option::some(312_500_000_000_000));
}

#[test]
fun mul_shr_respects_rounding_modes() {
    // 5*3 = 15; 15 >> 1 = 7.5
    let down = u128::mul_shr(5, 3, 1, rounding::down());
    assert_eq!(down, option::some(7));

    let up = u128::mul_shr(5, 3, 1, rounding::up());
    assert_eq!(up, option::some(8));

    let nearest = u128::mul_shr(5, 3, 1, rounding::nearest());
    assert_eq!(nearest, option::some(8));

    // 7*4 = 28; 28 >> 2 = 7.0
    let exact = u128::mul_shr(7, 4, 2, rounding::nearest());
    assert_eq!(exact, option::some(7));

    // 13*3 = 39; 39 >> 2 = 9.75
    let down2 = u128::mul_shr(13, 3, 2, rounding::down());
    assert_eq!(down2, option::some(9));

    let up2 = u128::mul_shr(13, 3, 2, rounding::up());
    assert_eq!(up2, option::some(10));

    let nearest2 = u128::mul_shr(13, 3, 2, rounding::nearest());
    assert_eq!(nearest2, option::some(10));

    // 7*3 = 21; 21 >> 2 = 5.25
    let down3 = u128::mul_shr(7, 3, 2, rounding::down());
    assert_eq!(down3, option::some(5));

    let up3 = u128::mul_shr(7, 3, 2, rounding::up());
    assert_eq!(up3, option::some(6));

    let nearest3 = u128::mul_shr(7, 3, 2, rounding::nearest());
    assert_eq!(nearest3, option::some(5));
}

#[test]
fun mul_shr_detects_overflow() {
    let overflow = u128::mul_shr(
        std::u128::max_value!(),
        std::u128::max_value!(),
        0,
        rounding::down(),
    );
    assert_eq!(overflow, option::none());
}

// === clz ===

#[test]
fun clz_returns_bit_width_for_zero() {
    // clz(0) should return 128 (all bits are leading zeros).
    let result = u128::clz(0);
    assert_eq!(result, 128);
}

#[test]
fun clz_returns_zero_for_top_bit_set() {
    // when the most significant bit is set, there are no leading zeros.
    let value = 1u128 << 127;
    let result = u128::clz(value);
    assert_eq!(result, 0);
}

#[test]
fun clz_returns_zero_for_max_value() {
    // max value has the top bit set, so no leading zeros.
    let max = std::u128::max_value!();
    let result = u128::clz(max);
    assert_eq!(result, 0);
}

// Test all possible bit positions from 0 to 127.
#[test]
fun clz_handles_all_bit_positions() {
    let mut bit_pos: u8 = 0;
    while (bit_pos < 128) {
        let value = 1u128 << bit_pos;
        let expected_clz = 127 - bit_pos;
        assert_eq!(u128::clz(value), expected_clz);
        bit_pos = bit_pos + 1;
    };
}

// Test that lower bits have no effect on the result.
#[test]
fun clz_lower_bits_have_no_effect() {
    let mut bit_pos: u8 = 0;
    while (bit_pos < 128) {
        let mut value = 1u128 << bit_pos;
        // set all bits below bit_pos to 1
        value = value | (value - 1);
        let expected_clz = 127 - bit_pos;
        assert_eq!(u128::clz(value), expected_clz);
        bit_pos = bit_pos + 1;
    };
}

#[test]
fun clz_counts_from_highest_bit() {
    // when multiple bits are set, clz counts from the highest bit.
    // 0b11 (bits 0 and 1 set) - highest is bit 1, so clz = 126
    assert_eq!(u128::clz(3), 126);

    // 0b1111 (bits 0-3 set) - highest is bit 3, so clz = 124
    assert_eq!(u128::clz(15), 124);

    // 0xff (bits 0-7 set) - highest is bit 7, so clz = 120
    assert_eq!(u128::clz(255), 120);
}

// Test values near power-of-2 boundaries.
#[test]
fun clz_handles_values_near_boundaries() {
    // 2^64 has bit 64 set, clz = 63
    assert_eq!(u128::clz(1 << 64), 63);

    // 2^64 - 1 has bit 63 set, clz = 64
    assert_eq!(u128::clz((1 << 64) - 1), 64);

    // 2^100 has bit 100 set, clz = 27
    assert_eq!(u128::clz(1 << 100), 27);

    // 2^100 - 1 has bit 99 set, clz = 28
    assert_eq!(u128::clz((1 << 100) - 1), 28);
}

// === log2 ===

#[test]
fun log2_returns_zero_for_zero() {
    // log2(0) should return 0 by convention
    assert_eq!(u128::log2(0, rounding::down()), 0);
    assert_eq!(u128::log2(0, rounding::up()), 0);
    assert_eq!(u128::log2(0, rounding::nearest()), 0);
}

#[test]
fun log2_returns_zero_for_one() {
    // log2(1) = 0 since 2^0 = 1
    assert_eq!(u128::log2(1, rounding::down()), 0);
    assert_eq!(u128::log2(1, rounding::up()), 0);
    assert_eq!(u128::log2(1, rounding::nearest()), 0);
}

#[test]
fun log2_handles_powers_of_two() {
    let rounding_modes = vector[rounding::down(), rounding::up(), rounding::nearest()];
    let mut i = 0;
    while (i < rounding_modes.length()) {
        // for powers of 2, log2 returns the exponent regardless of rounding mode
        let rounding = rounding_modes[i];
        assert_eq!(u128::log2(1 << 0, rounding), 0);
        assert_eq!(u128::log2(1 << 1, rounding), 1);
        assert_eq!(u128::log2(1 << 8, rounding), 8);
        assert_eq!(u128::log2(1 << 16, rounding), 16);
        assert_eq!(u128::log2(1 << 32, rounding), 32);
        assert_eq!(u128::log2(1 << 64, rounding), 64);
        assert_eq!(u128::log2(1 << 100, rounding), 100);
        assert_eq!(u128::log2(1 << 127, rounding), 127);
        i = i + 1;
    }
}

#[test]
fun log2_rounds_down() {
    // log2 with Down mode truncates to floor
    let down = rounding::down();
    assert_eq!(u128::log2(3, down), 1); // 1.58 → 1
    assert_eq!(u128::log2(5, down), 2); // 2.32 → 2
    assert_eq!(u128::log2(7, down), 2); // 2.81 → 2
    assert_eq!(u128::log2(15, down), 3); // 3.91 → 3
    assert_eq!(u128::log2(255, down), 7); // 7.99 → 7
}

#[test]
fun log2_rounds_up() {
    // log2 with Up mode rounds to ceiling
    let up = rounding::up();
    assert_eq!(u128::log2(3, up), 2); // 1.58 → 2
    assert_eq!(u128::log2(5, up), 3); // 2.32 → 3
    assert_eq!(u128::log2(7, up), 3); // 2.81 → 3
    assert_eq!(u128::log2(15, up), 4); // 3.91 → 4
    assert_eq!(u128::log2(255, up), 8); // 7.99 → 8
}

#[test]
fun log2_rounds_to_nearest() {
    // log2 with Nearest mode rounds to closest integer
    let nearest = rounding::nearest();
    assert_eq!(u128::log2(3, nearest), 2); // 1.58 → 2
    assert_eq!(u128::log2(5, nearest), 2); // 2.32 → 2
    assert_eq!(u128::log2(7, nearest), 3); // 2.81 → 3
    assert_eq!(u128::log2(15, nearest), 4); // 3.91 → 4
    assert_eq!(u128::log2(255, nearest), 8); // 7.99 → 8
}

#[test]
fun log2_handles_values_near_boundaries() {
    // test values just before and at power-of-2 boundaries
    let down = rounding::down();

    // 2^8 - 1 = 255
    assert_eq!(u128::log2((1 << 8) - 1, down), 7);
    // 2^8 = 256
    assert_eq!(u128::log2(1 << 8, down), 8);

    // 2^64 - 1
    assert_eq!(u128::log2((1 << 64) - 1, down), 63);
    // 2^64
    assert_eq!(u128::log2(1 << 64, down), 64);
}

#[test]
fun log2_handles_max_value() {
    // max value has all bits set, so log2 = 127
    let max = std::u128::max_value!();
    assert_eq!(u128::log2(max, rounding::down()), 127);
    assert_eq!(u128::log2(max, rounding::up()), 128);
    assert_eq!(u128::log2(max, rounding::nearest()), 128);
}

// === log256 ===

#[test]
fun log256_returns_zero_for_zero() {
    // log256(0) should return 0 by convention
    assert_eq!(u128::log256(0, rounding::down()), 0);
    assert_eq!(u128::log256(0, rounding::up()), 0);
    assert_eq!(u128::log256(0, rounding::nearest()), 0);
}

#[test]
fun log256_returns_zero_for_one() {
    // log256(1) = 0 since 256^0 = 1
    assert_eq!(u128::log256(1, rounding::down()), 0);
    assert_eq!(u128::log256(1, rounding::up()), 0);
    assert_eq!(u128::log256(1, rounding::nearest()), 0);
}

#[test]
fun log256_handles_powers_of_256() {
    // Test exact powers of 256
    let rounding_modes = vector[rounding::down(), rounding::up(), rounding::nearest()];
    let mut i = 0;
    while (i < rounding_modes.length()) {
        let rounding = rounding_modes[i];
        assert_eq!(u128::log256(1 << 8, rounding), 1); // 256^1 = 256
        assert_eq!(u128::log256(1 << 16, rounding), 2); // 256^2 = 65536
        assert_eq!(u128::log256(1 << 24, rounding), 3); // 256^3 = 16777216
        assert_eq!(u128::log256(1 << 32, rounding), 4); // 256^4 = 4294967296
        assert_eq!(u128::log256(1 << 64, rounding), 8); // 256^8 = 2^64
        assert_eq!(u128::log256(1 << 96, rounding), 12); // 256^12 = 2^96
        assert_eq!(u128::log256(1 << 120, rounding), 15); // 256^15 = 2^120
        i = i + 1;
    }
}

#[test]
fun log256_rounds_down() {
    // log256 with Down mode truncates to floor
    let down = rounding::down();
    assert_eq!(u128::log256(15, down), 0); // 0.488 → 0
    assert_eq!(u128::log256(16, down), 0); // 0.5 → 0
    assert_eq!(u128::log256(255, down), 0); // 0.999 → 0
    assert_eq!(u128::log256(1 << 8, down), 1); // 1 exactly
    assert_eq!(u128::log256((1 << 8) + 1, down), 1); // 1.001 → 1
    assert_eq!(u128::log256((1 << 16) - 1, down), 1); // 1.9999 → 1
    assert_eq!(u128::log256(1 << 16, down), 2); // 2 exactly
    assert_eq!(u128::log256((1 << 64) - 1, down), 7); // 7.9999 → 7
    assert_eq!(u128::log256(1 << 64, down), 8); // 8 exactly
    assert_eq!(u128::log256((1 << 120) - 1, down), 14); // 14.9999 → 14
    assert_eq!(u128::log256(1 << 120, down), 15); // 15 exactly
}

#[test]
fun log256_rounds_up() {
    // log256 with Up mode rounds to ceiling
    let up = rounding::up();
    assert_eq!(u128::log256(15, up), 1); // 0.488 → 1
    assert_eq!(u128::log256(16, up), 1); // 0.5 → 1
    assert_eq!(u128::log256(255, up), 1); // 0.999 → 1
    assert_eq!(u128::log256(1 << 8, up), 1); // 1 exactly
    assert_eq!(u128::log256((1 << 8) + 1, up), 2); // 1.001 → 2
    assert_eq!(u128::log256((1 << 16) - 1, up), 2); // 1.9999 → 2
    assert_eq!(u128::log256(1 << 16, up), 2); // 2 exactly
    assert_eq!(u128::log256((1 << 64) - 1, up), 8); // 7.9999 → 8
    assert_eq!(u128::log256(1 << 64, up), 8); // 8 exactly
    assert_eq!(u128::log256((1 << 120) - 1, up), 15); // 14.9999 → 15
    assert_eq!(u128::log256(1 << 120, up), 15); // 15 exactly
}

#[test]
fun log256_rounds_to_nearest() {
    // log256 with Nearest mode rounds to closest integer
    // Midpoint between 256^k and 256^(k+1) is 256^k × 16
    let nearest = rounding::nearest();
    // Between 256^0 and 256^1: midpoint is 16
    assert_eq!(u128::log256(15, nearest), 0); // 0.488 < 0.5 → 0
    assert_eq!(u128::log256(16, nearest), 1); // 0.5 → 1
    assert_eq!(u128::log256(255, nearest), 1); // 0.999 → 1
    // Between 256^1 and 256^2: midpoint is 4096
    assert_eq!(u128::log256((1 << 12) - 1, nearest), 1); // 1.4999 < 1.5 → 1
    assert_eq!(u128::log256(1 << 12, nearest), 2); // 1.5 → 2
    assert_eq!(u128::log256((1 << 16) - 1, nearest), 2); // 1.9999 → 2
    // Between 256^7 and 256^8: midpoint is 1 << 60
    assert_eq!(u128::log256((1 << 60) - 1, nearest), 7); // 7.4999 < 7.5 → 7
    assert_eq!(u128::log256(1 << 60, nearest), 8); // 7.5 → 8
    assert_eq!(u128::log256((1 << 64) - 1, nearest), 8); // 7.9999 → 8
}

#[test]
fun log256_handles_max_value() {
    // max value is less than 256^16 = 2^128, so log256 is less than 16
    let max = std::u128::max_value!();
    assert_eq!(u128::log256(max, rounding::down()), 15);
    assert_eq!(u128::log256(max, rounding::up()), 16);
    assert_eq!(u128::log256(max, rounding::nearest()), 16);
}

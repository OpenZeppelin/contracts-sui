module openzeppelin_math::macros_tests;

use openzeppelin_math::macros;
use openzeppelin_math::rounding;
use openzeppelin_math::u512;
use std::unit_test::assert_eq;

// === mul_div ===

#[test]
fun fast_rounding_modes() {
    // Downward rounding leaves the truncated quotient untouched.
    let down = macros::mul_div_u256_fast(7, 10, 4, rounding::down());
    assert_eq!(down, 17);

    // Force a manual round-up.
    let up = macros::mul_div_u256_fast(5, 3, 4, rounding::up());
    assert_eq!(up, 4);

    // Nearest rounds down when the remainder is small.
    let nearest_down = macros::mul_div_u256_fast(6, 1, 5, rounding::nearest());
    assert_eq!(nearest_down, 1);

    // Nearest rounds up when the remainder dominates.
    let nearest_up = macros::mul_div_u256_fast(9, 1, 5, rounding::nearest());
    assert_eq!(nearest_up, 2);
}

#[test]
fun fast_handles_exact_division() {
    // An exact division should never apply rounding adjustments.
    let exact = macros::mul_div_u256_fast(8, 2, 4, rounding::up());
    assert_eq!(exact, 4);
}

#[test, expected_failure(abort_code = macros::EDivideByZero)]
fun fast_rejects_zero_denominator() {
    macros::mul_div_u256_fast(1, 1, 0, rounding::down());
}

#[test]
fun wide_matches_u512_downward() {
    let large = (std::u128::max_value!() as u256) + 1;
    let numerator = u512::mul_u256(large, large);
    let (overflow, baseline, _) = u512::div_rem_u256(numerator, 7);
    assert_eq!(overflow, false);
    let (macro_overflow, wide) = macros::mul_div_u256_wide(
        large,
        large,
        7,
        rounding::down(),
    );
    assert_eq!(macro_overflow, false);
    assert_eq!(wide, baseline);
}

#[test]
fun wide_respects_rounding_modes() {
    let large = (std::u128::max_value!() as u256) + 1;
    let numerator = u512::mul_u256(large, large);
    let (_, baseline, remainder) = u512::div_rem_u256(numerator, 7);
    assert!(remainder != 0);

    // Rounding up always bumps the truncated quotient when remainder is non-zero.
    let (overflow_up, up) = macros::mul_div_u256_wide(
        large,
        large,
        7,
        rounding::up(),
    );
    assert_eq!(overflow_up, false);
    assert_eq!(up, baseline + 1);

    // Nearest mirrors `rounding::down` when the remainder is small...
    let denom_down = 13;
    let (_, baseline_down, remainder_down) = u512::div_rem_u256(
        numerator,
        denom_down,
    );
    assert!(remainder_down < denom_down - remainder_down);
    let (overflow_nearest_down, nearest_down) = macros::mul_div_u256_wide(
        large,
        large,
        denom_down,
        rounding::nearest(),
    );
    assert_eq!(overflow_nearest_down, false);
    assert_eq!(nearest_down, baseline_down);

    // ...and bumps when the remainder dominates.
    let denom_up = 11;
    let (_, baseline_up, remainder_up) = u512::div_rem_u256(
        numerator,
        denom_up,
    );
    assert!(remainder_up >= denom_up - remainder_up);
    let (overflow_nearest_up, nearest_up) = macros::mul_div_u256_wide(
        large,
        large,
        denom_up,
        rounding::nearest(),
    );
    assert_eq!(overflow_nearest_up, false);
    assert_eq!(nearest_up, baseline_up + 1);
}

#[test, expected_failure(abort_code = macros::EDivideByZero)]
fun wide_rejects_zero_denominator() {
    let large = (std::u128::max_value!() as u256) + 1;
    macros::mul_div_u256_wide(large, large, 0, rounding::down());
}

#[test]
fun wide_detects_overflowing_quotient() {
    let max = std::u256::max_value!();
    let (overflow, _) = macros::mul_div_u256_wide(
        max,
        max,
        1,
        rounding::down(),
    );
    assert_eq!(overflow, true);
}

#[test]
fun macro_uses_fast_path_for_small_inputs() {
    let (overflow, result) = macros::mul_div!(15u8, 3u8, 4u8, rounding::down());
    assert_eq!(overflow, false);
    let expected = macros::mul_div_u256_fast(15, 3, 4, rounding::down());
    assert_eq!(result, expected);
}

#[test]
fun macro_uses_wide_path_for_large_inputs() {
    let large = (std::u128::max_value!() as u256) + 1;
    let (overflow, macro_result) = macros::mul_div!(large, large, 7, rounding::down());
    assert_eq!(overflow, false);
    let (wide_overflow, expected) = macros::mul_div_u256_wide(
        large,
        large,
        7,
        rounding::down(),
    );
    assert_eq!(wide_overflow, false);
    assert_eq!(macro_result, expected);
}

#[test, expected_failure(abort_code = macros::EDivideByZero)]
fun macro_rejects_zero_denominator() {
    macros::mul_div!(1u64, 1u64, 0u64, rounding::down());
}

// === checked_shr ===

#[test]
fun checked_shr_returns_some() {
    // 0b1_0000_0000 >> 8 lands on 0b1 without precision loss.
    let result = macros::checked_shr!(256u16, 8);
    assert_eq!(result, option::some(1u16));
}

#[test]
fun checked_shr_detects_set_bits() {
    // Detect that the low bit would be truncated.
    let result = macros::checked_shr!(5u32, 1);
    assert_eq!(result, option::none());
}

// === checked_shl ===

#[test]
fun checked_shl_returns_some() {
    // 0x0001 << 8 remains within the u16 range.
    let result = macros::checked_shl!(1u16, 8);
    assert_eq!(result, option::some(256u16));
}

#[test]
fun checked_shl_detects_high_bits() {
    // Highest bit of u256 set — shifting would overflow the 256-bit range.
    let result = macros::checked_shl!(std::u256::max_value!(), 1);
    assert_eq!(result, option::none());
}

// === average ===

#[test]
fun average_respects_rounding_modes() {
    let down = macros::average!(4u64, 7u64, rounding::down());
    assert_eq!(down, 5u64);

    let up = macros::average!(4u64, 7u64, rounding::up());
    assert_eq!(up, 6u64);

    let nearest = macros::average!(1u16, 2u16, rounding::nearest());
    assert_eq!(nearest, 2u16);

    let reversed = macros::average!(7u32, 4u32, rounding::down());
    assert_eq!(reversed, 5u32);
}

#[test]
fun average_handles_large_inputs() {
    let max = std::u256::max_value!();
    let almost = max - 1;

    let down = macros::average!(max, almost, rounding::down());
    assert_eq!(down, almost);

    let up = macros::average!(max, almost, rounding::up());
    assert_eq!(up, max);
}

#[test]
fun average_of_equal_values() {
    let value = 42u64;
    assert_eq!(macros::average!(value, value, rounding::down()), value);
    assert_eq!(macros::average!(value, value, rounding::up()), value);
    assert_eq!(macros::average!(value, value, rounding::nearest()), value);
}

// === clz ===

#[test]
fun clz_returns_bit_width_for_zero() {
    // clz(0) should return the bit width (all bits are leading zeros)
    assert_eq!(macros::clz!(0u8, 8), 8);
    assert_eq!(macros::clz!(0u16, 16), 16);
    assert_eq!(macros::clz!(0u32, 32), 32);
    assert_eq!(macros::clz!(0u64, 64), 64);
    assert_eq!(macros::clz!(0u128, 128), 128);
    assert_eq!(macros::clz!(0u256, 256), 256);
}

#[test]
fun clz_returns_zero_for_top_bit_set() {
    // when the most significant bit is set, there are no leading zeros
    assert_eq!(macros::clz!(1u8 << 7, 8), 0);
    assert_eq!(macros::clz!(1u16 << 15, 16), 0);
    assert_eq!(macros::clz!(1u32 << 31, 32), 0);
    assert_eq!(macros::clz!(1u64 << 63, 64), 0);
    assert_eq!(macros::clz!(1u128 << 127, 128), 0);
    assert_eq!(macros::clz!(1u256 << 255, 256), 0);
}

#[test]
fun clz_returns_zero_for_max_value() {
    // max value has the top bit set, so no leading zeros
    assert_eq!(macros::clz!(std::u8::max_value!(), 8), 0);
    assert_eq!(macros::clz!(std::u16::max_value!(), 16), 0);
    assert_eq!(macros::clz!(std::u32::max_value!(), 32), 0);
    assert_eq!(macros::clz!(std::u64::max_value!(), 64), 0);
    assert_eq!(macros::clz!(std::u128::max_value!(), 128), 0);
    assert_eq!(macros::clz!(std::u256::max_value!(), 256), 0);
}

#[test]
fun clz_handles_powers_of_two() {
    // for powers of 2, clz returns bit_width - 1 - log2(value)
    assert_eq!(macros::clz!(1u8, 8), 7); // 2^0
    assert_eq!(macros::clz!(2u8, 8), 6); // 2^1
    assert_eq!(macros::clz!(4u8, 8), 5); // 2^2
    assert_eq!(macros::clz!(8u8, 8), 4); // 2^3

    assert_eq!(macros::clz!(1u64, 64), 63); // 2^0
    assert_eq!(macros::clz!(256u64, 64), 55); // 2^8
    assert_eq!(macros::clz!(65536u64, 64), 47); // 2^16

    assert_eq!(macros::clz!(1u256, 256), 255); // 2^0
    assert_eq!(macros::clz!(1u256 << 64, 256), 191); // 2^64
    assert_eq!(macros::clz!(1u256 << 128, 256), 127); // 2^128
}

#[test]
fun clz_lower_bits_have_no_effect() {
    // when lower bits are set, they don't affect the clz count
    // 0b11 = 3: highest bit is 1, so clz = 6 for u8
    assert_eq!(macros::clz!(3u8, 8), 6);
    // 0b111 = 7: highest bit is 2, so clz = 5 for u8
    assert_eq!(macros::clz!(7u8, 8), 5);
    // 0b1111 = 15: highest bit is 3, so clz = 4 for u8
    assert_eq!(macros::clz!(15u8, 8), 4);

    // For u256: 255 = 0xff (bits 0-7 set), highest is bit 7, so clz = 248
    assert_eq!(macros::clz!(255u256, 256), 248);
    // 65535 = 0xffff (bits 0-15 set), highest is bit 15, so clz = 240
    assert_eq!(macros::clz!(65535u256, 256), 240);
}

#[test]
fun clz_handles_values_near_boundaries() {
    // test values just before and at power-of-2 boundaries
    // 2^8 = 256
    assert_eq!(macros::clz!(256u16, 16), 7);
    // 2^8 - 1 = 255
    assert_eq!(macros::clz!(255u16, 16), 8);

    // 2^16 = 65536
    assert_eq!(macros::clz!(65536u32, 32), 15);
    // 2^16 - 1 = 65535
    assert_eq!(macros::clz!(65535u32, 32), 16);

    // 2^32
    assert_eq!(macros::clz!(1u64 << 32, 64), 31);
    // 2^32 - 1
    assert_eq!(macros::clz!((1u64 << 32) - 1, 64), 32);
}

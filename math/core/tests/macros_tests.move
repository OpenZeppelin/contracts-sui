module openzeppelin_math::macros_tests;

use openzeppelin_math::macros;
use openzeppelin_math::rounding;
use openzeppelin_math::u512;
use std::unit_test::assert_eq;

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

// === mul_div ===

#[test]
fun mul_div_fast_rounding_modes() {
    // Downward rounding leaves the truncated quotient untouched.
    let (overflow_down, down) = macros::mul_div_u256_fast(7, 10, 4, rounding::down());
    assert_eq!(overflow_down, false);
    assert_eq!(down, 17u256);

    // Force a manual round-up.
    let (overflow_up, up) = macros::mul_div_u256_fast(5, 3, 4, rounding::up());
    assert_eq!(overflow_up, false);
    assert_eq!(up, 4);

    // Nearest rounds down when the remainder is small.
    let (overflow_nearest_down, nearest_down) = macros::mul_div_u256_fast(
        6,
        1,
        5,
        rounding::nearest(),
    );
    assert_eq!(overflow_nearest_down, false);
    assert_eq!(nearest_down, 1);

    // Nearest rounds up when the remainder dominates.
    let (overflow_nearest_up, nearest_up) = macros::mul_div_u256_fast(9, 1, 5, rounding::nearest());
    assert_eq!(overflow_nearest_up, false);
    assert_eq!(nearest_up, 2);
}

#[test]
fun mul_div_fast_handles_exact_division() {
    // An exact division should never apply rounding adjustments.
    let (_, exact) = macros::mul_div_u256_fast(8, 2, 4, rounding::up());
    assert_eq!(exact, 4);
}

#[test, expected_failure(abort_code = macros::EDivideByZero)]
fun mul_div_fast_rejects_zero_denominator() {
    macros::mul_div_u256_fast(1, 1, 0, rounding::down());
}

#[test]
fun mul_div_wide_matches_u512_downward() {
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
fun mul_div_wide_respects_rounding_modes() {
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
fun mul_div_wide_rejects_zero_denominator() {
    let large = (std::u128::max_value!() as u256) + 1;
    macros::mul_div_u256_wide(large, large, 0, rounding::down());
}

#[test]
fun mul_div_wide_detects_overflowing_quotient() {
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
fun mul_div_macro_uses_fast_path_for_small_inputs() {
    let (overflow, result) = macros::mul_div!(15u8, 3u8, 4u8, rounding::down());
    assert_eq!(overflow, false);
    let (_, expected) = macros::mul_div_u256_fast(15, 3, 4, rounding::down());
    assert_eq!(result, expected);
}

#[test]
fun mul_div_macro_uses_wide_path_for_large_inputs() {
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
fun mul_div_macro_rejects_zero_denominator() {
    macros::mul_div!(1u64, 1u64, 0u64, rounding::down());
}

// === mul_shr ===

#[test]
fun mul_shr_fast_basic_shift() {
    // Verify the fast helper performs a simple shift when no rounding is needed.
    let (overflow, result) = macros::mul_shr_u256_fast(9, 4, 3, rounding::down());
    assert_eq!(overflow, false);
    assert_eq!(result, 4u256);
}

#[test]
fun mul_shr_fast_rounding_modes() {
    // Downward rounding should truncate without adjustment.
    let (overflow_down, down) = macros::mul_shr_u256_fast(15, 3, 1, rounding::down());
    assert_eq!(overflow_down, false);
    assert_eq!(down, 22u256);

    // Upward rounding always bumps when remainder is non-zero.
    let (overflow_up, up) = macros::mul_shr_u256_fast(15, 3, 1, rounding::up());
    assert_eq!(overflow_up, false);
    assert_eq!(up, 23u256);

    // Nearest should match the upward result when the remainder is large enough.
    let (overflow_nearest, nearest) = macros::mul_shr_u256_fast(15, 3, 1, rounding::nearest());
    assert_eq!(overflow_nearest, false);
    assert_eq!(nearest, 23u256);
}

#[test]
fun mul_shr_fast_zero_shift_preserves_product() {
    // When shift is zero, expect the raw product to be returned untouched.
    let (overflow, result) = macros::mul_shr_u256_fast(1234, 5678, 0, rounding::nearest());
    assert_eq!(overflow, false);
    assert_eq!(result, 1234 * 5678);
}

#[test]
fun mul_shr_fast_tie_rounds_up() {
    // Product 3 * 5 = 15; shifting by one yields a tie that `nearest` resolves upward.
    let (overflow, nearest) = macros::mul_shr_u256_fast(3, 5, 1, rounding::nearest());
    assert_eq!(overflow, false);
    assert_eq!(nearest, 8);
}

#[test]
fun mul_shr_wide_crosses_limbs() {
    // Exercise the path where the cross-limb carry is needed to produce the result.
    let a = 1 << 255;
    let b = 2;
    let (overflow, result) = macros::mul_shr_u256_wide(a, b, 1, rounding::down());
    assert_eq!(overflow, false);
    assert_eq!(result, 1 << 255);
}

#[test]
fun mul_shr_wide_matches_div_rem_logic() {
    // Compare against the exact 512-bit division to ensure rounding mirrors div/rem semantics.
    let a = (1u256 << 180) + 123u256;
    let b = (1u256 << 60) + 7u256;
    let shift: u8 = 5;
    let product = u512::mul_u256(a, b);
    let denominator = 1u256 << shift;
    let (div_overflow, quotient, remainder) = u512::div_rem_u256(product, denominator);
    assert_eq!(div_overflow, false);
    assert!(remainder != 0);

    let (overflow_down, down) = macros::mul_shr_u256_wide(a, b, shift, rounding::down());
    assert_eq!(overflow_down, false);
    assert_eq!(down, quotient);

    let (overflow_up, up) = macros::mul_shr_u256_wide(a, b, shift, rounding::up());
    assert_eq!(overflow_up, false);
    assert_eq!(up, quotient + 1);

    let (overflow_nearest, nearest) = macros::mul_shr_u256_wide(a, b, shift, rounding::nearest());
    assert_eq!(overflow_nearest, false);
    let should_round_up = remainder >= denominator - remainder;
    let expected_nearest = if (should_round_up) {
        quotient + 1
    } else {
        quotient
    };
    assert_eq!(nearest, expected_nearest);
}

#[test]
fun mul_shr_wide_detects_shift_overflow() {
    // Shifting a full-width product by one should overflow the 256-bit range.
    let max = std::u256::max_value!();
    let (overflow, _) = macros::mul_shr_u256_wide(max, max, 1, rounding::down());
    assert_eq!(overflow, true);
}

#[test]
fun mul_shr_wide_detects_zero_shift_overflow() {
    // Zero shift with a full-width product reports overflow via the helper.
    let max = std::u256::max_value!();
    let (overflow, result) = macros::mul_shr_u256_wide(max, max, 0, rounding::nearest());
    assert_eq!(overflow, true);
    assert_eq!(result, 0);
}

#[test]
fun mul_shr_inner_uses_fast_path() {
    // Small operands should be routed to the fast helper internally.
    let (inner_overflow, inner) = macros::mul_shr_inner(9, 4, 3, rounding::down());
    let (fast_overflow, fast) = macros::mul_shr_u256_fast(9, 4, 3, rounding::down());
    assert_eq!(inner_overflow, fast_overflow);
    assert_eq!(inner, fast);
}

#[test]
fun mul_shr_inner_uses_wide_path() {
    // Large operands force the selector to use the wide helper.
    let large = (std::u128::max_value!() as u256) + 1;
    let shift: u8 = 4;
    let (inner_overflow, inner) = macros::mul_shr_inner(large, large, shift, rounding::nearest());
    let (wide_overflow, wide) = macros::mul_shr_u256_wide(large, large, shift, rounding::nearest());
    assert_eq!(inner_overflow, wide_overflow);
    assert_eq!(inner, wide);
}

#[test]
fun mul_shr_macro_fast_path_matches_helper() {
    // Macro should agree with the fast helper when operands stay below the threshold.
    let (macro_overflow, macro_result) = macros::mul_shr!(9u32, 4u32, 3u8, rounding::down());
    let (fast_overflow, fast_result) = macros::mul_shr_u256_fast(9, 4, 3, rounding::down());
    assert_eq!(macro_overflow, fast_overflow);
    assert_eq!(macro_result, fast_result);
}

#[test]
fun mul_shr_macro_wide_path_matches_helper() {
    // And it should delegate to the wide helper when inputs exceed the fast-path bounds.
    let large = (std::u128::max_value!() as u256) + 1;
    let shift: u8 = 4;
    let (macro_overflow, macro_result) = macros::mul_shr!(large, large, shift, rounding::nearest());
    let (wide_overflow, wide_result) = macros::mul_shr_u256_wide(
        large,
        large,
        shift,
        rounding::nearest(),
    );
    assert_eq!(macro_overflow, wide_overflow);
    assert_eq!(macro_result, wide_result);
}

#[test]
fun mul_shr_macro_detects_overflow() {
    // Macro surface must mirror the helper's overflow reporting.
    let max = std::u256::max_value!();
    let (overflow, result) = macros::mul_shr!(max, max, 1u8, rounding::down());
    assert_eq!(overflow, true);
    assert_eq!(result, 0);
}

#[test]
fun round_division_result_handles_rounding_modes() {
    let (overflow_down, rounded_down) = macros::round_division_result(
        10,
        16,
        1,
        rounding::nearest(),
    );
    assert_eq!(overflow_down, false);
    assert_eq!(rounded_down, 10u256);

    let (overflow_nearest, rounded_nearest) = macros::round_division_result(
        10,
        8,
        4,
        rounding::nearest(),
    );
    assert_eq!(overflow_nearest, false);
    assert_eq!(rounded_nearest, 11u256);

    let max = std::u256::max_value!();
    let (overflow_up, _) = macros::round_division_result(max, 2, 1, rounding::up());
    assert_eq!(overflow_up, true);
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

// === log2 ===

#[test]
fun log2_returns_zero_for_zero() {
    // log2(0) should return 0 by convention
    assert_eq!(macros::log2!(0u8, 8, rounding::down()), 0);
    assert_eq!(macros::log2!(0u8, 8, rounding::up()), 0);
    assert_eq!(macros::log2!(0u8, 8, rounding::nearest()), 0);
    assert_eq!(macros::log2!(0u16, 16, rounding::down()), 0);
    assert_eq!(macros::log2!(0u32, 32, rounding::up()), 0);
    assert_eq!(macros::log2!(0u64, 64, rounding::nearest()), 0);
    assert_eq!(macros::log2!(0u128, 128, rounding::down()), 0);
    assert_eq!(macros::log2!(0u256, 256, rounding::up()), 0);
}

#[test]
fun log2_returns_zero_for_one() {
    // log2(1) = 0 since 2^0 = 1
    assert_eq!(macros::log2!(1u8, 8, rounding::down()), 0);
    assert_eq!(macros::log2!(1u8, 8, rounding::up()), 0);
    assert_eq!(macros::log2!(1u8, 8, rounding::nearest()), 0);
    assert_eq!(macros::log2!(1u16, 16, rounding::down()), 0);
    assert_eq!(macros::log2!(1u32, 32, rounding::up()), 0);
    assert_eq!(macros::log2!(1u64, 64, rounding::nearest()), 0);
    assert_eq!(macros::log2!(1u128, 128, rounding::down()), 0);
    assert_eq!(macros::log2!(1u256, 256, rounding::up()), 0);
}

#[test]
fun log2_rounding_mode_nearest() {
    let nearest = rounding::nearest();
    assert_eq!(macros::log2!(6u8, 8, nearest), 3); // 2.585 -> 3
    assert_eq!(macros::log2!(11u16, 16, nearest), 3); // 3.459 -> 3
    assert_eq!(macros::log2!(12u16, 16, nearest), 4); // 3.585 -> 4
    assert_eq!(macros::log2!(22u32, 32, nearest), 4); // 4.459 -> 4
    assert_eq!(macros::log2!(23u32, 32, nearest), 5); // 4.524 -> 5
    assert_eq!(macros::log2!(45u64, 64, nearest), 5); // 5.492 -> 5
    assert_eq!(macros::log2!(46u64, 64, nearest), 6); // 5.524 -> 6
    assert_eq!(macros::log2!(90u128, 128, nearest), 6); // 6.492 -> 6
    assert_eq!(macros::log2!(91u128, 128, nearest), 7); // 6.508 -> 7
    assert_eq!(macros::log2!(181u256, 256, nearest), 7); // 7.4998 -> 7
    assert_eq!(macros::log2!(182u256, 256, nearest), 8); // 7.5078 -> 8
}

#[test]
fun log2_rounding_mode_nearest_high_values() {
    let val_1 = 0xB504F261779BF7325BF8F7DB0AAFE8F8227AE7E69797296F9526CCD8BBF32000u256;
    assert_eq!(macros::log2!(val_1, 256, rounding::nearest()), 255); // 255.4999 -> 255
    let val_2 = 0xB504FB6D10AAFE26CC0E4F709AB10D92CEBF3593218E22304000000000000000u256;
    assert_eq!(macros::log2!(val_2, 256, rounding::nearest()), 256); // 255.500001 -> 256
}

// === log256 ===

#[test]
fun log256_returns_zero_for_zero() {
    // log256(0) should return 0 by convention
    assert_eq!(macros::log256!(0u8, 8, rounding::down()), 0);
    assert_eq!(macros::log256!(0u8, 8, rounding::up()), 0);
    assert_eq!(macros::log256!(0u8, 8, rounding::nearest()), 0);
    assert_eq!(macros::log256!(0u16, 16, rounding::down()), 0);
    assert_eq!(macros::log256!(0u32, 32, rounding::up()), 0);
    assert_eq!(macros::log256!(0u64, 64, rounding::nearest()), 0);
    assert_eq!(macros::log256!(0u128, 128, rounding::down()), 0);
    assert_eq!(macros::log256!(0u256, 256, rounding::up()), 0);
}

#[test]
fun log256_returns_zero_for_one() {
    // log256(1) = 0 since 256^0 = 1
    assert_eq!(macros::log256!(1u8, 8, rounding::down()), 0);
    assert_eq!(macros::log256!(1u8, 8, rounding::up()), 0);
    assert_eq!(macros::log256!(1u8, 8, rounding::nearest()), 0);
    assert_eq!(macros::log256!(1u16, 16, rounding::down()), 0);
    assert_eq!(macros::log256!(1u32, 32, rounding::up()), 0);
    assert_eq!(macros::log256!(1u64, 64, rounding::nearest()), 0);
    assert_eq!(macros::log256!(1u128, 128, rounding::down()), 0);
    assert_eq!(macros::log256!(1u256, 256, rounding::up()), 0);
}

#[test]
fun log256_handles_powers_of_256() {
    // for powers of 256, log256 returns the exponent regardless of rounding mode
    let rounding_modes = vector[rounding::down(), rounding::up(), rounding::nearest()];
    rounding_modes.destroy!(|rounding| {
        // 256^0 = 1
        assert_eq!(macros::log256!(1u16, 16, rounding), 0);
        // 256^1 = 2^8
        assert_eq!(macros::log256!(1u16 << 8, 16, rounding), 1);
        // 256^2 = 2^16
        assert_eq!(macros::log256!(1u32 << 16, 32, rounding), 2);
        // 256^3 = 2^24
        assert_eq!(macros::log256!(1u32 << 24, 32, rounding), 3);
        // 256^4 = 2^32
        assert_eq!(macros::log256!(1u64 << 32, 64, rounding), 4);
        // 256^8 = 2^64
        assert_eq!(macros::log256!(1u128 << 64, 128, rounding), 8);
        // 256^16 = 2^128
        assert_eq!(macros::log256!(1u256 << 128, 256, rounding), 16);
        // 256^31 = 2^248
        assert_eq!(macros::log256!(1u256 << 248, 256, rounding), 31);
    });
}

#[test]
fun log256_rounds_down() {
    // log256 with Down mode truncates to floor
    let down = rounding::down();
    assert_eq!(macros::log256!((1u16 << 8) - 1, 16, down), 0); // log256(255) < 1 → 0
    assert_eq!(macros::log256!((1u16 << 8) + 1, 16, down), 1); // log256(257) > 1 → 1
    assert_eq!(macros::log256!((1u32 << 16) - 1, 32, down), 1); // log256(65535) < 2 → 1
    assert_eq!(macros::log256!((1u32 << 16) + 1, 32, down), 2); // log256(65537) > 2 → 2
    assert_eq!(macros::log256!((1u64 << 24) - 1, 64, down), 2); // log256(16777215) < 3 → 2
    assert_eq!(macros::log256!((1u64 << 24) + 1, 64, down), 3); // log256(16777217) > 3 → 3
}

#[test]
fun log256_rounds_up() {
    // log256 with Up mode rounds to ceiling
    let up = rounding::up();
    assert_eq!(macros::log256!((1u16 << 8) - 1, 16, up), 1); // log256(255) < 1 → 1
    assert_eq!(macros::log256!((1u16 << 8) + 1, 16, up), 2); // log256(257) > 2 → 2
    assert_eq!(macros::log256!((1u32 << 16) - 1, 32, up), 2); // log256(65535) < 3 → 2
    assert_eq!(macros::log256!((1u32 << 16) + 1, 32, up), 3); // log256(65537) > 3 → 3
    assert_eq!(macros::log256!((1u64 << 24) - 1, 64, up), 3); // log256(16777215) < 4 → 3
    assert_eq!(macros::log256!((1u64 << 24) + 1, 64, up), 4); // log256(16777217) > 4 → 4
}

#[test]
fun log256_rounds_to_nearest() {
    // log256 with Nearest mode rounds to closest integer
    // Midpoint is 256^k × √256 = 256^k × 16
    let nearest = rounding::nearest();

    // Between 256^0 and 256^1: midpoint is 16
    assert_eq!(macros::log256!(15u8, 8, nearest), 0); // < 16, rounds down
    assert_eq!(macros::log256!(16u8, 8, nearest), 1); // >= 16, rounds up
    assert_eq!(macros::log256!(255u16, 16, nearest), 1); // > 16, rounds up

    // Between 256^1 and 256^2: midpoint is 256 × 16 = 4096
    assert_eq!(macros::log256!(4095u16, 16, nearest), 1); // < 4096, rounds down
    assert_eq!(macros::log256!(4096u16, 16, nearest), 2); // >= 4096, rounds up
    assert_eq!(macros::log256!(65535u32, 32, nearest), 2); // > 4096, rounds up

    // Between 256^2 and 256^3: midpoint is 65536 × 16 = 1048576
    assert_eq!(macros::log256!(1048575u32, 32, nearest), 2); // < 1048576, rounds down
    assert_eq!(macros::log256!(1048576u32, 32, nearest), 3); // >= 1048576, rounds up
    assert_eq!(macros::log256!(16777215u32, 32, nearest), 3); // > 1048576, rounds up
}

#[test]
fun log256_handles_max_values() {
    // Test with maximum values for different types
    assert_eq!(macros::log256!(std::u8::max_value!(), 8, rounding::down()), 0);
    assert_eq!(macros::log256!(std::u8::max_value!(), 8, rounding::up()), 1);
    assert_eq!(macros::log256!(std::u8::max_value!(), 8, rounding::nearest()), 1);

    assert_eq!(macros::log256!(std::u64::max_value!(), 64, rounding::down()), 7);
    assert_eq!(macros::log256!(std::u64::max_value!(), 64, rounding::up()), 8);
    assert_eq!(macros::log256!(std::u64::max_value!(), 64, rounding::nearest()), 8);

    assert_eq!(macros::log256!(std::u256::max_value!(), 256, rounding::down()), 31);
    assert_eq!(macros::log256!(std::u256::max_value!(), 256, rounding::up()), 32);
    assert_eq!(macros::log256!(std::u256::max_value!(), 256, rounding::nearest()), 32);
}

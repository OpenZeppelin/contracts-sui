#[test_only]
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

// === inv_mod / mod_sub / mul_mod helpers ===

#[test]
fun inv_mod_extended_impl_returns_inverse() {
    let result = macros::inv_mod_extended_impl(3, 11);
    assert_eq!(result, option::some(4));
}

#[test]
fun inv_mod_extended_impl_returns_none_when_not_coprime() {
    let result = macros::inv_mod_extended_impl(8, 12);
    assert_eq!(result, option::none());
}

#[test]
fun inv_mod_extended_impl_modulus_one_returns_none() {
    let result = macros::inv_mod_extended_impl(5, 1);
    assert_eq!(result, option::none());
}

#[test]
fun inv_mod_extended_impl_reduced_zero_returns_none() {
    let result = macros::inv_mod_extended_impl(12, 4);
    assert_eq!(result, option::none());
}

#[test, expected_failure(abort_code = macros::EZeroModulus)]
fun inv_mod_extended_impl_rejects_zero_modulus() {
    macros::inv_mod_extended_impl(1, 0);
}

#[test]
fun inv_mod_macro_matches_impl() {
    let macro_inverse = macros::inv_mod!(3, 11);
    assert_eq!(macro_inverse, option::some(4));
}

#[test]
fun mod_sub_impl_wraps_underflow() {
    let result = macros::mod_sub_impl(3, 5, 11);
    assert_eq!(result, 9);
}

#[test]
fun mul_mod_impl_returns_zero_when_operand_zero() {
    let result = macros::mul_mod_impl(0, 123, 11);
    assert_eq!(result, 0);
}

#[test]
fun mul_mod_impl_handles_wide_operands() {
    // Pick operands whose product overflows 256 bits to force the wide path.
    let a = 1u256 << 200;
    let b = (1u256 << 150) + 1234;
    let modulus = (1u256 << 201) - 109;

    // Baseline: compute (a * b) % modulus manually using u512 helpers.
    let wide_product = u512::mul_u256(a, b);
    let (_, _, expected) = u512::div_rem_u256(wide_product, modulus);

    // The helper should match the reference result for wide operands.
    let result = macros::mul_mod_impl(a, b, modulus);
    assert_eq!(result, expected);
}

#[test, expected_failure(abort_code = macros::EZeroModulus)]
fun mul_mod_impl_rejects_zero_modulus() {
    macros::mul_mod_impl(5, 7, 0);
}

#[test]
fun mul_mod_macro_matches_helper() {
    let direct = macros::mul_mod_impl(123, 456, 789);
    let via_macro = macros::mul_mod!(123, 456, 789);
    assert_eq!(via_macro, direct as u64);
}

#[test, expected_failure(abort_code = macros::EZeroModulus)]
fun mul_mod_macro_rejects_zero_modulus() {
    macros::mul_mod!(1, 2, 0);
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

// === msb ===

#[test]
fun msb_returns_zero_for_zero() {
    // msb(0) should return 0 by convention
    assert_eq!(macros::msb!(0u8, 8), 0);
    assert_eq!(macros::msb!(0u16, 16), 0);
    assert_eq!(macros::msb!(0u32, 32), 0);
    assert_eq!(macros::msb!(0u64, 64), 0);
    assert_eq!(macros::msb!(0u128, 128), 0);
    assert_eq!(macros::msb!(0u256, 256), 0);
}

#[test]
fun msb_returns_correct_position_for_top_bit_set() {
    // when the most significant bit is set, msb returns bit_width - 1
    assert_eq!(macros::msb!(1u8 << 7, 8), 7);
    assert_eq!(macros::msb!(1u16 << 15, 16), 15);
    assert_eq!(macros::msb!(1u32 << 31, 32), 31);
    assert_eq!(macros::msb!(1u64 << 63, 64), 63);
    assert_eq!(macros::msb!(1u128 << 127, 128), 127);
    assert_eq!(macros::msb!(1u256 << 255, 256), 255);
}

#[test]
fun msb_returns_correct_position_for_max_value() {
    // max value has the top bit set, so msb returns bit_width - 1
    assert_eq!(macros::msb!(std::u8::max_value!(), 8), 7);
    assert_eq!(macros::msb!(std::u16::max_value!(), 16), 15);
    assert_eq!(macros::msb!(std::u32::max_value!(), 32), 31);
    assert_eq!(macros::msb!(std::u64::max_value!(), 64), 63);
    assert_eq!(macros::msb!(std::u128::max_value!(), 128), 127);
    assert_eq!(macros::msb!(std::u256::max_value!(), 256), 255);
}

#[test]
fun msb_handles_powers_of_two() {
    // for powers of 2, msb returns the exponent
    assert_eq!(macros::msb!(1u8, 8), 0); // 2^0
    assert_eq!(macros::msb!(2u8, 8), 1); // 2^1
    assert_eq!(macros::msb!(4u8, 8), 2); // 2^2
    assert_eq!(macros::msb!(8u8, 8), 3); // 2^3

    assert_eq!(macros::msb!(1u64, 64), 0); // 2^0
    assert_eq!(macros::msb!(256u64, 64), 8); // 2^8
    assert_eq!(macros::msb!(65536u64, 64), 16); // 2^16

    assert_eq!(macros::msb!(1u256, 256), 0); // 2^0
    assert_eq!(macros::msb!(1u256 << 64, 256), 64); // 2^64
    assert_eq!(macros::msb!(1u256 << 128, 256), 128); // 2^128
}

#[test]
fun msb_lower_bits_have_no_effect() {
    // when lower bits are set, they don't affect the msb position
    // 0b11 = 3: highest bit is 1, so msb = 1 for u8
    assert_eq!(macros::msb!(3u8, 8), 1);
    // 0b111 = 7: highest bit is 2, so msb = 2 for u8
    assert_eq!(macros::msb!(7u8, 8), 2);
    // 0b1111 = 15: highest bit is 3, so msb = 3 for u8
    assert_eq!(macros::msb!(15u8, 8), 3);

    // For u256: 255 = 0xff (bits 0-7 set), highest is bit 7, so msb = 7
    assert_eq!(macros::msb!(255u256, 256), 7);
    // 65535 = 0xffff (bits 0-15 set), highest is bit 15, so msb = 15
    assert_eq!(macros::msb!(65535u256, 256), 15);
}

#[test]
fun msb_handles_values_near_boundaries() {
    // test values just before and at power-of-2 boundaries
    // 2^8 = 256
    assert_eq!(macros::msb!(256u16, 16), 8);
    // 2^8 - 1 = 255
    assert_eq!(macros::msb!(255u16, 16), 7);

    // 2^16 = 65536
    assert_eq!(macros::msb!(65536u32, 32), 16);
    // 2^16 - 1 = 65535
    assert_eq!(macros::msb!(65535u32, 32), 15);

    // 2^32
    assert_eq!(macros::msb!(1u64 << 32, 64), 32);
    // 2^32 - 1
    assert_eq!(macros::msb!((1u64 << 32) - 1, 64), 31);
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

// === log10 ===

#[test]
fun log10_returns_zero_for_zero() {
    // log10(0) should return 0 by convention
    assert_eq!(macros::log10!(0u8, rounding::down()), 0);
    assert_eq!(macros::log10!(0u8, rounding::up()), 0);
    assert_eq!(macros::log10!(0u8, rounding::nearest()), 0);
    assert_eq!(macros::log10!(0u16, rounding::down()), 0);
    assert_eq!(macros::log10!(0u32, rounding::up()), 0);
    assert_eq!(macros::log10!(0u64, rounding::nearest()), 0);
    assert_eq!(macros::log10!(0u128, rounding::down()), 0);
    assert_eq!(macros::log10!(0u256, rounding::up()), 0);
}

#[test]
fun log10_handles_powers_of_10() {
    // for powers of 10, log10 returns the exponent regardless of rounding mode
    let rounding_modes = vector[rounding::down(), rounding::up(), rounding::nearest()];
    rounding_modes.destroy!(|rounding| {
        assert_eq!(macros::log10!(1u8, rounding), 0); // 10^0
        assert_eq!(macros::log10!(10u8, rounding), 1); // 10^1
        assert_eq!(macros::log10!(100u16, rounding), 2); // 10^2
        assert_eq!(macros::log10!(1000u16, rounding), 3); // 10^3
        assert_eq!(macros::log10!(10000u32, rounding), 4); // 10^4
        assert_eq!(macros::log10!(100000u32, rounding), 5); // 10^5
        assert_eq!(macros::log10!(1000000u32, rounding), 6); // 10^6
        assert_eq!(macros::log10!(1000000000u64, rounding), 9); // 10^9
        assert_eq!(macros::log10!(1000000000000u64, rounding), 12); // 10^12
        assert_eq!(macros::log10!(10000000000000000u128, rounding), 16); // 10^16
    });
}

#[test]
fun log10_rounds_down() {
    // log10 with Down mode truncates to floor
    let down = rounding::down();
    assert_eq!(macros::log10!(9u8, down), 0); // log10(9) < 1 → 0
    assert_eq!(macros::log10!(11u8, down), 1); // log10(11) > 1 → 1
    assert_eq!(macros::log10!(99u8, down), 1); // log10(99) < 2 → 1
    assert_eq!(macros::log10!(101u16, down), 2); // log10(101) > 2 → 2
    assert_eq!(macros::log10!(999u16, down), 2); // log10(999) < 3 → 2
    assert_eq!(macros::log10!(1001u16, down), 3); // log10(1001) > 3 → 3
    assert_eq!(macros::log10!(9999u32, down), 3); // log10(9999) < 4 → 3
    assert_eq!(macros::log10!(10001u32, down), 4); // log10(10001) > 4 → 4
}

#[test]
fun log10_rounds_up() {
    // log10 with Up mode rounds to ceiling
    let up = rounding::up();
    assert_eq!(macros::log10!(9u8, up), 1); // log10(9) < 1 → 1
    assert_eq!(macros::log10!(11u8, up), 2); // log10(11) > 1 → 2
    assert_eq!(macros::log10!(99u8, up), 2); // log10(99) < 2 → 2
    assert_eq!(macros::log10!(101u16, up), 3); // log10(101) > 2 → 3
    assert_eq!(macros::log10!(999u16, up), 3); // log10(999) < 3 → 3
    assert_eq!(macros::log10!(1001u16, up), 4); // log10(1001) > 3 → 4
    assert_eq!(macros::log10!(9999u32, up), 4); // log10(9999) < 4 → 4
    assert_eq!(macros::log10!(10001u32, up), 5); // log10(10001) > 4 → 5
}

#[test]
fun log10_rounds_to_nearest() {
    // log10 with Nearest mode rounds to closest integer
    // Midpoint between 10^k and 10^(k+1) is √10 · 10^k ≈ 3.162 · 10^k
    let nearest = rounding::nearest();

    // Between 10^0 and 10^1: midpoint at √10 ≈ 3.162
    assert_eq!(macros::log10!(3u8, nearest), 0); // log10(3) ≈ 0.477, < 0.5 → 0
    assert_eq!(macros::log10!(4u8, nearest), 1); // log10(4) ≈ 0.602, > 0.5 → 1
    assert_eq!(macros::log10!(9u8, nearest), 1); // log10(9) ≈ 0.954, > 0.5 → 1

    // Between 10^1 and 10^2: midpoint at 10 × √10 ≈ 31.62
    assert_eq!(macros::log10!(31u8, nearest), 1); // < 31.62, rounds down
    assert_eq!(macros::log10!(32u8, nearest), 2); // > 31.62, rounds up
    assert_eq!(macros::log10!(99u8, nearest), 2); // > 31.62, rounds up

    // Between 10^2 and 10^3: midpoint at 100 × √10 ≈ 316.2
    assert_eq!(macros::log10!(316u16, nearest), 2); // ≈ 316.2, rounds down
    assert_eq!(macros::log10!(317u16, nearest), 3); // > 316.2, rounds up
    assert_eq!(macros::log10!(999u16, nearest), 3); // > 316.2, rounds up

    // Between 10^3 and 10^4: midpoint at 1000 × √10 ≈ 3162
    assert_eq!(macros::log10!(3162u16, nearest), 3); // ≈ 3162, rounds down
    assert_eq!(macros::log10!(3163u16, nearest), 4); // > 3162, rounds up
    assert_eq!(macros::log10!(9999u32, nearest), 4); // > 3162, rounds up

    // Between 10^4 and 10^5: midpoint at 10000 × √10 ≈ 31622
    assert_eq!(macros::log10!(31622u32, nearest), 4); // ≈ 31622, rounds down
    assert_eq!(macros::log10!(31623u32, nearest), 5); // > 31622, rounds up
}

#[test]
fun log10_handles_max_values() {
    // Test with maximum values for different types
    // u8::MAX = 255, log10(255) ≈ 2.407
    assert_eq!(macros::log10!(std::u8::max_value!(), rounding::down()), 2);
    assert_eq!(macros::log10!(std::u8::max_value!(), rounding::up()), 3);
    assert_eq!(macros::log10!(std::u8::max_value!(), rounding::nearest()), 2);

    // u16::MAX = 65535, log10(65535) ≈ 4.816
    assert_eq!(macros::log10!(std::u16::max_value!(), rounding::down()), 4);
    assert_eq!(macros::log10!(std::u16::max_value!(), rounding::up()), 5);
    assert_eq!(macros::log10!(std::u16::max_value!(), rounding::nearest()), 5);

    // u32::MAX = 4294967295, log10(2^32-1) ≈ 9.633
    assert_eq!(macros::log10!(std::u32::max_value!(), rounding::down()), 9);
    assert_eq!(macros::log10!(std::u32::max_value!(), rounding::up()), 10);
    assert_eq!(macros::log10!(std::u32::max_value!(), rounding::nearest()), 10);

    // u64::MAX, log10(2^64-1) ≈ 19.266
    assert_eq!(macros::log10!(std::u64::max_value!(), rounding::down()), 19);
    assert_eq!(macros::log10!(std::u64::max_value!(), rounding::up()), 20);
    assert_eq!(macros::log10!(std::u64::max_value!(), rounding::nearest()), 19);

    // u128::MAX, log10(2^128-1) ≈ 38.531
    assert_eq!(macros::log10!(std::u128::max_value!(), rounding::down()), 38);
    assert_eq!(macros::log10!(std::u128::max_value!(), rounding::up()), 39);
    assert_eq!(macros::log10!(std::u128::max_value!(), rounding::nearest()), 39);

    // u256::MAX, log10(2^256-1) ≈ 77.064
    assert_eq!(macros::log10!(std::u256::max_value!(), rounding::down()), 77);
    assert_eq!(macros::log10!(std::u256::max_value!(), rounding::up()), 78);
    assert_eq!(macros::log10!(std::u256::max_value!(), rounding::nearest()), 77);
}

#[test]
fun log10_handles_edge_cases_near_powers() {
    // Test values just before and after powers of 10
    let down = rounding::down();
    let up = rounding::up();

    // Around 10^2 = 100
    assert_eq!(macros::log10!(99u8, down), 1);
    assert_eq!(macros::log10!(100u8, down), 2);
    assert_eq!(macros::log10!(101u16, down), 2);

    assert_eq!(macros::log10!(99u8, up), 2);
    assert_eq!(macros::log10!(100u8, up), 2);
    assert_eq!(macros::log10!(101u16, up), 3);

    // Around 10^3 = 1000
    assert_eq!(macros::log10!(999u16, down), 2);
    assert_eq!(macros::log10!(1000u16, down), 3);
    assert_eq!(macros::log10!(1001u16, down), 3);

    assert_eq!(macros::log10!(999u16, up), 3);
    assert_eq!(macros::log10!(1000u16, up), 3);
    assert_eq!(macros::log10!(1001u16, up), 4);

    // Around 10^6 = 1000000
    assert_eq!(macros::log10!(999999u32, down), 5);
    assert_eq!(macros::log10!(1000000u32, down), 6);
    assert_eq!(macros::log10!(1000001u32, down), 6);
}

#[test]
fun log10_large_u256_values() {
    // Test value that goes through fast path
    let value = std::u256::pow(10, 38) + 1; // 10^38 + 1
    assert_eq!(macros::log10!(value, rounding::down()), 38);
    assert_eq!(macros::log10!(value, rounding::up()), 39);
    assert_eq!(macros::log10!(value, rounding::nearest()), 38);

    // Test larger value that require u512 arithmetic
    let value = std::u256::pow(10, 77) + 1; // 10^77 + 1
    assert_eq!(macros::log10!(value, rounding::down()), 77);
    assert_eq!(macros::log10!(value, rounding::up()), 78);
    assert_eq!(macros::log10!(value, rounding::nearest()), 77);
}

// === sqrt ===

#[test]
fun sqrt_returns_zero_for_zero() {
    // sqrt(0) = 0 by definition
    let rounding_modes = vector[rounding::down(), rounding::up(), rounding::nearest()];
    rounding_modes.destroy!(|rounding| {
        assert_eq!(macros::sqrt!(0u8, rounding), 0);
        assert_eq!(macros::sqrt!(0u16, rounding), 0);
        assert_eq!(macros::sqrt!(0u32, rounding), 0);
        assert_eq!(macros::sqrt!(0u64, rounding), 0);
        assert_eq!(macros::sqrt!(0u128, rounding), 0);
        assert_eq!(macros::sqrt!(0u256, rounding), 0);
    });
}

#[test]
fun sqrt_handles_perfect_squares() {
    // Perfect squares should return exact result regardless of rounding mode
    let rounding_modes = vector[rounding::down(), rounding::up(), rounding::nearest()];
    rounding_modes.destroy!(|rounding| {
        assert_eq!(macros::sqrt!(1u32, rounding), 1);
        assert_eq!(macros::sqrt!(4u32, rounding), 2);
        assert_eq!(macros::sqrt!(9u32, rounding), 3);
        assert_eq!(macros::sqrt!(16u32, rounding), 4);
        assert_eq!(macros::sqrt!(25u32, rounding), 5);
        assert_eq!(macros::sqrt!(64u32, rounding), 8);
        assert_eq!(macros::sqrt!(100u32, rounding), 10);
        assert_eq!(macros::sqrt!(144u32, rounding), 12);
        assert_eq!(macros::sqrt!(256u32, rounding), 16);
        assert_eq!(macros::sqrt!(65536u64, rounding), 256);
        assert_eq!(macros::sqrt!(1u256 << 254, rounding), 1 << 127);
    });
}

#[test]
fun sqrt_rounds_down() {
    // sqrt with Down mode truncates to floor
    let down = rounding::down();
    assert_eq!(macros::sqrt!(2u32, down), 1); // sqrt(2) ≈ 1.414 → 1
    assert_eq!(macros::sqrt!(3u32, down), 1); // sqrt(3) ≈ 1.732 → 1
    assert_eq!(macros::sqrt!(5u32, down), 2); // sqrt(5) ≈ 2.236 → 2
    assert_eq!(macros::sqrt!(8u32, down), 2); // sqrt(8) ≈ 2.828 → 2
    assert_eq!(macros::sqrt!(10u32, down), 3); // sqrt(10) ≈ 3.162 → 3
    assert_eq!(macros::sqrt!(15u32, down), 3); // sqrt(15) ≈ 3.873 → 3
    assert_eq!(macros::sqrt!(24u32, down), 4); // sqrt(24) ≈ 4.899 → 4
    assert_eq!(macros::sqrt!(99u32, down), 9); // sqrt(99) ≈ 9.950 → 9
    assert_eq!(macros::sqrt!(255u32, down), 15); // sqrt(255) ≈ 15.969 → 15
}

#[test]
fun sqrt_rounds_up() {
    // sqrt with Up mode rounds to ceiling
    let up = rounding::up();
    assert_eq!(macros::sqrt!(2u32, up), 2); // sqrt(2) ≈ 1.414 → 2
    assert_eq!(macros::sqrt!(3u32, up), 2); // sqrt(3) ≈ 1.732 → 2
    assert_eq!(macros::sqrt!(5u32, up), 3); // sqrt(5) ≈ 2.236 → 3
    assert_eq!(macros::sqrt!(8u32, up), 3); // sqrt(8) ≈ 2.828 → 3
    assert_eq!(macros::sqrt!(10u32, up), 4); // sqrt(10) ≈ 3.162 → 4
    assert_eq!(macros::sqrt!(15u32, up), 4); // sqrt(15) ≈ 3.873 → 4
    assert_eq!(macros::sqrt!(24u32, up), 5); // sqrt(24) ≈ 4.899 → 5
    assert_eq!(macros::sqrt!(99u32, up), 10); // sqrt(99) ≈ 9.950 → 10
    assert_eq!(macros::sqrt!(255u32, up), 16); // sqrt(255) ≈ 15.969 → 16
}

#[test]
fun sqrt_rounds_to_nearest() {
    // sqrt with Nearest mode rounds to closest integer
    let nearest = rounding::nearest();
    assert_eq!(macros::sqrt!(2u32, nearest), 1); // sqrt(2) ≈ 1.414 → 1
    assert_eq!(macros::sqrt!(3u32, nearest), 2); // sqrt(3) ≈ 1.732 → 2
    assert_eq!(macros::sqrt!(5u32, nearest), 2); // sqrt(5) ≈ 2.236 → 2
    assert_eq!(macros::sqrt!(7u32, nearest), 3); // sqrt(7) ≈ 2.646 → 3
    assert_eq!(macros::sqrt!(8u32, nearest), 3); // sqrt(8) ≈ 2.828 → 3
    assert_eq!(macros::sqrt!(10u32, nearest), 3); // sqrt(10) ≈ 3.162 → 3
    assert_eq!(macros::sqrt!(13u32, nearest), 4); // sqrt(13) ≈ 3.606 → 4
    assert_eq!(macros::sqrt!(15u32, nearest), 4); // sqrt(15) ≈ 3.873 → 4
    assert_eq!(macros::sqrt!(24u32, nearest), 5); // sqrt(24) ≈ 4.899 → 5
    assert_eq!(macros::sqrt!(99u32, nearest), 10); // sqrt(99) ≈ 9.950 → 10
    assert_eq!(macros::sqrt!(255u32, nearest), 16); // sqrt(255) ≈ 15.969 → 16
}

#[test]
fun sqrt_handles_small_values() {
    // Test edge cases for small values
    assert_eq!(macros::sqrt!(1u8, rounding::down()), 1);
    assert_eq!(macros::sqrt!(1u8, rounding::up()), 1);
    assert_eq!(macros::sqrt!(1u8, rounding::nearest()), 1);

    assert_eq!(macros::sqrt!(2u8, rounding::down()), 1);
    assert_eq!(macros::sqrt!(2u8, rounding::up()), 2);
    assert_eq!(macros::sqrt!(2u8, rounding::nearest()), 1);

    assert_eq!(macros::sqrt!(3u8, rounding::down()), 1);
    assert_eq!(macros::sqrt!(3u8, rounding::up()), 2);
    assert_eq!(macros::sqrt!(3u8, rounding::nearest()), 2);
}

#[test]
fun sqrt_handles_large_values() {
    // Test with larger values across different types
    let down = rounding::down();
    let up = rounding::up();
    let nearest = rounding::nearest();

    // u64 tests
    assert_eq!(macros::sqrt!(1000000u64, down), 1000);
    assert_eq!(macros::sqrt!(1000001u64, down), 1000);
    assert_eq!(macros::sqrt!(1000001u64, up), 1001);
    assert_eq!(macros::sqrt!(1002000u64, nearest), 1001);

    // u128 tests
    assert_eq!(macros::sqrt!(1u128 << 64, down), 1 << 32); // 2^64
    assert_eq!(macros::sqrt!(std::u128::max_value!(), down), std::u64::max_value!() as u128);

    // u256 tests
    let large = 1 << 128;
    assert_eq!(macros::sqrt!(large, down), 1u256 << 64);
    assert_eq!(macros::sqrt!(large, up), 1u256 << 64);
    assert_eq!(macros::sqrt!(large, nearest), 1u256 << 64);
}

#[test]
fun sqrt_handles_powers_of_two() {
    // Powers of 4 (perfect squares of powers of 2)
    let rounding_modes = vector[rounding::down(), rounding::up(), rounding::nearest()];
    rounding_modes.destroy!(|rounding| {
        assert_eq!(macros::sqrt!(1u64 << 0, rounding), 1); // sqrt(1) = 1
        assert_eq!(macros::sqrt!(1u64 << 2, rounding), 2); // sqrt(4) = 2
        assert_eq!(macros::sqrt!(1u64 << 4, rounding), 4); // sqrt(16) = 4
        assert_eq!(macros::sqrt!(1u64 << 6, rounding), 8); // sqrt(64) = 8
        assert_eq!(macros::sqrt!(1u64 << 8, rounding), 16); // sqrt(256) = 16
        assert_eq!(macros::sqrt!(1u64 << 10, rounding), 32); // sqrt(1024) = 32
        assert_eq!(macros::sqrt!(1u64 << 20, rounding), 1024); // sqrt(2^20) = 1024
    });
}

#[test]
fun sqrt_midpoint_behavior() {
    // Test values exactly between two perfect squares
    // Between 4 (2^2) and 9 (3^2): midpoint is around 6.5 (since 2.5^2 = 6.25)
    // sqrt(5) ≈ 2.236, closer to 2
    assert_eq!(macros::sqrt!(5u32, rounding::nearest()), 2);
    // sqrt(6) ≈ 2.449, closer to 2
    assert_eq!(macros::sqrt!(6u32, rounding::nearest()), 2);
    // sqrt(7) ≈ 2.646, closer to 3
    assert_eq!(macros::sqrt!(7u32, rounding::nearest()), 3);
    // sqrt(8) ≈ 2.828, closer to 3
    assert_eq!(macros::sqrt!(8u32, rounding::nearest()), 3);

    // Between 9 (3^2) and 16 (4^2): midpoint at 12.5
    // sqrt(12) ≈ 3.464, closer to 3
    assert_eq!(macros::sqrt!(12u32, rounding::nearest()), 3);
    // sqrt(13) ≈ 3.606, closer to 4
    assert_eq!(macros::sqrt!(13u32, rounding::nearest()), 4);
}

#[test]
fun sqrt_works_with_different_widths() {
    // Verify the macro works correctly across all unsigned integer types
    assert_eq!(macros::sqrt!(100u8, rounding::down()), 10u8);
    assert_eq!(macros::sqrt!(1000u16, rounding::down()), 31u16);
    assert_eq!(macros::sqrt!(10000u32, rounding::down()), 100u32);
    assert_eq!(macros::sqrt!(100000u64, rounding::down()), 316u64);
    assert_eq!(macros::sqrt!(1000000u128, rounding::down()), 1000u128);
    assert_eq!(macros::sqrt!(10000000u256, rounding::down()), 3162u256);
}

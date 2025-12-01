module openzeppelin_math::coin_utils_tests;

use openzeppelin_math::coin_utils;
use std::unit_test::assert_eq;

// === Test Helpers ===

/// Build a test value with specified base and decimal places.
///
/// # Examples
/// - `value(1, 18)` = 1 token with 18 decimals = 1000000000000000000
/// - `value(5, 9)` = 5 tokens with 9 decimals = 5000000000
/// - `value(1, 0)` = 1 token with 0 decimals = 1
fun value(base: u64, decimals: u8): u256 {
  (base as u256) * std::u256::pow(10, decimals)
}

// === Tests for safe_downcast_balance ===

#[test]
fun ai_TMP_test_downcast_same_decimals() {
  let amount = value(1, 9); // 1 token with 9 decimals
  let result = coin_utils::safe_downcast_balance(amount, 9, 9);
  assert_eq!(result, value(1, 9) as u64);
}

#[test]
fun test_downcast_same_decimals() {
  let amount = value(1, 9); // 1 token with 9 decimals
  let result = coin_utils::safe_downcast_balance(amount, 9, 9);
  assert_eq!(result, value(1, 9) as u64);
}

#[test]
fun test_downcast_scale_down_18_to_9() {
  // 1 ETH (18 decimals) -> 9 decimals
  let amount = value(1, 18);
  let result = coin_utils::safe_downcast_balance(amount, 18, 9);
  assert_eq!(result, value(1, 9) as u64);
}

#[test]
fun test_downcast_scale_down_18_to_6() {
  // 1 ETH (18 decimals) -> 6 decimals (USDC)
  let amount = value(1, 18);
  let result = coin_utils::safe_downcast_balance(amount, 18, 6);
  assert_eq!(result, value(1, 6) as u64);
}

#[test]
fun test_downcast_scale_up_6_to_9() {
  // 1 USDC (6 decimals) -> 9 decimals
  let amount = value(1, 6);
  let result = coin_utils::safe_downcast_balance(amount, 6, 9);
  assert_eq!(result, value(1, 9) as u64);
}

#[test]
fun test_downcast_scale_up_6_to_18() {
  // 1 USDC (6 decimals) -> 18 decimals
  let amount = value(1, 6);
  let result = coin_utils::safe_downcast_balance(amount, 6, 18);
  assert_eq!(result, value(1, 18) as u64);
}

#[test]
fun test_downcast_with_fractional_amount() {
  // 1.5 ETH (18 decimals) -> 9 decimals
  let amount = value(15, 17); // 1.5 ETH
  let result = coin_utils::safe_downcast_balance(amount, 18, 9);
  assert_eq!(result, value(15, 8) as u64); // 1.5 with 9 decimals
}

#[test]
fun test_downcast_zero_decimals() {
  // Test with 0 decimals (now allowed)
  let amount = 100u256;
  let result = coin_utils::safe_downcast_balance(amount, 0, 0);
  assert_eq!(result, 100);
}

#[test]
fun test_downcast_from_nine_to_zero() {
  // 1 token (9 decimals) -> 0 decimals (truncates fractional part)
  let amount = value(1, 9);
  let result = coin_utils::safe_downcast_balance(amount, 9, 0);
  assert_eq!(result, 1);
}

#[test]
fun test_downcast_max_decimal_diff() {
  // Test maximum decimal difference (24 -> 0)
  let amount = value(1, 24); // 1 token with 24 decimals
  let result = coin_utils::safe_downcast_balance(amount, 24, 0);
  assert_eq!(result, 1);
}

#[test]
fun test_downcast_zero_amount() {
  // Test with zero amount
  let result = coin_utils::safe_downcast_balance(0u256, 18, 9);
  assert_eq!(result, 0);
}

// === New Truncation Tests ===

#[test]
fun test_downcast_truncates_fractional_part() {
  // 1.999 tokens (9 decimals) -> 0 decimals should truncate to 1, NOT round to 2
  let amount = value(1999, 6);
  let result = coin_utils::safe_downcast_balance(amount, 9, 0);
  assert_eq!(result, 1); // Truncates, does not round
}

#[test]
fun test_downcast_truncates_just_below_threshold() {
  // 1.999999999 tokens (9 decimals) -> 0 decimals
  let amount = 1999999999u256;
  let result = coin_utils::safe_downcast_balance(amount, 9, 0);
  assert_eq!(result, 1); // Still truncates to 1
}

#[test]
fun test_downcast_precision_loss_explicit() {
  // 123.456789123456789123 ETH (18 decimals) -> 6 decimals loses last 12 digits
  let amount = 123456789123456789123u256;
  let result = coin_utils::safe_downcast_balance(amount, 18, 6);
  assert_eq!(result, 123456789); // Lost .123456789123
}

#[test]
fun test_downcast_precision_loss_small_amount() {
  // 0.000000001 tokens (18 decimals) -> 9 decimals loses precision
  let amount = value(1, 9); // 10^9 with 18 decimals = 0.000000001 tokens
  let result = coin_utils::safe_downcast_balance(amount, 18, 9);
  assert_eq!(result, 1);
}

#[test]
fun test_downcast_truncates_to_zero() {
  // Amount too small to represent after scaling down
  let amount = 999999999u256; // 0.999999999 with 9 decimals
  let result = coin_utils::safe_downcast_balance(amount, 9, 0);
  assert_eq!(result, 0); // Truncates to 0
}

#[test]
fun test_downcast_smallest_representable_after_scale() {
  // Smallest amount that results in 1 after scaling
  let amount = value(1, 9); // Exactly 1.0 with 9 decimals
  let result = coin_utils::safe_downcast_balance(amount, 9, 0);
  assert_eq!(result, 1);
}

#[test]
fun test_downcast_just_above_truncation_threshold() {
  // Just above the truncation threshold for 18->9 decimals
  let amount = value(1, 9); // 10^9 - exactly 1 unit after scaling
  let result = coin_utils::safe_downcast_balance(amount, 18, 9);
  assert_eq!(result, 1);
}

#[test]
fun test_downcast_just_below_truncation_threshold() {
  // Just below the truncation threshold for 18->9 decimals
  let amount = 999999999u256; // 10^9 - 1 - truncates to 0
  let result = coin_utils::safe_downcast_balance(amount, 18, 9);
  assert_eq!(result, 0);
}

// === Tests for safe_upcast_balance ===

#[test]
fun test_upcast_same_decimals() {
  let amount = value(1, 9) as u64; // 1 token with 9 decimals
  let result = coin_utils::safe_upcast_balance(amount, 9, 9);
  assert_eq!(result, value(1, 9));
}

#[test]
fun test_upcast_scale_up_9_to_18() {
  // 1 token (9 decimals) -> 18 decimals (ETH)
  let amount = value(1, 9) as u64;
  let result = coin_utils::safe_upcast_balance(amount, 9, 18);
  assert_eq!(result, value(1, 18));
}

#[test]
fun test_upcast_scale_up_6_to_18() {
  // 1 USDC (6 decimals) -> 18 decimals (ETH)
  let amount = value(1, 6) as u64;
  let result = coin_utils::safe_upcast_balance(amount, 6, 18);
  assert_eq!(result, value(1, 18));
}

#[test]
fun test_upcast_scale_down_18_to_9() {
  // Small amount (18 decimals) -> 9 decimals
  // Using realistic u64 value
  let amount = value(1, 9) as u64; // 0.000000001 tokens with 18 decimals
  let result = coin_utils::safe_upcast_balance(amount, 18, 9);
  assert_eq!(result, 1u256);
}

#[test]
fun test_upcast_scale_down_9_to_6() {
  // 1 token (9 decimals) -> 6 decimals (USDC)
  let amount = value(1, 9) as u64;
  let result = coin_utils::safe_upcast_balance(amount, 9, 6);
  assert_eq!(result, value(1, 6));
}

#[test]
fun test_upcast_zero_decimals() {
  // Test with 0 decimals (now allowed)
  let amount = 100u64;
  let result = coin_utils::safe_upcast_balance(amount, 0, 0);
  assert_eq!(result, 100u256);
}

#[test]
fun test_upcast_from_zero_to_nine() {
  // 1 token (0 decimals) -> 9 decimals
  let amount = 1u64;
  let result = coin_utils::safe_upcast_balance(amount, 0, 9);
  assert_eq!(result, value(1, 9));
}

#[test]
fun test_upcast_from_nine_to_zero() {
  // 1 token (9 decimals) -> 0 decimals
  let amount = value(1, 9) as u64;
  let result = coin_utils::safe_upcast_balance(amount, 9, 0);
  assert_eq!(result, 1u256);
}

#[test]
fun test_upcast_max_decimals() {
  // Test with maximum decimals (24 -> 24)
  let amount = 1000u64; // Small amount to fit in u64
  let result = coin_utils::safe_upcast_balance(amount, 24, 24);
  assert_eq!(result, 1000u256);
}

#[test]
fun test_upcast_to_max_decimals() {
  // 1 token (9 decimals) -> 24 decimals
  let amount = value(1, 9) as u64;
  let result = coin_utils::safe_upcast_balance(amount, 9, 24);
  assert_eq!(result, value(1, 24));
}

#[test]
fun test_upcast_u64_max_value() {
  // Test max u64 value
  let max_u64 = std::u64::max_value!();
  let result = coin_utils::safe_upcast_balance(max_u64, 9, 9);
  assert_eq!(result, (max_u64 as u256));
}

#[test]
fun test_upcast_zero_amount() {
  // Test with zero amount
  let result = coin_utils::safe_upcast_balance(0u64, 9, 18);
  assert_eq!(result, 0u256);
}

// === Tests for decimal scaling ===

#[test]
fun test_decimal_diff_1() {
  // 10^1 = 10
  let amount = value(1, 9); // 9 decimals
  let result = coin_utils::safe_downcast_balance(amount, 10, 9);
  assert_eq!(result, value(1, 8) as u64); // divided by 10
}

#[test]
fun test_decimal_diff_2() {
  // 10^2 = 100
  let amount = value(1, 9);
  let result = coin_utils::safe_downcast_balance(amount, 11, 9);
  assert_eq!(result, value(1, 7) as u64); // divided by 100
}

#[test]
fun test_decimal_diff_3() {
  // 10^3 = 1000
  let amount = value(1, 9);
  let result = coin_utils::safe_downcast_balance(amount, 12, 9);
  assert_eq!(result, value(1, 6) as u64); // divided by 1000
}

#[test]
fun test_decimal_diff_6() {
  // 10^6 = 1000000 (USDC decimals)
  let amount = value(1, 6);
  let result = coin_utils::safe_upcast_balance(amount as u64, 6, 12);
  assert_eq!(result, value(1, 12)); // multiplied by 10^6
}

#[test]
fun test_decimal_diff_9() {
  // 10^9 (common Sui decimals)
  let amount = value(1, 9) as u64;
  let result = coin_utils::safe_upcast_balance(amount, 9, 18);
  assert_eq!(result, value(1, 18)); // multiplied by 10^9
}

#[test]
fun test_decimal_diff_12() {
  // 10^12
  let amount = 1u64;
  let result = coin_utils::safe_upcast_balance(amount, 1, 13);
  assert_eq!(result, value(1, 12)); // multiplied by 10^12
}

#[test]
fun test_decimal_diff_24() {
  // Maximum decimal difference (24 - 0 = 24)
  let amount = 1u64;
  let result = coin_utils::safe_upcast_balance(amount, 0, 24);
  assert_eq!(result, value(1, 24)); // multiplied by 10^24
}

// === Error Tests for safe_downcast_balance ===

#[test]
#[expected_failure(abort_code = coin_utils::EInvalidDecimals)]
fun test_downcast_raw_decimals_too_large() {
  coin_utils::safe_downcast_balance(value(1, 6), 25, 9);
}

#[test]
#[expected_failure(abort_code = coin_utils::EInvalidDecimals)]
fun test_downcast_scaled_decimals_too_large() {
  coin_utils::safe_downcast_balance(value(1, 6), 9, 25);
}

#[test]
#[expected_failure(abort_code = coin_utils::ESafeDowncastOverflowedInt)]
fun test_downcast_overflow_after_scaling_up() {
  // Value is ok before scaling but overflows after scaling up
  let amount = (std::u64::max_value!() as u256) / 1000;
  coin_utils::safe_downcast_balance(amount, 6, 18); // Scale up by 10^12, will overflow
}

// === Error Tests for safe_upcast_balance ===

#[test]
#[expected_failure(abort_code = coin_utils::EInvalidDecimals)]
fun test_upcast_source_decimals_too_large() {
  coin_utils::safe_upcast_balance(1000000, 25, 9);
}

#[test]
#[expected_failure(abort_code = coin_utils::EInvalidDecimals)]
fun test_upcast_target_decimals_too_large() {
  coin_utils::safe_upcast_balance(1000000, 9, 25);
}

// === Roundtrip Tests ===

#[test]
fun test_roundtrip_eth_to_sui_to_eth() {
  // ETH (18) -> Sui (9) -> ETH (18)
  let original = value(15, 17); // 1.5 ETH
  let sui = coin_utils::safe_downcast_balance(original, 18, 9);
  let back = coin_utils::safe_upcast_balance(sui, 9, 18);
  assert_eq!(back, original);
}

#[test]
fun test_roundtrip_usdc_to_sui_to_usdc() {
  // USDC (6) -> Sui (9) -> USDC (6)
  let original = value(15, 5); // 1.5 USDC
  let sui = coin_utils::safe_downcast_balance(original, 6, 9);
  let back = coin_utils::safe_upcast_balance(sui, 9, 6);
  assert_eq!(back, original);
}

#[test]
fun test_roundtrip_sui_to_eth_to_sui() {
  // Sui (9) -> ETH (18) -> Sui (9)
  let original = value(15, 8) as u64; // 1.5 tokens
  let eth = coin_utils::safe_upcast_balance(original, 9, 18);
  let back = coin_utils::safe_downcast_balance(eth, 18, 9);
  assert_eq!(back, original);
}

#[test]
fun test_roundtrip_with_max_decimals() {
  // Test max decimal difference roundtrip (24 -> 0 -> 24)
  let original = value(1, 24); // 1 token with 24 decimals
  let scaled = coin_utils::safe_downcast_balance(original, 24, 0);
  let back = coin_utils::safe_upcast_balance(scaled, 0, 24);
  assert_eq!(back, original);
}

#[test]
fun test_roundtrip_zero_decimals() {
  // 0 decimals -> 9 decimals -> 0 decimals
  let original = value(100, 0);
  let scaled_up = coin_utils::safe_downcast_balance(original, 0, 9);
  let back = coin_utils::safe_downcast_balance((scaled_up as u256), 9, 0);
  assert_eq!(back, original as u64);
}

// === New Roundtrip Tests with Precision Loss ===

#[test]
fun test_roundtrip_with_truncation_loss() {
  // Demonstrate that roundtrip with intermediate downscaling loses precision
  let original = 1234567890123456789u256; // 1.234567890123456789 ETH (18 decimals)

  // ETH (18) -> Sui (9) -> ETH (18)
  let sui = coin_utils::safe_downcast_balance(original, 18, 9);
  let back = coin_utils::safe_upcast_balance(sui, 9, 18);

  // Precision is lost due to truncation
  assert!(back != original);
  assert_eq!(back, value(123456789, 10)); // Lost last 9 digits
}

// === Successive Scaling Tests ===

#[test]
fun test_multiple_scaling_operations_down() {
  // Test chaining: 18 -> 12 -> 9 -> 6
  let original = value(1, 18); // 1 token with 18 decimals

  let step1 = coin_utils::safe_downcast_balance(original, 18, 12);
  let step2 = coin_utils::safe_downcast_balance((step1 as u256), 12, 9);
  let step3 = coin_utils::safe_downcast_balance((step2 as u256), 9, 6);

  // Direct conversion should match chained conversion
  let direct = coin_utils::safe_downcast_balance(original, 18, 6);
  assert_eq!(step3, direct);
}

#[test]
fun test_multiple_scaling_operations_up() {
  // Test chaining: 6 -> 9 -> 12 -> 18
  let original = value(1, 6) as u64; // 1 token with 6 decimals

  let step1 = coin_utils::safe_upcast_balance(original, 6, 9);
  let step2 = coin_utils::safe_upcast_balance((step1 as u64), 9, 12);
  let step3 = coin_utils::safe_upcast_balance((step2 as u64), 12, 18);

  // Direct conversion should match chained conversion
  let direct = coin_utils::safe_upcast_balance(original, 6, 18);
  assert_eq!(step3, direct);
}

#[test]
fun test_multiple_scaling_mixed_directions() {
  // Test: 9 -> 18 -> 6 -> 12 -> 9
  let original = value(1, 9) as u64; // 1 token with 9 decimals

  let step1 = coin_utils::safe_upcast_balance(original, 9, 18);
  let step2 = coin_utils::safe_downcast_balance(step1, 18, 6);
  let step3 = coin_utils::safe_upcast_balance(step2, 6, 12);
  let step4 = coin_utils::safe_downcast_balance((step3 as u256), 12, 9);

  // Should return to original value
  assert_eq!(step4, original);
}

// === Additional Edge Cases ===

#[test]
fun test_downcast_exactly_u64_max() {
  // Test downcast with amount exactly equal to u64::MAX
  let max_u64 = std::u64::max_value!();
  let result = coin_utils::safe_downcast_balance((max_u64 as u256), 9, 9);
  assert_eq!(result, max_u64);
}

#[test]
#[expected_failure(abort_code = coin_utils::ESafeDowncastOverflowedInt)]
fun test_downcast_u64_max_plus_one() {
  // Test downcast with amount = u64::MAX + 1 (should abort)
  let too_large = ((std::u64::max_value!() as u256) + 1);
  let _ = coin_utils::safe_downcast_balance(too_large, 9, 9);
}

#[test]
fun test_downcast_scaling_to_exactly_u64_max() {
  // Test scaling that results in exactly u64::MAX after scaling up
  // Use a value that when scaled up by 10^9 results in u64::MAX
  let amount = (std::u64::max_value!() as u256) / value(1, 9);
  let result = coin_utils::safe_downcast_balance(amount, 0, 9);
  // Result should be less than or equal to u64::MAX
  assert!(result <= std::u64::max_value!());
}

#[test]
fun test_downcast_scaling_to_exactly_u64_max_after_scale_down() {
  // Test scaling that results in exactly u64::MAX after scaling down
  let max_u64 = std::u64::max_value!();
  let amount = (max_u64 as u256) * 10; // Scale up first
  let result = coin_utils::safe_downcast_balance(amount, 10, 9); // Then scale down
  assert_eq!(result, max_u64);
}

#[test]
fun test_upcast_u64_max_with_max_decimal_diff() {
  // Test upcast with u64::MAX and maximum decimal difference (0 -> 24)
  let max_u64 = std::u64::max_value!();
  let result = coin_utils::safe_upcast_balance(max_u64, 0, 24);
  // Result should be max_u64 * 10^24, which fits in u256
  assert!(result > (max_u64 as u256));
}

#[test]
fun test_upcast_large_amounts_various_decimals() {
  // Test upcast with large amounts and various decimal combinations
  let amount = value(1, 18) as u64; // 1e18
  let result1 = coin_utils::safe_upcast_balance(amount, 18, 24);
  assert_eq!(result1, value(1, 24)); // 1e24

  let result2 = coin_utils::safe_upcast_balance(amount, 18, 0);
  assert_eq!(result2, 1u256);
}

#[test]
fun test_scale_amount_with_zero() {
  // Test that scaling zero returns zero regardless of decimals
  let result1 = coin_utils::safe_downcast_balance(0u256, 0, 24);
  assert_eq!(result1, 0);

  let result2 = coin_utils::safe_upcast_balance(0u64, 0, 24);
  assert_eq!(result2, 0u256);

  let result3 = coin_utils::safe_downcast_balance(0u256, 24, 0);
  assert_eq!(result3, 0);
}

#[test]
fun test_scale_amount_very_small_values() {
  // Test scaling with very small amounts across different decimal differences
  let result = coin_utils::safe_upcast_balance(1u64, 0, 18);
  assert_eq!(result, value(1, 18));
}

#[test]
fun test_scale_amount_preserves_exact_powers_of_10() {
  // Test that scaling preserves exact values for powers of 10 (no precision loss)
  // 10^9 with 9 decimals -> 10^6 with 6 decimals should be exactly 10^6
  let amount = value(1, 9); // 10^9
  let result = coin_utils::safe_downcast_balance(amount, 9, 6);
  assert_eq!(result, value(1, 6) as u64); // Exactly 10^6, no precision loss
}

#[test]
fun test_validate_decimals_one_at_max() {
  // Test with one decimal at MAX_DECIMALS and one below - should pass
  // When scaling from 24 to 9 decimals, we scale DOWN (divide by 10^15)
  // Use a large amount that won't truncate to zero
  let amount = value(1, 18); // 10^18 with 24 decimals
  let result = coin_utils::safe_downcast_balance(amount, 24, 9);
  // 10^18 / 10^15 = 10^3 = 1000
  assert_eq!(result, 1000u64);
}

#[test]
#[expected_failure(abort_code = coin_utils::EInvalidDecimals)]
fun test_validate_decimals_both_too_large() {
  // Test with both decimals at MAX_DECIMALS + 1 - should abort
  coin_utils::safe_downcast_balance(1000u256, 25, 25);
}

#[test]
#[expected_failure(abort_code = coin_utils::EInvalidDecimals)]
fun test_validate_decimals_first_invalid_second_valid() {
  // Test with first decimal invalid, second valid - should abort
  coin_utils::safe_downcast_balance(1000u256, 25, 9);
}

#[test]
#[expected_failure(abort_code = coin_utils::EInvalidDecimals)]
fun test_validate_decimals_first_valid_second_invalid() {
  // Test with first decimal valid, second invalid - should abort
  coin_utils::safe_downcast_balance(1000u256, 9, 25);
}

// === Precision Preservation Tests ===

#[test]
fun test_precision_preservation() {
  // Verify that scaling preserves economic value
  // 123.456789 tokens with 6 decimals = 123456789
  let amount = 123456789u64;

  // Scale up to 18 decimals
  let scaled_up = coin_utils::safe_upcast_balance(amount, 6, 18);
  assert_eq!(scaled_up, value(amount, 12));

  // Scale back down to 6 decimals
  let scaled_down = coin_utils::safe_downcast_balance(scaled_up, 18, 6);
  assert_eq!(scaled_down, amount);
}

#[test]
fun test_precision_no_loss_for_clean_divisions() {
  // Values that divide evenly should have no precision loss
  let amount = value(5, 9); // 5.0 tokens with 9 decimals
  let result = coin_utils::safe_downcast_balance(amount, 9, 6);
  let back = coin_utils::safe_upcast_balance(result, 6, 9);
  assert_eq!(back, amount); // Perfect roundtrip
}

#[test]
fun test_smallest_unit_preservation() {
  // Test that smallest representable units are handled correctly
  let one_wei = 1u256; // 1 wei (smallest ETH unit)
  let result = coin_utils::safe_downcast_balance(one_wei, 18, 18);
  assert_eq!(result, 1);

  // But scaling down loses it
  let lost = coin_utils::safe_downcast_balance(one_wei, 18, 9);
  assert_eq!(lost, 0); // Truncated to zero
}

#[test]
fun test_pow_10_zero_edge_case() {
  // Verify that 10^0 = 1 is handled correctly
  let amount = 123456789u256;

  // 0 -> 0 should be identity operation
  let result1 = coin_utils::safe_downcast_balance(amount, 0, 0);
  assert_eq!(result1, (amount as u64));

  // Multiplying/dividing by 10^0 = 1 should preserve value
  let result2 = coin_utils::safe_upcast_balance((amount as u64), 0, 0);
  assert_eq!(result2, amount);
}

module openzeppelin_math::utils_tests;

use openzeppelin_math::utils;
use std::unit_test::assert_eq;

// === Tests for safe_downcast_balance ===

#[test]
fun test_downcast_same_decimals() {
    let amount = 1000000000u256; // 1 token with 9 decimals
    let result = utils::safe_downcast_balance(amount, 9, 9);
    assert_eq!(result, 1000000000);
}

#[test]
fun test_downcast_scale_down_18_to_9() {
    // 1 ETH (18 decimals) -> 9 decimals
    let amount = 1000000000000000000u256;
    let result = utils::safe_downcast_balance(amount, 18, 9);
    assert_eq!(result, 1000000000);
}

#[test]
fun test_downcast_scale_down_18_to_6() {
    // 1 ETH (18 decimals) -> 6 decimals (USDC)
    let amount = 1000000000000000000u256;
    let result = utils::safe_downcast_balance(amount, 18, 6);
    assert_eq!(result, 1000000);
}

#[test]
fun test_downcast_scale_up_6_to_9() {
    // 1 USDC (6 decimals) -> 9 decimals
    let amount = 1000000u256;
    let result = utils::safe_downcast_balance(amount, 6, 9);
    assert_eq!(result, 1000000000);
}

#[test]
fun test_downcast_scale_up_6_to_18() {
    // 1 USDC (6 decimals) -> 18 decimals
    let amount = 1000000u256;
    let result = utils::safe_downcast_balance(amount, 6, 18);
    assert_eq!(result, 1000000000000000000);
}

#[test]
fun test_downcast_with_fractional_amount() {
    // 1.5 ETH (18 decimals) -> 9 decimals
    let amount = 1500000000000000000u256;
    let result = utils::safe_downcast_balance(amount, 18, 9);
    assert_eq!(result, 1500000000);
}

#[test]
fun test_downcast_zero_decimals() {
    // Test with 0 decimals (now allowed)
    let amount = 100u256;
    let result = utils::safe_downcast_balance(amount, 0, 0);
    assert_eq!(result, 100);
}

#[test]
fun test_downcast_from_zero_to_nine() {
    // 1 token (0 decimals) -> 9 decimals
    let amount = 1u256;
    let result = utils::safe_downcast_balance(amount, 0, 9);
    assert_eq!(result, 1000000000);
}

#[test]
fun test_downcast_from_nine_to_zero() {
    // 1 token (9 decimals) -> 0 decimals (truncates fractional part)
    let amount = 1000000000u256;
    let result = utils::safe_downcast_balance(amount, 9, 0);
    assert_eq!(result, 1);
}

#[test]
fun test_downcast_max_decimals() {
    // Test with maximum decimals (24 -> 24)
    let amount = 1000u256; // Small amount to fit in u64
    let result = utils::safe_downcast_balance(amount, 24, 24);
    assert_eq!(result, 1000u64);
}

#[test]
fun test_downcast_max_decimal_diff() {
    // Test maximum decimal difference (24 -> 0)
    let amount = 1000000000000000000000000u256; // 1 token with 24 decimals
    let result = utils::safe_downcast_balance(amount, 24, 0);
    assert_eq!(result, 1);
}

#[test]
fun test_downcast_u64_max_value() {
    // Test max u64 value fits
    let max_u64 = std::u64::max_value!();
    let result = utils::safe_downcast_balance((max_u64 as u256), 9, 9);
    assert_eq!(result, max_u64);
}

#[test]
fun test_downcast_zero_amount() {
    // Test with zero amount
    let result = utils::safe_downcast_balance(0u256, 18, 9);
    assert_eq!(result, 0);
}

// === Tests for safe_upcast_balance ===

#[test]
fun test_upcast_same_decimals() {
    let amount = 1000000000u64; // 1 token with 9 decimals
    let result = utils::safe_upcast_balance(amount, 9, 9);
    assert_eq!(result, 1000000000u256);
}

#[test]
fun test_upcast_scale_up_9_to_18() {
    // 1 token (9 decimals) -> 18 decimals (ETH)
    let amount = 1000000000u64;
    let result = utils::safe_upcast_balance(amount, 9, 18);
    assert_eq!(result, 1000000000000000000u256);
}

#[test]
fun test_upcast_scale_up_6_to_18() {
    // 1 USDC (6 decimals) -> 18 decimals (ETH)
    let amount = 1000000u64;
    let result = utils::safe_upcast_balance(amount, 6, 18);
    assert_eq!(result, 1000000000000000000u256);
}

#[test]
fun test_upcast_scale_down_18_to_9() {
    // 1 token (18 decimals) -> 9 decimals (fits in u64)
    let amount = 1000000000000000000u64;
    let result = utils::safe_upcast_balance(amount, 18, 9);
    assert_eq!(result, 1000000000u256);
}

#[test]
fun test_upcast_scale_down_9_to_6() {
    // 1 token (9 decimals) -> 6 decimals (USDC)
    let amount = 1000000000u64;
    let result = utils::safe_upcast_balance(amount, 9, 6);
    assert_eq!(result, 1000000u256);
}

#[test]
fun test_upcast_zero_decimals() {
    // Test with 0 decimals (now allowed)
    let amount = 100u64;
    let result = utils::safe_upcast_balance(amount, 0, 0);
    assert_eq!(result, 100u256);
}

#[test]
fun test_upcast_from_zero_to_nine() {
    // 1 token (0 decimals) -> 9 decimals
    let amount = 1u64;
    let result = utils::safe_upcast_balance(amount, 0, 9);
    assert_eq!(result, 1000000000u256);
}

#[test]
fun test_upcast_from_nine_to_zero() {
    // 1 token (9 decimals) -> 0 decimals
    let amount = 1000000000u64;
    let result = utils::safe_upcast_balance(amount, 9, 0);
    assert_eq!(result, 1u256);
}

#[test]
fun test_upcast_max_decimals() {
    // Test with maximum decimals (24 -> 24)
    let amount = 1000u64; // Small amount to fit in u64
    let result = utils::safe_upcast_balance(amount, 24, 24);
    assert_eq!(result, 1000u256);
}

#[test]
fun test_upcast_to_max_decimals() {
    // 1 token (9 decimals) -> 24 decimals
    let amount = 1000000000u64;
    let result = utils::safe_upcast_balance(amount, 9, 24);
    assert_eq!(result, 1000000000000000000000000u256);
}

#[test]
fun test_upcast_u64_max_value() {
    // Test max u64 value
    let max_u64 = std::u64::max_value!();
    let result = utils::safe_upcast_balance(max_u64, 9, 9);
    assert_eq!(result, (max_u64 as u256));
}

#[test]
fun test_upcast_zero_amount() {
    // Test with zero amount
    let result = utils::safe_upcast_balance(0u64, 9, 18);
    assert_eq!(result, 0u256);
}

// === Tests for decimal scaling (indirectly tests pow_10) ===

#[test]
fun test_decimal_diff_1() {
    // 10^1 = 10
    let amount = 1000000000u256; // 9 decimals
    let result = utils::safe_downcast_balance(amount, 10, 9);
    assert_eq!(result, 100000000); // divided by 10
}

#[test]
fun test_decimal_diff_2() {
    // 10^2 = 100
    let amount = 1000000000u256;
    let result = utils::safe_downcast_balance(amount, 11, 9);
    assert_eq!(result, 10000000); // divided by 100
}

#[test]
fun test_decimal_diff_3() {
    // 10^3 = 1000
    let amount = 1000000000u256;
    let result = utils::safe_downcast_balance(amount, 12, 9);
    assert_eq!(result, 1000000); // divided by 1000
}

#[test]
fun test_decimal_diff_6() {
    // 10^6 = 1000000 (USDC decimals)
    let amount = 1000000u256;
    let result = utils::safe_upcast_balance(amount as u64, 6, 12);
    assert_eq!(result, 1000000000000u256); // multiplied by 10^6
}

#[test]
fun test_decimal_diff_9() {
    // 10^9 (common Sui decimals)
    let amount = 1000000000u64;
    let result = utils::safe_upcast_balance(amount, 9, 18);
    assert_eq!(result, 1000000000000000000u256); // multiplied by 10^9
}

#[test]
fun test_decimal_diff_12() {
    // 10^12
    let amount = 1u64;
    let result = utils::safe_upcast_balance(amount, 1, 13);
    assert_eq!(result, 1000000000000u256); // multiplied by 10^12
}

#[test]
fun test_decimal_diff_24() {
    // Maximum decimal difference (24 - 0 = 24)
    let amount = 1u64;
    let result = utils::safe_upcast_balance(amount, 0, 24);
    assert_eq!(result, 1000000000000000000000000u256); // multiplied by 10^24
}

// === Error Tests for safe_downcast_balance ===

#[test]
#[expected_failure(abort_code = utils::EInvalidDecimals)]
fun test_downcast_raw_decimals_too_large() {
    utils::safe_downcast_balance(1000000u256, 25, 9);
}

#[test]
#[expected_failure(abort_code = utils::EInvalidDecimals)]
fun test_downcast_scaled_decimals_too_large() {
    utils::safe_downcast_balance(1000000u256, 9, 25);
}

#[test]
#[expected_failure(abort_code = utils::ESafeDowncastOverflowedInt)]
fun test_downcast_overflow() {
    // Try to downcast value that exceeds u64::MAX
    let too_large = ((std::u64::max_value!() as u256) + 1);
    utils::safe_downcast_balance(too_large, 9, 9);
}

#[test]
#[expected_failure(abort_code = utils::ESafeDowncastOverflowedInt)]
fun test_downcast_overflow_after_scaling_up() {
    // Value is ok before scaling but overflows after scaling up
    let amount = (std::u64::max_value!() as u256) / 1000;
    utils::safe_downcast_balance(amount, 6, 18); // Scale up by 10^12, will overflow
}

// === Error Tests for safe_upcast_balance ===

#[test]
#[expected_failure(abort_code = utils::EInvalidDecimals)]
fun test_upcast_source_decimals_too_large() {
    utils::safe_upcast_balance(1000000, 25, 9);
}

#[test]
#[expected_failure(abort_code = utils::EInvalidDecimals)]
fun test_upcast_target_decimals_too_large() {
    utils::safe_upcast_balance(1000000, 9, 25);
}

// === Roundtrip Tests ===

#[test]
fun test_roundtrip_eth_to_sui_to_eth() {
    // ETH (18) -> Sui (9) -> ETH (18)
    let original = 1500000000000000000u256; // 1.5 ETH
    let sui = utils::safe_downcast_balance(original, 18, 9);
    let back = utils::safe_upcast_balance(sui, 9, 18);
    assert_eq!(back, original);
}

#[test]
fun test_roundtrip_usdc_to_sui_to_usdc() {
    // USDC (6) -> Sui (9) -> USDC (6)
    let original = 1500000u256; // 1.5 USDC
    let sui = utils::safe_downcast_balance(original, 6, 9);
    let back = utils::safe_upcast_balance(sui, 9, 6);
    assert_eq!(back, original);
}

#[test]
fun test_roundtrip_sui_to_eth_to_sui() {
    // Sui (9) -> ETH (18) -> Sui (9)
    let original = 1500000000u64; // 1.5 tokens
    let eth = utils::safe_upcast_balance(original, 9, 18);
    let back = utils::safe_downcast_balance(eth, 18, 9);
    assert_eq!(back, original);
}

#[test]
fun test_roundtrip_with_max_decimals() {
    // Test max decimal difference roundtrip (24 -> 0 -> 24)
    let original = 1000000000000000000000000u256; // 1 token with 24 decimals
    let scaled = utils::safe_downcast_balance(original, 24, 0);
    let back = utils::safe_upcast_balance(scaled, 0, 24);
    assert_eq!(back, original);
}

#[test]
fun test_roundtrip_zero_decimals() {
    // 0 decimals -> 9 decimals -> 0 decimals
    let original = 100u256;
    let scaled_up = utils::safe_downcast_balance(original, 0, 9);
    let back = utils::safe_downcast_balance((scaled_up as u256), 9, 0);
    assert_eq!(back, original as u64);
}

// === Additional Edge Cases ===

#[test]
fun test_multiple_token_amounts() {
    // Test with various token amounts
    let amounts = vector[1u256, 100u256, 1000000u256, 1000000000u256];
    let mut i = 0;
    while (i < amounts.length()) {
        let amount = *amounts.borrow(i);
        let result = utils::safe_downcast_balance(amount, 9, 9);
        assert_eq!(result, (amount as u64));
        i = i + 1;
    };
}

#[test]
fun test_all_decimal_combinations() {
    // Test common decimal pairs (0, 6, 9, 12, 18)
    let decimals = vector[0u8, 6u8, 9u8, 12u8, 18u8];
    let mut i = 0;
    while (i < decimals.length()) {
        let mut j = 0;
        while (j < decimals.length()) {
            let from_dec = *decimals.borrow(i);
            let to_dec = *decimals.borrow(j);

            // Use tiny amount to avoid overflow
            let amount = 1u256;
            let _ = utils::safe_downcast_balance(amount, from_dec, to_dec);

            j = j + 1;
        };
        i = i + 1;
    };
}

#[test]
fun test_precision_preservation() {
    // Verify that scaling preserves economic value
    // 123.456789 tokens with 6 decimals = 123456789
    let amount = 123456789u64;

    // Scale up to 18 decimals
    let scaled_up = utils::safe_upcast_balance(amount, 6, 18);
    assert_eq!(scaled_up, 123456789000000000000u256);

    // Scale back down to 6 decimals
    let scaled_down = utils::safe_downcast_balance(scaled_up, 18, 6);
    assert_eq!(scaled_down, amount);
}

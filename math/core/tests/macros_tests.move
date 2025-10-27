module openzeppelin_math::macros_tests;

use openzeppelin_math::macros;
use openzeppelin_math::rounding;
use openzeppelin_math::u512;
use std::unit_test::assert_eq;

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
    let (macro_overflow, wide) = macros::mul_div_u256_wide(large, large, 7, rounding::down());
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
    let (overflow_up, up) = macros::mul_div_u256_wide(large, large, 7, rounding::up());
    assert_eq!(overflow_up, false);
    assert_eq!(up, baseline + 1);

    // Nearest mirrors `rounding::down` when the remainder is small...
    let denom_down = 13;
    let (_, baseline_down, remainder_down) = u512::div_rem_u256(numerator, denom_down);
    assert!(remainder_down < denom_down - remainder_down);
    let (overflow_nearest_down, nearest_down) =
        macros::mul_div_u256_wide(large, large, denom_down, rounding::nearest());
    assert_eq!(overflow_nearest_down, false);
    assert_eq!(nearest_down, baseline_down);

    // ...and bumps when the remainder dominates.
    let denom_up = 11;
    let (_, baseline_up, remainder_up) = u512::div_rem_u256(numerator, denom_up);
    assert!(remainder_up >= denom_up - remainder_up);
    let (overflow_nearest_up, nearest_up) =
        macros::mul_div_u256_wide(large, large, denom_up, rounding::nearest());
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
    let (overflow, _) = macros::mul_div_u256_wide(max, max, 1, rounding::down());
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
    let (wide_overflow, expected) = macros::mul_div_u256_wide(large, large, 7, rounding::down());
    assert_eq!(wide_overflow, false);
    assert_eq!(macro_result, expected);
}

#[test, expected_failure(abort_code = macros::EDivideByZero)]
fun macro_rejects_zero_denominator() {
    macros::mul_div!(1u64, 1u64, 0u64, rounding::down());
}

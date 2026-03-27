#[test_only]
module openzeppelin_fp_math::sd29x9_conversion_tests;

use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_convert;
use openzeppelin_fp_math::sd29x9_test_helpers::{neg, pos};
use std::unit_test::assert_eq;

const MAX_POSITIVE_VALUE: u128 = 0x7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
const SCALE: u128 = 1_000_000_000;

#[test]
fun from_u64_scales_positive_whole_numbers() {
    let value = sd29x9_convert::from_u64(42, false);
    assert_eq!(value.unwrap(), 42 * SCALE);
}

#[test]
fun from_u128_scales_negative_whole_numbers() {
    let value = sd29x9_convert::from_u128(42, true);
    assert_eq!(value, neg(42 * SCALE));
}

#[test]
fun from_u128_zero_clears_negative_sign() {
    let value = sd29x9_convert::from_u128(0, true);
    assert!(value.is_zero());
    assert_eq!(value, sd29x9::zero());
}

#[test]
fun from_u128_scales_max_supported_whole_magnitude() {
    let max_whole = MAX_POSITIVE_VALUE / SCALE;
    let positive = sd29x9_convert::from_u128(max_whole, false);
    let negative = sd29x9_convert::from_u128(max_whole, true);

    assert_eq!(positive.unwrap(), max_whole * SCALE);
    assert_eq!(negative, sd29x9::wrap(max_whole * SCALE, true));
}

#[test, expected_failure(abort_code = sd29x9_convert::EOverflow)]
fun from_u128_aborts_when_scaled_value_overflows() {
    let max_whole = MAX_POSITIVE_VALUE / SCALE;
    sd29x9_convert::from_u128(max_whole + 1, false);
}

#[test]
fun try_from_u128_returns_none_when_scaled_value_overflows() {
    let max_whole = MAX_POSITIVE_VALUE / SCALE;
    assert_eq!(sd29x9_convert::try_from_u128(max_whole + 1, false), option::none());
}

#[test]
fun try_from_u128_returns_some_for_max_supported_whole_magnitude() {
    let max_whole = MAX_POSITIVE_VALUE / SCALE;
    let expected = sd29x9::wrap(max_whole * SCALE, false);
    assert_eq!(sd29x9_convert::try_from_u128(max_whole, false), option::some(expected));
}

#[test]
fun to_parts_trunc_handles_positive_fractional_values() {
    let (magnitude, is_negative) = sd29x9_convert::to_parts_trunc(pos(42 * SCALE + 123_456_789));
    assert_eq!(magnitude, 42);
    assert!(!is_negative);
}

#[test]
fun to_parts_trunc_handles_negative_fractional_values() {
    let (magnitude, is_negative) = sd29x9_convert::to_parts_trunc(neg(42 * SCALE + 123_456_789));
    assert_eq!(magnitude, 42);
    assert!(is_negative);
}

#[test]
fun to_parts_trunc_clears_sign_for_subunit_negative_values() {
    let (magnitude, is_negative) = sd29x9_convert::to_parts_trunc(neg(1));
    assert_eq!(magnitude, 0);
    assert!(!is_negative);
}

#[test]
fun to_u128_trunc_converts_supported_positive_values() {
    let value = pos(42 * SCALE + 999_999_999);
    assert_eq!(sd29x9_convert::to_u128_trunc(value), 42);
}

#[test, expected_failure(abort_code = sd29x9_convert::ENegativeValue)]
fun to_u128_trunc_aborts_for_negative_values() {
    sd29x9_convert::to_u128_trunc(neg(SCALE));
}

#[test]
fun try_to_u128_trunc_returns_none_for_negative_values() {
    assert_eq!(sd29x9_convert::try_to_u128_trunc(neg(SCALE)), option::none());
}

#[test]
fun to_u64_trunc_converts_supported_positive_values() {
    let value = pos(42 * SCALE + 500_000_000);
    assert_eq!(sd29x9_convert::to_u64_trunc(value), 42);
}

#[test, expected_failure(abort_code = sd29x9_convert::EIntegerOverflow)]
fun to_u64_trunc_aborts_when_whole_part_exceeds_u64_max() {
    let overflow_whole = (std::u64::max_value!() as u128) + 1;
    let value = sd29x9::wrap(overflow_whole * SCALE, false);
    sd29x9_convert::to_u64_trunc(value);
}

#[test]
fun try_to_u64_trunc_returns_none_for_negative_values() {
    assert_eq!(sd29x9_convert::try_to_u64_trunc(neg(SCALE)), option::none());
}

#[test]
fun try_to_u64_trunc_returns_none_when_whole_part_exceeds_u64_max() {
    let overflow_whole = (std::u64::max_value!() as u128) + 1;
    let value = sd29x9::wrap(overflow_whole * SCALE, false);
    assert_eq!(sd29x9_convert::try_to_u64_trunc(value), option::none());
}

#[test]
fun whole_number_roundtrip_preserves_supported_positive_values() {
    let samples = vector[0, 1, 42, 1_000_000, (std::u64::max_value!() as u128)];

    samples.destroy!(|whole| {
        let fixed = sd29x9_convert::from_u128(whole, false);
        assert_eq!(sd29x9_convert::to_u128_trunc(fixed), whole);
    });
}

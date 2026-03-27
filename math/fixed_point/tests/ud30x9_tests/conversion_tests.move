#[test_only]
module openzeppelin_fp_math::ud30x9_conversion_tests;

use openzeppelin_fp_math::ud30x9;
use openzeppelin_fp_math::ud30x9_convert;
use openzeppelin_fp_math::ud30x9_test_helpers::fixed;
use std::unit_test::assert_eq;

const MAX_RAW_VALUE: u128 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
const SCALE: u128 = 1_000_000_000;

#[test]
fun from_u64_scales_whole_numbers() {
    let value = ud30x9_convert::from_u64(42);
    assert_eq!(value.unwrap(), 42 * SCALE);
}

#[test]
fun from_u128_scales_max_supported_whole_number() {
    let max_whole = MAX_RAW_VALUE / SCALE;
    let value = ud30x9_convert::from_u128(max_whole);
    assert_eq!(value.unwrap(), max_whole * SCALE);
}

#[test, expected_failure(abort_code = ud30x9_convert::EOverflow)]
fun from_u128_aborts_when_scaled_value_overflows() {
    let max_whole = MAX_RAW_VALUE / SCALE;
    ud30x9_convert::from_u128(max_whole + 1);
}

#[test]
fun try_from_u128_returns_none_when_scaled_value_overflows() {
    let max_whole = MAX_RAW_VALUE / SCALE;
    assert_eq!(ud30x9_convert::try_from_u128(max_whole + 1), option::none());
}

#[test]
fun try_from_u128_returns_some_for_max_supported_whole_number() {
    let max_whole = MAX_RAW_VALUE / SCALE;
    let expected = ud30x9::wrap(max_whole * SCALE);
    assert_eq!(ud30x9_convert::try_from_u128(max_whole), option::some(expected));
}

#[test]
fun to_u128_trunc_drops_fractional_part() {
    assert_eq!(ud30x9_convert::to_u128_trunc(fixed(42 * SCALE + 123_456_789)), 42);
    assert_eq!(ud30x9_convert::to_u128_trunc(fixed(SCALE - 1)), 0);
}

#[test]
fun to_u128_trunc_handles_max_raw_value() {
    let max = ud30x9::max();
    let expected = MAX_RAW_VALUE / SCALE;
    assert_eq!(ud30x9_convert::to_u128_trunc(max), expected);
}

#[test]
fun to_u64_trunc_converts_supported_values() {
    let value = fixed(42 * SCALE + 999_999_999);
    assert_eq!(ud30x9_convert::to_u64_trunc(value), 42);
}

#[test, expected_failure(abort_code = ud30x9_convert::EIntegerOverflow)]
fun to_u64_trunc_aborts_when_whole_part_exceeds_u64_max() {
    let overflow_whole = (std::u64::max_value!() as u128) + 1;
    let value = ud30x9::wrap(overflow_whole * SCALE);
    ud30x9_convert::to_u64_trunc(value);
}

#[test]
fun try_to_u64_trunc_returns_none_when_whole_part_exceeds_u64_max() {
    let overflow_whole = (std::u64::max_value!() as u128) + 1;
    let value = ud30x9::wrap(overflow_whole * SCALE);
    assert_eq!(ud30x9_convert::try_to_u64_trunc(value), option::none());
}

#[test]
fun whole_number_roundtrip_preserves_supported_values() {
    let samples = vector[0, 1, 42, 1_000_000, (std::u64::max_value!() as u128)];

    samples.destroy!(|whole| {
        let fixed = ud30x9_convert::from_u128(whole);
        assert_eq!(ud30x9_convert::to_u128_trunc(fixed), whole);
    });
}

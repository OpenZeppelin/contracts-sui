#[test_only]
module openzeppelin_fp_math::ud30x9_casting_tests;

use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::ud30x9;
use openzeppelin_fp_math::ud30x9_base;
use openzeppelin_fp_math::ud30x9_test_helpers::fixed;
use std::unit_test::assert_eq;

const MAX_POSITIVE_SD29X9: u128 = 0x7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
const SCALE: u128 = 1_000_000_000;

// ==== Tests ====

#[test]
fun into_sd29x9_converts_zero() {
    let zero = ud30x9::zero();
    let converted = zero.into_SD29x9();
    assert!(converted.is_zero());
    assert!(converted.eq(sd29x9::zero()));
}

#[test]
fun into_sd29x9_converts_integer_and_fractional_values() {
    // 42.0
    let integer = fixed(42 * SCALE);
    assert_eq!(integer.into_SD29x9().unwrap(), 42 * SCALE);

    // 42.123456789
    let fractional = fixed(42 * SCALE + 123_456_789);
    assert_eq!(fractional.into_SD29x9().unwrap(), 42 * SCALE + 123_456_789);
}

#[test]
fun into_sd29x9_roundtrip_for_supported_values() {
    let samples = vector[
        0,
        1,
        SCALE - 1,
        SCALE,
        SCALE + 1,
        123 * SCALE + 456_789_012,
        MAX_POSITIVE_SD29X9 - 1,
        MAX_POSITIVE_SD29X9,
    ];

    samples.destroy!(|val| {
        let x = fixed(val);
        let result = x.into_SD29x9().into_UD30x9();
        assert_eq!(x, result);
    });
}

#[test]
fun into_sd29x9_converts_max_supported_value() {
    let max_supported = fixed(MAX_POSITIVE_SD29X9);
    let expected = sd29x9::wrap(MAX_POSITIVE_SD29X9, false);
    assert_eq!(max_supported.into_SD29x9(), expected);
}

#[test, expected_failure(abort_code = ud30x9_base::ECannotBeConvertedToSD29x9)]
fun into_sd29x9_aborts_when_value_exceeds_sd29x9_max() {
    let unsupported_val = fixed(MAX_POSITIVE_SD29X9 + 1);
    unsupported_val.into_SD29x9();
}

#[test, expected_failure(abort_code = ud30x9_base::ECannotBeConvertedToSD29x9)]
fun into_sd29x9_aborts_for_ud30x9_max() {
    ud30x9::max().into_SD29x9();
}

#[test]
fun try_into_sd29x9_returns_some_for_zero() {
    let zero = ud30x9::zero();
    let result = zero.try_into_SD29x9();
    assert_eq!(result, option::some(sd29x9::zero()));
    result.do!(|val| assert!(val.is_zero()));
}

#[test]
fun try_into_sd29x9_returns_some_for_integer_and_fractional_values() {
    // 42.0
    let int_val = fixed(42 * SCALE);
    let expected_int = sd29x9::wrap(42 * SCALE, false);
    assert_eq!(int_val.try_into_SD29x9(), option::some(expected_int));

    // 42.123456789
    let fractional = fixed(42 * SCALE + 123_456_789);
    let expected_fractional = sd29x9::wrap(42 * SCALE + 123_456_789, false);
    assert_eq!(fractional.try_into_SD29x9(), option::some(expected_fractional));
}

#[test]
fun try_into_sd29x9_roundtrip_for_supported_values() {
    let samples = vector[
        0,
        1,
        SCALE - 1,
        SCALE,
        SCALE + 1,
        123 * SCALE + 456_789_012,
        MAX_POSITIVE_SD29X9 - 1,
        MAX_POSITIVE_SD29X9,
    ];

    samples.destroy!(|val| {
        let x = fixed(val);
        let result = x.try_into_SD29x9().destroy_some().try_into_UD30x9().destroy_some();
        assert_eq!(x, result);
    });
}

#[test]
fun try_into_sd29x9_returns_some_for_max_supported_value() {
    let max_supported = fixed(MAX_POSITIVE_SD29X9);
    let expected = sd29x9::wrap(MAX_POSITIVE_SD29X9, false);
    assert_eq!(max_supported.try_into_SD29x9(), option::some(expected));
}

#[test]
fun try_into_sd29x9_returns_none_when_value_exceeds_sd29x9_max() {
    let unsupported_val = fixed(MAX_POSITIVE_SD29X9 + 1);
    assert_eq!(unsupported_val.try_into_SD29x9(), option::none());
}

#[test]
fun try_into_sd29x9_returns_none_for_ud30x9_max() {
    assert_eq!(ud30x9::max().try_into_SD29x9(), option::none());
}

#[test]
fun try_into_sd29x9_matches_into_sd29x9_on_convertible_values() {
    let samples = vector[0, 1, SCALE - 1, SCALE, 123 * SCALE + 456_789_012, MAX_POSITIVE_SD29X9];

    samples.destroy!(|raw| {
        let x = fixed(raw);
        assert_eq!(ud30x9_base::try_into_SD29x9(x), option::some(x.into_SD29x9()));
    });
}

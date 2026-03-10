#[test_only]
module openzeppelin_fp_math::sd29x9_casting_tests;

use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_base;
use openzeppelin_fp_math::sd29x9_test_helpers::{pos, neg};
use openzeppelin_fp_math::ud30x9;
use std::unit_test::assert_eq;

const MAX_POSITIVE_VALUE: u128 = 0x7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
const SCALE: u128 = 1_000_000_000;

#[test]
fun into_ud30x9_converts_zero() {
    let zero = sd29x9::zero();
    let converted = zero.into_UD30x9();
    assert!(converted.is_zero());
    assert!(converted.eq(ud30x9::zero()));
}

#[test]
fun into_ud30x9_converts_integer_and_fractional_values() {
    // 42.0
    let integer = pos(42 * SCALE);
    let expected_int = ud30x9::wrap(42 * SCALE);
    assert_eq!(integer.into_UD30x9(), expected_int);

    // 42.123456789
    let fractional = pos(42 * SCALE + 123_456_789);
    let expected_fractional = ud30x9::wrap(42 * SCALE + 123_456_789);
    assert_eq!(fractional.into_UD30x9(), expected_fractional);
}

#[test]
fun into_ud30x9_roundtrip_for_supported_values() {
    let samples = vector[
        0,
        1,
        SCALE - 1,
        SCALE,
        SCALE + 1,
        123 * SCALE + 456_789_012,
        MAX_POSITIVE_VALUE,
    ];

    samples.destroy!(|val| {
        let x = pos(val);
        let result = x.into_UD30x9().into_SD29x9();
        assert_eq!(x, result);
    });
}

#[test]
fun into_ud30x9_converts_max_supported_value() {
    let max_supported = sd29x9::max();
    let expected = ud30x9::wrap(MAX_POSITIVE_VALUE);
    assert_eq!(max_supported.into_UD30x9(), expected);
}

#[test, expected_failure(abort_code = sd29x9_base::ECannotBeConvertedToUD30x9)]
fun into_ud30x9_aborts_for_negative_fractional_value() {
    let unsupported_val = neg(SCALE + 1);
    unsupported_val.into_UD30x9();
}

#[test, expected_failure(abort_code = sd29x9_base::ECannotBeConvertedToUD30x9)]
fun into_ud30x9_aborts_for_negative_integer_value() {
    neg(SCALE).into_UD30x9();
}

#[test, expected_failure(abort_code = sd29x9_base::ECannotBeConvertedToUD30x9)]
fun into_ud30x9_aborts_for_sd29x9_min() {
    sd29x9::min().into_UD30x9();
}

#[test]
fun try_into_ud30x9_returns_some_for_zero() {
    let zero = sd29x9::zero();
    let result = zero.try_into_UD30x9();
    assert_eq!(result, option::some(ud30x9::zero()));
    result.do!(|val| assert!(val.is_zero()));
}

#[test]
fun try_into_ud30x9_returns_some_for_integer_and_fractional_values() {
    // 42.0
    let int_val = pos(42 * SCALE);
    let expected_int = ud30x9::wrap(42 * SCALE);
    assert_eq!(int_val.try_into_UD30x9(), option::some(expected_int));

    // 42.123456789
    let fractional = pos(42 * SCALE + 123_456_789);
    let expected_fractional = ud30x9::wrap(42 * SCALE + 123_456_789);
    assert_eq!(fractional.try_into_UD30x9(), option::some(expected_fractional));
}

#[test]
fun try_into_ud30x9_roundtrip_for_supported_values() {
    let samples = vector[
        0,
        1,
        SCALE - 1,
        SCALE,
        SCALE + 1,
        123 * SCALE + 456_789_012,
        MAX_POSITIVE_VALUE,
    ];

    samples.destroy!(|val| {
        let x = pos(val);
        let result = x.try_into_UD30x9().destroy_some().try_into_SD29x9().destroy_some();
        assert_eq!(x, result);
    });
}

#[test]
fun try_into_ud30x9_returns_some_for_max_supported_value() {
    let max_supported = sd29x9::max();
    let expected = ud30x9::wrap(MAX_POSITIVE_VALUE);
    assert_eq!(max_supported.try_into_UD30x9(), option::some(expected));
}

#[test]
fun try_into_ud30x9_returns_none_for_negative_fractional_value() {
    let unsupported_val = neg(SCALE + 1);
    assert_eq!(unsupported_val.try_into_UD30x9(), option::none());
}

#[test]
fun try_into_ud30x9_returns_none_for_negative_integer_value() {
    assert_eq!(neg(SCALE).try_into_UD30x9(), option::none());
}

#[test]
fun try_into_ud30x9_returns_none_for_sd29x9_min() {
    assert_eq!(sd29x9::min().try_into_UD30x9(), option::none());
}

#[test]
fun try_into_ud30x9_matches_into_ud30x9_on_convertible_values() {
    let samples = vector[0, 1, SCALE - 1, SCALE, 123 * SCALE + 456_789_012, MAX_POSITIVE_VALUE];

    samples.destroy!(|raw| {
        let x = pos(raw);
        assert_eq!(sd29x9_base::try_into_UD30x9(x), option::some(x.into_UD30x9()));
    });
}

#[test_only]
module openzeppelin_fp_math::ud30x9_wrap_tests;

use openzeppelin_fp_math::u128_cast::into_UD30x9;
use openzeppelin_fp_math::ud30x9;
use openzeppelin_fp_math::ud30x9_test_helpers::fixed;
use std::unit_test::assert_eq;

use fun into_UD30x9 as u128.into_UD30x9;

const MAX_VALUE: u128 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
const SCALE: u128 = 1_000_000_000;

// ==== Tests ====

#[test]
fun wrap_and_unwrap_roundtrip() {
    let raw = 123_456_789u128;
    let value = ud30x9::wrap(raw);
    assert_eq!(value.unwrap(), raw);

    let zero = ud30x9::wrap(0);
    assert_eq!(zero.unwrap(), 0);
}

#[test]
fun casting_from_u128_matches_wrap() {
    let raw = 987_654_321u128;
    let casted = raw.into_UD30x9();
    assert_eq!(casted.unwrap(), raw);

    let manual = fixed(raw);
    assert_eq!(manual.unwrap(), raw);
}

#[test]
fun wrap_zero() {
    assert!(ud30x9::wrap(0).is_zero());
    assert!(ud30x9::zero().is_zero());
}

#[test]
fun wrap_one() {
    assert_eq!(ud30x9::wrap(1).unwrap(), 1);
}

#[test]
fun wrap_scale() {
    assert_eq!(ud30x9::wrap(SCALE).unwrap(), SCALE);
}

#[test]
fun wrap_max_value() {
    assert_eq!(ud30x9::wrap(MAX_VALUE).unwrap(), ud30x9::max().unwrap());
}

#[test]
fun wrap_large_value() {
    assert_eq!(fixed(987_654_321_000_000_000).unwrap(), 987_654_321_000_000_000);
}

#[test]
fun wrap_scale_minus_one() {
    assert_eq!(fixed(SCALE - 1).unwrap(), SCALE - 1);
}

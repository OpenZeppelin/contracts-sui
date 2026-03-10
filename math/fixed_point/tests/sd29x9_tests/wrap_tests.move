#[test_only]
module openzeppelin_fp_math::sd29x9_wrap_tests;

use openzeppelin_fp_math::sd29x9::{Self, from_bits};
use openzeppelin_fp_math::sd29x9_test_helpers::{pos, neg, expect};
use std::unit_test::assert_eq;

const ALL_ONES: u128 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
const MAX_POSITIVE_VALUE: u128 = 0x7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
const MIN_NEGATIVE_VALUE: u128 = 0x8000_0000_0000_0000_0000_0000_0000_0000;

#[test]
fun wrap_max_positive() {
    let value = sd29x9::wrap(MAX_POSITIVE_VALUE, false);
    expect(value, sd29x9::max());
}

#[test]
fun wrap_zero_is_zero() {
    assert!(sd29x9::wrap(0, false).is_zero());
}

#[test]
fun wrap_negative_zero_is_zero() {
    assert!(sd29x9::wrap(0, true).is_zero());
}

#[test]
fun wrap_min_value() {
    expect(sd29x9::min(), from_bits(MIN_NEGATIVE_VALUE));
}

#[test, expected_failure(abort_code = sd29x9::EOverflow)]
fun wrap_cannot_produce_min_value() {
    // wrap() cannot represent min value; use min() instead
    sd29x9::wrap(MIN_NEGATIVE_VALUE, true);
}

#[test]
fun wrap_small_positive() {
    assert_eq!(pos(1).unwrap(), 1);
}

#[test]
fun wrap_negative_one_is_all_ones() {
    assert_eq!(neg(1).unwrap(), ALL_ONES);
}

#[test]
fun from_bits_zero() {
    assert!(from_bits(0).is_zero());
}

#[test]
fun from_bits_all_ones() {
    assert_eq!(from_bits(ALL_ONES).unwrap(), ALL_ONES);
}

#[test]
fun from_bits_max_positive() {
    expect(from_bits(MAX_POSITIVE_VALUE), sd29x9::max());
}

#[test]
fun from_bits_min_negative() {
    expect(from_bits(MIN_NEGATIVE_VALUE), sd29x9::min());
}

#[test]
fun from_bits_one() {
    expect(from_bits(1), pos(1));
}

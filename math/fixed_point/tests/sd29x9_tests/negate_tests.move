#[test_only]
module openzeppelin_fp_math::sd29x9_negate_tests;

use openzeppelin_fp_math::sd29x9::{Self, from_bits};
use openzeppelin_fp_math::sd29x9_base;
use openzeppelin_fp_math::sd29x9_test_helpers::{pos, neg};
use std::unit_test::assert_eq;

const MIN_NEGATIVE_VALUE: u128 = 0x8000_0000_0000_0000_0000_0000_0000_0000;
const SCALE: u128 = 1_000_000_000;

#[test]
fun negate_handles_zero() {
    assert_eq!(sd29x9::zero().negate(), sd29x9::zero());
}

#[test]
fun negate_flips_positive_and_negative_values() {
    assert_eq!(pos(1).negate(), neg(1));
    assert_eq!(pos(SCALE).negate(), neg(SCALE));
    assert_eq!(pos(5 * SCALE + 300_000_000).negate(), neg(5 * SCALE + 300_000_000));

    assert_eq!(neg(1).negate(), pos(1));
    assert_eq!(neg(SCALE).negate(), pos(SCALE));
    assert_eq!(neg(5 * SCALE + 300_000_000).negate(), pos(5 * SCALE + 300_000_000));
}

#[test]
fun negate_is_its_own_inverse() {
    let zero = sd29x9::zero();
    assert_eq!(zero.negate().negate(), zero);

    let one = pos(1);
    assert_eq!(one.negate().negate(), one);

    let minus_one = neg(1);
    assert_eq!(minus_one.negate().negate(), minus_one);

    let large_positive = pos(500_000_000_000_000_000);
    assert_eq!(large_positive.negate().negate(), large_positive);

    let large_negative = neg(500_000_000_000_000_000);
    assert_eq!(large_negative.negate().negate(), large_negative);

    let pos_with_fraction = pos(42 * SCALE + 123_456_789);
    assert_eq!(pos_with_fraction.negate().negate(), pos_with_fraction);

    let neg_with_fraction = neg(42 * SCALE + 123_456_789);
    assert_eq!(neg_with_fraction.negate().negate(), neg_with_fraction);

    let max = sd29x9::max();
    assert_eq!(max.negate().negate(), max);
}

#[test]
fun negate_handles_max() {
    assert_eq!(sd29x9::max().negate(), from_bits(MIN_NEGATIVE_VALUE + 1));
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun negate_fails_for_min() {
    sd29x9::min().negate();
}

#[test]
fun negate_handles_min_plus_smallest_step() {
    let min_plus_epsilon = neg(MIN_NEGATIVE_VALUE - 1);
    assert_eq!(min_plus_epsilon.negate(), sd29x9::max());
}

#[test]
fun negate_one() {
    assert_eq!(pos(SCALE).negate(), neg(SCALE));
    assert_eq!(neg(SCALE).negate(), pos(SCALE));
}

#[test]
fun negate_large_value() {
    assert_eq!(neg(500_000_000_000).negate(), pos(500_000_000_000));
}

#[test]
fun negate_changes_sign_bit() {
    let raw = 42 * SCALE;
    assert!(pos(raw).negate().unwrap() != raw);
}

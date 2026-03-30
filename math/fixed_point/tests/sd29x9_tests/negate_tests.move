#[test_only]
module openzeppelin_fp_math::sd29x9_negate_tests;

use openzeppelin_fp_math::sd29x9::{Self, from_bits};
use openzeppelin_fp_math::sd29x9_base;
use openzeppelin_fp_math::sd29x9_test_helpers::{pos, neg, expect};

const MIN_NEGATIVE_VALUE: u128 = 0x8000_0000_0000_0000_0000_0000_0000_0000;
const SCALE: u128 = 1_000_000_000;

#[test]
fun negate_handles_zero() {
    expect!(sd29x9::zero().negate(), sd29x9::zero());
}

#[test]
fun negate_flips_positive_and_negative_values() {
    expect!(pos(1).negate(), neg(1));
    expect!(pos(SCALE).negate(), neg(SCALE));
    expect!(pos(5 * SCALE + 300_000_000).negate(), neg(5 * SCALE + 300_000_000));

    expect!(neg(1).negate(), pos(1));
    expect!(neg(SCALE).negate(), pos(SCALE));
    expect!(neg(5 * SCALE + 300_000_000).negate(), pos(5 * SCALE + 300_000_000));
}

#[test]
fun negate_is_its_own_inverse() {
    let zero = sd29x9::zero();
    expect!(zero.negate().negate(), zero);

    let one = pos(1);
    expect!(one.negate().negate(), one);

    let minus_one = neg(1);
    expect!(minus_one.negate().negate(), minus_one);

    let large_positive = pos(500_000_000_000_000_000);
    expect!(large_positive.negate().negate(), large_positive);

    let large_negative = neg(500_000_000_000_000_000);
    expect!(large_negative.negate().negate(), large_negative);

    let pos_with_fraction = pos(42 * SCALE + 123_456_789);
    expect!(pos_with_fraction.negate().negate(), pos_with_fraction);

    let neg_with_fraction = neg(42 * SCALE + 123_456_789);
    expect!(neg_with_fraction.negate().negate(), neg_with_fraction);

    let max = sd29x9::max();
    expect!(max.negate().negate(), max);
}

#[test]
fun negate_handles_max() {
    expect!(sd29x9::max().negate(), from_bits(MIN_NEGATIVE_VALUE + 1));
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun negate_fails_for_min() {
    sd29x9::min().negate();
}

#[test]
fun negate_handles_min_plus_smallest_step() {
    let min_plus_epsilon = neg(MIN_NEGATIVE_VALUE - 1);
    expect!(min_plus_epsilon.negate(), sd29x9::max());
}

#[test]
fun negate_one() {
    expect!(pos(SCALE).negate(), neg(SCALE));
    expect!(neg(SCALE).negate(), pos(SCALE));
}

#[test]
fun negate_large_value() {
    expect!(neg(500_000_000_000).negate(), pos(500_000_000_000));
}

#[test]
fun negate_changes_sign_bit() {
    let raw = 42 * SCALE;
    assert!(pos(raw).negate().unwrap() != raw);
}

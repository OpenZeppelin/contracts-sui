#[test_only]
module openzeppelin_fp_math::sd29x9_is_negative_tests;

use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_test_helpers::{neg, pos};
use std::unit_test::assert_eq;

const SCALE: u128 = 1_000_000_000;

#[test]
fun returns_false_for_zero() {
    assert_eq!(sd29x9::zero().is_negative(), false);
}

#[test]
fun returns_false_for_positive_values() {
    assert_eq!(pos(1).is_negative(), false);
    assert_eq!(pos(SCALE).is_negative(), false);
    assert_eq!(pos(5 * SCALE + 500_000_000).is_negative(), false);
}

#[test]
fun returns_true_for_negative_values() {
    assert_eq!(neg(1).is_negative(), true);
    assert_eq!(neg(SCALE).is_negative(), true);
    assert_eq!(neg(5 * SCALE + 500_000_000).is_negative(), true);
}

#[test]
fun returns_false_for_max() {
    assert_eq!(sd29x9::max().is_negative(), false);
}

#[test]
fun returns_true_for_min() {
    assert_eq!(sd29x9::min().is_negative(), true);
}

#[test]
fun matches_sign_bit_at_boundary() {
    // The largest positive raw magnitude (2^127 - 1) must read as non-negative.
    let max_pos: u128 = 0x7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
    assert_eq!(sd29x9::wrap(max_pos, false).is_negative(), false);
    // The smallest-magnitude negative value (magnitude 1, i.e. -10^-9; raw bit
    // pattern 0xFFFF...FF after two's complement) must read as negative.
    assert_eq!(sd29x9::wrap(1, true).is_negative(), true);
}

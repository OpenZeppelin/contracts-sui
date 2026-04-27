#[test_only]
module openzeppelin_fp_math::sd29x9_ceil_tests;

use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_base;
use openzeppelin_fp_math::sd29x9_test_helpers::{pos, neg};
use std::unit_test::assert_eq;

const MIN_NEGATIVE_VALUE: u128 = 0x8000_0000_0000_0000_0000_0000_0000_0000;
const SCALE: u128 = 1_000_000_000;

#[test]
fun ceil_rounds_up_positive_fractional_values() {
    // 5.3 -> 6.0
    assert_eq!(pos(5 * SCALE + 300_000_000).ceil(), pos(6 * SCALE));
    // 5.9 -> 6.0
    assert_eq!(pos(5 * SCALE + 900_000_000).ceil(), pos(6 * SCALE));
    // 1.1 -> 2.0
    assert_eq!(pos(SCALE + 100_000_000).ceil(), pos(2 * SCALE));
    // 0.5 -> 1.0
    assert_eq!(pos(500_000_000).ceil(), pos(SCALE));
    // 0.1 -> 1.0
    assert_eq!(pos(100_000_000).ceil(), pos(SCALE));
}

#[test]
fun ceil_truncates_negative_fractional_values() {
    // -5.3 -> -5.0
    assert_eq!(neg(5 * SCALE + 300_000_000).ceil(), neg(5 * SCALE));
    // -5.9 -> -5.0
    assert_eq!(neg(5 * SCALE + 900_000_000).ceil(), neg(5 * SCALE));
    // -1.1 -> -1.0
    assert_eq!(neg(SCALE + 100_000_000).ceil(), neg(SCALE));
    // -0.5 -> 0.0
    assert_eq!(neg(500_000_000).ceil(), sd29x9::zero());
    // -0.1 -> 0.0
    assert_eq!(neg(100_000_000).ceil(), sd29x9::zero());
}

#[test]
fun ceil_preserves_integer_values() {
    // 5.0 -> 5.0
    assert_eq!(pos(5 * SCALE).ceil(), pos(5 * SCALE));
    // -5.0 -> -5.0
    assert_eq!(neg(5 * SCALE).ceil(), neg(5 * SCALE));
    // 0.0 -> 0.0
    assert_eq!(sd29x9::zero().ceil(), sd29x9::zero());
    // 100.0 -> 100.0
    assert_eq!(pos(100 * SCALE).ceil(), pos(100 * SCALE));
}

#[test]
fun ceil_handles_edge_cases() {
    // Very small positive fractional: 0.000000001 -> ceil: 1.0
    assert_eq!(pos(1).ceil(), pos(SCALE));

    // Very small negative fractional: -0.000000001 -> ceil: 0.0
    assert_eq!(neg(1).ceil(), sd29x9::zero());

    // Large value with fraction: 1000000000.5 -> ceil: 1000000001.0
    assert_eq!(pos(1_000_000_000 * SCALE + 500_000_000).ceil(), pos(1_000_000_001 * SCALE));
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun ceil_fails_for_max() {
    sd29x9::max().ceil();
}

#[test]
fun ceil_handles_min() {
    let min = sd29x9::min();
    let expected = MIN_NEGATIVE_VALUE - MIN_NEGATIVE_VALUE % SCALE;
    assert_eq!(min.ceil(), neg(expected));
}

#[test]
fun ceil_of_zero() {
    assert_eq!(sd29x9::zero().ceil(), sd29x9::zero());
}

#[test]
fun ceil_of_negative_just_above_integer() {
    // -0.999999999 -> 0
    assert_eq!(neg(999_999_999).ceil(), sd29x9::zero());
}

#[test]
fun ceil_of_exact_negative_integer() {
    assert_eq!(neg(5 * SCALE).ceil(), neg(5 * SCALE));
}

#[test]
fun ceil_of_pos_just_above_integer() {
    // 1.000000001 -> 2
    assert_eq!(pos(SCALE + 1).ceil(), pos(2 * SCALE));
}

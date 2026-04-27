#[test_only]
module openzeppelin_fp_math::sd29x9_abs_tests;

use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_base;
use openzeppelin_fp_math::sd29x9_test_helpers::{pos, neg};
use std::unit_test::assert_eq;

const MAX_POSITIVE_VALUE: u128 = 0x7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
const SCALE: u128 = 1_000_000_000;

#[test]
fun abs_preserves_positive_values() {
    // 5.0 -> 5.0
    assert_eq!(pos(5 * SCALE).abs(), pos(5 * SCALE));
    // 5.5 -> 5.5
    assert_eq!(pos(5 * SCALE + 500_000_000).abs(), pos(5 * SCALE + 500_000_000));
    // 0.1 -> 0.1
    assert_eq!(pos(100_000_000).abs(), pos(100_000_000));
}

#[test]
fun abs_converts_negative_to_positive() {
    // -5.0 -> 5.0
    assert_eq!(neg(5 * SCALE).abs(), pos(5 * SCALE));
    // -5.5 -> 5.5
    assert_eq!(neg(5 * SCALE + 500_000_000).abs(), pos(5 * SCALE + 500_000_000));
    // -0.1 -> 0.1
    assert_eq!(neg(100_000_000).abs(), pos(100_000_000));
    // -1.0 -> 1.0
    assert_eq!(neg(SCALE).abs(), pos(SCALE));
}

#[test]
fun abs_handles_zero() {
    // 0.0 -> 0.0
    assert_eq!(sd29x9::zero().abs(), sd29x9::zero());
}

#[test]
fun abs_handles_edge_cases() {
    // Very small positive: 0.000000001 -> 0.000000001
    assert_eq!(pos(1).abs(), pos(1));

    // Very small negative: -0.000000001 -> 0.000000001
    assert_eq!(neg(1).abs(), pos(1));

    // Large positive value: 1000000000.5 -> 1000000000.5
    assert_eq!(
        pos(1_000_000_000 * SCALE + 500_000_000).abs(),
        pos(1_000_000_000 * SCALE + 500_000_000),
    );

    // Large negative value: -1000000000.5 -> 1000000000.5
    assert_eq!(
        neg(1_000_000_000 * SCALE + 500_000_000).abs(),
        pos(1_000_000_000 * SCALE + 500_000_000),
    );

    // Max positive value remains unchanged
    assert_eq!(sd29x9::max().abs(), sd29x9::max());
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun abs_fails_for_min() {
    sd29x9::min().abs();
}

#[test]
fun abs_of_max_minus_one() {
    assert_eq!(pos(MAX_POSITIVE_VALUE - 1).abs(), pos(MAX_POSITIVE_VALUE - 1));
}

#[test]
fun abs_double_application() {
    // abs is idempotent on result
    assert_eq!(neg(42 * SCALE).abs().abs(), pos(42 * SCALE));
}

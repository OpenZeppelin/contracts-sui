#[test_only]
module openzeppelin_fp_math::ud30x9_abs_tests;

use openzeppelin_fp_math::ud30x9;
use openzeppelin_fp_math::ud30x9_test_helpers::{fixed, expect};
use std::unit_test::assert_eq;

const MAX_VALUE: u128 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
const SCALE: u128 = 1_000_000_000;

// ==== Tests ====

#[test]
fun abs_returns_same_value_for_unsigned() {
    // 5.0 -> 5.0
    let value = fixed(5 * SCALE);
    assert_eq!(value.abs().unwrap(), value.unwrap());

    // 5.5 -> 5.5
    let value = fixed(5 * SCALE + 500_000_000);
    assert_eq!(value.abs().unwrap(), value.unwrap());

    // 0.1 -> 0.1
    let value = fixed(100_000_000);
    assert_eq!(value.abs().unwrap(), value.unwrap());
}

#[test]
fun abs_handles_zero() {
    // 0.0 -> 0.0
    let zero = ud30x9::zero();
    assert_eq!(zero.abs().unwrap(), 0);
}

#[test]
fun abs_handles_edge_cases() {
    // 0.000000001 -> 0.000000001
    let tiny = fixed(1);
    expect!(tiny.abs(), tiny);

    // 1000000.5 -> 1000000.5
    let large = fixed(1000000 * SCALE + 500_000_000);
    expect!(large.abs(), large);

    // Max value remains unchanged
    let max = ud30x9::max();
    assert_eq!(max.abs().unwrap(), MAX_VALUE);
}

#[test]
fun abs_of_one() {
    assert_eq!(fixed(SCALE).abs().unwrap(), SCALE);
}

#[test]
fun abs_of_scale_minus_one() {
    assert_eq!(fixed(SCALE - 1).abs().unwrap(), SCALE - 1);
}

#[test]
fun abs_of_max() {
    expect!(ud30x9::max().abs(), ud30x9::max());
}

#[test]
fun abs_is_idempotent() {
    assert_eq!(fixed(42 * SCALE).abs().abs().unwrap(), 42 * SCALE);
}

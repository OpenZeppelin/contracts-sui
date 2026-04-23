#[test_only]
module openzeppelin_fp_math::ud30x9_floor_tests;

use openzeppelin_fp_math::ud30x9;
use openzeppelin_fp_math::ud30x9_test_helpers::fixed;
use std::unit_test::assert_eq;

const MAX_VALUE: u128 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
const SCALE: u128 = 1_000_000_000;

#[test]
fun floor_truncates_fractional_values() {
    // 5.3 -> 5.0
    let value = fixed(5 * SCALE + 300_000_000);
    assert_eq!(value.floor(), fixed(5 * SCALE));

    // 5.9 -> 5.0
    let value = fixed(5 * SCALE + 900_000_000);
    assert_eq!(value.floor(), fixed(5 * SCALE));

    // 1.1 -> 1.0
    let value = fixed(SCALE + 100_000_000);
    assert_eq!(value.floor(), fixed(SCALE));

    // 0.5 -> 0.0
    let value = fixed(500_000_000);
    assert_eq!(value.floor(), fixed(0));

    // 0.1 -> 0.0
    let value = fixed(100_000_000);
    assert_eq!(value.floor(), fixed(0));
}

#[test]
fun floor_preserves_integer_values() {
    // 5.0 -> 5.0
    let value = fixed(5 * SCALE);
    assert_eq!(value.floor(), fixed(5 * SCALE));

    // 0.0 -> 0.0
    let zero = fixed(0);
    assert_eq!(zero.floor(), fixed(0));

    // 100.0 -> 100.0
    let value = fixed(100 * SCALE);
    assert_eq!(value.floor(), fixed(100 * SCALE));

    // 1.0 -> 1.0
    let value = fixed(SCALE);
    assert_eq!(value.floor(), fixed(SCALE));
}

#[test]
fun floor_handles_edge_cases() {
    // 0.000000001 -> 0.0
    let tiny = fixed(1);
    assert_eq!(tiny.floor(), fixed(0));

    // 1000000000.5 -> 1000000000.0
    let large = fixed(1_000_000_000 * SCALE + 500_000_000);
    assert_eq!(large.floor(), fixed(1_000_000_000 * SCALE));

    // 5.000000001 -> 5.0
    let almost = fixed(5 * SCALE + 1);
    assert_eq!(almost.floor(), fixed(5 * SCALE));
}

#[test]
fun floor_handles_max() {
    let max = ud30x9::max();
    let expected = MAX_VALUE - MAX_VALUE % SCALE;
    assert_eq!(max.floor(), fixed(expected));
}

#[test]
fun floor_of_zero() {
    assert_eq!(fixed(0).floor(), fixed(0));
}

#[test]
fun floor_of_just_above_integer() {
    // 1.000000001 -> 1.0
    assert_eq!(fixed(SCALE + 1).floor(), fixed(SCALE));
}

#[test]
fun floor_of_just_below_integer() {
    // 1.999999999 -> 1.0
    assert_eq!(fixed(2 * SCALE - 1).floor(), fixed(SCALE));
}

#[test]
fun floor_large_integer() {
    // 1000000.0 -> 1000000.0 (integer preserved)
    assert_eq!(fixed(1_000_000 * SCALE).floor(), fixed(1_000_000 * SCALE));
}

#[test]
fun floor_of_999999999() {
    // 0.999999999 -> 0.0
    assert!(fixed(999_999_999).floor().is_zero());
}

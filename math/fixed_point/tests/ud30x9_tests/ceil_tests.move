#[test_only]
module openzeppelin_fp_math::ud30x9_ceil_tests;

use openzeppelin_fp_math::ud30x9;
use openzeppelin_fp_math::ud30x9_base;
use openzeppelin_fp_math::ud30x9_test_helpers::fixed;
use std::unit_test::assert_eq;

const SCALE: u128 = 1_000_000_000;

#[test]
fun ceil_rounds_up_fractional_values() {
    // 5.3 -> 6.0
    let value = fixed(5 * SCALE + 300_000_000);
    assert_eq!(value.ceil(), fixed(6 * SCALE));

    // 5.9 -> 6.0
    let value = fixed(5 * SCALE + 900_000_000);
    assert_eq!(value.ceil(), fixed(6 * SCALE));

    // 1.1 -> 2.0
    let value = fixed(SCALE + 100_000_000);
    assert_eq!(value.ceil(), fixed(2 * SCALE));

    // 0.5 -> 1.0
    let value = fixed(500_000_000);
    assert_eq!(value.ceil(), fixed(SCALE));

    // 0.1 -> 1.0
    let value = fixed(100_000_000);
    assert_eq!(value.ceil(), fixed(SCALE));
}

#[test]
fun ceil_preserves_integer_values() {
    // 5.0 -> 5.0
    let value = fixed(5 * SCALE);
    assert_eq!(value.ceil(), fixed(5 * SCALE));

    // 0.0 -> 0.0
    let zero = fixed(0);
    assert_eq!(zero.ceil(), fixed(0));

    // 100.0 -> 100.0
    let value = fixed(100 * SCALE);
    assert_eq!(value.ceil(), fixed(100 * SCALE));

    // 1.0 -> 1.0
    let value = fixed(SCALE);
    assert_eq!(value.ceil(), fixed(SCALE));
}

#[test]
fun ceil_handles_edge_cases() {
    // 0.000000001 -> 1.0
    let tiny = fixed(1);
    assert_eq!(tiny.ceil(), fixed(SCALE));

    // 1000000000.5 -> 1000000001.0
    let large = fixed(1_000_000_000 * SCALE + 500_000_000);
    assert_eq!(large.ceil(), fixed(1_000_000_001 * SCALE));

    // 5.999999999 -> 6.0
    let almost = fixed(6 * SCALE - 1);
    assert_eq!(almost.ceil(), fixed(6 * SCALE));
}

#[test, expected_failure(abort_code = ud30x9_base::EOverflow)]
fun ceil_fails_for_max() {
    ud30x9::max().ceil();
}

#[test]
fun ceil_of_zero() {
    assert_eq!(fixed(0).ceil(), fixed(0));
}

#[test]
fun ceil_of_just_above_integer() {
    // 1.000000001 -> 2.0
    assert_eq!(fixed(SCALE + 1).ceil(), fixed(2 * SCALE));
}

#[test]
fun ceil_of_just_below_integer() {
    // 1.999999999 -> 2.0
    assert_eq!(fixed(2 * SCALE - 1).ceil(), fixed(2 * SCALE));
}

#[test]
fun ceil_large_integer() {
    // 1000000.0 -> 1000000.0 (integer preserved)
    assert_eq!(fixed(1_000_000 * SCALE).ceil(), fixed(1_000_000 * SCALE));
}

#[test]
fun ceil_of_999999999() {
    // 0.999999999 -> 1.0
    assert_eq!(fixed(999_999_999).ceil(), fixed(SCALE));
}

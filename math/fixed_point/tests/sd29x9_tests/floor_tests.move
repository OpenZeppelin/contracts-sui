#[test_only]
module openzeppelin_fp_math::sd29x9_floor_tests;

use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_base;
use openzeppelin_fp_math::sd29x9_test_helpers::{pos, neg, expect};

const MAX_POSITIVE_VALUE: u128 = 0x7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
const SCALE: u128 = 1_000_000_000;

#[test]
fun floor_truncates_positive_fractional_values() {
    // 5.3 -> 5.0
    expect(pos(5 * SCALE + 300_000_000).floor(), pos(5 * SCALE));
    // 5.9 -> 5.0
    expect(pos(5 * SCALE + 900_000_000).floor(), pos(5 * SCALE));
    // 1.1 -> 1.0
    expect(pos(SCALE + 100_000_000).floor(), pos(SCALE));
    // 0.5 -> 0.0
    expect(pos(500_000_000).floor(), sd29x9::zero());
    // 0.1 -> 0.0
    expect(pos(100_000_000).floor(), sd29x9::zero());
}

#[test]
fun floor_rounds_down_negative_fractional_values() {
    // -5.3 -> -6.0
    expect(neg(5 * SCALE + 300_000_000).floor(), neg(6 * SCALE));
    // -5.9 -> -6.0
    expect(neg(5 * SCALE + 900_000_000).floor(), neg(6 * SCALE));
    // -1.1 -> -2.0
    expect(neg(SCALE + 100_000_000).floor(), neg(2 * SCALE));
    // -0.5 -> -1.0
    expect(neg(500_000_000).floor(), neg(SCALE));
    // -0.1 -> -1.0
    expect(neg(100_000_000).floor(), neg(SCALE));
}

#[test]
fun floor_preserves_integer_values() {
    // 5.0 -> 5.0
    expect(pos(5 * SCALE).floor(), pos(5 * SCALE));
    // -5.0 -> -5.0
    expect(neg(5 * SCALE).floor(), neg(5 * SCALE));
    // 0.0 -> 0.0
    expect(sd29x9::zero().floor(), sd29x9::zero());
    // 100.0 -> 100.0
    expect(pos(100 * SCALE).floor(), pos(100 * SCALE));
}

#[test]
fun floor_handles_edge_cases() {
    // Very small positive fractional: 0.000000001 -> floor: 0.0
    expect(pos(1).floor(), sd29x9::zero());

    // Very small negative fractional: -0.000000001 -> floor: -1.0
    expect(neg(1).floor(), neg(SCALE));

    // Large value with fraction: 1000000000.5 -> floor: 1000000000.0
    expect(pos(1_000_000_000 * SCALE + 500_000_000).floor(), pos(1_000_000_000 * SCALE));
}

#[test]
fun floor_handles_max() {
    let max = sd29x9::max();
    let expected = MAX_POSITIVE_VALUE - MAX_POSITIVE_VALUE % SCALE;
    expect(max.floor(), pos(expected));
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun floor_fails_for_min() {
    sd29x9::min().floor();
}

#[test]
fun floor_of_zero() {
    expect(sd29x9::zero().floor(), sd29x9::zero());
}

#[test]
fun floor_of_positive_just_below_integer() {
    // 1.999999999 -> 1
    expect(pos(2 * SCALE - 1).floor(), pos(SCALE));
}

#[test]
fun floor_of_negative_just_below_integer() {
    // -1.000000001 -> -2
    expect(neg(SCALE + 1).floor(), neg(2 * SCALE));
}

#[test]
fun floor_of_exact_negative_integer() {
    expect(neg(3 * SCALE).floor(), neg(3 * SCALE));
}

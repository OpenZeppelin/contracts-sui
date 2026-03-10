#[test_only]
module openzeppelin_fp_math::sd29x9_abs_tests;

use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_base;
use openzeppelin_fp_math::sd29x9_test_helpers::{pos, neg, expect};

const MAX_POSITIVE_VALUE: u128 = 0x7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
const SCALE: u128 = 1_000_000_000;

#[test]
fun abs_preserves_positive_values() {
    // 5.0 -> 5.0
    expect(pos(5 * SCALE).abs(), pos(5 * SCALE));
    // 5.5 -> 5.5
    expect(pos(5 * SCALE + 500_000_000).abs(), pos(5 * SCALE + 500_000_000));
    // 0.1 -> 0.1
    expect(pos(100_000_000).abs(), pos(100_000_000));
}

#[test]
fun abs_converts_negative_to_positive() {
    // -5.0 -> 5.0
    expect(neg(5 * SCALE).abs(), pos(5 * SCALE));
    // -5.5 -> 5.5
    expect(neg(5 * SCALE + 500_000_000).abs(), pos(5 * SCALE + 500_000_000));
    // -0.1 -> 0.1
    expect(neg(100_000_000).abs(), pos(100_000_000));
    // -1.0 -> 1.0
    expect(neg(SCALE).abs(), pos(SCALE));
}

#[test]
fun abs_handles_zero() {
    // 0.0 -> 0.0
    expect(sd29x9::zero().abs(), sd29x9::zero());
}

#[test]
fun abs_handles_edge_cases() {
    // Very small positive: 0.000000001 -> 0.000000001
    expect(pos(1).abs(), pos(1));

    // Very small negative: -0.000000001 -> 0.000000001
    expect(neg(1).abs(), pos(1));

    // Large positive value: 1000000000.5 -> 1000000000.5
    expect(
        pos(1_000_000_000 * SCALE + 500_000_000).abs(),
        pos(1_000_000_000 * SCALE + 500_000_000),
    );

    // Large negative value: -1000000000.5 -> 1000000000.5
    expect(
        neg(1_000_000_000 * SCALE + 500_000_000).abs(),
        pos(1_000_000_000 * SCALE + 500_000_000),
    );

    // Max positive value remains unchanged
    expect(sd29x9::max().abs(), sd29x9::max());
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun abs_fails_for_min() {
    sd29x9::min().abs();
}

#[test]
fun abs_of_max_minus_one() {
    expect(pos(MAX_POSITIVE_VALUE - 1).abs(), pos(MAX_POSITIVE_VALUE - 1));
}

#[test]
fun abs_double_application() {
    // abs is idempotent on result
    expect(neg(42 * SCALE).abs().abs(), pos(42 * SCALE));
}

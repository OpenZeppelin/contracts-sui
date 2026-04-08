#[test_only]
module openzeppelin_fp_math::sd29x9_rem_tests;

use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_test_helpers::{pos, neg};
use std::unit_test::assert_eq;

const SCALE: u128 = 1_000_000_000;

#[test]
fun rem_tracks_dividend_sign() {
    assert_eq!(pos(100 * SCALE).rem(pos(15 * SCALE)), pos(10 * SCALE));
    assert_eq!(neg(100 * SCALE).rem(pos(15 * SCALE)), neg(10 * SCALE));
    assert_eq!(pos(42 * SCALE).rem(neg(21 * SCALE)), sd29x9::zero());
}

#[test, expected_failure(arithmetic_error, location = openzeppelin_fp_math::sd29x9_base)]
fun rem_with_zero_divisor_aborts() {
    pos(10).rem(sd29x9::zero());
}

#[test]
fun rem_positive_positive() {
    assert_eq!(pos(10 * SCALE).rem(pos(3 * SCALE)), pos(SCALE));
}

#[test]
fun rem_exact_division() {
    assert_eq!(pos(15 * SCALE).rem(pos(5 * SCALE)), sd29x9::zero());
}

#[test]
fun rem_dividend_equals_divisor() {
    assert_eq!(pos(7 * SCALE).rem(pos(7 * SCALE)), sd29x9::zero());
}

#[test]
fun rem_dividend_less_than_divisor() {
    assert_eq!(pos(3 * SCALE).rem(pos(10 * SCALE)), pos(3 * SCALE));
}

#[test]
fun rem_large_fractional() {
    assert_eq!(pos(100 * SCALE + 500_000_000).rem(pos(SCALE)), pos(500_000_000));
}

#[test]
fun rem_negative_negative() {
    assert_eq!(neg(13 * SCALE).rem(neg(5 * SCALE)), neg(3 * SCALE));
}

#[test]
fun rem_negative_divisor_keeps_positive_dividend_sign() {
    assert_eq!(pos(13 * SCALE).rem(neg(5 * SCALE)), pos(3 * SCALE));
}

#[test_only]
module openzeppelin_fp_math::sd29x9_mod_tests;

use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_base;
use openzeppelin_fp_math::sd29x9_test_helpers::{pos, neg};
use std::unit_test::assert_eq;

const SCALE: u128 = 1_000_000_000;

#[test]
fun mod_result_always_non_negative() {
    assert_eq!(pos(100 * SCALE).mod(pos(15 * SCALE)), pos(10 * SCALE));
    assert_eq!(neg(100 * SCALE).mod(pos(15 * SCALE)), pos(5 * SCALE));
    assert_eq!(pos(42 * SCALE).mod(neg(21 * SCALE)), sd29x9::zero());
}

#[test, expected_failure(abort_code = sd29x9_base::EDivisionByZero)]
fun mod_with_zero_modulus_aborts() {
    pos(10).mod(sd29x9::zero());
}

#[test]
fun mod_positive_positive() {
    assert_eq!(pos(10 * SCALE).mod(pos(3 * SCALE)), pos(SCALE));
}

#[test]
fun mod_negative_positive() {
    // rem(-10, 3) = -1, but mod(-10, 3) = 3 - 1 = 2
    assert_eq!(neg(10 * SCALE).mod(pos(3 * SCALE)), pos(2 * SCALE));
}

#[test]
fun mod_positive_negative() {
    assert_eq!(pos(10 * SCALE).mod(neg(3 * SCALE)), pos(SCALE));
}

#[test]
fun mod_negative_negative() {
    // rem(-10, -3) = -1, but mod(-10, -3) = 3 - 1 = 2
    assert_eq!(neg(10 * SCALE).mod(neg(3 * SCALE)), pos(2 * SCALE));
}

#[test]
fun mod_exact_division() {
    assert_eq!(pos(15 * SCALE).mod(pos(5 * SCALE)), sd29x9::zero());
    assert_eq!(neg(15 * SCALE).mod(pos(5 * SCALE)), sd29x9::zero());
    assert_eq!(pos(15 * SCALE).mod(neg(5 * SCALE)), sd29x9::zero());
    assert_eq!(neg(15 * SCALE).mod(neg(5 * SCALE)), sd29x9::zero());
}

#[test]
fun mod_dividend_equals_divisor() {
    assert_eq!(pos(7 * SCALE).mod(pos(7 * SCALE)), sd29x9::zero());
    assert_eq!(neg(7 * SCALE).mod(pos(7 * SCALE)), sd29x9::zero());
}

#[test]
fun mod_dividend_less_than_divisor() {
    assert_eq!(pos(3 * SCALE).mod(pos(10 * SCALE)), pos(3 * SCALE));
    // rem(-3, 10) = -3, but mod(-3, 10) = 10 - 3 = 7
    assert_eq!(neg(3 * SCALE).mod(pos(10 * SCALE)), pos(7 * SCALE));
}

#[test]
fun mod_large_fractional() {
    assert_eq!(pos(100 * SCALE + 500_000_000).mod(pos(SCALE)), pos(500_000_000));
    assert_eq!(neg(100 * SCALE + 500_000_000).mod(pos(SCALE)), pos(500_000_000));
}

#[test]
fun mod_zero_dividend() {
    assert_eq!(sd29x9::zero().mod(pos(5 * SCALE)), sd29x9::zero());
}

#[test]
fun mod_negative_large_values() {
    // rem(-13, 5) = -3, but mod(-13, 5) = 5 - 3 = 2
    assert_eq!(neg(13 * SCALE).mod(pos(5 * SCALE)), pos(2 * SCALE));
    assert_eq!(neg(13 * SCALE).mod(neg(5 * SCALE)), pos(2 * SCALE));
}

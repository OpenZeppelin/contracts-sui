#[test_only]
module openzeppelin_fp_math::sd29x9_mod_tests;

use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_test_helpers::{pos, neg, expect};

const SCALE: u128 = 1_000_000_000;

#[test]
fun mod_tracks_dividend_sign() {
    expect(pos(100 * SCALE).mod(pos(15 * SCALE)), pos(10 * SCALE));
    expect(neg(100 * SCALE).mod(pos(15 * SCALE)), neg(10 * SCALE));
    expect(pos(42 * SCALE).mod(neg(21 * SCALE)), sd29x9::zero());
}

#[test, expected_failure(arithmetic_error, location = openzeppelin_fp_math::sd29x9_base)]
fun mod_with_zero_modulus_aborts() {
    pos(10).mod(sd29x9::zero());
}

#[test]
fun mod_positive_positive() {
    expect(pos(10 * SCALE).mod(pos(3 * SCALE)), pos(SCALE));
}

#[test]
fun mod_exact_division() {
    expect(pos(15 * SCALE).mod(pos(5 * SCALE)), sd29x9::zero());
}

#[test]
fun mod_dividend_equals_divisor() {
    expect(pos(7 * SCALE).mod(pos(7 * SCALE)), sd29x9::zero());
}

#[test]
fun mod_dividend_less_than_divisor() {
    expect(pos(3 * SCALE).mod(pos(10 * SCALE)), pos(3 * SCALE));
}

#[test]
fun mod_large_fractional() {
    expect(
        pos(100 * SCALE + 500_000_000).mod(pos(SCALE)),
        pos(500_000_000),
    );
}

#[test]
fun mod_negative_negative() {
    expect(neg(13 * SCALE).mod(neg(5 * SCALE)), neg(3 * SCALE));
}

#[test]
fun mod_negative_divisor_keeps_positive_dividend_sign() {
    expect(pos(13 * SCALE).mod(neg(5 * SCALE)), pos(3 * SCALE));
}

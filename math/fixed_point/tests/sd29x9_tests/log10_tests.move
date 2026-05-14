#[test_only]
module openzeppelin_fp_math::sd29x9_log10_tests;

use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_base;
use openzeppelin_fp_math::sd29x9_test_helpers::{pos, neg};
use std::unit_test::assert_eq;

const SCALE: u128 = 1_000_000_000;

// === Exact value ===

#[test]
fun log10_of_one_is_zero() {
    assert_eq!(sd29x9::one().log10(), sd29x9::zero());
}

// === Powers of ten (within 1 ulp at UD30x9 scale) ===

#[test]
fun log10_of_positive_powers_of_ten_pins_values() {
    // log10(1) = 0 exactly.
    assert_eq!(pos(SCALE).log10(), pos(0));
    // For k >= 1, log10(10^k) = k exactly, but flooring the floored-constant
    // product at user scale lands the result 1 ulp below k * SCALE.
    let mut k: u8 = 1;
    while (k <= 11) {
        let x_raw = std::u128::pow(10, k) * SCALE;
        let expected = pos((k as u128) * SCALE - 1);
        assert_eq!(pos(x_raw).log10(), expected);
        k = k + 1;
    };
}

#[test]
fun log10_of_negative_powers_of_ten_pins_values() {
    // log10(10^-k) = -k exactly. The negative-branch kernel produces a high-
    // biased magnitude; combined with the floored `log10(2)` constant, the
    // user-scale floor lands at `k * SCALE` for small `k` and one ulp below
    // for larger `k`. Empirically:
    //   k = 1..=4: magnitude = k * SCALE
    //   k = 5..=9: magnitude = k * SCALE - 1
    let mut k: u8 = 1;
    while (k <= 9) {
        let x_raw = SCALE / std::u128::pow(10, k);
        let mag = (k as u128) * SCALE;
        let expected = neg(if (k <= 4) mag else mag - 1);
        assert_eq!(pos(x_raw).log10(), expected);
        k = k + 1;
    };
}

// === Spot checks ===

#[test]
fun log10_of_positive_two_matches_reference() {
    // log10(2) = 0.30102999566398... -> 301_029_995
    assert_eq!(pos(2 * SCALE).log10(), pos(301_029_995));
}

// === Aborts ===

#[test, expected_failure(abort_code = sd29x9_base::ELogUndefined)]
fun log10_of_zero_aborts() {
    sd29x9::zero().log10();
}

#[test, expected_failure(abort_code = sd29x9_base::ELogUndefined)]
fun log10_of_negative_aborts() {
    neg(SCALE).log10();
}

#[test, expected_failure(abort_code = sd29x9_base::ELogUndefined)]
fun log10_of_min_value_aborts() {
    sd29x9::min().log10();
}

// === Boundary at minimum positive input ===

#[test]
fun log10_of_pos_1_matches_reference() {
    // pos(1) represents 10^-9. log10(10^-9) = -9 exactly; flooring at user
    // scale lands the magnitude 1 ulp below 9 * SCALE.
    assert_eq!(pos(1).log10(), neg(9 * SCALE - 1));
}

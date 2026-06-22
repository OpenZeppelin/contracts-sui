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

// === Powers of ten (exact) ===

#[test]
fun log10_of_positive_powers_of_ten_is_exact() {
    assert_eq!(pos(SCALE).log10(), pos(0));
    let mut k: u8 = 1;
    while (k <= 11) {
        let x_raw = std::u128::pow(10, k) * SCALE;
        assert_eq!(pos(x_raw).log10(), pos((k as u128) * SCALE));
        k = k + 1;
    };
}

#[test]
fun log10_of_negative_powers_of_ten_is_exact() {
    let mut k: u8 = 1;
    while (k <= 9) {
        let x_raw = SCALE / std::u128::pow(10, k);
        assert_eq!(pos(x_raw).log10(), neg((k as u128) * SCALE));
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
    // pos(1) represents 10^-9.
    assert_eq!(pos(1).log10(), neg(9 * SCALE));
}

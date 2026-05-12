#[test_only]
module openzeppelin_fp_math::sd29x9_log10_tests;

use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_base;
use openzeppelin_fp_math::sd29x9_test_helpers::{pos, neg};
use std::unit_test::assert_eq;

const SCALE: u128 = 1_000_000_000;

// ==== Exact value ====

#[test]
fun log10_of_one_is_zero() {
    assert_eq!(sd29x9::one().log10(), sd29x9::zero());
}

// ==== Powers of ten (within 1 ulp at UD30x9 scale) ====

#[test]
fun log10_of_positive_powers_of_ten_is_within_one_ulp() {
    let mut k: u8 = 0;
    while (k <= 11) {
        let x_raw = std::u128::pow(10, k) * SCALE;
        let expected = pos((k as u128) * SCALE);
        let result = pos(x_raw).log10();
        let delta = result.sub(expected).abs().unwrap();
        assert!(delta <= 1);
        k = k + 1;
    };
}

#[test]
fun log10_of_negative_powers_of_ten_is_within_one_ulp() {
    // SCALE / 10^k for k = 1..=9 stays exact in UD30x9; for higher k the input
    // itself loses precision so we stop at k = 9.
    let mut k: u8 = 1;
    while (k <= 9) {
        let x_raw = SCALE / std::u128::pow(10, k);
        let expected = neg((k as u128) * SCALE);
        let result = pos(x_raw).log10();
        let delta = result.sub(expected).abs().unwrap();
        assert!(delta <= 1);
        k = k + 1;
    };
}

// ==== Spot checks ====

#[test]
fun log10_of_positive_two_matches_reference() {
    // log10(2) = 0.30102999566398... -> 301_029_995
    assert_eq!(pos(2 * SCALE).log10(), pos(301_029_995));
}

// ==== Aborts ====

#[test, expected_failure(abort_code = sd29x9_base::ELogUndefined)]
fun log10_of_zero_aborts() {
    sd29x9::zero().log10();
}

#[test, expected_failure(abort_code = sd29x9_base::ELogUndefined)]
fun log10_of_negative_aborts() {
    neg(SCALE).log10();
}

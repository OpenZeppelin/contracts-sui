#[test_only]
module openzeppelin_fp_math::ud30x9_log10_tests;

use openzeppelin_fp_math::ud30x9;
use openzeppelin_fp_math::ud30x9_base;
use openzeppelin_fp_math::ud30x9_test_helpers::fixed;
use std::unit_test::assert_eq;

const SCALE: u128 = 1_000_000_000;

// === Exact value ===

#[test]
fun log10_of_one_is_zero() {
    assert_eq!(ud30x9::one().log10(), ud30x9::zero());
}

// === Powers of 10 (exact) ===

#[test]
fun log10_of_powers_of_ten_is_exact() {
    assert_eq!(fixed(SCALE).log10(), fixed(0));
    let mut k: u8 = 1;
    while (k <= 11) {
        let x_raw = std::u128::pow(10, k) * SCALE;
        assert_eq!(fixed(x_raw).log10(), fixed((k as u128) * SCALE));
        k = k + 1;
    };
}

// === Spot checks ===

#[test]
fun log10_of_two_matches_reference() {
    // log10(2) = 0.30102999566398... -> 301_029_995
    assert_eq!(fixed(2 * SCALE).log10(), fixed(301_029_995));
}

// === Aborts ===

#[test, expected_failure(abort_code = ud30x9_base::ELogUndefined)]
fun log10_of_zero_aborts() {
    ud30x9::zero().log10();
}

#[test, expected_failure(abort_code = ud30x9_base::ELogUndefined)]
fun log10_of_sub_one_aborts() {
    fixed(SCALE - 1).log10();
}

// === Random property tests ===

#[random_test]
fun log10_monotonicity(a: u128, b: u128) {
    if (a < SCALE || b < SCALE) return;
    let (lo, hi) = if (a <= b) (a, b) else (b, a);
    assert!(fixed(lo).log10().lte(fixed(hi).log10()));
}

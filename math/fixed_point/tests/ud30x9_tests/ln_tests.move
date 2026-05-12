#[test_only]
module openzeppelin_fp_math::ud30x9_ln_tests;

use openzeppelin_fp_math::ud30x9;
use openzeppelin_fp_math::ud30x9_base;
use openzeppelin_fp_math::ud30x9_test_helpers::fixed;
use std::unit_test::assert_eq;

const SCALE: u128 = 1_000_000_000;

// e at UD30x9 scale: 2.71828182845904523536... -> floor at 10^9 = 2_718_281_828
const E_RAW: u128 = 2_718_281_828;
// log2(e) at 10^18 scale, rounded down: 1.44269504088896340735... * 10^18
// Used at high precision so its truncation error doesn't get amplified by ln(x).
const LOG2_E_HI: u256 = 1_442_695_040_888_963_407;
const INTERNAL: u256 = 1_000_000_000_000_000_000;

// ==== Exact value ====

#[test]
fun ln_of_one_is_zero() {
    assert_eq!(ud30x9::one().ln(), ud30x9::zero());
}

// ==== Spot checks ====

#[test]
fun ln_of_two_matches_reference() {
    // ln(2) = 0.6931471805599453... -> 693_147_180
    assert_eq!(fixed(2 * SCALE).ln(), fixed(693_147_180));
}

#[test]
fun ln_of_ten_matches_reference() {
    // ln(10) = 2.302585092994045... -> 2_302_585_092
    assert_eq!(fixed(10 * SCALE).ln(), fixed(2_302_585_092));
}

#[test]
fun ln_of_e_matches_reference() {
    // ln(E_RAW / SCALE) is just below 1 because E_RAW itself is rounded down;
    // the algorithm + round-down at user scale floors to SCALE - 1.
    assert_eq!(fixed(E_RAW).ln(), fixed(SCALE - 1));
}

// ==== Aborts ====

#[test, expected_failure(abort_code = ud30x9_base::ELogUndefined)]
fun ln_of_zero_aborts() {
    ud30x9::zero().ln();
}

#[test, expected_failure(abort_code = ud30x9_base::ELogUndefined)]
fun ln_of_sub_one_aborts() {
    fixed(SCALE - 1).ln();
}

// ==== Random property tests ====

#[random_test]
fun ln_monotonicity(a: u128, b: u128) {
    if (a < SCALE || b < SCALE) return;
    let (lo, hi) = if (a <= b) (a, b) else (b, a);
    assert!(fixed(lo).ln().lte(fixed(hi).ln()));
}

#[random_test]
fun ln_cross_base_log2(a: u128) {
    if (a < SCALE) return;
    let x = fixed(a);
    // ln(x) * log2(e) approximates log2(x). Using LOG2_E at 10^18 precision keeps
    // the constant's truncation error from being amplified by ln(x).
    let ln_x = x.ln().unwrap() as u256;
    let derived = ln_x * LOG2_E_HI / INTERNAL;
    let direct = x.log2().unwrap() as u256;
    let diff = if (derived >= direct) { derived - direct } else { direct - derived };
    // ln rounds down (1 ulp at UD30x9), multiplication amplifies by ~log2(e)=1.44,
    // division truncates once more. Worst case ~5 ulps.
    assert!(diff <= 5);
}

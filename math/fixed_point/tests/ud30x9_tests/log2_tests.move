#[test_only]
module openzeppelin_fp_math::ud30x9_log2_tests;

use openzeppelin_fp_math::ud30x9;
use openzeppelin_fp_math::ud30x9_base;
use openzeppelin_fp_math::ud30x9_test_helpers::fixed;
use std::unit_test::assert_eq;

const SCALE: u128 = 1_000_000_000;

// ==== Exact integer logs ====

#[test]
fun log2_of_one_is_zero() {
    assert_eq!(ud30x9::one().log2(), ud30x9::zero());
}

#[test]
fun log2_of_powers_of_two_is_exact() {
    let mut k: u8 = 0;
    while (k <= 37) {
        assert_eq!(fixed(SCALE << k).log2(), fixed((k as u128) * SCALE));
        k = k + 1;
    };
}

// ==== Spot checks against off-chain reference ====

#[test]
fun log2_of_three_matches_reference() {
    // log2(3) = 1.5849625007211561814... -> floor at 10^9 scale = 1_584_962_500
    assert_eq!(fixed(3 * SCALE).log2(), fixed(1_584_962_500));
}

#[test]
fun log2_of_ten_matches_reference() {
    // log2(10) = 3.3219280948873623478... -> floor at 10^9 scale = 3_321_928_094
    assert_eq!(fixed(10 * SCALE).log2(), fixed(3_321_928_094));
}

// ==== Aborts ====

#[test, expected_failure(abort_code = ud30x9_base::ELogUndefined)]
fun log2_of_zero_aborts() {
    ud30x9::zero().log2();
}

#[test, expected_failure(abort_code = ud30x9_base::ELogUndefined)]
fun log2_of_sub_one_aborts() {
    fixed(SCALE - 1).log2();
}

// ==== Extreme values ====

#[test]
fun log2_of_max_ud30x9() {
    // log2(u128::MAX / 10^9) ≈ 98.something; result should fit in [98·SCALE, 99·SCALE).
    let result = fixed(std::u128::max_value!()).log2().unwrap();
    assert!(result >= 98 * SCALE && result < 99 * SCALE);
}

// ==== Random property tests ====

#[random_test]
fun log2_monotonicity(a: u128, b: u128) {
    if (a < SCALE || b < SCALE) return;
    let (lo, hi) = if (a <= b) (a, b) else (b, a);
    assert!(fixed(lo).log2().lte(fixed(hi).log2()));
}

#[random_test]
fun log2_product_rule(a: u128, b: u128) {
    // Constrain x, y to [SCALE, 5e18) so that x*y stays within UD30x9.
    let span: u128 = 5_000_000_000_000_000_000 - SCALE;
    let x = fixed(SCALE + (a % span));
    let y = fixed(SCALE + (b % span));
    let xy = x.mul(y);

    let lhs = xy.log2().unwrap() as u256;
    let rhs = (x.log2().unwrap() as u256) + (y.log2().unwrap() as u256);
    let diff = if (lhs >= rhs) { lhs - rhs } else { rhs - lhs };
    // Error budget: 1 ulp from each log2 (2), plus ~1 ulp from mul truncation
    // (sensitivity in log space is bounded by `1/ln(2) ≈ 1.44`).
    assert!(diff <= 5);
}

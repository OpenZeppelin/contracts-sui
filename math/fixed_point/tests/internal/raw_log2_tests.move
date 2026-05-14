#[test_only]
module openzeppelin_fp_math::raw_log2_tests;

use openzeppelin_fp_math::common;
use std::unit_test::assert_eq;

const SCALE: u128 = 1_000_000_000;
const INTERNAL: u128 = 1_000_000_000_000_000_000;

// === Boundary ===

#[test]
fun raw_log2_of_one_is_zero() {
    let (neg, mag) = common::raw_log2(SCALE);
    assert!(!neg);
    assert_eq!(mag, 0);
}

// === Positive branch: exact integer logs ===

#[test]
fun raw_log2_of_positive_powers_of_two_is_exact() {
    let mut k: u8 = 0;
    while (k <= 37) {
        let x_raw = SCALE << k;
        let (neg, mag) = common::raw_log2(x_raw);
        assert!(!neg);
        assert_eq!(mag, (k as u128) * INTERNAL);
        k = k + 1;
    };
}

// === Negative branch: exact integer logs (k <= 9 because SCALE = 2^9 * 5^9) ===

#[test]
fun raw_log2_of_negative_powers_of_two_is_exact() {
    let mut k: u8 = 1;
    while (k <= 9) {
        let x_raw = SCALE >> k;
        let (neg, mag) = common::raw_log2(x_raw);
        assert!(neg);
        assert_eq!(mag, (k as u128) * INTERNAL);
        k = k + 1;
    };
}

// === Spot check against off-chain reference ===

#[test]
fun raw_log2_of_three_matches_reference() {
    // log2(3) = 1.5849625007211561814...
    // floor(log2(3) * 10^18) = 1_584_962_500_721_156_181
    let (neg, mag) = common::raw_log2(3 * SCALE);
    assert!(!neg);
    let reference: u128 = 1_584_962_500_721_156_181;
    let diff = if (mag >= reference) { mag - reference } else { reference - mag };
    // Allow ~1 ulp at user-facing 10^9 scale (= 10^9 ulps at 10^18). Empirically
    // the algorithm stays well under this; the bound asserts the error stays
    // below one UD30x9 ulp after downscaling.
    assert!(diff < 100_000);
}

#[test]
fun raw_log2_of_one_third_matches_reference_with_negation() {
    // x_raw = 333_333_333 represents the truncated decimal 0.333333333 (one
    // raw ulp below true 1/3). log2(0.333333333) = log2(1/3) + log2(0.999...9)
    // ≈ -1.5849625021638512. floor(|that| * 10^18) = 1_584_962_502_163_851_215.
    let (neg, mag) = common::raw_log2(333_333_333);
    assert!(neg);
    let reference: u128 = 1_584_962_502_163_851_215;
    let diff = if (mag >= reference) { mag - reference } else { reference - mag };
    assert!(diff < 100_000);
}

// === Asymmetric inputs near SCALE boundary ===

#[test]
fun raw_log2_just_below_one_is_negative() {
    // x_raw = SCALE - 1 ⇒ real value ≈ 0.999_999_999, log2 ≈ -1.443e-9
    let (neg, mag) = common::raw_log2(SCALE - 1);
    assert!(neg);
    // Magnitude should be very small (a few ulps at 10^9 scale = a few · 10^9 at 10^18)
    assert!(mag < 100_000_000_000);
}

#[test]
fun raw_log2_just_above_one_is_positive() {
    // x_raw = SCALE + 1 ⇒ real value ≈ 1.000_000_001, log2 ≈ 1.443e-9
    let (neg, mag) = common::raw_log2(SCALE + 1);
    assert!(!neg);
    assert!(mag < 100_000_000_000);
}

// === Abort ===

#[test, expected_failure(abort_code = common::ELogOfZero)]
fun raw_log2_of_zero_aborts() {
    common::raw_log2(0);
}

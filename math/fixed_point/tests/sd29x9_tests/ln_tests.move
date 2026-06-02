#[test_only]
module openzeppelin_fp_math::sd29x9_ln_tests;

use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_base;
use openzeppelin_fp_math::sd29x9_test_helpers::{pos, neg};
use std::unit_test::assert_eq;

const SCALE: u128 = 1_000_000_000;
// e at UD30x9 scale: 2.71828182845904523536... -> floor 2_718_281_828
const E_RAW: u128 = 2_718_281_828;

// === Exact value ===

#[test]
fun ln_of_one_is_zero() {
    assert_eq!(sd29x9::one().ln(), sd29x9::zero());
}

// === Spot checks ===

#[test]
fun ln_of_positive_two_matches_reference() {
    // ln(2) = 0.6931471805599453... -> 693_147_180
    assert_eq!(pos(2 * SCALE).ln(), pos(693_147_180));
}

#[test]
fun ln_of_positive_ten_matches_reference() {
    // ln(10) = 2.302585092994045... -> 2_302_585_092
    assert_eq!(pos(10 * SCALE).ln(), pos(2_302_585_092));
}

#[test]
fun ln_of_positive_e_matches_reference() {
    assert_eq!(pos(E_RAW).ln(), pos(SCALE - 1));
}

#[test]
fun ln_of_half_pins_value() {
    // ln(0.5) = -ln(2). raw_log2(SCALE/2) returns mag = 10^18 exactly (this is
    // an exact-power-of-2 input), so the final mul_div(10^18, ln2_e18, 10^27,
    // down) = 693_147_180 (truncating the remainder 559_945_309).
    let result = pos(SCALE / 2).ln();
    assert_eq!(result, neg(693_147_180));
}

// === Aborts ===

#[test, expected_failure(abort_code = sd29x9_base::ELogUndefined)]
fun ln_of_zero_aborts() {
    sd29x9::zero().ln();
}

#[test, expected_failure(abort_code = sd29x9_base::ELogUndefined)]
fun ln_of_negative_aborts() {
    neg(SCALE).ln();
}

#[test, expected_failure(abort_code = sd29x9_base::ELogUndefined)]
fun ln_of_min_value_aborts() {
    sd29x9::min().ln();
}

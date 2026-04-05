#[test_only]
module openzeppelin_fp_math::ud30x9_div_tests;

use openzeppelin_fp_math::ud30x9;
use openzeppelin_fp_math::ud30x9_base;
use openzeppelin_fp_math::ud30x9_test_helpers::fixed;
use std::unit_test::assert_eq;

const SCALE: u128 = 1_000_000_000;

// ==== Tests ====

#[test]
fun div_handles_zero_and_identity_cases() {
    let zero = fixed(0);
    let one = fixed(SCALE);
    let value = fixed(7 * SCALE + 500_000_000); // 7.5

    assert_eq!(zero.div(value), zero);
    assert_eq!(value.div(one), value);
}

#[test]
fun div_handles_exact_and_fractional_results() {
    // 7.5 / 2.5 = 3.0
    let numerator = fixed(7 * SCALE + 500_000_000);
    let denominator = fixed(2 * SCALE + 500_000_000);
    assert_eq!(numerator.div(denominator), fixed(3 * SCALE));

    // 1.0 / 3.0 = 0.333333333...
    assert_eq!(fixed(SCALE).div(fixed(3 * SCALE)), fixed(333_333_333));
}

#[test]
fun div_truncates_repeating_results() {
    // 2.000000001 / 2.0 = 1.0000000005 -> 1.000000000
    let numerator = fixed(2 * SCALE + 1);
    let denominator = fixed(2 * SCALE);
    assert_eq!(numerator.div(denominator), fixed(SCALE));
}

#[test]
fun div_trunc_and_away_variants_cover_inexact_and_exact_results() {
    let numerator = fixed(SCALE);
    let denominator = fixed(3 * SCALE);
    assert_eq!(numerator.div(denominator), numerator.div_trunc(denominator));
    assert_eq!(numerator.div_trunc(denominator), fixed(333_333_333));
    assert_eq!(numerator.div_away(denominator), fixed(333_333_334));

    let exact_numerator = fixed(7 * SCALE + 500_000_000);
    let exact_denominator = fixed(2 * SCALE + 500_000_000);
    let expected = fixed(3 * SCALE);
    assert_eq!(exact_numerator.div_trunc(exact_denominator), expected);
    assert_eq!(exact_numerator.div_away(exact_denominator), expected);
}

#[test]
fun div_trunc_and_away_handle_zero_identity_and_smallest_nonzero_quotients() {
    let zero = fixed(0);
    let one = fixed(SCALE);
    let value = fixed(7 * SCALE + 500_000_000);
    let ulp = fixed(1);
    let two = fixed(2 * SCALE);

    assert_eq!(zero.div_trunc(value), zero);
    assert_eq!(zero.div_away(value), zero);
    assert_eq!(value.div_trunc(one), value);
    assert_eq!(value.div_away(one), value);

    // 0.000000001 / 2.0 = 0.0000000005
    assert_eq!(ulp.div_trunc(two), zero);
    assert_eq!(ulp.div_away(two), ulp);
}

#[test]
fun div_handles_extreme_but_valid_inputs() {
    // max / max = 1.0
    assert_eq!(ud30x9::max().div(ud30x9::max()), fixed(SCALE));
}

#[test, expected_failure(arithmetic_error, location = openzeppelin_fp_math::ud30x9_base)]
fun div_by_zero_aborts() {
    fixed(10 * SCALE).div(fixed(0));
}

#[test, expected_failure(arithmetic_error, location = openzeppelin_fp_math::ud30x9_base)]
fun div_trunc_by_zero_aborts() {
    fixed(10 * SCALE).div_trunc(fixed(0));
}

#[test, expected_failure(arithmetic_error, location = openzeppelin_fp_math::ud30x9_base)]
fun div_away_by_zero_aborts() {
    fixed(10 * SCALE).div_away(fixed(0));
}

#[test, expected_failure(abort_code = ud30x9_base::EOverflow)]
fun div_result_overflow_aborts() {
    // max / 0.000000001 would exceed u128 when rescaled.
    ud30x9::max().div(fixed(1));
}

#[test, expected_failure(abort_code = ud30x9_base::EOverflow)]
fun div_away_result_overflow_aborts() {
    ud30x9::max().div_away(fixed(1));
}

#[test]
fun div_self_is_one() {
    let cases = vector[
        fixed(SCALE),
        fixed(2 * SCALE),
        fixed(7 * SCALE + 500_000_000),
        fixed(100 * SCALE),
    ];
    cases.destroy!(|x| {
        assert_eq!(x.div(x), fixed(SCALE));
    });
}

#[test]
fun div_large_by_small() {
    // 10.0 / 2.0 = 5.0
    assert_eq!(fixed(10 * SCALE).div(fixed(2 * SCALE)), fixed(5 * SCALE));
}

#[test]
fun div_small_by_large() {
    // 1.0 / 10.0 = 0.1
    assert_eq!(fixed(SCALE).div(fixed(10 * SCALE)), fixed(100_000_000));
}

#[test]
fun div_two_by_four() {
    // 2.0 / 4.0 = 0.5
    assert_eq!(fixed(2 * SCALE).div(fixed(4 * SCALE)), fixed(500_000_000));
}

#[test_only]
module openzeppelin_fp_math::ud30x9_div_tests;

use openzeppelin_fp_math::ud30x9;
use openzeppelin_fp_math::ud30x9_base;
use openzeppelin_fp_math::ud30x9_test_helpers::{fixed, expect};

const SCALE: u128 = 1_000_000_000;

// ==== Tests ====

#[test]
fun div_handles_zero_and_identity_cases() {
    let zero = fixed(0);
    let one = fixed(SCALE);
    let value = fixed(7 * SCALE + 500_000_000); // 7.5

    expect(zero.div(value), zero);
    expect(value.div(one), value);
}

#[test]
fun div_handles_exact_and_fractional_results() {
    // 7.5 / 2.5 = 3.0
    let numerator = fixed(7 * SCALE + 500_000_000);
    let denominator = fixed(2 * SCALE + 500_000_000);
    expect(numerator.div(denominator), fixed(3 * SCALE));

    // 1.0 / 3.0 = 0.333333333...
    expect(fixed(SCALE).div(fixed(3 * SCALE)), fixed(333_333_333));
}

#[test]
fun div_truncates_repeating_results() {
    // 2.000000001 / 2.0 = 1.0000000005 -> 1.000000000
    let numerator = fixed(2 * SCALE + 1);
    let denominator = fixed(2 * SCALE);
    expect(numerator.div(denominator), fixed(SCALE));
}

#[test]
fun div_handles_extreme_but_valid_inputs() {
    // max / max = 1.0
    expect(ud30x9::max().div(ud30x9::max()), fixed(SCALE));
}

#[test, expected_failure(abort_code = ud30x9_base::EDivideByZero)]
fun div_by_zero_aborts() {
    fixed(10 * SCALE).div(fixed(0));
}

#[test, expected_failure(abort_code = ud30x9_base::EOverflow)]
fun div_result_overflow_aborts() {
    // max / 0.000000001 would exceed u128 when rescaled.
    ud30x9::max().div(fixed(1));
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
        expect(x.div(x), fixed(SCALE));
    });
}

#[test]
fun div_large_by_small() {
    // 10.0 / 2.0 = 5.0
    expect(fixed(10 * SCALE).div(fixed(2 * SCALE)), fixed(5 * SCALE));
}

#[test]
fun div_small_by_large() {
    // 1.0 / 10.0 = 0.1
    expect(fixed(SCALE).div(fixed(10 * SCALE)), fixed(100_000_000));
}

#[test]
fun div_two_by_four() {
    // 2.0 / 4.0 = 0.5
    expect(fixed(2 * SCALE).div(fixed(4 * SCALE)), fixed(500_000_000));
}

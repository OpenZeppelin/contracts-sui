#[test_only]
module openzeppelin_fp_math::ud30x9_pow_tests;

use openzeppelin_fp_math::ud30x9;
use openzeppelin_fp_math::ud30x9_base;
use openzeppelin_fp_math::ud30x9_test_helpers::{fixed, expect, expect_ne};

const SCALE: u128 = 1_000_000_000;

// ==== Tests ====

#[test]
fun pow_handles_zero_and_one_exponents() {
    let x = fixed(12 * SCALE + 345_678_901);
    expect(x.pow(0), fixed(SCALE));
    expect(x.pow(1), x);
    expect(fixed(0).pow(0), fixed(SCALE));
}

#[test]
fun pow_handles_zero_and_one_bases() {
    expect(fixed(0).pow(5), fixed(0));
    expect(fixed(SCALE).pow(17), fixed(SCALE));
}

#[test]
fun pow_handles_fractional_values_and_truncation() {
    // 1.5^2 = 2.25, 1.5^3 = 3.375
    let one_point_five = fixed(1_500_000_000);
    expect(one_point_five.pow(2), fixed(2_250_000_000));
    expect(one_point_five.pow(3), fixed(3_375_000_000));

    // 1.000000001^2 = 1.000000002000000001 -> 1.000000002
    let epsilon = fixed(SCALE + 1);
    expect(epsilon.pow(2), fixed(SCALE + 2));
}

#[test]
fun pow_supports_high_exponents() {
    let val = fixed(SCALE + 250_000_000); // 1.25
    let pow255 = val.pow(255);
    expect(pow255, fixed(5_152_918_999_790_606_401_120_741_084_983_548));
    // with binary exponentiation, rounding/truncation behavior for larger exponents is affected by grouping
    expect_ne!(pow255, val.pow(254).mul(val));
}

#[test, expected_failure(abort_code = ud30x9_base::EOverflow)]
fun pow_overflow_aborts_for_large_base() {
    ud30x9::max().pow(2);
}

#[test, expected_failure(abort_code = ud30x9_base::EOverflow)]
fun pow_overflow_aborts_with_correct_abort_code() {
    ud30x9::max().pow(32);
}

#[test]
fun pow_two_squared() {
    // 2.0^2 = 4.0
    expect(fixed(2 * SCALE).pow(2), fixed(4 * SCALE));
}

#[test]
fun pow_three_cubed() {
    // 3.0^3 = 27.0
    expect(fixed(3 * SCALE).pow(3), fixed(27 * SCALE));
}

#[test]
fun pow_half_squared() {
    // 0.5^2 = 0.25
    expect(fixed(500_000_000).pow(2), fixed(250_000_000));
}

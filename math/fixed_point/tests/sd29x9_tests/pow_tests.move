#[test_only]
module openzeppelin_fp_math::sd29x9_pow_tests;

use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_base;
use openzeppelin_fp_math::sd29x9_test_helpers::{pos, neg};
use std::unit_test::assert_eq;

const SCALE: u128 = 1_000_000_000;

#[test]
fun pow_handles_zero_and_one_exponents() {
    let x = pos(12 * SCALE + 345_678_901);
    assert_eq!(x.pow(0), sd29x9::one());
    assert_eq!(x.pow(1), x);
    assert_eq!(sd29x9::zero().pow(0), sd29x9::one());
}

#[test]
fun pow_handles_zero_base_and_sign_parity() {
    let zero = sd29x9::zero();
    assert_eq!(zero.pow(5), zero);

    let neg_base = neg(2 * SCALE);
    assert_eq!(neg_base.pow(2), pos(4 * SCALE));
    assert_eq!(neg_base.pow(3), neg(8 * SCALE));
}

#[test]
fun pow_handles_fractional_values_and_truncation() {
    // 1.5^2 = 2.25, 1.5^3 = 3.375
    let one_point_five = pos(1_500_000_000);
    assert_eq!(one_point_five.pow(2), pos(2_250_000_000));
    assert_eq!(one_point_five.pow(3), pos(3_375_000_000));

    // 1.000000001^2 = 1.000000002000000001 -> 1.000000002
    let epsilon = pos(SCALE + 1);
    assert_eq!(epsilon.pow(2), pos(SCALE + 2));
}

#[test]
fun pow_handles_negative_one_parity() {
    let neg_one = neg(SCALE);
    assert_eq!(neg_one.pow(2), pos(SCALE));
    assert_eq!(neg_one.pow(3), neg(SCALE));
}

#[test]
fun pow_supports_high_exponents() {
    let val = pos(SCALE + 250_000_000); // 1.25
    // Expected value is the result of `sd29x9::pow`'s binary exponentiation with intermediate
    // truncation, not simply floor(1.25^16 * 10^9) (the exact value before flooring is ≈35_527_136_788.005)
    assert_eq!(val.pow(16), pos(35_527_136_781));

    let pow255 = val.pow(255);
    assert_eq!(pow255, pos(5_152_918_999_790_606_401_120_741_084_983_548));
    // with binary exponentiation, rounding/truncation behavior for larger exponents is affected by grouping
    assert!(pow255 != val.pow(254).mul(val));
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun pow_overflow_aborts_for_large_base() {
    sd29x9::max().pow(3);
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun pow_overflow_aborts_for_large_exponent() {
    let three = pos(3 * SCALE);
    three.pow(255);
}

#[test]
fun pow_two_squared() {
    assert_eq!(pos(2 * SCALE).pow(2), pos(4 * SCALE));
}

#[test]
fun pow_three_cubed() {
    assert_eq!(pos(3 * SCALE).pow(3), pos(27 * SCALE));
}

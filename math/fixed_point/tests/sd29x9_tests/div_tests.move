#[test_only]
module openzeppelin_fp_math::sd29x9_div_tests;

use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_base;
use openzeppelin_fp_math::sd29x9_test_helpers::{pos, neg};
use std::unit_test::assert_eq;

const SCALE: u128 = 1_000_000_000;

#[test]
fun div_handles_zero_sign_and_identity_cases() {
    let zero = sd29x9::zero();
    let one = pos(SCALE);
    let neg_one = neg(SCALE);
    let value = pos(7 * SCALE + 500_000_000); // 7.5

    assert_eq!(zero.div(value), zero);
    assert_eq!(value.div(one), value);
    assert_eq!(value.div(neg_one), value.negate());
}

#[test]
fun div_handles_signs_and_exact_fractional_results() {
    // 7.5 / 2.5 = 3.0
    let numerator = pos(7 * SCALE + 500_000_000);
    let denominator = pos(2 * SCALE + 500_000_000);
    assert_eq!(numerator.div(denominator), pos(3 * SCALE));
    assert_eq!(numerator.div(denominator.negate()), neg(3 * SCALE));
    assert_eq!(numerator.negate().div(denominator.negate()), pos(3 * SCALE));
}

#[test]
fun div_truncates_towards_zero() {
    // 1.0 / 3.0 = 0.333333333...
    assert_eq!(pos(SCALE).div(pos(3 * SCALE)), pos(333_333_333));
    assert_eq!(neg(SCALE).div(pos(3 * SCALE)), neg(333_333_333));
}

#[test]
fun div_trunc_and_away_variants_cover_signs_and_exactness() {
    let numerator = pos(SCALE);
    let denominator = pos(3 * SCALE);
    assert_eq!(numerator.div(denominator), numerator.div_trunc(denominator));
    assert_eq!(numerator.div_trunc(denominator), pos(333_333_333));
    assert_eq!(numerator.div_away(denominator), pos(333_333_334));
    assert_eq!(numerator.negate().div_trunc(denominator), neg(333_333_333));
    assert_eq!(numerator.negate().div_away(denominator), neg(333_333_334));

    let exact_numerator = pos(7 * SCALE + 500_000_000);
    let exact_denominator = pos(2 * SCALE + 500_000_000);
    let expected = pos(3 * SCALE);
    assert_eq!(exact_numerator.div_trunc(exact_denominator), expected);
    assert_eq!(exact_numerator.div_away(exact_denominator), expected);
}

#[test]
fun div_trunc_and_away_handle_zero_smallest_nonzero_and_sign_parity() {
    let zero = sd29x9::zero();
    let ulp = pos(1);
    let two = pos(2 * SCALE);
    let neg_one = neg(SCALE);

    assert_eq!(zero.div_trunc(neg_one), zero);
    assert_eq!(zero.div_away(neg_one), zero);

    // 0.000000001 / 2.0 = 0.0000000005
    assert_eq!(ulp.div_trunc(two), zero);
    assert_eq!(ulp.div_away(two), pos(1));
    assert_eq!(ulp.negate().div_trunc(two), zero);
    assert_eq!(ulp.negate().div_away(two), neg(1));
    assert_eq!(ulp.div_away(two.negate()), neg(1));
    assert_eq!(ulp.negate().div_away(two.negate()), pos(1));
}

#[test]
fun div_handles_min_over_one() {
    assert_eq!(sd29x9::min().div(pos(SCALE)), sd29x9::min());
}

#[test, expected_failure(abort_code = sd29x9_base::EDivisionByZero)]
fun div_by_zero_aborts() {
    pos(10 * SCALE).div(sd29x9::zero());
}

#[test, expected_failure(abort_code = sd29x9_base::EDivisionByZero)]
fun div_trunc_by_zero_aborts() {
    pos(10 * SCALE).div_trunc(sd29x9::zero());
}

#[test, expected_failure(abort_code = sd29x9_base::EDivisionByZero)]
fun div_away_by_zero_aborts() {
    pos(10 * SCALE).div_away(sd29x9::zero());
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun div_handles_min_div_negative_one() {
    sd29x9::min().div(neg(SCALE));
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun div_away_handles_min_div_negative_one() {
    sd29x9::min().div_away(neg(SCALE));
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun div_away_overflow_aborts_for_large_positive_result() {
    sd29x9::max().div_away(pos(1));
}

#[test]
fun div_self_is_one() {
    let one = sd29x9::one();
    let values = vector[
        pos(SCALE),
        pos(5 * SCALE),
        pos(42 * SCALE + 123_456_789),
        pos(1_000_000_000_000),
    ];
    values.destroy!(|x| {
        assert_eq!(x.div(x), one);
    });
}

#[test]
fun div_positive_fractions() {
    // 5 / 2 = 2.5
    assert_eq!(pos(5 * SCALE).div(pos(2 * SCALE)), pos(2 * SCALE + 500_000_000));
}

#[test]
fun div_small_by_large() {
    // 1 / 10 = 0.1
    assert_eq!(pos(SCALE).div(pos(10 * SCALE)), pos(100_000_000));
}

#[test]
fun div_sign_parity() {
    // 6 / 2 = 3, all four sign combinations
    let six = pos(6 * SCALE);
    let two = pos(2 * SCALE);
    let three = pos(3 * SCALE);

    assert_eq!(six.div(two), three);
    assert_eq!(six.negate().div(two), three.negate());
    assert_eq!(six.div(two.negate()), three.negate());
    assert_eq!(six.negate().div(two.negate()), three);
}

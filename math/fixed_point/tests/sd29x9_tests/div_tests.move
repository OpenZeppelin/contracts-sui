#[test_only]
module openzeppelin_fp_math::sd29x9_div_tests;

use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_base;
use openzeppelin_fp_math::sd29x9_test_helpers::{pos, neg, expect};

const SCALE: u128 = 1_000_000_000;

#[test]
fun div_handles_zero_sign_and_identity_cases() {
    let zero = sd29x9::zero();
    let one = pos(SCALE);
    let neg_one = neg(SCALE);
    let value = pos(7 * SCALE + 500_000_000); // 7.5

    expect(zero.div(value), zero);
    expect(value.div(one), value);
    expect(value.div(neg_one), value.negate());
}

#[test]
fun div_handles_signs_and_exact_fractional_results() {
    // 7.5 / 2.5 = 3.0
    let numerator = pos(7 * SCALE + 500_000_000);
    let denominator = pos(2 * SCALE + 500_000_000);
    expect(numerator.div(denominator), pos(3 * SCALE));
    expect(numerator.div(denominator.negate()), neg(3 * SCALE));
    expect(numerator.negate().div(denominator.negate()), pos(3 * SCALE));
}

#[test]
fun div_truncates_towards_zero() {
    // 1.0 / 3.0 = 0.333333333...
    expect(pos(SCALE).div(pos(3 * SCALE)), pos(333_333_333));
    expect(neg(SCALE).div(pos(3 * SCALE)), neg(333_333_333));
}

#[test]
fun div_handles_min_over_one() {
    expect(sd29x9::min().div(pos(SCALE)), sd29x9::min());
}

#[test, expected_failure(arithmetic_error, location = openzeppelin_fp_math::sd29x9_base)]
fun div_by_zero_aborts() {
    pos(10 * SCALE).div(sd29x9::zero());
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun div_handles_min_div_negative_one() {
    sd29x9::min().div(neg(SCALE));
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
        expect(x.div(x), one);
    });
}

#[test]
fun div_positive_fractions() {
    // 5 / 2 = 2.5
    expect(
        pos(5 * SCALE).div(pos(2 * SCALE)),
        pos(2 * SCALE + 500_000_000),
    );
}

#[test]
fun div_small_by_large() {
    // 1 / 10 = 0.1
    expect(pos(SCALE).div(pos(10 * SCALE)), pos(100_000_000));
}

#[test]
fun div_sign_parity() {
    // 6 / 2 = 3, all four sign combinations
    let six = pos(6 * SCALE);
    let two = pos(2 * SCALE);
    let three = pos(3 * SCALE);

    expect(six.div(two), three);
    expect(six.negate().div(two), three.negate());
    expect(six.div(two.negate()), three.negate());
    expect(six.negate().div(two.negate()), three);
}

#[test_only]
module openzeppelin_fp_math::sd29x9_mul_tests;

use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_base;
use openzeppelin_fp_math::sd29x9_test_helpers::{pos, neg, pair, unpack};
use std::unit_test::assert_eq;

const MAX_POSITIVE_VALUE: u128 = 0x7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
const MIN_NEGATIVE_VALUE: u128 = 0x8000_0000_0000_0000_0000_0000_0000_0000;
const SCALE: u128 = 1_000_000_000;

#[test]
fun mul_handles_multiplication_by_zero() {
    let zero = sd29x9::zero();
    let values = vector[
        sd29x9::zero(),
        sd29x9::one(),
        sd29x9::one().negate(),
        pos(5 * SCALE + 250_000_000),
        neg(5 * SCALE + 250_000_000),
        pos(500_000_000_000_000_000),
        neg(500_000_000_000_000_000),
        sd29x9::max(),
        sd29x9::min(),
    ];
    values.destroy!(|val| {
        assert_eq!(val.mul(zero), zero);
        assert_eq!(zero.mul(val), zero);
    });
}

#[test]
fun mul_handles_multiplication_by_one() {
    let one = sd29x9::one();
    let values = vector[
        sd29x9::zero(),
        sd29x9::one(),
        sd29x9::one().negate(),
        pos(5 * SCALE + 250_000_000),
        neg(5 * SCALE + 250_000_000),
        pos(500_000_000_000_000_000),
        neg(500_000_000_000_000_000),
    ];
    values.destroy!(|val| {
        assert_eq!(val.mul(one), val);
        assert_eq!(one.mul(val), val);
    });
}

#[test]
fun mul_handles_multiplication_by_minus_one() {
    let minus_one = sd29x9::one().negate();
    let values = vector[
        sd29x9::zero(),
        sd29x9::one(),
        sd29x9::one().negate(),
        pos(5 * SCALE + 250_000_000),
        neg(5 * SCALE + 250_000_000),
        pos(500_000_000_000_000_000),
        neg(500_000_000_000_000_000),
    ];
    values.destroy!(|val| {
        assert_eq!(val.mul(minus_one), val.negate());
        assert_eq!(minus_one.mul(val), val.negate());
    });
}

#[test]
fun mul_handles_signs_for_integers() {
    let two = pos(2 * SCALE);
    let three = pos(3 * SCALE);
    let six = pos(6 * SCALE);
    let minus_two = two.negate();
    let minus_three = three.negate();
    let minus_six = six.negate();

    // 1. Both positive
    assert_eq!(two.mul(three), six);

    // 2. Left positive, right negative
    assert_eq!(two.mul(minus_three), minus_six);

    // 3. Left negative, right positive
    assert_eq!(minus_two.mul(three), minus_six);

    // 4. Both negative
    assert_eq!(minus_two.mul(minus_three), six);
}

#[test]
fun mul_handles_signs_for_fractional() {
    // 1.5 * 2.25 = 3.375
    let left = pos(1_500_000_000);
    let right = pos(2_250_000_000);
    let expected = pos(3_375_000_000);

    // 1. Both positive
    assert_eq!(left.mul(right), expected);

    // 2. Left positive, right negative
    assert_eq!(left.mul(right.negate()), expected.negate());

    // 3. Left negative, right positive
    assert_eq!(left.negate().mul(right), expected.negate());

    // 4. Both negative
    assert_eq!(left.negate().mul(right.negate()), expected);
}

#[test]
fun mul_truncates_towards_zero_at_scale_boundary() {
    // 1.000000001 * 1.000000001 = 1.000000002000000001 -> 1.000000002
    let x = pos(SCALE + 1);
    assert_eq!(x.mul(x), pos(SCALE + 2));

    // 1.000000001 * 1.000000002 = 1.000000003000000002 -> 1.000000003
    assert_eq!(pos(SCALE + 1).mul(pos(SCALE + 2)), pos(SCALE + 3));

    // 0.999999999 * 0.999999999 = 0.999999998000000001 -> 0.999999998
    let almost_one = pos(SCALE - 1);
    assert_eq!(almost_one.mul(almost_one), pos(SCALE - 2));

    // Sign checks near the truncation boundary
    assert_eq!(x.negate().mul(x), neg(SCALE + 2));
    assert_eq!(x.negate().mul(x.negate()), pos(SCALE + 2));
}

#[test]
fun mul_trunc_and_away_variants_cover_signs_and_exactness() {
    let x = pos(SCALE + 1);
    let y = pos(SCALE + 1);
    assert_eq!(x.mul(y), x.mul_trunc(y));
    assert_eq!(x.mul_trunc(y), pos(SCALE + 2));
    assert_eq!(x.mul_away(y), pos(SCALE + 3));
    assert_eq!(x.negate().mul_trunc(y), neg(SCALE + 2));
    assert_eq!(x.negate().mul_away(y), neg(SCALE + 3));

    let left = pos(1_500_000_000);
    let right = pos(2_250_000_000);
    let expected = pos(3_375_000_000);
    assert_eq!(left.mul_trunc(right), expected);
    assert_eq!(left.mul_away(right), expected);
}

#[test]
fun mul_trunc_and_away_handle_zero_and_smallest_nonzero_products() {
    let zero = sd29x9::zero();
    let ulp = pos(1);
    let neg_one = neg(SCALE);

    assert_eq!(zero.mul_trunc(neg_one), zero);
    assert_eq!(zero.mul_away(neg_one), zero);

    // 0.000000001 * 0.000000001 = 0.000000000000000001
    assert_eq!(ulp.mul_trunc(ulp), zero);
    assert_eq!(ulp.mul_away(ulp), pos(1));
    assert_eq!(ulp.negate().mul_trunc(ulp), zero);
    assert_eq!(ulp.negate().mul_away(ulp), neg(1));
    assert_eq!(ulp.negate().mul_away(ulp.negate()), pos(1));
}

#[test]
fun mul_handles_difficult_fractional_magnitudes() {
    // (999999999.999999999)^2 = 999999999999999998.000000000000000001
    let value = pos(999_999_999_999_999_999);
    let expected_square = pos(999_999_999_999_999_998_000_000_000);
    assert_eq!(value.mul(value), pos(999_999_999_999_999_998_000_000_000));
    assert_eq!(value.negate().mul(value), expected_square.negate());
    assert_eq!(value.mul(value.negate()), expected_square.negate());
    assert_eq!(value.negate().mul(value.negate()), expected_square);

    // 123456789.123456789 * 987654321.987654321
    let left = pos(123_456_789_123_456_789);
    let right = pos(987_654_321_987_654_321);
    let expected_product = pos(121_932_631_356_500_531_347_203_169);
    assert_eq!(left.mul(right), expected_product);
    assert_eq!(left.negate().mul(right), expected_product.negate());
    assert_eq!(left.mul(right.negate()), expected_product.negate());
    assert_eq!(left.negate().mul(right.negate()), expected_product);
}

#[test]
fun mul_large_intermediate_product_does_not_overflow() {
    // These products exceed u128 before scaling down, so this checks that
    // multiplication uses a wider intermediate and only then divides by SCALE
    let half = pos(SCALE / 2); // 0.5
    let max = sd29x9::max();
    let min = sd29x9::min();

    assert_eq!(max.mul(half), pos(MAX_POSITIVE_VALUE / 2));
    assert_eq!(half.mul(max), pos(MAX_POSITIVE_VALUE / 2));

    assert_eq!(min.mul(half), neg(MIN_NEGATIVE_VALUE / 2));
    assert_eq!(half.mul(min), neg(MIN_NEGATIVE_VALUE / 2));
}

#[test]
fun mul_handles_min_times_one() {
    let min = sd29x9::min();
    let one = sd29x9::one();
    assert_eq!(min.mul(one), min);
}

#[test]
fun mul_handles_max_times_one() {
    let max = sd29x9::max();
    let one = sd29x9::one();
    assert_eq!(max.mul(one), max);
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun mul_overflow_aborts_for_min_times_negative_one() {
    sd29x9::min().mul(neg(SCALE));
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun mul_away_overflow_aborts_for_min_times_negative_one() {
    sd29x9::min().mul_away(neg(SCALE));
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun mul_overflow_aborts_for_large_positive_result() {
    sd29x9::max().mul(pos(SCALE + 1));
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun mul_overflow_aborts_for_large_negative_result() {
    sd29x9::min().mul(pos(SCALE + 1));
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun mul_away_overflow_aborts_for_large_negative_result() {
    sd29x9::min().mul_away(pos(SCALE + 1));
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun mul_away_overflow_aborts_for_large_positive_result() {
    sd29x9::max().mul_away(pos(SCALE + 1));
}

#[test]
fun mul_commutativity() {
    let pairs = vector[
        pair(pos(2 * SCALE), pos(3 * SCALE)),
        pair(neg(5 * SCALE), pos(7 * SCALE)),
        pair(neg(4 * SCALE), neg(6 * SCALE)),
        pair(pos(1_500_000_000), pos(2_250_000_000)),
    ];
    pairs.destroy!(|p| {
        let (a, b) = p.unpack();
        assert_eq!(a.mul(b).unwrap(), b.mul(a).unwrap());
    });
}

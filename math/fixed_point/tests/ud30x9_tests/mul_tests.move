#[test_only]
module openzeppelin_fp_math::ud30x9_mul_tests;

use openzeppelin_fp_math::ud30x9;
use openzeppelin_fp_math::ud30x9_base;
use openzeppelin_fp_math::ud30x9_test_helpers::{fixed, pair, unpack};
use std::unit_test::assert_eq;

const MAX_VALUE: u128 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
const SCALE: u128 = 1_000_000_000;

#[test]
fun mul_handles_multiplication_by_zero() {
    let zero = fixed(0);
    let values = vector[
        fixed(0),
        fixed(SCALE),
        fixed(5 * SCALE + 250_000_000),
        fixed(500_000_000_000_000_000),
        ud30x9::max(),
    ];

    values.destroy!(|val| {
        assert_eq!(val.mul(zero), zero);
        assert_eq!(zero.mul(val), zero);
    });
}

#[test]
fun mul_handles_multiplication_by_one() {
    let one = fixed(SCALE);
    let values = vector[
        fixed(0),
        fixed(SCALE),
        fixed(5 * SCALE + 250_000_000),
        fixed(500_000_000_000_000_000),
    ];

    values.destroy!(|val| {
        assert_eq!(val.mul(one), val);
        assert_eq!(one.mul(val), val);
    });
}

#[test]
fun mul_handles_exact_and_fractional_products() {
    // 1.5 * 2.25 = 3.375
    let a = fixed(1_500_000_000);
    let b = fixed(2_250_000_000);
    assert_eq!(a.mul(b), fixed(3_375_000_000));

    // 2.0 * 3.0 = 6.0
    assert_eq!(fixed(2 * SCALE).mul(fixed(3 * SCALE)), fixed(6 * SCALE));
}

#[test]
fun mul_truncates_towards_zero_at_scale_boundary() {
    // 1.000000001 * 1.000000001 = 1.000000002000000001 -> 1.000000002
    let x = fixed(SCALE + 1);
    assert_eq!(x.mul(x), fixed(SCALE + 2));

    // 1.000000001 * 1.000000002 = 1.000000003000000002 -> 1.000000003
    assert_eq!(fixed(SCALE + 1).mul(fixed(SCALE + 2)), fixed(SCALE + 3));

    // 0.999999999 * 0.999999999 = 0.999999998000000001 -> 0.999999998
    let almost_one = fixed(SCALE - 1);
    assert_eq!(almost_one.mul(almost_one), fixed(SCALE - 2));
}

#[test]
fun mul_trunc_and_away_variants_cover_inexact_and_exact_products() {
    let x = fixed(SCALE + 1);
    let y = fixed(SCALE + 1);
    assert_eq!(x.mul(y), x.mul_trunc(y));
    assert_eq!(x.mul_trunc(y), fixed(SCALE + 2));
    assert_eq!(x.mul_away(y), fixed(SCALE + 3));

    let left = fixed(1_500_000_000);
    let right = fixed(2_250_000_000);
    let expected = fixed(3_375_000_000);
    assert_eq!(left.mul_trunc(right), expected);
    assert_eq!(left.mul_away(right), expected);
}

#[test]
fun mul_trunc_and_away_handle_zero_identity_and_smallest_nonzero_products() {
    let zero = fixed(0);
    let one = fixed(SCALE);
    let value = fixed(5 * SCALE + 250_000_000);
    let ulp = fixed(1);

    assert_eq!(zero.mul_trunc(value), zero);
    assert_eq!(zero.mul_away(value), zero);
    assert_eq!(value.mul_trunc(one), value);
    assert_eq!(value.mul_away(one), value);

    // 0.000000001 * 0.000000001 = 0.000000000000000001
    assert_eq!(ulp.mul_trunc(ulp), zero);
    assert_eq!(ulp.mul_away(ulp), ulp);
}

#[test]
fun mul_handles_difficult_fractional_magnitudes() {
    // (999999999.999999999)^2 = 999999999999999998.000000000000000001
    let value = fixed(999_999_999_999_999_999);
    assert_eq!(value.mul(value), fixed(999_999_999_999_999_998_000_000_000));

    // 123456789.123456789 * 987654321.987654321
    let left = fixed(123_456_789_123_456_789);
    let right = fixed(987_654_321_987_654_321);
    assert_eq!(left.mul(right), fixed(121_932_631_356_500_531_347_203_169));
}

#[test]
fun mul_large_intermediate_product_does_not_overflow() {
    // This product exceeds u128 before scaling down, so this checks that
    // multiplication uses a wider intermediate and only then divides by SCALE.
    let half = fixed(SCALE / 2); // 0.5
    let max = ud30x9::max();
    assert_eq!(max.mul(half), fixed(MAX_VALUE / 2));
    assert_eq!(half.mul(max), fixed(MAX_VALUE / 2));
}

#[test]
fun mul_handles_max_times_one() {
    let max = ud30x9::max();
    let one = fixed(SCALE);
    assert_eq!(max.mul(one), max);
}

#[test, expected_failure(abort_code = ud30x9_base::EOverflow)]
fun mul_overflow_aborts_for_large_result() {
    ud30x9::max().mul(fixed(SCALE + 1));
}

#[test, expected_failure(abort_code = ud30x9_base::EOverflow)]
fun mul_away_overflow_aborts_for_large_result() {
    ud30x9::max().mul_away(fixed(SCALE + 1));
}

#[test]
fun mul_commutativity() {
    let pairs = vector[
        pair(fixed(2 * SCALE), fixed(3 * SCALE)),
        pair(fixed(1_500_000_000), fixed(2_250_000_000)),
        pair(fixed(SCALE / 2), fixed(SCALE * 4)),
    ];
    pairs.destroy!(|p| {
        let (a, b) = p.unpack();
        assert_eq!(a.mul(b).unwrap(), b.mul(a).unwrap());
    });
}

#[test]
fun mul_fractional_small() {
    // 0.5 * 0.5 = 0.25
    assert_eq!(fixed(500_000_000).mul(fixed(500_000_000)), fixed(250_000_000));
}

#[test_only]
module openzeppelin_fp_math::ud30x9_mul_tests;

use openzeppelin_fp_math::ud30x9;
use openzeppelin_fp_math::ud30x9_base;
use openzeppelin_fp_math::ud30x9_test_helpers::{fixed, expect, pair, unpack};
use std::unit_test::assert_eq;

const MAX_VALUE: u128 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
const SCALE: u128 = 1_000_000_000;

// ==== Tests ====

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
        expect(val.mul(zero), zero);
        expect(zero.mul(val), zero);
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
        expect(val.mul(one), val);
        expect(one.mul(val), val);
    });
}

#[test]
fun mul_handles_exact_and_fractional_products() {
    // 1.5 * 2.25 = 3.375
    let a = fixed(1_500_000_000);
    let b = fixed(2_250_000_000);
    expect(a.mul(b), fixed(3_375_000_000));

    // 2.0 * 3.0 = 6.0
    expect(fixed(2 * SCALE).mul(fixed(3 * SCALE)), fixed(6 * SCALE));
}

#[test]
fun mul_truncates_towards_zero_at_scale_boundary() {
    // 1.000000001 * 1.000000001 = 1.000000002000000001 -> 1.000000002
    let x = fixed(SCALE + 1);
    expect(x.mul(x), fixed(SCALE + 2));

    // 1.000000001 * 1.000000002 = 1.000000003000000002 -> 1.000000003
    expect(fixed(SCALE + 1).mul(fixed(SCALE + 2)), fixed(SCALE + 3));

    // 0.999999999 * 0.999999999 = 0.999999998000000001 -> 0.999999998
    let almost_one = fixed(SCALE - 1);
    expect(almost_one.mul(almost_one), fixed(SCALE - 2));
}

#[test]
fun mul_handles_difficult_fractional_magnitudes() {
    // (999999999.999999999)^2 = 999999999999999998.000000000000000001
    let value = fixed(999_999_999_999_999_999);
    expect(value.mul(value), fixed(999_999_999_999_999_998_000_000_000));

    // 123456789.123456789 * 987654321.987654321
    let left = fixed(123_456_789_123_456_789);
    let right = fixed(987_654_321_987_654_321);
    expect(left.mul(right), fixed(121_932_631_356_500_531_347_203_169));
}

#[test]
fun mul_large_intermediate_product_does_not_overflow() {
    // This product exceeds u128 before scaling down, so this checks that
    // multiplication uses a wider intermediate and only then divides by SCALE.
    let half = fixed(SCALE / 2); // 0.5
    let max = ud30x9::max();
    expect(max.mul(half), fixed(MAX_VALUE / 2));
    expect(half.mul(max), fixed(MAX_VALUE / 2));
}

#[test]
fun mul_handles_max_times_one() {
    let max = ud30x9::max();
    let one = fixed(SCALE);
    expect(max.mul(one), max);
}

#[test, expected_failure(abort_code = ud30x9_base::EOverflow)]
fun mul_overflow_aborts_for_large_result() {
    ud30x9::max().mul(fixed(SCALE + 1));
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
    expect(fixed(500_000_000).mul(fixed(500_000_000)), fixed(250_000_000));
}

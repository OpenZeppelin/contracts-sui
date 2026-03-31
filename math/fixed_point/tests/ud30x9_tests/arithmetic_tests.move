#[test_only]
module openzeppelin_fp_math::ud30x9_arithmetic_tests;

use openzeppelin_fp_math::ud30x9_base;
use openzeppelin_fp_math::ud30x9_test_helpers::{fixed, expect, pair, unpack};
use std::unit_test::assert_eq;

const MAX_VALUE: u128 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
const SCALE: u128 = 1_000_000_000;

#[test]
fun checked_arithmetic_matches_integers() {
    let left = fixed(1_000 * SCALE);
    let right = fixed(600 * SCALE);

    let sum = left.add(right);
    assert_eq!(sum.unwrap(), 1_600 * SCALE);

    let diff = left.sub(right);
    assert_eq!(diff.unwrap(), 400 * SCALE);

    let remainder = left.mod(right);
    assert_eq!(remainder.unwrap(), 400 * SCALE);
}

#[test, expected_failure(abort_code = ud30x9_base::EOverflow)]
fun checked_add_overflow_aborts_as_expected() {
    fixed(MAX_VALUE).add(fixed(1));
}

#[test, expected_failure(abort_code = ud30x9_base::EOverflow)]
fun checked_sub_underflow_aborts_as_expected() {
    fixed(0).sub(fixed(1));
}

#[test, expected_failure(arithmetic_error, location = openzeppelin_fp_math::ud30x9_base)]
fun modulo_with_zero_divisor_aborts() {
    fixed(10).mod(fixed(0));
}

#[test]
fun modulo_and_zero_helpers_match_u128() {
    let dividend = fixed(100 * SCALE);
    let divisor = fixed(25 * SCALE);
    assert_eq!(dividend.mod(divisor).unwrap(), 0);

    let odd_dividend = fixed(101 * SCALE);
    let remainder = odd_dividend.mod(divisor);
    assert_eq!(remainder.unwrap(), SCALE);

    assert!(!dividend.is_zero());
}

#[test]
fun add_zero_is_identity() {
    let zero = fixed(0);
    let cases = vector[
        fixed(SCALE),
        fixed(42 * SCALE),
        fixed(123 * SCALE + 456_000_000),
        fixed(1_000_000 * SCALE),
    ];
    cases.destroy!(|x| {
        expect(x.add(zero), x);
        expect(zero.add(x), x);
    });
}

#[test]
fun sub_self_is_zero() {
    let cases = vector[
        fixed(SCALE),
        fixed(42 * SCALE),
        fixed(123 * SCALE + 456_000_000),
        fixed(1_000_000 * SCALE),
    ];
    cases.destroy!(|x| {
        assert!(x.sub(x).is_zero());
    });
}

#[test]
fun add_commutativity() {
    let pairs = vector[
        pair(fixed(100 * SCALE), fixed(200 * SCALE)),
        pair(fixed(SCALE), fixed(2 * SCALE)),
        pair(fixed(123 * SCALE + 456_000_000), fixed(7 * SCALE + 890_000_000)),
    ];
    pairs.destroy!(|p| {
        let (a, b) = p.unpack();
        assert_eq!(a.add(b).unwrap(), b.add(a).unwrap());
    });
}

#[test]
fun mod_exact_division() {
    assert!(fixed(100 * SCALE).mod(fixed(25 * SCALE)).is_zero());
}

#[test]
fun mod_various() {
    assert_eq!(fixed(17 * SCALE).mod(fixed(5 * SCALE)).unwrap(), 2 * SCALE);
    assert_eq!(fixed(10 * SCALE).mod(fixed(3 * SCALE)).unwrap(), SCALE);
    assert!(fixed(7 * SCALE).mod(fixed(7 * SCALE)).is_zero());
}

#[test]
fun add_scale_values() {
    assert_eq!(fixed(SCALE).add(fixed(SCALE)).unwrap(), 2 * SCALE);
}

#[test]
fun sub_large_values() {
    assert_eq!(fixed(1_000_000 * SCALE).sub(fixed(999_999 * SCALE)).unwrap(), SCALE);
}

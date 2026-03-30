#[test_only]
module openzeppelin_fp_math::ud30x9_unchecked_tests;

use openzeppelin_fp_math::ud30x9_test_helpers::{fixed, expect};
use std::unit_test::assert_eq;

const MAX_VALUE: u128 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;

// ==== Tests ====

#[test]
fun unchecked_add_wraps_on_overflow() {
    let a = fixed(5);
    let b = fixed(7);
    assert_eq!(a.unchecked_add(b).unwrap(), 12);

    let near_max = fixed(MAX_VALUE - 5);
    let wrap_amount = fixed(10);
    let wrapped = near_max.unchecked_add(wrap_amount);
    assert_eq!(wrapped.unwrap(), 4);
}

#[test]
fun unchecked_sub_wraps_both_directions() {
    let ten = fixed(10);
    let three = fixed(3);

    assert_eq!(ten.unchecked_sub(three).unwrap(), 7);

    let wrapped = three.unchecked_sub(ten);
    assert_eq!(wrapped.unwrap(), MAX_VALUE - 6);
}

#[test]
fun unchecked_add_zero_is_identity() {
    let zero = fixed(0);
    let cases = vector[fixed(1), fixed(100), fixed(MAX_VALUE / 2), fixed(999)];
    cases.destroy!(|x| {
        expect!(x.unchecked_add(zero), x);
    });
}

#[test]
fun unchecked_sub_zero_is_identity() {
    let zero = fixed(0);
    let cases = vector[fixed(1), fixed(100), fixed(MAX_VALUE / 2), fixed(999)];
    cases.destroy!(|x| {
        expect!(x.unchecked_sub(zero), x);
    });
}

#[test]
fun unchecked_add_small_values() {
    assert_eq!(fixed(3).unchecked_add(fixed(4)).unwrap(), 7);
}

#[test]
fun unchecked_sub_small_values() {
    assert_eq!(fixed(10).unchecked_sub(fixed(3)).unwrap(), 7);
}

#[test]
fun unchecked_add_and_sub_are_inverse() {
    let delta = fixed(5);
    let cases = vector[fixed(10), fixed(100), fixed(1_000_000), fixed(42)];
    cases.destroy!(|x| {
        expect!(x.unchecked_add(delta).unchecked_sub(delta), x);
    });
}

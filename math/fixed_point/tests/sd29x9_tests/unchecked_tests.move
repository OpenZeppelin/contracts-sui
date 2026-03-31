#[test_only]
module openzeppelin_fp_math::sd29x9_unchecked_tests;

use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_test_helpers::{pos, neg};
use std::unit_test::assert_eq;

const SCALE: u128 = 1_000_000_000;

#[test]
fun unchecked_add_and_sub_wrap_around() {
    let max = sd29x9::max();
    let one = pos(1);
    assert_eq!(max.unchecked_add(one), sd29x9::min());

    let min_val = sd29x9::min();
    assert_eq!(min_val.unchecked_sub(one), max);
}

#[test]
fun unchecked_sub_zero_is_identity_for_positive() {
    let x = pos(123 * SCALE + 456_000_000);
    assert_eq!(x.unchecked_sub(sd29x9::zero()), x);
}

#[test]
fun unchecked_sub_zero_is_identity_for_negative() {
    let x = neg(123 * SCALE + 456_000_000);
    assert_eq!(x.unchecked_sub(sd29x9::zero()), x);
}

#[test]
fun unchecked_sub_zero_is_identity_for_max() {
    let max = sd29x9::max();
    assert_eq!(max.unchecked_sub(sd29x9::zero()), max);
}

#[test]
fun unchecked_sub_zero_is_identity_for_min() {
    let min = sd29x9::min();
    assert_eq!(min.unchecked_sub(sd29x9::zero()), min);
}

#[test]
fun unchecked_sub_zero_is_identity_for_zero() {
    let zero = sd29x9::zero();
    assert_eq!(zero.unchecked_sub(zero), zero);
}

#[test]
fun unchecked_add_zero_is_identity() {
    let zero = sd29x9::zero();
    let values = vector[pos(1), neg(1), pos(SCALE), neg(SCALE), sd29x9::max(), sd29x9::min(), zero];
    values.destroy!(|x| {
        assert_eq!(x.unchecked_add(zero), x);
    });
}

#[test]
fun unchecked_add_small_values() {
    assert_eq!(pos(3).unchecked_add(pos(4)), pos(7));
}

#[test]
fun unchecked_sub_small_values() {
    assert_eq!(pos(10).unchecked_sub(pos(3)), pos(7));
}

#[test_only]
module openzeppelin_fp_math::ud30x9_tests;

use openzeppelin_fp_math::casting_u128;
use openzeppelin_fp_math::ud30x9::{Self, UD30x9};
use std::unit_test::assert_eq;

const MAX_VALUE: u128 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;

// ==== Helpers ====

fun fixed(value: u128): UD30x9 {
    ud30x9::wrap(value)
}

// ==== Tests ====

#[test]
fun wrap_and_unwrap_roundtrip() {
    let raw = 123_456_789u128;
    let value = ud30x9::wrap(raw);
    assert_eq!(value.unwrap(), raw);

    let zero = ud30x9::wrap(0);
    assert_eq!(zero.unwrap(), 0);
}

#[test]
fun checked_arithmetic_matches_integers() {
    let left = fixed(1_000);
    let right = fixed(600);

    let sum = left.add(right);
    assert_eq!(sum.unwrap(), 1_600);

    let diff = left.sub(right);
    assert_eq!(diff.unwrap(), 400);

    let remainder = left.mod_(right);
    assert_eq!(remainder.unwrap(), 400);
}

#[test]
fun comparison_helpers_cover_all_outcomes() {
    let low = fixed(10);
    let high = fixed(20);

    assert!(low.lt(high));
    assert!(!high.lt(low));

    assert!(high.gt(low));
    assert!(!low.gt(high));

    assert!(high.gte(low));
    assert!(high.gte(high));
    assert!(!low.gte(high));

    assert!(low.lte(high));
    assert!(low.lte(low));
    assert!(!high.lte(low));

    assert!(low.eq(low));
    assert!(!low.eq(high));

    assert!(low.neq(high));
    assert!(!low.neq(low));

    let zero = fixed(0);
    assert!(zero.is_zero());
    assert!(!high.is_zero());
}

#[test]
fun bitwise_and_shift_helpers_behave_like_u128() {
    let raw = 0xF0F0u128;
    let other_raw = 0x00FFu128;
    let value = fixed(raw);
    let other = fixed(other_raw);

    assert_eq!(value.and(0x0FF0u128).unwrap(), raw & 0x0FF0u128);
    assert_eq!(value.and2(other).unwrap(), raw & other_raw);
    assert_eq!(value.or(other).unwrap(), raw | other_raw);
    assert_eq!(value.xor(other).unwrap(), raw ^ other_raw);

    let inverted = value.not();
    assert_eq!(inverted.unwrap(), MAX_VALUE ^ raw);

    let left_shifted = value.lshift(4);
    assert_eq!(left_shifted.unwrap(), raw << 4);

    let right_shifted = value.rshift(4);
    assert_eq!(right_shifted.unwrap(), raw >> 4);
}

#[test]
fun unchecked_addition_wraps_on_overflow() {
    let a = fixed(5);
    let b = fixed(7);
    assert_eq!(a.unchecked_add(b).unwrap(), 12);

    let near_max = fixed(MAX_VALUE - 5);
    let wrap_amount = fixed(10);
    let wrapped = near_max.unchecked_add(wrap_amount);
    assert_eq!(wrapped.unwrap(), 4);
}

#[test]
fun unchecked_subtraction_wraps_both_directions() {
    let ten = fixed(10);
    let three = fixed(3);

    assert_eq!(ten.unchecked_sub(three).unwrap(), 7);

    let wrapped = three.unchecked_sub(ten);
    assert_eq!(wrapped.unwrap(), MAX_VALUE - 6);
}

#[test]
fun modulo_and_zero_helpers_match_u128() {
    let dividend = fixed(100);
    let divisor = fixed(25);
    assert_eq!(dividend.mod_(divisor).unwrap(), 0);

    let odd_dividend = fixed(101);
    let remainder = odd_dividend.mod_(divisor);
    assert_eq!(remainder.unwrap(), 1);

    assert!(!dividend.is_zero());
}

#[test]
fun casting_from_u128_matches_wrap() {
    let raw = 987_654_321u128;
    let casted = casting_u128::into_UD30x9(raw);
    assert_eq!(casted.unwrap(), raw);

    let manual = fixed(raw);
    assert_eq!(manual.unwrap(), raw);
}

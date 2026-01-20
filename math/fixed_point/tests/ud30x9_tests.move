#[test_only]
module openzeppelin_fp_math::ud30x9_tests;

use openzeppelin_fp_math::casting_u128::into_UD30x9;
use openzeppelin_fp_math::ud30x9::{Self, UD30x9};
use std::unit_test::assert_eq;

use fun into_UD30x9 as u128.into_UD30x9;

const MAX_VALUE: u128 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
const SCALE: u128 = 1_000_000_000;

// ==== Helpers ====

fun fixed(value: u128): UD30x9 {
    ud30x9::wrap(value)
}

fun expect(left: UD30x9, right: UD30x9) {
    assert_eq!(left.unwrap(), right.unwrap());
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

    let remainder = left.mod(right);
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
    let raw = 0xF0F0;
    let other_raw = 0x00FF;
    let value = fixed(raw);
    let other = fixed(other_raw);

    assert_eq!(value.and(0x0FF0).unwrap(), raw & 0x0FF0);
    assert_eq!(value.and2(other).unwrap(), raw & other_raw);
    assert_eq!(value.or(other).unwrap(), raw | other_raw);
    assert_eq!(value.xor(other).unwrap(), raw ^ other_raw);

    let inverted = value.not();
    assert_eq!(inverted.unwrap(), MAX_VALUE ^ raw);

    let left_zero = value.lshift(0);
    assert_eq!(left_zero.unwrap(), raw);
    let left_shifted = value.lshift(4);
    assert_eq!(left_shifted.unwrap(), raw << 4);

    let right_zero = value.rshift(0);
    assert_eq!(right_zero.unwrap(), raw);
    let right_shifted = value.rshift(4);
    assert_eq!(right_shifted.unwrap(), raw >> 4);
}

#[test, expected_failure]
fun checked_add_overflow_aborts() {
    fixed(MAX_VALUE).add(fixed(1));
}

#[test, expected_failure]
fun checked_sub_underflow_aborts() {
    fixed(0).sub(fixed(1));
}

#[test, expected_failure]
fun modulo_with_zero_divisor_aborts() {
    fixed(10).mod(fixed(0));
}

#[test, expected_failure]
fun lshift_by_128_aborts() {
    fixed(1).lshift(128);
}

#[test, expected_failure]
fun rshift_by_128_aborts() {
    fixed(1).rshift(128);
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
    assert_eq!(dividend.mod(divisor).unwrap(), 0);

    let odd_dividend = fixed(101);
    let remainder = odd_dividend.mod(divisor);
    assert_eq!(remainder.unwrap(), 1);

    assert!(!dividend.is_zero());
}

#[test]
fun casting_from_u128_matches_wrap() {
    let raw = 987_654_321u128;
    let casted = raw.into_UD30x9();
    assert_eq!(casted.unwrap(), raw);

    let manual = fixed(raw);
    assert_eq!(manual.unwrap(), raw);
}

// === abs ===

#[test]
fun abs_returns_same_value_for_unsigned() {
    // 5.0 -> 5.0
    let value = fixed(5 * SCALE);
    assert_eq!(value.abs().unwrap(), value.unwrap());

    // 5.5 -> 5.5
    let value = fixed(5 * SCALE + 500_000_000);
    assert_eq!(value.abs().unwrap(), value.unwrap());

    // 0.1 -> 0.1
    let value = fixed(100_000_000);
    assert_eq!(value.abs().unwrap(), value.unwrap());
}

#[test]
fun abs_handles_zero() {
    // 0.0 -> 0.0
    let zero = ud30x9::zero();
    assert_eq!(zero.abs().unwrap(), 0);
}

#[test]
fun abs_handles_edge_cases() {
    // 0.000000001 -> 0.000000001
    let tiny = fixed(1);
    expect(tiny.abs(), tiny);

    // 1000000.5 -> 1000000.5
    let large = fixed(1000000 * SCALE + 500_000_000);
    expect(large.abs(), large);

    // Max value remains unchanged
    let max = ud30x9::max();
    assert_eq!(max.abs().unwrap(), MAX_VALUE);
}

// === ceil ===

#[test]
fun ceil_rounds_up_fractional_values() {
    // 5.3 -> 6.0
    let value = fixed(5 * SCALE + 300_000_000);
    expect(value.ceil(), fixed(6 * SCALE));

    // 5.9 -> 6.0
    let value = fixed(5 * SCALE + 900_000_000);
    expect(value.ceil(), fixed(6 * SCALE));

    // 1.1 -> 2.0
    let value = fixed(SCALE + 100_000_000);
    expect(value.ceil(), fixed(2 * SCALE));

    // 0.5 -> 1.0
    let value = fixed(500_000_000);
    expect(value.ceil(), fixed(SCALE));

    // 0.1 -> 1.0
    let value = fixed(100_000_000);
    expect(value.ceil(), fixed(SCALE));
}

#[test]
fun ceil_preserves_integer_values() {
    // 5.0 -> 5.0
    let value = fixed(5 * SCALE);
    expect(value.ceil(), fixed(5 * SCALE));

    // 0.0 -> 0.0
    let zero = fixed(0);
    expect(zero.ceil(), fixed(0));

    // 100.0 -> 100.0
    let value = fixed(100 * SCALE);
    expect(value.ceil(), fixed(100 * SCALE));

    // 1.0 -> 1.0
    let value = fixed(SCALE);
    expect(value.ceil(), fixed(SCALE));
}

#[test]
fun ceil_handles_edge_cases() {
    // 0.000000001 -> 1.0
    let tiny = fixed(1);
    expect(tiny.ceil(), fixed(SCALE));

    // 1000000000.5 -> 1000000000.0
    let large = fixed(1_000_000_000 * SCALE + 500_000_000);
    expect(large.ceil(), fixed(1_000_000_001 * SCALE));

    // 5.999999999 -> 6.0
    let almost = fixed(6 * SCALE - 1);
    expect(almost.ceil(), fixed(6 * SCALE));
}

#[test, expected_failure]
fun ceil_fails_for_max() {
    ud30x9::max().ceil();
}

// === floor ===

#[test]
fun floor_truncates_fractional_values() {
    // 5.3 -> 5.0
    let value = fixed(5 * SCALE + 300_000_000);
    expect(value.floor(), fixed(5 * SCALE));

    // 5.9 -> 5.0
    let value = fixed(5 * SCALE + 900_000_000);
    expect(value.floor(), fixed(5 * SCALE));

    // 1.1 -> 1.0
    let value = fixed(SCALE + 100_000_000);
    expect(value.floor(), fixed(SCALE));

    // 0.5 -> 0.0
    let value = fixed(500_000_000);
    expect(value.floor(), fixed(0));

    // 0.1 -> 0.0
    let value = fixed(100_000_000);
    expect(value.floor(), fixed(0));
}

#[test]
fun floor_preserves_integer_values() {
    // 5.0 -> 5.0
    let value = fixed(5 * SCALE);
    expect(value.floor(), fixed(5 * SCALE));

    // 0.0 -> 0.0
    let zero = fixed(0);
    expect(zero.floor(), fixed(0));

    // 100.0 -> 100.0
    let value = fixed(100 * SCALE);
    expect(value.floor(), fixed(100 * SCALE));

    // 1.0 -> 1.0
    let value = fixed(SCALE);
    expect(value.floor(), fixed(SCALE));
}

#[test]
fun floor_handles_edge_cases() {
    // 0.000000001 -> 0.0
    let tiny = fixed(1);
    expect(tiny.floor(), fixed(0));

    // 1000000000.5 -> 1000000000.0
    let large = fixed(1_000_000_000 * SCALE + 500_000_000);
    expect(large.floor(), fixed(1_000_000_000 * SCALE));

    // 5.000000001 -> 5.0
    let almost = fixed(5 * SCALE + 1);
    expect(almost.floor(), fixed(5 * SCALE));
}

#[test]
fun floor_handles_max() {
    let max = ud30x9::max();
    let expected = MAX_VALUE - MAX_VALUE % SCALE;
    expect(max.floor(), fixed(expected));
}

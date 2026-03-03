#[test_only]
module openzeppelin_fp_math::ud30x9_tests;

use openzeppelin_fp_math::casting_u128::into_UD30x9;
use openzeppelin_fp_math::ud30x9::{Self, UD30x9};
use openzeppelin_fp_math::ud30x9_base;
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

#[test, expected_failure(abort_code = ud30x9_base::EOverflow)]
fun checked_add_overflow_aborts_as_expected() {
    fixed(MAX_VALUE).add(fixed(1));
}

#[test, expected_failure(abort_code = ud30x9_base::EOverflow)]
fun checked_sub_underflow_aborts_as_expected() {
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

#[test, expected_failure(abort_code = ud30x9_base::EOverflow)]
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

// === mul ===

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

// === div ===

#[test]
fun div_handles_zero_and_identity_cases() {
    let zero = fixed(0);
    let one = fixed(SCALE);
    let value = fixed(7 * SCALE + 500_000_000); // 7.5

    expect(zero.div(value), zero);
    expect(value.div(one), value);
}

#[test]
fun div_handles_exact_and_fractional_results() {
    // 7.5 / 2.5 = 3.0
    let numerator = fixed(7 * SCALE + 500_000_000);
    let denominator = fixed(2 * SCALE + 500_000_000);
    expect(numerator.div(denominator), fixed(3 * SCALE));

    // 1.0 / 3.0 = 0.333333333...
    expect(fixed(SCALE).div(fixed(3 * SCALE)), fixed(333_333_333));
}

#[test]
fun div_truncates_repeating_results() {
    // 2.000000001 / 2.0 = 1.0000000005 -> 1.000000000
    let numerator = fixed(2 * SCALE + 1);
    let denominator = fixed(2 * SCALE);
    expect(numerator.div(denominator), fixed(SCALE));
}

#[test]
fun div_handles_extreme_but_valid_inputs() {
    // max / max = 1.0
    expect(ud30x9::max().div(ud30x9::max()), fixed(SCALE));
}

#[test, expected_failure]
fun div_by_zero_aborts() {
    fixed(10 * SCALE).div(fixed(0));
}

#[test, expected_failure(abort_code = ud30x9_base::EOverflow)]
fun div_result_overflow_aborts() {
    // max / 0.000000001 would exceed u128 when rescaled.
    ud30x9::max().div(fixed(1));
}

// === pow ===

#[test]
fun pow_handles_zero_and_one_exponents() {
    let x = fixed(12 * SCALE + 345_678_901);
    expect(x.pow(0), fixed(SCALE));
    expect(x.pow(1), x);
    expect(fixed(0).pow(0), fixed(SCALE));
}

#[test]
fun pow_handles_zero_and_one_bases() {
    expect(fixed(0).pow(5), fixed(0));
    expect(fixed(SCALE).pow(17), fixed(SCALE));
}

#[test]
fun pow_handles_fractional_values_and_truncation() {
    // 1.5^2 = 2.25, 1.5^3 = 3.375
    let one_point_five = fixed(1_500_000_000);
    expect(one_point_five.pow(2), fixed(2_250_000_000));
    expect(one_point_five.pow(3), fixed(3_375_000_000));

    // 1.000000001^2 = 1.000000002000000001 -> 1.000000002
    let epsilon = fixed(SCALE + 1);
    expect(epsilon.pow(2), fixed(SCALE + 2));
}

#[test]
fun pow_supports_high_exponents() {
    let val = fixed(SCALE + 250_000_000); // 1.25
    val.pow(255);
}

#[test, expected_failure(abort_code = ud30x9_base::EOverflow)]
fun pow_overflow_aborts_for_large_base() {
    ud30x9::max().pow(2);
}

#[test, expected_failure(abort_code = ud30x9_base::EOverflow)]
fun pow_overflow_aborts_with_correct_abort_code() {
    ud30x9::max().pow(32);
}

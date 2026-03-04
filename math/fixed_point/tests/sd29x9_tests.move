#[test_only]
module openzeppelin_fp_math::sd29x9_tests;

use openzeppelin_fp_math::sd29x9::{Self, SD29x9, from_bits};
use openzeppelin_fp_math::sd29x9_base;
use openzeppelin_fp_math::ud30x9;
use std::unit_test::assert_eq;

const ALL_ONES: u128 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
const MAX_POSITIVE_VALUE: u128 = 0x7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF; // 2^127 - 1
const MIN_NEGATIVE_VALUE: u128 = 0x8000_0000_0000_0000_0000_0000_0000_0000; // -2^127 in two's complement
const SCALE: u128 = 1_000_000_000;

// ==== Helpers ====

fun pos(raw: u128): SD29x9 {
    sd29x9::wrap(raw, false)
}

fun neg(raw: u128): SD29x9 {
    sd29x9::wrap(raw, true)
}

fun expect(left: SD29x9, right: SD29x9) {
    assert_eq!(left.unwrap(), right.unwrap());
}

// ==== Tests ====

#[test]
fun wrap_max_positive() {
    let value = sd29x9::wrap(MAX_POSITIVE_VALUE, false);
    expect(value, sd29x9::max());
}

#[test]
fun addition_and_subtraction_cover_signs() {
    expect(pos(10).add(neg(5)), pos(5));
    expect(neg(10).add(pos(5)), neg(5));
    expect(neg(7).add(neg(9)), neg(16));

    expect(pos(20).sub(pos(7)), pos(13));
    expect(pos(7).sub(pos(20)), neg(13));
    expect(neg(9).sub(neg(4)), neg(5));
}

#[test]
fun sum_handles_edge_cases() {
    let (min, max, zero) = (sd29x9::min(), sd29x9::max(), sd29x9::zero());
    expect(min.add(zero), min);
    expect(max.add(zero), max);
    expect(zero.add(min), min);
    expect(zero.add(max), max);

    let one = pos(1);
    expect(max.negate().add(one.negate()), min);
    expect(max.sub(one).add(one), max);
    expect(min.add(one).add(one).negate().add(one), max);
}

#[test]
fun sum_can_reach_minimum_value() {
    let min_val = sd29x9::min();
    let min_plus_one = min_val.add(pos(1));
    let zero = sd29x9::zero();

    // 0 + min = min (should work with checked add)
    expect(zero.add(min_val), min_val);
    // (min + 1) + (-1) = min
    expect(min_plus_one.add(neg(1)), min_val);
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun sum_handles_overflow() {
    let max = sd29x9::max();
    let one = pos(1);
    expect(max.add(one), sd29x9::min());
}

#[test]
fun sub_handles_edge_cases() {
    let (min, max, zero) = (sd29x9::min(), sd29x9::max(), sd29x9::zero());
    expect(min.sub(zero), min);
    expect(max.sub(zero), max);

    let one = pos(1);
    let min_plus_one = min.add(one);
    expect(zero.sub(min_plus_one), max);
    expect(zero.sub(max), min_plus_one);

    expect(max.negate().add(one.negate()), min);
    expect(max.sub(one).add(one), max);
    expect(min.add(one).add(one).negate().add(one), max);
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun sub_handles_overflow() {
    let min = sd29x9::min();
    let one = pos(1);
    expect(min.sub(one), sd29x9::max());
}

#[test]
fun comparison_helpers_handle_all_cases() {
    let neg_two = neg(2);
    let neg_four = neg(4);
    let pos_two = pos(2);

    assert!(neg_four.lt(neg_two));
    assert!(neg_two.lt(pos_two));
    assert!(!pos_two.lt(neg_two));

    assert!(pos_two.gt(neg_two));
    assert!(pos_two.gte(pos_two));
    assert!(!neg_four.gte(neg_two));

    assert!(pos_two.lte(pos_two));
    assert!(neg_four.lte(neg_two));
    assert!(!pos_two.lte(neg_two));

    assert!(pos_two.eq(pos_two));
    assert!(neg_two.neq(pos_two));
}

#[test]
fun bitwise_operations_match_raw_behavior() {
    let all_ones = from_bits(0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF);
    let mask = 0xFF;
    let pattern = from_bits(0xF0F0);

    assert_eq!(all_ones.and(mask).unwrap(), mask);
    assert_eq!(all_ones.and2(pattern).unwrap(), pattern.unwrap());
    assert_eq!(pattern.or(from_bits(0x0F0F)).unwrap(), 0xFFFF);
    assert_eq!(pattern.xor(from_bits(0xFFFF)).unwrap(), 0x0F0F);
    assert_eq!(pattern.not().unwrap(), from_bits(pattern.unwrap() ^ ALL_ONES).unwrap());
}

#[test]
fun shifts_cover_positive_negative_and_large_offsets() {
    let neg_value = neg(8);
    let pos_value = pos(4);

    expect(pos_value.lshift(0), pos_value);
    expect(pos_value.lshift(1), pos(8));
    expect(neg_value.lshift(1), neg(16));
    assert!(pos_value.lshift(128).is_zero());
    assert!(pos_value.lshift(129).is_zero());

    expect(pos_value.rshift(0), pos_value);
    expect(pos_value.rshift(1), pos(2));
    expect(neg_value.rshift(1), neg(4));
    expect(neg_value.rshift(0), neg_value);

    let neg_one = neg(1);
    expect(neg_one.rshift(127), neg_one);
    expect(pos_value.rshift(128), sd29x9::zero());
    expect(
        neg_one.rshift(128),
        from_bits(0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF),
    );
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun checked_add_overflow_aborts() {
    let max = sd29x9::max();
    let one = pos(1);
    max.add(one);
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun checked_sub_overflow_aborts() {
    let min_val = sd29x9::min();
    let one = pos(1);
    min_val.sub(one);
}

#[test]
fun mod_tracks_dividend_sign() {
    expect(pos(100).mod(pos(15)), pos(10));
    expect(neg(100).mod(pos(15)), neg(10));
    expect(pos(42).mod(neg(21)), sd29x9::zero());
}

#[test, expected_failure]
fun mod_with_zero_modulus_aborts() {
    pos(10).mod(sd29x9::zero());
}

#[test]
fun unchecked_add_and_sub_wrap_around() {
    let max = sd29x9::max();
    let one = pos(1);
    expect(max.unchecked_add(one), sd29x9::min());

    let min_val = sd29x9::min();
    expect(min_val.unchecked_sub(one), max);
}

#[test]
fun unchecked_sub_zero_is_identity_for_positive() {
    let x = pos(123 * SCALE + 456_000_000);
    expect(x.unchecked_sub(sd29x9::zero()), x);
}

#[test]
fun unchecked_sub_zero_is_identity_for_negative() {
    let x = neg(123 * SCALE + 456_000_000);
    expect(x.unchecked_sub(sd29x9::zero()), x);
}

#[test]
fun unchecked_sub_zero_is_identity_for_max() {
    let max = sd29x9::max();
    expect(max.unchecked_sub(sd29x9::zero()), max);
}

#[test]
fun unchecked_sub_zero_is_identity_for_min() {
    let min = sd29x9::min();
    expect(min.unchecked_sub(sd29x9::zero()), min);
}

#[test]
fun unchecked_sub_zero_is_identity_for_zero() {
    let zero = sd29x9::zero();
    expect(zero.unchecked_sub(zero), zero);
}

#[test]
fun logical_helpers_match_sd29x9_interface() {
    let value = pos(123);
    assert!(sd29x9::zero().is_zero());
    assert!(!value.is_zero());

    assert_eq!(value.unwrap(), value.unwrap());
    expect(pos(5), pos(5));
}

// === abs ===

#[test]
fun abs_preserves_positive_values() {
    // 5.0 -> 5.0
    expect(pos(5 * SCALE).abs(), pos(5 * SCALE));
    // 5.5 -> 5.5
    expect(pos(5 * SCALE + 500_000_000).abs(), pos(5 * SCALE + 500_000_000));
    // 0.1 -> 0.1
    expect(pos(100_000_000).abs(), pos(100_000_000));
}

#[test]
fun abs_converts_negative_to_positive() {
    // -5.0 -> 5.0
    expect(neg(5 * SCALE).abs(), pos(5 * SCALE));
    // -5.5 -> 5.5
    expect(neg(5 * SCALE + 500_000_000).abs(), pos(5 * SCALE + 500_000_000));
    // -0.1 -> 0.1
    expect(neg(100_000_000).abs(), pos(100_000_000));
    // -1.0 -> 1.0
    expect(neg(SCALE).abs(), pos(SCALE));
}

#[test]
fun abs_handles_zero() {
    // 0.0 -> 0.0
    expect(sd29x9::zero().abs(), sd29x9::zero());
}

#[test]
fun abs_handles_edge_cases() {
    // Very small positive: 0.000000001 -> 0.000000001
    expect(pos(1).abs(), pos(1));

    // Very small negative: -0.000000001 -> 0.000000001
    expect(neg(1).abs(), pos(1));

    // Large positive value: 1000000000.5 -> 1000000000.5
    expect(
        pos(1_000_000_000 * SCALE + 500_000_000).abs(),
        pos(1_000_000_000 * SCALE + 500_000_000),
    );

    // Large negative value: -1000000000.5 -> 1000000000.5
    expect(
        neg(1_000_000_000 * SCALE + 500_000_000).abs(),
        pos(1_000_000_000 * SCALE + 500_000_000),
    );

    // Max positive value remains unchanged
    expect(sd29x9::max().abs(), sd29x9::max());
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun abs_fails_for_min() {
    sd29x9::min().abs();
}

// === ceil ===

#[test]
fun ceil_rounds_up_positive_fractional_values() {
    // 5.3 -> 6.0
    expect(pos(5 * SCALE + 300_000_000).ceil(), pos(6 * SCALE));
    // 5.9 -> 6.0
    expect(pos(5 * SCALE + 900_000_000).ceil(), pos(6 * SCALE));
    // 1.1 -> 2.0
    expect(pos(SCALE + 100_000_000).ceil(), pos(2 * SCALE));
    // 0.5 -> 1.0
    expect(pos(500_000_000).ceil(), pos(SCALE));
    // 0.1 -> 1.0
    expect(pos(100_000_000).ceil(), pos(SCALE));
}

#[test]
fun ceil_truncates_negative_fractional_values() {
    // -5.3 -> -5.0
    expect(neg(5 * SCALE + 300_000_000).ceil(), neg(5 * SCALE));
    // -5.9 -> -5.0
    expect(neg(5 * SCALE + 900_000_000).ceil(), neg(5 * SCALE));
    // -1.1 -> -1.0
    expect(neg(SCALE + 100_000_000).ceil(), neg(SCALE));
    // -0.5 -> 0.0
    expect(neg(500_000_000).ceil(), sd29x9::zero());
    // -0.1 -> 0.0
    expect(neg(100_000_000).ceil(), sd29x9::zero());
}

#[test]
fun ceil_preserves_integer_values() {
    // 5.0 -> 5.0
    expect(pos(5 * SCALE).ceil(), pos(5 * SCALE));
    // -5.0 -> -5.0
    expect(neg(5 * SCALE).ceil(), neg(5 * SCALE));
    // 0.0 -> 0.0
    expect(sd29x9::zero().ceil(), sd29x9::zero());
    // 100.0 -> 100.0
    expect(pos(100 * SCALE).ceil(), pos(100 * SCALE));
}

#[test]
fun ceil_handles_edge_cases() {
    // Very small positive fractional: 0.000000001 -> ceil: 1.0
    expect(pos(1).ceil(), pos(SCALE));

    // Very small negative fractional: -0.000000001 -> ceil: 0.0
    expect(neg(1).ceil(), sd29x9::zero());

    // Large value with fraction: 1000000000.5 -> ceil: 1000000001.0
    expect(pos(1_000_000_000 * SCALE + 500_000_000).ceil(), pos(1_000_000_001 * SCALE));
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun ceil_fails_for_max() {
    sd29x9::max().ceil();
}

#[test]
fun ceil_handles_min() {
    let min = sd29x9::min();
    let expected = MIN_NEGATIVE_VALUE - MIN_NEGATIVE_VALUE % SCALE;
    expect(min.ceil(), neg(expected));
}

// === floor ===

#[test]
fun floor_truncates_positive_fractional_values() {
    // 5.3 -> 5.0
    expect(pos(5 * SCALE + 300_000_000).floor(), pos(5 * SCALE));
    // 5.9 -> 5.0
    expect(pos(5 * SCALE + 900_000_000).floor(), pos(5 * SCALE));
    // 1.1 -> 1.0
    expect(pos(SCALE + 100_000_000).floor(), pos(SCALE));
    // 0.5 -> 0.0
    expect(pos(500_000_000).floor(), sd29x9::zero());
    // 0.1 -> 0.0
    expect(pos(100_000_000).floor(), sd29x9::zero());
}

#[test]
fun floor_rounds_down_negative_fractional_values() {
    // -5.3 -> -6.0
    expect(neg(5 * SCALE + 300_000_000).floor(), neg(6 * SCALE));
    // -5.9 -> -6.0
    expect(neg(5 * SCALE + 900_000_000).floor(), neg(6 * SCALE));
    // -1.1 -> -2.0
    expect(neg(SCALE + 100_000_000).floor(), neg(2 * SCALE));
    // -0.5 -> -1.0
    expect(neg(500_000_000).floor(), neg(SCALE));
    // -0.1 -> -1.0
    expect(neg(100_000_000).floor(), neg(SCALE));
}

#[test]
fun floor_preserves_integer_values() {
    // 5.0 -> 5.0
    expect(pos(5 * SCALE).floor(), pos(5 * SCALE));
    // -5.0 -> -5.0
    expect(neg(5 * SCALE).floor(), neg(5 * SCALE));
    // 0.0 -> 0.0
    expect(sd29x9::zero().floor(), sd29x9::zero());
    // 100.0 -> 100.0
    expect(pos(100 * SCALE).floor(), pos(100 * SCALE));
}

#[test]
fun floor_handles_edge_cases() {
    // Very small positive fractional: 0.000000001 -> floor: 0.0
    expect(pos(1).floor(), sd29x9::zero());

    // Very small negative fractional: -0.000000001 -> floor: -1.0
    expect(neg(1).floor(), neg(SCALE));

    // Large value with fraction: 1000000000.5 -> floor: 1000000000.0
    expect(pos(1_000_000_000 * SCALE + 500_000_000).floor(), pos(1_000_000_000 * SCALE));
}

#[test]
fun floor_handles_max() {
    let max = sd29x9::max();
    let expected = MAX_POSITIVE_VALUE - MAX_POSITIVE_VALUE % SCALE;
    expect(max.floor(), pos(expected));
}

#[test, expected_failure]
fun floor_fails_for_min() {
    sd29x9::min().floor();
}

// === negate ===

#[test]
fun negate_handles_zero() {
    expect(sd29x9::zero().negate(), sd29x9::zero());
}

#[test]
fun negate_flips_positive_and_negative_values() {
    expect(pos(1).negate(), neg(1));
    expect(pos(SCALE).negate(), neg(SCALE));
    expect(pos(5 * SCALE + 300_000_000).negate(), neg(5 * SCALE + 300_000_000));

    expect(neg(1).negate(), pos(1));
    expect(neg(SCALE).negate(), pos(SCALE));
    expect(neg(5 * SCALE + 300_000_000).negate(), pos(5 * SCALE + 300_000_000));
}

#[test]
fun negate_is_its_own_inverse() {
    let zero = sd29x9::zero();
    expect(zero.negate().negate(), zero);

    let one = pos(1);
    expect(one.negate().negate(), one);

    let minus_one = neg(1);
    expect(minus_one.negate().negate(), minus_one);

    let large_positive = pos(500_000_000_000_000_000);
    expect(large_positive.negate().negate(), large_positive);

    let large_negative = neg(500_000_000_000_000_000);
    expect(large_negative.negate().negate(), large_negative);

    let pos_with_fraction = pos(42 * SCALE + 123_456_789);
    expect(pos_with_fraction.negate().negate(), pos_with_fraction);

    let neg_with_fraction = neg(42 * SCALE + 123_456_789);
    expect(neg_with_fraction.negate().negate(), neg_with_fraction);

    let max = sd29x9::max();
    expect(max.negate().negate(), max);
}

#[test]
fun negate_handles_max() {
    expect(sd29x9::max().negate(), from_bits(MIN_NEGATIVE_VALUE + 1));
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun negate_fails_for_min() {
    sd29x9::min().negate();
}

#[test]
fun negate_handles_min_minus_one() {
    let min_minus_one = neg(MIN_NEGATIVE_VALUE - 1);
    expect(min_minus_one.negate(), sd29x9::max());
}

// === mul ===

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
    ];
    values.destroy!(|val| {
        expect(val.mul(zero), zero);
        expect(zero.mul(val), zero);
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
        expect(val.mul(one), val);
        expect(one.mul(val), val);
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
        expect(val.mul(minus_one), val.negate());
        expect(minus_one.mul(val), val.negate());
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
    expect(two.mul(three), six);

    // 2. Left positive, right negative
    expect(two.mul(minus_three), minus_six);

    // 3. Left negative, right positive
    expect(minus_two.mul(three), minus_six);

    // 4. Both negative
    expect(minus_two.mul(minus_three), six);
}

#[test]
fun mul_handles_signs_for_fractional() {
    // 1.5 * 2.25 = 3.375
    let left = pos(1_500_000_000);
    let right = pos(2_250_000_000);
    let expected = pos(3_375_000_000);

    // 1. Both positive
    expect(left.mul(right), expected);

    // 2. Left positive, right negative
    expect(left.mul(right.negate()), expected.negate());

    // 3. Left negative, right positive
    expect(left.negate().mul(right), expected.negate());

    // 4. Both negative
    expect(left.negate().mul(right.negate()), expected);
}

#[test]
fun mul_handles_fractional_products() {
    let a = pos(1_500_000_000);
    let b = pos(2_250_000_000);
    let product = pos(3_375_000_000);

    // 1.5 * 2.25 = 3.375
    expect(a.mul(b), pos(3_375_000_000));

    // 1.5 * -2.25 = -3.375
    expect(a.mul(b.negate()), product.negate());

    // -1.5 * 2.25 = -3.375
    expect(a.negate().mul(b), product.negate());

    // -1.5 * -2.25 = 3.375
    expect(a.negate().mul(b.negate()), product);
}

#[test]
fun mul_truncates_towards_zero_at_scale_boundary() {
    // 1.000000001 * 1.000000001 = 1.000000002000000001 -> 1.000000002
    let x = pos(SCALE + 1);
    expect(x.mul(x), pos(SCALE + 2));

    // 1.000000001 * 1.000000002 = 1.000000003000000002 -> 1.000000003
    expect(pos(SCALE + 1).mul(pos(SCALE + 2)), pos(SCALE + 3));

    // 0.999999999 * 0.999999999 = 0.999999998000000001 -> 0.999999998
    let almost_one = pos(SCALE - 1);
    expect(almost_one.mul(almost_one), pos(SCALE - 2));

    // Sign checks near the truncation boundary
    expect(x.negate().mul(x), neg(SCALE + 2));
    expect(x.negate().mul(x.negate()), pos(SCALE + 2));
}

#[test]
fun mul_handles_difficult_fractional_magnitudes() {
    // (999999999.999999999)^2 = 999999999999999998.000000000000000001
    let value = pos(999_999_999_999_999_999);
    let expected_square = pos(999_999_999_999_999_998_000_000_000);
    expect(value.mul(value), pos(999_999_999_999_999_998_000_000_000));
    expect(value.negate().mul(value), expected_square.negate());
    expect(value.mul(value.negate()), expected_square.negate());
    expect(value.negate().mul(value.negate()), expected_square);

    // 123456789.123456789 * 987654321.987654321
    let left = pos(123_456_789_123_456_789);
    let right = pos(987_654_321_987_654_321);
    let expected_product = pos(121_932_631_356_500_531_347_203_169);
    expect(left.mul(right), expected_product);
    expect(left.negate().mul(right), expected_product.negate());
    expect(left.mul(right.negate()), expected_product.negate());
    expect(left.negate().mul(right.negate()), expected_product);
}

#[test]
fun mul_large_intermediate_product_does_not_overflow() {
    // These products exceed u128 before scaling down, so this checks that
    // multiplication uses a wider intermediate and only then divides by SCALE
    let half = pos(SCALE / 2); // 0.5
    let max = sd29x9::max();
    let min = sd29x9::min();

    expect(max.mul(half), pos(MAX_POSITIVE_VALUE / 2));
    expect(half.mul(max), pos(MAX_POSITIVE_VALUE / 2));

    expect(min.mul(half), neg(MIN_NEGATIVE_VALUE / 2));
    expect(half.mul(min), neg(MIN_NEGATIVE_VALUE / 2));
}

#[test]
fun mul_handles_min_times_one() {
    let min = sd29x9::min();
    let one = sd29x9::one();
    expect(min.mul(one), min);
}

#[test]
fun mul_handles_max_times_one() {
    let max = sd29x9::max();
    let one = sd29x9::one();
    expect(max.mul(one), max);
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun mul_overflow_aborts_for_min_times_negative_one() {
    sd29x9::min().mul(neg(SCALE));
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun mul_overflow_aborts_for_large_positive_result() {
    sd29x9::max().mul(pos(SCALE + 1));
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun mul_overflow_aborts_for_large_negative_result() {
    sd29x9::min().mul(pos(SCALE + 1));
}

// === div ===

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

#[test, expected_failure]
fun div_by_zero_aborts() {
    pos(10 * SCALE).div(sd29x9::zero());
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun div_handles_min_div_negative_one() {
    sd29x9::min().div(neg(SCALE));
}

// === pow ===

#[test]
fun pow_handles_zero_and_one_exponents() {
    let x = pos(12 * SCALE + 345_678_901);
    expect(x.pow(0), sd29x9::one());
    expect(x.pow(1), x);
    expect(sd29x9::zero().pow(0), sd29x9::one());
}

#[test]
fun pow_handles_zero_base_and_sign_parity() {
    let zero = sd29x9::zero();
    expect(zero.pow(5), zero);

    let neg_base = neg(2 * SCALE);
    expect(neg_base.pow(2), pos(4 * SCALE));
    expect(neg_base.pow(3), neg(8 * SCALE));
}

#[test]
fun pow_handles_fractional_values_and_truncation() {
    // 1.5^2 = 2.25, 1.5^3 = 3.375
    let one_point_five = pos(1_500_000_000);
    expect(one_point_five.pow(2), pos(2_250_000_000));
    expect(one_point_five.pow(3), pos(3_375_000_000));

    // 1.000000001^2 = 1.000000002000000001 -> 1.000000002
    let epsilon = pos(SCALE + 1);
    expect(epsilon.pow(2), pos(SCALE + 2));
}

#[test]
fun pow_handles_negative_one_parity() {
    let neg_one = neg(SCALE);
    expect(neg_one.pow(2), pos(SCALE));
    expect(neg_one.pow(3), neg(SCALE));
}

#[test]
fun pow_supports_high_exponents() {
    let val = pos(SCALE + 250_000_000); // 1.25
    val.pow(255);
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun pow_overflow_aborts_for_large_base() {
    sd29x9::max().pow(2);
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun pow_overflow_aborts_for_large_exponent() {
    let three = pos(3 * SCALE);
    three.pow(255);
}

// === into_UD30x9 ===

#[test]
fun into_ud30x9_converts_zero() {
    let zero = sd29x9::zero();
    let converted = zero.into_UD30x9();
    assert!(converted.is_zero());
    assert!(converted.eq(ud30x9::zero()));
}

#[test]
fun into_ud30x9_converts_integer_and_fractional_values() {
    // 42.0
    let integer = pos(42 * SCALE);
    let expected_int = ud30x9::wrap(42 * SCALE);
    assert_eq!(integer.into_UD30x9(), expected_int);

    // 42.123456789
    let fractional = pos(42 * SCALE + 123_456_789);
    let expected_fractional = ud30x9::wrap(42 * SCALE + 123_456_789);
    assert_eq!(fractional.into_UD30x9(), expected_fractional);
}

#[test]
fun into_ud30x9_roundtrip_for_supported_values() {
    let samples = vector[
        0,
        1,
        SCALE - 1,
        SCALE,
        SCALE + 1,
        123 * SCALE + 456_789_012,
        MAX_POSITIVE_VALUE,
    ];

    samples.destroy!(|val| {
        let x = pos(val);
        let result = x.into_UD30x9().into_SD29x9();
        assert_eq!(x, result);
    });
}

#[test]
fun into_ud30x9_converts_max_supported_value() {
    let max_supported = sd29x9::max();
    let expected = ud30x9::wrap(MAX_POSITIVE_VALUE);
    assert_eq!(max_supported.into_UD30x9(), expected);
}

#[test, expected_failure(abort_code = sd29x9_base::ECannotBeConvertedToUD30x9)]
fun into_ud30x9_aborts_for_negative_fractional_value() {
    let unsupported_val = neg(SCALE + 1);
    unsupported_val.into_UD30x9();
}

#[test, expected_failure(abort_code = sd29x9_base::ECannotBeConvertedToUD30x9)]
fun into_ud30x9_aborts_for_sd29x9_min() {
    sd29x9::min().into_UD30x9();
}

// === try_into_UD30x9 ===

#[test]
fun try_into_ud30x9_returns_some_for_zero() {
    let zero = sd29x9::zero();
    let result = zero.try_into_UD30x9();
    assert_eq!(result, option::some(ud30x9::zero()));
    result.do!(|val| assert!(val.is_zero()));
}

#[test]
fun try_into_ud30x9_returns_some_for_integer_and_fractional_values() {
    // 42.0
    let int_val = pos(42 * SCALE);
    let expected_int = ud30x9::wrap(42 * SCALE);
    assert_eq!(int_val.try_into_UD30x9(), option::some(expected_int));

    // 42.123456789
    let fractional = pos(42 * SCALE + 123_456_789);
    let expected_fractional = ud30x9::wrap(42 * SCALE + 123_456_789);
    assert_eq!(fractional.try_into_UD30x9(), option::some(expected_fractional));
}

#[test]
fun try_into_ud30x9_roundtrip_for_supported_values() {
    let samples = vector[
        0,
        1,
        SCALE - 1,
        SCALE,
        SCALE + 1,
        123 * SCALE + 456_789_012,
        MAX_POSITIVE_VALUE,
    ];

    samples.destroy!(|val| {
        let x = pos(val);
        let result = x.try_into_UD30x9().destroy_some().try_into_SD29x9().destroy_some();
        assert_eq!(x, result);
    });
}

#[test]
fun try_into_ud30x9_returns_some_for_max_supported_value() {
    let max_supported = sd29x9::max();
    let expected = ud30x9::wrap(MAX_POSITIVE_VALUE);
    assert_eq!(max_supported.try_into_UD30x9(), option::some(expected));
}

#[test]
fun try_into_ud30x9_returns_none_for_negative_fractional_value() {
    let unsupported_val = neg(SCALE + 1);
    assert_eq!(unsupported_val.try_into_UD30x9(), option::none());
}

#[test]
fun try_into_ud30x9_returns_none_for_sd29x9_min() {
    assert_eq!(sd29x9::min().try_into_UD30x9(), option::none());
}

#[test]
fun try_into_ud30x9_matches_into_ud30x9_on_convertible_values() {
    let samples = vector[0, 1, SCALE - 1, SCALE, 123 * SCALE + 456_789_012, MAX_POSITIVE_VALUE];

    samples.destroy!(|raw| {
        let x = pos(raw);
        assert_eq!(sd29x9_base::try_into_UD30x9(x), option::some(x.into_UD30x9()));
    });
}

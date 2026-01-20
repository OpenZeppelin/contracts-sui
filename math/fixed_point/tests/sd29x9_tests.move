#[test_only]
module openzeppelin_fp_math::sd29x9_tests;

use openzeppelin_fp_math::sd29x9::{Self, SD29x9, from_bits};
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
fun addition_and_subtraction_cover_signs() {
    expect(pos(10).add(neg(5)), pos(5));
    expect(neg(10).add(pos(5)), neg(5));
    expect(neg(7).add(neg(9)), neg(16));

    expect(pos(20).sub(pos(7)), pos(13));
    expect(pos(7).sub(pos(20)), neg(13));
    expect(neg(9).sub(neg(4)), neg(5));
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

#[test, expected_failure(abort_code = sd29x9::EOverflow)]
fun checked_add_overflow_aborts() {
    let max = sd29x9::max();
    let one = pos(1);
    max.add(one);
}

#[test, expected_failure(abort_code = sd29x9::EOverflow)]
fun checked_sub_overflow_aborts() {
    let min_val = sd29x9::min();
    let one = pos(1);
    min_val.sub(one);
}

#[test]
fun modulo_tracks_dividend_sign() {
    expect(pos(100).mod(pos(15)), pos(10));
    expect(neg(100).mod(pos(15)), neg(10));
    expect(pos(42).mod(neg(21)), sd29x9::zero());
}

#[test, expected_failure]
fun modulo_with_zero_divisor_aborts() {
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

#[test, expected_failure]
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

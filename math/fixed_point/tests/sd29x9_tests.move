#[test_only]
module openzeppelin_fp_math::sd29x9_tests;

use openzeppelin_fp_math::sd29x9::{Self, SD29x9, from_bits};
use std::unit_test::assert_eq;

const ALL_ONES: u128 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;

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
    let mask = 0xFFu128;
    let pattern = from_bits(0xF0F0u128);

    assert_eq!(all_ones.and(mask).unwrap(), mask);
    assert_eq!(all_ones.and2(pattern).unwrap(), pattern.unwrap());
    assert_eq!(pattern.or(from_bits(0x0F0Fu128)).unwrap(), 0xFFFFu128);
    assert_eq!(pattern.xor(from_bits(0xFFFFu128)).unwrap(), 0x0F0Fu128);
    assert_eq!(pattern.not().unwrap(), from_bits(pattern.unwrap() ^ ALL_ONES).unwrap());
}

#[test]
fun shifts_cover_positive_negative_and_large_offsets() {
    let neg_value = neg(8);
    let pos_value = pos(4);

    expect(pos_value.lshift(1), pos(8));
    expect(neg_value.lshift(1), neg(16));
    assert!(pos_value.lshift(129).is_zero());

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

#[test]
fun modulo_tracks_dividend_sign() {
    expect(pos(100).mod_(pos(15)), pos(10));
    expect(neg(100).mod_(pos(15)), neg(10));
    expect(pos(42).mod_(neg(21)), sd29x9::zero());
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

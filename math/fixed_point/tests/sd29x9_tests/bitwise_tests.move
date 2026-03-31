#[test_only]
module openzeppelin_fp_math::sd29x9_bitwise_tests;

use openzeppelin_fp_math::sd29x9::{Self, from_bits};
use openzeppelin_fp_math::sd29x9_test_helpers::{pos, neg, expect};
use std::unit_test::assert_eq;

const ALL_ONES: u128 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;

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

#[test]
fun lshift_truncates_high_bits_before_full_width() {
    let value = from_bits(0xF000_0000_0000_0000_0000_0000_0000_0001);
    assert_eq!(value.lshift(4).unwrap(), 0x0000_0000_0000_0000_0000_0000_0000_0010);
}

#[test]
fun and_with_zero_is_zero() {
    assert_eq!(pos(0xFF).and(0).unwrap(), 0);
}

#[test]
fun or_with_zero_is_identity() {
    assert_eq!(pos(0xF0F0).or(from_bits(0)).unwrap(), 0xF0F0);
}

#[test]
fun xor_with_self_is_zero() {
    assert!(from_bits(0xABCD).xor(from_bits(0xABCD)).is_zero());
}

#[test]
fun not_of_zero_is_all_ones() {
    assert_eq!(from_bits(0).not().unwrap(), ALL_ONES);
}

#[test]
fun and2_commutativity() {
    let a = from_bits(0xF0F0_ABCD);
    let b = from_bits(0x0F0F_1234);
    assert_eq!(a.and2(b).unwrap(), b.and2(a).unwrap());
}

#[test]
fun or_combines_bits() {
    assert_eq!(from_bits(0xF0).or(from_bits(0x0F)).unwrap(), 0xFF);
}

#[test]
fun lshift_by_1_doubles_magnitude() {
    expect(pos(4).lshift(1), pos(8));
}

#[test]
fun rshift_by_1_halves_magnitude() {
    expect(pos(8).rshift(1), pos(4));
}

#[test]
fun rshift_preserves_negative_sign_for_large_shift() {
    // neg(1) in two's complement is all ones; arithmetic right shift keeps it all ones
    expect(neg(1).rshift(127), neg(1));
}

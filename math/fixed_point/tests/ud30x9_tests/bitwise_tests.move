#[test_only]
module openzeppelin_fp_math::ud30x9_bitwise_tests;

use openzeppelin_fp_math::ud30x9_test_helpers::{fixed, expect, pair, unpack};
use std::unit_test::assert_eq;

const MAX_VALUE: u128 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;

// ==== Tests ====

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

#[test]
fun lshift_by_128_returns_zero() {
    let x = fixed(1);
    expect(x.lshift(128), fixed(0));
}

#[test]
fun rshift_by_128_returns_zero() {
    let x = fixed(1);
    expect(x.rshift(128), fixed(0));
}

#[test]
fun lshift_by_255_returns_zero() {
    let x = fixed(1);
    expect(x.lshift(255), fixed(0));
}

#[test]
fun rshift_by_255_returns_zero() {
    let x = fixed(1);
    expect(x.rshift(255), fixed(0));
}

#[test]
fun lshift_truncates_high_bits_before_full_width() {
    let value = fixed(0xF000_0000_0000_0000_0000_0000_0000_0001);
    assert_eq!(value.lshift(4).unwrap(), 0x0000_0000_0000_0000_0000_0000_0000_0010);
}

#[test]
fun and_with_zero_is_zero() {
    assert!(fixed(0xFF).and(0).is_zero());
}

#[test]
fun or_with_zero_is_identity() {
    assert_eq!(fixed(0xF0F0).or(fixed(0)).unwrap(), 0xF0F0);
}

#[test]
fun xor_with_self_is_zero() {
    assert!(fixed(0xABCD).xor(fixed(0xABCD)).is_zero());
}

#[test]
fun not_of_zero_is_all_ones() {
    assert_eq!(fixed(0).not().unwrap(), MAX_VALUE);
}

#[test]
fun and2_commutativity() {
    let pairs = vector[
        pair(fixed(0xF0F0), fixed(0x00FF)),
        pair(fixed(0xABCD), fixed(0x1234)),
        pair(fixed(MAX_VALUE), fixed(0xFF00)),
    ];
    pairs.destroy!(|p| {
        let (a, b) = p.unpack();
        assert_eq!(a.and2(b).unwrap(), b.and2(a).unwrap());
    });
}

#[test]
fun lshift_by_1_doubles() {
    assert_eq!(fixed(4).lshift(1).unwrap(), 8);
}

#[test]
fun rshift_by_1_halves() {
    assert_eq!(fixed(8).rshift(1).unwrap(), 4);
}

#[test]
fun lshift_then_rshift_is_identity_when_no_overflow() {
    assert_eq!(fixed(4).lshift(2).rshift(2).unwrap(), 4);
}

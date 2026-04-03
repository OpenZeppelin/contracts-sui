#[test_only]
module openzeppelin_fp_math::ud30x9_bitwise_tests;

use openzeppelin_fp_math::ud30x9_base;
use openzeppelin_fp_math::ud30x9_test_helpers::{fixed, pair, unpack};
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

    let right_zero = value.unchecked_rshift(0);
    assert_eq!(right_zero.unwrap(), raw);
    let right_shifted = value.unchecked_rshift(4);
    assert_eq!(right_shifted.unwrap(), raw >> 4);
}

#[test]
fun unchecked_lshift_by_128_returns_zero() {
    let x = fixed(1);
    assert_eq!(x.unchecked_lshift(128), fixed(0));
}

#[test]
fun unchecked_rshift_by_128_returns_zero() {
    let x = fixed(1);
    assert_eq!(x.unchecked_rshift(128), fixed(0));
}

#[test]
fun unchecked_lshift_by_255_returns_zero() {
    let x = fixed(1);
    assert_eq!(x.unchecked_lshift(255), fixed(0));
}

#[test]
fun unchecked_rshift_by_255_returns_zero() {
    let x = fixed(1);
    assert_eq!(x.unchecked_rshift(255), fixed(0));
}

#[test]
fun unchecked_lshift_truncates_high_bits_before_full_width() {
    let value = fixed(0xF000_0000_0000_0000_0000_0000_0000_0001);
    assert_eq!(value.unchecked_lshift(4).unwrap(), 0x0000_0000_0000_0000_0000_0000_0000_0010);
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
fun lshift_zero_by_any_amount_returns_zero() {
    assert_eq!(fixed(0).lshift(0), fixed(0));
    assert_eq!(fixed(0).lshift(1), fixed(0));
    assert_eq!(fixed(0).lshift(127), fixed(0));
    assert_eq!(fixed(0).lshift(128), fixed(0));
    assert_eq!(fixed(0).lshift(255), fixed(0));
}

#[test]
fun lshift_by_0_is_identity() {
    assert_eq!(fixed(1).lshift(0).unwrap(), 1);
    assert_eq!(fixed(MAX_VALUE).lshift(0).unwrap(), MAX_VALUE);
}

#[test]
fun lshift_by_1_doubles() {
    assert_eq!(fixed(4).lshift(1).unwrap(), 8);
}

#[test]
fun lshift_small_values() {
    assert_eq!(fixed(1).lshift(4).unwrap(), 16);
    assert_eq!(fixed(0xFF).lshift(8).unwrap(), 0xFF00);
}

#[test]
fun lshift_max_safe_shift() {
    // 1 << 127 is the highest single-bit value in u128
    assert_eq!(fixed(1).lshift(127).unwrap(), 1 << 127);
}

#[test]
fun lshift_then_unchecked_rshift_is_identity_when_no_overflow() {
    assert_eq!(fixed(4).lshift(2).unchecked_rshift(2).unwrap(), 4);
    assert_eq!(fixed(0xABCD).lshift(16).unchecked_rshift(16).unwrap(), 0xABCD);
}

#[test, expected_failure(abort_code = ud30x9_base::EOverflow)]
fun lshift_aborts_on_overflow() {
    // 2 << 127 would require 129 bits
    fixed(2).lshift(127);
}

#[test, expected_failure(abort_code = ud30x9_base::EOverflow)]
fun lshift_aborts_when_bits_is_128() {
    fixed(1).lshift(128);
}

#[test, expected_failure(abort_code = ud30x9_base::EOverflow)]
fun lshift_aborts_when_bits_is_255() {
    fixed(1).lshift(255);
}

#[test, expected_failure(abort_code = ud30x9_base::EOverflow)]
fun lshift_aborts_for_high_bits_overflow() {
    // Top nibble is non-zero, shifting by 4 pushes bits past u128
    fixed(0xF000_0000_0000_0000_0000_0000_0000_0001).lshift(4);
}

#[test]
fun unchecked_lshift_by_1_doubles() {
    assert_eq!(fixed(4).unchecked_lshift(1).unwrap(), 8);
}

#[test]
fun unchecked_rshift_by_1_halves() {
    assert_eq!(fixed(8).unchecked_rshift(1).unwrap(), 4);
}

#[test]
fun unchecked_lshift_then_unchecked_rshift_is_identity_when_no_overflow() {
    assert_eq!(fixed(4).unchecked_lshift(2).unchecked_rshift(2).unwrap(), 4);
}

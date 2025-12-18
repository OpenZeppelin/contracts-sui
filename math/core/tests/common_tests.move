#[test_only]
module openzeppelin_math::common_tests;

use openzeppelin_math::common;
use std::unit_test::assert_eq;

// === clz ===

#[test]
fun clz_returns_full_width_for_zero() {
    assert_eq!(common::clz(0, 256), 256);
}

#[test]
fun clz_detects_top_bit() {
    let top_bit = 1u256 << 255;
    assert_eq!(common::clz(top_bit, 256), 0);
}

#[test]
fun clz_counts_middle_bits() {
    let value = 1u256 << 128;
    assert_eq!(common::clz(value, 256), 127);

    let lower_value = 1u256 << 5;
    assert_eq!(common::clz(lower_value, 256), 250);
}

#[test]
fun clz_handles_u8_values() {
    let zero: u8 = 0;
    assert_eq!(common::clz(zero as u256, 8), 8);

    let top_bit: u8 = 1u8 << 7;
    assert_eq!(common::clz(top_bit as u256, 8), 0);

    let mid_bit: u8 = 1u8 << 2;
    assert_eq!(common::clz(mid_bit as u256, 8), 5);
}

#[test]
fun clz_handles_u16_values() {
    let top_bit: u16 = 1u16 << 15;
    assert_eq!(common::clz(top_bit as u256, 16), 0);

    let mid_bit: u16 = 1u16 << 9;
    assert_eq!(common::clz(mid_bit as u256, 16), 6);
}

#[test]
fun clz_handles_u32_values() {
    let top_bit: u32 = 1u32 << 31;
    assert_eq!(common::clz(top_bit as u256, 32), 0);

    let mid_bit: u32 = 1u32 << 12;
    assert_eq!(common::clz(mid_bit as u256, 32), 19);
}

#[test]
fun clz_handles_u64_values() {
    let top_bit: u64 = 1u64 << 63;
    assert_eq!(common::clz(top_bit as u256, 64), 0);

    let mid_bit: u64 = 1u64 << 40;
    assert_eq!(common::clz(mid_bit as u256, 64), 23);
}

#[test]
fun clz_handles_u128_values() {
    let top_bit: u128 = 1u128 << 127;
    assert_eq!(common::clz(top_bit as u256, 128), 0);

    let mid_bit: u128 = 1u128 << 40;
    assert_eq!(common::clz(mid_bit as u256, 128), 87);
}

// === msb ===

#[test]
fun msb_returns_zero_for_zero() {
    assert_eq!(common::msb(0, 256), 0);
}

#[test]
fun msb_returns_correct_position_for_top_bit_set() {
    // when the most significant bit is set, msb returns 255
    let value = 1 << 255;
    let result = common::msb(value, 256);
    assert_eq!(result, 255);
}

#[test]
fun msb_returns_correct_position_for_max_value() {
    // max value has the top bit set, so msb returns 255
    let max = std::u256::max_value!();
    let result = common::msb(max, 256);
    assert_eq!(result, 255);
}

#[test]
fun msb_counts_middle_bits() {
    let value = 1u256 << 128;
    assert_eq!(common::msb(value, 256), 128);

    let lower_value = 1u256 << 5;
    assert_eq!(common::msb(lower_value, 256), 5);
}

#[test]
fun msb_handles_u8_values() {
    let zero: u8 = 0;
    assert_eq!(common::msb(zero as u256, 8), 0);

    let top_bit: u8 = 1u8 << 7;
    assert_eq!(common::msb(top_bit as u256, 8), 7);

    let mid_bit: u8 = 1u8 << 2;
    assert_eq!(common::msb(mid_bit as u256, 8), 2);
}

#[test]
fun msb_handles_u16_values() {
    let top_bit: u16 = 1u16 << 15;
    assert_eq!(common::msb(top_bit as u256, 16), 15);

    let mid_bit: u16 = 1u16 << 9;
    assert_eq!(common::msb(mid_bit as u256, 16), 9);
}

#[test]
fun msb_handles_u32_values() {
    let top_bit: u32 = 1u32 << 31;
    assert_eq!(common::msb(top_bit as u256, 32), 31);

    let mid_bit: u32 = 1u32 << 12;
    assert_eq!(common::msb(mid_bit as u256, 32), 12);
}

#[test]
fun msb_handles_u64_values() {
    let top_bit: u64 = 1u64 << 63;
    assert_eq!(common::msb(top_bit as u256, 64), 63);

    let mid_bit: u64 = 1u64 << 40;
    assert_eq!(common::msb(mid_bit as u256, 64), 40);
}

#[test]
fun msb_handles_u128_values() {
    let top_bit: u128 = 1u128 << 127;
    assert_eq!(common::msb(top_bit as u256, 128), 127);

    let mid_bit: u128 = 1u128 << 40;
    assert_eq!(common::msb(mid_bit as u256, 128), 40);
}

// === sqrt ===

#[test]
fun sqrt_returns_zero_for_zero() {
    assert_eq!(common::sqrt_floor(0), 0);
}

#[test]
fun sqrt_handles_perfect_squares() {
    assert_eq!(common::sqrt_floor(4), 2);
    assert_eq!(common::sqrt_floor(9), 3);
    assert_eq!(common::sqrt_floor(16), 4);
    assert_eq!(common::sqrt_floor(25), 5);
    assert_eq!(common::sqrt_floor(100), 10);
    assert_eq!(common::sqrt_floor(256), 16);
    assert_eq!(common::sqrt_floor(65536), 256);
    assert_eq!(common::sqrt_floor(1 << 64), 1 << 32);
    assert_eq!(common::sqrt_floor(1 << 128), 1 << 64);
}

#[test]
fun sqrt_floors_non_perfect_squares() {
    assert_eq!(common::sqrt_floor(2), 1); // 1.414... → 1
    assert_eq!(common::sqrt_floor(3), 1); // 1.732... → 1
    assert_eq!(common::sqrt_floor(5), 2); // 2.236... → 2
    assert_eq!(common::sqrt_floor(8), 2); // 2.828... → 2
    assert_eq!(common::sqrt_floor(15), 3); // 3.873... → 3
    assert_eq!(common::sqrt_floor(99), 9); // 9.950... → 9
    assert_eq!(common::sqrt_floor(255), 15); // 15.969... → 15
}

#[test]
fun sqrt_handles_u8_values() {
    let zero: u8 = 0;
    assert_eq!(common::sqrt_floor(zero as u256), 0);

    let one: u8 = 1;
    assert_eq!(common::sqrt_floor(one as u256), 1);

    let four: u8 = 4;
    assert_eq!(common::sqrt_floor(four as u256), 2);

    let max: u8 = std::u8::max_value!();
    assert_eq!(common::sqrt_floor(max as u256), 15);
}

#[test]
fun sqrt_handles_u16_values() {
    let perfect: u16 = 256;
    assert_eq!(common::sqrt_floor(perfect as u256), 16);

    let non_perfect: u16 = 1000;
    assert_eq!(common::sqrt_floor(non_perfect as u256), 31);

    let max: u16 = std::u16::max_value!();
    assert_eq!(common::sqrt_floor(max as u256), 255);
}

#[test]
fun sqrt_handles_u32_values() {
    let perfect: u32 = 65536;
    assert_eq!(common::sqrt_floor(perfect as u256), 256);

    let non_perfect: u32 = 1000000;
    assert_eq!(common::sqrt_floor(non_perfect as u256), 1000);

    let max: u32 = std::u32::max_value!();
    assert_eq!(common::sqrt_floor(max as u256), 65535);
}

#[test]
fun sqrt_handles_u64_values() {
    let perfect: u64 = 1 << 32;
    assert_eq!(common::sqrt_floor(perfect as u256), 1 << 16);

    let non_perfect: u64 = 100000000;
    assert_eq!(common::sqrt_floor(non_perfect as u256), 10000);

    let max: u64 = std::u64::max_value!();
    assert_eq!(common::sqrt_floor(max as u256), 4294967295);
}

#[test]
fun sqrt_handles_u128_values() {
    let perfect: u128 = 1 << 64;
    assert_eq!(common::sqrt_floor(perfect as u256), 1 << 32);

    let large: u128 = 1000000000000000000;
    assert_eq!(common::sqrt_floor(large as u256), 1000000000);

    let max: u128 = std::u128::max_value!();
    assert_eq!(common::sqrt_floor(max as u256), std::u64::max_value!() as u256);
}

#[test]
fun sqrt_handles_u256_values() {
    let perfect: u256 = 1 << 128;
    assert_eq!(common::sqrt_floor(perfect), 1 << 64);

    let large: u256 = 1 << 200;
    assert_eq!(common::sqrt_floor(large), 1 << 100);

    let max: u256 = std::u256::max_value!();
    assert_eq!(common::sqrt_floor(max), std::u128::max_value!() as u256);
}

#[test_only]
module openzeppelin_math::median;

use openzeppelin_math::macros;
use std::unit_test::assert_eq;

#[test]
fun median_empty_vector_returns_zero() {
    let vec = vector<u64>[];
    assert_eq!(macros::median!(vec), 0u64);
}

#[test]
fun median_single_element() {
    let vec = vector[42u64];
    assert_eq!(macros::median!(vec), 42u64);
}

#[test]
fun median_odd_length_unsorted() {
    let vec = vector[5u64, 1, 9, 3, 7];
    assert_eq!(macros::median!(vec), 5u64);
}

#[test]
fun median_even_length_unsorted() {
    let vec = vector[10u64, 2, 8, 4];
    assert_eq!(macros::median!(vec), 6u64);
}

#[test]
fun median_even_length_rounds_down() {
    let vec = vector[6u64, 5, 1, 2];
    // (2 + 5) / 2 = 3.5 -> rounds down to 3
    assert_eq!(macros::median!(vec), 3u64);
}

#[test]
fun median_with_duplicates() {
    let vec = vector[2u64, 2, 2, 3, 4];
    assert_eq!(macros::median!(vec), 2u64);
}

#[test]
fun median_supports_u8() {
    let vec = vector[5u8, 1, 9];
    assert_eq!(macros::median!(vec), 5u8);
}

#[test]
fun median_two_elements_unsorted() {
    let vec = vector[9u64, 1];
    assert_eq!(macros::median!(vec), 5u64);
}

#[test]
fun median_two_elements_same_value() {
    let vec = vector[7u64, 7];
    assert_eq!(macros::median!(vec), 7u64);
}

#[test]
fun median_sorted_even_length() {
    let vec = vector[1u64, 3, 5, 7];
    assert_eq!(macros::median!(vec), 4u64);
}

#[test]
fun median_reverse_sorted_odd_length() {
    let vec = vector[9u64, 7, 5, 3, 1];
    assert_eq!(macros::median!(vec), 5u64);
}

#[test]
fun median_with_many_duplicates_even() {
    let vec = vector[4u64, 1, 4, 4, 2, 4];
    assert_eq!(macros::median!(vec), 4u64);
}

#[test]
fun median_even_length_zero_and_max() {
    let vec = vector[0u64, 18446744073709551615];
    // floor(u64::MAX / 2)
    assert_eq!(macros::median!(vec), 9223372036854775807u64);
}

#[test]
fun median_u16_even_length() {
    let vec = vector[100u16, 200, 1, 3];
    assert_eq!(macros::median!(vec), 51u16);
}

#[test]
fun median_u32_odd_length() {
    let vec = vector[1000u32, 1, 500, 3, 7];
    assert_eq!(macros::median!(vec), 7u32);
}

#[test]
fun median_u128_even_length_large_values() {
    let vec = vector[340282366920938463463374607431768211455u128, 0u128];
    assert_eq!(macros::median!(vec), 170141183460469231731687303715884105727u128);
}

#[test]
fun median_u256_odd_length_large_values() {
    let vec = vector[
        0u256,
        115792089237316195423570985008687907853269984665640564039457584007913129639935u256,
        340282366920938463463374607431768211455u256,
    ];
    assert_eq!(macros::median!(vec), 340282366920938463463374607431768211455u256);
}

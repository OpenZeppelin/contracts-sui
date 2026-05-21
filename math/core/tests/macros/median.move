#[test_only]
module openzeppelin_math::median;

use openzeppelin_math::rounding::{Self, RoundingMode};
use openzeppelin_math::vector;
use std::unit_test::assert_eq;

// Helpers for the two workhorse widths. Each test that calls a helper avoids inlining
// `median!`'s body, keeping the test module's total bytecode under Sui's per-package
// arena limit — every `median!` expansion includes the full `quick_sort_by!` stack
// loop plus `average!`'s u256-upcast machinery. Widths used by only a couple of tests
// (`u8`, `u16`, `u32`, `u128`) inline the macro directly.

fun u64_median(vec: vector<u64>, mode: RoundingMode): Option<u64> {
    vector::median!(vec, mode)
}

fun u256_median(vec: vector<u256>, mode: RoundingMode): Option<u256> {
    vector::median!(vec, mode)
}

// === Empty input ===

#[test]
fun median_empty_vector_returns_none() {
    assert!(u64_median(vector<u64>[], rounding::down()).is_none());
}

#[test]
fun median_empty_u8_returns_none() {
    assert!(vector::median!(vector<u8>[], rounding::down()).is_none());
}

#[test]
fun median_empty_u16_returns_none() {
    assert!(vector::median!(vector<u16>[], rounding::down()).is_none());
}

#[test]
fun median_empty_u32_returns_none() {
    assert!(vector::median!(vector<u32>[], rounding::down()).is_none());
}

#[test]
fun median_empty_u128_returns_none() {
    assert!(vector::median!(vector<u128>[], rounding::down()).is_none());
}

#[test]
fun median_empty_u256_returns_none() {
    assert!(u256_median(vector<u256>[], rounding::nearest()).is_none());
}

// === Single-element and small inputs ===

#[test]
fun median_single_element() {
    assert_eq!(u64_median(vector[42u64], rounding::down()).destroy_some(), 42u64);
}

#[test]
fun median_two_elements_unsorted() {
    assert_eq!(u64_median(vector[9u64, 1], rounding::down()).destroy_some(), 5u64);
}

#[test]
fun median_two_elements_same_value() {
    assert_eq!(u64_median(vector[7u64, 7], rounding::down()).destroy_some(), 7u64);
}

// === Odd-length correctness ===

#[test]
fun median_odd_length_unsorted() {
    assert_eq!(u64_median(vector[5u64, 1, 9, 3, 7], rounding::down()).destroy_some(), 5u64);
}

#[test]
fun median_reverse_sorted_odd_length() {
    assert_eq!(u64_median(vector[9u64, 7, 5, 3, 1], rounding::down()).destroy_some(), 5u64);
}

#[test]
fun median_already_sorted_odd() {
    assert_eq!(u64_median(vector[1u64, 2, 3, 4, 5], rounding::down()).destroy_some(), 3u64);
}

#[test]
fun median_odd_length_rounding_mode_irrelevant_down() {
    assert_eq!(u64_median(vector[5u64, 1, 9, 3, 7], rounding::down()).destroy_some(), 5u64);
}

#[test]
fun median_odd_length_rounding_mode_irrelevant_up() {
    assert_eq!(u64_median(vector[5u64, 1, 9, 3, 7], rounding::up()).destroy_some(), 5u64);
}

#[test]
fun median_odd_length_rounding_mode_irrelevant_nearest() {
    assert_eq!(u64_median(vector[5u64, 1, 9, 3, 7], rounding::nearest()).destroy_some(), 5u64);
}

// === Even-length correctness and rounding contract ===

#[test]
fun median_even_length_unsorted() {
    assert_eq!(u64_median(vector[10u64, 2, 8, 4], rounding::down()).destroy_some(), 6u64);
}

#[test]
fun median_even_length_rounds_down() {
    // (2 + 5) / 2 = 3.5 -> rounds down to 3
    assert_eq!(u64_median(vector[6u64, 5, 1, 2], rounding::down()).destroy_some(), 3u64);
}

#[test]
fun median_even_length_rounds_up() {
    // middles 2 and 3 -> ceil((2+3)/2) = 3
    assert_eq!(u64_median(vector[1u64, 2, 3, 4], rounding::up()).destroy_some(), 3u64);
}

#[test]
fun median_even_length_rounds_nearest_half_rounds_up() {
    // (1 + 2) / 2 = 1.5 — rounding::nearest() rounds half-up
    assert_eq!(u64_median(vector[1u64, 2], rounding::nearest()).destroy_some(), 2u64);
}

#[test]
fun median_even_length_nearest_exact_midpoint_down() {
    // sorted: [2, 4, 8, 10]; middles 4, 8 -> (4+8)/2 = 6 exactly. Every rounding
    // mode returns the exact value.
    assert_eq!(u64_median(vector[10u64, 2, 8, 4], rounding::down()).destroy_some(), 6u64);
}

#[test]
fun median_even_length_nearest_exact_midpoint_up() {
    assert_eq!(u64_median(vector[10u64, 2, 8, 4], rounding::up()).destroy_some(), 6u64);
}

#[test]
fun median_even_length_nearest_exact_midpoint_nearest() {
    assert_eq!(u64_median(vector[10u64, 2, 8, 4], rounding::nearest()).destroy_some(), 6u64);
}

#[test]
fun median_sorted_even_length() {
    assert_eq!(u64_median(vector[1u64, 3, 5, 7], rounding::down()).destroy_some(), 4u64);
}

// === Duplicates ===

#[test]
fun median_with_duplicates() {
    assert_eq!(u64_median(vector[2u64, 2, 2, 3, 4], rounding::down()).destroy_some(), 2u64);
}

#[test]
fun median_with_many_duplicates_even() {
    assert_eq!(u64_median(vector[4u64, 1, 4, 4, 2, 4], rounding::down()).destroy_some(), 4u64);
}

// === Constant-vector idempotence ===

#[test]
fun median_constant_vector_down_n3() {
    assert_eq!(u64_median(vector[7u64, 7, 7], rounding::down()).destroy_some(), 7u64);
}

#[test]
fun median_constant_vector_down_n4() {
    assert_eq!(u64_median(vector[7u64, 7, 7, 7], rounding::down()).destroy_some(), 7u64);
}

#[test]
fun median_constant_vector_down_zeros() {
    assert_eq!(u64_median(vector[0u64, 0], rounding::down()).destroy_some(), 0u64);
}

#[test]
fun median_constant_vector_down_u64_max() {
    let max = std::u64::max_value!();
    assert_eq!(u64_median(vector[max, max], rounding::down()).destroy_some(), max);
}

#[test]
fun median_constant_vector_up() {
    assert_eq!(u64_median(vector[42u64, 42], rounding::up()).destroy_some(), 42u64);
}

#[test]
fun median_constant_vector_nearest() {
    assert_eq!(u64_median(vector[42u64, 42], rounding::nearest()).destroy_some(), 42u64);
}

// === Permutation invariance ===

#[test]
fun median_permutation_canonical_odd() {
    assert_eq!(u64_median(vector[1u64, 2, 3, 4, 5], rounding::down()).destroy_some(), 3u64);
}

#[test]
fun median_permutation_shuffled_odd() {
    assert_eq!(u64_median(vector[3u64, 1, 5, 2, 4], rounding::down()).destroy_some(), 3u64);
}

#[test]
fun median_permutation_reversed_odd() {
    assert_eq!(u64_median(vector[5u64, 4, 3, 2, 1], rounding::down()).destroy_some(), 3u64);
}

#[test]
fun median_permutation_canonical_even() {
    assert_eq!(u64_median(vector[1u64, 2, 3, 4], rounding::down()).destroy_some(), 2u64);
}

#[test]
fun median_permutation_shuffled_even() {
    assert_eq!(u64_median(vector[4u64, 1, 3, 2], rounding::down()).destroy_some(), 2u64);
}

#[test]
fun median_permutation_other_shuffle_even() {
    assert_eq!(u64_median(vector[3u64, 4, 2, 1], rounding::down()).destroy_some(), 2u64);
}

// === Overflow safety on even-length resolution ===

#[test]
fun median_even_length_zero_and_max() {
    // floor(u64::MAX / 2)
    assert_eq!(
        u64_median(vector[0, std::u64::max_value!()], rounding::down()).destroy_some(),
        std::u64::max_value!() / 2,
    );
}

#[test]
fun median_even_u256_max_max_down() {
    let max = std::u256::max_value!();
    assert_eq!(u256_median(vector[max, max], rounding::down()).destroy_some(), max);
}

#[test]
fun median_even_u256_max_max_up() {
    let max = std::u256::max_value!();
    assert_eq!(u256_median(vector[max, max], rounding::up()).destroy_some(), max);
}

#[test]
fun median_even_u256_max_max_nearest() {
    let max = std::u256::max_value!();
    assert_eq!(u256_median(vector[max, max], rounding::nearest()).destroy_some(), max);
}

#[test]
fun median_even_u256_zero_and_max_down() {
    // floor(MAX/2) = 2^255 - 1
    let max = std::u256::max_value!();
    let half_floor = std::u256::max_value!() / 2;
    assert_eq!(u256_median(vector[0, max], rounding::down()).destroy_some(), half_floor);
}

#[test]
fun median_even_u256_zero_and_max_up() {
    // ceil(MAX/2) = 2^255
    let max = std::u256::max_value!();
    let half_ceil = std::u256::max_value!() / 2 + 1;
    assert_eq!(u256_median(vector[0, max], rounding::up()).destroy_some(), half_ceil);
}

#[test]
fun median_even_u256_zero_and_max_nearest() {
    // 0.5 tie -> nearest rounds up -> 2^255
    let max = std::u256::max_value!();
    let half_ceil = std::u256::max_value!() / 2 + 1;
    assert_eq!(u256_median(vector[0, max], rounding::nearest()).destroy_some(), half_ceil);
}

// === Per-width sanity checks ===

#[test]
fun median_supports_u8() {
    assert_eq!(vector::median!(vector[5u8, 1, 9], rounding::down()).destroy_some(), 5u8);
}

#[test]
fun median_u16_even_length() {
    assert_eq!(vector::median!(vector[100u16, 200, 1, 3], rounding::down()).destroy_some(), 51u16);
}

#[test]
fun median_u32_odd_length() {
    assert_eq!(
        vector::median!(vector[1000u32, 1, 500, 3, 7], rounding::down()).destroy_some(),
        7u32,
    );
}

#[test]
fun median_u128_even_length_large_values() {
    assert_eq!(
        vector::median!(vector[std::u128::max_value!(), 0], rounding::down()).destroy_some(),
        std::u128::max_value!() / 2,
    );
}

#[test]
fun median_u256_odd_length_large_values() {
    let u128_max_as_u256 = std::u128::max_value!() as u256;
    assert_eq!(
        u256_median(
            vector[0, std::u256::max_value!(), u128_max_as_u256],
            rounding::down(),
        ).destroy_some(),
        u128_max_as_u256,
    );
}

// === Scale ===

#[test]
fun median_large_odd_length() {
    // Build a 1001-element vector [0, 1, ..., 1000] and check median = 500.
    let mut vec = vector<u64>[];
    let mut i = 0u64;
    while (i <= 1000) {
        vec.push_back(i);
        i = i + 1;
    };
    assert_eq!(u64_median(vec, rounding::down()).destroy_some(), 500u64);
}

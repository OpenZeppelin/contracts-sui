#[test_only]
module openzeppelin_math::median;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::{Self, RoundingMode};
use openzeppelin_math::vector;
use std::unit_test::assert_eq;

fun sorted_median_u64(sorted: &vector<u64>, rounding_mode: RoundingMode): u64 {
    let len = sorted.length();
    let mid = len / 2;
    if (len % 2 == 1) {
        sorted[mid]
    } else {
        macros::average!(sorted[mid - 1], sorted[mid], rounding_mode)
    }
}

// === Empty input ===

#[test, expected_failure(abort_code = vector::EEmptyVector)]
fun median_empty_u8_aborts() {
    vector::median!(&vector<u8>[], rounding::down());
}

#[test, expected_failure(abort_code = vector::EEmptyVector)]
fun median_empty_u16_aborts() {
    vector::median!(&vector<u16>[], rounding::down());
}

#[test, expected_failure(abort_code = vector::EEmptyVector)]
fun median_empty_u32_aborts() {
    vector::median!(&vector<u32>[], rounding::down());
}

#[test, expected_failure(abort_code = vector::EEmptyVector)]
fun median_empty_u64_aborts() {
    vector::median!(&vector<u64>[], rounding::down());
}

#[test, expected_failure(abort_code = vector::EEmptyVector)]
fun median_empty_u128_aborts() {
    vector::median!(&vector<u128>[], rounding::down());
}

#[test, expected_failure(abort_code = vector::EEmptyVector)]
fun median_empty_u256_aborts() {
    vector::median!(&vector<u256>[], rounding::nearest());
}

#[test, expected_failure(abort_code = vector::EEmptyVector)]
fun median_u256_empty_aborts() {
    vector::median_u256(vector[], rounding::down());
}

// === Single-element and small inputs ===

#[test]
fun median_single_element() {
    assert_eq!(vector::median!(&vector[42u64], rounding::down()), 42u64);
}

#[test]
fun median_two_elements_unsorted() {
    assert_eq!(vector::median!(&vector[9u64, 1], rounding::down()), 5u64);
}

#[test]
fun median_two_elements_same_value() {
    assert_eq!(vector::median!(&vector[7u64, 7], rounding::down()), 7u64);
}

#[test]
fun median_does_not_mutate_input() {
    let vec = vector[3u64, 1, 2];
    assert_eq!(vector::median!(&vec, rounding::down()), 2u64);
    assert_eq!(vec, vector[3u64, 1, 2]);
}

#[test]
fun median_u256_computes_directly() {
    assert_eq!(vector::median_u256(vector[10u256, 2, 8, 4], rounding::down()), 6u256);
}

#[test]
fun median_u256_computes_odd_directly() {
    assert_eq!(vector::median_u256(vector[9u256, 1, 7, 3, 5], rounding::down()), 5u256);
}

#[test]
fun median_u256_respects_even_rounding_modes() {
    assert_eq!(vector::median_u256(vector[6u256, 5, 1, 2], rounding::down()), 3u256);
    assert_eq!(vector::median_u256(vector[6u256, 5, 1, 2], rounding::nearest()), 4u256);
    assert_eq!(vector::median_u256(vector[6u256, 5, 1, 2], rounding::up()), 4u256);
}

#[test]
fun median_u256_handles_many_duplicates() {
    assert_eq!(vector::median_u256(vector[4u256, 1, 4, 4, 2, 4], rounding::down()), 4u256);
}

#[test]
fun median_u256_handles_extreme_values() {
    let max = std::u256::max_value!();
    assert_eq!(vector::median_u256(vector[0, max], rounding::nearest()), max / 2 + 1);
}

// === Odd-length correctness ===

#[test]
fun median_odd_length_unsorted() {
    assert_eq!(vector::median!(&vector[5u64, 1, 9, 3, 7], rounding::down()), 5u64);
}

#[test]
fun median_reverse_sorted_odd_length() {
    assert_eq!(vector::median!(&vector[9u64, 7, 5, 3, 1], rounding::down()), 5u64);
}

#[test]
fun median_already_sorted_odd() {
    assert_eq!(vector::median!(&vector[1u64, 2, 3, 4, 5], rounding::down()), 3u64);
}

#[random_test]
fun median_odd_length_rounding_modes_agree_u64(mut v: vector<u64>, a: u64, _b: u64) {
    // ensure `v` has odd length
    if (v.is_empty()) {
        v.push_back(a);
    } else if (v.length() % 2 == 0) {
        // pop avoids overflow risk of push if v.length == u64::max
        v.pop_back();
    };

    let down = vector::median!(&v, rounding::down());
    let nearest = vector::median!(&v, rounding::nearest());
    let up = vector::median!(&v, rounding::up());

    assert_eq!(down, nearest);
    assert_eq!(nearest, up);
}

#[random_test]
fun median_matches_sorted_reference_u64(mut v: vector<u64>, a: u64) {
    if (v.is_empty()) {
        v.push_back(a);
    };

    let down = vector::median!(&v, rounding::down());
    let nearest = vector::median!(&v, rounding::nearest());
    let up = vector::median!(&v, rounding::up());

    let mut sorted = v;
    vector::quick_sort!(&mut sorted);

    assert_eq!(down, sorted_median_u64(&sorted, rounding::down()));
    assert_eq!(nearest, sorted_median_u64(&sorted, rounding::nearest()));
    assert_eq!(up, sorted_median_u64(&sorted, rounding::up()));
}

// === Even-length correctness and rounding contract ===

#[test]
fun median_even_length_unsorted() {
    assert_eq!(vector::median!(&vector[10u64, 2, 8, 4], rounding::down()), 6u64);
}

#[test]
fun median_even_length_rounds_down() {
    // (2 + 5) / 2 = 3.5 -> rounds down to 3
    assert_eq!(vector::median!(&vector[6u64, 5, 1, 2], rounding::down()), 3u64);
}

#[test]
fun median_even_length_rounds_up() {
    // middles 2 and 3 -> ceil((2+3)/2) = 3
    assert_eq!(vector::median!(&vector[1u64, 2, 3, 4], rounding::up()), 3u64);
}

#[test]
fun median_even_length_rounds_nearest_half_rounds_up() {
    // (1 + 2) / 2 = 1.5 — rounding::nearest() rounds half-up
    assert_eq!(vector::median!(&vector[1u64, 2], rounding::nearest()), 2u64);
}

#[test]
fun median_even_length_nearest_exact_midpoint_down() {
    // sorted: [2, 4, 8, 10]; middles 4, 8 -> (4+8)/2 = 6 exactly. Every rounding
    // mode returns the exact value.
    assert_eq!(vector::median!(&vector[10u64, 2, 8, 4], rounding::down()), 6u64);
}

#[test]
fun median_even_length_nearest_exact_midpoint_up() {
    assert_eq!(vector::median!(&vector[10u64, 2, 8, 4], rounding::up()), 6u64);
}

#[test]
fun median_even_length_nearest_exact_midpoint_nearest() {
    assert_eq!(vector::median!(&vector[10u64, 2, 8, 4], rounding::nearest()), 6u64);
}

#[test]
fun median_sorted_even_length() {
    assert_eq!(vector::median!(&vector[1u64, 3, 5, 7], rounding::down()), 4u64);
}

#[random_test]
fun median_even_length_rounding_modes_are_monotonic_u64(mut v: vector<u64>, a: u64, b: u64) {
    // ensure `v` has even length (pop avoids overflow risk of push if v.length == u64::max)
    if (v.length() % 2 == 1) { v.pop_back(); };
    // ensure `v` is non-empty
    if (v.is_empty()) {
        v.push_back(a);
        v.push_back(b);
    };

    let down = vector::median!(&v, rounding::down());
    let nearest = vector::median!(&v, rounding::nearest());
    let up = vector::median!(&v, rounding::up());

    assert!(down <= nearest);
    assert!(nearest <= up);
}

// === Duplicates ===

#[test]
fun median_with_duplicates() {
    assert_eq!(vector::median!(&vector[2u64, 2, 2, 3, 4], rounding::down()), 2u64);
}

#[test]
fun median_with_many_duplicates_even() {
    assert_eq!(vector::median!(&vector[4u64, 1, 4, 4, 2, 4], rounding::down()), 4u64);
}

// === Constant-vector idempotence ===

#[test]
fun median_constant_vector_down_n3() {
    assert_eq!(vector::median!(&vector[7u64, 7, 7], rounding::down()), 7u64);
}

#[test]
fun median_constant_vector_down_n4() {
    assert_eq!(vector::median!(&vector[7u64, 7, 7, 7], rounding::down()), 7u64);
}

#[test]
fun median_constant_vector_down_zeros() {
    assert_eq!(vector::median!(&vector[0u64, 0], rounding::down()), 0u64);
}

#[test]
fun median_constant_vector_down_u64_max() {
    let max = std::u64::max_value!();
    assert_eq!(vector::median!(&vector[max, max], rounding::down()), max);
}

#[test]
fun median_constant_vector_up() {
    assert_eq!(vector::median!(&vector[42u64, 42], rounding::up()), 42u64);
}

#[test]
fun median_constant_vector_nearest() {
    assert_eq!(vector::median!(&vector[42u64, 42], rounding::nearest()), 42u64);
}

// === Permutation invariance ===

#[test]
fun median_permutation_canonical_odd() {
    assert_eq!(vector::median!(&vector[1u64, 2, 3, 4, 5], rounding::down()), 3u64);
}

#[test]
fun median_permutation_shuffled_odd() {
    assert_eq!(vector::median!(&vector[3u64, 1, 5, 2, 4], rounding::down()), 3u64);
}

#[test]
fun median_permutation_reversed_odd() {
    assert_eq!(vector::median!(&vector[5u64, 4, 3, 2, 1], rounding::down()), 3u64);
}

#[test]
fun median_permutation_canonical_even() {
    assert_eq!(vector::median!(&vector[1u64, 2, 3, 4], rounding::down()), 2u64);
}

#[test]
fun median_permutation_shuffled_even() {
    assert_eq!(vector::median!(&vector[4u64, 1, 3, 2], rounding::down()), 2u64);
}

#[test]
fun median_permutation_other_shuffle_even() {
    assert_eq!(vector::median!(&vector[3u64, 4, 2, 1], rounding::down()), 2u64);
}

// === Overflow safety on even-length resolution ===

#[test]
fun median_even_u64_zero_and_max_down() {
    // floor(u64::MAX / 2) = 2^63 - 1
    assert_eq!(
        vector::median!(&vector[0, std::u64::max_value!()], rounding::down()),
        std::u64::max_value!() / 2,
    );
}

#[test]
fun median_even_u64_zero_and_max_up() {
    // ceil(u64::MAX / 2) = 2^63
    assert_eq!(
        vector::median!(&vector[0, std::u64::max_value!()], rounding::up()),
        std::u64::max_value!() / 2 + 1,
    );
}

#[test]
fun median_even_u64_zero_and_max_nearest() {
    // 0.5 tie -> nearest rounds up -> 2^63
    assert_eq!(
        vector::median!(&vector[0, std::u64::max_value!()], rounding::nearest()),
        std::u64::max_value!() / 2 + 1,
    );
}

#[test]
fun median_even_u256_max_max_down() {
    let max = std::u256::max_value!();
    assert_eq!(vector::median!(&vector[max, max], rounding::down()), max);
}

#[test]
fun median_even_u256_max_max_up() {
    let max = std::u256::max_value!();
    assert_eq!(vector::median!(&vector[max, max], rounding::up()), max);
}

#[test]
fun median_even_u256_max_max_nearest() {
    let max = std::u256::max_value!();
    assert_eq!(vector::median!(&vector[max, max], rounding::nearest()), max);
}

#[test]
fun median_even_u256_zero_and_max_down() {
    // floor(MAX/2) = 2^255 - 1
    let max = std::u256::max_value!();
    let half_floor = std::u256::max_value!() / 2;
    assert_eq!(vector::median!(&vector[0, max], rounding::down()), half_floor);
}

#[test]
fun median_even_u256_zero_and_max_up() {
    // ceil(MAX/2) = 2^255
    let max = std::u256::max_value!();
    let half_ceil = std::u256::max_value!() / 2 + 1;
    assert_eq!(vector::median!(&vector[0, max], rounding::up()), half_ceil);
}

#[test]
fun median_even_u256_zero_and_max_nearest() {
    // 0.5 tie -> nearest rounds up -> 2^255
    let max = std::u256::max_value!();
    let half_ceil = std::u256::max_value!() / 2 + 1;
    assert_eq!(vector::median!(&vector[0, max], rounding::nearest()), half_ceil);
}

// === Per-width sanity checks ===

#[test]
fun median_supports_u8() {
    assert_eq!(vector::median!(&vector[5u8, 1, 9], rounding::down()), 5u8);
}

#[test]
fun median_u8_even_length_rounds_after_average() {
    assert_eq!(vector::median!(&vector[1u8, 2, 5, 9], rounding::down()), 3u8);
    assert_eq!(vector::median!(&vector[1u8, 2, 5, 9], rounding::nearest()), 4u8);
    assert_eq!(vector::median!(&vector[1u8, 2, 5, 9], rounding::up()), 4u8);
}

#[test]
fun median_u16_even_length() {
    assert_eq!(vector::median!(&vector[100u16, 200, 1, 3], rounding::down()), 51u16);
}

#[test]
fun median_u32_odd_length() {
    assert_eq!(vector::median!(&vector[1000u32, 1, 500, 3, 7], rounding::down()), 7u32);
}

#[test]
fun median_u128_even_length_large_values() {
    assert_eq!(
        vector::median!(&vector[std::u128::max_value!(), 0], rounding::down()),
        std::u128::max_value!() / 2,
    );
}

#[test]
fun median_u256_odd_length_large_values() {
    let u128_max_as_u256 = std::u128::max_value!() as u256;
    assert_eq!(
        vector::median!(&vector[0, std::u256::max_value!(), u128_max_as_u256], rounding::down()),
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
    assert_eq!(vector::median!(&vec, rounding::down()), 500u64);
}

#[test]
fun median_large_even_reverse_sorted_length() {
    // Build a 1000-element vector [1000, 999, ..., 1].
    let mut vec = vector<u64>[];
    let mut i = 1000u64;
    while (i > 0) {
        vec.push_back(i);
        i = i - 1;
    };

    assert_eq!(vector::median!(&vec, rounding::down()), 500u64);
    assert_eq!(vector::median!(&vec, rounding::up()), 501u64);
    assert_eq!(vector::median!(&vec, rounding::nearest()), 501u64);
}

#[test]
fun median_large_duplicate_heavy_vector() {
    // Build 1000 interleaved values with counts: 400 ones, 300 twos, 300 threes.
    let mut vec = vector<u64>[];
    let mut i = 0u64;
    while (i < 1000) {
        let bucket = i % 10;
        if (bucket < 4) {
            vec.push_back(1);
        } else if (bucket < 7) {
            vec.push_back(2);
        } else {
            vec.push_back(3);
        };
        i = i + 1;
    };

    assert_eq!(vector::median!(&vec, rounding::down()), 2u64);
    assert_eq!(vector::median!(&vec, rounding::nearest()), 2u64);
    assert_eq!(vector::median!(&vec, rounding::up()), 2u64);
}

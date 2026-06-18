#[test_only]
module openzeppelin_math::median;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::{Self, RoundingMode};
use openzeppelin_math::vector;
use std::unit_test::assert_eq;

// `median!` inlines the full selection algorithm at every call site, and every expansion counts
// against the test package's VM load budget. The wrappers (`median_u8`..`median_u256`) compile
// the same algorithm once, so the bulk of the behavioral coverage below exercises the wrappers,
// while a compact section instantiates the macro itself at every width.

fun sorted_median_u64(sorted: &vector<u64>, rounding_mode: RoundingMode): u64 {
    let len = sorted.length();
    let mid = len / 2;
    if (len % 2 == 1) {
        sorted[mid]
    } else {
        macros::average!(sorted[mid - 1], sorted[mid], rounding_mode)
    }
}

fun sorted_median_u256(sorted: &vector<u256>, rounding_mode: RoundingMode): u256 {
    let len = sorted.length();
    let mid = len / 2;
    if (len % 2 == 1) {
        sorted[mid]
    } else {
        macros::average!(sorted[mid - 1], sorted[mid], rounding_mode)
    }
}

fun all_modes(): vector<RoundingMode> {
    vector[rounding::down(), rounding::nearest(), rounding::up()]
}

// === Empty input ===

#[test, expected_failure(abort_code = vector::EMedianOfEmptyVector)]
fun median_macro_empty_aborts() {
    vector::median!(&vector<u64>[], rounding::down());
}

#[test, expected_failure(abort_code = vector::EMedianOfEmptyVector)]
fun median_u8_empty_aborts() {
    vector::median_u8(&vector<u8>[], rounding::down());
}

#[test, expected_failure(abort_code = vector::EMedianOfEmptyVector)]
fun median_u16_empty_aborts() {
    vector::median_u16(&vector<u16>[], rounding::down());
}

#[test, expected_failure(abort_code = vector::EMedianOfEmptyVector)]
fun median_u32_empty_aborts() {
    vector::median_u32(&vector<u32>[], rounding::down());
}

#[test, expected_failure(abort_code = vector::EMedianOfEmptyVector)]
fun median_u64_empty_aborts() {
    vector::median_u64(&vector<u64>[], rounding::down());
}

#[test, expected_failure(abort_code = vector::EMedianOfEmptyVector)]
fun median_u128_empty_aborts() {
    vector::median_u128(&vector<u128>[], rounding::nearest());
}

#[test, expected_failure(abort_code = vector::EMedianOfEmptyVector)]
fun median_u256_empty_aborts() {
    vector::median_u256(&vector<u256>[], rounding::up());
}

// === Macro expansion coverage ===
//
// One macro instantiation per width, each cross-checked against the corresponding wrapper for
// every rounding mode on both an odd-length and an even-length input. Wrapper agreement is the
// strongest available oracle: the wrappers run the same expansion compiled in-library, and they
// are independently validated against a sorted reference below.

#[test]
fun median_macro_matches_wrapper_u8() {
    let odd = vector[5u8, 1, 9];
    let even = vector[1u8, 2, 5, 9];
    all_modes().do!(|m| {
        assert_eq!(vector::median!(&odd, m), vector::median_u8(&odd, m));
        assert_eq!(vector::median!(&even, m), vector::median_u8(&even, m));
    });
}

#[test]
fun median_macro_matches_wrapper_u16() {
    let odd = vector[100u16, 200, 1];
    let even = vector[100u16, 200, 1, 3];
    all_modes().do!(|m| {
        assert_eq!(vector::median!(&odd, m), vector::median_u16(&odd, m));
        assert_eq!(vector::median!(&even, m), vector::median_u16(&even, m));
    });
}

#[test]
fun median_macro_matches_wrapper_u32() {
    let odd = vector[1000u32, 1, 500, 3, 7];
    let even = vector[1000u32, 1, 500, 3];
    all_modes().do!(|m| {
        assert_eq!(vector::median!(&odd, m), vector::median_u32(&odd, m));
        assert_eq!(vector::median!(&even, m), vector::median_u32(&even, m));
    });
}

#[test]
fun median_macro_matches_wrapper_u64() {
    let odd = vector[5u64, 1, 9, 3, 7];
    let even = vector[6u64, 5, 1, 2];
    all_modes().do!(|m| {
        assert_eq!(vector::median!(&odd, m), vector::median_u64(&odd, m));
        assert_eq!(vector::median!(&even, m), vector::median_u64(&even, m));
    });
}

#[test]
fun median_macro_matches_wrapper_u128() {
    let odd = vector[std::u128::max_value!(), 0, 7];
    let even = vector[std::u128::max_value!(), 0];
    all_modes().do!(|m| {
        assert_eq!(vector::median!(&odd, m), vector::median_u128(&odd, m));
        assert_eq!(vector::median!(&even, m), vector::median_u128(&even, m));
    });
}

#[test]
fun median_macro_matches_wrapper_u256() {
    let odd = vector[0, std::u256::max_value!(), std::u128::max_value!() as u256];
    let even = vector[0, std::u256::max_value!()];
    all_modes().do!(|m| {
        assert_eq!(vector::median!(&odd, m), vector::median_u256(&odd, m));
        assert_eq!(vector::median!(&even, m), vector::median_u256(&even, m));
    });
}

#[test]
fun median_macro_does_not_mutate_input() {
    let vec = vector[3u64, 1, 2];
    assert_eq!(vector::median!(&vec, rounding::down()), 2u64);
    assert_eq!(vec, vector[3u64, 1, 2]);
}

#[random_test]
fun median_macro_matches_wrapper_random_u64(mut v: vector<u64>, a: u64) {
    if (v.is_empty()) v.push_back(a);
    all_modes().do!(|m| assert_eq!(vector::median!(&v, m), vector::median_u64(&v, m)));
}

// === Single-element and small inputs ===

#[test]
fun median_single_element() {
    assert_eq!(vector::median_u64(&vector[42u64], rounding::down()), 42u64);
}

#[test]
fun median_two_elements_unsorted() {
    assert_eq!(vector::median_u64(&vector[9u64, 1], rounding::down()), 5u64);
}

#[test]
fun median_two_elements_same_value() {
    assert_eq!(vector::median_u64(&vector[7u64, 7], rounding::down()), 7u64);
}

#[test]
fun median_does_not_mutate_input() {
    let vec = vector[3u64, 1, 2];
    assert_eq!(vector::median_u64(&vec, rounding::down()), 2u64);
    assert_eq!(vec, vector[3u64, 1, 2]);
}

#[test]
fun median_u256_does_not_mutate_input() {
    let v = vector[10u256, 2, 8, 4];
    assert_eq!(vector::median_u256(&v, rounding::down()), 6u256);
    assert_eq!(v, vector[10u256, 2, 8, 4]);
}

#[test]
fun median_u256_computes_directly() {
    assert_eq!(vector::median_u256(&vector[10u256, 2, 8, 4], rounding::down()), 6u256);
}

#[test]
fun median_u256_computes_odd_directly() {
    assert_eq!(vector::median_u256(&vector[9u256, 1, 7, 3, 5], rounding::down()), 5u256);
}

#[test]
fun median_u256_respects_even_rounding_modes() {
    let v = vector[6u256, 5, 1, 2];
    assert_eq!(vector::median_u256(&v, rounding::down()), 3u256);
    assert_eq!(vector::median_u256(&v, rounding::nearest()), 4u256);
    assert_eq!(vector::median_u256(&v, rounding::up()), 4u256);
}

#[test]
fun median_u256_handles_many_duplicates() {
    assert_eq!(vector::median_u256(&vector[4u256, 1, 4, 4, 2, 4], rounding::down()), 4u256);
}

#[test]
fun median_u256_handles_extreme_values() {
    let max = std::u256::max_value!();
    assert_eq!(vector::median_u256(&vector[0, max], rounding::nearest()), max / 2 + 1);
}

// === Odd-length correctness ===

#[test]
fun median_odd_length_unsorted() {
    assert_eq!(vector::median_u64(&vector[5u64, 1, 9, 3, 7], rounding::down()), 5u64);
}

#[test]
fun median_reverse_sorted_odd_length() {
    assert_eq!(vector::median_u64(&vector[9u64, 7, 5, 3, 1], rounding::down()), 5u64);
}

#[test]
fun median_already_sorted_odd() {
    assert_eq!(vector::median_u64(&vector[1u64, 2, 3, 4, 5], rounding::down()), 3u64);
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

    let down = vector::median_u64(&v, rounding::down());
    let nearest = vector::median_u64(&v, rounding::nearest());
    let up = vector::median_u64(&v, rounding::up());

    assert_eq!(down, nearest);
    assert_eq!(nearest, up);
}

#[random_test]
fun median_matches_sorted_reference_u64(mut v: vector<u64>, a: u64) {
    if (v.is_empty()) {
        v.push_back(a);
    };

    let down = vector::median_u64(&v, rounding::down());
    let nearest = vector::median_u64(&v, rounding::nearest());
    let up = vector::median_u64(&v, rounding::up());

    let mut sorted = v;
    vector::quick_sort!(&mut sorted);

    assert_eq!(down, sorted_median_u64(&sorted, rounding::down()));
    assert_eq!(nearest, sorted_median_u64(&sorted, rounding::nearest()));
    assert_eq!(up, sorted_median_u64(&sorted, rounding::up()));
}

// === Even-length correctness and rounding contract ===

#[test]
fun median_even_length_unsorted() {
    assert_eq!(vector::median_u64(&vector[10u64, 2, 8, 4], rounding::down()), 6u64);
}

#[test]
fun median_even_length_rounds_down() {
    // (2 + 5) / 2 = 3.5 -> rounds down to 3
    assert_eq!(vector::median_u64(&vector[6u64, 5, 1, 2], rounding::down()), 3u64);
}

#[test]
fun median_even_length_rounds_up() {
    // middles 2 and 3 -> ceil((2+3)/2) = 3
    assert_eq!(vector::median_u64(&vector[1u64, 2, 3, 4], rounding::up()), 3u64);
}

#[test]
fun median_even_length_rounds_nearest_half_rounds_up() {
    // (1 + 2) / 2 = 1.5 - rounding::nearest() rounds half-up
    assert_eq!(vector::median_u64(&vector[1u64, 2], rounding::nearest()), 2u64);
}

#[test]
fun median_even_length_exact_midpoint_all_modes() {
    // sorted: [2, 4, 8, 10]; middles 4, 8 -> (4+8)/2 = 6 exactly. Every rounding mode returns
    // the exact value.
    let v = vector[10u64, 2, 8, 4];
    assert_eq!(vector::median_u64(&v, rounding::down()), 6u64);
    assert_eq!(vector::median_u64(&v, rounding::up()), 6u64);
    assert_eq!(vector::median_u64(&v, rounding::nearest()), 6u64);
}

#[test]
fun median_sorted_even_length() {
    assert_eq!(vector::median_u64(&vector[1u64, 3, 5, 7], rounding::down()), 4u64);
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

    let down = vector::median_u64(&v, rounding::down());
    let nearest = vector::median_u64(&v, rounding::nearest());
    let up = vector::median_u64(&v, rounding::up());

    assert!(down <= nearest);
    assert!(nearest <= up);
}

// === Duplicates ===

#[test]
fun median_with_duplicates() {
    assert_eq!(vector::median_u64(&vector[2u64, 2, 2, 3, 4], rounding::down()), 2u64);
}

#[test]
fun median_with_many_duplicates_even() {
    assert_eq!(vector::median_u64(&vector[4u64, 1, 4, 4, 2, 4], rounding::down()), 4u64);
}

// === Constant-vector idempotence ===

#[test]
fun median_constant_vector_down_n3() {
    assert_eq!(vector::median_u64(&vector[7u64, 7, 7], rounding::down()), 7u64);
}

#[test]
fun median_constant_vector_down_n4() {
    assert_eq!(vector::median_u64(&vector[7u64, 7, 7, 7], rounding::down()), 7u64);
}

#[test]
fun median_constant_vector_down_zeros() {
    assert_eq!(vector::median_u64(&vector[0u64, 0], rounding::down()), 0u64);
}

#[test]
fun median_constant_vector_down_u64_max() {
    let max = std::u64::max_value!();
    assert_eq!(vector::median_u64(&vector[max, max], rounding::down()), max);
}

#[test]
fun median_constant_vector_up() {
    assert_eq!(vector::median_u64(&vector[42u64, 42], rounding::up()), 42u64);
}

#[test]
fun median_constant_vector_nearest() {
    assert_eq!(vector::median_u64(&vector[42u64, 42], rounding::nearest()), 42u64);
}

// === Permutation invariance ===

#[test]
fun median_permutation_invariance_odd() {
    assert_eq!(vector::median_u64(&vector[1u64, 2, 3, 4, 5], rounding::down()), 3u64);
    assert_eq!(vector::median_u64(&vector[3u64, 1, 5, 2, 4], rounding::down()), 3u64);
    assert_eq!(vector::median_u64(&vector[5u64, 4, 3, 2, 1], rounding::down()), 3u64);
}

#[test]
fun median_permutation_invariance_even() {
    assert_eq!(vector::median_u64(&vector[1u64, 2, 3, 4], rounding::down()), 2u64);
    assert_eq!(vector::median_u64(&vector[4u64, 1, 3, 2], rounding::down()), 2u64);
    assert_eq!(vector::median_u64(&vector[3u64, 4, 2, 1], rounding::down()), 2u64);
}

// === Overflow safety on even-length resolution ===

#[test]
fun median_even_u64_zero_and_max() {
    let max = std::u64::max_value!();
    // floor(u64::MAX / 2) = 2^63 - 1; the 0.5 tie rounds up to 2^63 for `up` and `nearest`.
    assert_eq!(vector::median_u64(&vector[0, max], rounding::down()), max / 2);
    assert_eq!(vector::median_u64(&vector[0, max], rounding::up()), max / 2 + 1);
    assert_eq!(vector::median_u64(&vector[0, max], rounding::nearest()), max / 2 + 1);
}

#[test]
fun median_even_u256_max_max() {
    // Averaging the maximum value with itself must not overflow in any mode.
    let max = std::u256::max_value!();
    assert_eq!(vector::median_u256(&vector[max, max], rounding::down()), max);
    assert_eq!(vector::median_u256(&vector[max, max], rounding::up()), max);
    assert_eq!(vector::median_u256(&vector[max, max], rounding::nearest()), max);
}

#[test]
fun median_even_u256_zero_and_max() {
    let max = std::u256::max_value!();
    // floor(MAX/2) = 2^255 - 1; the 0.5 tie rounds up to 2^255 for `up` and `nearest`.
    assert_eq!(vector::median_u256(&vector[0, max], rounding::down()), max / 2);
    assert_eq!(vector::median_u256(&vector[0, max], rounding::up()), max / 2 + 1);
    assert_eq!(vector::median_u256(&vector[0, max], rounding::nearest()), max / 2 + 1);
}

// === Per-width wrapper coverage ===

#[test]
fun median_u8_basics() {
    assert_eq!(vector::median_u8(&vector[42u8], rounding::down()), 42);
    assert_eq!(vector::median_u8(&vector[5u8, 1, 9], rounding::down()), 5);
    // even-length rounding contract
    assert_eq!(vector::median_u8(&vector[1u8, 2, 5, 9], rounding::down()), 3);
    assert_eq!(vector::median_u8(&vector[1u8, 2, 5, 9], rounding::nearest()), 4);
    assert_eq!(vector::median_u8(&vector[1u8, 2, 5, 9], rounding::up()), 4);
    // duplicates and width extremes
    assert_eq!(vector::median_u8(&vector[2u8, 2, 2, 3, 4], rounding::down()), 2);
    let max = std::u8::max_value!();
    assert_eq!(vector::median_u8(&vector[0u8, max], rounding::down()), max / 2);
    assert_eq!(vector::median_u8(&vector[0u8, max], rounding::up()), max / 2 + 1);
}

#[test]
fun median_u16_basics() {
    assert_eq!(vector::median_u16(&vector[100u16, 200, 1, 3], rounding::down()), 51);
    assert_eq!(vector::median_u16(&vector[5u16, 1, 9, 3, 7], rounding::down()), 5);
    let max = std::u16::max_value!();
    assert_eq!(vector::median_u16(&vector[0u16, max], rounding::up()), max / 2 + 1);
}

#[test]
fun median_u32_basics() {
    assert_eq!(vector::median_u32(&vector[1000u32, 1, 500, 3, 7], rounding::down()), 7);
    assert_eq!(vector::median_u32(&vector[10u32, 2, 8, 4], rounding::down()), 6);
    let max = std::u32::max_value!();
    assert_eq!(vector::median_u32(&vector[0u32, max], rounding::nearest()), max / 2 + 1);
}

#[test]
fun median_u128_basics() {
    assert_eq!(
        vector::median_u128(&vector[std::u128::max_value!(), 0], rounding::down()),
        std::u128::max_value!() / 2,
    );
    assert_eq!(vector::median_u128(&vector[4u128, 1, 4, 4, 2, 4], rounding::down()), 4);
    // width extreme: the 0.5 tie rounds up under `up` and `nearest`, and must not overflow
    let max = std::u128::max_value!();
    assert_eq!(vector::median_u128(&vector[0u128, max], rounding::up()), max / 2 + 1);
    assert_eq!(vector::median_u128(&vector[0u128, max], rounding::nearest()), max / 2 + 1);
}

#[test]
fun median_u16_even_length_rounding_modes() {
    // sorted: [1, 2, 5, 9]; central pair (2, 5) -> (2 + 5) / 2 = 3.5
    assert_eq!(vector::median_u16(&vector[1u16, 2, 5, 9], rounding::down()), 3);
    assert_eq!(vector::median_u16(&vector[1u16, 2, 5, 9], rounding::nearest()), 4);
    assert_eq!(vector::median_u16(&vector[1u16, 2, 5, 9], rounding::up()), 4);
}

#[test]
fun median_u32_even_length_rounding_modes() {
    assert_eq!(vector::median_u32(&vector[1u32, 2, 5, 9], rounding::down()), 3);
    assert_eq!(vector::median_u32(&vector[1u32, 2, 5, 9], rounding::nearest()), 4);
    assert_eq!(vector::median_u32(&vector[1u32, 2, 5, 9], rounding::up()), 4);
}

#[test]
fun median_u128_even_length_rounding_modes() {
    // sorted: [1, 2, 5, 9]; central pair (2, 5) -> (2 + 5) / 2 = 3.5
    assert_eq!(vector::median_u128(&vector[1u128, 2, 5, 9], rounding::down()), 3);
    assert_eq!(vector::median_u128(&vector[1u128, 2, 5, 9], rounding::nearest()), 4);
    assert_eq!(vector::median_u128(&vector[1u128, 2, 5, 9], rounding::up()), 4);
}

#[test]
fun median_odd_length_rounding_modes_agree_u16() {
    let v = vector[5u16, 1, 9, 3, 7];
    assert_eq!(
        vector::median_u16(&v, rounding::down()),
        vector::median_u16(&v, rounding::nearest()),
    );
    assert_eq!(vector::median_u16(&v, rounding::nearest()), vector::median_u16(&v, rounding::up()));
    assert_eq!(vector::median_u16(&v, rounding::down()), 5);
}

#[test]
fun median_odd_length_rounding_modes_agree_u32() {
    let v = vector[5u32, 1, 9, 3, 7];
    assert_eq!(
        vector::median_u32(&v, rounding::down()),
        vector::median_u32(&v, rounding::nearest()),
    );
    assert_eq!(vector::median_u32(&v, rounding::nearest()), vector::median_u32(&v, rounding::up()));
    assert_eq!(vector::median_u32(&v, rounding::down()), 5);
}

#[test]
fun median_odd_length_rounding_modes_agree_u128() {
    let v = vector[5u128, 1, 9, 3, 7];
    assert_eq!(
        vector::median_u128(&v, rounding::down()),
        vector::median_u128(&v, rounding::nearest()),
    );
    assert_eq!(
        vector::median_u128(&v, rounding::nearest()),
        vector::median_u128(&v, rounding::up()),
    );
    assert_eq!(vector::median_u128(&v, rounding::down()), 5);
}

// === Randomized per-width wrapper cross-checks against the u64 reference path ===

#[random_test]
fun median_u8_matches_widened_u64(mut v: vector<u8>, a: u8) {
    if (v.is_empty()) v.push_back(a);
    let widened = v.map_ref!(|x| *x as u64);
    all_modes().do!(
        |m| assert_eq!(vector::median_u8(&v, m) as u64, vector::median_u64(&widened, m)),
    );
}

#[random_test]
fun median_u16_matches_widened_u64(mut v: vector<u16>, a: u16) {
    if (v.is_empty()) v.push_back(a);
    let widened = v.map_ref!(|x| *x as u64);
    all_modes().do!(
        |m| assert_eq!(vector::median_u16(&v, m) as u64, vector::median_u64(&widened, m)),
    );
}

#[random_test]
fun median_u32_matches_widened_u64(mut v: vector<u32>, a: u32) {
    if (v.is_empty()) v.push_back(a);
    let widened = v.map_ref!(|x| *x as u64);
    all_modes().do!(
        |m| assert_eq!(vector::median_u32(&v, m) as u64, vector::median_u64(&widened, m)),
    );
}

#[random_test]
fun median_u64_matches_widened_u128(mut v: vector<u64>, a: u64) {
    if (v.is_empty()) v.push_back(a);
    let widened = v.map_ref!(|x| *x as u128);
    all_modes().do!(
        |m| assert_eq!(vector::median_u64(&v, m) as u128, vector::median_u128(&widened, m)),
    );
}

#[random_test]
fun median_u128_matches_widened_u256(mut v: vector<u128>, a: u128) {
    if (v.is_empty()) v.push_back(a);
    let widened = v.map_ref!(|x| *x as u256);
    all_modes().do!(
        |m| assert_eq!(vector::median_u128(&v, m) as u256, vector::median_u256(&widened, m)),
    );
}

#[random_test]
fun median_u256_matches_macro(mut v: vector<u256>, a: u256) {
    if (v.is_empty()) v.push_back(a);
    all_modes().do!(|m| assert_eq!(vector::median_u256(&v, m), vector::median!(&v, m)));
}

#[random_test]
fun median_matches_sorted_reference_u256(mut v: vector<u256>, a: u256) {
    // Independent full-range oracle for the widest type: sort a copy and read the central
    // values directly. This anchors the widening cross-check chain (u8..u128 are compared
    // upward, ending at u256), so the whole web rests on a reference that is not quickselect.
    if (v.is_empty()) v.push_back(a);
    let mut sorted = v;
    vector::quick_sort!(&mut sorted);
    all_modes().do!(|m| assert_eq!(vector::median_u256(&v, m), sorted_median_u256(&sorted, m)));
}

#[random_test]
fun median_is_a_central_order_statistic_u64(mut v: vector<u64>, a: u64) {
    // Oracle-free property: for an odd-length vector, no more than half the elements may sit
    // strictly below the median, and no more than half strictly above it.
    if (v.is_empty()) {
        v.push_back(a);
    } else if (v.length() % 2 == 0) {
        // pop avoids overflow risk of push if v.length == u64::max
        v.pop_back();
    };

    let m = vector::median_u64(&v, rounding::down());
    let half = v.length() / 2;
    let mut below = 0;
    let mut above = 0;
    v.do_ref!(|x| {
        if (*x < m) below = below + 1;
        if (*x > m) above = above + 1;
    });
    assert!(below <= half);
    assert!(above <= half);
}

// === Quickselect base-case boundary (n = 10 vs n = 11) ===
//
// The selection loop switches to insertion sort when the active range is `<= 10`. A 10-element
// vector is resolved entirely by the insertion-sort base case; an 11-element vector forces at
// least one median-of-three + three-way-partition step first. Both shuffled inputs sort to
// [1, 2, ..., n].

#[test]
fun median_boundary_n10_insertion_sort_base_case() {
    // sorted: [1..10]; even length -> average of 5th and 6th order statistics (5, 6).
    let v = vector[9u64, 2, 7, 4, 1, 8, 3, 6, 5, 10];
    assert_eq!(vector::median_u64(&v, rounding::down()), 5);
    assert_eq!(vector::median_u64(&v, rounding::nearest()), 6);
    assert_eq!(vector::median_u64(&v, rounding::up()), 6);
}

#[test]
fun median_boundary_n11_forces_partition_step() {
    // sorted: [1..11]; odd length -> central order statistic is 6.
    let v = vector[9u64, 2, 7, 4, 1, 8, 3, 6, 5, 11, 10];
    assert_eq!(vector::median_u64(&v, rounding::down()), 6);
    assert_eq!(vector::median_u64(&v, rounding::nearest()), 6);
    assert_eq!(vector::median_u64(&v, rounding::up()), 6);
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
    assert_eq!(vector::median_u64(&vec, rounding::down()), 500u64);
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

    assert_eq!(vector::median_u64(&vec, rounding::down()), 500u64);
    assert_eq!(vector::median_u64(&vec, rounding::up()), 501u64);
    assert_eq!(vector::median_u64(&vec, rounding::nearest()), 501u64);
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

    assert_eq!(vector::median_u64(&vec, rounding::down()), 2u64);
    assert_eq!(vector::median_u64(&vec, rounding::nearest()), 2u64);
    assert_eq!(vector::median_u64(&vec, rounding::up()), 2u64);
}

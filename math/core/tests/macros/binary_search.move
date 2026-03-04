#[test_only]
module openzeppelin_math::binary_search;

use openzeppelin_math::macros;
use std::unit_test::assert_eq;

#[test]
fun binary_search_finds_element_at_beginning() {
    let haystack = vector[1u64, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    assert_eq!(macros::binary_search!(haystack, 1u64), true);
}

#[test]
fun binary_search_finds_element_at_end() {
    let haystack = vector[1u64, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    assert_eq!(macros::binary_search!(haystack, 10u64), true);
}

#[test]
fun binary_search_finds_element_in_middle() {
    let haystack = vector[1u64, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    assert_eq!(macros::binary_search!(haystack, 5u64), true);
    assert_eq!(macros::binary_search!(haystack, 6u64), true);
}

#[test]
fun binary_search_finds_all_elements() {
    let haystack = vector[10u32, 20, 30, 40, 50];
    assert_eq!(macros::binary_search!(haystack, 10u32), true);
    assert_eq!(macros::binary_search!(haystack, 20u32), true);
    assert_eq!(macros::binary_search!(haystack, 30u32), true);
    assert_eq!(macros::binary_search!(haystack, 40u32), true);
    assert_eq!(macros::binary_search!(haystack, 50u32), true);
}

#[test]
fun binary_search_returns_false_for_missing_element() {
    let haystack = vector[1u64, 3, 5, 7, 9];
    assert_eq!(macros::binary_search!(haystack, 2u64), false);
    assert_eq!(macros::binary_search!(haystack, 4u64), false);
    assert_eq!(macros::binary_search!(haystack, 6u64), false);
    assert_eq!(macros::binary_search!(haystack, 8u64), false);
}

#[test]
fun binary_search_returns_false_for_value_below_range() {
    let haystack = vector[10u64, 20, 30, 40, 50];
    assert_eq!(macros::binary_search!(haystack, 0u64), false);
    assert_eq!(macros::binary_search!(haystack, 5u64), false);
    assert_eq!(macros::binary_search!(haystack, 9u64), false);
}

#[test]
fun binary_search_returns_false_for_value_above_range() {
    let haystack = vector[10u64, 20, 30, 40, 50];
    assert_eq!(macros::binary_search!(haystack, 51u64), false);
    assert_eq!(macros::binary_search!(haystack, 60u64), false);
    assert_eq!(macros::binary_search!(haystack, 100u64), false);
}

#[test]
fun binary_search_handles_empty_vector() {
    let haystack = vector<u64>[];
    assert_eq!(macros::binary_search!(haystack, 0u64), false);
    assert_eq!(macros::binary_search!(haystack, 1u64), false);
}

#[test]
fun binary_search_handles_single_element_found() {
    let haystack = vector[42u64];
    assert_eq!(macros::binary_search!(haystack, 42u64), true);
}

#[test]
fun binary_search_handles_single_element_not_found() {
    let haystack = vector[42u64];
    assert_eq!(macros::binary_search!(haystack, 41u64), false);
    assert_eq!(macros::binary_search!(haystack, 43u64), false);
}

#[test]
fun binary_search_handles_two_elements() {
    let haystack = vector[10u64, 20];
    assert_eq!(macros::binary_search!(haystack, 10u64), true);
    assert_eq!(macros::binary_search!(haystack, 20u64), true);
    assert_eq!(macros::binary_search!(haystack, 5u64), false);
    assert_eq!(macros::binary_search!(haystack, 15u64), false);
    assert_eq!(macros::binary_search!(haystack, 25u64), false);
}

#[test]
fun binary_search_handles_duplicates() {
    let haystack = vector[1u64, 2, 2, 2, 3];
    assert_eq!(macros::binary_search!(haystack, 2u64), true);
    assert_eq!(macros::binary_search!(haystack, 1u64), true);
    assert_eq!(macros::binary_search!(haystack, 3u64), true);
}

#[test]
fun binary_search_works_with_u8() {
    let haystack = vector[1u8, 10, 20, 30, 40, 50, 100, 200, 255];
    assert_eq!(macros::binary_search!(haystack, 1u8), true);
    assert_eq!(macros::binary_search!(haystack, 30u8), true);
    assert_eq!(macros::binary_search!(haystack, 255u8), true);
    assert_eq!(macros::binary_search!(haystack, 25u8), false);
}

#[test]
fun binary_search_works_with_u16() {
    let haystack = vector[100u16, 1000, 10000, 50000, 65535];
    assert_eq!(macros::binary_search!(haystack, 100u16), true);
    assert_eq!(macros::binary_search!(haystack, 10000u16), true);
    assert_eq!(macros::binary_search!(haystack, 65535u16), true);
    assert_eq!(macros::binary_search!(haystack, 500u16), false);
}

#[test]
fun binary_search_works_with_u32() {
    let haystack = vector[1u32, 1000, 1000000, 1000000000];
    assert_eq!(macros::binary_search!(haystack, 1u32), true);
    assert_eq!(macros::binary_search!(haystack, 1000000u32), true);
    assert_eq!(macros::binary_search!(haystack, 999999u32), false);
}

#[test]
fun binary_search_works_with_u128() {
    let haystack = vector[
        1u128,
        1000,
        1000000,
        1000000000,
        1000000000000,
        340282366920938463463374607431768211455, // max u128
    ];
    assert_eq!(macros::binary_search!(haystack, 1u128), true);
    assert_eq!(macros::binary_search!(haystack, 1000000000000u128), true);
    assert_eq!(macros::binary_search!(haystack, 340282366920938463463374607431768211455u128), true);
    assert_eq!(macros::binary_search!(haystack, 999u128), false);
}

#[test]
fun binary_search_works_with_u256() {
    let haystack = vector[
        1u256,
        1000,
        1000000,
        1000000000,
        1000000000000000000,
        std::u256::max_value!(),
    ];
    assert_eq!(macros::binary_search!(haystack, 1u256), true);
    assert_eq!(macros::binary_search!(haystack, 1000000000u256), true);
    assert_eq!(macros::binary_search!(haystack, std::u256::max_value!()), true);
    assert_eq!(macros::binary_search!(haystack, 999u256), false);
}

#[test]
fun binary_search_handles_large_sorted_vector() {
    // Test with a larger vector to ensure binary search efficiency
    let haystack = vector[
        1u64,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
        12,
        13,
        14,
        15,
        16,
        17,
        18,
        19,
        20,
        21,
        22,
        23,
        24,
        25,
        26,
        27,
        28,
        29,
        30,
    ];
    assert_eq!(macros::binary_search!(haystack, 1u64), true);
    assert_eq!(macros::binary_search!(haystack, 15u64), true);
    assert_eq!(macros::binary_search!(haystack, 30u64), true);
    assert_eq!(macros::binary_search!(haystack, 16u64), true);
    assert_eq!(macros::binary_search!(haystack, 0u64), false);
    assert_eq!(macros::binary_search!(haystack, 31u64), false);
}

#[test]
fun binary_search_handles_powers_of_ten() {
    // Test with actual powers of 10 like in is_power_of_ten
    let powers = vector[
        1u64,
        10,
        100,
        1000,
        10000,
        100000,
        1000000,
        10000000,
        100000000,
        1000000000,
        10000000000,
        100000000000,
        1000000000000,
        10000000000000,
        100000000000000,
        1000000000000000,
        10000000000000000,
        100000000000000000,
        1000000000000000000,
        10000000000000000000,
    ];

    // All powers should be found
    assert_eq!(macros::binary_search!(powers, 1u64), true);
    assert_eq!(macros::binary_search!(powers, 10u64), true);
    assert_eq!(macros::binary_search!(powers, 1000u64), true);
    assert_eq!(macros::binary_search!(powers, 1000000u64), true);
    assert_eq!(macros::binary_search!(powers, 10000000000000000000u64), true);

    // Non-powers should not be found
    assert_eq!(macros::binary_search!(powers, 2u64), false);
    assert_eq!(macros::binary_search!(powers, 11u64), false);
    assert_eq!(macros::binary_search!(powers, 999u64), false);
    assert_eq!(macros::binary_search!(powers, 1001u64), false);
    assert_eq!(macros::binary_search!(powers, 9999u64), false);
}

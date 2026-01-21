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

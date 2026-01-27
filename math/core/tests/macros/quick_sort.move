#[test_only]
module openzeppelin_math::quick_sort;

use openzeppelin_math::vector;
use std::unit_test::assert_eq;

// === quick_sort ===

#[test]
fun quick_sort_empty_vector() {
    // Sorting an empty vector should remain empty
    let mut vec = vector<u64>[];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector<u64>[]);
}

#[test]
fun quick_sort_single_element() {
    // A vector with a single element should remain unchanged
    let mut vec = vector[42u64];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[42u64]);
}

#[test]
fun quick_sort_two_elements_ascending() {
    // Two elements already in order should remain in order
    let mut vec = vector[1u64, 2];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[1u64, 2]);
}

#[test]
fun quick_sort_two_elements_descending() {
    // Two elements in reverse order should be sorted
    let mut vec = vector[2u64, 1];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[1u64, 2]);
}

#[test]
fun quick_sort_three_elements() {
    // Three elements in random order
    let mut vec = vector[3u64, 1, 2];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[1u64, 2, 3]);
}

#[test]
fun quick_sort_already_sorted() {
    // A vector that is already sorted should remain unchanged
    let mut vec = vector[1u32, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[1u32, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
}

#[test]
fun quick_sort_reverse_sorted() {
    // A vector sorted in reverse order should be fully sorted
    let mut vec = vector[10u32, 9, 8, 7, 6, 5, 4, 3, 2, 1];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[1u32, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
}

#[test]
fun quick_sort_random_small_vector() {
    // Small random vector
    let mut vec = vector[5u64, 2, 8, 1, 9, 3, 7, 4, 6];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[1u64, 2, 3, 4, 5, 6, 7, 8, 9]);
}

#[test]
fun quick_sort_with_duplicates() {
    // Vector with duplicate values
    let mut vec = vector[5u32, 2, 5, 1, 5, 2, 3, 5, 1];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[1u32, 1, 2, 2, 3, 5, 5, 5, 5]);
}

#[test]
fun quick_sort_all_same_values() {
    // Vector where all elements are the same
    let mut vec = vector[7u64, 7, 7, 7, 7, 7, 7];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[7u64, 7, 7, 7, 7, 7, 7]);
}

#[test]
fun quick_sort_two_distinct_values() {
    // Vector with only two distinct values
    let mut vec = vector[2u32, 1, 2, 1, 2, 1, 1, 2];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[1u32, 1, 1, 1, 2, 2, 2, 2]);
}

#[test]
fun quick_sort_medium_vector() {
    // Medium-sized vector with random values
    let mut vec = vector[45u64, 23, 87, 12, 56, 34, 78, 90, 11, 33, 22, 67, 88, 15, 42];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[11u64, 12, 15, 22, 23, 33, 34, 42, 45, 56, 67, 78, 87, 88, 90]);
}

#[test]
fun quick_sort_large_vector() {
    // Larger vector with random values
    let mut vec = vector[
        100u64,
        50,
        75,
        25,
        90,
        10,
        85,
        35,
        60,
        45,
        70,
        15,
        80,
        40,
        55,
        20,
        65,
        30,
        95,
        5,
        68,
        37,
        58,
        48,
        72,
        18,
        82,
        38,
        57,
        47,
    ];
    vector::quick_sort!(&mut vec);
    assert_eq!(
        vec,
        vector[
            5u64,
            10,
            15,
            18,
            20,
            25,
            30,
            35,
            37,
            38,
            40,
            45,
            47,
            48,
            50,
            55,
            57,
            58,
            60,
            65,
            68,
            70,
            72,
            75,
            80,
            82,
            85,
            90,
            95,
            100,
        ],
    );
}

#[test]
fun quick_sort_u8_values() {
    // Test with u8 type
    let mut vec = vector[255u8, 127, 0, 64, 192, 32, 96, 200];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[0u8, 32, 64, 96, 127, 192, 200, 255]);
}

#[test]
fun quick_sort_u16_values() {
    // Test with u16 type
    let mut vec = vector[65535u16, 32768, 0, 16384, 49152, 8192, 24576, 57344];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[0u16, 8192, 16384, 24576, 32768, 49152, 57344, 65535]);
}

#[test]
fun quick_sort_u32_values() {
    // Test with u32 type
    let mut vec = vector[1000000u32, 500000, 250000, 750000, 100, 50, 900000, 200];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[50u32, 100, 200, 250000, 500000, 750000, 900000, 1000000]);
}

#[test]
fun quick_sort_u128_values() {
    // Test with u128 type
    let mut vec = vector[
        1000000000000u128,
        500000000000,
        250000000000,
        750000000000,
        100,
        50,
        900000000000,
        200,
    ];
    vector::quick_sort!(&mut vec);
    assert_eq!(
        vec,
        vector[
            50u128,
            100,
            200,
            250000000000,
            500000000000,
            750000000000,
            900000000000,
            1000000000000,
        ],
    );
}

#[test]
fun quick_sort_u256_values() {
    // Test with u256 type
    let mut vec = vector[
        1000000000000000000u256,
        500000000000000000,
        250000000000000000,
        750000000000000000,
        100,
        50,
        900000000000000000,
        200,
    ];
    vector::quick_sort!(&mut vec);
    assert_eq!(
        vec,
        vector[
            50u256,
            100,
            200,
            250000000000000000,
            500000000000000000,
            750000000000000000,
            900000000000000000,
            1000000000000000000,
        ],
    );
}

#[test]
fun quick_sort_partition_edge_case_pivot() {
    // Test a case where pivot selection matters
    let mut vec = vector[1u64, 2, 3, 4, 5];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[1u64, 2, 3, 4, 5]);
}

#[test]
fun quick_sort_alternating_values() {
    // Alternating high and low values
    let mut vec = vector[1u64, 100, 2, 99, 3, 98, 4, 97, 5, 96];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[1u64, 2, 3, 4, 5, 96, 97, 98, 99, 100]);
}

#[test]
fun quick_sort_mostly_sorted_with_one_outlier() {
    // Mostly sorted vector with one element out of place at the beginning
    let mut vec = vector[100u64, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[1u64, 2, 3, 4, 5, 6, 7, 8, 9, 10, 100]);
}

#[test]
fun quick_sort_mostly_sorted_with_one_outlier_at_end() {
    // Mostly sorted vector with one element out of place at the end
    let mut vec = vector[1u64, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[0u64, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
}

#[test]
fun quick_sort_saw_tooth_pattern() {
    // Saw-tooth pattern: goes up then down repeatedly
    let mut vec = vector[1u64, 3, 2, 4, 3, 5, 4, 6, 5, 7, 6, 8];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[1u64, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 8]);
}

#[test]
fun quick_sort_ascending_gap_then_descending() {
    // Values go up then have a big gap then go down
    let mut vec = vector[1u64, 2, 3, 100, 99, 98];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[1u64, 2, 3, 98, 99, 100]);
}

#[test]
fun quick_sort_extreme_range_values() {
    // Test with extreme range values
    let mut vec = vector[0u64, std::u64::max_value!(), 1, std::u64::max_value!() - 1];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[0u64, 1, std::u64::max_value!() - 1, std::u64::max_value!()]);
}

#[test]
fun quick_sort_many_duplicates_spread_throughout() {
    // Many duplicate values spread throughout
    let mut vec = vector[5u32, 1, 5, 2, 5, 3, 5, 4, 5, 5];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[1u32, 2, 3, 4, 5, 5, 5, 5, 5, 5]);
}

#[test]
fun quick_sort_pairs_of_duplicates() {
    // Pairs of duplicates
    let mut vec = vector[2u64, 2, 1, 1, 4, 4, 3, 3];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[1u64, 1, 2, 2, 3, 3, 4, 4]);
}

#[test]
fun quick_sort_pyramid_pattern() {
    // Pyramid pattern: increases to middle then decreases
    let mut vec = vector[1u32, 5, 3, 2, 4, 5, 1];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[1u32, 1, 2, 3, 4, 5, 5]);
}

#[test]
fun quick_sort_single_large_value_at_start() {
    // Single large value at the start
    let mut vec = vector[1000u64, 1, 2, 3, 4, 5];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[1u64, 2, 3, 4, 5, 1000]);
}

#[test]
fun quick_sort_single_small_value_at_end() {
    // Single small value at the end
    let mut vec = vector[5u64, 4, 3, 2, 1, 0];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[0u64, 1, 2, 3, 4, 5]);
}

#[test]
fun quick_sort_three_equal_one_different() {
    // Three equal values and one different
    let mut vec = vector[5u64, 5, 5, 1];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[1u64, 5, 5, 5]);
}

#[test]
fun quick_sort_one_different_three_equal() {
    // One different value and three equal
    let mut vec = vector[1u64, 5, 5, 5];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[1u64, 5, 5, 5]);
}

#[test]
fun quick_sort_maintains_stability_like_behavior() {
    // While quicksort is not guaranteed to be stable, verify correct ordering
    let mut vec = vector[3u64, 1, 4, 1, 5, 9, 2, 6, 5, 3];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[1u64, 1, 2, 3, 3, 4, 5, 5, 6, 9]);
}

#[test]
fun quick_sort_very_large_values() {
    // Test with very large u64 values
    let mut vec = vector[
        18446744073709551615u64, // u64::MAX
        9223372036854775808u64, // Near half
        4611686018427387904u64, // Near quarter
        13835058055282163712u64, // Near three-quarters
    ];
    vector::quick_sort!(&mut vec);
    assert_eq!(
        vec,
        vector[
            4611686018427387904u64,
            9223372036854775808u64,
            13835058055282163712u64,
            18446744073709551615u64,
        ],
    );
}

#[test]
fun quick_sort_sequential_with_shuffle() {
    // Sequential values that are shuffled
    let mut vec = vector[7u32, 1, 3, 6, 2, 8, 4, 9, 5, 10];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[1u32, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
}

#[test]
fun quick_sort_nested_ranges() {
    // Multiple ranges: [1-3], [10-12], [20-22]
    let mut vec = vector[22u64, 1, 11, 2, 21, 3, 12, 20, 10];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[1u64, 2, 3, 10, 11, 12, 20, 21, 22]);
}

#[test]
fun quick_sort_binary_like_pattern() {
    // Powers of 2 in random order
    let mut vec = vector[256u32, 1, 4, 32, 2, 128, 8, 64, 16];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[1u32, 2, 4, 8, 16, 32, 64, 128, 256]);
}

#[test]
fun quick_sort_high_to_low_middle_low() {
    // High values first, then low values mixed in middle
    let mut vec = vector[100u64, 90, 80, 5, 10, 70, 15, 60];
    vector::quick_sort!(&mut vec);
    assert_eq!(vec, vector[5u64, 10, 15, 60, 70, 80, 90, 100]);
}

#[test]
fun quick_sort_returns_consistent_results() {
    // Verify that sorting the same vec
    let mut data1 = vector[42u64, 17, 93, 8, 54, 31, 67, 22, 85, 11];
    let mut data2 = vector[42u64, 17, 93, 8, 54, 31, 67, 22, 85, 11];

    vector::quick_sort!(&mut data1);
    vector::quick_sort!(&mut data2);

    assert_eq!(data1, data2);
}

#[test]
fun quick_sort_produces_sorted_output() {
    // Verify output is actually sorted by checking each element <= next element
    let mut vec = vector[89u32, 12, 76, 45, 23, 98, 34, 67, 1, 55];
    vector::quick_sort!(&mut vec);

    let len = vec.length();
    let mut i = 0;
    while (i + 1 < len) {
        assert!(vec[i] <= vec[i + 1]);
        i = i + 1;
    };
}

#[test]
fun quick_sort_preserves_all_elements() {
    // Verify that all original elements are still present after sorting
    let original = vector[7u64, 2, 9, 1, 5, 8, 3, 6, 4];
    let mut sorted = original;
    vector::quick_sort!(&mut sorted);

    // Check that sorted contains all elements from original
    let len = sorted.length();
    assert_eq!(len, original.length());

    // Count occurrences in both vectors
    let mut i = 0;
    while (i < len) {
        let value = sorted[i];

        // Count this value in original
        let mut count_original = 0;
        let mut j = 0;
        while (j < len) {
            if (original[j] == value) {
                count_original = count_original + 1;
            };
            j = j + 1;
        };

        // Count this value in sorted
        let mut count_sorted = 0;
        j = 0;
        while (j < len) {
            if (sorted[j] == value) {
                count_sorted = count_sorted + 1;
            };
            j = j + 1;
        };

        // They should match
        assert_eq!(count_original, count_sorted);
        i = i + 1;
    };
}

// === quick_sort_by ===

#[test]
fun quick_sort_by_descending_basic() {
    // Descending order using a custom comparator
    let mut vec = vector[3u64, 1, 4, 1, 5, 9, 2, 6];
    vector::quick_sort_by!(&mut vec, |x: &u64, y: &u64| *x >= *y);
    assert_eq!(vec, vector[9u64, 6, 5, 4, 3, 2, 1, 1]);
}

#[test]
fun quick_sort_by_descending_duplicates() {
    // Descending order with repeated values
    let mut vec = vector[5u32, 2, 5, 1, 5, 2, 3, 5, 1];
    vector::quick_sort_by!(&mut vec, |x: &u32, y: &u32| *x >= *y);
    assert_eq!(vec, vector[5u32, 5, 5, 5, 3, 2, 2, 1, 1]);
}

#[test]
fun quick_sort_by_descending_already_sorted() {
    // Vector already in descending order remains unchanged
    let mut vec = vector[10u32, 9, 8, 7, 6, 5, 4, 3, 2, 1];
    vector::quick_sort_by!(&mut vec, |x: &u32, y: &u32| *x >= *y);
    assert_eq!(vec, vector[10u32, 9, 8, 7, 6, 5, 4, 3, 2, 1]);
}

#[test_only]
public struct Transfer has copy, drop {
    id: u8, // Transfer identifier
    value: u64, // Transfer value in smallest unit
}

#[test]
fun quick_sort_by_struct_member_ascending() {
    // Sort transfers by value member in ascending order
    let transfer1 = Transfer { id: 1, value: 3000 };
    let transfer2 = Transfer { id: 2, value: 2500 };
    let transfer3 = Transfer { id: 3, value: 3500 };
    let transfer4 = Transfer { id: 4, value: 2000 };

    let mut vec = vector[transfer1, transfer2, transfer3, transfer4];
    vector::quick_sort_by!(&mut vec, |x: &Transfer, y: &Transfer| x.value <= y.value);

    assert_eq!(vec[0].value, 2000);
    assert_eq!(vec[1].value, 2500);
    assert_eq!(vec[2].value, 3000);
    assert_eq!(vec[3].value, 3500);
}

#[test]
fun quick_sort_by_struct_member_descending() {
    // Sort transfers by value member in descending order
    let transfer1 = Transfer { id: 1, value: 3000 };
    let transfer2 = Transfer { id: 2, value: 2500 };
    let transfer3 = Transfer { id: 3, value: 3500 };
    let transfer4 = Transfer { id: 4, value: 2000 };

    let mut vec = vector[transfer1, transfer2, transfer3, transfer4];
    vector::quick_sort_by!(&mut vec, |x: &Transfer, y: &Transfer| x.value >= y.value);

    assert_eq!(vec[0].value, 3500);
    assert_eq!(vec[1].value, 3000);
    assert_eq!(vec[2].value, 2500);
    assert_eq!(vec[3].value, 2000);
}

#[test]
fun quick_sort_by_struct_member_with_duplicates() {
    // Sort transfers by value when multiple have the same value
    let transfer1 = Transfer { id: 1, value: 3000 };
    let transfer2 = Transfer { id: 2, value: 2500 };
    let transfer3 = Transfer { id: 3, value: 3000 };
    let transfer4 = Transfer { id: 4, value: 2500 };
    let transfer5 = Transfer { id: 5, value: 3500 };

    let mut vec = vector[transfer1, transfer2, transfer3, transfer4, transfer5];
    vector::quick_sort_by!(&mut vec, |x: &Transfer, y: &Transfer| x.value <= y.value);

    assert_eq!(vec[0].value, 2500);
    assert_eq!(vec[1].value, 2500);
    assert_eq!(vec[2].value, 3000);
    assert_eq!(vec[3].value, 3000);
    assert_eq!(vec[4].value, 3500);
}

#[test]
fun quick_sort_by_struct_member_already_sorted() {
    // Vector of transfers already sorted by value should remain unchanged
    let transfer1 = Transfer { id: 1, value: 2000 };
    let transfer2 = Transfer { id: 2, value: 2500 };
    let transfer3 = Transfer { id: 3, value: 3000 };
    let transfer4 = Transfer { id: 4, value: 3500 };

    let mut vec = vector[transfer1, transfer2, transfer3, transfer4];
    vector::quick_sort_by!(&mut vec, |x: &Transfer, y: &Transfer| x.value <= y.value);

    assert_eq!(vec[0].value, 2000);
    assert_eq!(vec[1].value, 2500);
    assert_eq!(vec[2].value, 3000);
    assert_eq!(vec[3].value, 3500);
}

#[test]
fun quick_sort_by_struct_member_reverse_sorted() {
    // Vector of transfers in reverse value order should be sorted correctly
    let transfer1 = Transfer { id: 1, value: 3500 };
    let transfer2 = Transfer { id: 2, value: 3000 };
    let transfer3 = Transfer { id: 3, value: 2500 };
    let transfer4 = Transfer { id: 4, value: 2000 };

    let mut vec = vector[transfer1, transfer2, transfer3, transfer4];
    vector::quick_sort_by!(&mut vec, |x: &Transfer, y: &Transfer| x.value <= y.value);

    assert_eq!(vec[0].value, 2000);
    assert_eq!(vec[1].value, 2500);
    assert_eq!(vec[2].value, 3000);
    assert_eq!(vec[3].value, 3500);
}

#[test]
fun quick_sort_by_struct_single_element() {
    // Single transfer in vector
    let transfer = Transfer { id: 1, value: 3000 };
    let mut vec = vector[transfer];
    vector::quick_sort_by!(&mut vec, |x: &Transfer, y: &Transfer| x.value <= y.value);

    assert_eq!(vec.length(), 1);
    assert_eq!(vec[0].value, 3000);
}

#[test]
fun quick_sort_by_struct_member_large_vector() {
    // Larger vector of transfers sorted by value
    let mut vec = vector[
        Transfer { id: 1, value: 4500 },
        Transfer { id: 2, value: 2300 },
        Transfer { id: 3, value: 6700 },
        Transfer { id: 4, value: 1200 },
        Transfer { id: 5, value: 8900 },
        Transfer { id: 6, value: 3400 },
        Transfer { id: 7, value: 5600 },
        Transfer { id: 8, value: 1800 },
    ];

    vector::quick_sort_by!(&mut vec, |x: &Transfer, y: &Transfer| x.value <= y.value);

    assert_eq!(vec[0].value, 1200);
    assert_eq!(vec[1].value, 1800);
    assert_eq!(vec[2].value, 2300);
    assert_eq!(vec[3].value, 3400);
    assert_eq!(vec[4].value, 4500);
    assert_eq!(vec[5].value, 5600);
    assert_eq!(vec[6].value, 6700);
    assert_eq!(vec[7].value, 8900);
}

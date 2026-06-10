module openzeppelin_math::vector;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::RoundingMode;

// === Errors ===

#[error(code = 0)]
const EMedianOfEmptyVector: vector<u8> = "Median of empty vector is undefined";

// === Public Functions ===

/// Sort an unsigned integer vector in-place using the quicksort algorithm.
///
/// NOTE: This is an unstable in-place sort.
///
/// This macro implements the iterative quicksort algorithm with three-way partitioning
/// (Dutch National Flag scheme), which efficiently sorts vectors in-place with `O(n log n)`
/// average-case time complexity. The theoretical worst case is `O(n²)`, but median-of-three
/// pivot selection makes it much less likely for common inputs, while three-way partitioning
/// improves practical performance when duplicate elements are present.
///
/// The macro uses an explicit stack to avoid recursion limitations for `Move` macros, making
/// it suitable for arbitrarily large vectors.
///
/// #### Generics
/// - `$Int`: Any unsigned integer type (`u8`, `u16`, `u32`, `u64`, `u128`, or `u256`).
///
/// #### Parameters
/// - `$vec`: A mutable reference to the vector to be sorted in-place.
///
/// #### Example
/// ```move
/// let mut vec = vector[3u64, 1, 4, 1, 5, 9, 2, 6];
/// vector::quick_sort!(&mut vec);
/// // vec is now [1, 1, 2, 3, 4, 5, 6, 9]
/// ```
public macro fun quick_sort<$Int>($vec: &mut vector<$Int>) {
    quick_sort_by!($vec, |x: &$Int, y: &$Int| *x <= *y)
}

/// Sort a vector in-place using the quicksort algorithm with a custom comparison function.
///
/// NOTE: This is an unstable in-place sort.
///
/// This macro implements the iterative quicksort algorithm with three-way partitioning
/// (Dutch National Flag scheme), which efficiently sorts vectors in-place with `O(n log n)`
/// average-case time complexity. The theoretical worst case is `O(n²)`, but median-of-three
/// pivot selection makes it much less likely for common inputs, while three-way partitioning
/// improves practical performance when duplicate elements are present. Using an incorrect
/// comparator (see `$le` below) can also degrade performance.
///
/// The macro uses an explicit stack to avoid recursion limitations for `Move` macros, making
/// it suitable for arbitrarily large vectors.
///
/// #### Generics
/// - `$T`: Any type that can be compared using the provided comparison function.
///
/// #### Parameters
/// - `$vec`: A mutable reference to the vector to be sorted in-place.
/// - `$le`: A comparison function that takes two references and returns `true` if the first
///   element should be ordered before or equal to the second element. **Must implement
///   non-strict ordering** (i.e., `<=` for ascending, `>=` for descending). Using a strict
///   comparator (e.g., `<` instead of `<=`) defeats three-way partitioning, which can degrade
///   performance to `O(n²)` when duplicate elements are present. Always use non-strict
///   operators to ensure optimal behavior.
///
/// #### Example
/// ```move
/// // Sort in ascending order
/// let mut vec = vector[3u64, 1, 4, 1, 5, 9, 2, 6];
/// vector::quick_sort_by!(&mut vec, |x: &u64, y: &u64| *x <= *y);
/// // vec is now [1, 1, 2, 3, 4, 5, 6, 9]
///
/// // Sort in descending order
/// let mut vec = vector[3u64, 1, 4, 1, 5, 9, 2, 6];
/// vector::quick_sort_by!(&mut vec, |x: &u64, y: &u64| *x >= *y);
/// // vec is now [9, 6, 5, 4, 3, 2, 1, 1]
/// ```
public macro fun quick_sort_by<$T>($vec: &mut vector<$T>, $le: |&$T, &$T| -> bool) {
    let vec = $vec;
    let len = vec.length();

    // Iterative implementation based on stack data structure (vector).
    let mut stack_start = vector[0];
    let mut stack_end = vector[len];

    while (!stack_start.is_empty()) {
        let start = stack_start.pop_back();
        let end = stack_end.pop_back();

        // Empty range: nothing to sort.
        if (start == end) {
            continue
        };
        // Single-element range: already sorted.
        if (start + 1 == end) {
            continue
        };

        // Use insertion sort for small sub-partitions.
        if (end - start <= 10) {
            // Inline insertion sort for the sub-range [start, end).
            let mut i = start + 1;
            while (i < end) {
                let mut j = i;
                while (
                    j != start
                        && $le(&vec[j], &vec[j - 1])
                        && !$le(&vec[j - 1], &vec[j])
                ) {
                    vec.swap(j, j - 1);
                    j = j - 1;
                };
                i = i + 1;
            };
            continue
        };

        // Pivot index is the last element.
        let pivot_index = end - 1;

        // Choose median-of-three (start, mid, pivot_index) as a pivot
        // and place it on the last position.
        let mid = start + (end - start) / 2;
        if ($le(&vec[mid], &vec[start])) {
            vec.swap(start, mid);
        };
        if ($le(&vec[pivot_index], &vec[start])) {
            vec.swap(start, pivot_index)
        };
        if ($le(&vec[mid], &vec[pivot_index])) {
            vec.swap(mid, pivot_index);
        };

        // Three-way partition (Dutch National Flag) around the pivot.
        // Regions: [start, lt) ordered before pivot, [lt, i) equal to pivot, [i, gt) unprocessed,
        // [gt, pivot_index) ordered after pivot.
        // The pivot value is at `pivot_index` (end - 1) and will be moved into the equal region after partitioning.
        let mut lt = start;
        let mut i = start;
        let mut gt = pivot_index; // gt points to pivot_index initially; pivot is excluded from scan.

        while (i < gt) {
            if ($le(&vec[i], &vec[pivot_index])) {
                if ($le(&vec[pivot_index], &vec[i])) {
                    // vec[i] equal to pivot: element belongs in the equal region, just advance `i`.
                    i = i + 1;
                } else {
                    // vec[i] ordered before pivot: swap to the before-pivot region.
                    vec.swap(lt, i);
                    lt = lt + 1;
                    i = i + 1;
                }
            } else {
                // vec[i] ordered after pivot: swap to the after-pivot region.
                gt = gt - 1;
                vec.swap(i, gt);
                // Don't advance `i`; the swapped-in element needs to be examined.
            };
        };

        // Move the pivot from `pivot_index` into the equal region.
        // `gt` is now the start of the after-pivot region, and pivot is at `pivot_index` (== end - 1).
        // Swap pivot with vec[gt] to place it adjacent to the equal region.
        vec.swap(gt, pivot_index);
        // After swap: [start, lt) before pivot, [lt, eq_end) equal to pivot, [eq_end, end) after pivot.
        let eq_end = gt + 1;

        // Push partitions: larger first, smaller second.
        // Since we use pop_back, smaller will be processed first.
        // Stack size will be no longer than O(log(n)).
        let left_size = lt - start;
        let right_size = end - eq_end;

        if (left_size <= right_size) {
            // Left ≤ right: push right (larger) first, left (smaller) second.
            // Skip empty and single-element right partitions.
            if (right_size > 1) {
                stack_start.push_back(eq_end);
                stack_end.push_back(end);
            };

            // Skip empty and single-element left partitions.
            if (left_size > 1) {
                stack_start.push_back(start);
                stack_end.push_back(lt);
            };
        } else {
            // Left > right: push left (larger) first, right (smaller) second.
            // Skip empty and single-element left partitions.
            if (left_size > 1) {
                stack_start.push_back(start);
                stack_end.push_back(lt);
            };

            // Skip empty and single-element right partitions.
            if (right_size > 1) {
                stack_start.push_back(eq_end);
                stack_end.push_back(end);
            };
        };
    };
}

/// Compute the median of an unsigned integer vector.
///
/// For odd-length vectors, the median is the central order statistic and
/// `$rounding_mode` has no effect on the result.
///
/// For even-length vectors, the median is the arithmetic mean of the two central
/// values, rounded according to `$rounding_mode`.
///
/// The input vector is not mutated.
///
/// Median selection uses quickselect over a `u256` working vector instead of
/// sorting the full input. Benchmarks show similar cost for tiny vectors and
/// substantially lower cost than sorting as input size grows.
///
/// #### Generics
/// - `$Int`: Any unsigned integer type (`u8`, `u16`, `u32`, `u64`, `u128`, or `u256`).
///
/// #### Parameters
/// - `$vec`: Reference to the vector whose median is desired.
/// - `$rounding_mode`: Rounding strategy, applied only when the length is even.
///
/// #### Returns
/// - The median of `$vec`.
///
/// #### Aborts
/// - `EMedianOfEmptyVector` if `$vec` is empty.
///
/// #### Example
/// ```move
/// use openzeppelin_math::rounding;
/// use openzeppelin_math::vector;
///
/// let v = vector[3u64, 1, 4, 1, 5, 9, 2, 6];
/// let m = vector::median!(&v, rounding::down());
/// // m == 3
/// ```
public macro fun median<$Int>($vec: &vector<$Int>, $rounding_mode: RoundingMode): $Int {
    let vec = $vec;
    let vec_u256 = vec.map_ref!(|x| *x as u256);
    median_u256(vec_u256, $rounding_mode) as $Int
}

// === Concrete Public Functions ===

/// Compute the median of a `u256` vector with configurable rounding.
///
/// This function consumes and partially reorders `vec`.
///
/// Median selection uses quickselect instead of sorting the full input.
/// Benchmarks show similar cost for tiny vectors and substantially lower cost
/// than sorting as input size grows.
///
/// #### Parameters
/// - `vec`: Vector whose median is desired (consumed).
/// - `rounding_mode`: Rounding strategy, applied only when the length is even.
///
/// #### Returns
/// - The median of `vec`.
///
/// #### Aborts
/// - `EMedianOfEmptyVector` if `vec` is empty.
///
/// #### Example
/// ```move
/// use openzeppelin_math::rounding;
/// use openzeppelin_math::vector;
///
/// let m = vector::median_u256(vector[10u256, 2, 8, 4], rounding::down());
/// // m == 6
/// ```
public fun median_u256(mut vec: vector<u256>, rounding_mode: RoundingMode): u256 {
    let len = vec.length();
    assert!(len != 0, EMedianOfEmptyVector);

    let mid = len / 2;
    if (len % 2 == 1) {
        select_k_u256(&mut vec, mid)
    } else {
        let upper = select_k_u256(&mut vec, mid);
        // Selecting index `mid` leaves all preceding elements less than or equal
        // to `upper`, so the lower central statistic is the prefix maximum.
        let lower = max_prefix_u256(&vec, mid);
        macros::average!(lower, upper, rounding_mode)
    }
}

// === Internal Functions ===

// Return the kth order statistic, partially partitioning `vec` in place.
//
// Quickselect repeatedly partitions the active range around a pivot and keeps
// only the side that can contain index `k`. This avoids sorting the whole vector
// while still placing the selected value at the same index it would occupy in
// sorted order.
fun select_k_u256(vec: &mut vector<u256>, k: u64): u256 {
    let mut start = 0;
    let mut end = vec.length();

    loop {
        if (start + 1 >= end) return vec[k];

        // Use insertion sort as the quickselect base case for small active ranges.
        if (end - start <= 10) {
            insertion_sort_u256_range(vec, start, end);
            return vec[k]
        };

        let pivot_index = end - 1;
        let mid = start + (end - start) / 2;

        // Median-of-three pivot selection using start, middle, and end - 1.
        // The median of those three values is moved into `pivot_index`.
        if (vec[mid] <= vec[start]) {
            vec.swap(start, mid);
        };
        if (vec[pivot_index] <= vec[start]) {
            vec.swap(start, pivot_index)
        };
        if (vec[mid] <= vec[pivot_index]) {
            vec.swap(mid, pivot_index);
        };

        let mut lt = start;
        let mut i = start;
        let mut gt = pivot_index;

        // Three-way partition around the pivot at `pivot_index`.
        //
        // During the scan:
        // - [start, lt) contains values less than the pivot.
        // - [lt, i) contains values equal to the pivot.
        // - [i, gt) is unprocessed.
        // - [gt, pivot_index) contains values greater than the pivot.
        while (i < gt) {
            if (vec[i] <= vec[pivot_index]) {
                if (vec[pivot_index] <= vec[i]) {
                    i = i + 1;
                } else {
                    vec.swap(lt, i);
                    lt = lt + 1;
                    i = i + 1;
                }
            } else {
                gt = gt - 1;
                vec.swap(i, gt);
            };
        };

        // Move the pivot next to the equal region. After this, [lt, eq_end)
        // contains exactly the pivot-equivalent values.
        vec.swap(gt, pivot_index);
        let eq_end = gt + 1;

        // Discard the partitions that cannot contain the kth order statistic.
        if (k < lt) {
            end = lt;
        } else if (k >= eq_end) {
            start = eq_end;
        } else {
            return vec[k]
        };
    }
}

// Sort a half-open sub-range [start, end). Used as the quickselect base case
// for small active ranges.
fun insertion_sort_u256_range(vec: &mut vector<u256>, start: u64, end: u64) {
    let mut i = start + 1;
    while (i < end) {
        let mut j = i;
        while (j != start && vec[j] < vec[j - 1]) {
            vec.swap(j, j - 1);
            j = j - 1;
        };
        i = i + 1;
    };
}

// Return the maximum value in vec[0..end).
//
// For even-length medians, selecting the upper middle index partitions the
// vector enough to guarantee every earlier element is less than or equal to it,
// but that prefix is not sorted. The lower middle value is therefore the maximum
// of the prefix.
fun max_prefix_u256(vec: &vector<u256>, end: u64): u256 {
    let mut max = vec[0];
    let mut i = 1;
    while (i < end) {
        if (max < vec[i]) {
            max = vec[i];
        };
        i = i + 1;
    };
    max
}

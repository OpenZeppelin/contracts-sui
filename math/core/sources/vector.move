module openzeppelin_math::vector;

/// Sort an unsigned integer vector in-place using the quicksort algorithm.
///
/// NOTE: This is an unstable in-place sort.
///
/// This macro implements the iterative quicksort algorithm with the Lomuto partition scheme,
/// which efficiently sorts vectors in-place with `O(n log n)` average-case time complexity and
/// `O(n²)` worst-case complexity, when the smallest or largest element is consistently
/// selected as the pivot.
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
/// macros::quick_sort!(&mut vec);
/// // vec is now [1, 1, 2, 3, 4, 5, 6, 9]
/// ```
public macro fun quick_sort<$Int>($vec: &mut vector<$Int>) {
    quick_sort_by!($vec, |x: &$Int, y: &$Int| *x <= *y)
}

/// Sort a vector in-place using the quicksort algorithm with a custom comparison function.
///
/// NOTE: This is an unstable in-place sort.
///
/// This macro implements the iterative quicksort algorithm with the Lomuto partition scheme,
/// which efficiently sorts vectors in-place with `O(n log n)` average-case time complexity and
/// `O(n²)` worst-case complexity, when the smallest or largest element is consistently
/// selected as the pivot.
///
/// The macro uses an explicit stack to avoid recursion limitations for `Move` macros, making
/// it suitable for arbitrarily large vectors.
///
/// #### Generics
/// - `$Int`: Any type that can be compared using the provided comparison function.
///
/// #### Parameters
/// - `$vec`: A mutable reference to the vector to be sorted in-place.
/// - `$le`: A comparison function that takes two references and returns `true` if the first
///   element should be ordered before or equal to the second element. For ascending order,
///   this should implement "less than or equal to" semantics.
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

        // Ensure we have at least two elements in vector.
        if (start + 1 >= end) {
            continue
        };

        // Pivot index is the last element.
        let pivot_index = end - 1;

        // Choose median-of-three (start, mid, pivot_index) as a pivot
        // and place it on the last position.
        let mid = (start + end) / 2;
        if ($le(&vec[mid], &vec[start])) {
            vec.swap(start, mid);
        };
        if ($le(&vec[pivot_index], &vec[start])) {
            vec.swap(start, pivot_index)
        };
        if ($le(&vec[mid], &vec[pivot_index])) {
            vec.swap(mid, pivot_index);
        };

        // Partition vector around pivot_index.
        let mut i = start;
        let mut j = start;
        while (j < pivot_index) {
            // If second index `j` is smaller (or equal) than pivot,
            if ($le(&vec[j], &vec[pivot_index])) {
                // swap it with element from the first partition.
                vec.swap(i, j);
                i = i + 1;
            };
            j = j + 1;
        };

        // Swap pivot to the partition index. Swapped element will be greater,
        // than a pivot since it was already processed.
        // Index `i` is now partition index.
        vec.swap(i, pivot_index);

        // Push partitions: larger first, smaller second.
        // Since we use pop_back, smaller will be processed first.
        // Stack size will be no longer than O(log(n)).
        let left_size = i - start;
        let right_size = end - (i + 1);

        if (left_size <= right_size) {
            // Left ≤ right: push right (larger) first, left (smaller) second.
            stack_start.push_back(i + 1);
            stack_end.push_back(end);

            stack_start.push_back(start);
            stack_end.push_back(i);
        } else {
            // Left > right: push left (larger) first, right (smaller) second.
            stack_start.push_back(start);
            stack_end.push_back(i);

            stack_start.push_back(i + 1);
            stack_end.push_back(end);
        };
    };
}

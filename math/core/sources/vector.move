module openzeppelin_math::vector;

/// Sort an unsigned integer vector in-place using the quicksort algorithm.
///
/// NOTE: This is an unstable in-place sort.
///
/// This macro implements the iterative quicksort algorithm with three-way partitioning
/// (Dutch National Flag scheme), which efficiently sorts vectors in-place with `O(n log n)`
/// average-case time complexity and `O(n²)` worst-case complexity, when the smallest or
/// largest element is consistently selected as the pivot.
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
/// average-case time complexity and `O(n²)` worst-case complexity, when the smallest or
/// largest element is consistently selected as the pivot.
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

        // Three-way partition (Dutch National Flag) around the pivot.
        // Regions: [start, lt) < pivot, [lt, i) == pivot, [i, gt) unprocessed, [gt, pivot_index) > pivot.
        // The pivot value is at `pivot_index` (end - 1) and will be moved into the equal region after partitioning.
        let mut lt = start;
        let mut i = start;
        let mut gt = pivot_index; // gt points to pivot_index initially; pivot is excluded from scan.

        while (i < gt) {
            if ($le(&vec[i], &vec[pivot_index])) {
                if ($le(&vec[pivot_index], &vec[i])) {
                    // vec[i] == pivot: element is equal, just advance `i`.
                    i = i + 1;
                } else {
                    // vec[i] < pivot: swap to the less-than region.
                    vec.swap(lt, i);
                    lt = lt + 1;
                    i = i + 1;
                }
            } else {
                // vec[i] > pivot: swap to the greater-than region.
                gt = gt - 1;
                vec.swap(i, gt);
                // Don't advance `i`; the swapped-in element needs to be examined.
            };
        };

        // Move the pivot from `pivot_index` into the equal region.
        // `gt` is now the start of the greater-than region, and pivot is at `pivot_index` (== end - 1).
        // Swap pivot with vec[gt] to place it adjacent to the equal region.
        vec.swap(gt, pivot_index);
        // After swap: [start, lt) < pivot, [lt, gt + 1) == pivot, (gt, end) > pivot.
        let eq_end = gt + 1;

        // Push partitions: larger first, smaller second.
        // Since we use pop_back, smaller will be processed first.
        // Stack size will be no longer than O(log(n)).
        let left_size = lt - start;
        let right_size = end - eq_end;

        if (left_size <= right_size) {
            // Left ≤ right: push right (larger) first, left (smaller) second.
            stack_start.push_back(eq_end);
            stack_end.push_back(end);

            stack_start.push_back(start);
            stack_end.push_back(lt);
        } else {
            // Left > right: push left (larger) first, right (smaller) second.
            stack_start.push_back(start);
            stack_end.push_back(lt);

            stack_start.push_back(eq_end);
            stack_end.push_back(end);
        };
    };
}

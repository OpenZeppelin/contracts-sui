/// Vector algorithms for unsigned integers: in-place quicksort and median selection.
module openzeppelin_math::vector;

use openzeppelin_math::rounding::{Self, RoundingMode};

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
/// average-case time complexity. The theoretical worst case is `O(n²)` and remains reachable
/// for adversarially ordered inputs despite median-of-three pivot selection. Three-way
/// partitioning improves practical performance when duplicate elements are present.
///
/// The macro uses an explicit stack to avoid recursion limitations for `Move` macros. Input
/// size is still bounded by transaction gas and memory limits; avoid sorting unbounded vectors,
/// especially when the caller can control the vector contents.
///
/// #### Bytecode vs. gas trade-off
///
/// As a macro, every call site inlines the full sorting algorithm — roughly 750 bytes of
/// compiled bytecode per call. This module ships no precompiled sorting wrappers, so if you
/// sort the same element type from more than one place, wrap the macro in a small function in
/// your own module (e.g. `fun sort(v: &mut vector<u64>) { vector::quick_sort!(v) }`) and call
/// that instead: the expansion is paid once, every additional call site costs only a regular
/// function call with no measurable gas difference, and your module stays well within Sui's
/// cap on the total compiled size of a published package.
///
/// #### Generics
/// - `$Int`: Any unsigned integer type (`u8`, `u16`, `u32`, `u64`, `u128`, or `u256`).
///
/// #### Parameters
/// - `$vec`: A mutable reference to the vector to be sorted in-place.
///
/// #### Example
/// ```move
/// use openzeppelin_math::vector;
///
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
/// average-case time complexity. The theoretical worst case is `O(n²)` and remains reachable
/// for adversarially ordered inputs despite median-of-three pivot selection. Three-way
/// partitioning improves practical performance when duplicate elements are present. Using an
/// incorrect comparator (see `$le` below) can also degrade performance or produce unsorted
/// output.
///
/// The macro uses an explicit stack to avoid recursion limitations for `Move` macros. Input
/// size is still bounded by transaction gas and memory limits; avoid sorting unbounded vectors,
/// especially when the caller can control the vector contents.
///
/// #### Bytecode vs. gas trade-off
///
/// As a macro, every call site inlines the full sorting algorithm together with the comparator —
/// roughly 750 bytes of compiled bytecode per call. A precompiled wrapper cannot live in this
/// library because the comparator is a compile-time lambda, which ordinary functions cannot
/// accept as an argument. If you sort with the same element type and comparator from more than
/// one place, wrap the call in a small function in your own module (e.g.
/// `fun sort_desc(v: &mut vector<u64>) { vector::quick_sort_by!(v, |a, b| *a >= *b) }`): the
/// expansion is paid once, every additional call site costs only a regular function call with no
/// measurable gas difference, and your module stays well within Sui's cap on the total compiled
/// size of a published package.
///
/// #### Generics
/// - `$T`: Any type that can be compared using the provided comparison function.
///
/// #### Parameters
/// - `$vec`: A mutable reference to the vector to be sorted in-place.
/// - `$le`: A comparison function that takes two references and returns `true` if the first
///   element should be ordered before or equal to the second element. **Must implement a
///   consistent total preorder** (i.e., non-strict `<=` for ascending, `>=` for descending).
///   Using a strict comparator (e.g., `<` instead of `<=`) defeats three-way partitioning,
///   which can degrade performance to `O(n²)` when duplicate elements are present. An
///   inconsistent, non-transitive, or non-total comparator is not detected and can silently
///   return a vector that is not sorted according to the intended order. The macro may invoke
///   `$le` twice for a single element probe to distinguish equality from before/after ordering,
///   so account for that when the comparator is expensive.
///
/// #### Example
/// ```move
/// use openzeppelin_math::vector;
///
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
                // The comparator is non-strict, so strict ordering is derived as:
                // a < b iff a <= b and !(b <= a).
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
        // The pivot value is held at `pivot_index` and will be swapped into `gt` after the
        // scan, making the equal region contiguous as [lt, gt + 1).
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
                    // When lt == i, this intentionally relies on swap(i, i) as a no-op.
                    vec.swap(lt, i);
                    lt = lt + 1;
                    i = i + 1;
                }
            } else {
                // vec[i] ordered after pivot: swap to the after-pivot region.
                gt = gt - 1;
                // When i == gt, this intentionally relies on swap(i, i) as a no-op.
                vec.swap(i, gt);
                // Don't advance `i`; the swapped-in element needs to be examined.
            };
        };

        // Move the pivot from `pivot_index` into the equal region.
        // `gt` is now the start of the after-pivot region, and pivot is at `pivot_index` (== end - 1).
        // Swap pivot with vec[gt] to place it adjacent to the equal region.
        // When gt == pivot_index, there is no after-pivot region and the swap is a no-op.
        vec.swap(gt, pivot_index);
        // After swap: [start, lt) before pivot, [lt, eq_end) equal to pivot, [eq_end, end) after pivot.
        let eq_end = gt + 1;

        // Push partitions: larger first, smaller second.
        // Since we use pop_back, smaller will be processed first. This ordering is what keeps
        // the pending stack bounded by O(log(n)).
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
/// For odd-length vectors, the median is the central order statistic and `$rounding_mode` has
/// no effect on the result. For even-length vectors, the median is the arithmetic mean of the
/// two central values, rounded according to `$rounding_mode`.
///
/// The input vector is not mutated: the selection algorithm runs on an internal working copy,
/// so the caller's vector keeps its original order.
///
/// #### Bytecode vs. gas trade-off
///
/// This macro inlines the complete selection algorithm at every call site, which makes it the
/// most gas-efficient form but adds roughly 750–870 bytes of compiled bytecode per call,
/// depending on the integer width. The
/// `median_u8` … `median_u256` functions expose the exact same algorithm precompiled once in
/// this module: calling them costs only a regular function call at the call site. Prefer the
/// wrappers by default; reach for the macro directly when a call site is gas-critical. This
/// matters because Sui caps the total compiled size of a published package, so liberal use of
/// the macro spends that budget quickly.
///
/// Average-case time complexity is `O(n)`, with `O(n)` extra storage for the working copy. The
/// theoretical worst case is `O(n²)` and remains reachable for adversarially ordered inputs
/// despite median-of-three pivot selection. Avoid computing the median of unbounded vectors,
/// especially when the caller can control the vector contents.
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
    let rounding_mode = $rounding_mode;

    // An empty vector has no median. The check delegates to `median_u8`, whose own emptiness
    // assertion raises the module's canonical `EMedianOfEmptyVector`: a public macro expands in
    // the caller's module, where this module's private error constant is not visible, so the
    // abort must come from a public function. Inside `median_u8`, that assertion runs before
    // the code inlined from this macro, so the call below always aborts at runtime and can
    // never recurse.
    if (vec.is_empty()) {
        median_u8(&vector[], rounding_mode);
    };

    let len = vec.length();
    let k = len / 2;

    // Quickselect reorders the values it inspects, so work on a copy. Dereferencing copies the
    // whole vector with a single instruction, which is far cheaper than an element-by-element
    // loop.
    let mut w = *vec;

    // Find the k-th order statistic (the upper of the two central values when `len` is even)
    // with iterative quickselect: partition the active range [start, end) around a pivot, then
    // keep only the side that contains index `k`.
    let mut start = 0;
    let mut end = len;
    let upper = loop {
        if (start + 1 >= end) break w[k];

        // Insertion sort is cheaper than partitioning once the active range is small.
        if (end - start <= 10) {
            let mut i = start + 1;
            while (i < end) {
                let mut j = i;
                while (j != start && w[j] < w[j - 1]) {
                    w.swap(j, j - 1);
                    j = j - 1;
                };
                i = i + 1;
            };
            break w[k]
        };

        // Median-of-three pivot selection over (start, mid, end - 1); the median of those
        // three values ends up at `pivot_index`.
        let pivot_index = end - 1;
        let mid = start + (end - start) / 2;
        if (w[mid] <= w[start]) w.swap(start, mid);
        if (w[pivot_index] <= w[start]) w.swap(start, pivot_index);
        if (w[mid] <= w[pivot_index]) w.swap(mid, pivot_index);

        // The pivot stays at `pivot_index` for the whole scan, so read it into a local once;
        // an indexed read inside the loop would be paid again on every comparison.
        let pivot = w[pivot_index];

        // Three-way (Dutch National Flag) partition. During the scan:
        //   [start, lt)        values less than the pivot
        //   [lt, i)            values equal to the pivot
        //   [i, gt)            unprocessed
        //   [gt, pivot_index)  values greater than the pivot
        let mut lt = start;
        let mut i = start;
        let mut gt = pivot_index;
        while (i < gt) {
            let current = w[i];
            if (current <= pivot) {
                if (pivot <= current) {
                    i = i + 1;
                } else {
                    // When lt == i, this intentionally relies on swap(i, i) being a no-op.
                    w.swap(lt, i);
                    lt = lt + 1;
                    i = i + 1;
                }
            } else {
                gt = gt - 1;
                // When i == gt, this intentionally relies on swap(i, i) being a no-op.
                w.swap(i, gt);
            };
        };

        // Move the pivot next to the equal region, making [lt, eq_end) exactly the
        // pivot-equal values.
        w.swap(gt, pivot_index);
        let eq_end = gt + 1;

        // Drop the partition that cannot contain index `k`; if `k` landed in the equal
        // region, the pivot itself is the answer.
        if (k < lt) {
            end = lt;
        } else if (k >= eq_end) {
            start = eq_end;
        } else {
            break w[k]
        };
    };

    if (len % 2 == 1) {
        // Odd length: the median is the central order statistic and needs no rounding.
        upper
    } else {
        // Even length: the median is the average of the two central values. Selecting index
        // `k` left every preceding element less than or equal to `upper`, so the lower central
        // value is the maximum of the (still unsorted) prefix.
        let mut lower = w[0];
        let mut i = 1;
        while (i < k) {
            if (lower < w[i]) lower = w[i];
            i = i + 1;
        };

        // Average the two central values without overflow by anchoring on `lower` and adding
        // half the gap. The fractional part is either zero or exactly one half, and one half
        // rounds up under both `up` and `nearest`, so only `down` truncates.
        let delta = upper - lower;
        let mut result = lower + delta / 2;
        if (delta % 2 == 1 && rounding_mode != rounding::down()) {
            result = result + 1;
        };
        result
    }
}

/// Compute the median of a `u8` vector with configurable rounding.
///
/// Precompiled wrapper around `median!`: same algorithm, same results, same abort behavior,
/// but the selection bytecode lives in this module instead of being inlined at the call site.
/// The input vector is not mutated. See `median!` for the full contract and the bytecode
/// vs. gas trade-off.
///
/// #### Aborts
/// - `EMedianOfEmptyVector` if `vec` is empty.
public fun median_u8(vec: &vector<u8>, rounding_mode: RoundingMode): u8 {
    assert!(!vec.is_empty(), EMedianOfEmptyVector);
    median!(vec, rounding_mode)
}

/// Compute the median of a `u16` vector with configurable rounding.
///
/// Precompiled wrapper around `median!`: same algorithm, same results, same abort behavior,
/// but the selection bytecode lives in this module instead of being inlined at the call site.
/// The input vector is not mutated. See `median!` for the full contract and the bytecode
/// vs. gas trade-off.
///
/// #### Aborts
/// - `EMedianOfEmptyVector` if `vec` is empty.
public fun median_u16(vec: &vector<u16>, rounding_mode: RoundingMode): u16 {
    assert!(!vec.is_empty(), EMedianOfEmptyVector);
    median!(vec, rounding_mode)
}

/// Compute the median of a `u32` vector with configurable rounding.
///
/// Precompiled wrapper around `median!`: same algorithm, same results, same abort behavior,
/// but the selection bytecode lives in this module instead of being inlined at the call site.
/// The input vector is not mutated. See `median!` for the full contract and the bytecode
/// vs. gas trade-off.
///
/// #### Aborts
/// - `EMedianOfEmptyVector` if `vec` is empty.
public fun median_u32(vec: &vector<u32>, rounding_mode: RoundingMode): u32 {
    assert!(!vec.is_empty(), EMedianOfEmptyVector);
    median!(vec, rounding_mode)
}

/// Compute the median of a `u64` vector with configurable rounding.
///
/// Precompiled wrapper around `median!`: same algorithm, same results, same abort behavior,
/// but the selection bytecode lives in this module instead of being inlined at the call site.
/// The input vector is not mutated. See `median!` for the full contract and the bytecode
/// vs. gas trade-off.
///
/// #### Aborts
/// - `EMedianOfEmptyVector` if `vec` is empty.
public fun median_u64(vec: &vector<u64>, rounding_mode: RoundingMode): u64 {
    assert!(!vec.is_empty(), EMedianOfEmptyVector);
    median!(vec, rounding_mode)
}

/// Compute the median of a `u128` vector with configurable rounding.
///
/// Precompiled wrapper around `median!`: same algorithm, same results, same abort behavior,
/// but the selection bytecode lives in this module instead of being inlined at the call site.
/// The input vector is not mutated. See `median!` for the full contract and the bytecode
/// vs. gas trade-off.
///
/// #### Aborts
/// - `EMedianOfEmptyVector` if `vec` is empty.
public fun median_u128(vec: &vector<u128>, rounding_mode: RoundingMode): u128 {
    assert!(!vec.is_empty(), EMedianOfEmptyVector);
    median!(vec, rounding_mode)
}

/// Compute the median of a `u256` vector with configurable rounding.
///
/// Precompiled wrapper around `median!`: same algorithm, same results, same abort behavior,
/// but the selection bytecode lives in this module instead of being inlined at the call site.
/// The input vector is not mutated. See `median!` for the full contract and the bytecode
/// vs. gas trade-off.
///
/// #### Aborts
/// - `EMedianOfEmptyVector` if `vec` is empty.
public fun median_u256(vec: &vector<u256>, rounding_mode: RoundingMode): u256 {
    assert!(!vec.is_empty(), EMedianOfEmptyVector);
    median!(vec, rounding_mode)
}

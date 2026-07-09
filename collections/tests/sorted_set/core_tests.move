/// Core behavioral suite - the happy-path + boundary behavior of every non-comparator and
/// bare-comparator operation: lifecycle (`new`/`singleton`/`from_keys`), size (`length`/
/// `is_empty`), extremes (`head`/`tail`/`pop_*`), `keys`, ordered navigation, and pagination.
/// Failure modes, polarity, the differential check, comparator footguns, aborts, and types
/// live in their own modules.
module openzeppelin_collections::sorted_set_core_tests;

use openzeppelin_collections::sorted_set as ss;
use openzeppelin_collections::sorted_set_test_util as u;
use std::unit_test::assert_eq;

const U64_MAX: u64 = 18446744073709551615;

// === lifecycle: new / singleton / from_keys ===

#[test]
fun new_empty() {
    // new() takes no ctx, is empty, drops out of scope (no destroy_empty).
    let s = ss::new<u64>();
    assert!(s.is_empty());
    assert_eq!(s.length(), 0);
    assert_eq!(s.head(), option::none());
    assert_eq!(s.tail(), option::none());
    assert_eq!(s.keys(), vector[]);
    assert!(u::wf(&s));
}

#[test]
fun singleton() {
    // One element at index 0, no comparator, trivially well-formed.
    let s = ss::singleton<u64>(42);
    assert_eq!(s.length(), 1);
    assert!(u::has(&s, 42));
    assert_eq!(s.head(), option::some(42));
    assert_eq!(s.tail(), option::some(42));
    assert_eq!(s.keys(), vector[42u64]);
    assert!(u::wf(&s));
}

#[test]
fun singleton_then_second_key() {
    // A singleton is a normal well-formed state - inserting a distinct key grows it.
    let mut s = ss::singleton<u64>(20);
    assert!(u::ins(&mut s, 10)); // smaller -> goes to index 0
    assert_eq!(s.length(), 2);
    assert_eq!(s.keys(), vector[10u64, 20]);
    assert!(u::wf(&s));
    // symmetric: a LARGER second key appends at index 1 (the existing case only covered prepend).
    let mut s2 = ss::singleton<u64>(20);
    assert!(u::ins(&mut s2, 30)); // larger -> appends at index 1
    assert_eq!(s2.keys(), vector[20u64, 30]);
    assert!(u::wf(&s2));
}

#[test]
fun singleton_reinsert_same_key() {
    // Re-inserting the singleton's key is a no-op (false), length stays 1.
    let mut s = ss::singleton<u64>(7);
    assert!(!u::ins(&mut s, 7));
    assert_eq!(s.length(), 1);
    assert!(u::wf(&s));
}

#[test]
fun singleton_non_integer_key() {
    // Singleton needs NO comparator, so it works for a struct key too (index 0).
    let s = ss::singleton<u::Key>(u::mk(5, 99));
    assert_eq!(u::len_k(&s), 1);
    assert!(u::has_k(&s, 5));
    assert!(u::wf_k(&s));
}

#[test]
fun from_keys_dedup() {
    // De-duplicates (distinct count, NOT input length), sorted ascending.
    let s = u::fromk(vector[3u64, 1, 2, 1, 3]);
    assert_eq!(s.length(), 3);
    assert_eq!(s.keys(), vector[1u64, 2, 3]);
    assert!(u::wf(&s));
}

#[test]
fun from_keys_empty_and_singleton() {
    // Boundaries: empty input -> empty set; one key -> singleton-equivalent.
    let s0 = u::fromk(vector[]);
    assert!(s0.is_empty());
    let s1 = u::fromk(vector[5u64]);
    assert!(s1.length() == 1 && u::has(&s1, 5));
    assert!(u::wf(&s1));
}

// === lifecycle: from_sorted_keys (O(N) constructor for pre-sorted input) ===

#[test]
fun from_sorted_builds_ascending_and_dedups() {
    // Sorted input with adjacent duplicates -> distinct keys ascending (dedup like from_keys).
    let s = u::from_sorted(vector[1u64, 2, 2, 3, 3, 3, 5]);
    assert_eq!(s.length(), 4);
    assert_eq!(s.keys(), vector[1u64, 2, 3, 5]);
    assert!(u::wf(&s));
}

#[test]
fun from_sorted_empty_and_singleton() {
    // Boundaries: empty input -> empty set; one key -> singleton-equivalent. No comparator call
    // happens for n < 2, so a single key never touches the sorted check.
    let s0 = u::from_sorted(vector[]);
    assert!(s0.is_empty());
    let s1 = u::from_sorted(vector[9u64]);
    assert!(s1.length() == 1 && u::has(&s1, 9));
    assert!(u::wf(&s1));
}

#[test]
fun from_sorted_matches_from_keys_on_sorted_input() {
    // For any sorted input, from_sorted_keys! must produce EXACTLY what from_keys! does.
    let input = vector[0u64, 1, 1, 2, 4, 4, 4, 7, 9];
    let a = u::from_sorted(input);
    let b = u::fromk(input);
    assert_eq!(a.keys(), b.keys());
    assert_eq!(a.length(), b.length());
    assert!(u::wf(&a));
}

#[test]
fun from_sorted_by_reverse_comparator() {
    // Descending-numeric input is "sorted" (non-decreasing) under `>`; dup 20 collapses.
    let s = u::from_sorted_rev(vector[30u64, 20, 20, 10]);
    assert_eq!(s.length(), 3);
    assert_eq!(s.keys(), vector[30u64, 20, 10]); // stored descending-numeric under `>`
    assert!(u::wf_rev(&s)); // well-formed under `>` ...
    assert!(!u::wf(&s)); // ... but genuinely reversed vs `<`
}

#[test]
fun from_sorted_coarse_keeps_last_bytes() {
    // Under a coarse (id-only) comparator, a compare-equal run collapses keeping the LAST key's
    // bytes - identical to from_keys!'s upsert-last-wins rule.
    let s = u::from_sorted_k(vector[u::mk(1, 100), u::mk(1, 200), u::mk(2, 9)]);
    assert_eq!(u::len_k(&s), 2);
    let ks = u::keys_k(&s);
    assert_eq!(u::key_id(ks.borrow(0)), 1);
    assert_eq!(u::key_tag(ks.borrow(0)), 200); // the LAST of the id==1 run won
    assert!(u::wf_k(&s));
}

#[test]
fun from_sorted_large_n_builds_correctly() {
    // Build 500 strictly-increasing keys in O(N); result is complete, sorted, well-formed.
    let mut input = vector[];
    let mut i = 0u64;
    while (i < 500) {
        input.push_back(i * 3);
        i = i + 1;
    };
    let s = u::from_sorted(input);
    assert_eq!(s.length(), 500);
    assert!(u::wf(&s));
    assert_eq!(*s.keys().borrow(0), 0);
    assert_eq!(*s.keys().borrow(499), 499 * 3);
}

#[test]
fun from_sorted_all_equal_collapses() {
    // A run of ALL-equal keys collapses to one element. Every i>=1 takes the dedup branch, so the
    // loop's LAST op is a back-refresh (remove_at + insert_at at the tail) - a position the
    // mid-run dedup cases never reach.
    let s = u::from_sorted(vector[5u64, 5, 5, 5]);
    assert_eq!(s.length(), 1);
    assert_eq!(s.keys(), vector[5u64]);
    assert!(u::has(&s, 5));
    assert!(u::wf(&s));
}

#[test]
fun from_sorted_two_element_minimal() {
    // Minimal non-trivial cases: exactly one append (i=1) and one dedup (i=1).
    let inc = u::from_sorted(vector[1u64, 2]); // append branch fires once
    assert_eq!(inc.keys(), vector[1u64, 2]);
    let dup = u::from_sorted(vector[5u64, 5]); // dedup branch fires once
    assert_eq!(dup.keys(), vector[5u64]);
    assert!(u::wf(&inc) && u::wf(&dup));
}

#[test]
fun from_sorted_matches_from_keys_dups_at_scale() {
    // Differential at SCALE with DUPLICATES: a long sorted input where every value appears twice
    // must produce EXACTLY the tested O(N^2) reference constructor's result (full key vector, not
    // just length/first/last). The strongest single check of the dedup path.
    let mut input = vector[];
    let mut i = 0u64;
    while (i < 300) {
        input.push_back(i / 2); // 0,0,1,1,...,149,149 - sorted, each value twice
        i = i + 1;
    };
    let a = u::from_sorted(input);
    let b = u::fromk(input); // from_keys!, differentially validated against RefSet elsewhere
    assert_eq!(a.keys(), b.keys()); // identical, key for key
    assert_eq!(a.length(), 150); // 300 inputs -> 150 distinct
    assert!(u::wf(&a));
}

#[test]
fun from_sorted_then_mutate_is_normal_set() {
    // A from_sorted-built set must behave as a fully functional SortedSet afterwards: mutate,
    // query membership, navigate, and pop - all correct and well-formed.
    let mut s = u::from_sorted(vector[10u64, 20, 30, 40]);
    assert!(u::ins(&mut s, 25)); // insert into the interior
    assert!(!u::ins(&mut s, 30)); // duplicate -> false
    u::rem(&mut s, 20); // remove a present key
    assert!(u::has(&s, 25) && !u::has(&s, 20));
    assert_eq!(s.keys(), vector[10u64, 25, 30, 40]);
    assert_eq!(u::fnext(&s, 10, false), option::some(25)); // navigation intact
    assert_eq!(s.pop_front(), 10);
    assert_eq!(s.pop_back(), 40);
    assert!(u::wf(&s));
}

#[test]
fun from_sorted_trailing_duplicate_run() {
    // The input's final elements are a compare-equal run, so the loop's LAST iteration is a dedup
    // (back-refresh), not an append - the mirror of the other tests, which all end on an append.
    let s = u::from_sorted(vector[1u64, 2, 3, 3, 3]);
    assert_eq!(s.keys(), vector[1u64, 2, 3]);
    assert_eq!(s.length(), 3);
    assert!(u::wf(&s));
}

#[test]
fun from_sorted_leading_equal_run_then_append() {
    // A leading run of equal keys collapses at index 0 (back == 0 on every dedup), then a
    // strictly-greater key must still append correctly at index 1 afterwards.
    let s = u::from_sorted(vector[7u64, 7, 7, 9]);
    assert_eq!(s.keys(), vector[7u64, 9]);
    assert_eq!(s.head(), option::some(7));
    assert_eq!(s.tail(), option::some(9));
    assert!(u::wf(&s));
}

#[test]
fun from_sorted_coarse_trailing_dedup_keeps_last_bytes() {
    // Coarse last-wins when the winning byte-refresh is the FINAL loop iteration; the existing
    // coarse test's dedup is interior and its loop ends on an append.
    let s = u::from_sorted_k(vector[u::mk(7, 1), u::mk(7, 2), u::mk(7, 3)]);
    assert_eq!(u::len_k(&s), 1);
    let ks = u::keys_k(&s);
    assert_eq!(u::key_id(ks.borrow(0)), 7);
    assert_eq!(u::key_tag(ks.borrow(0)), 3); // the LAST of the run won, as the final op
    assert!(u::wf_k(&s));
}

#[test]
fun from_sorted_rev_at_scale_matches_from_keys() {
    // Reverse comparator BEYOND n=4: a long descending-with-duplicates input must match the
    // reverse from_keys! oracle key-for-key and be well-formed under `>`.
    let mut input = vector[];
    let mut i = 0u64;
    while (i < 200) {
        input.push_back(199 - i / 2); // 199,199,198,198,...,100,100 - non-increasing (sorted under >)
        i = i + 1;
    };
    let a = u::from_sorted_rev(input);
    let b = u::fromk_rev(input);
    assert_eq!(a.keys(), b.keys()); // identical stored (descending) order
    assert_eq!(a.length(), 100); // 200 inputs -> 100 distinct
    assert!(u::wf_rev(&a));
}

#[test]
fun from_sorted_u64_max_boundary() {
    // Values at the top of the u64 range: append then a dedup at U64_MAX. The macro never does
    // arithmetic on key values, so there is no overflow surprise; back = length - 1 stays in range.
    let s = u::from_sorted(vector[U64_MAX - 1, U64_MAX, U64_MAX]);
    assert_eq!(s.keys(), vector[U64_MAX - 1, U64_MAX]);
    assert_eq!(s.length(), 2);
    assert!(u::wf(&s));
}

// === size & extremes ===

#[test]
fun length_is_empty_track() {
    // Length tracks the entry count exactly, no cached counter to desync.
    let mut s = ss::new<u64>();
    assert!(s.is_empty());
    u::ins(&mut s, 1);
    u::ins(&mut s, 2);
    u::ins(&mut s, 2); // no-op
    assert!(s.length() == 2 && !s.is_empty());
    u::rem(&mut s, 1);
    assert_eq!(s.length(), 1);
}

#[test]
fun head_tail_extremes_and_update() {
    // head/tail are the comparator min/max; update on a new extreme.
    let mut s = u::fromk(vector[20u64, 30, 40]);
    assert_eq!(s.head(), option::some(20));
    assert_eq!(s.tail(), option::some(40));
    u::ins(&mut s, 10); // new min
    u::ins(&mut s, 50); // new max
    assert_eq!(s.head(), option::some(10));
    assert_eq!(s.tail(), option::some(50));
}

#[test]
fun pop_drain_monotonic() {
    // pop_front/pop_back return current min/max, -1 each, order preserved.
    let mut s = u::fromk(vector[30u64, 10, 20, 40]);
    assert_eq!(s.pop_front(), 10);
    assert_eq!(s.pop_back(), 40);
    assert!(u::wf(&s));
    assert_eq!(s.pop_front(), 20);
    assert_eq!(s.pop_back(), 30);
    assert!(s.is_empty());
}

#[test]
fun pop_singleton_no_underflow() {
    // pop_back on a length-1 set empties it with no n-1 underflow.
    let mut s = ss::singleton<u64>(99);
    assert_eq!(s.pop_back(), 99);
    assert!(s.is_empty());
    let mut s2 = ss::singleton<u64>(7);
    assert_eq!(s2.pop_front(), 7);
    assert!(s2.is_empty());
}

#[test]
fun drain_to_empty_then_reuse() {
    // The full state-machine cycle multi -> drain-to-empty -> REUSE. pop_drain_monotonic
    // drains but then STOPS; this asserts a set drained via pop_* leaves a CLEAN empty state that
    // accepts a fresh insert and behaves as new (no stale internal index/length).
    let mut s = u::fromk(vector[30u64, 10, 20]);
    assert_eq!(s.pop_front(), 10);
    assert_eq!(s.pop_back(), 30);
    assert_eq!(s.pop_front(), 20);
    assert!(s.is_empty() && u::wf(&s));
    // reuse the just-drained set:
    assert!(u::ins(&mut s, 99)); // fresh insert into a drained set -> true (newly added)
    assert!(s.length() == 1 && s.head() == option::some(99));
    assert!(u::wf(&s));
    assert_eq!(s.pop_back(), 99);
    assert!(s.is_empty());
}

// === keys: owned, ascending, deduped ===

#[test]
fun keys_owned_sorted_deduped() {
    // keys() reflects stored ascending order; it is a fresh copy each call.
    let mut s = u::fromk(vector[30u64, 10, 20]);
    assert_eq!(s.keys(), vector[10u64, 20, 30]);
    // mutate then re-read: a fresh copy, not a stale/cached reference.
    u::ins(&mut s, 5);
    assert_eq!(s.keys(), vector[5u64, 10, 20, 30]);
    u::rem(&mut s, 20);
    assert_eq!(s.keys(), vector[5u64, 10, 30]);
}

#[test]
fun keys_equals_concat_of_pages() {
    // keys() equals the concatenation of all keys_from! pages.
    let s = u::fromk(vector[10u64, 20, 30, 40, 50]);
    let mut concat = vector[];
    concat.append(u::page(&s, 0, true, 2)); // [10,20]
    concat.append(u::page(&s, 20, false, 2)); // [30,40]
    concat.append(u::page(&s, 40, false, 2)); // [50]
    assert_eq!(concat, s.keys());
    assert_eq!(concat, vector[10u64, 20, 30, 40, 50]);
}

// === ordered navigation on {10,20,30} ===

#[test]
fun navigation_table() {
    // ceiling/floor (include) vs strict next/prev.
    let s = u::fromk(vector[10u64, 20, 30]);
    assert_eq!(u::fnext(&s, 15, true), option::some(20)); // ceiling of a gap
    assert_eq!(u::fnext(&s, 20, true), option::some(20)); // include hit
    assert_eq!(u::fnext(&s, 20, false), option::some(30)); // strict next
    assert_eq!(u::fnext(&s, 30, false), option::none()); // past tail
    assert_eq!(u::fnext(&s, 30, true), option::some(30));
    assert_eq!(u::fnext(&s, 5, true), option::some(10)); // below head
    assert_eq!(u::fnext(&s, 35, true), option::none());
    assert_eq!(u::fprev(&s, 25, true), option::some(20)); // floor of a gap
    assert_eq!(u::fprev(&s, 20, false), option::some(10)); // strict prev
    assert_eq!(u::fprev(&s, 10, false), option::none()); // below head
    assert_eq!(u::fprev(&s, 5, true), option::none());
    // include-floor HITS (symmetry with the find_next include hits above):
    assert_eq!(u::fprev(&s, 30, true), option::some(30)); // at-tail include floor
    assert_eq!(u::fprev(&s, 20, true), option::some(20)); // interior include floor
    // Any key a navigation op RETURNS must be a member - compose each non-none
    // result back into contains!. (A returned key that failed membership would be a desync.)
    assert!(u::has(&s, u::fnext(&s, 15, true).destroy_some())); // ceiling-of-gap result is present
    assert!(u::has(&s, u::fprev(&s, 25, true).destroy_some())); // floor-of-gap result is present
    assert!(u::has(&s, u::nkey(&s, 10).destroy_some())); // next_key result is present
    assert!(u::has(&s, u::pkey(&s, 30).destroy_some())); // prev_key result is present
}

#[test]
fun navigation_boundary_duality_and_termination() {
    // cursor termination + head/tail boundary agreement.
    let s = u::fromk(vector[10u64, 20, 30]);
    assert_eq!(u::nkey(&s, 30), option::none()); // next_key!(tail) terminates
    assert_eq!(u::pkey(&s, 10), option::none()); // prev_key!(head) terminates
    assert_eq!(u::nkey(&s, 10), option::some(20));
    assert_eq!(u::pkey(&s, 30), option::some(20));
    // find_next!(k<=head, true) == head; find_prev!(k>=tail, true) == tail.
    assert_eq!(u::fnext(&s, 5, true), s.head());
    assert_eq!(u::fprev(&s, 99, true), s.tail());
}

#[test]
fun navigation_empty_all_none() {
    // every navigation op on an empty set returns none.
    let s = ss::new<u64>();
    assert_eq!(u::fnext(&s, 5, true), option::none());
    assert_eq!(u::fprev(&s, 5, true), option::none());
    assert_eq!(u::nkey(&s, 5), option::none());
    assert_eq!(u::pkey(&s, 5), option::none());
}

#[test]
fun navigation_singleton() {
    // singleton {H} -> next/prev terminate; include-forms return H.
    let s = ss::singleton<u64>(42);
    assert_eq!(u::nkey(&s, 42), option::none());
    assert_eq!(u::pkey(&s, 42), option::none());
    assert_eq!(u::fnext(&s, 42, true), option::some(42));
    assert_eq!(u::fprev(&s, 42, true), option::some(42));
}

// === pagination: bounded, contiguous, resumable ===

#[test]
fun pagination_resume() {
    // pages are contiguous and resume with include==false, no overlap/gap.
    let s = u::fromk(vector[10u64, 20, 30, 40, 50]);
    assert_eq!(u::page(&s, 10, true, 2), vector[10u64, 20]);
    assert_eq!(u::page(&s, 20, false, 2), vector[30u64, 40]);
    assert_eq!(u::page(&s, 40, false, 10), vector[50u64]); // fewer than limit at the tail
    assert_eq!(u::page(&s, 50, false, 10), vector[]); // past tail
}

#[test]
fun pagination_edges() {
    // boundaries: limit==0, empty set, from<head, from>tail.
    let s = u::fromk(vector[10u64, 20, 30]);
    assert_eq!(u::page(&s, 0, true, 0), vector[]); // limit 0
    assert_eq!(u::page(&s, 0, true, 100), vector[10u64, 20, 30]); // from < head -> from head
    assert_eq!(u::page(&s, 30, false, 100), vector[]); // from at tail, strict
    let empty = ss::new<u64>();
    assert_eq!(u::page(&empty, 0, true, 100), vector[]); // empty set
}

#[test]
fun pagination_limit_max_no_overflow() {
    // limit == u64::MAX on a small set returns all qualifying keys, no overflow abort
    // (the map loop bounds on out.length() < limit, never start + limit).
    let s = u::fromk(vector[10u64, 20, 30]);
    assert_eq!(u::page(&s, 0, true, U64_MAX), vector[10u64, 20, 30]);
}

// === independence ===

#[test]
fun two_sets_independent() {
    // ops on two distinct sets are fully independent (two distinct Move locations).
    let mut a = ss::new<u64>();
    let mut b = ss::new<u64>();
    u::ins(&mut a, 1);
    u::ins(&mut b, 2);
    u::ins(&mut a, 3);
    assert_eq!(a.keys(), vector[1u64, 3]);
    assert_eq!(b.keys(), vector[2u64]);
    u::rem(&mut a, 1);
    assert_eq!(a.keys(), vector[3u64]);
    assert_eq!(b.keys(), vector[2u64]); // b untouched by a's removal
}

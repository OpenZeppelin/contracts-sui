/// Core behavioral suite - the happy-path + boundary behavior of every non-comparator and
/// bare-comparator operation: lifecycle (`new`/`singleton`/`from_keys`), size (`length`/
/// `is_empty`), extremes (`head`/`tail`/`pop_*`), `keys`, ordered navigation, and pagination.
/// Failure modes, polarity, the differential check, comparator footguns, aborts, and types
/// live in their own modules.
module openzeppelin_sorted_set::core_tests;

use openzeppelin_sorted_set::sorted_set::{Self as ss};
use openzeppelin_sorted_set::test_util as u;
use std::unit_test::assert_eq;

const U64_MAX: u64 = 18446744073709551615;

// === lifecycle: new / singleton / from_keys ===

#[test]
fun new_empty() {
    // new() takes no ctx, is empty, drops out of scope (no destroy_empty).
    let s = ss::new<u64>();
    assert!(ss::is_empty(&s));
    assert_eq!(ss::length(&s), 0);
    assert_eq!(ss::head(&s), option::none());
    assert_eq!(ss::tail(&s), option::none());
    assert_eq!(ss::keys(&s), vector[]);
    assert!(u::wf(&s));
}

#[test]
fun singleton() {
    // One element at index 0, no comparator, trivially well-formed.
    let s = ss::singleton<u64>(42);
    assert_eq!(ss::length(&s), 1);
    assert!(u::has(&s, 42));
    assert_eq!(ss::head(&s), option::some(42));
    assert_eq!(ss::tail(&s), option::some(42));
    assert_eq!(ss::keys(&s), vector[42u64]);
    assert!(u::wf(&s));
}

#[test]
fun singleton_then_second_key() {
    // A singleton is a normal well-formed state - inserting a distinct key grows it.
    let mut s = ss::singleton<u64>(20);
    assert!(u::ins(&mut s, 10)); // smaller -> goes to index 0
    assert_eq!(ss::length(&s), 2);
    assert_eq!(ss::keys(&s), vector[10u64, 20]);
    assert!(u::wf(&s));
    // symmetric: a LARGER second key appends at index 1 (the existing case only covered prepend).
    let mut s2 = ss::singleton<u64>(20);
    assert!(u::ins(&mut s2, 30)); // larger -> appends at index 1
    assert_eq!(ss::keys(&s2), vector[20u64, 30]);
    assert!(u::wf(&s2));
}

#[test]
fun singleton_reinsert_same_key() {
    // Re-inserting the singleton's key is a no-op (false), length stays 1.
    let mut s = ss::singleton<u64>(7);
    assert!(!u::ins(&mut s, 7));
    assert_eq!(ss::length(&s), 1);
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
    assert_eq!(ss::length(&s), 3);
    assert_eq!(ss::keys(&s), vector[1u64, 2, 3]);
    assert!(u::wf(&s));
}

#[test]
fun from_keys_empty_and_singleton() {
    // Boundaries: empty input -> empty set; one key -> singleton-equivalent.
    let s0 = u::fromk(vector[]);
    assert!(ss::is_empty(&s0));
    let s1 = u::fromk(vector[5u64]);
    assert!(ss::length(&s1) == 1 && u::has(&s1, 5));
    assert!(u::wf(&s1));
}

// === size & extremes ===

#[test]
fun length_is_empty_track() {
    // Length tracks the entry count exactly, no cached counter to desync.
    let mut s = ss::new<u64>();
    assert!(ss::is_empty(&s));
    u::ins(&mut s, 1);
    u::ins(&mut s, 2);
    u::ins(&mut s, 2); // no-op
    assert!(ss::length(&s) == 2 && !ss::is_empty(&s));
    u::rem(&mut s, 1);
    assert_eq!(ss::length(&s), 1);
    u::rem(&mut s, 99); // absent no-op
    assert_eq!(ss::length(&s), 1);
}

#[test]
fun head_tail_extremes_and_update() {
    // head/tail are the comparator min/max; update on a new extreme.
    let mut s = u::fromk(vector[20u64, 30, 40]);
    assert_eq!(ss::head(&s), option::some(20));
    assert_eq!(ss::tail(&s), option::some(40));
    u::ins(&mut s, 10); // new min
    u::ins(&mut s, 50); // new max
    assert_eq!(ss::head(&s), option::some(10));
    assert_eq!(ss::tail(&s), option::some(50));
}

#[test]
fun pop_drain_monotonic() {
    // pop_front/pop_back return current min/max, -1 each, order preserved.
    let mut s = u::fromk(vector[30u64, 10, 20, 40]);
    assert_eq!(ss::pop_front(&mut s), 10);
    assert_eq!(ss::pop_back(&mut s), 40);
    assert!(u::wf(&s));
    assert_eq!(ss::pop_front(&mut s), 20);
    assert_eq!(ss::pop_back(&mut s), 30);
    assert!(ss::is_empty(&s));
}

#[test]
fun pop_singleton_no_underflow() {
    // pop_back on a length-1 set empties it with no n-1 underflow.
    let mut s = ss::singleton<u64>(99);
    assert_eq!(ss::pop_back(&mut s), 99);
    assert!(ss::is_empty(&s));
    let mut s2 = ss::singleton<u64>(7);
    assert_eq!(ss::pop_front(&mut s2), 7);
    assert!(ss::is_empty(&s2));
}

#[test]
fun drain_to_empty_then_reuse() {
    // The full state-machine cycle multi -> drain-to-empty -> REUSE. pop_drain_monotonic
    // drains but then STOPS; this asserts a set drained via pop_* leaves a CLEAN empty state that
    // accepts a fresh insert and behaves as new (no stale internal index/length).
    let mut s = u::fromk(vector[30u64, 10, 20]);
    assert_eq!(ss::pop_front(&mut s), 10);
    assert_eq!(ss::pop_back(&mut s), 30);
    assert_eq!(ss::pop_front(&mut s), 20);
    assert!(ss::is_empty(&s) && u::wf(&s));
    // reuse the just-drained set:
    assert!(u::ins(&mut s, 99)); // fresh insert into a drained set -> true (newly added)
    assert!(ss::length(&s) == 1 && ss::head(&s) == option::some(99));
    assert!(u::wf(&s));
    assert_eq!(ss::pop_back(&mut s), 99);
    assert!(ss::is_empty(&s));
}

// === keys: owned, ascending, deduped ===

#[test]
fun keys_owned_sorted_deduped() {
    // keys() reflects stored ascending order; it is a fresh copy each call.
    let mut s = u::fromk(vector[30u64, 10, 20]);
    assert_eq!(ss::keys(&s), vector[10u64, 20, 30]);
    // mutate then re-read: a fresh copy, not a stale/cached reference.
    u::ins(&mut s, 5);
    assert_eq!(ss::keys(&s), vector[5u64, 10, 20, 30]);
    u::rem(&mut s, 20);
    assert_eq!(ss::keys(&s), vector[5u64, 10, 30]);
}

#[test]
fun keys_equals_concat_of_pages() {
    // keys() equals the concatenation of all keys_from! pages.
    let s = u::fromk(vector[10u64, 20, 30, 40, 50]);
    let mut concat = vector[];
    concat.append(u::page(&s, 0, true, 2)); // [10,20]
    concat.append(u::page(&s, 20, false, 2)); // [30,40]
    concat.append(u::page(&s, 40, false, 2)); // [50]
    assert_eq!(concat, ss::keys(&s));
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
    assert_eq!(u::fnext(&s, 5, true), ss::head(&s));
    assert_eq!(u::fprev(&s, 99, true), ss::tail(&s));
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
    assert_eq!(ss::keys(&a), vector[1u64, 3]);
    assert_eq!(ss::keys(&b), vector[2u64]);
    u::rem(&mut a, 1);
    assert_eq!(ss::keys(&a), vector[3u64]);
    assert_eq!(ss::keys(&b), vector[2u64]); // b untouched by a's removal
}

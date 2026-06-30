/// Functional core on `SortedMap<u64, u64>`.
///
/// Covers the maintained-by-construction core: lifecycle, upsert/remove
/// semantics, extremes & pop, navigation, pagination (incl. the overflow-safe
/// `out.length() < limit` bound). Sorted order is checked after mutations via the
/// `wf` well-formedness check. All ops route through `test_util`'s thin wrappers so no
/// test function approaches the 256-locals limit.
module openzeppelin_sorted_map::core_tests;

use openzeppelin_sorted_map::sorted_map as sm;
use openzeppelin_sorted_map::test_util as u;
use std::unit_test::assert_eq;

const U64_MAX: u64 = 18446744073709551615;

// === Lifecycle ===

#[test]
fun new_empty() {
    let m = sm::new<u64, u64>();
    assert_eq!(sm::length(&m), 0);
    assert!(sm::is_empty(&m));
    assert_eq!(sm::head(&m), option::none());
    assert_eq!(sm::tail(&m), option::none());
    sm::destroy_empty(m); // destroy_empty happy path
}

// === Insert: fresh grows, upsert replaces ===

#[test]
fun insert_fresh_grows() {
    let mut m = sm::new<u64, u64>();
    assert_eq!(u::ins(&mut m, 20, 200), option::none()); // none on fresh
    assert_eq!(u::ins(&mut m, 10, 100), option::none());
    assert_eq!(u::ins(&mut m, 30, 300), option::none());
    assert_eq!(sm::length(&m), 3); // +1 each
    assert!(u::wf(&m)); // sorted, no dups
    assert_eq!(u::get(&m, 10), 100);
    assert_eq!(u::get(&m, 20), 200);
    assert_eq!(u::get(&m, 30), 300);
}

#[test]
fun insert_upsert_replaces() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 100);
    u::ins(&mut m, 20, 200);
    // Re-insert an existing key: length unchanged, returns some(old), new value wins.
    assert_eq!(u::ins(&mut m, 10, 999), option::some(100)); // some(old)
    assert_eq!(sm::length(&m), 2); // no growth
    assert_eq!(u::get(&m, 10), 999); // new value
    assert!(u::wf(&m));
    // Repeated replace stays constant (no duplicates / +2).
    assert_eq!(u::ins(&mut m, 10, 111), option::some(999));
    assert_eq!(sm::length(&m), 2);
    assert!(u::wf(&m));
}

#[test]
fun insert_order_shuffled() {
    // 60 scrambled keys inserted in arbitrary order -> still strictly ascending.
    let m = u::build_scrambled(60);
    assert_eq!(sm::length(&m), 60);
    assert!(u::wf(&m));
    // Independent ascending-walk check via head + next_key: strictly increasing, count == n.
    let mut cur = sm::head(&m);
    let mut prev = option::none<u64>();
    let mut count = 0u64;
    while (cur.is_some()) {
        let k = *cur.borrow();
        if (prev.is_some()) assert!(*prev.borrow() < k); // strictly increasing
        prev = option::some(k);
        cur = u::nxt(&m, k);
        count = count + 1;
    };
    assert_eq!(count, 60);
}

// === Borrow / borrow_mut ===

#[test]
fun borrow_and_mut_present() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 5, 50);
    u::ins(&mut m, 7, 70);
    assert_eq!(u::get(&m, 5), 50);
    u::set(&mut m, 5, 51); // borrow_mut -> overwrite value
    assert_eq!(u::get(&m, 5), 51);
    assert_eq!(u::get(&m, 7), 70); // neighbor untouched
}

#[test]
fun borrow_mut_preserves_order() {
    // borrow_mut yields &mut V, never &mut Entry: the key cannot be desynced.
    let mut m = u::build_scrambled(40);
    let h = *sm::head(&m).borrow();
    let t = *sm::tail(&m).borrow();
    u::set(&mut m, h, 12345);
    u::set(&mut m, t, 67890);
    assert!(u::wf(&m)); // order intact after value mutation
    assert_eq!(sm::head(&m), option::some(h)); // extremes unchanged
    assert_eq!(sm::tail(&m), option::some(t));
    assert_eq!(u::get(&m, h), 12345);
}

// === contains == borrow-succeeds ===

#[test]
fun contains_matches_borrow() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 1);
    u::ins(&mut m, 20, 2);
    u::ins(&mut m, 30, 3);
    // present
    assert!(u::has(&m, 20) && u::get(&m, 20) == 2);
    // absent: below head, above tail, interior gap
    assert!(!u::has(&m, 5));
    assert!(!u::has(&m, 35));
    assert!(!u::has(&m, 25));
    // state transition: insert flips false->true, remove flips true->false
    u::ins(&mut m, 25, 25);
    assert!(u::has(&m, 25));
    u::rm(&mut m, 25);
    assert!(!u::has(&m, 25));
}

// === Remove ===

#[test]
fun remove_head_tail_middle() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 1);
    u::ins(&mut m, 20, 2);
    u::ins(&mut m, 30, 3);
    u::ins(&mut m, 40, 4);
    assert_eq!(u::rm(&mut m, 10), option::some(1)); // head
    assert_eq!(u::rm(&mut m, 40), option::some(4)); // tail
    assert_eq!(u::rm(&mut m, 20), option::some(2)); // middle
    assert_eq!(sm::length(&m), 1);
    assert!(u::wf(&m)); // shift kept order
    assert_eq!(sm::head(&m), option::some(30));
    assert!(!u::has(&m, 20));
}

#[test]
fun remove_absent_none() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 1);
    u::ins(&mut m, 30, 3);
    assert_eq!(u::rm(&mut m, 5), option::none()); // below head
    assert_eq!(u::rm(&mut m, 35), option::none()); // above tail
    assert_eq!(u::rm(&mut m, 20), option::none()); // interior gap
    assert_eq!(sm::length(&m), 2); // unchanged
    assert!(u::wf(&m));
}

#[test]
fun remove_reinsert_roundtrip() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 1);
    u::ins(&mut m, 20, 2);
    assert_eq!(u::rm(&mut m, 10), option::some(1));
    assert!(!u::has(&m, 10));
    assert_eq!(u::ins(&mut m, 10, 11), option::none()); // reinserts fresh
    assert_eq!(u::get(&m, 10), 11);
    assert!(u::wf(&m));
}

// === Extremes & pop ===

#[test]
fun head_tail_extremes() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 20, 2);
    assert!(sm::head(&m) == option::some(20) && sm::tail(&m) == option::some(20)); // singleton
    u::ins(&mut m, 10, 1); // new min
    u::ins(&mut m, 30, 3); // new max
    assert_eq!(sm::head(&m), option::some(10));
    assert_eq!(sm::tail(&m), option::some(30));
}

#[test]
fun pop_front_back_drains() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 1);
    u::ins(&mut m, 20, 2);
    u::ins(&mut m, 30, 3);
    let (k0, v0) = sm::pop_front(&mut m); // smallest
    assert!(k0 == 10 && v0 == 1);
    let (k1, v1) = sm::pop_back(&mut m); // largest
    assert!(k1 == 30 && v1 == 3);
    assert_eq!(sm::length(&m), 1);
    let (k2, v2) = sm::pop_back(&mut m); // length-1 map: no n-1 underflow
    assert!(k2 == 20 && v2 == 2);
    assert!(sm::is_empty(&m));
    sm::destroy_empty(m);
}

// === Navigation: find_next / find_prev ===

#[test]
fun find_next_table() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 1);
    u::ins(&mut m, 20, 2);
    u::ins(&mut m, 30, 3);
    // absent target: include is irrelevant (ceiling == strict-next)
    assert_eq!(u::fnext(&m, 15, true), option::some(20));
    assert_eq!(u::fnext(&m, 15, false), option::some(20));
    // present target: include returns it; strict skips it
    assert_eq!(u::fnext(&m, 20, true), option::some(20));
    assert_eq!(u::fnext(&m, 20, false), option::some(30));
    // at the max
    assert_eq!(u::fnext(&m, 30, true), option::some(30));
    assert_eq!(u::fnext(&m, 30, false), option::none());
    // below head / above tail
    assert_eq!(u::fnext(&m, 5, true), option::some(10));
    assert_eq!(u::fnext(&m, 35, true), option::none());
}

#[test]
fun find_prev_table() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 1);
    u::ins(&mut m, 20, 2);
    u::ins(&mut m, 30, 3);
    assert_eq!(u::fprev(&m, 25, true), option::some(20));
    assert_eq!(u::fprev(&m, 25, false), option::some(20));
    assert_eq!(u::fprev(&m, 20, true), option::some(20));
    assert_eq!(u::fprev(&m, 20, false), option::some(10));
    assert_eq!(u::fprev(&m, 10, true), option::some(10));
    assert_eq!(u::fprev(&m, 10, false), option::none()); // strict-prev of min
    assert_eq!(u::fprev(&m, 35, true), option::some(30));
    assert_eq!(u::fprev(&m, 5, false), option::none());
}

#[test]
fun next_prev_key_sugar() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 1);
    u::ins(&mut m, 20, 2);
    u::ins(&mut m, 30, 3);
    assert_eq!(u::nxt(&m, 20), option::some(30));
    assert_eq!(u::nxt(&m, 30), option::none()); // next_key(tail) == none
    assert_eq!(u::prv(&m, 20), option::some(10));
    assert_eq!(u::prv(&m, 10), option::none()); // prev_key(head) == none
}

// === Navigation boundary duality ===

#[test]
fun navigation_boundary_duality() {
    // empty: all four none
    let e = sm::new<u64, u64>();
    assert_eq!(u::fnext(&e, 5, true), option::none());
    assert_eq!(u::fprev(&e, 5, true), option::none());
    assert_eq!(u::nxt(&e, 5), option::none());
    assert_eq!(u::prv(&e, 5), option::none());
    sm::destroy_empty(e);

    // singleton {10}: H == T == 10
    let mut s = sm::new<u64, u64>();
    u::ins(&mut s, 10, 1);
    assert!(u::nxt(&s, 10) == option::none() && u::prv(&s, 10) == option::none());
    assert_eq!(u::fnext(&s, 10, true), option::some(10));
    assert_eq!(u::fprev(&s, 10, true), option::some(10));
    assert_eq!(sm::head(&s), sm::tail(&s));

    // {10,20,30}: cursor-termination relations at the extremes
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 1);
    u::ins(&mut m, 20, 2);
    u::ins(&mut m, 30, 3);
    let h = *sm::head(&m).borrow();
    let t = *sm::tail(&m).borrow();
    assert_eq!(u::nxt(&m, t), option::none()); // forward walk stops at tail
    assert_eq!(u::prv(&m, t), option::some(20));
    assert_eq!(u::prv(&m, h), option::none()); // backward walk stops at head
    assert_eq!(u::nxt(&m, h), option::some(20));
    assert_eq!(u::fnext(&m, 5, true), sm::head(&m)); // find_next(k<=H,true) == head
    assert_eq!(u::fprev(&m, 35, true), sm::tail(&m)); // find_prev(k>=T,true) == tail
}

// === Pagination ===

#[test]
fun keys_from_paginate_resume() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 1);
    u::ins(&mut m, 20, 2);
    u::ins(&mut m, 30, 3);
    u::ins(&mut m, 40, 4);
    u::ins(&mut m, 50, 5);
    // page 1, resume with include=false, no overlap / no gap
    assert_eq!(u::kfrom(&m, 10, true, 2), vector[10, 20]);
    assert_eq!(u::kfrom(&m, 20, false, 2), vector[30, 40]);
    assert_eq!(u::kfrom(&m, 40, false, 10), vector[50]);
    assert_eq!(u::kfrom(&m, 50, false, 10), vector[]); // past tail via strict resume
    // from < head pages from head; from > tail is empty; limit 0 is empty
    assert_eq!(u::kfrom(&m, 5, true, 10), vector[10, 20, 30, 40, 50]);
    assert_eq!(u::kfrom(&m, 100, true, 10), vector[]);
    assert_eq!(u::kfrom(&m, 10, true, 0), vector[]);
}

#[test]
fun keys_from_overflow_limit() {
    // The loop bound is `out.length() < limit`, never `start + limit` - so a huge limit
    // returns the tail with NO arithmetic overflow / abort.
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 1);
    u::ins(&mut m, 20, 2);
    u::ins(&mut m, 30, 3);
    assert_eq!(u::kfrom(&m, 20, false, 1000), vector[30]);
    assert_eq!(u::kfrom(&m, 0, true, U64_MAX), vector[10, 20, 30]);
}

// === Length tracks the vector with no cached counter ===

#[test]
fun length_delta_per_op() {
    let mut m = sm::new<u64, u64>();
    assert_eq!(sm::length(&m), 0);
    u::ins(&mut m, 10, 1);
    assert_eq!(sm::length(&m), 1); // fresh: +1
    u::ins(&mut m, 10, 2);
    assert_eq!(sm::length(&m), 1); // upsert: 0
    u::rm(&mut m, 99);
    assert_eq!(sm::length(&m), 1); // absent remove: 0
    u::rm(&mut m, 10);
    assert_eq!(sm::length(&m), 0); // remove: -1
}

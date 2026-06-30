/// Core happy-path + boundary suite: the per-operation contracts (lifecycle, size/bounds, point
/// access, navigation, pagination, pop/drain). Everything runs at FORCED LOW degree (inner 4 /
/// leaf 3) so a handful of inserts already spans multiple leaves and levels, and the
/// well-formedness check (`bsm_well_formed`) is asserted after every shape-changing op.
///
/// All comparator-bearing ops route through `test_util` wrappers (one macro expansion per body).
module openzeppelin_big_sorted_map::core_tests;

use openzeppelin_big_sorted_map::big_sorted_map::{Self as bsm, BigSortedMap};
use openzeppelin_big_sorted_map::test_util as u;
use std::unit_test::assert_eq;

// Well-formedness check at the forced low degree used throughout, ascending.
fun wf(m: &BigSortedMap<u64, u64>): bool { u::bsm_well_formed(m, 4, 3, true) }

/// Build keys `1..=n` (value `k*100`) into a degree-(4,3) tree via the public insert path.
fun build(n: u64, ctx: &mut TxContext): BigSortedMap<u64, u64> {
    let mut map = bsm::new_with_config<u64, u64>(4, 3, ctx);
    let mut k = 1u64;
    while (k <= n) {
        u::ins(&mut map, k, k * 100);
        k = k + 1;
    };
    map
}

// === Lifecycle / empty tree ===

#[test]
fun new_empty() {
    let mut ctx = tx_context::dummy();
    let map = bsm::new<u64, u64>(&mut ctx);
    assert!(bsm::is_empty(&map));
    assert_eq!(bsm::length(&map), 0);
    assert!(bsm::head(&map).is_none());
    assert!(bsm::tail(&map).is_none());
    assert!(!u::has(&map, 5));
    // empty tree is well-formed: single empty leaf root, NULL chain ends.
    assert!(u::bsm_well_formed(&map, 64, 64, true));
    // an empty-tree lookup locates the inline root leaf (no df load).
    assert_eq!(u::locate(&map, 5), bsm::root_index());
    bsm::destroy_empty(map);
}

// === Insert: upsert semantics + cached length ===

#[test]
fun insert_fresh_grows_then_upsert_replaces() {
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new_with_config<u64, u64>(4, 3, &mut ctx);
    // fresh inserts: each returns none, length +1.
    let mut k = 1u64;
    while (k <= 7) {
        assert!(u::ins(&mut map, k, k * 100).is_none());
        assert_eq!(bsm::length(&map), k);
        assert!(wf(&map));
        k = k + 1;
    };
    // upsert an existing key: returns some(old), length unchanged, value updated.
    let old = u::ins(&mut map, 4, 999);
    assert_eq!(old, option::some(400));
    assert_eq!(bsm::length(&map), 7);
    assert_eq!(u::get(&map, 4), 999);
    assert!(wf(&map));
    u::drain_destroy(map);
}

// === Remove: total, none on miss ===

#[test]
fun remove_hit_and_miss() {
    let mut ctx = tx_context::dummy();
    let mut map = build(9, &mut ctx);
    // miss: none, tree unchanged.
    assert!(u::rem(&mut map, 100).is_none());
    assert_eq!(bsm::length(&map), 9);
    assert!(wf(&map));
    // hit: some(old value), length -1, key gone, neighbours intact.
    assert_eq!(u::rem(&mut map, 5), option::some(500));
    assert_eq!(bsm::length(&map), 8);
    assert!(!u::has(&map, 5));
    assert!(u::get(&map, 4) == 400 && u::get(&map, 6) == 600);
    assert!(wf(&map));
    u::drain_destroy(map);
}

// === head/tail are the comparator extremes, O(1) ===

#[test]
fun head_tail_extremes() {
    let mut ctx = tx_context::dummy();
    let mut map = build(10, &mut ctx);
    assert_eq!(bsm::head(&map), option::some(1));
    assert_eq!(bsm::tail(&map), option::some(10));
    // remove the current extremes; head/tail track the new ones.
    u::rem(&mut map, 1);
    u::rem(&mut map, 10);
    assert_eq!(bsm::head(&map), option::some(2));
    assert_eq!(bsm::tail(&map), option::some(9));
    assert!(wf(&map));
    u::drain_destroy(map);
}

// === pop_front / pop_back remove global min/max + rebalance ===

#[test]
fun pop_front_back_drains_in_order() {
    let mut ctx = tx_context::dummy();
    let mut map = build(8, &mut ctx);
    let (k1, v1) = bsm::pop_front(&mut map);
    assert!(k1 == 1 && v1 == 100);
    let (k8, v8) = bsm::pop_back(&mut map);
    assert!(k8 == 8 && v8 == 800);
    assert_eq!(bsm::length(&map), 6);
    assert!(bsm::head(&map) == option::some(2) && bsm::tail(&map) == option::some(7));
    assert!(wf(&map));
    // drain the remainder front-to-back; keys come out ascending.
    let mut expect = 2u64;
    while (!bsm::is_empty(&map)) {
        let (k, v) = bsm::pop_front(&mut map);
        assert!(k == expect && v == expect * 100);
        assert!(wf(&map));
        expect = expect + 1;
    };
    assert_eq!(expect, 8); // popped 2..=7
    bsm::destroy_empty(map);
}

// === pop_*_n: bounded drain, stop-at-empty, n==0 ===

#[test]
fun pop_n_bounded_and_stop_at_empty() {
    let mut ctx = tx_context::dummy();
    let mut map = build(7, &mut ctx);
    // n == 0 returns empty, no abort, tree unchanged.
    let (k0, v0) = bsm::pop_front_n(&mut map, 0);
    assert!(k0 == vector[] && v0 == vector[]);
    assert_eq!(bsm::length(&map), 7);
    // pop 3 from the front, ascending.
    let (kf, vf) = bsm::pop_front_n(&mut map, 3);
    assert_eq!(kf, vector[1u64, 2, 3]);
    assert_eq!(vf, vector[100u64, 200, 300]);
    assert!(wf(&map));
    // pop more than remain from the back: descending (pop order), STOPS at empty without aborting.
    let (kb, vb) = bsm::pop_back_n(&mut map, 100);
    assert_eq!(kb, vector[7u64, 6, 5, 4]);
    assert_eq!(vb, vector[700u64, 600, 500, 400]);
    assert!(bsm::is_empty(&map));
    bsm::destroy_empty(map);
}

// === find_next / find_prev across leaf boundaries, include flag ===

#[test]
fun find_next_prev_table() {
    let mut ctx = tx_context::dummy();
    let map = build(12, &mut ctx); // 1..12 across several leaves
    // ceiling (include) at a present key returns the key itself; strict advances one.
    assert_eq!(u::fnext(&map, 6, true), option::some(6));
    assert_eq!(u::fnext(&map, 6, false), option::some(7));
    // crosses a leaf boundary regardless of where the split fell.
    assert_eq!(u::fprev(&map, 6, true), option::some(6));
    assert_eq!(u::fprev(&map, 6, false), option::some(5));
    // absent key between entries: ceiling/floor straddle the gap (none here since dense).
    assert_eq!(u::fnext(&map, 0, true), option::some(1)); // below head -> head
    assert_eq!(u::fprev(&map, 100, true), option::some(12)); // above tail -> tail
    // off the ends.
    assert!(u::fnext(&map, 12, false).is_none());
    assert!(u::fprev(&map, 1, false).is_none());
    assert!(u::fnext(&map, 100, true).is_none());
    assert!(u::fprev(&map, 0, true).is_none());
    u::drain_destroy(map);
}

#[test]
fun next_prev_key_sugar() {
    let mut ctx = tx_context::dummy();
    let map = build(5, &mut ctx);
    assert_eq!(u::nxt(&map, 3), option::some(4));
    assert_eq!(u::prv(&map, 3), option::some(2));
    assert!(u::nxt(&map, 5).is_none()); // forward-cursor termination at the tail
    assert!(u::prv(&map, 1).is_none()); // backward-cursor termination at the head
    u::drain_destroy(map);
}

// === keys_from pagination: ascending, contiguous, gap-free, resumable ===

#[test]
fun keys_from_paginate_resume() {
    let mut ctx = tx_context::dummy();
    let map = build(12, &mut ctx);
    // first page of 5 from the head.
    let p1 = u::kfrom(&map, 1, true, 5);
    assert_eq!(p1, vector[1u64, 2, 3, 4, 5]);
    // resume: last key of p1 back with include=false -> the next contiguous page, no overlap/gap.
    let p2 = u::kfrom(&map, 5, false, 5);
    assert_eq!(p2, vector[6u64, 7, 8, 9, 10]);
    let p3 = u::kfrom(&map, 10, false, 5);
    assert_eq!(p3, vector[11u64, 12]); // tail page is short, never aborts
    // limit == 0 on a NON-empty tree: the count-bound caps the page at zero keys. Distinct
    // from the empty-tree empty result - here the tree HAS keys and `from` resolves to a real leaf, but
    // the OUTER guard `out.length() < limit` is 0 < 0 and short-circuits before any df load.
    assert_eq!(u::kfrom(&map, 1, true, 0), vector[]);
    assert_eq!(u::kfrom(&map, 5, false, 0), vector[]); // exclusive-boundary limit-0 also empty
    // from > global max on a NON-empty tree: descent lands in the rightmost leaf with start == leaf_len,
    // so collect_keys_from steps to leaf_next (NULL) immediately and returns empty (clean chain-tail
    // termination) - NOT an abort. A start-clamp regression would wrongly emit 12 here.
    assert_eq!(u::kfrom(&map, 100, true, 5), vector[]);
    assert_eq!(u::kfrom(&map, 12, false, 5), vector[]); // exclusive on the exact max -> also empty
    // an over-large limit just stops at the tail.
    assert_eq!(u::kfrom(&map, 1, true, 1000).length(), 12);
    u::drain_destroy(map);
}

// === contains == borrow-succeeds; borrow_mut is in-place &mut V ===

#[test]
fun contains_matches_borrow_and_mut() {
    let mut ctx = tx_context::dummy();
    let mut map = build(10, &mut ctx);
    let mut k = 0u64;
    while (k <= 11) {
        // contains agrees exactly with borrow succeeding.
        assert_eq!(u::has(&map, k), (k >= 1 && k <= 10));
        k = k + 1;
    };
    // borrow_mut yields &mut V; mutating it changes the value, NOT the key position.
    u::set(&mut map, 7, 7777);
    assert_eq!(u::get(&map, 7), 7777);
    // keys still strictly ascending after the in-place value mutation.
    assert!(wf(&map));
    assert_eq!(u::kfrom(&map, 1, true, 100), vector[1u64, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    u::drain_destroy(map);
}

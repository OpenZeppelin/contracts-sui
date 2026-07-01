/// The cross-tier bridge suite - `from_sorted_map` / `into_sorted_map`. The
/// bulk build moves (never copies/drops) every value, re-validates source order BEFORE any df write,
/// and - critically - distributes entries EVENLY so every node including each level's RIGHTMOST
/// stays at or above the half-full floor (a naive bottom-up pack reaches the half-full
/// floor by a path no later op would heal). All u64/u64 here; the non-drop conservation half of the
/// bridge lives in `conservation_tests`. The well-formedness check is asserted on every built tree.
module openzeppelin_collections::big_sorted_map_bridge_tests;

use openzeppelin_collections::big_sorted_map as bsm;
use openzeppelin_collections::big_sorted_map_test_util as u;
use openzeppelin_collections::sorted_map as sm;
use std::unit_test::assert_eq;

// === from -> into round-trip at an uneven size (5 leaves of 3,3,3,2,2 at degree 3) ===

#[test]
fun from_into_roundtrip_uneven_tail() {
    let mut ctx = tx_context::dummy();
    let src = u::sm_build(13); // n=13, leaf 3 -> an uneven tail
    let mut map = u::from_sm_lowdeg(src, &mut ctx);
    assert_eq!(bsm::length(&map), 13);
    // every node - including the rightmost leaf of the level - is at least half-full.
    assert!(u::bsm_well_formed(&map, 4, 3, true));
    // every key reachable with its value (no stranding from the bulk build).
    let mut k = 1u64;
    while (k <= 13) {
        assert_eq!(u::get(&map, k), k * 10);
        k = k + 1;
    };
    // a full ordered scan reconstructs the sorted key list (leaf chain intact).
    let all = u::kfrom(&map, 1, true, 100);
    assert_eq!(all, vector[1u64, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]);
    // drain back to a tier-1 SortedMap; the (K,V) multiset is identical.
    let back = bsm::into_sorted_map(&mut map);
    assert_eq!(sm::length(&back), 13);
    let mut k = 1u64;
    while (k <= 13) {
        assert_eq!(u::sm_get(&back, k), k * 10);
        k = k + 1;
    };
    bsm::destroy_empty(map); // map emptied by the drain
    let _drop_back = back; // back is u64/u64 (droppable)
}

// === the half-full tail holds across the worst-case sizes (naive pack would underflow) ===

#[test]
fun bulk_build_half_full_tail_across_sizes() {
    let mut ctx = tx_context::dummy();
    // n mod leaf_max == 1 at leaf 3 (7, 10, 13, ...) is the case a naive pack leaves a 1-entry tail
    // leaf (< floor 2). The even-distribution build must keep every leaf >= ceil(3/2) = 2.
    let sizes = vector[4u64, 7, 10, 13, 16, 19, 25, 31];
    let mut i = 0;
    while (i < sizes.length()) {
        let n = *sizes.borrow(i);
        let src = u::sm_build(n);
        let map = u::from_sm_lowdeg(src, &mut ctx);
        assert_eq!(bsm::length(&map), n);
        assert!(u::bsm_well_formed(&map, 4, 3, true)); // the well-formedness check enforces the half-full floor
        // spot-check reachability at the extremes and the middle.
        assert!(u::get(&map, 1) == 10 && u::get(&map, n) == n * 10);
        u::drain_destroy(map);
        i = i + 1;
    };
}

// === one-shot default-degree build (the common migration path) ===

#[test]
fun from_sorted_map_default_degree() {
    let mut ctx = tx_context::dummy();
    let src = u::sm_build(200);
    let map = u::from_sm_default(src, &mut ctx); // default degrees (64) -> shallow tree
    assert_eq!(bsm::length(&map), 200);
    assert!(u::bsm_well_formed(&map, 64, 64, true));
    assert!(bsm::head(&map) == option::some(1) && bsm::tail(&map) == option::some(200));
    // a sampling of keys reachable.
    let mut k = 1u64;
    while (k <= 200) {
        assert_eq!(u::get(&map, k), k * 10);
        k = k + 7;
    };
    u::drain_destroy(map);
}

// === an empty source bridges to an empty (well-formed) tree ===

#[test]
fun from_empty_source() {
    let mut ctx = tx_context::dummy();
    let src = sm::new<u64, u64>(); // empty
    let map = u::from_sm_lowdeg(src, &mut ctx);
    assert!(bsm::is_empty(&map));
    assert!(u::bsm_well_formed(&map, 4, 3, true));
    bsm::destroy_empty(map);
}

// === a single-entry source (degenerate one-leaf build) ===

#[test]
fun from_singleton_source() {
    let mut ctx = tx_context::dummy();
    let mut src = sm::new<u64, u64>();
    u::sm_ins(&mut src, 42, 420);
    let mut map = u::from_sm_lowdeg(src, &mut ctx);
    assert_eq!(bsm::length(&map), 1);
    assert!(u::root_is_leaf(&map) && u::tree_depth(&map) == 0);
    assert_eq!(u::get(&map, 42), 420);
    assert!(u::bsm_well_formed(&map, 4, 3, true));
    let (k, v) = bsm::pop_front(&mut map);
    assert!(k == 42 && v == 420);
    bsm::destroy_empty(map);
}

// === into_sorted_map UNDER the capacity heuristic succeeds (positive boundary) ===

#[test]
fun into_sorted_map_under_capacity_succeeds() {
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new_with_config<u64, u64>(4, 3, &mut ctx);
    let mut k = 1u64;
    while (k <= 50) { u::ins(&mut map, k, k * 10); k = k + 1; };
    let back = bsm::into_sorted_map(&mut map); // 50 << 10_000 -> no abort
    assert_eq!(sm::length(&back), 50);
    // the emptied tree is reusable / destroyable; it is back to a single empty leaf root.
    assert!(bsm::is_empty(&map));
    assert!(u::bsm_well_formed(&map, 4, 3, true));
    bsm::destroy_empty(map);
    let _ = back;
}

// === into_sorted_map on an EMPTY tree takes the length==0 early-return path ===
// The empty-return branch (does zero state mutation, never enters take_root or the leaf-chain walk)
// is never run by the other call sites, which all drain depth>=1 trees. The load-bearing pin is the
// returned VALUE (an empty SortedMap), which the well-formedness check says nothing about.

// Pins branch: into_sorted_map / given an empty tree / it returns an empty SortedMap, tree untouched
#[test]
fun into_sorted_map_empty_tree() {
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new_with_config<u64, u64>(4, 3, &mut ctx); // empty single-leaf root
    let back = bsm::into_sorted_map(&mut map); // length==0 early-return path
    assert!(sm::length(&back) == 0 && sm::is_empty(&back)); // THE pin: empty SortedMap returned
    assert!(bsm::is_empty(&map));
    assert!(u::bsm_well_formed(&map, 4, 3, true)); // tree untouched, still well-formed
    bsm::destroy_empty(map);
    sm::destroy_empty(back);
}

// === bridging a DESCENDING source under the matching reverse comparator builds OK ===

#[test]
fun reverse_comparator_bridge() {
    let mut ctx = tx_context::dummy();
    let src = u::sm_build_desc(13); // ordered descending under `>`
    // revalidates strictly-increasing-under-`>` (i.e. descending) -> OK; builds a reverse-ordered tree.
    let map = u::from_sm_rev(src, &mut ctx);
    assert_eq!(bsm::length(&map), 13);
    assert!(u::bsm_well_formed(&map, 4, 3, false)); // well-formed under the REVERSE order
    // under `>`, head is the largest key, tail the smallest.
    assert_eq!(bsm::head(&map), option::some(13));
    assert_eq!(bsm::tail(&map), option::some(1));
    assert!(u::has_rev(&map, 7) && u::get_rev(&map, 7) == 70);
    u::drain_destroy(map);
}

// === from_sorted_map_by! (bare _by, DEFAULT degrees) with a reverse comparator ===
// The only one of the 4 from_* macro forms never expanded with a non-`<` comparator: from_sorted_map!
// hardwires `<`; reverse_comparator_bridge threads `>` but via the explicit-degree config sibling.
// This pins the default-degree dispatch THREADED with a caller comparator - a dropped $lt here compiles
// and ships undetected today.

// Pins branch: from_sorted_map_by! / given a descending source + matching `>` at default degrees / it builds a value-conserving reverse-ordered tree
#[test]
fun from_sorted_map_by_default_degree_reverse() {
    let mut ctx = tx_context::dummy();
    let src = u::sm_build_desc(200); // descending under `>` (valid for `>`)
    let map = u::from_sm_default_rev(src, &mut ctx); // DEFAULT degrees (64) + custom `>`
    assert_eq!(bsm::length(&map), 200);
    assert!(u::bsm_well_formed(&map, 64, 64, false)); // well-formed under the REVERSE order
    assert!(bsm::head(&map) == option::some(200) && bsm::tail(&map) == option::some(1));
    assert!(u::has_rev(&map, 100) && u::get_rev(&map, 100) == 1000);
    u::drain_destroy(map);
}

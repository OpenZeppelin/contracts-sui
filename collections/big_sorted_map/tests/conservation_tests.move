/// Value-conservation suite - the economic core (value conservation, plus the child-id
/// conservation inside the structural ops). Every test stores a NON-DROPPABLE value
/// (`test_util::NoDrop`): the compiler then forbids implicitly dropping a value, so any path that
/// fails to thread every value back out simply will not compile - a silent `V: drop` conservation
/// bug becomes a build error. On top of that type-level guarantee, each test reads the surviving
/// value ids to prove the right values landed in the right place after splits, merges,
/// borrow-from-sibling, collapse, and the cross-tier bridge.
///
/// The well-formedness check is generic over `V`, so these non-drop trees get the SAME equal-depth /
/// half-full / routing == subtree-max check the u64 differential gets. Forced low degree (4,3).
module openzeppelin_big_sorted_map::conservation_tests;

use openzeppelin_big_sorted_map::big_sorted_map::{Self as bsm, BigSortedMap};
use openzeppelin_big_sorted_map::test_util as u;
use openzeppelin_sorted_map::sorted_map as sm;
use std::unit_test::assert_eq;

fun wf(m: &BigSortedMap<u64, u::NoDrop>): bool { u::bsm_well_formed(m, 4, 3, true) }

/// Build keys `1..=n` with NoDrop value-id `k*1000` (fresh inserts; the `none`s are consumed).
fun build_nd(n: u64, ctx: &mut TxContext): BigSortedMap<u64, u::NoDrop> {
    let mut map = bsm::new_with_config<u64, u::NoDrop>(4, 3, ctx);
    let mut k = 1u64;
    while (k <= n) {
        u::ins_nd(&mut map, k, u::nd(k * 1000)).destroy_none();
        k = k + 1;
    };
    map
}

// === non-drop V survives a multi-level split + a remove-driven merge/borrow churn ===

#[test]
fun nodrop_survives_split_and_rebalance() {
    let mut ctx = tx_context::dummy();
    let mut map = build_nd(12, &mut ctx); // forces splits to a multi-level tree
    assert_eq!(bsm::length(&map), 12);
    assert!(wf(&map));
    // every value present with its exact id (no copy, no loss across the splits).
    let mut k = 1u64;
    while (k <= 12) {
        assert!(u::has_nd(&map, k) && u::nd_value_id(&map, k) == k * 1000);
        k = k + 1;
    };
    // remove the evens (forces underflow -> borrow/merge); each removed value is RETURNED and must
    // be explicitly consumed (the compiler rejects an implicit drop of NoDrop).
    let mut k = 2u64;
    while (k <= 12) {
        let removed = u::rem_nd(&mut map, k);
        assert_eq!(u::nd_unwrap(removed.destroy_some()), k * 1000); // exact value came back out
        k = k + 2;
    };
    assert_eq!(bsm::length(&map), 6);
    assert!(wf(&map));
    // survivors intact after the structural churn moved values between nodes.
    let mut k = 1u64;
    while (k <= 11) {
        assert_eq!(u::nd_value_id(&map, k), k * 1000);
        k = k + 2;
    };
    u::drain_destroy_nd(map); // drains the rest, consuming every NoDrop, then destroy_empty
}

// === upsert RETURNS the displaced value (conserved, not dropped); new value stored ===

#[test]
fun nodrop_upsert_returns_old_value() {
    let mut ctx = tx_context::dummy();
    let mut map = build_nd(7, &mut ctx);
    // replace key 4's value; the OLD NoDrop must be returned (some), not silently burned.
    let ret = u::ins_nd(&mut map, 4, u::nd(40404));
    let old = ret.destroy_some();
    assert_eq!(u::nd_unwrap(old), 4000); // the displaced value, conserved
    assert_eq!(bsm::length(&map), 7); // upsert, not a fresh insert
    assert_eq!(u::nd_value_id(&map, 4), 40404); // new value in place
    assert!(wf(&map));
    u::drain_destroy_nd(map);
}

// === borrow_mut mutates V IN PLACE (no drop of the old NoDrop), keys unmoved ===

#[test]
fun nodrop_borrow_mut_in_place() {
    let mut ctx = tx_context::dummy();
    let mut map = build_nd(8, &mut ctx);
    u::set_nd(&mut map, 5, 55555); // mutate the NoDrop payload in place via &mut V
    assert_eq!(u::nd_value_id(&map, 5), 55555);
    assert_eq!(bsm::length(&map), 8);
    assert!(wf(&map)); // key 5 still in sorted position (only V changed)
    u::drain_destroy_nd(map);
}

// === pop_front / pop_back move each value out exactly once, in order ===

#[test]
fun nodrop_pop_conserves_in_order() {
    let mut ctx = tx_context::dummy();
    let mut map = build_nd(8, &mut ctx);
    // Consume each NoDrop UNCONDITIONALLY (a short-circuited `&&` would leave it undropped).
    let (k1, w1) = bsm::pop_front(&mut map);
    let id1 = u::nd_unwrap(w1);
    assert!(k1 == 1 && id1 == 1000);
    let (k8, w8) = bsm::pop_back(&mut map);
    let id8 = u::nd_unwrap(w8);
    assert!(k8 == 8 && id8 == 8000);
    assert_eq!(bsm::length(&map), 6);
    assert!(wf(&map));
    u::drain_destroy_nd(map);
}

// === pop_front_n / pop_back_n batch-drain moves each non-drop value out exactly once ===

#[test]
fun nodrop_pop_n_batch_conserves() {
    let mut ctx = tx_context::dummy();
    let mut map = build_nd(10, &mut ctx);
    // pop the first 3 as a parallel (keys, NoDrop-values) batch; consume every value.
    let (fk, mut fv) = bsm::pop_front_n(&mut map, 3);
    assert_eq!(fk, vector[1u64, 2, 3]);
    let id3 = u::nd_unwrap(fv.pop_back()); // values are index-aligned with keys [1,2,3]
    let id2 = u::nd_unwrap(fv.pop_back());
    let id1 = u::nd_unwrap(fv.pop_back());
    fv.destroy_empty();
    assert!(id1 == 1000 && id2 == 2000 && id3 == 3000);
    // pop the last 3 (descending key order); consume every value.
    let (bk, mut bv) = bsm::pop_back_n(&mut map, 3);
    assert_eq!(bk, vector[10u64, 9, 8]);
    let idr3 = u::nd_unwrap(bv.pop_back()); // aligned with [10,9,8] -> ids 10000,9000,8000
    let idr2 = u::nd_unwrap(bv.pop_back());
    let idr1 = u::nd_unwrap(bv.pop_back());
    bv.destroy_empty();
    assert!(idr1 == 10000 && idr2 == 9000 && idr3 == 8000);
    assert_eq!(bsm::length(&map), 4); // 4,5,6,7 remain
    assert!(wf(&map));
    u::drain_destroy_nd(map);
}

// === borrow_from_sibling moves a non-drop value between leaves intact ===

#[test]
fun nodrop_borrow_from_sibling_conserves() {
    let mut ctx = tx_context::dummy();
    // root[2,4,7], L0[1,2] L1[3,4] L2[5,6,7] (ids k*1000).
    let mut map = build_nd(7, &mut ctx);
    // remove 3 -> L1 underflows -> borrow_from_right moves key 5's (NoDrop) value into L1.
    let removed = u::rem_nd(&mut map, 3);
    assert_eq!(u::nd_unwrap(removed.destroy_some()), 3000);
    // key 5's value was physically moved to another leaf - it must be intact, not duplicated/lost.
    assert_eq!(u::nd_value_id(&map, 5), 5000);
    assert!(u::nd_value_id(&map, 4) == 4000 && u::nd_value_id(&map, 6) == 6000);
    assert_eq!(bsm::length(&map), 6);
    assert!(wf(&map));
    u::drain_destroy_nd(map);
}

// === a merge folds a non-drop leaf into its sibling; collapse conserves every value ===

#[test]
fun nodrop_merge_collapse_conserves() {
    let mut ctx = tx_context::dummy();
    let mut map = build_nd(4, &mut ctx); // root[2,4], L0[1,2] L1[3,4]
    // remove 1 -> L0 underflows, no spare sibling -> merge L1 into L0 -> root collapses to a leaf.
    let removed = u::rem_nd(&mut map, 1);
    assert_eq!(u::nd_unwrap(removed.destroy_some()), 1000);
    assert!(u::root_is_leaf(&map)); // collapsed
    // the merged-in values (from the absorbed sibling) survived the append + collapse.
    assert_eq!(u::nd_value_id(&map, 2), 2000);
    assert_eq!(u::nd_value_id(&map, 3), 3000);
    assert_eq!(u::nd_value_id(&map, 4), 4000);
    assert!(wf(&map));
    u::drain_destroy_nd(map);
}

// === the cross-tier bridge round-trips every (K, NoDrop) with no loss/duplication ===

#[test]
fun nodrop_bridge_roundtrip_conserves() {
    let mut ctx = tx_context::dummy();
    let src = u::sm_build_nd(13); // SortedMap<u64, NoDrop>, ids k*1000, uneven tail at degree 3
    // move-only bulk build into a multi-level BSM.
    let mut map = u::from_sm_nd_lowdeg(src, &mut ctx);
    assert_eq!(bsm::length(&map), 13);
    assert!(wf(&map));
    let mut k = 1u64;
    while (k <= 13) {
        assert_eq!(u::nd_value_id(&map, k), k * 1000);
        k = k + 1;
    };
    // drain back to a tier-1 SortedMap (move-only); the (K,V) multiset is identical.
    let back = bsm::into_sorted_map(&mut map);
    assert_eq!(openzeppelin_sorted_map::sorted_map::length(&back), 13);
    // `map` is emptied; tear it down. `back` holds the conserved NoDrop values - drain them too.
    bsm::destroy_empty(map);
    u::sm_drain_destroy_nd(back);
}

// === into_sorted_map's depth-0 single-leaf-root branch conserves every NoDrop ===
// into_sorted_map has two disjoint drain branches; the depth-0 (min_leaf_index==ROOT_INDEX) branch -
// take_root -> append the inline leaf's V-multiset -> reinstall a fresh empty leaf root - has zero
// coverage under ANY V (every other call site drains depth>=1). A drop/misthreading of the inline
// leaf's values is silent under V:drop; only a NoDrop witness on THIS branch catches it.

// Pins branch: into_sorted_map / given a depth-0 single-leaf-root NoDrop tree / it drains move-only and reinstalls an empty leaf root
#[test]
fun nodrop_into_sorted_map_single_leaf_root() {
    let mut ctx = tx_context::dummy();
    // leaf_max 3, only 2 entries -> a single inline leaf root (depth 0, min_leaf_index == ROOT_INDEX).
    let mut map = bsm::new_with_config<u64, u::NoDrop>(4, 3, &mut ctx);
    u::ins_nd(&mut map, 1, u::nd(1000)).destroy_none();
    u::ins_nd(&mut map, 2, u::nd(2000)).destroy_none();
    assert!(u::root_is_leaf(&map) && u::tree_depth(&map) == 0);
    let mut back = bsm::into_sorted_map(&mut map); // depth-0 take_root/append/reinstall path
    assert_eq!(sm::length(&back), 2);
    // Consume each NoDrop UNCONDITIONALLY (a short-circuited `&&` would leave it undropped -> no compile).
    let (k1, w1) = sm::pop_front(&mut back);
    let id1 = u::nd_unwrap(w1);
    assert!(k1 == 1 && id1 == 1000);
    let (k2, w2) = sm::pop_front(&mut back);
    let id2 = u::nd_unwrap(w2);
    assert!(k2 == 2 && id2 == 2000);
    sm::destroy_empty(back);
    assert!(bsm::is_empty(&map));
    assert!(u::bsm_well_formed(&map, 4, 3, true)); // reinstall: fresh empty leaf root
    bsm::destroy_empty(map);
}

// === borrow_from_left moves a non-drop value between leaves intact (the LEFT branch) ===
// borrow_from_left (pop_back(left) -> insert_at(child, 0)) is a DISTINCT V-move primitive from
// borrow_from_right (pop_front -> insert_at(tail)). Only the right branch has a NoDrop witness; the
// left branch runs only under droppable u64 (structural::borrow_from_left_sibling), where a
// copy/drop of V is not a compile error. The well-formedness check is value-blind, so it cannot pin this.

// Pins branch: borrow_from_left / given an underfull leaf whose LEFT sibling has spare / it moves the left max NoDrop into the child, no copy/drop
#[test]
fun nodrop_borrow_from_left_conserves() {
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new_with_config<u64, u::NoDrop>(4, 3, &mut ctx);
    u::ins_nd(&mut map, 1, u::nd(1000)).destroy_none();
    u::ins_nd(&mut map, 2, u::nd(2000)).destroy_none();
    u::ins_nd(&mut map, 3, u::nd(3000)).destroy_none();
    u::ins_nd(&mut map, 4, u::nd(4000)).destroy_none();
    u::ins_nd(&mut map, 0, u::nd(0)).destroy_none(); // L0=[0,1,2] gains a spare; root[2,4]
    assert!(wf(&map));
    // remove 3: L1=[3,4]->[4] underflows; left L0=[0,1,2] has spare and is PREFERRED ->
    // borrow_from_left moves key 2's NoDrop value to the FRONT of L1 (pop_back path).
    let removed = u::rem_nd(&mut map, 3);
    assert_eq!(u::nd_unwrap(removed.destroy_some()), 3000);
    // key 2's value was physically moved between leaves: intact, not duplicated/lost.
    assert!(u::has_nd(&map, 2) && u::nd_value_id(&map, 2) == 2000);
    assert!(u::nd_value_id(&map, 0) == 0 && u::nd_value_id(&map, 1) == 1000);
    assert_eq!(u::nd_value_id(&map, 4), 4000);
    assert_eq!(bsm::length(&map), 4);
    assert!(wf(&map));
    u::drain_destroy_nd(map);
}

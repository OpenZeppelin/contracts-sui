/// The published DIY-cursor primitive surface. This library ships no built-in cursor but freezes the
/// leaf-chain layout (`prev`/`next`, never-reused ids) and publishes `locate_leaf[_by]!`,
/// `borrow_node{,_mut}`, `node_leaf{,_mut}`, `leaf_value_at_mut`, `leaf_next`/`leaf_prev`,
/// `null_index` so an integrator can hand-roll the leaf-walk. These primitives are otherwise only
/// touched inside the well-formedness check's internal walk; this module exercises them AS the
/// consumer-facing cursor API a regression would otherwise slip past:
///   - locate a leaf in a multi-level tree and confirm it brackets the key;
///   - walk the chain forward (`leaf_next`) and backward (`leaf_prev`) and reconstruct the global
///     ordered key set, cross-checking against `keys_from`;
///   - mutate a value in place through the cursor (`leaf_value_at_mut`) - the O(1)/step hot path;
///   - a leaf id captured before a merge that frees it becomes a fail-LOUD `df::borrow`
///     abort (never-reused ids), not a silent stale read.
module openzeppelin_collections::big_sorted_map_cursor_tests;

use openzeppelin_collections::big_sorted_map::{Self as bsm, BigSortedMap};
use openzeppelin_collections::big_sorted_map_test_util as u;
use openzeppelin_collections::sorted_map as sm;
use std::unit_test::assert_eq;

fun build(n: u64, ctx: &mut TxContext): BigSortedMap<u64, u64> {
    let mut map = bsm::new_with_config<u64, u64>(4, 3, ctx);
    let mut k = 1u64;
    while (k <= n) { u::ins(&mut map, k, k * 10); k = k + 1; };
    map
}

/// Reconstruct the global key sequence by walking the leaf chain FORWARD from the leftmost leaf
/// (located via `locate_leaf!` of a below-min key) - the canonical DIY read cursor.
fun walk_forward(map: &BigSortedMap<u64, u64>): vector<u64> {
    let mut out = vector[];
    let mut cur = u::locate(map, 0); // 0 < every key -> the leftmost leaf
    while (cur != bsm::null_index()) {
        let node = bsm::borrow_node(map, cur);
        let leaf = bsm::node_leaf(node);
        let n = sm::length(leaf);
        let mut i = 0;
        while (i < n) { out.push_back(*sm::key_at(leaf, i)); i = i + 1; };
        cur = bsm::leaf_next(node);
    };
    out
}

/// Walk the chain BACKWARD from the rightmost leaf (`leaf_prev`), collecting keys descending.
fun walk_backward(map: &BigSortedMap<u64, u64>): vector<u64> {
    let mut out = vector[];
    let mut cur = u::locate(map, 1_000_000); // > every key -> the rightmost leaf
    while (cur != bsm::null_index()) {
        let node = bsm::borrow_node(map, cur);
        let leaf = bsm::node_leaf(node);
        let mut i = sm::length(leaf);
        while (i > 0) { i = i - 1; out.push_back(*sm::key_at(leaf, i)); };
        cur = bsm::leaf_prev(node);
    };
    out
}

// === locate + bidirectional leaf-walk reconstructs the canonical scan ===

#[test]
fun cursor_locate_and_bidirectional_walk() {
    let mut ctx = tx_context::dummy();
    let map = build(30, &mut ctx);
    assert!(u::tree_depth(&map) >= 2); // genuinely multi-level
    // locate a mid key: it must land in a NON-root df leaf that brackets the key.
    let leaf_id = u::locate(&map, 15);
    assert!(leaf_id != bsm::root_index());
    let node = bsm::borrow_node(&map, leaf_id);
    let leaf = bsm::node_leaf(node);
    let lo = *sm::key_at(leaf, 0);
    let hi = *sm::key_at(leaf, sm::length(leaf) - 1);
    assert!(lo <= 15 && 15 <= hi); // the located leaf contains-or-would-contain 15
    // the forward walk over the PUBLISHED primitives equals the canonical keys_from scan.
    let fwd = walk_forward(&map);
    assert_eq!(fwd, u::kfrom(&map, 0, true, 1000));
    assert_eq!(fwd.length(), 30);
    // the backward walk is the exact reverse.
    let bwd = walk_backward(&map);
    let mut rev = vector[];
    let mut i = fwd.length();
    while (i > 0) { i = i - 1; rev.push_back(*fwd.borrow(i)); };
    assert_eq!(bwd, rev);
    u::drain_destroy(map);
}

// === in-place value mutation through the cursor (leaf_value_at_mut), keys unmoved ===

#[test]
fun cursor_mutates_value_in_place() {
    let mut ctx = tx_context::dummy();
    let mut map = build(20, &mut ctx);
    let leaf_id = u::locate(&map, 13);
    // read the key at offset 0 of the located leaf, then mutate ITS value through the cursor.
    let key0 = *sm::key_at(bsm::node_leaf(bsm::borrow_node(&map, leaf_id)), 0);
    *bsm::leaf_value_at_mut(&mut map, leaf_id, 0) = 99_999;
    assert_eq!(u::get(&map, key0), 99_999); // the mutation took effect via the cursor
    assert!(u::bsm_well_formed(&map, 4, 3, true)); // keys still sorted (only V changed)
    u::drain_destroy(map);
}

// === a leaf id freed by a merge becomes a fail-LOUD abort, never a silent stale read ===

#[test]
#[expected_failure(abort_code = sui::dynamic_field::EFieldDoesNotExist)]
fun cursor_stale_id_after_merge_aborts_loud() {
    let mut ctx = tx_context::dummy();
    // root[2,4], L0[1,2] L1[3,4]: capture L1's df id, then remove 1 -> L1 merges into L0 and is
    // freed (remove_node), then the root collapses. Never-reused ids make a later
    // borrow of the stale id a clean df::borrow abort (fail-loud), not a shifted stale read.
    let mut map = bsm::new_with_config<u64, u64>(4, 3, &mut ctx);
    u::ins(&mut map, 1, 10);
    u::ins(&mut map, 2, 20);
    u::ins(&mut map, 3, 30);
    u::ins(&mut map, 4, 40);
    let stale = bsm::child_id_at(bsm::borrow_node(&map, bsm::root_index()), 1); // L1's id
    let _ = u::rem(&mut map, 1); // merge frees L1's df slot, root collapses
    // a stale DIY cursor that did not re-seed now borrows a freed id -> aborts in dynamic_field.
    let _ = bsm::is_leaf(bsm::borrow_node(&map, stale));
    u::drain_destroy(map); // unreachable; present so the function type-checks
}

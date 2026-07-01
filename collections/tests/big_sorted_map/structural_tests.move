/// The Tier-1 structural suite - white-box pins of the construction-only B+Tree invariants that
/// NO assert and NO type rule guards (a wrong rule ships silently; only the differential test +
/// this well-formedness check catch them). Every test forces low degree (leaf 3 / inner 4 - split
/// at 4 entries / 5 children, half-full floor 2) so a handful of ops triggers the whole cascade, and
/// asserts both the precise tree shape (via the published node-inspection surface) AND
/// `bsm_well_formed`.
///
/// Headline targets: first-split root relocation; copy-up split + slot discipline; new-global-max
/// right-spine bump; delete-interior-leaf-max routing cascade; borrow L/R; merge folds right->left;
/// root collapse; equal depth / half-full / routing.
module openzeppelin_collections::big_sorted_map_structural_tests;

use openzeppelin_collections::big_sorted_map::{Self as bsm, BigSortedMap};
use openzeppelin_collections::big_sorted_map_test_util as u;
use std::unit_test::assert_eq;

fun wf(m: &BigSortedMap<u64, u64>): bool { u::bsm_well_formed(m, 4, 3, true) }

// === first split relocates the leaf root into an inner root (depth 0 -> 1) ===

#[test]
fun first_split_relocates_root() {
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new_with_config<u64, u64>(4, 3, &mut ctx);
    // 1,2,3 fill the single leaf root exactly (3 == leaf_max), still depth 0.
    u::ins(&mut map, 1, 10);
    u::ins(&mut map, 2, 20);
    u::ins(&mut map, 3, 30);
    assert_eq!(u::tree_depth(&map), 0);
    assert!(u::root_is_leaf(&map));
    assert_eq!(u::root_child_count(&map), 3);
    assert!(wf(&map));
    // 4 overflows the leaf root -> split_root: a new inner root with two leaf children.
    u::ins(&mut map, 4, 40);
    assert_eq!(u::tree_depth(&map), 1);
    assert!(!u::root_is_leaf(&map));
    assert_eq!(u::root_child_count(&map), 2);
    // copy-up split: left half keeps its max as the separator; routing == subtree maxes.
    assert_eq!(u::root_routing_key_at(&map, 0), 2); // left leaf [1,2]
    assert_eq!(u::root_routing_key_at(&map, 1), 4); // right leaf [3,4]
    assert!(bsm::head(&map) == option::some(1) && bsm::tail(&map) == option::some(4));
    // every key still reachable across the new level.
    assert!(u::get(&map, 1) == 10 && u::get(&map, 4) == 40);
    assert!(wf(&map));
    u::drain_destroy(map);
}

// === an ascending run bumps the rightmost routing key of the right spine to each new max ===

#[test]
fun new_global_max_bumps_right_spine() {
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new_with_config<u64, u64>(4, 3, &mut ctx);
    let mut k = 1u64;
    while (k <= 20) {
        u::ins(&mut map, k, k * 10);
        // After every ascending insert the new key is the global max; the rightmost routing key of
        // the (inner) root must equal it (the right-spine bump reached the top).
        if (!u::root_is_leaf(&map)) {
            let last = u::root_child_count(&map) - 1;
            assert_eq!(u::root_routing_key_at(&map, last), k);
        };
        assert_eq!(bsm::tail(&map), option::some(k));
        assert!(wf(&map)); // the well-formedness check re-checks routing==subtree-max at EVERY node
        k = k + 1;
    };
    assert_eq!(bsm::length(&map), 20);
    u::drain_destroy(map);
}

// === repeated splits build a multi-level tree of equal depth, all keys reachable ===

#[test]
fun multi_level_growth_equal_depth() {
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new_with_config<u64, u64>(4, 3, &mut ctx);
    // middle-out insertion order so splits happen at interior positions (exercises slot
    // discipline: the left half's routing entry is inserted at the RECORDED child index, not the end).
    let order = vector[
        50u64,
        25,
        75,
        12,
        37,
        62,
        87,
        6,
        18,
        31,
        43,
        56,
        68,
        81,
        93,
        3,
        9,
        15,
        21,
        28,
        34,
        40,
        46,
        53,
        59,
        65,
        71,
        78,
        84,
        90,
        96,
    ];
    let mut i = 0;
    while (i < order.length()) {
        u::ins(&mut map, *order.borrow(i), *order.borrow(i) * 3);
        assert!(wf(&map)); // equal depth + routing correctness after every interior split
        i = i + 1;
    };
    assert!(u::tree_depth(&map) >= 2); // genuinely multi-level
    assert_eq!(bsm::length(&map), order.length());
    // every inserted key reachable with its value, none fabricated.
    let mut i = 0;
    while (i < order.length()) {
        let key = *order.borrow(i);
        assert_eq!(u::get(&map, key), key * 3);
        i = i + 1;
    };
    // a full ordered scan reconstructs the sorted key set (leaf chain intact, gap/dup-free).
    let all = u::kfrom(&map, 0, true, 1000);
    assert_eq!(all.length(), order.length());
    let mut j = 1;
    while (j < all.length()) {
        assert!(*all.borrow(j - 1) < *all.borrow(j));
        j = j + 1;
    };
    u::drain_destroy(map);
}

// === delete an INTERIOR leaf's max without underflow -> ancestor routing key cascades ===
// (A stale-high routing key still ROUTES correctly, so only a structural assertion catches it.)

#[test]
fun delete_interior_leaf_max_updates_routing() {
    let mut ctx = tx_context::dummy();
    let src = u::sm_build(9); // keys 1..=9, values k*10
    // bulk build -> L0=[1,2,3] L1=[4,5,6] L2=[7,8,9], root routing [3,6,9], depth 1.
    let mut map = u::from_sm_44(src, &mut ctx);
    assert!(u::bsm_well_formed(&map, 4, 4, true));
    assert_eq!(u::root_routing_key_at(&map, 1), 6); // L1's routing key starts at its max, 6
    // delete L1's max (6): L1 is the MIDDLE (non-last) child, 3 -> 2 entries (== floor, no underflow).
    assert_eq!(u::rem(&mut map, 6), option::some(60));
    // routing[1] MUST now be L1's new max, 5 (with the old bug it stranded at 6).
    assert_eq!(u::root_routing_key_at(&map, 1), 5);
    // and the well-formedness check confirms routing == subtree-max at every node.
    assert!(u::bsm_well_formed(&map, 4, 4, true));
    // functional cross-check: 6 gone, neighbours intact, navigation skips the gap.
    assert!(!u::has(&map, 6));
    assert!(u::get(&map, 5) == 50 && u::get(&map, 7) == 70);
    assert_eq!(u::nxt(&map, 5), option::some(7));
    u::drain_destroy(map);
}

// === via pop_back: the descend_rightmost path also rewrites the right-spine routing key ===
// (pop_back reaches do_remove through descend_rightmost, NOT find_path_by! - a distinct descent, so
//  its delete-max cascade is pinned white-box separately from the comparator-remove path above.)

#[test]
fun pop_back_updates_right_spine_routing() {
    let mut ctx = tx_context::dummy();
    let src = u::sm_build(9); // -> [1,2,3][4,5,6][7,8,9], root routing [3,6,9]
    let mut map = u::from_sm_44(src, &mut ctx);
    assert_eq!(u::root_routing_key_at(&map, 2), 9);
    // pop_back removes the global max 9; rightmost leaf [7,8,9] -> [7,8]; routing[2] -> new max 8.
    let (k, v) = bsm::pop_back(&mut map);
    assert!(k == 9 && v == 90);
    assert_eq!(u::root_routing_key_at(&map, 2), 8); // descend_rightmost path cascaded the routing key
    assert!(u::bsm_well_formed(&map, 4, 4, true));
    // pop again: [7,8] -> [7] underflows -> rebalance; the well-formedness check confirms structure stays well-formed.
    let (k2, _v2) = bsm::pop_back(&mut map);
    assert_eq!(k2, 8);
    assert!(u::bsm_well_formed(&map, 4, 4, true));
    assert_eq!(bsm::tail(&map), option::some(7));
    u::drain_destroy(map);
}

// === remove that underflows borrows from the RIGHT sibling (no merge, parent unchanged) ===

#[test]
fun borrow_from_right_sibling() {
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new_with_config<u64, u64>(4, 3, &mut ctx);
    // Build root[2,4,7], L0[1,2] L1[3,4] L2[5,6,7] (ins 1..7 ascending).
    let mut k = 1u64;
    while (k <= 7) { u::ins(&mut map, k, k * 10); k = k + 1; };
    assert_eq!(u::root_child_count(&map), 3);
    // remove 3: L1=[3,4] -> [4] underflows; left L0=[1,2] has no spare, right L2=[5,6,7] does ->
    // borrow_from_right moves 5 to L1 -> L1=[4,5], L2=[6,7]; routing[1] rewritten to L1's new max 5.
    assert_eq!(u::rem(&mut map, 3), option::some(30));
    assert_eq!(u::root_child_count(&map), 3); // BORROW, not merge: child count unchanged
    assert_eq!(u::root_routing_key_at(&map, 1), 5);
    assert_eq!(u::root_routing_key_at(&map, 2), 7);
    assert!(wf(&map));
    // no key lost / fabricated.
    assert!(!u::has(&map, 3));
    assert_eq!(u::kfrom(&map, 0, true, 100), vector[1u64, 2, 4, 5, 6, 7]);
    u::drain_destroy(map);
}

// === remove that underflows borrows from the LEFT sibling (preferred when it has spare) ===

#[test]
fun borrow_from_left_sibling() {
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new_with_config<u64, u64>(4, 3, &mut ctx);
    // ins 1,2,3,4 -> root[2,4], L0[1,2] L1[3,4]; ins 0 -> L0[0,1,2] (left sibling now has spare).
    u::ins(&mut map, 1, 10);
    u::ins(&mut map, 2, 20);
    u::ins(&mut map, 3, 30);
    u::ins(&mut map, 4, 40);
    u::ins(&mut map, 0, 0);
    assert_eq!(u::root_child_count(&map), 2);
    // remove 3: L1=[3,4] -> [4] underflows; left L0=[0,1,2] has spare (3>2) and is PREFERRED ->
    // borrow_from_left moves 2 to the front of L1 -> L0=[0,1], L1=[2,4]; routing[0] -> L0's new max 1.
    assert_eq!(u::rem(&mut map, 3), option::some(30));
    assert_eq!(u::root_child_count(&map), 2); // borrow, not merge
    assert_eq!(u::root_routing_key_at(&map, 0), 1);
    assert_eq!(u::root_routing_key_at(&map, 1), 4);
    assert!(wf(&map));
    assert_eq!(u::kfrom(&map, 0, true, 100), vector[0u64, 1, 2, 4]);
    u::drain_destroy(map);
}

// === a merge folds right->left and the root collapses (depth 1 -> 0) ===

#[test]
fun merge_folds_right_into_left_and_collapses_root() {
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new_with_config<u64, u64>(4, 3, &mut ctx);
    // ins 1,2,3,4 -> root[2,4], L0[1,2] L1[3,4], depth 1, exactly two children.
    u::ins(&mut map, 1, 10);
    u::ins(&mut map, 2, 20);
    u::ins(&mut map, 3, 30);
    u::ins(&mut map, 4, 40);
    assert!(u::tree_depth(&map) == 1 && u::root_child_count(&map) == 2);
    // remove 1: L0=[1,2] -> [2] underflows; neither sibling has spare (L1=[3,4] has 2) -> MERGE.
    // merge folds the RIGHT (L1) into the LEFT (L0) -> [2,3,4]; root drops to one child -> COLLAPSE.
    assert_eq!(u::rem(&mut map, 1), option::some(10));
    assert_eq!(u::tree_depth(&map), 0); // the only height-decrease path
    assert!(u::root_is_leaf(&map));
    assert_eq!(u::root_child_count(&map), 3); // promoted leaf [2,3,4]
    assert!(bsm::head(&map) == option::some(2) && bsm::tail(&map) == option::some(4));
    assert!(wf(&map));
    assert_eq!(u::kfrom(&map, 0, true, 100), vector[2u64, 3, 4]);
    u::drain_destroy(map);
}

// === drain a multi-level tree to empty, then assert NO df node is left orphaned under the UID ===
// The no-leak invariant has two halves: the oracle walks every REACHABLE node, but `object::delete`
// silently orphans any df left stranded under the UID, which a reachable-only walk cannot see. This
// pins the ORPHAN half: ids are monotone and never reused, so after a full drain every id ever handed
// out must be FREE. `live_df_node_count_for_testing` probes the whole alloc range; a teardown
// regression that strands a node leaves its df present, so this assert fails instead of leaking.

#[test]
fun drain_to_empty_leaves_no_orphan_df_nodes() {
    let mut ctx = tx_context::dummy();
    // min-degree floor (inner 4 / leaf 3): a small insert count forces depth >= 2 with many df nodes.
    let mut map = bsm::new_with_config<u64, u64>(4, 3, &mut ctx);
    let n = 40u64;
    let mut k = 1u64;
    while (k <= n) { u::ins(&mut map, k, k * 10); k = k + 1; };
    assert!(u::tree_depth(&map) >= 2); // genuinely multi-level: real inner df nodes were allocated
    assert!(bsm::live_df_node_count_for_testing(&map) > 0); // df arena is non-empty before the drain
    // Paged drain to empty (the prescribed teardown for a large tree).
    loop {
        let (keys, _vals) = bsm::pop_front_n(&mut map, 8);
        if (keys.is_empty()) break;
    };
    assert!(bsm::is_empty(&map));
    assert!(wf(&map)); // back to a well-formed single empty leaf root
    // THE pin: every allocated df id has been freed - zero orphans stranded under the UID.
    assert_eq!(bsm::live_df_node_count_for_testing(&map), 0);
    bsm::destroy_empty(map);
}

// === grow to a multi-level tree, then drain to empty; depth shrinks back, well-formedness holds ===

#[test]
fun grow_then_drain_to_empty_well_formed_every_step() {
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new_with_config<u64, u64>(4, 3, &mut ctx);
    let n = 30u64;
    let mut k = 1u64;
    while (k <= n) {
        u::ins(&mut map, k, k);
        assert!(wf(&map));
        k = k + 1;
    };
    assert!(u::tree_depth(&map) >= 2);
    // drain via pop_front; the tree rebalances/collapses back down, equal depth held throughout.
    let mut prev_depth = u::tree_depth(&map);
    while (!bsm::is_empty(&map)) {
        let (_, _) = bsm::pop_front(&mut map);
        let d = u::tree_depth(&map);
        assert!(d <= prev_depth); // depth is monotone non-increasing under a front drain
        prev_depth = d;
        assert!(wf(&map));
    };
    assert!(u::tree_depth(&map) == 0 && u::root_is_leaf(&map));
    bsm::destroy_empty(map);
}

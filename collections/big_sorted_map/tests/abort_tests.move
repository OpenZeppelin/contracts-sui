/// The abort surface: all SEVEN `big_sorted_map` library aborts (codes 0-6), each asserted FIRST
/// at THIS module's location, PLUS the one cross-module exception - `sorted_map::EBadSplit`,
/// which deliberately reports `location = sorted_map`. Also pins the affirmative total
/// API: the non-aborting ops return none/false/empty and chain through a PTB-shaped sequence without
/// unwinding, and the `pop_*_n` STOP-at-empty contract (NOT an abort).
///
/// Every BSM-owned `#[expected_failure]` pins BOTH `abort_code = ...big_sorted_map::E*` AND
/// `location = ...big_sorted_map`. The error constants are module-private but referenceable from a
/// dependent's test attribute.
module openzeppelin_big_sorted_map::abort_tests;

use openzeppelin_big_sorted_map::big_sorted_map::{Self as bsm, BigSortedMap};
use openzeppelin_big_sorted_map::test_util as u;
use openzeppelin_sorted_map::sorted_map as sm;
use std::unit_test::assert_eq;

// === code 0 - EMapNotEmpty: destroy_empty on a non-empty tree ===

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_big_sorted_map::big_sorted_map::EMapNotEmpty,
        location = openzeppelin_big_sorted_map::big_sorted_map,
    ),
]
fun destroy_empty_nonempty_aborts() {
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new<u64, u64>(&mut ctx);
    u::ins(&mut map, 1, 10);
    bsm::destroy_empty(map); // aborts off the cached length before deleting anything
}

// === code 1 - EKeyNotFound: borrow / borrow_mut on an absent key ===

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_big_sorted_map::big_sorted_map::EKeyNotFound,
        location = openzeppelin_big_sorted_map::big_sorted_map,
    ),
]
fun borrow_absent_aborts_at_bsm() {
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new_with_config<u64, u64>(4, 3, &mut ctx);
    let mut k = 1u64;
    while (k <= 8) { u::ins(&mut map, k, k); k = k + 1; };
    let _ = u::get(&map, 100); // absent: assert_key_found fires inside big_sorted_map
    u::drain_destroy(map);
}

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_big_sorted_map::big_sorted_map::EKeyNotFound,
        location = openzeppelin_big_sorted_map::big_sorted_map,
    ),
]
fun borrow_mut_absent_aborts_at_bsm() {
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new_with_config<u64, u64>(4, 3, &mut ctx);
    u::ins(&mut map, 1, 10);
    u::set(&mut map, 100, 999); // borrow_mut on an absent key
    u::drain_destroy(map);
}

// === code 1 - EKeyNotFound: an INTERIOR-gap miss (idx < leaf_len) - the silent-successor slot ===
// The two tests above miss ABOVE the global max (idx == leaf_len, where a dropped found-assert would
// hit a vector OOB). Neither exercises the interior-gap slot, where lower_bound idx < leaf_len: a
// dropped/reordered assert_key_found there SILENTLY returns the successor's &V (and for borrow_mut
// hands &mut to the WRONG key, with no abort). assert_key_found runs STRICTLY before leaf_value_at.

// Pins branch: borrow / given populated multi-level tree / when key in an interior gap / it aborts EKeyNotFound
#[test]
#[
    expected_failure(
        abort_code = openzeppelin_big_sorted_map::big_sorted_map::EKeyNotFound,
        location = openzeppelin_big_sorted_map::big_sorted_map,
    ),
]
fun borrow_interior_gap_miss_aborts_at_bsm() {
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new_with_config<u64, u64>(4, 3, &mut ctx); // inner4/leaf3 -> multi-level
    let mut k = 1u64;
    while (k <= 12) { u::ins(&mut map, k * 2, k * 100); k = k + 1; }; // evens 2..24 across df leaves
    let _ = u::get(&map, 11); // interior gap between 10 and 12; lower-bound idx < leaf_len -> abort
    u::drain_destroy(map);
}

// Pins branch: borrow_mut / given populated multi-level tree / when key in an interior gap / it aborts EKeyNotFound
#[test]
#[
    expected_failure(
        abort_code = openzeppelin_big_sorted_map::big_sorted_map::EKeyNotFound,
        location = openzeppelin_big_sorted_map::big_sorted_map,
    ),
]
fun borrow_mut_interior_gap_miss_aborts_at_bsm() {
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new_with_config<u64, u64>(4, 3, &mut ctx);
    let mut k = 1u64;
    while (k <= 12) { u::ins(&mut map, k * 2, k * 100); k = k + 1; };
    u::set(&mut map, 11, 999); // interior-gap borrow_mut miss -> must abort, not mutate key 12's value
    u::drain_destroy(map);
}

// === code 2 - EEmpty: pop_front / pop_back on an empty tree ===

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_big_sorted_map::big_sorted_map::EEmpty,
        location = openzeppelin_big_sorted_map::big_sorted_map,
    ),
]
fun pop_front_empty_aborts() {
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new<u64, u64>(&mut ctx);
    let (_k, _v) = bsm::pop_front(&mut map);
    u::drain_destroy(map);
}

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_big_sorted_map::big_sorted_map::EEmpty,
        location = openzeppelin_big_sorted_map::big_sorted_map,
    ),
]
fun pop_back_empty_aborts() {
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new<u64, u64>(&mut ctx);
    let (_k, _v) = bsm::pop_back(&mut map);
    u::drain_destroy(map);
}

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_big_sorted_map::big_sorted_map::EEmpty,
        location = openzeppelin_big_sorted_map::big_sorted_map,
    ),
]
fun pop_front_after_draining_aborts() {
    // Drain a singleton, then pop the now-empty tree: still EEmpty (the empty check is first).
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new<u64, u64>(&mut ctx);
    u::ins(&mut map, 7, 70);
    let (_k, _v) = bsm::pop_front(&mut map);
    let (_k2, _v2) = bsm::pop_front(&mut map);
    u::drain_destroy(map);
}

// === code 3 - EInvalidDegree: new_with_config below the half-fill floor (the DoS guard) ===

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_big_sorted_map::big_sorted_map::EInvalidDegree,
        location = openzeppelin_big_sorted_map::big_sorted_map,
    ),
]
fun new_with_config_low_leaf_degree_aborts() {
    let mut ctx = tx_context::dummy();
    // leaf degree 2 < LEAF_MIN_DEGREE (3) - would allow a 1-entry-per-leaf scan attack.
    let map = bsm::new_with_config<u64, u64>(4, 2, &mut ctx);
    bsm::destroy_empty(map);
}

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_big_sorted_map::big_sorted_map::EInvalidDegree,
        location = openzeppelin_big_sorted_map::big_sorted_map,
    ),
]
fun new_with_config_low_inner_degree_aborts() {
    let mut ctx = tx_context::dummy();
    // inner degree 3 < INNER_MIN_DEGREE (4).
    let map = bsm::new_with_config<u64, u64>(3, 3, &mut ctx);
    bsm::destroy_empty(map);
}

// === code 4 - EWouldExceedTier1EntryHeuristic: into_sorted_map past the tier-1 count cap ===
// SLOW (~tens of seconds): the heuristic is 10_000, so the tree must hold 10_001 entries. The
// capacity assert is statement 1 of into_sorted_map, firing BEFORE any drain (the tree stays intact
// on the abort path). This is the only test that builds a large tree; everything else forces low
// degree. (The 10_000 threshold is provisional - OQ-4.)

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_big_sorted_map::big_sorted_map::EWouldExceedTier1EntryHeuristic,
        location = openzeppelin_big_sorted_map::big_sorted_map,
    ),
]
fun into_sorted_map_over_capacity_aborts() {
    let mut ctx = tx_context::dummy();
    let mut src = sm::new<u64, u64>();
    let mut k = 1u64;
    while (k <= 10001) { sm::insert!(&mut src, k, k); k = k + 1; }; // ascending -> O(1) appends
    let mut map = bsm::from_sorted_map!(src, &mut ctx); // default degree: a cheap, shallow tree
    let drained = bsm::into_sorted_map(&mut map); // aborts at statement 1 (length > 10_000)
    // Unreachable (the line above aborts); present only so the function type-checks.
    sm::destroy_empty(drained);
    u::drain_destroy(map);
}

// === code 5 - ESourceNotSortedUnderComparator: from_sorted_map source misordered ===

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_big_sorted_map::big_sorted_map::ESourceNotSortedUnderComparator,
        location = openzeppelin_big_sorted_map::big_sorted_map,
    ),
]
fun from_sorted_map_unsorted_source_aborts() {
    let mut ctx = tx_context::dummy();
    let src = u::sm_build(6); // ASCENDING [1..6] under the map's default `<`
    // Bridge it under the REVERSE comparator `>`: the source is not strictly-increasing under `>`,
    // so the revalidation aborts on the first pair - BEFORE any df write (the tree never forms).
    let map = u::from_sm_rev(src, &mut ctx);
    u::drain_destroy(map);
}

// === code 6 - EWrongNodeKind: an asserting node accessor used on the wrong node kind ===

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_big_sorted_map::big_sorted_map::EWrongNodeKind,
        location = openzeppelin_big_sorted_map::big_sorted_map,
    ),
]
fun wrong_node_kind_inner_accessor_on_leaf_aborts() {
    let mut ctx = tx_context::dummy();
    let map = bsm::new<u64, u64>(&mut ctx); // empty tree: the root is a LEAF
    // `node_inner` on a leaf is a discriminant mismatch -> EWrongNodeKind (the D1 production guard).
    let _ = bsm::node_inner(bsm::borrow_node(&map, bsm::root_index()));
    bsm::destroy_empty(map);
}

// === code 6 - EWrongNodeKind: the MIRROR direction - a LEAF accessor on an INNER node ===
// node_leaf/node_leaf_mut assert n.is_leaf (the opposite-polarity assert from the node_inner-on-leaf
// case above). On <u64,u64> leaf and inner are the same type, so this assert is the ONLY backstop;
// it is the one of 12 assert! sites with no failure test. node_leaf is a published DIY-cursor
// primitive - exactly the misuse a cursor hits if it forgets is_leaf before node_leaf on a routing node.

// Pins branch: node_leaf / given an INNER node / when the leaf accessor is applied / it aborts EWrongNodeKind at the bsm location
#[test]
#[
    expected_failure(
        abort_code = openzeppelin_big_sorted_map::big_sorted_map::EWrongNodeKind,
        location = openzeppelin_big_sorted_map::big_sorted_map,
    ),
]
fun wrong_node_kind_leaf_accessor_on_inner_aborts() {
    let mut ctx = tx_context::dummy();
    // 4 inserts at leaf_max 3 split the leaf root -> the root becomes an INNER node.
    let mut map = bsm::new_with_config<u64, u64>(4, 3, &mut ctx);
    let mut k = 1u64;
    while (k <= 8) { u::ins(&mut map, k, k * 10); k = k + 1; };
    assert!(!u::root_is_leaf(&map)); // precondition: the root is now an inner node
    // node_leaf on the inner root is the discriminant mismatch in the UNTESTED direction.
    let _ = bsm::node_leaf(bsm::borrow_node(&map, bsm::root_index()));
    u::drain_destroy(map); // unreachable; present so the function type-checks
}

// === EBadSplit (sorted_map code 3) - the SOLE cross-module abort (location = sorted_map) ===

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_sorted_map::sorted_map::EBadSplit,
        location = openzeppelin_sorted_map::sorted_map,
    ),
]
fun split_off_out_of_bounds_aborts_at_sorted_map() {
    let mut s = u::sm_build(3); // len 3
    let extra = sm::split_off(&mut s, 100); // at > len -> EBadSplit at the MAP's location
    sm::destroy_empty(extra);
    sm::destroy_empty(s);
}

// === Positive: split_off at == len is valid (empty result, no abort) - the boundary case ===

#[test]
fun split_off_at_len_is_empty_no_abort() {
    let mut s = u::sm_build(3);
    let tail = sm::split_off(&mut s, 3); // at == len: valid, returns an empty map
    assert!(sm::is_empty(&tail));
    assert_eq!(sm::length(&s), 3);
    sm::destroy_empty(tail);
    let _d = s; // s is droppable (u64/u64)
}

// === Affirmative total API: non-pop ops never abort; pop_*_n stops at empty ===

#[test]
fun total_api_no_abort_on_empty_and_miss() {
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new_with_config<u64, u64>(4, 3, &mut ctx);
    // empty: every total op returns the empty answer, no abort.
    assert!(!u::has(&map, 7));
    assert!(u::rem(&mut map, 7).is_none());
    assert!(u::fnext(&map, 7, true).is_none());
    assert!(u::fprev(&map, 7, true).is_none());
    assert!(u::nxt(&map, 7).is_none());
    assert!(u::prv(&map, 7).is_none());
    assert_eq!(u::kfrom(&map, 0, true, 10), vector[]);
    // pop_*_n on empty returns empty WITHOUT aborting (the stop-at-empty contract, NOT EEmpty).
    let (ka, va) = bsm::pop_front_n(&mut map, 5);
    assert!(ka == vector[] && va == vector[]);
    let (kb, vb) = bsm::pop_back_n(&mut map, 5);
    assert!(kb == vector[] && vb == vector[]);
    // populated: miss on an interior gap and past the tail, still no abort.
    let mut k = 1u64;
    while (k <= 10) { u::ins(&mut map, k * 2, k); k = k + 1; }; // evens 2..20
    assert!(!u::has(&map, 7));
    assert!(u::rem(&mut map, 7).is_none());
    assert!(u::fnext(&map, 100, true).is_none());
    u::drain_destroy(map);
}

#[test]
fun ptb_shaped_chain_no_abort() {
    // A PTB-style chain runs end to end with no abort, on an empty then a populated tree - nothing
    // unwinds an earlier command. Routed through helpers so the chain expands no macros.
    let mut ctx = tx_context::dummy();
    let mut map: BigSortedMap<u64, u64> = bsm::new_with_config<u64, u64>(4, 3, &mut ctx);
    let _ = u::has(&map, 1);
    let _ = u::fnext(&map, 1, true);
    let _ = u::rem(&mut map, 1);
    let _ = u::ins(&mut map, 1, 100);
    let _ = u::kfrom(&map, 0, true, 5);
    let mut k = 2u64;
    while (k <= 6) { u::ins(&mut map, k, k * 100); k = k + 1; };
    let _ = u::has(&map, 3);
    let _ = u::fnext(&map, 3, false);
    let _ = u::rem(&mut map, 3);
    let _ = u::ins(&mut map, 3, 333);
    assert_eq!(u::kfrom(&map, 0, true, 10), vector[1u64, 2, 3, 4, 5, 6]);
    u::drain_destroy(map);
}

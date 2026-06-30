/// The comparator dimension - the worst footgun: a non-strict or inconsistent comparator silently
/// corrupts BOTH leaf order AND routing keys tree-wide, and is UNREPAIRABLE in place. The library
/// stores no comparator and ships no detection, so the test channel is the only catch.
///
/// This suite (1) proves the legitimate REVERSE comparator works end-to-end and is well-formed
/// under `>`; (2) turns comparator violations into RED well-formedness results - proving the
/// well-formedness check is NON-VACUOUS (a non-strict comparator's duplicate keys and an
/// inconsistent comparator's misroute both make `bsm_well_formed` return false); (3) pins coarse-
/// comparator BYTE fidelity at both the leaf and the routing key; and (4) round-trips a
/// non-integer struct key through the `_by` API. All ops route through `test_util`
/// wrappers. Comparator purity / reentrancy is compile-foreclosed - see the
/// commented snippet at the end.
module openzeppelin_big_sorted_map::comparator_tests;

use openzeppelin_big_sorted_map::big_sorted_map as bsm;
use openzeppelin_big_sorted_map::test_util as u;
use std::unit_test::assert_eq;

// === a consistently-applied REVERSE comparator is legitimate and value-conserving ===

#[test]
fun reverse_comparator_consistent() {
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new_with_config<u64, u64>(4, 3, &mut ctx);
    // build descending-ordered under `>` (insert in arbitrary order; the comparator defines order).
    let order = vector[5u64, 1, 9, 3, 7, 2, 8, 4, 6, 10];
    let mut i = 0;
    while (i < order.length()) {
        let k = *order.borrow(i);
        u::ins_rev(&mut map, k, k * 100);
        // well-formed under the REVERSE order (ascending = false): keys DESCEND down the leaf chain.
        assert!(u::bsm_well_formed(&map, 4, 3, false));
        i = i + 1;
    };
    // under `>`, `head` is the LARGEST numeric key and `tail` the smallest (order is flipped).
    assert_eq!(bsm::head(&map), option::some(10));
    assert_eq!(bsm::tail(&map), option::some(1));
    // a reverse-comparator keys_from page walks DESCENDING, and RESUMES gap-free: feed the last key
    // back with include=false to get the next contiguous descending page (under reverse lt).
    assert_eq!(u::kfrom_rev(&map, 100, true, 5), vector[10u64, 9, 8, 7, 6]);
    assert_eq!(u::kfrom_rev(&map, 6, false, 5), vector[5u64, 4, 3, 2, 1]); // resume, no overlap/gap
    // point ops agree under the same comparator.
    assert!(u::has_rev(&map, 7) && u::get_rev(&map, 7) == 700);
    assert_eq!(u::rem_rev(&mut map, 7), option::some(700));
    assert!(!u::has_rev(&map, 7));
    assert!(u::bsm_well_formed(&map, 4, 3, false));
    u::drain_destroy(map);
}

// === RED: a NON-STRICT comparator lands duplicate keys -> the well-formedness check catches it ===

#[test]
fun nonstrict_comparator_duplicates_caught_by_well_formed_check() {
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new_with_config<u64, u64>(4, 3, &mut ctx);
    u::ins(&mut map, 1, 10);
    u::ins(&mut map, 2, 20);
    u::ins(&mut map, 3, 30);
    assert!(u::bsm_well_formed(&map, 4, 3, true)); // well-formed so far
    // `<=` is NOT a strict order: derived equality (`!lt(a,b) && !lt(b,a)`) never fires, so
    // re-inserting key 2 is treated as FRESH and a DUPLICATE 2 lands (length grows).
    let ret = u::ins_le(&mut map, 2, 999);
    assert!(ret.is_none()); // not detected as a replace
    assert_eq!(bsm::length(&map), 4); // a duplicate key was created
    // THE POINT: the well-formedness check now returns FALSE - adjacent equal keys are not strictly
    // increasing. A black-box reachability test would not notice; the well-formedness check is the catch.
    assert!(!u::bsm_well_formed(&map, 4, 3, true));
    u::drain_destroy(map);
}

// === RED: an INCONSISTENT comparator misroutes -> the well-formedness check catches the corruption ===

#[test]
fun inconsistent_comparator_misroute_caught_by_well_formed_check() {
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new_with_config<u64, u64>(4, 3, &mut ctx);
    // build a MULTI-LEVEL tree under `<` (ascending).
    let mut k = 1u64;
    while (k <= 10) { u::ins(&mut map, k, k * 10); k = k + 1; };
    assert!(u::bsm_well_formed(&map, 4, 3, true));
    // insert a fresh key with the WRONG (descending) comparator into the ascending tree: under `>`,
    // 100 is the "smallest", so the inner descent routes it hard-LEFT and it lands at index 0 of the
    // leftmost leaf - out of order, corrupting the structure.
    u::ins_gt(&mut map, 100, 1000);
    // PIN that the misroute actually happened (not a coincidental valid landing): the fresh key
    // landed (length 11) and it sits at the FRONT, so `head` is now 100 (out of order).
    assert_eq!(bsm::length(&map), 11);
    assert_eq!(bsm::head(&map), option::some(100));
    // THE POINT: the well-formedness check (under the tree's true ascending order) now returns FALSE.
    assert!(!u::bsm_well_formed(&map, 4, 3, true));
    u::drain_destroy(map);
}

// === an inconsistent-comparator remove MISSES a present key (stranded, no abort) ===

#[test]
fun inconsistent_comparator_remove_strands() {
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new_with_config<u64, u64>(4, 3, &mut ctx);
    // multi-level ascending tree.
    let mut k = 1u64;
    while (k <= 12) { u::ins(&mut map, k, k * 10); k = k + 1; };
    // removing key 3 under the WRONG (descending) comparator misroutes at an inner node and reports
    // a MISS - remove is total, so it returns none WITHOUT aborting, leaving key 3 present and
    // STRANDED. The library cannot detect this; only the consumer's correct-comparator discipline can.
    assert!(u::rem_rev(&mut map, 3).is_none());
    assert!(u::has(&map, 3)); // still present under the true order
    assert_eq!(bsm::length(&map), 12); // nothing removed
    assert!(u::bsm_well_formed(&map, 4, 3, true)); // the tree itself is still well-formed (just a missed op)
    u::drain_destroy(map);
}

// === coarse-comparator upsert stores the NEW key bytes at the leaf ===

#[test]
fun coarse_upsert_stores_new_leaf_key_bytes() {
    let mut ctx = tx_context::dummy();
    // single-leaf coarse map ordered on `id`; `tag` is a byte-distinguishable payload in the KEY.
    let mut map = bsm::new_with_config<u::CoarseKey, u64>(4, 8, &mut ctx);
    u::ins_ck(&mut map, u::ck(1, 0), 10);
    u::ins_ck(&mut map, u::ck(2, 0), 20);
    u::ins_ck(&mut map, u::ck(3, 0), 30);
    assert_eq!(u::root_leaf_ck_tag(&map, 1), 0); // key id=2 currently carries tag 0
    // upsert id=2 with a byte-distinct key (tag 77) and a new value: id compares EQUAL, so it is a
    // replace - and the stored KEY bytes must become the caller's new bytes.
    let old = u::ins_ck(&mut map, u::ck(2, 77), 222);
    assert_eq!(old, option::some(20)); // replace returns the old value
    assert_eq!(bsm::length(&map), 3); // not a fresh insert
    assert_eq!(u::get_ck(&map, 2), 222); // new value stored
    assert_eq!(u::root_leaf_ck_tag(&map, 1), 77); // NEW key bytes stored at the leaf
    u::drain_destroy_ck(map);
}

// === a coarse upsert of a leaf-MAX propagates the new bytes into the ROUTING key ===

#[test]
fun coarse_upsert_of_subtree_max_propagates_to_routing() {
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new_with_config<u::CoarseKey, u64>(4, 3, &mut ctx);
    // 4 inserts split the leaf root -> root inner routes by coarse subtree-max:
    //   left leaf [10,20], right leaf [30,40], root routing ids [20, 40].
    u::ins_ck(&mut map, u::ck(10, 0), 1);
    u::ins_ck(&mut map, u::ck(20, 0), 2);
    u::ins_ck(&mut map, u::ck(30, 0), 3);
    u::ins_ck(&mut map, u::ck(40, 0), 4);
    assert!(!u::root_is_leaf(&map));
    assert_eq!(u::root_routing_ck_id(&map, 0), 20); // left subtree max id
    assert_eq!(u::root_routing_ck_tag(&map, 0), 0); // ... currently tag 0
    // upsert id=20 (the LEFT leaf's max, hence routing key 0) with byte-distinct tag 88.
    let old = u::ins_ck(&mut map, u::ck(20, 88), 999);
    assert_eq!(old, option::some(2));
    // the new key bytes must propagate into BOTH the leaf max AND the routing key.
    assert_eq!(u::child_leaf_ck_tag(&map, 0, 1), 88); // left leaf's max key bytes updated
    assert_eq!(u::root_routing_ck_tag(&map, 0), 88); // routing key bytes updated (the tree-level claim)
    assert_eq!(u::root_routing_ck_id(&map, 0), 20); // id (the lt-class) unchanged
    u::drain_destroy_ck(map);
}

// === a coarse REMOVE of a leaf-max refreshes the routing key's BYTES ===
// The two tests above pin coarse byte fidelity on the INSERT/upsert refresh only. The delete-max
// routing cascade fires from a DIFFERENT call site (do_remove's `if idx==new_len ... refresh`), and
// on a coarse comparator must carry the NEW max's BYTES (not the lt-class alone) into the routing key.
// That byte property is invisible to the u64 differential test (tag-blind; for u64 bytes are the lt-class).
// `rem_ck` + `root_routing_ck_tag` were scaffolded for exactly this and are otherwise dead.
//
// Fixture (degree 4,4): build L0=[id10,id15(tag99),id20] L1=[id30,id40,id50], root routing [20,50].
// Removing the left-leaf MAX id20 leaves L0=[id10,id15] (2 == floor, NO merge -> 2-level shape and the
// inner-root routing reads survive); the new L0 max is id15, a byte-distinct (tag 99) key.

// Pins branch: remove_by! / given a coarse comparator and a leaf-max that is a routing key / when the leaf-max is removed / it rewrites the routing key to the new max's BYTES
#[test]
fun coarse_remove_of_subtree_max_refreshes_routing_bytes() {
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new_with_config<u::CoarseKey, u64>(4, 4, &mut ctx);
    u::ins_ck(&mut map, u::ck(10, 0), 1);
    u::ins_ck(&mut map, u::ck(20, 0), 2);
    u::ins_ck(&mut map, u::ck(30, 0), 3);
    u::ins_ck(&mut map, u::ck(40, 0), 4); // leaf [10,20,30,40] (4 == leaf_max, no split yet)
    u::ins_ck(&mut map, u::ck(50, 0), 5); // overflow -> split: L0=[10,20] L1=[30,40,50], routing [20,50]
    u::ins_ck(&mut map, u::ck(15, 99), 6); // routes into L0 (15<20) -> L0=[10,15,20] (byte-distinct tag 99)
    assert!(!u::root_is_leaf(&map));
    assert!(u::root_routing_ck_id(&map, 0) == 20 && u::root_routing_ck_tag(&map, 0) == 0); // L0 max = id20 tag0
    // remove the left-leaf MAX id=20. Total -> some(2). New L0 max = id15 (tag 99); L0 now holds 2 >=
    // floor 2, so NO merge - the 2-level shape is preserved and the delete-max cascade fires.
    assert_eq!(u::rem_ck(&mut map, 20), option::some(2));
    assert_eq!(bsm::length(&map), 5);
    // on the REMOVE path: routing key 0 now carries id=15 AND its NEW bytes
    // tag=99 (not a stale {20,0} byte-copy and not a tag-zeroed synthetic).
    assert_eq!(u::root_routing_ck_id(&map, 0), 15); // routing id updated to the new subtree max
    assert_eq!(u::root_routing_ck_tag(&map, 0), 99); // NEW max BYTES propagated on the remove path
    assert_eq!(u::get_ck(&map, 15), 6); // id=15 still reachable with its value
    u::drain_destroy_ck(map);
}

// === a non-integer struct key round-trips through the `_by` API across a multi-level tree ===
// NOTE: the well-formedness check is u64-key specialized, so struct-key trees are verified here by point
// reachability + ordered-scan only; their STRUCTURAL correctness is covered TRANSITIVELY because the
// descent/cascade machinery is generic over K and identical to the u64 path the differential test
// exhaustively exercises (the comparator is just a lambda; only the field it reads differs).

#[test]
fun struct_key_by_roundtrip() {
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new_with_config<u::Key, u64>(4, 3, &mut ctx);
    let mut i = 0u64;
    let order = vector[5u64, 1, 9, 3, 7, 2, 8, 4, 6, 10, 11, 12];
    while (i < order.length()) {
        let id = *order.borrow(i);
        u::ins_k(&mut map, u::mk(id), id * 100);
        i = i + 1;
    };
    assert_eq!(bsm::length(&map), 12);
    assert!(u::has_k(&map, 7) && u::get_k(&map, 7) == 700);
    assert!(!u::has_k(&map, 99));
    assert_eq!(u::rem_k(&mut map, 7), option::some(700));
    assert!(!u::has_k(&map, 7));
    assert_eq!(bsm::length(&map), 11);
    // structural check on the STRUCT-key path: a full ascending scan yields strictly increasing ids.
    let scan = u::kf_k(&map, 0, 100);
    assert_eq!(scan.length(), 11);
    let mut i = 1;
    while (i < scan.length()) {
        assert!(u::key_id(scan.borrow(i - 1)) < u::key_id(scan.borrow(i)));
        i = i + 1;
    };
    u::drain_destroy_k(map);
}

// ===========================================================================
// Comparator purity / mutation-reentrancy is COMPILE-foreclosed (commented snippet)
// ===========================================================================
//
// The comparator lambda is consulted across many searches per descent; it must be pure and
// deterministic within one op. A non-deterministic lambda cannot be written in a deterministic
// unit test (Move tests have no randomness source), so the property is covered by construction
// (every comparator in this suite is a pure `*a < *b` / `a.id < b.id`). Mutation-reentrancy - a
// comparator that mutates the tree mid-search - is foreclosed by the borrow checker: the op already
// holds the tree `&mut`, so a lambda capturing it for a second `&mut` does not type-check:
//
//     bsm::insert_by!(&mut map, k, v, |a, b| { bsm::insert!(&mut map, 0, 0); *a < *b }); // E: borrow conflict

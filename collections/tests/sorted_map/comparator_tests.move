/// The comparator contract and the public-but-unchecked corruption surface.
///
/// The library stores no comparator, so order is meaningful only relative to a strict total
/// order threaded consistently. These tests pin both the legitimate case (a reverse
/// comparator used consistently conserves everything) and the two footguns (a non-strict
/// `<=` duplicates keys; mixing `<`/`>` strands values) - using `is_well_formed` to
/// turn the violation scenarios into red results. They also characterize the `insert_at`/
/// `remove_at` corruption surface, the upsert key-byte survival rule, and
/// why a non-deterministic comparator corrupts order.
module openzeppelin_collections::sorted_map_comparator_tests;

use openzeppelin_collections::sorted_map as sm;
use openzeppelin_collections::sorted_map_test_util::{Self as u, CoarseKey};
use std::unit_test::assert_eq;

// === Non-integer (struct) keys via the `_by` forms ===

#[test]
fun by_forms_struct_keys() {
    let mut m = sm::new<CoarseKey, u64>();
    u::ins_ck(&mut m, u::ck(30, 1), 300).destroy_none();
    u::ins_ck(&mut m, u::ck(10, 1), 100).destroy_none();
    u::ins_ck(&mut m, u::ck(20, 1), 200).destroy_none();
    assert_eq!(m.length(), 3);
    assert!(u::wf_ck(&m)); // ordered by id under the supplied comparator
    assert!(u::has_ck(&m, 20) && u::get_ck(&m, 20) == 200);
    assert!(!u::has_ck(&m, 25));
    assert_eq!(u::rm_ck(&mut m, 10), 100);
    assert!(u::wf_ck(&m));
}

// === A reverse comparator used CONSISTENTLY is legitimate ===

#[test]
fun reverse_comparator_consistent() {
    let mut m = sm::new<u64, u64>();
    u::ins_rev(&mut m, 10, 1).destroy_none();
    u::ins_rev(&mut m, 30, 3).destroy_none();
    u::ins_rev(&mut m, 20, 2).destroy_none();
    // physically descending: head() is the largest, tail() the smallest
    assert_eq!(m.head(), option::some(30));
    assert_eq!(m.tail(), option::some(10));
    assert!(u::wf_rev(&m)); // well-formed under `>` ...
    assert!(!u::wf(&m)); // ... but NOT under `<` (it is genuinely reversed)
    assert!(u::has_rev(&m, 20) && u::get_rev(&m, 20) == 2);
    // every value conserved
    assert_eq!(u::rm_rev(&mut m, 30), 3);
    assert_eq!(u::rm_rev(&mut m, 10), 1);
    assert_eq!(u::rm_rev(&mut m, 20), 2);
    m.destroy_empty();
}

// === Footgun (a): a non-strict `<=` never detects equality -> duplicate keys ===

#[test]
fun nonstrict_comparator_duplicates() {
    let mut m = sm::new<u64, u64>();
    u::ins_le(&mut m, 5, 1).destroy_none();
    // same key under `<=`: searching for 5 in [5], `lt(mk,target)` = `5<=5` is true, so the
    // search takes the lt-branch (lo=mid+1) and never reaches the equality branch - `found`
    // stays false and the second 5 lands as a fresh duplicate. (Equivalently: derived
    // equality `!(a<=b) && !(b<=a)` is unsatisfiable for a non-strict relation.)
    u::ins_le(&mut m, 5, 2).destroy_none();
    assert_eq!(m.length(), 2); // TWO entries comparing equal
    assert!(!u::wf(&m)); // the well-formedness check catches the non-strict disorder
}

// === Footgun (b): mixing `<` (build) and `>` (remove) strands a present key ===

#[test, expected_failure(abort_code = sm::EKeyNotFound)]
fun remove_with_mixed_comparator_abortss() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 1); // ascending build under `<`
    u::ins(&mut m, 20, 2);
    u::ins(&mut m, 30, 3);
    // remove a PRESENT key under `>`: the descending search reads ascending data, walks
    // the wrong way, and aborts due to not finding the key.
    u::rm_gt(&mut m, 10);
    abort
}

// === Public-but-unchecked surface: insert_at at a wrong index corrupts order ===

#[test]
fun insert_at_wrong_index_corrupts() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 1);
    u::ins(&mut m, 20, 2);
    u::ins(&mut m, 30, 3);
    // Misuse: jam a large key at index 0 (out of sorted position).
    m.insert_at(0, sm::new_entry(999, 9));
    assert_eq!(m.length(), 4);
    assert!(!u::wf(&m)); // the well-formedness check catches what production never re-checks
}

// === remove_at misuse still returns the value (no silent loss) ===

#[test]
fun remove_at_misuse_returns_value() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 1);
    u::ins(&mut m, 20, 2);
    u::ins(&mut m, 30, 3);
    let (k, v) = m.remove_at(0); // direct index op: returns (key, value) at index 0
    assert_eq!(k, 10); // key moved out, not lost
    assert_eq!(v, 1); // value moved out, not lost (move semantics)
    assert_eq!(m.length(), 2);
    assert!(u::wf(&m)); // removing the head left [20,30] well-formed
}

// === Out-of-bounds index aborts inside std::vector, not the library ===

#[test, expected_failure(abort_code = std::vector::EINDEX_OUT_OF_BOUNDS, location = std::vector)]
fun insert_at_oob_aborts_in_vector() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 1);
    m.insert_at(5, sm::new_entry(99, 9)); // index 5 on a length-1 map
}

// The `remove_at` companion: an out-of-bounds index aborts inside std::vector, not the library.
#[test, expected_failure(abort_code = std::vector::EINDEX_OUT_OF_BOUNDS, location = std::vector)]
fun remove_at_oob_aborts_in_vector() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 1);
    m.remove_at(5); // index 5 on a length-1 map
}

// === add_by under a custom (reverse) comparator: fresh inserts stay well-formed under `>` ===

#[test]
fun add_by_reverse_comparator() {
    let mut m = sm::new<u64, u64>();
    // Strict insert of distinct keys in arbitrary order under `>`: the map is consistently
    // reversed - well-formed under `>` (and NOT under `<`).
    u::add_rev(&mut m, 10, 100);
    u::add_rev(&mut m, 30, 300);
    u::add_rev(&mut m, 20, 200);
    assert_eq!(m.length(), 3);
    assert!(u::wf_rev(&m)); // strictly DEscending under `>`
    assert!(!u::wf(&m)); // ... hence not well-formed under `<`
    assert_eq!(u::get_rev(&m, 30), 300); // head under `>`
    assert_eq!(u::get_rev(&m, 10), 100); // tail under `>`
}

// === Upsert keeps the FIRST (stored) key bytes, observable under a coarse comparator ===

#[test]
fun upsert_coarse_comparator_key_bytes() {
    let mut m = sm::new<CoarseKey, u64>();
    u::ins_ck(&mut m, u::ck(1, 100), 10).destroy_none(); // id=1, tag=100
    // upsert with the SAME id but a DIFFERENT tag (same class under id-order)
    let old = u::ins_ck(&mut m, u::ck(1, 200), 20);
    assert_eq!(old, option::some(10)); // displaced value returned
    assert_eq!(m.length(), 1); // exactly one entry
    assert_eq!(u::get_ck(&m, 1), 20); // new value won
    assert_eq!(u::head_ck_tag(&m), 100); // upsert reuses the stored key: the FIRST key bytes survive
}

// === contains == borrow-succeeds under a custom comparator ===

#[test]
fun contains_borrow_agree_by() {
    let mut m = sm::new<CoarseKey, u64>();
    u::ins_ck(&mut m, u::ck(10, 0), 1).destroy_none();
    u::ins_ck(&mut m, u::ck(20, 0), 2).destroy_none();
    assert!(u::has_ck(&m, 10) && u::get_ck(&m, 10) == 1); // present: contains AND borrow succeed
    assert!(!u::has_ck(&m, 15)); // absent: contains false
}

/// The other half of the contains/borrow agreement under a custom comparator: when
/// `contains_by` is false, the matching `borrow_by` aborts EKeyNotFound at the library
/// location (it does not succeed).
#[test, expected_failure(abort_code = sm::EKeyNotFound, location = sm)]
fun borrow_by_absent_aborts() {
    let mut m = sm::new<CoarseKey, u64>();
    u::ins_ck(&mut m, u::ck(10, 0), 1).destroy_none();
    u::ins_ck(&mut m, u::ck(20, 0), 2).destroy_none();
    u::get_ck(&m, 15); // absent under the id-order comparator -> EKeyNotFound
}

// === A non-deterministic comparator corrupts order on an otherwise-fine map ===

#[test]
fun nondeterministic_comparator_corrupts() {
    let mut m = sm::new<u64, u64>();
    let mut ctr = 0u64;
    let mut i = 0;
    // A comparator whose answer depends on a mutable counter and ignores its arguments -
    // the canonical non-deterministic lambda. Within one binary search the two consecutive
    // calls always disagree (strict alternation), so the equality branch is never taken:
    // every key lands fresh, but at a position dictated by counter parity rather than its
    // value. Inserting an ascending sequence therefore yields an out-of-order vector. The
    // computation is fully deterministic, so the honest `<` well-formedness check stably
    // reports NOT well-formed: the library cannot detect the bad lambda.
    while (i < 16) {
        let _ = m.upsert_by!(&i, i, |_, _| {
            ctr = ctr + 1;
            ctr % 2 == 0
        });
        i = i + 1;
    };
    assert_eq!(m.length(), 16); // no collapse: every insert landed fresh
    assert!(!m.is_well_formed!()); // ... but order is broken
}

// === `_by` navigation under a CUSTOM (reverse) comparator: ceiling/floor are lt-relative ===
//
// The bare navigation tests (core_tests) pin the find_next_by/find_prev_by/next_key_by/
// prev_key_by macro BODIES via the |a,b| *a<*b default. What no bare test reaches is the
// SAME macros threaded with a non-default comparator. Built under `>`, the map is physically
// DESCENDING [30,20,10]; head() is the largest numeric key, "next" walks toward the smallest.

#[test]
fun navigation_by_reverse_comparator() {
    let mut m = sm::new<u64, u64>();
    u::ins_rev(&mut m, 10, 1);
    u::ins_rev(&mut m, 30, 3);
    u::ins_rev(&mut m, 20, 2); // physical order under `>`: [30, 20, 10]
    // forward cursor under `>` walks 30 -> 20 -> 10 and terminates at the lt-tail
    assert!(u::nxt_rev(&m, 30) == option::some(20) && u::nxt_rev(&m, 20) == option::some(10));
    assert_eq!(u::nxt_rev(&m, 10), option::none()); // next of lt-tail == none
    assert_eq!(u::prv_rev(&m, 10), option::some(20));
    assert_eq!(u::prv_rev(&m, 30), option::none()); // prev of lt-head == none
    // ceiling vs strict-next on a present key, then an absent target (lt-relative)
    assert_eq!(u::fnext_rev(&m, 20, true), option::some(20)); // include returns self
    assert_eq!(u::fnext_rev(&m, 20, false), option::some(10)); // strict-next under `>` is 10
    assert_eq!(u::fnext_rev(&m, 25, true), option::some(20)); // absent: lt-ceiling is 20
    assert_eq!(u::fprev_rev(&m, 20, false), option::some(30)); // strict-prev under `>` is 30
    assert_eq!(u::fprev_rev(&m, 5, true), m.tail()); // lt-floor at the extreme == tail
}

// === `keys_from_by` under a reverse comparator: contiguous lt-ascending page, resumable ===

#[test]
fun keys_from_by_reverse_comparator() {
    let mut m = sm::new<u64, u64>();
    u::ins_rev(&mut m, 10, 1);
    u::ins_rev(&mut m, 20, 2);
    u::ins_rev(&mut m, 30, 3); // physical [30, 20, 10]
    assert_eq!(u::kfrom_rev(&m, 30, true, 2), vector[30, 20]);
    assert_eq!(u::kfrom_rev(&m, 20, false, 2), vector[10]); // resume: no overlap, no gap
    assert_eq!(u::kfrom_rev(&m, 35, true, 10), vector[30, 20, 10]); // from beyond lt-head -> full
    assert_eq!(u::kfrom_rev(&m, 5, true, 10), vector[]); // from past lt-tail -> empty
    assert_eq!(u::kfrom_rev(&m, 30, true, 0), vector[]); // limit 0 -> empty
}

// === borrow_mut_by (the one point-access `_by` macro otherwise never invoked) ===

/// Present key under a custom comparator: borrow_mut_by yields an order-safe `&mut V`
/// (it returns `&mut V`, never `&mut Entry`, so the key cannot be desynced).
#[test]
fun borrow_mut_by_persists_order_safe() {
    let mut m = sm::new<CoarseKey, u64>();
    u::ins_ck(&mut m, u::ck(10, 1), 100).destroy_none();
    u::ins_ck(&mut m, u::ck(20, 1), 200).destroy_none();
    u::ins_ck(&mut m, u::ck(30, 1), 300).destroy_none();
    u::set_ck(&mut m, 20, 999); // *borrow_mut_by!(.., |a,b| a.id < b.id) = 999
    assert_eq!(u::get_ck(&m, 20), 999); // write persisted
    assert!(u::wf_ck(&m)); // order intact (key not desynced)
    assert!(u::get_ck(&m, 10) == 100 && u::get_ck(&m, 30) == 300); // neighbors untouched
}

/// Absent key under a custom comparator: borrow_mut_by aborts EKeyNotFound at the library
/// location (the mutable companion to borrow_by_absent_aborts).
#[test, expected_failure(abort_code = sm::EKeyNotFound, location = sm)]
fun borrow_mut_by_absent_aborts() {
    let mut m = sm::new<CoarseKey, u64>();
    u::ins_ck(&mut m, u::ck(10, 0), 1).destroy_none();
    u::ins_ck(&mut m, u::ck(20, 0), 2).destroy_none();
    u::set_ck(&mut m, 15, 0); // absent under the id-order comparator -> EKeyNotFound
}

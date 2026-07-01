/// The public-but-unchecked bulk structural primitives `split_off` / `append`.
///
/// These are `public` (not `public(package)`) only to serve the sibling `big_sorted_map`,
/// whose B+Tree node payload IS a `SortedMap`: splitting/merging tree nodes are positional,
/// comparator-free moves. They are NOT a supported map API and are an ORDER-CORRUPTION
/// surface if their (unchecked) preconditions are violated - the same class as `insert_at`/
/// `remove_at`. This module pins their observable behavior at `sorted_map`'s own
/// audited boundary, where `big_sorted_map`'s differential suite would otherwise be the only
/// witness. Every value-bearing case runs under the non-droppable `NoDrop` witness so a
/// dropped/duplicated value is a BUILD error, not a silent loss.
///
/// `split_off(self, at)` moves `[at, len)` into a fresh map (self keeps `[0, at)`), aborts
/// `EBadSplit` if `at > len`. `append(self, other)` move-concatenates `other` onto
/// `self`. Both are pure moves - no `V` is copied or dropped - so they are correct for a
/// non-`drop` `V`.
module openzeppelin_collections::sorted_map_structural_tests;

use openzeppelin_collections::sorted_map as sm;
use openzeppelin_collections::sorted_map_test_util::{Self as u, NoDrop};
use std::unit_test::assert_eq;

// === split_off: interior split moves the suffix, both halves stay sorted & disjoint ===

#[test]
fun split_off_moves_suffix() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 1);
    u::ins(&mut m, 20, 2);
    u::ins(&mut m, 30, 3);
    u::ins(&mut m, 40, 4);
    u::ins(&mut m, 50, 5);
    let ret = sm::split_off(&mut m, 2); // self keeps [10,20]; ret = [30,40,50]
    assert!(sm::length(&m) == 2 && sm::length(&ret) == 3);
    assert!(u::wf(&m) && u::wf(&ret)); // both halves still strictly increasing
    assert!(sm::head(&m) == option::some(10) && sm::tail(&m) == option::some(20));
    assert!(sm::head(&ret) == option::some(30) && sm::tail(&ret) == option::some(50));
    assert!(*sm::tail(&m).borrow() < *sm::head(&ret).borrow()); // disjoint: retained < returned
    assert!(u::get(&m, 10) == 1 && u::get(&ret, 40) == 4); // values travelled with their keys
}

// === split_off boundary indices: at==0 (self emptied) and at==len (result empty), both valid ===

#[test]
fun split_off_boundary_indices() {
    // at == 0 on an EMPTY map -> both halves empty (degenerate edge, still valid: 0 <= 0)
    let mut z = sm::new<u64, u64>();
    let zr = sm::split_off(&mut z, 0);
    assert!(sm::is_empty(&z) && sm::is_empty(&zr));
    sm::destroy_empty(z);
    sm::destroy_empty(zr);

    // at == 0 -> self emptied, result == the whole map
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 1);
    u::ins(&mut m, 20, 2);
    u::ins(&mut m, 30, 3);
    let ret = sm::split_off(&mut m, 0);
    assert!(sm::is_empty(&m) && sm::length(&ret) == 3 && u::wf(&ret));
    sm::destroy_empty(m);

    // at == len -> self unchanged, result empty (the upper bound is INCLUSIVE: no abort)
    let mut m2 = sm::new<u64, u64>();
    u::ins(&mut m2, 10, 1);
    u::ins(&mut m2, 20, 2);
    let n = sm::length(&m2);
    let ret2 = sm::split_off(&mut m2, n);
    assert!(sm::length(&m2) == 2 && sm::is_empty(&ret2) && u::wf(&m2));
    sm::destroy_empty(ret2);
}

// === split_off at > len aborts EBadSplit at the LIBRARY location (the forced-public surface's only abort) ===

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_collections::sorted_map::EBadSplit,
        location = openzeppelin_collections::sorted_map,
    ),
]
fun split_off_at_gt_len_aborts() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 1);
    u::ins(&mut m, 20, 2);
    let _ret = sm::split_off(&mut m, 3); // at=3 > len=2 -> EBadSplit
}

// === split_off is move-only: both halves conserve a non-droppable V multiset ===

#[test]
fun split_off_conserves_nodrop() {
    let mut m = sm::new<u64, NoDrop>();
    // id(i) = i*7 + 1 ties each value to its key, catching a key->value misassociation
    let mut i = 0;
    while (i < 6) {
        u::ins_nd(&mut m, i, u::nd(i * 7 + 1)).destroy_none();
        i = i + 1;
    };
    let mut ret = sm::split_off(&mut m, 3); // m = [0,1,2]; ret = [3,4,5]
    let mut cnt = 0u64;
    while (!sm::is_empty(&m)) {
        let (k, w) = sm::pop_front(&mut m);
        assert_eq!(u::nd_unwrap(w), k * 7 + 1); // retained half: value matches its own key
        cnt = cnt + 1;
    };
    while (!sm::is_empty(&ret)) {
        let (k, w) = sm::pop_front(&mut ret);
        assert_eq!(u::nd_unwrap(w), k * 7 + 1); // moved half: value matches its own key
        cnt = cnt + 1;
    };
    assert_eq!(cnt, 6); // every value came back out - none lost (compile-enforced), none duplicated
    sm::destroy_empty(m);
    sm::destroy_empty(ret);
}

// === append move-concatenates a strictly-later, disjoint map; result stays sorted ===

#[test]
fun append_concatenates() {
    let mut a = sm::new<u64, u64>();
    u::ins(&mut a, 10, 1);
    u::ins(&mut a, 20, 2);
    let mut b = sm::new<u64, u64>();
    u::ins(&mut b, 30, 3);
    u::ins(&mut b, 40, 4);
    sm::append(&mut a, b); // b is consumed by move
    assert!(sm::length(&a) == 4 && u::wf(&a));
    assert!(sm::head(&a) == option::some(10) && sm::tail(&a) == option::some(40));
    assert_eq!(u::get(&a, 30), 3); // values carried across the concat
}

// === append is move-only: the concatenated non-droppable V multiset is conserved ===

#[test]
fun append_conserves_nodrop() {
    let mut a = sm::new<u64, NoDrop>();
    let mut b = sm::new<u64, NoDrop>();
    let mut i = 0;
    while (i < 3) { u::ins_nd(&mut a, i, u::nd(i * 7 + 1)).destroy_none(); i = i + 1; };
    while (i < 6) { u::ins_nd(&mut b, i, u::nd(i * 7 + 1)).destroy_none(); i = i + 1; };
    sm::append(&mut a, b); // every V moved, nothing dropped (no V: drop bound)
    let mut cnt = 0u64;
    while (!sm::is_empty(&a)) {
        let (k, w) = sm::pop_front(&mut a);
        assert_eq!(u::nd_unwrap(w), k * 7 + 1);
        cnt = cnt + 1;
    };
    assert_eq!(cnt, 6);
    sm::destroy_empty(a);
}

// === append degenerate edges: an empty operand on either side is a no-op / a move ===

#[test]
fun append_empty_edges() {
    // append(a, empty) leaves self unchanged
    let mut a = sm::new<u64, u64>();
    u::ins(&mut a, 10, 1);
    u::ins(&mut a, 20, 2);
    let empty = sm::new<u64, u64>();
    sm::append(&mut a, empty); // empty operand consumed
    assert!(sm::length(&a) == 2 && u::wf(&a) && u::get(&a, 20) == 2);
    // append(empty, b) makes self become exactly b
    let mut e = sm::new<u64, u64>();
    let mut b = sm::new<u64, u64>();
    u::ins(&mut b, 30, 3);
    u::ins(&mut b, 40, 4);
    sm::append(&mut e, b);
    assert!(sm::length(&e) == 2 && u::wf(&e));
    assert!(sm::head(&e) == option::some(30) && sm::tail(&e) == option::some(40));
}

// === append's precondition is UNCHECKED: violating it corrupts order ===

#[test]
fun append_violated_precondition_corrupts() {
    // append assumes other is disjoint and strictly after self (self.tail < other.head). It
    // performs NO order check (a check would need a comparator). Violating it leaves the vector
    // unsorted - the same public-but-unchecked corruption surface as insert_at, caught only by
    // the test-only well-formedness check, never re-validated in production.
    let mut a = sm::new<u64, u64>();
    u::ins(&mut a, 10, 1);
    u::ins(&mut a, 40, 4);
    let mut b = sm::new<u64, u64>();
    u::ins(&mut b, 20, 2);
    u::ins(&mut b, 30, 3); // b's range overlaps/precedes a's tail
    sm::append(&mut a, b); // precondition violated: a.tail (40) is NOT < b.head (20)
    assert_eq!(sm::length(&a), 4);
    assert!(!u::wf(&a)); // result [10,40,20,30] is not strictly increasing - the check catches it
}

// === Round-trip property: split_off then append-back reconstructs the original exactly ===

#[test]
fun split_off_then_append_roundtrip() {
    let mut m = u::build_scrambled(40);
    let before = u::kfrom(&m, 0, true, 1000); // full ascending key list
    let part = sm::split_off(&mut m, 17); // m keeps [0,17); part = [17,40)
    sm::append(&mut m, part); // precondition m.tail < part.head holds by construction
    assert_eq!(u::kfrom(&m, 0, true, 1000), before); // identical key sequence restored
    assert!(sm::length(&m) == 40 && u::wf(&m));
}

/// Type-level / ability facts and structural composability.
///
/// Most of these properties are enforced by Move's type system, so "the test is that it
/// compiles": ability witnesses, value/store embedding, distinct instantiations coexisting,
/// the read-only `entries` surface, two independent maps, and the per-operation K/V ability
/// lattice (each op instantiated at the minimal K/V abilities its body needs). The NEGATIVE
/// half (a resource-V map cannot be copied/dropped, `e.key` cannot be read, `entries_mut`
/// does not exist, a bare macro rejects `address`, a bare `SortedMap` cannot be transferred)
/// is a build-time fact - documented as the commented non-compiling snippets at the bottom,
/// to be exercised by review/CI, not a runnable `#[test]`.
module openzeppelin_collections::sorted_map_type_tests;

use openzeppelin_collections::sorted_map::{Self as sm, SortedMap};
use openzeppelin_collections::sorted_map_test_util::{
    Self as u,
    NoDrop,
    Bid,
    Ask,
    StoreKey,
    CopyKey,
    DropKey,
};
use std::unit_test::assert_eq;

// Ability witnesses: instantiation fails to compile if the type lacks the ability.
// Referencing `T` via `type_name::with_defining_ids` keeps the parameter used; the
// ability constraint on each function is the actual assertion.
fun needs_store<T: store>() { let _ = std::type_name::with_defining_ids<T>(); }

fun needs_copy<T: copy>() { let _ = std::type_name::with_defining_ids<T>(); }

fun needs_drop<T: drop>() { let _ = std::type_name::with_defining_ids<T>(); }

#[test]
fun ability_witnesses() {
    // store holds for BOTH the value-V and resource-V maps
    needs_store<SortedMap<u64, u64>>();
    needs_store<SortedMap<u64, NoDrop>>();
    // copy + drop materialize jointly only for the value-V map
    needs_copy<SortedMap<u64, u64>>();
    needs_drop<SortedMap<u64, u64>>();
}

#[test]
fun copy_droppable_map() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 1, 10);
    let c = copy m; // copy materializes for u64/u64
    assert_eq!(u::get(&m, 1), 10);
    assert_eq!(u::get(&c, 1), 10);
    // both m and c are implicitly dropped here (drop materializes)
}

public struct Holder has store {
    m: SortedMap<u64, u64>,
}

#[test]
fun embed_in_store_struct() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 1, 10);
    let h = Holder { m }; // a SortedMap embeds directly in a `has store` struct
    let Holder { m: inner } = h;
    assert_eq!(u::get(&inner, 1), 10);
}

#[test]
fun distinct_instantiations_coexist() {
    // SortedMap<u64,Bid> and SortedMap<u64,Ask> are distinct, non-interchangeable types
    // that coexist in one function.
    let mut bids = sm::new<u64, Bid>();
    let mut asks = sm::new<u64, Ask>();
    u::ups_bid(&mut bids, 100, u::bid(1)).destroy_none();
    u::ups_ask(&mut asks, 200, u::ask(2)).destroy_none();
    assert_eq!(u::get_bid_px(&bids, 100), 1);
    assert_eq!(u::get_ask_px(&asks, 200), 2);
}

#[test]
fun two_maps_independent() {
    // Interleaved mutation of two maps - each is an independent Move value.
    let mut a = sm::new<u64, u64>();
    let mut b = sm::new<u64, u64>();
    u::ins(&mut a, 1, 10);
    u::ins(&mut b, 1, 99);
    u::ins(&mut a, 2, 20);
    u::rm(&mut b, 1);
    assert!(u::get(&a, 1) == 10 && u::get(&a, 2) == 20);
    assert_eq!(a.length(), 2);
    assert!(b.is_empty());
}

#[test]
fun entries_read_only() {
    // The only bulk view is an immutable &vector<Entry>; entries are read via accessors.
    // This pins the positive read path only; the no-mutable-escape-hatch half (no
    // `entries_mut`/`into_entries`, and `&vector` cannot coerce to `&mut vector`) is
    // a build-time fact, kept as the commented compile-fail negatives at the bottom of this file.
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 1, 10);
    u::ins(&mut m, 2, 20);
    let es = m.entries();
    assert_eq!(es.length(), 2);
    assert_eq!(*es.borrow(0).key(), 1);
    assert_eq!(*es.borrow(0).value(), 10);
    assert_eq!(*es.borrow(1).key(), 2);
}

// `value_at`/`value_at_mut` are the low-level positional accessors the point-access macros
// expand to (`borrow!`/`borrow_mut!` read and write through them). This pins both the read
// (`value_at`) and the order-safe write (`value_at_mut` yields `&mut V`, never `&mut Entry`)
// at sorted_map's own audited boundary, independent of the macro layer.
#[test]
fun value_at_reads_and_writes() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 1);
    u::ins(&mut m, 20, 2);
    assert_eq!(*m.value_at(0), 1);
    assert_eq!(*m.value_at(1), 2);
    *m.value_at_mut(1) = 99; // write through the &mut V
    assert_eq!(*m.value_at(1), 99); // re-read confirms the mutation persisted
    assert_eq!(u::get(&m, 20), 99); // and the public borrow agrees
}

// ===========================================================================
// K/V ability lattice: each op family instantiated at the MINIMAL K/V abilities its body needs.
// The wrapper in test_util instantiates the op at a lattice corner (so the macro expands there,
// not here); the assertions confirm the op also BEHAVES. The complementary "must NOT compile"
// half is the negative-snippet block below.
// ===========================================================================

#[test]
fun value_conserving_ops_need_nothing_of_key() {
    // K = StoreKey (store only: no copy, no drop). The lifecycle and value-conserving ops
    // (add/contains/borrow/borrow_mut/remove) all instantiate - they constrain K with nothing.
    let mut m = sm::new<StoreKey, u64>();
    u::sk_add(&mut m, 20, 200);
    u::sk_add(&mut m, 10, 100);
    u::sk_add(&mut m, 30, 300);
    assert_eq!(m.length(), 3);
    assert!(u::sk_has(&m, 20) && !u::sk_has(&m, 25));
    assert_eq!(u::sk_get(&m, 10), 100);
    u::sk_set(&mut m, 10, 111); // borrow_mut_by
    assert_eq!(u::sk_get(&m, 10), 111);
    let (kid, v) = u::sk_remove(&mut m, 20); // remove_by returns the no-drop key + value
    assert!(kid == 20 && v == 200);
    assert_eq!(m.length(), 2);
    // drain via pop (regular funs); each no-drop key is unwrapped, never dropped
    let (k, _v) = m.pop_front();
    assert_eq!(k.store_key_unwrap(), 10);
    let (k, _v) = m.pop_back();
    assert_eq!(k.store_key_unwrap(), 30);
    m.destroy_empty();
}

#[test]
fun from_sorted_needs_nothing_of_key() {
    // from_sorted_keys_values_by constrains K with nothing: build from store-only keys.
    let mut m = u::sk_from_sorted(vector[10, 20, 30], vector[100, 200, 300]);
    assert_eq!(m.length(), 3);
    assert!(u::sk_has(&m, 20) && u::sk_get(&m, 30) == 300);
    let (k, _v) = m.pop_back();
    assert_eq!(k.store_key_unwrap(), 30);
    let (k, _v) = m.pop_back();
    assert_eq!(k.store_key_unwrap(), 20);
    let (k, _v) = m.pop_front();
    assert_eq!(k.store_key_unwrap(), 10);
    m.destroy_empty();
}

#[test]
fun key_copying_ops_need_copy_not_drop() {
    // K = CopyKey (copy + store, NO drop). head/tail/keys and all of navigation/pagination copy
    // keys out, so `copy` alone suffices - `drop` is not required. `add` also works (moves the
    // key in). (upsert does NOT compile here - see the negatives below.)
    let mut m = sm::new<CopyKey, u64>();
    u::ck2_add(&mut m, 10, 100);
    u::ck2_add(&mut m, 20, 200);
    u::ck2_add(&mut m, 30, 300);
    assert_eq!(u::ck2_head(&m), option::some(10));
    assert_eq!(u::ck2_tail(&m), option::some(30));
    assert_eq!(u::ck2_keys(&m), vector[10, 20, 30]);
    assert_eq!(u::ck2_fnext(&m, 15, true), option::some(20));
    assert_eq!(u::ck2_fnext(&m, 20, false), option::some(30));
    assert_eq!(u::ck2_fprev(&m, 25, false), option::some(20));
    assert_eq!(u::ck2_nxt(&m, 20), option::some(30));
    assert_eq!(u::ck2_prv(&m, 20), option::some(10));
    assert_eq!(u::ck2_kfrom(&m, 10, true, 2), vector[10, 20]);
    // drain (CopyKey has no drop): unwrap each popped key
    let (k, _v) = m.pop_front();
    assert_eq!(k.copy_key_unwrap(), 10);
    let (k, _v) = m.pop_back();
    assert_eq!(k.copy_key_unwrap(), 30);
    let (k, _v) = m.pop_back();
    assert_eq!(k.copy_key_unwrap(), 20);
    m.destroy_empty();
}

#[test]
fun upsert_needs_drop_not_copy() {
    // K = DropKey (drop + store, NO copy). upsert drops the displaced key, so `drop` alone
    // suffices - `copy` is not required. (head/tail/keys/navigation do NOT compile - negatives.)
    let mut m = sm::new<DropKey, u64>();
    assert_eq!(u::dk_upsert(&mut m, 10, 100), option::none());
    assert_eq!(u::dk_upsert(&mut m, 20, 200), option::none());
    // replace: returns some(old); the displaced DropKey is dropped internally (needs K: drop)
    assert_eq!(u::dk_upsert(&mut m, 10, 999), option::some(100));
    assert_eq!(m.length(), 2);
    assert_eq!(u::dk_get(&m, 10), 999);
    assert_eq!(u::dk_remove(&mut m, 10), 999);
    assert_eq!(u::dk_remove(&mut m, 20), 200);
    m.destroy_empty();
}

#[test]
fun ops_leave_value_unconstrained() {
    // V = NoDrop (store only). `add` MOVES the value in; navigation/pagination read only keys, so
    // a resource V never blocks them. (contains/borrow/upsert/remove and from_sorted with a
    // NoDrop V are pinned in conservation_tests.)
    let mut m = sm::new<u64, NoDrop>();
    u::add_nd(&mut m, 10, u::nd(100));
    u::add_nd(&mut m, 30, u::nd(300));
    u::add_nd(&mut m, 20, u::nd(200));
    assert_eq!(m.length(), 3);
    assert_eq!(u::fnext_nd(&m, 15, true), option::some(20));
    assert_eq!(u::fprev_nd(&m, 25, false), option::some(20));
    assert_eq!(u::nxt_nd(&m, 20), option::some(30));
    assert_eq!(u::prv_nd(&m, 10), option::none());
    assert_eq!(u::kfrom_nd(&m, 10, true, 2), vector[10, 20]);
    // drain the resource values out (each NoDrop must be threaded back out)
    let (_k, w) = m.pop_front();
    assert_eq!(w.nd_unwrap(), 100);
    let (_k, w) = m.pop_front();
    assert_eq!(w.nd_unwrap(), 200);
    let (_k, w) = m.pop_back();
    assert_eq!(w.nd_unwrap(), 300);
    m.destroy_empty();
}

// ===========================================================================
// NEGATIVE compile-facts (NOT runnable `#[test]`s - they must FAIL to compile).
// Kept as commented snippets; exercised by review / a CI compile-fail harness.
// ===========================================================================
//
// A resource-V map is NOT copyable / droppable:
//   let m = sm::new<u64, NoDrop>();   // store-only
//   let _c = copy m;                  // E05001: 'copy' not satisfied
//   // (m also cannot be implicitly dropped - it must be drained + destroy_empty'd)
//
// Key abilities are demanded PER-OPERATION, not by the map itself. A store-only key
// (`StoreKey`: no `copy`, no `drop`) constructs, fills, and drains fine - the lifecycle and
// value-conserving ops (contains/borrow/borrow_mut/add/remove/from_sorted) need nothing of K
// (exercised positively above). But two op families constrain K at their expansion site:
//   let m = sm::new<StoreKey, u64>();
//   let p = u::store_key(1);
//   // (a) key-COPYING ops copy a key OUT of the map -> need K: copy. The comparator is
//   //     irrelevant to this error (the copy is from returning the key by value), hence the
//   //     trivial `|_, _| true`:
//   sm::head(&m); sm::tail(&m); sm::keys(&m);          // E05001: need K: copy
//   sm::find_next_by!(&m, &p, true, |_, _| true);      // E05001: need K: copy
//   sm::find_prev_by!(&m, &p, true, |_, _| true);      // E05001: need K: copy
//   sm::next_key_by!(&m, &p, |_, _| true);             // E05001: need K: copy
//   sm::prev_key_by!(&m, &p, |_, _| true);             // E05001: need K: copy
//   sm::keys_from_by!(&m, &p, true, 10, |_, _| true);  // E05001: need K: copy
//   // (b) upsert drops the DISPLACED key -> needs K: drop. This fails even for CopyKey (which
//   //     HAS copy but not drop), isolating `drop` as the missing ability. `add`/`add_by` never
//   //     drop the key (a duplicate ABORTS), and `remove_by` RETURNS the key, so both need no
//   //     drop and compile on a no-drop key (exercised positively above):
//   let mut mc = sm::new<CopyKey, u64>();
//   sm::upsert_by!(&mut mc, u::copy_key(1), 0, |_, _| true); // E05001: needs K: drop
//
// No bulk mutable / owning escape hatch:
//   let mut m = sm::new<u64, u64>();
//   sm::entries_mut(&mut m);          // no such function
//   std::vector::reverse(sm::entries(&m)); // &vector cannot coerce to &mut vector
//
// A bare macro on a non-integer key is a hard compile error:
//   let mut m = sm::new<address, u64>();
//   sm::upsert!(&mut m, &@0x1, 1);   // E04003: `<` not defined for address -> use upsert_by!
//
// A bare (UID-less) map cannot be transferred:
//   sui::transfer::public_transfer(sm::new<u64, u64>(), @0x1); // needs T: key
//
// A comparator cannot re-enter to mutate the map mid-search:
//   sm::upsert_by!(&mut m, &1, 1, |a, b| { sm::upsert!(&mut m, &9, 9); *a < *b }); // borrow conflict
//
// is_well_formed[_by] is `#[test_only]`, absent from the published module: a
// PRODUCTION (non-#[test_only]) consumer function cannot resolve it (zero on-chain cost; an
// O(n) per-op walk would erase the single-object thesis). Build-time/visibility fact,
// exercised by review / a CI compile-fail harness, not a runnable `#[test]`:
//   public fun prod_check(m: &SortedMap<u64, u64>): bool { sm::is_well_formed!(m) } // unresolved: test-only

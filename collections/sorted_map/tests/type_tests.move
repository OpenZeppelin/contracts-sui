/// Type-level / ability facts and structural composability.
///
/// Most of these properties are enforced by Move's type system, so "the test is that it
/// compiles": ability witnesses, value/store embedding, distinct
/// instantiations coexisting, the read-only `entries_ref` surface, and two
/// independent maps. The NEGATIVE half (a resource-V map cannot be copied/dropped,
/// `e.key` cannot be read, `entries_mut` does not exist, a bare macro rejects `address`,
/// a bare `SortedMap` cannot be transferred) is a build-time fact - documented as the
/// commented non-compiling snippets at the bottom, to be exercised by review/CI, not a
/// runnable `#[test]`.
module openzeppelin_sorted_map::type_tests;

use openzeppelin_sorted_map::sorted_map::{Self as sm, SortedMap};
use openzeppelin_sorted_map::test_util::{Self as u, NoDrop, Bid, Ask};
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
    u::ins_bid(&mut bids, 100, u::bid(1)).destroy_none();
    u::ins_ask(&mut asks, 200, u::ask(2)).destroy_none();
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
    assert_eq!(sm::length(&a), 2);
    assert!(sm::is_empty(&b));
}

#[test]
fun entries_ref_read_only() {
    // The only bulk view is an immutable &vector<Entry>; entries are read via accessors.
    // This pins the positive read path only; the no-mutable-escape-hatch half (no
    // `entries_mut`/`into_entries`, and `&vector` cannot coerce to `&mut vector`) is
    // a build-time fact, kept as the commented compile-fail negatives at the bottom of this file.
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 1, 10);
    u::ins(&mut m, 2, 20);
    let es = sm::entries_ref(&m);
    assert_eq!(es.length(), 2);
    assert_eq!(*sm::entry_key(es.borrow(0)), 1);
    assert_eq!(*sm::entry_value(es.borrow(0)), 10);
    assert_eq!(*sm::entry_key(es.borrow(1)), 2);
}

// `key_at` is a low-level positional key accessor. No `sorted_map` macro uses it (the
// macros read keys via entry_key(entries_ref(..).borrow(i))), but `big_sorted_map` calls it
// heavily across packages (node-max reads, the cross-leaf navigation chain, build_from_sorted).
// Its contract is therefore otherwise pinned only in the sibling's suite; this pins it at
// sorted_map's own audited boundary.
#[test]
fun key_at_positional_read() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 1);
    u::ins(&mut m, 20, 2);
    assert_eq!(*sm::key_at(&m, 0), 10);
    assert_eq!(*sm::key_at(&m, 1), 20);
}

// `value_at`/`value_at_mut` are the value-side companions to `key_at`: low-level positional
// accessors that no `sorted_map` macro uses but `big_sorted_map` calls across packages. This
// pins both the read (`value_at`) and the order-safe write (`value_at_mut` yields `&mut V`) at
// sorted_map's own audited boundary.
#[test]
fun value_at_reads_and_writes() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 1);
    u::ins(&mut m, 20, 2);
    assert_eq!(*sm::value_at(&m, 0), 1);
    assert_eq!(*sm::value_at(&m, 1), 2);
    *sm::value_at_mut(&mut m, 1) = 99; // write through the &mut V
    assert_eq!(*sm::value_at(&m, 1), 99); // re-read confirms the mutation persisted
    assert_eq!(u::get(&m, 20), 99); // and the public borrow agrees
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
// A store-only key is rejected:
//   public struct BadKey has store {}
//   let _m = sm::new<BadKey, u64>();  // K: copy + drop + store not satisfied
//
// Entry fields are private; key cannot be read or mutated in place:
//   let e = sm::make_entry(1u64, 2u64);
//   let _k = e.key;                   // field `key` is private to sorted_map
//   // borrow_mut! yields &mut V, never &mut Entry - no &mut to the key exists
//
// No bulk mutable / owning escape hatch:
//   let mut m = sm::new<u64, u64>();
//   sm::entries_mut(&mut m);          // no such function
//   std::vector::reverse(sm::entries_ref(&m)); // &vector cannot coerce to &mut vector
//
// A bare macro on a non-integer key is a hard compile error:
//   let mut m = sm::new<address, u64>();
//   sm::insert!(&mut m, @0x1, 1);     // E04003: `<` not defined for address -> use insert_by!
//
// A bare (UID-less) map cannot be transferred:
//   sui::transfer::public_transfer(sm::new<u64, u64>(), @0x1); // needs T: key
//
// A comparator cannot re-enter to mutate the map mid-search:
//   sm::insert_by!(&mut m, 1, 1, |a, b| { sm::insert!(&mut m, 9, 9); *a < *b }); // borrow conflict
//
// is_well_formed[_by] is `#[test_only]`, absent from the published module: a
// PRODUCTION (non-#[test_only]) consumer function cannot resolve it (zero on-chain cost; an
// O(n) per-op walk would erase the single-object thesis). Build-time/visibility fact,
// exercised by review / a CI compile-fail harness, not a runnable `#[test]`:
//   public fun prod_check(m: &SortedMap<u64, u64>): bool { sm::is_well_formed!(m) } // unresolved: test-only

/// The type-level / ability suite: the compiler-enforced bucket. This bucket needs only POSITIVE
/// round-trips (instantiating the type proves the ability holds) plus COMMENTED non-compiling
/// snippets for the negatives - it must NOT be over-tested.
module openzeppelin_collections::sorted_set_type_tests;

use openzeppelin_collections::sorted_set::{Self as ss, SortedSet};
use openzeppelin_collections::sorted_set_test_util as u;
use std::unit_test::assert_eq;
use sui::test_scenario as ts;

// A consumer's own object embedding a set BY VALUE - the only way to share it.
public struct Watch has key { id: UID, s: SortedSet<u64> }

// A store+drop wrapper to witness the set embeds as a `store` field and falls out of scope.
public struct Box has drop, store { s: SortedSet<u64> }

// === SortedSet<K> is UNCONDITIONALLY copy + drop + store for every admissible K ===

#[test]
fun abilities_copy_drop_store_witness() {
    // Each instantiation type-checks ONLY if the witnessed ability holds. There is no
    // non-droppable instantiation to write a negative for - its very absence IS the invariant.
    u::needs_copy<SortedSet<u64>>();
    u::needs_drop<SortedSet<u64>>();
    u::needs_store<SortedSet<u64>>();
    u::needs_copy<SortedSet<address>>();
    u::needs_drop<SortedSet<address>>();
    u::needs_store<SortedSet<address>>();
    u::needs_copy<SortedSet<u::Key>>(); // struct key -> still copy+drop+store
    u::needs_drop<SortedSet<u::Key>>();
    u::needs_store<SortedSet<u::Key>>();
}

#[test]
fun populated_set_drops_no_destroy_empty() {
    // A populated set simply falls out of scope - there is no destroy_empty terminal.
    let s = u::fromk(vector[1u64, 2, 3]);
    assert_eq!(s.length(), 3);
    // no teardown call: `s` drops here because SortedSet is unconditionally `drop`.
}

#[test]
fun embed_in_store_struct() {
    // The set embeds as a `store` field; the wrapper drops, taking the set with it.
    let b = Box { s: u::fromk(vector[1u64, 2]) };
    assert_eq!(b.s.length(), 2);
    // `b` (and its embedded SortedSet) drops out of scope.
}

// === a copy is a deep, independent snapshot - never an alias ===

#[test]
fun copy_is_deep_independent_snapshot() {
    let mut s1 = u::fromk(vector[1u64, 2, 3]);
    let mut s2 = s1; // COPY (SortedSet: copy); s1 is used below, so this is a copy, not a move
    u::ins(&mut s2, 4);
    assert!(!u::has(&s1, 4)); // mutating the copy never touches the original
    assert!(u::has(&s2, 4));
    assert!(s1.length() == 3 && s2.length() == 4);
    // symmetric: mutating the original leaves the earlier copy frozen at copy time.
    u::rem(&mut s1, 1);
    assert!(u::has(&s2, 1));
    assert!(s1.length() == 2 && s2.length() == 4);
    assert!(u::wf(&s1) && u::wf(&s2));
}

#[test]
fun copy_then_drain_each_independently() {
    // Copy a populated set then DRAIN each independently and assert each stays internally
    // consistent. The snapshot test above covers upsert/remove! only; pop_* is the one mutator
    // never run on a copy. Draining one copy must not alias the other's backing vector.
    let mut s1 = u::fromk(vector[1u64, 2, 3]);
    let mut s2 = s1; // COPY (s1 is used below)
    // drain s1 fully via pop_*; s2 must stay intact.
    let _ = s1.pop_front();
    let _ = s1.pop_back();
    let _ = s1.pop_front();
    assert!(s1.is_empty() && u::wf(&s1));
    assert_eq!(s2.length(), 3); // s2 untouched by s1's full drain
    assert_eq!(s2.keys(), vector[1u64, 2, 3]);
    assert!(u::wf(&s2));
    // now drain s2 independently; s1 stays empty.
    let _ = s2.pop_back();
    assert!(s2.length() == 2 && s1.is_empty());
    assert!(u::wf(&s2));
}

// === UID-less value - embed in a `has key` object, share, drain, delete ===

#[test]
fun embed_in_key_object_share_drain_delete() {
    let admin = @0xAD;
    let mut sc = ts::begin(admin);
    {
        let s = u::fromk(vector[3u64, 1, 2]);
        let w = Watch { id: object::new(sc.ctx()), s };
        transfer::share_object(w);
    };
    sc.next_tx(admin);
    {
        let mut w = sc.take_shared<Watch>();
        assert_eq!(w.s.length(), 3);
        let _ = w.s.pop_front(); // mutate the embedded set through the shared object
        assert_eq!(w.s.length(), 2);
        ts::return_shared(w);
    };
    sc.next_tx(admin);
    {
        let w = sc.take_shared<Watch>();
        let Watch { id, s: _ } = w; // the set drops with the wrapper - no orphaned child objects
        id.delete();
    };
    sc.end();
}

// === distinct instantiations are distinct, incompatible types (nominal typing) ===
// (no bulk-vector escape hatch is compile-fail-only -> commented snippet below.)

#[test]
fun nominal_typing_coexist() {
    let su = ss::singleton<u64>(1);
    let sa = ss::singleton<address>(@0xA); // singleton needs no comparator -> works for address
    assert_eq!(su.length(), 1);
    assert_eq!(sa.length(), 1);
    // SortedSet<u64> and SortedSet<address> coexist; the type system forbids mixing them (see the
    // commented non-compiling snippets below).
}

#[test]
fun non_integer_key_by_roundtrip() {
    // A non-integer struct key round-trips through the `_by` API (bare `<` would not
    // type-check for a struct - see the commented snippet).
    let mut s = ss::new<u::Key>();
    assert!(u::ins_k(&mut s, u::mk(3, 0)));
    assert!(u::ins_k(&mut s, u::mk(1, 0)));
    assert!(u::ins_k(&mut s, u::mk(2, 0)));
    assert_eq!(u::len_k(&s), 3);
    assert!(u::has_k(&s, 2));
    u::rem_k(&mut s, 2);
    assert!(!u::has_k(&s, 2));
    assert!(u::wf_k(&s));
    // pop_front returns the bare struct K (the inner (Key, Unit)'s Unit is dropped) - proven for
    // u64 by pop_returns_bare_key_not_tuple; this pins the same Unit-drop/bare-K return for a
    // non-integer key. Remaining ids are {1, 3}; pop_front yields the smallest id.
    let kmin: u::Key = s.pop_front();
    assert_eq!(u::key_id(&kmin), 1);
    assert_eq!(u::len_k(&s), 1);
    assert!(u::wf_k(&s));
}

// === Unit is the inert, 1-byte, frozen-layout marker ===

#[test]
fun unit_is_one_byte() {
    // A layout-frozen guard (NOT a capacity test): an empty struct serializes to 1 BCS byte,
    // byte-identical to bool. Growing Unit would break BCS of every downstream object
    // and lower the capacity ceiling.
    let unit = ss::unit();
    assert_eq!(std::bcs::to_bytes(&unit).length(), 1);
}

// === macro-inlining depth is bounded (~256 locals/fn) and WORSE for the set ===

#[test]
fun macro_inlining_headroom() {
    // Each set macro inlines THREE layers (set macro -> map macro -> search!; from_keys is four),
    // so a function's ~256-locals budget is spent fast. MEASURED on sui 1.73.1: 11 distinct bare
    // `upsert` expansions in ONE function compile; the 12th panics with `value (277) cannot exceed
    // (255)` - vs ~20 for the map (the extra inlining layer is why it is WORSE for the set). `_by`
    // forms and `from_keys` are heavier still. This is why every comparator op in the rest of the
    // suite is wrapped one-per-helper in test_util (a helper CALL does not expand) and op streams
    // run in loops: the 256-locals discipline is load-bearing, not cosmetic. This test pins the
    // POSITIVE half - a handful of in-body expansions (6 here, well under ~11) is fine. The
    // negative (12+ -> compiler panic) cannot be a live #[test] (it fails to compile), so it is
    // recorded above as a measured fact.
    let mut s = ss::new<u64>();
    s.upsert!(&3);
    s.upsert!(&1);
    let _ = s.contains!(&1);
    s.remove!(&3);
    let _ = s.find_next!(&0, true);
    let _ = s.keys_from!(&0, true, 10);
    assert_eq!(s.length(), 1); // only key 1 remains
}

#[test]
fun pop_returns_bare_key_not_tuple() {
    // pop_* return K alone (the inner (K, Unit)'s Unit is dropped). If pop returned
    // (K, Unit) this binding to a u64 would not type-check.
    let mut s = ss::singleton<u64>(42);
    let k: u64 = s.pop_front();
    assert_eq!(k, 42);
}

#[test]
fun from_keys_macro_depth_compiles() {
    // macro_inlining_headroom pins 3-layer BARE ops in-body; this pins the HEADLINE
    // 4-layer from_keys expansion (do! -> set upsert -> map upsert_by! -> search!) compiling in a
    // #[test] body directly - both the bare and a _by form - not only via test_util helpers.
    let s = ss::from_keys!(vector[3u64, 1, 2]); // bare 4-layer expansion in-body
    assert_eq!(s.keys(), vector[1u64, 2, 3]);
    let sk = ss::from_keys_by!(vector[30u64, 10, 20], |a, b| *a > *b); // _by 4-layer expansion in-body
    assert_eq!(sk.keys(), vector[30u64, 20, 10]);
}

// ===========================================================================
// Commented NON-COMPILING snippets (the negative compile-fail bucket)
// ===========================================================================
//
// These are deliberately NOT live code: each would fail to type-check, which is the proof. They
// are kept here (positive round-trips + commented non-compiling snippets) so a reviewer can see
// exactly what the type system forecloses.
//
// No resource-valued or store-only set; V is fixed to Unit (no second type arg):
//     let s = ss::new<u64, sui::coin::Coin<SUI>>();   // E: SortedSet takes ONE type parameter
//
// A store-only key is rejected at the type annotation:
//     public struct SO has store {}
//     let s = ss::new<SO>();                          // E05001: SO is missing copy, drop
//
// A bare macro on a non-integer key fails (no built-in `<`); use the _by form:
//     let mut s = ss::new<address>();
//     ss::upsert!(&mut s, &@0x1);                    // E04003: `<` not defined for address
//
// No accessor yields &mut K or &mut Entry<K, Unit>; a stored key is reachable only as
// &K. The strongest mutable handle reachable through inner_mut is &mut Unit (the value), never
// &mut K, so a key can be changed only by remove-then-insert:
//     let _km: &mut u64 = sorted_map::value_at_mut(ss::inner_mut(&mut s), 0); // &mut Unit, NOT &mut K
//     // ...there is no key_at_mut / entry_mut on the set OR the map - no symbol yields &mut K
//
// No raw &mut vector / bulk escape hatch on the set surface. Only inner (&) and
// inner_mut (&mut SortedMap) exist - neither a &mut vector - and there is no entries_mut /
// into_entries / keys_mut. A bulk reverse is therefore unrepresentable:
//     ss::entries_mut(&mut s);                          // E03003: no `entries_mut` on the set
//     ss::into_entries(s);                              // E03003: no `into_entries` on the set
//     ss::inner(&s).entries().reverse();        // E: entries yields &vector; reverse needs &mut
//
// Instantiations are nominal; cannot mix a u64 key into an address set:
//     let mut sa = ss::new<address>();
//     ss::upsert!(&mut sa, &1u64);                   // E: expected address, found u64
//
// A bare SortedSet is NOT `key`, so it cannot be transferred/shared directly; it must
// be wrapped in a consumer's own `has key` object (as `Watch` is above):
//     transfer::public_transfer(ss::new<u64>(), @0x1); // E: SortedSet lacks the `key` ability
//
// The well-formedness check is #[test_only]; a PRODUCTION call does not compile:
//     // in a non-test module:
//     public fun check(s: &SortedSet<u64>): bool {
//         sorted_map::is_well_formed!(ss::inner(s))   // E: test-only used in non-test code
//     }
//
// Mutation-reentrancy is foreclosed by the borrow checker; a comparator that tries to
// mutate the set mid-search cannot type-check (the set is already borrowed &mut for the op):
//     ss::upsert_by!(&mut s, &k, |a, b| { ss::upsert!(&mut s, &0); *a < *b });  // E: borrow conflict

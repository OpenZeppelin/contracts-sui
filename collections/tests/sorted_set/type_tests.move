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

// === SortedSet<K> has exactly the abilities of K (Unit contributes copy + drop + store) ===

#[test]
fun abilities_follow_key() {
    // Each instantiation type-checks ONLY if the witnessed ability holds. A copy+drop+store key
    // yields a copy+drop+store set; a store-ONLY key (`NoDropKey`) yields a store-only set - it
    // witnesses `store` but there is deliberately no `needs_drop<SortedSet<NoDropKey>>()` (it would
    // NOT compile - that absence IS the "abilities follow K" invariant, exercised via the terminal
    // in store_only_key_drain_then_destroy_empty).
    u::needs_copy<SortedSet<u64>>();
    u::needs_drop<SortedSet<u64>>();
    u::needs_store<SortedSet<u64>>();
    u::needs_copy<SortedSet<address>>();
    u::needs_drop<SortedSet<address>>();
    u::needs_store<SortedSet<address>>();
    u::needs_copy<SortedSet<u::Key>>(); // copy+drop+store struct key -> copy+drop+store set
    u::needs_drop<SortedSet<u::Key>>();
    u::needs_store<SortedSet<u::Key>>();
    u::needs_store<SortedSet<u::NoDropKey>>(); // store-only key -> store-only set (no copy, no drop)
}

#[test]
fun droppable_key_set_drops_no_destroy_empty() {
    // With a `drop` key the set is `drop`, so a populated set simply falls out of scope - no
    // destroy_empty needed. (A non-`drop` key set does need it: see below.)
    let s = u::fromk(vector[1u64, 2, 3]);
    assert_eq!(s.length(), 3);
    // no teardown call: `s` drops here because SortedSet<u64> is `drop`.
}

#[test]
fun destroy_empty_on_empty_droppable_set() {
    // destroy_empty also accepts a droppable-key set - redundant with letting it fall out of scope,
    // but a valid explicit terminal. Covers a fresh new() and a singleton drained back to empty.
    ss::new<u64>().destroy_empty();
    let mut s = ss::singleton<u64>(7);
    let _ = s.pop_front();
    s.destroy_empty(); // drained to empty -> ok
}

#[test]
fun store_only_key_drain_then_destroy_empty() {
    // A store-only key makes SortedSet<NoDropKey> itself store-only - it CANNOT fall out of scope,
    // so it must be drained then explicitly torn down. Keys leave through remove! or pop_* and must
    // be consumed because NoDropKey has no `drop`; this walkthrough drains in order with pop_front.
    // The emptied set is then closed by destroy_empty. Omitting it would not compile, which is the
    // structural proof that the terminal is load-bearing here.
    let mut s = ss::new<u::NoDropKey>();
    u::add_ndk(&mut s, u::ndk(2));
    u::add_ndk(&mut s, u::ndk(1));
    u::add_ndk(&mut s, u::ndk(3));
    assert_eq!(s.length(), 3);
    let mut ids = vector[];
    while (!s.is_empty()) {
        ids.push_back(u::ndk_unwrap(s.pop_front())); // smallest id first
    };
    assert_eq!(ids, vector[1u64, 2, 3]); // drained in comparator (id) order, none lost
    s.destroy_empty(); // the emptied store-only set's only terminal
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
    assert!(u::ups_k(&mut s, u::mk(3, 0)));
    assert!(u::ups_k(&mut s, u::mk(1, 0)));
    assert!(u::ups_k(&mut s, u::mk(2, 0)));
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
    s.upsert!(3);
    s.upsert!(1);
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
    // 4-layer from_keys expansion (fold! -> set upsert -> map upsert_by! -> search!) compiling in a
    // #[test] body directly - both the bare and a _by form - not only via test_util helpers.
    let s = ss::from_keys!(vector[3u64, 1, 2]); // bare 4-layer expansion in-body
    assert_eq!(s.keys(), vector[1u64, 2, 3]);
    let sk = ss::from_keys_by!(vector[30u64, 10, 20], |a, b| *a > *b); // _by 4-layer expansion in-body
    assert_eq!(sk.keys(), vector[30u64, 20, 10]);
}

// === K ability lattice: each op family at the MINIMAL K ability its body needs ===
// The wrapper in test_util instantiates the op at a lattice corner (so the macro expands there,
// not here); the assertions confirm it also BEHAVES. The "must NOT compile" half is the
// negative-snippet block below. (`abilities_follow_key` above already pins the store-only corner
// at the type level; these pin the per-op behavior.)

#[test]
fun value_conserving_ops_need_nothing_of_key() {
    // K = NoDropKey (store only: no copy, no drop). add/contains/remove and the lifecycle ops all
    // instantiate - they constrain K with nothing. (upsert/from_keys/from_sorted_keys need drop;
    // the reads need copy - see the negatives.)
    let mut s = ss::new<u::NoDropKey>();
    u::add_ndk(&mut s, u::ndk(20));
    u::add_ndk(&mut s, u::ndk(10));
    u::add_ndk(&mut s, u::ndk(30));
    assert_eq!(s.length(), 3);
    assert!(u::has_ndk(&s, 20) && !u::has_ndk(&s, 25));
    assert_eq!(u::rem_ndk(&mut s, 20), 20); // remove_by RETURNS the key (needs no drop)
    assert_eq!(s.length(), 2);
    assert!(!u::has_ndk(&s, 20));
    // drain the store-only set via pop_* (each key consumed by ndk_unwrap), then destroy_empty
    assert_eq!(u::ndk_unwrap(s.pop_front()), 10);
    assert_eq!(u::ndk_unwrap(s.pop_back()), 30);
    s.destroy_empty();
}

#[test]
fun key_copying_ops_need_copy_not_drop() {
    // K = CopyKey (copy + store, NO drop). head/tail/keys and all navigation/pagination copy keys
    // out, so `copy` alone suffices - `drop` is not required. `add` also works.
    // (upsert/from_keys/from_sorted_keys do NOT compile here - see the negatives.)
    let mut s = ss::new<u::CopyKey>();
    u::add_ck(&mut s, 10);
    u::add_ck(&mut s, 20);
    u::add_ck(&mut s, 30);
    assert_eq!(u::head_ck(&s), option::some(10));
    assert_eq!(u::tail_ck(&s), option::some(30));
    assert_eq!(u::keys_ck(&s), vector[10, 20, 30]);
    assert_eq!(u::fnext_ck(&s, 15, true), option::some(20));
    assert_eq!(u::fprev_ck(&s, 25, false), option::some(20));
    assert_eq!(u::nkey_ck(&s, 20), option::some(30));
    assert_eq!(u::pkey_ck(&s, 20), option::some(10));
    assert_eq!(u::page_ck(&s, 10, true, 2), vector[10, 20]);
    // drain (CopyKey has no drop): unwrap each popped key
    assert_eq!(u::copy_key_unwrap(s.pop_front()), 10);
    assert_eq!(u::copy_key_unwrap(s.pop_back()), 30);
    assert_eq!(u::copy_key_unwrap(s.pop_back()), 20);
    s.destroy_empty();
}

#[test]
fun key_dropping_ops_need_drop_not_copy() {
    // K = DropKey (drop + store, NO copy). upsert, from_keys, and from_sorted_keys can drop a key,
    // so `drop` alone suffices - `copy` is not required. add/contains/remove also work.
    // (head/tail/keys/navigation do NOT compile here - see the negatives.) SortedSet<DropKey> is
    // itself `drop`, so it falls out of scope - no destroy_empty needed.
    let mut s = ss::new<u::DropKey>();
    assert!(u::ups_dk(&mut s, 10)); // newly added
    assert!(u::ups_dk(&mut s, 20));
    assert!(!u::ups_dk(&mut s, 10)); // duplicate: false; the displaced key is dropped (needs drop)
    assert_eq!(s.length(), 2);
    u::add_dk(&mut s, 30); // strict insert
    assert!(u::has_dk(&s, 30));
    u::rem_dk(&mut s, 20);
    assert!(!u::has_dk(&s, 20));
    assert_eq!(s.length(), 2);
    // from_keys over a no-copy key de-duplicates (needs drop only, never copy)
    let s2 = u::fromk_dk(vector[3, 1, 2, 1, 3]);
    assert_eq!(s2.length(), 3);
    // from_sorted_keys has the same minimal `drop` bound and de-duplicates adjacent equals.
    let s3 = u::from_sorted_dk(vector[1, 1, 2, 3, 3]);
    assert_eq!(s3.length(), 3);
    assert!(u::has_dk(&s3, 1) && u::has_dk(&s3, 2) && u::has_dk(&s3, 3));
}

// ===========================================================================
// Commented NON-COMPILING snippets (the negative compile-fail bucket)
// ===========================================================================
//
// These are deliberately NOT live code: each would fail to type-check, which is the proof. They
// are kept here (positive round-trips + commented non-compiling snippets) so a reviewer can see
// exactly what the type system forecloses.
//
// No resource-valued or store-only VALUE set; V is fixed to Unit (no second type arg):
//     let s = ss::new<u64, sui::coin::Coin<SUI>>();   // E: SortedSet takes ONE type parameter
//
// A store-only KEY is ACCEPTED (the set is then store-only and must be destroy_empty'd - see
// store_only_key_drain_then_destroy_empty); it is a NON-drop set that has no live negative. But an
// ability the KEY lacks is still forbidden on the set - a store-only-key set is not `drop`:
//     u::needs_drop<SortedSet<u::NoDropKey>>();       // E05001: SortedSet<NoDropKey> lacks `drop`
//
// Key abilities are demanded PER-OPERATION. A store-only key (`NoDropKey`: no `copy`, no `drop`)
// works with everything that needs nothing of K - new/singleton/add_by!/contains_by!/remove_by!
// (which RETURNS the key)/pop_*/destroy_empty (exercised positively above). Two ability categories
// constrain K at the expansion site:
//     let mut s = ss::new<u::NoDropKey>();
//     let p = u::ndk(1);
//     // (a) key-DROPPING ops -> need K: drop. upsert drops the displaced key; from_keys is built
//     //     on upsert; from_sorted_keys drops adjacent duplicates. (add_by! never drops - a
//     //     duplicate ABORTS; remove_by! RETURNS the key.)
//     ss::upsert_by!(&mut s, u::ndk(1), |_, _| true);           // E05001: upsert needs `drop`
//     let _ = ss::from_keys_by!(vector[u::ndk(1)], |_, _| true); // E05001: from_keys needs `drop`
//     let _ = ss::from_sorted_keys_by!(vector[u::ndk(1)], |_, _| true); // E05001: needs `drop`
//     // (b) key-COPYING ops copy a key OUT -> need K: copy. The comparator is irrelevant to this
//     //     error (the copy is from returning the key), hence the trivial `|_, _| true`:
//     s.keys(); s.head(); s.tail();                             // E05001: need `copy` (no comparator)
//     ss::find_next_by!(&s, &p, true, |_, _| true);             // E05001: need `copy`
//     ss::find_prev_by!(&s, &p, true, |_, _| true);             // E05001: need `copy`
//     ss::next_key_by!(&s, &p, |_, _| true);                    // E05001: need `copy`
//     ss::prev_key_by!(&s, &p, |_, _| true);                    // E05001: need `copy`
//     ss::keys_from_by!(&s, &p, true, 10, |_, _| true);         // E05001: need `copy`
//
// These operations need specifically `drop`, not `copy`: they fail even for a copy-but-not-`drop`
// key (`CopyKey`), isolating `drop`, while add_by! and the copy-requiring reads all compile on that
// same key (exercised positively above):
//     let mut sc = ss::new<u::CopyKey>();
//     ss::upsert_by!(&mut sc, u::copy_key(1), |_, _| true);     // E05001: needs `drop`
//     let _ = ss::from_keys_by!(vector[u::copy_key(1)], |_, _| true); // E05001: needs `drop`
//     let _ = ss::from_sorted_keys_by!(vector[u::copy_key(1)], |_, _| true);
//     // E05001: needs `drop`
//
// A bare macro on a non-integer key fails (no built-in `<`); use the _by form:
//     let mut s = ss::new<address>();
//     ss::upsert!(&mut s, @0x1);                     // E04003: `<` not defined for address
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
//     ss::upsert!(&mut sa, 1u64);                    // E: expected address, found u64
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
//     ss::upsert_by!(&mut s, k, |a, b| { ss::upsert!(&mut s, 0); *a < *b });  // E: borrow conflict

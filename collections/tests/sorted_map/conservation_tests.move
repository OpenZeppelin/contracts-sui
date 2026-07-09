/// Value conservation.
///
/// These are the highest-leverage tests in the suite: run under a NON-DROPPABLE value
/// witness (`NoDrop`) and real `Coin<SUI>`, the compiler forbids implicitly dropping a
/// value, so an overwrite-without-return or a leaked value becomes a BUILD error rather
/// than a silent loss. Verifies that a non-drop V forces teardown, a resource V is
/// allowed, stored values leave only via a return path, and reads conserve.
module openzeppelin_collections::sorted_map_conservation_tests;

use openzeppelin_collections::sorted_map::{Self as sm, SortedMap};
use openzeppelin_collections::sorted_map_test_util::{Self as u, NoDrop, NoDropKey};
use std::unit_test::assert_eq;
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario as ts;

// === Non-droppable V: drain conserves the whole multiset ===

#[test]
fun conservation_drain_nodrop() {
    let mut m = sm::new<u64, NoDrop>();
    let n = 20;
    // insert key i with a value whose id encodes that key: id(i) = i*7 + 1
    let mut i = 0;
    while (i < n) {
        u::ins_nd(&mut m, i, u::nd(i * 7 + 1)).destroy_none(); // fresh insert returns none
        i = i + 1;
    };
    assert_eq!(m.length(), n);
    // Drain evens via remove, odds via pop_front. Every returned NoDrop MUST be consumed (it
    // has no `drop`) - failing to thread one back out would not compile, which is the
    // structural no-loss guarantee. We additionally assert each drained value's id matches the
    // key it came out under: this catches not just loss but a key->value MISassociation (a
    // silent cross-key swap) that a bare count or sum cannot.
    let mut cnt_out = 0u64;
    let mut k = 0;
    while (k < n) {
        if (k % 2 == 0) {
            let id = u::rm_nd(&mut m, k).nd_unwrap();
            assert_eq!(id, k * 7 + 1); // remove(k) returned key k's OWN value
            cnt_out = cnt_out + 1;
        };
        k = k + 1;
    };
    while (!m.is_empty()) {
        let (kk, w) = m.pop_front(); // smallest remaining key
        assert_eq!(w.nd_unwrap(), kk * 7 + 1); // popped value matches its own key
        cnt_out = cnt_out + 1;
    };
    assert_eq!(cnt_out, n); // exactly n values came back out (none lost, none fabricated)
    m.destroy_empty(); // map drained to empty: every value left via a return path
}

// === destroy_empty on a NON-EMPTY resource-V map aborts ENotEmpty (no bulk value loss) ===
//
// Exercising the guard under a non-droppable V proves destroy_empty can never silently
// bulk-discard stored resources. The abort consumes the still-owned NoDrop as the tx unwinds -
// the test compiles BECAUSE the map is moved into destroy_empty.
#[test, expected_failure(abort_code = sm::ENotEmpty, location = sm)]
fun destroy_empty_nonempty_nodrop() {
    let mut m = sm::new<u64, NoDrop>();
    u::ins_nd(&mut m, 1, u::nd(1)).destroy_none();
    m.destroy_empty(); // non-empty -> ENotEmpty at the library location
}

// === Upsert returns the displaced value, never drops it ===

#[test]
fun upsert_returns_old_nodrop() {
    let mut m = sm::new<u64, NoDrop>();
    u::ins_nd(&mut m, 5, u::nd(100)).destroy_none();
    // upsert: the OLD value is returned as some(old) and must be consumed.
    let old = u::ins_nd(&mut m, 5, u::nd(200)).destroy_some();
    assert_eq!(old.nd_unwrap(), 100);
    assert_eq!(m.length(), 1);
    assert_eq!(u::nd_value_id(&m, 5), 200); // new value present
    let w = u::rm_nd(&mut m, 5);
    w.nd_unwrap();
    m.destroy_empty();
}

// === Non-droppable KEY: add_by / upsert_by never implicitly drop a K ===
//
// K = NoDropKey (copy, no drop). A struct key has no built-in `<`, so only the `_by` macros
// apply. Any path that failed to thread a stored key back out - or that dropped a key on insert,
// replace, or teardown - would be a BUILD error, making the "no K: drop" guarantee structural.

#[test]
fun add_nodrop_key_conserves() {
    // add_by MOVES each fresh key into storage; keys are inserted out of `id` order.
    let mut m = sm::new<NoDropKey, u64>();
    u::add_ndk(&mut m, u::ndk(20, 0), 200);
    u::add_ndk(&mut m, u::ndk(10, 0), 100);
    u::add_ndk(&mut m, u::ndk(30, 0), 300);
    assert_eq!(m.length(), 3);
    assert!(u::has_ndk(&m, 20));
    // Drain: every stored key comes back out and MUST be consumed. Asserting the returned key's
    // id matches the lookup id confirms the STORED key is handed back, not a fabricated probe.
    let (k10, v10) = u::rm_ndk(&mut m, 10);
    assert!(u::ndk_id(&k10) == 10 && v10 == 100);
    u::ndk_unwrap(k10);
    let (k30, v30) = u::rm_ndk(&mut m, 30);
    assert!(u::ndk_id(&k30) == 30 && v30 == 300);
    u::ndk_unwrap(k30);
    let (k20, _) = m.pop_back(); // pop returns the stored key too
    u::ndk_unwrap(k20);
    m.destroy_empty(); // husk consumed: every key left via a return path
}

#[test]
fun upsert_nodrop_key_replace_reuses_stored_key() {
    // upsert_by on a replace keeps the FIRST-seen stored key (never disposes a K) and returns the
    // displaced VALUE as some(old); the incoming key is consumed by the wrapper, not dropped.
    let mut m = sm::new<NoDropKey, u64>();
    assert!(u::upsert_ndk(&mut m, u::ndk(5, 100), 50).is_none()); // fresh: id=5, tag=100
    // Re-upsert the SAME id with a DIFFERENT tag (compare-equal under id-order).
    let old = u::upsert_ndk(&mut m, u::ndk(5, 200), 55);
    assert_eq!(old, option::some(50)); // displaced value returned
    assert_eq!(m.length(), 1); // no growth
    // The stored key kept its first-seen tag (100): replace reused it rather than swapping in the
    // tag=200 key, and did so without ever dropping a K.
    let (k, v) = u::rm_ndk(&mut m, 5);
    assert!(u::ndk_id(&k) == 5 && u::ndk_tag(&k) == 100 && v == 55);
    u::ndk_unwrap(k);
    m.destroy_empty();
}

#[test, expected_failure(abort_code = sm::EKeyAlreadyExists, location = sm)]
fun add_nodrop_key_duplicate_aborts() {
    // The duplicate/abort path also needs no `K: drop`: the incoming key is discarded by the
    // unwind. The drain below is unreachable at runtime but statically required (the non-drop
    // husk must be consumed on the fall-through path the compiler still sees).
    let mut m = sm::new<NoDropKey, u64>();
    u::add_ndk(&mut m, u::ndk(1, 0), 10);
    u::add_ndk(&mut m, u::ndk(1, 0), 20); // duplicate id -> EKeyAlreadyExists
    let (k, _) = u::rm_ndk(&mut m, 1);
    u::ndk_unwrap(k);
    m.destroy_empty();
}

// === Read paths conserve the multiset / length ===

#[test]
fun read_path_conservative_nodrop() {
    let mut m = sm::new<u64, NoDrop>();
    u::ins_nd(&mut m, 1, u::nd(10)).destroy_none();
    u::ins_nd(&mut m, 2, u::nd(20)).destroy_none();
    u::ins_nd(&mut m, 3, u::nd(30)).destroy_none();
    let len0 = m.length();
    // a battery of reads - none may change the stored-value multiset
    assert!(u::has_nd(&m, 2));
    assert_eq!(u::nd_value_id(&m, 2), 20);
    assert_eq!(m.head(), option::some(1));
    assert_eq!(m.tail(), option::some(3));
    assert_eq!(m.length(), len0);
    assert!(u::nd_value_id(&m, 1) == 10 && u::nd_value_id(&m, 3) == 30); // values intact
    // drain
    u::rm_nd(&mut m, 1).nd_unwrap();
    u::rm_nd(&mut m, 2).nd_unwrap();
    u::rm_nd(&mut m, 3).nd_unwrap();
    m.destroy_empty();
}

// === Real resource V: Coin<SUI> round-trips with value preserved ===

#[test]
fun coin_value_roundtrip() {
    let mut ctx = tx_context::dummy();
    let mut m = sm::new<u64, Coin<SUI>>();
    m.upsert!(&1, coin::mint_for_testing<SUI>(100, &mut ctx)).destroy_none();
    m.upsert!(&2, coin::mint_for_testing<SUI>(250, &mut ctx)).destroy_none();
    assert_eq!(m.borrow!(&1).value(), 100);
    // upsert returns the displaced coin - it must be burned, not dropped.
    let old = m.upsert!(&1, coin::mint_for_testing<SUI>(999, &mut ctx)).destroy_some();
    assert_eq!(old.value(), 100);
    old.burn_for_testing();
    assert_eq!(m.borrow!(&1).value(), 999);
    // remove returns the (key, coin)
    let (_, r1) = m.remove!(&1);
    assert_eq!(r1.value(), 999);
    r1.burn_for_testing();
    // pop the remaining coin
    let (_k, r2) = m.pop_back();
    assert_eq!(r2.value(), 250);
    r2.burn_for_testing();
    m.destroy_empty();
}

// === Store-only map embedded in a shared object, drained, destroyed ===

public struct Wrapper has key {
    id: UID,
    m: SortedMap<u64, NoDrop>,
}

#[test]
fun store_only_map_wrapped_shared() {
    let admin = @0xA;
    let mut sc = ts::begin(admin);
    {
        let mut m = sm::new<u64, NoDrop>();
        u::ins_nd(&mut m, 1, u::nd(11)).destroy_none();
        u::ins_nd(&mut m, 2, u::nd(22)).destroy_none();
        let w = Wrapper { id: object::new(sc.ctx()), m };
        transfer::share_object(w);
    };
    sc.next_tx(admin);
    {
        let mut w = sc.take_shared<Wrapper>();
        let a = u::rm_nd(&mut w.m, 1).nd_unwrap();
        let b = u::rm_nd(&mut w.m, 2).nd_unwrap();
        assert_eq!(a + b, 33);
        ts::return_shared(w);
    };
    sc.next_tx(admin);
    {
        let Wrapper { id, m } = sc.take_shared<Wrapper>();
        // The drained husk is consumed by value. No child/dynamic-field objects could ever
        // exist (the map is UID-less) - this is structural, not asserted here;
        // sc.end() would error on any dangling object, which is the implicit check.
        m.destroy_empty();
        id.delete();
    };
    sc.end();
}

// === Bulk constructor conserves non-droppable values ===

#[test]
fun from_sorted_conserves_no_drop_values() {
    // V = NoDrop: the builder must MOVE each value in (never drop it), or this won't compile.
    let mut m = sm::from_sorted_keys_values!(
        vector[1u64, 2, 3],
        vector[u::nd(10), u::nd(20), u::nd(30)],
    );
    assert_eq!(u::nd_value_id(&m, 2), 20); // reads conserve
    // The whole multiset leaves only via a return path (pop_back drains largest-first).
    let (_, w3) = m.pop_back();
    let (_, w2) = m.pop_back();
    let (_, w1) = m.pop_back();
    m.destroy_empty();
    assert_eq!(w1.nd_unwrap(), 10);
    assert_eq!(w2.nd_unwrap(), 20);
    assert_eq!(w3.nd_unwrap(), 30);
}

/// Value conservation.
///
/// These are the highest-leverage tests in the suite: run under a NON-DROPPABLE value
/// witness (`NoDrop`) and real `Coin<SUI>`, the compiler forbids implicitly dropping a
/// value, so an overwrite-without-return or a leaked value becomes a BUILD error rather
/// than a silent loss. Verifies that a non-drop V forces teardown, a resource V is
/// allowed, stored values leave only via a return path, and reads conserve.
module openzeppelin_sorted_map::conservation_tests;

use openzeppelin_sorted_map::sorted_map::{Self as sm, SortedMap};
use openzeppelin_sorted_map::test_util::{Self as u, NoDrop};
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
    assert_eq!(sm::length(&m), n);
    // Drain evens via remove, odds via pop_front. Every returned NoDrop MUST be consumed (it
    // has no `drop`) - failing to thread one back out would not compile, which is the
    // structural no-loss guarantee. We additionally assert each drained value's id matches the
    // key it came out under: this catches not just loss but a key->value MISassociation (a
    // silent cross-key swap) that a bare count or sum cannot.
    let mut cnt_out = 0u64;
    let mut k = 0;
    while (k < n) {
        if (k % 2 == 0) {
            let id = u::nd_unwrap(u::rm_nd(&mut m, k).destroy_some());
            assert_eq!(id, k * 7 + 1); // remove(k) returned key k's OWN value
            cnt_out = cnt_out + 1;
        };
        k = k + 1;
    };
    while (!sm::is_empty(&m)) {
        let (kk, w) = sm::pop_front(&mut m);        // smallest remaining key
        assert_eq!(u::nd_unwrap(w), kk * 7 + 1); // popped value matches its own key
        cnt_out = cnt_out + 1;
    };
    assert_eq!(cnt_out, n); // exactly n values came back out (none lost, none fabricated)
    sm::destroy_empty(m);   // map drained to empty: every value left via a return path
}

// === destroy_empty on a NON-EMPTY resource-V map aborts ENotEmpty (no bulk value loss) ===
//
// Exercising the guard under a non-droppable V proves destroy_empty can never silently
// bulk-discard stored resources. The abort consumes the still-owned NoDrop as the tx unwinds -
// the test compiles BECAUSE the map is moved into destroy_empty.
#[test]
#[expected_failure(abort_code = openzeppelin_sorted_map::sorted_map::ENotEmpty, location = openzeppelin_sorted_map::sorted_map)]
fun destroy_empty_nonempty_nodrop() {
    let mut m = sm::new<u64, NoDrop>();
    u::ins_nd(&mut m, 1, u::nd(1)).destroy_none();
    sm::destroy_empty(m); // non-empty -> ENotEmpty at the library location
}

// === Upsert returns the displaced value, never drops it ===

#[test]
fun upsert_returns_old_nodrop() {
    let mut m = sm::new<u64, NoDrop>();
    u::ins_nd(&mut m, 5, u::nd(100)).destroy_none();
    // upsert: the OLD value is returned as some(old) and must be consumed.
    let old = u::ins_nd(&mut m, 5, u::nd(200)).destroy_some();
    assert_eq!(u::nd_unwrap(old), 100);
    assert_eq!(sm::length(&m), 1);
    assert_eq!(u::nd_value_id(&m, 5), 200); // new value present
    let w = u::rm_nd(&mut m, 5).destroy_some();
    u::nd_unwrap(w);
    sm::destroy_empty(m);
}

// === Read paths conserve the multiset / length ===

#[test]
fun read_path_conservative_nodrop() {
    let mut m = sm::new<u64, NoDrop>();
    u::ins_nd(&mut m, 1, u::nd(10)).destroy_none();
    u::ins_nd(&mut m, 2, u::nd(20)).destroy_none();
    u::ins_nd(&mut m, 3, u::nd(30)).destroy_none();
    let len0 = sm::length(&m);
    // a battery of reads - none may change the stored-value multiset
    assert!(u::has_nd(&m, 2));
    assert_eq!(u::nd_value_id(&m, 2), 20);
    assert_eq!(sm::head(&m), option::some(1));
    assert_eq!(sm::tail(&m), option::some(3));
    assert_eq!(sm::length(&m), len0);
    assert!(u::nd_value_id(&m, 1) == 10 && u::nd_value_id(&m, 3) == 30); // values intact
    // drain
    u::nd_unwrap(u::rm_nd(&mut m, 1).destroy_some());
    u::nd_unwrap(u::rm_nd(&mut m, 2).destroy_some());
    u::nd_unwrap(u::rm_nd(&mut m, 3).destroy_some());
    sm::destroy_empty(m);
}

// === Real resource V: Coin<SUI> round-trips with value preserved ===

#[test]
fun coin_value_roundtrip() {
    let mut ctx = tx_context::dummy();
    let mut m = sm::new<u64, Coin<SUI>>();
    sm::insert!(&mut m, 1, coin::mint_for_testing<SUI>(100, &mut ctx)).destroy_none();
    sm::insert!(&mut m, 2, coin::mint_for_testing<SUI>(250, &mut ctx)).destroy_none();
    assert_eq!(sm::borrow!(&m, &1).value(), 100);
    // upsert returns the displaced coin - it must be burned, not dropped.
    let old = sm::insert!(&mut m, 1, coin::mint_for_testing<SUI>(999, &mut ctx)).destroy_some();
    assert_eq!(old.value(), 100);
    coin::burn_for_testing(old);
    assert_eq!(sm::borrow!(&m, &1).value(), 999);
    // remove returns the coin
    let r1 = sm::remove!(&mut m, &1).destroy_some();
    assert_eq!(r1.value(), 999);
    coin::burn_for_testing(r1);
    // pop the remaining coin
    let (_k, r2) = sm::pop_back(&mut m);
    assert_eq!(r2.value(), 250);
    coin::burn_for_testing(r2);
    sm::destroy_empty(m);
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
        let a = u::nd_unwrap(u::rm_nd(&mut w.m, 1).destroy_some());
        let b = u::nd_unwrap(u::rm_nd(&mut w.m, 2).destroy_some());
        assert_eq!(a + b, 33);
        ts::return_shared(w);
    };
    sc.next_tx(admin);
    {
        let Wrapper { id, m } = sc.take_shared<Wrapper>();
        // The drained husk is consumed by value. No child/dynamic-field objects could ever
        // exist (the map is UID-less) - this is structural, not asserted here;
        // sc.end() would error on any dangling object, which is the implicit check.
        sm::destroy_empty(m);
        id.delete();
    };
    sc.end();
}

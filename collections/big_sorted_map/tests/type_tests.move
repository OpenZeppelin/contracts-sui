/// The type-level / ability + object-model suite - the compiler-enforced bucket plus the object
/// lifecycle witnesses that distinguish BSM from its value-type siblings. The type bucket needs
/// POSITIVE round-trips (instantiating/using the object proves the ability holds) plus COMMENTED
/// non-compiling snippets for the negatives.
module openzeppelin_big_sorted_map::type_tests;

use openzeppelin_big_sorted_map::big_sorted_map::{Self as bsm, BigSortedMap};
use openzeppelin_big_sorted_map::test_util as u;
use std::unit_test::assert_eq;
use sui::test_scenario as ts;

// A consumer object that EMBEDS a BSM by value (BSM is `store`). The df children of the embedded
// map travel with this object when it is shared/transferred.
public struct Holder has key {
    id: UID,
    map: BigSortedMap<u64, u64>,
}

// === embed a BSM in a shared object, mutate it through the object, then drain + delete ===

#[test]
fun embed_in_object_share_mutate_teardown() {
    let admin = @0xAD;
    let mut sc = ts::begin(admin);
    {
        let mut map = bsm::new_with_config<u64, u64>(4, 3, sc.ctx());
        let mut k = 1u64;
        while (k <= 10) { u::ins(&mut map, k, k * 10); k = k + 1; };
        transfer::share_object(Holder { id: object::new(sc.ctx()), map });
    };
    // a later tx mutates the embedded map THROUGH the shared object - the whole subtree came along.
    sc.next_tx(admin);
    {
        let mut h = sc.take_shared<Holder>();
        assert_eq!(bsm::length(&h.map), 10);
        u::ins(&mut h.map, 11, 110);
        let (k, v) = bsm::pop_front(&mut h.map);
        assert!(k == 1 && v == 10);
        assert!(u::bsm_well_formed(&h.map, 4, 3, true));
        ts::return_shared(h);
    };
    // teardown: the map can ONLY end via destroy_empty (copy/drop forced off) - drain then delete.
    sc.next_tx(admin);
    {
        let h = sc.take_shared<Holder>();
        let Holder { id, map } = h;
        u::drain_destroy(map); // drain-then-destroy_empty; never an implicit drop
        id.delete();
    };
    sc.end();
}

// === a BSM is itself a first-class shareable object (key + store) ===

#[test]
fun bsm_shared_directly() {
    let admin = @0xAD;
    let mut sc = ts::begin(admin);
    {
        let mut map = bsm::new_with_config<u64, u64>(4, 3, sc.ctx());
        let mut k = 1u64;
        while (k <= 6) { u::ins(&mut map, k, k); k = k + 1; };
        transfer::public_share_object(map); // key + store -> shareable directly, no wrapper
    };
    sc.next_tx(admin);
    {
        let mut map = sc.take_shared<BigSortedMap<u64, u64>>();
        u::ins(&mut map, 7, 7);
        assert_eq!(bsm::length(&map), 7);
        ts::return_shared(map);
    };
    sc.next_tx(admin);
    {
        let map = sc.take_shared<BigSortedMap<u64, u64>>();
        u::drain_destroy(map);
    };
    sc.end();
}

// === distinct instantiations are independent, incompatible types ===

#[test]
fun distinct_instantiations_coexist() {
    let mut ctx = tx_context::dummy();
    let mut a = bsm::new_with_config<u64, u64>(4, 3, &mut ctx);
    let mut b = bsm::new_with_config<u64, u::NoDrop>(4, 3, &mut ctx);
    u::ins(&mut a, 1, 100);
    u::ins_nd(&mut b, 1, u::nd(999)).destroy_none();
    // independent state, independent V types.
    assert_eq!(u::get(&a, 1), 100);
    assert_eq!(u::nd_value_id(&b, 1), 999);
    assert!(bsm::length(&a) == 1 && bsm::length(&b) == 1);
    u::drain_destroy(a);
    u::drain_destroy_nd(b);
}

// === keys leave only BY VALUE; a retained key copy is independent; borrow_mut is &mut V ===

#[test]
fun keys_immutable_returned_by_value() {
    let mut ctx = tx_context::dummy();
    let mut map = bsm::new_with_config<u64, u64>(4, 3, &mut ctx);
    let mut k = 1u64;
    while (k <= 10) { u::ins(&mut map, k, k * 10); k = k + 1; };
    // retain a returned key (a COPY of a u64, never an alias into the tree).
    let retained = bsm::head(&map);
    assert_eq!(retained, option::some(1));
    // mutate the tree: a value via borrow_mut (&mut V, never &mut K), and remove/insert the min.
    u::set(&mut map, 5, 5555);
    u::rem(&mut map, 1);            // remove the old min
    u::ins(&mut map, 0, 0);         // add a new min
    // LOAD-BEARING: the LIVE tree's min actually changed (this could fail if rem/ins/borrow_mut
    // had desynced key position); the retained copy staying some(1) is value-semantics, not a test.
    assert_eq!(bsm::head(&map), option::some(0));
    assert_eq!(retained, option::some(1)); // the captured copy is independent of the live tree
    // the tree's keys are still strictly sorted (borrow_mut touched V, not key position).
    assert!(u::bsm_well_formed(&map, 4, 3, true));
    assert_eq!(u::get(&map, 5), 5555);
    u::drain_destroy(map);
}

// === a populated BSM transferred to an address as an OWNED object - children travel ===
// The suite proves the SHARE half twice (public_share_object directly; share_object of a Holder) but
// never the OWNED-transfer half. Owned and shared are distinct Sui lifecycles: share keeps the object
// in the consensus pool, owned-transfer relocates it to a single account. A regression wiring df
// children to anything other than the object's own UID survives every share-based test; only an
// owned handoff + later take witnesses a pre-transfer df key staying reachable in the new owner's tx.

// Pins branch: BigSortedMap / given a populated tree transferred to an address (owned) / when the owner takes + mutates it later / its df children traveled with the object
#[test]
fun owned_transfer_roundtrip_children_travel() {
    let owner = @0xBEEF;
    let mut sc = ts::begin(owner);
    {
        let mut map = bsm::new_with_config<u64, u64>(4, 3, sc.ctx());
        let mut k = 1u64;
        while (k <= 10) { u::ins(&mut map, k, k * 10); k = k + 1; }; // degree 4,3 -> real df children
        assert!(u::bsm_well_formed(&map, 4, 3, true));
        transfer::public_transfer(map, owner); // key + store -> owned transfer to an address
    };
    sc.next_tx(owner);
    {
        let mut map = sc.take_from_address<BigSortedMap<u64, u64>>(owner);
        assert_eq!(bsm::length(&map), 10);    // cached length survived the handoff
        assert_eq!(u::get(&map, 7), 70);      // a df-stored key/value traveled with the object
        assert!(u::bsm_well_formed(&map, 4, 3, true));
        u::ins(&mut map, 11, 110);              // mutate as the new owner
        assert_eq!(u::get(&map, 11), 110);
        transfer::public_transfer(map, owner);
    };
    sc.next_tx(owner);
    {
        let map = sc.take_from_address<BigSortedMap<u64, u64>>(owner);
        u::drain_destroy(map);
    };
    sc.end();
}

// ===========================================================================
// Commented NON-COMPILING snippets (the negative compile-fail bucket)
// ===========================================================================
//
// Each would fail to type-check - which is the proof. Kept here (positive round-trips plus
// commented non-compiling snippets) so a reviewer sees what the type system forecloses.
//
// A BSM is NEVER copy/drop (UID forces them off), so it cannot fall out of scope or be
// copied; it must be drained and destroy_empty'd:
//     fun leak(ctx: &mut TxContext) { let _m = bsm::new<u64,u64>(ctx); }  // E: BigSortedMap has no 'drop'
//     let m2 = copy m;                                                    // E: BigSortedMap has no 'copy'
//
// Node is store-only (no drop/copy) and its constructors are private; a consumer cannot
// build or drop a Node, so a subtree can never be orphaned by a dropped node:
//     let n = bsm::new_leaf<u64,u64>(0, 0);   // E03003: 'new_leaf' is internal to big_sorted_map
//
// K and V are NOT phantom (both appear in Node fields); a phantom annotation is rejected:
//     // in big_sorted_map: public struct BigSortedMap<phantom K, ...>  // E: K used in field types
//
// No accessor yields &mut K or &mut Entry; the strongest mutable handle is &mut V:
//     let _km: &mut u64 = /* there is no key_at_mut / entry_mut anywhere on the BSM surface */;
//     // borrow_mut!/value_at_mut return &mut V only; a key changes only by remove-then-reinsert.
//
// There is no `version` field and no enum wrapper (a frozen df-backed layout cannot
// migrate in place); evolution is a parallel BigSortedMapV2 + consumer copy-migration.
//
// A bare macro on a non-integer key fails (no built-in `<`); the `_by` form is required:
//     let mut m = bsm::new<u::Key, u64>(&mut ctx);
//     bsm::insert!(&mut m, u::mk(1), 1);     // E: `<` is not defined for the struct key 'Key'

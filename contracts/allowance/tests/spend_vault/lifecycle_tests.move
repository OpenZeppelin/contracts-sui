// Vault lifecycle: new, share, destroy. Covers the ledger-side surface of the
// vault lifecycle: creating a vault with its sole vault-bound OwnerCap, the
// atomic single-PTB create+fund+mint+grant+share+handoff setup, sharing, and
// tearing down a vault (draining the ledger, deleting the UIDs, orphaning live
// caps, and the VaultCreated / VaultDestroyed events).
//
// A `new` that neither shares nor destroys the vault is a compile-time property:
// `Vault` has `key` and only `key`, so a no-drop value left unconsumed does not
// type-check and the file would not build. It is therefore not expressible as a
// runtime test and is asserted here only by the fact that every test consumes
// its vault via share or destroy.
//
// Pool-balance effects of destroy (destroy does NOT drain the address-balance
// pool; the owner must withdraw_all<T> every coin first) need a live
// AccumulatorRoot, which the unit-test VM cannot construct; they are not exercised
// by this package's tests (they require a live network). Only the ledger leg lives here.
module openzeppelin_allowance::spend_vault_lifecycle_tests;

use openzeppelin_allowance::spend_vault;
use openzeppelin_allowance::sv_test_utils::{Self as u, USDC, SUIT};
use std::unit_test::assert_eq;
use sui::event;
use sui::test_scenario as ts;

const OWNER: address = @0xA;
const SPENDER: address = @0xB;
const MAXU64: u64 = 18_446_744_073_709_551_615;

// === new: vault + sole OwnerCap, binding, VaultCreated event ===

#[test]
// new returns one vault + one OwnerCap whose vault_id binds to the vault, and
// emits exactly one VaultCreated{vault_id, owner_cap_id, creator}.
fun new_returns_vault_and_bound_owner_cap() {
    let mut s = ts::begin(OWNER);
    {
        let (v, oc) = spend_vault::new(s.ctx());
        let vid = object::id(&v);
        let ocid = object::id(&oc);

        // The OwnerCap is bound to exactly this vault.
        assert_eq!(spend_vault::owner_cap_vault_id(&oc), vid);

        // One VaultCreated, creator == sender (OWNER here).
        let evs = event::events_by_type<spend_vault::VaultCreated>();
        assert_eq!(evs.length(), 1);
        assert_eq!(evs[0], spend_vault::test_new_vault_created(vid, ocid, OWNER));

        spend_vault::share(v);
        transfer::public_transfer(oc, OWNER);
    };
    s.end();
}

#[test]
// A freshly created vault has an empty ledger (no caps minted yet) and no
// granted coin types: new builds only the vault + its sole OwnerCap.
fun new_vault_has_empty_ledger() {
    let mut s = ts::begin(OWNER);
    {
        let (v, oc) = spend_vault::new(s.ctx());
        assert_eq!(spend_vault::granted_coin_types(&v).length(), 0);
        spend_vault::share(v);
        transfer::public_transfer(oc, OWNER);
    };
    s.end();
}

#[test]
// VaultCreated.creator is ctx.sender() and may differ from the eventual owner:
// create as a third party, hand the cap to OWNER.
fun new_creator_may_differ_from_owner() {
    let creator: address = @0xC0FFEE;
    let mut s = ts::begin(creator);
    {
        let (v, oc) = spend_vault::new(s.ctx());
        let vid = object::id(&v);
        let ocid = object::id(&oc);
        let evs = event::events_by_type<spend_vault::VaultCreated>();
        assert_eq!(evs.length(), 1);
        assert_eq!(evs[0], spend_vault::test_new_vault_created(vid, ocid, creator));
        spend_vault::share(v);
        transfer::public_transfer(oc, OWNER); // owner != creator
    };
    s.end();
}

#[test]
// Each new() is independent: two vaults get distinct ids and distinct,
// correctly-bound OwnerCaps (one cap per vault, no cross-binding). Two
// VaultCreated events in the tx, one per vault.
fun two_new_vaults_are_independent() {
    let mut s = ts::begin(OWNER);
    {
        let (v1, oc1) = spend_vault::new(s.ctx());
        let (v2, oc2) = spend_vault::new(s.ctx());
        let vid1 = object::id(&v1);
        let vid2 = object::id(&v2);

        assert!(vid1 != vid2);
        // each cap binds to its own vault, never the other.
        assert_eq!(spend_vault::owner_cap_vault_id(&oc1), vid1);
        assert_eq!(spend_vault::owner_cap_vault_id(&oc2), vid2);
        assert!(spend_vault::owner_cap_vault_id(&oc1) != vid2);

        let evs = event::events_by_type<spend_vault::VaultCreated>();
        assert_eq!(evs.length(), 2);

        spend_vault::share(v1);
        spend_vault::share(v2);
        transfer::public_transfer(oc1, OWNER);
        transfer::public_transfer(oc2, OWNER);
    };
    s.end();
}

// === atomic single-PTB create+fund+mint+grant+share+handoff ===

#[test]
// The full setup composes in one tx and the resulting vault is usable in the
// next tx (cap takeable, grant present, owner cap takeable).
fun full_one_ptb_setup_succeeds() {
    let mut s = ts::begin(OWNER);
    // setup_granted does new -> deposit -> mint_cap -> set_allowance -> share ->
    // transfer(owner_cap) -> transfer(spender_cap) -> share(clock), all in tx 0.
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(SPENDER);
    {
        let v = u::take_vault(&s);
        let cap = u::take_spender_cap(&s, SPENDER);
        let oc = u::take_owner_cap(&s, OWNER);
        // grant landed atomically with the share.
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 500);
        assert!(spend_vault::contains<USDC>(&v, cid));
        ts::return_to_sender(&s, cap);
        ts::return_to_address(OWNER, oc);
        u::return_vault(v);
    };
    s.end();
}

#[test]
// Explicit inline version: new -> deposit USDC -> mint_cap -> set_allowance ->
// share -> transfer(owner_cap), all in ONE tx, then verify the shared vault in
// the next tx. Mirrors setup_granted but spelled out.
fun explicit_one_ptb_setup_succeeds() {
    let mut s = ts::begin(OWNER);
    let cid;
    {
        let clk = u::clock_at(u::start_ms(), s.ctx());
        let (mut v, oc) = spend_vault::new(s.ctx());
        spend_vault::deposit(&v, sui::coin::mint_for_testing<USDC>(1_000, s.ctx()), s.ctx());
        let cap = spend_vault::mint_cap(&v, &oc, s.ctx());
        cid = object::id(&cap);
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            500,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        spend_vault::share(v);
        transfer::public_transfer(cap, SPENDER);
        transfer::public_transfer(oc, OWNER);
        clk.share_for_testing();
    };
    s.next_tx(SPENDER);
    {
        let v = u::take_vault(&s);
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 500);
        u::return_vault(v);
    };
    s.end();
}

// === share emits nothing ===

#[test]
// share emits no event. new() emits one VaultCreated; the subsequent share adds
// nothing, so the only VaultCreated in the tx is new()'s.
fun share_emits_no_event() {
    let mut s = ts::begin(OWNER);
    {
        let (v, oc) = spend_vault::new(s.ctx());
        let vid = object::id(&v);
        let ocid = object::id(&oc);
        spend_vault::share(v); // <- the action under test; must add no event
        // Still exactly one VaultCreated (from new); share contributed none.
        let evs = event::events_by_type<spend_vault::VaultCreated>();
        assert_eq!(evs.length(), 1);
        assert_eq!(evs[0], spend_vault::test_new_vault_created(vid, ocid, OWNER));
        // and zero VaultDestroyed: share is not a teardown.
        assert_eq!(event::events_by_type<spend_vault::VaultDestroyed>().length(), 0);
        transfer::public_transfer(oc, OWNER);
    };
    s.end();
}

// === destroy: empty / never-shared, same-tx ===

#[test]
// A freshly created, NEVER-shared, empty vault is torn down in the same tx (new
// then destroy) and emits one VaultDestroyed{vault_id, by}.
fun destroy_fresh_empty_vault_same_tx() {
    let mut s = ts::begin(OWNER);
    {
        let (v, oc) = spend_vault::new(s.ctx());
        let vid = object::id(&v);
        spend_vault::destroy(v, oc, s.ctx());

        let evs = event::events_by_type<spend_vault::VaultDestroyed>();
        assert_eq!(evs.length(), 1);
        assert_eq!(evs[0], spend_vault::test_new_vault_destroyed(vid, OWNER));
    };
    s.end();
}

#[test]
// Pins the documented DANGER: `destroy` succeeds with coins still in the pool.
// There is NO on-chain guard that blocks a premature destroy of a funded vault,
// so this teardown of a vault holding 1_000 USDC in its address-balance pool
// completes and emits exactly one VaultDestroyed. Those coins then strand at the
// dead vault address, but the UID is gone, so the stranded balance is NOT
// observable in a unit test and is therefore not asserted here.
fun destroy_with_funded_pool_succeeds() {
    let mut s = ts::begin(OWNER);
    {
        let (v, oc) = spend_vault::new(s.ctx());
        let vid = object::id(&v);
        // Fund a non-zero pool, then destroy without draining it.
        spend_vault::deposit(&v, sui::coin::mint_for_testing<USDC>(1_000, s.ctx()), s.ctx());
        spend_vault::destroy(v, oc, s.ctx()); // SUCCEEDS despite the funded pool

        let evs = event::events_by_type<spend_vault::VaultDestroyed>();
        assert_eq!(evs.length(), 1);
        assert_eq!(evs[0], spend_vault::test_new_vault_destroyed(vid, OWNER));
    };
    s.end();
}

// === destroy: shared vault, canonical teardown ===

#[test]
// The canonical teardown: share in tx 0, then in a later tx take_shared<Vault> +
// take the owner cap and destroy. VaultDestroyed emitted with by == the
// destroying sender.
fun destroy_shared_vault_in_later_tx() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 0); // empty, shared, oc -> OWNER
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        assert_eq!(object::id(&v), vid);
        spend_vault::destroy(v, oc, s.ctx());

        let evs = event::events_by_type<spend_vault::VaultDestroyed>();
        assert_eq!(evs.length(), 1);
        assert_eq!(evs[0], spend_vault::test_new_vault_destroyed(vid, OWNER));
    };
    s.end();
}

// === destroy: drains a populated ledger ===

#[test]
// destroy fully pop_front-drains a non-empty ledger. Build a vault with 3
// entries (cap1: USDC+SUIT, cap2: USDC) in tx 0, then destroy in a later tx:
// succeeds (the drain loop empties the table before destroy_empty), one
// VaultDestroyed emitted.
fun destroy_drains_three_ledger_entries() {
    let mut s = ts::begin(OWNER);
    let vid;
    {
        let clk = u::clock_at(u::start_ms(), s.ctx());
        let (mut v, oc) = spend_vault::new(s.ctx());
        vid = object::id(&v);
        let cap1 = spend_vault::mint_cap(&v, &oc, s.ctx());
        let cap2 = spend_vault::mint_cap(&v, &oc, s.ctx());
        let cid1 = object::id(&cap1);
        let cid2 = object::id(&cap2);
        // cap1 granted two coins, cap2 granted one: 3 ledger entries total.
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid1,
            100,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        spend_vault::set_allowance<SUIT>(
            &mut v,
            &oc,
            cid1,
            200,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid2,
            300,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        spend_vault::share(v);
        transfer::public_transfer(cap1, SPENDER);
        transfer::public_transfer(cap2, SPENDER);
        transfer::public_transfer(oc, OWNER);
        clk.share_for_testing();
    };
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        spend_vault::destroy(v, oc, s.ctx()); // drains all 3 entries, then deletes UIDs

        let evs = event::events_by_type<spend_vault::VaultDestroyed>();
        assert_eq!(evs.length(), 1);
        assert_eq!(evs[0], spend_vault::test_new_vault_destroyed(vid, OWNER));
    };
    s.end();
}

#[test]
// destroy of a once-populated vault whose ledger was emptied first (here by
// revoke_all) still succeeds: the drain loop is a no-op and destroy_empty is the
// live backstop. VaultDestroyed emitted.
fun destroy_after_revoke_all_emptied_ledger() {
    let mut s = ts::begin(OWNER);
    let vid;
    let cid;
    {
        let clk = u::clock_at(u::start_ms(), s.ctx());
        let (mut v, oc) = spend_vault::new(s.ctx());
        vid = object::id(&v);
        let cap = spend_vault::mint_cap(&v, &oc, s.ctx());
        cid = object::id(&cap);
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            100,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        spend_vault::set_allowance<SUIT>(
            &mut v,
            &oc,
            cid,
            200,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        spend_vault::share(v);
        transfer::public_transfer(cap, SPENDER);
        transfer::public_transfer(oc, OWNER);
        clk.share_for_testing();
    };
    // Owner empties the ledger via revoke_all.
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        spend_vault::revoke_all(&mut v, &oc, cid, s.ctx());
        assert!(!spend_vault::contains<USDC>(&v, cid));
        assert!(!spend_vault::contains<SUIT>(&v, cid));
        u::return_vault(v);
        ts::return_to_address(OWNER, oc);
    };
    // Now destroy the emptied vault.
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        spend_vault::destroy(v, oc, s.ctx());

        let evs = event::events_by_type<spend_vault::VaultDestroyed>();
        assert_eq!(evs.length(), 1);
        assert_eq!(evs[0], spend_vault::test_new_vault_destroyed(vid, OWNER));
    };
    s.end();
}

// === destroy: foreign OwnerCap aborts (binding gate) ===

#[test, expected_failure(abort_code = spend_vault::EWrongOwnerCap)]
// Destroying vault A with vault B's OwnerCap aborts EWrongOwnerCap (the binding
// gate is the first and only check).
fun destroy_with_foreign_owner_cap_aborts() {
    let mut s = ts::begin(OWNER);
    let _vid = u::new_funded_vault<USDC>(&mut s, OWNER, 0); // vault A, shared
    s.next_tx(OWNER);
    let va = u::take_vault(&s);
    // a SECOND, unrelated vault B; its owner cap is foreign to A.
    let (_vb, ocb) = spend_vault::new(s.ctx());
    spend_vault::destroy(va, ocb, s.ctx()); // EWrongOwnerCap: ocb binds to B, not A
    abort
}

// === destroy orphans live caps; orphan is disposable ===

#[test]
// destroy orphans every live cap; in a later tx the SpenderCap still exists and
// delete_orphaned_cap disposes it, emitting one CapDeleted.
fun destroy_orphans_cap_then_delete_orphaned() {
    let mut s = ts::begin(OWNER);
    let vid;
    let cid;
    {
        let (v, oc) = spend_vault::new(s.ctx());
        vid = object::id(&v);
        let cap = spend_vault::mint_cap(&v, &oc, s.ctx());
        cid = object::id(&cap);
        spend_vault::share(v);
        transfer::public_transfer(cap, SPENDER);
        transfer::public_transfer(oc, OWNER);
    };
    // Owner tears the vault down; the cap is now orphaned in SPENDER's wallet.
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        spend_vault::destroy(v, oc, s.ctx());
    };
    // The orphaned SpenderCap still exists and is disposable.
    s.next_tx(SPENDER);
    {
        let cap = u::take_spender_cap(&s, SPENDER);
        // sanity: the orphan still reports its original vault binding.
        assert_eq!(spend_vault::spender_cap_vault_id(&cap), vid);
        spend_vault::delete_orphaned_cap(cap);

        let evs = event::events_by_type<spend_vault::CapDeleted>();
        assert_eq!(evs.length(), 1);
        assert_eq!(evs[0], spend_vault::test_new_cap_deleted(vid, cid));
    };
    s.end();
}

#[test]
// destroy consumes the OwnerCap BY VALUE. After teardown, no OwnerCap remains at
// OWNER's address; a follow-up take would have nothing. We witness consumption
// indirectly: a destroyed vault leaves the address with no OwnerCap to re-take
// (we simply do not re-take it; the by-value signature of destroy guarantees it
// is gone). This test pins that the by-value teardown path runs clean for a
// shared, populated vault.
fun destroy_consumes_owner_cap_by_value() {
    let mut s = ts::begin(OWNER);
    let vid;
    {
        let clk = u::clock_at(u::start_ms(), s.ctx());
        let (mut v, oc) = spend_vault::new(s.ctx());
        vid = object::id(&v);
        let cap = spend_vault::mint_cap(&v, &oc, s.ctx());
        let c = object::id(&cap);
        spend_vault::set_allowance<USDC>(&mut v, &oc, c, 50, MAXU64, option::none(), &clk, s.ctx());
        spend_vault::share(v);
        transfer::public_transfer(cap, SPENDER);
        transfer::public_transfer(oc, OWNER);
        clk.share_for_testing();
    };
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER); // the ONE owner cap
        spend_vault::destroy(v, oc, s.ctx()); // <- consumes it by value

        let evs = event::events_by_type<spend_vault::VaultDestroyed>();
        assert_eq!(evs.length(), 1);
        assert_eq!(evs[0], spend_vault::test_new_vault_destroyed(vid, OWNER));
    };
    s.end();
}

#[test]
// The destroying sender attribution: `by` is ctx.sender() of the destroy call,
// which can be any holder of the OwnerCap (here a rotated owner).
fun destroy_by_is_sender() {
    let new_owner: address = @0xDEAD;
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 0);
    // OWNER rotates the cap to new_owner.
    s.next_tx(OWNER);
    {
        let oc = u::take_owner_cap(&s, OWNER);
        transfer::public_transfer(oc, new_owner);
    };
    s.next_tx(new_owner);
    {
        let v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, new_owner);
        spend_vault::destroy(v, oc, s.ctx());

        let evs = event::events_by_type<spend_vault::VaultDestroyed>();
        assert_eq!(evs.length(), 1);
        assert_eq!(evs[0], spend_vault::test_new_vault_destroyed(vid, new_owner));
    };
    s.end();
}

// === destroy is unconditional w.r.t. ledger STATE ===

// Given a ledger holding suspended (remaining 0), expired, and unlimited entries
// across two caps, destroy tears the vault down regardless of entry state (one
// VaultDestroyed, no spender/ledger precondition): the owner exit is
// unconditional and ledger-independent, and the drain handles whatever exists.
#[test]
fun destroy_unconditional_over_adversarial_ledger() {
    let mut s = ts::begin(OWNER);
    let future = u::start_ms() + 1_000;
    let vid;
    {
        let clk = u::clock_at(u::start_ms(), s.ctx());
        let (mut v, oc) = spend_vault::new(s.ctx());
        vid = object::id(&v);
        let cap1 = spend_vault::mint_cap(&v, &oc, s.ctx());
        let c1 = object::id(&cap1);
        let cap2 = spend_vault::mint_cap(&v, &oc, s.ctx());
        let c2 = object::id(&cap2);
        spend_vault::set_allowance<USDC>(&mut v, &oc, c1, 0, MAXU64, option::none(), &clk, s.ctx()); // suspended
        spend_vault::set_allowance<SUIT>(
            &mut v,
            &oc,
            c1,
            100,
            future,
            option::none(),
            &clk,
            s.ctx(),
        ); // will expire
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            c2,
            MAXU64,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        ); // unlimited
        transfer::public_transfer(cap1, SPENDER);
        transfer::public_transfer(cap2, SPENDER);
        spend_vault::share(v);
        transfer::public_transfer(oc, OWNER);
        clk.share_for_testing();
    };
    s.next_tx(OWNER);
    {
        let mut clk = u::take_clock(&s);
        clk.set_for_testing(future + 1); // the SUIT entry is now expired
        let v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        spend_vault::destroy(v, oc, s.ctx());
        let evs = event::events_by_type<spend_vault::VaultDestroyed>();
        assert_eq!(evs.length(), 1);
        assert_eq!(evs[0], spend_vault::test_new_vault_destroyed(vid, OWNER));
        u::return_clock(clk);
    };
    s.end();
}

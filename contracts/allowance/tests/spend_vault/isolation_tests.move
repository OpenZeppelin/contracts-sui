// Isolation triad + batching/sequencing (no AccumulatorRoot functions).
//
// Covers vault/cap/coin-type isolation, per-(cap,coin) independence, multi-call
// PTB batching of each verb, and the two sequential spend/revoke orderings.
//
// Pool-balance effects need an AccumulatorRoot, which the unit-test VM cannot
// construct; those (the native pool-short abort and every &AccumulatorRoot-taking
// read) are not exercised by this package's tests.
module openzeppelin_allowance::spend_vault_isolation_tests;

use openzeppelin_allowance::spend_vault::{Self, SpenderCap};
use openzeppelin_allowance::sv_test_utils::{Self as u, USDC, SUIT, DEEP};
use std::type_name;
use std::unit_test::{assert_eq, destroy};
use sui::coin;
use sui::event;
use sui::test_scenario as ts;

const OWNER: address = @0xA;
const SPENDER: address = @0xB;
const MAXU64: u64 = 18_446_744_073_709_551_615;

// === CROSS-VAULT ===

#[test, expected_failure(abort_code = spend_vault::EWrongVault)]
fun spend_with_foreign_vault_cap_aborts_wrong_vault() {
    // A SpenderCap bound to vault B presented to spend on vault A -> code 1.
    let mut s = ts::begin(OWNER);
    // Vault A: the target of the spend.
    let (_vida, _cida) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(SPENDER);
    let mut va = u::take_vault(&s);
    let clk = u::take_clock(&s);
    // Vault B: a brand-new, granted vault; mint a cap bound to B.
    let (mut vb, ocb) = spend_vault::new(s.ctx());
    let capb = spend_vault::mint_cap(&vb, &ocb, s.ctx());
    let cidb = object::id(&capb);
    spend_vault::set_allowance<USDC>(
        &mut vb,
        &ocb,
        cidb,
        500,
        MAXU64,
        option::none(),
        &clk,
        s.ctx(),
    );
    // B's cap on A -> EWrongVault (code 1), before any ledger access.
    let b = spend_vault::spend<USDC>(&mut va, &capb, 100, &clk, s.ctx());
    destroy(b);
    abort
}

#[test, expected_failure(abort_code = spend_vault::EWrongOwnerCap)]
fun revoke_with_foreign_owner_cap_aborts_wrong_owner_cap() {
    // An OwnerCap bound to vault B presented to revoke on vault A -> code 0.
    let mut s = ts::begin(OWNER);
    let (_vida, cida) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(OWNER);
    let mut va = u::take_vault(&s);
    // Vault B with its own OwnerCap.
    let (_vb, ocb) = spend_vault::new(s.ctx());
    // B's owner cap used to revoke A's grant -> EWrongOwnerCap (code 0).
    let _ = spend_vault::revoke<USDC>(&mut va, &ocb, cida, s.ctx());
    abort
}

#[test]
fun op_on_vault_a_leaves_vault_b_ledger_untouched() {
    // A spend on A leaves B's allowance bit-identical (a DIFFERENT object).
    let mut s = ts::begin(OWNER);
    // Vault A and Vault B both funded + granted USDC=500 to their own caps.
    let (vida, cida) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 10_000, 500, MAXU64);
    let (vidb, cidb) = make_second_vault(&mut s);
    // Operate on A: spend 200 via cap A. B (a separate shared object) must be untouched.
    s.next_tx(SPENDER);
    {
        let mut va = ts::take_shared_by_id<spend_vault::Vault>(&s, vida);
        let vb = ts::take_shared_by_id<spend_vault::Vault>(&s, vidb);
        let clk = u::take_clock(&s);
        let capa = ts::take_from_address_by_id<SpenderCap>(&s, SPENDER, cida);
        let b = spend_vault::spend<USDC>(&mut va, &capa, 200, &clk, s.ctx());
        assert_eq!(spend_vault::allowance<USDC>(&va, cida), 300); // A drawn
        // B's ledger is read off a DIFFERENT vault object: cannot have shifted.
        assert_eq!(spend_vault::allowance<USDC>(&vb, cidb), 500);
        assert!(spend_vault::contains<USDC>(&vb, cidb));
        destroy(b);
        ts::return_to_address(SPENDER, capa);
        u::return_vault(va);
        u::return_vault(vb);
        u::return_clock(clk);
    };
    s.end();
}

// === CROSS-CAP ===

#[test]
fun revoke_cap_x_leaves_cap_y_live_and_spendable() {
    // One vault, two caps both granted USDC=500; revoke X -> Y still live.
    let mut s = ts::begin(OWNER);
    let (_vid, cidx, cidy) = two_cap_vault(&mut s);
    // Owner revokes cap X's USDC.
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let was = spend_vault::revoke<USDC>(&mut v, &oc, cidx, s.ctx());
        assert!(was); // X was present, now removed
        assert!(!spend_vault::contains<USDC>(&v, cidx)); // X gone
        assert!(spend_vault::contains<USDC>(&v, cidy)); // Y untouched
        assert_eq!(spend_vault::allowance<USDC>(&v, cidy), 500);
        ts::return_to_address(OWNER, oc);
        u::return_vault(v);
    };
    // Cap Y can still spend its full 500.
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let capy = ts::take_from_address_by_id<SpenderCap>(&s, SPENDER, cidy);
        let b = spend_vault::spend<USDC>(&mut v, &capy, 500, &clk, s.ctx());
        assert_eq!(b.value(), 500);
        assert_eq!(spend_vault::allowance<USDC>(&v, cidy), 0);
        destroy(b);
        ts::return_to_address(SPENDER, capy);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

#[test]
fun spends_on_two_caps_draw_independently() {
    // Draw 200 on cap X -> X 300, cap Y still 500 (independent accounting).
    let mut s = ts::begin(OWNER);
    let (_vid, cidx, cidy) = two_cap_vault(&mut s);
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        // Both caps live at the same address; take each by its known id.
        let capx = ts::take_from_address_by_id<SpenderCap>(&s, SPENDER, cidx);
        let capy = ts::take_from_address_by_id<SpenderCap>(&s, SPENDER, cidy);
        // Spend on X only.
        let b = spend_vault::spend<USDC>(&mut v, &capx, 200, &clk, s.ctx());
        assert_eq!(spend_vault::allowance<USDC>(&v, cidx), 300); // X drawn
        assert_eq!(spend_vault::allowance<USDC>(&v, cidy), 500); // Y untouched
        destroy(b);
        ts::return_to_address(SPENDER, capx);
        ts::return_to_address(SPENDER, capy);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

#[test]
fun set_allowance_on_cap_x_leaves_cap_y_identical() {
    // Owner-side change to cap X never alters cap Y's entry.
    let mut s = ts::begin(OWNER);
    let (_vid, cidx, cidy) = two_cap_vault(&mut s);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cidx,
            999,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        assert_eq!(spend_vault::allowance<USDC>(&v, cidx), 999); // X changed
        assert_eq!(spend_vault::allowance<USDC>(&v, cidy), 500); // Y bit-identical
        assert_eq!(spend_vault::expiry<USDC>(&v, cidy), MAXU64);
        ts::return_to_address(OWNER, oc);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

// === CROSS-TYPE runtime gate ===

#[test, expected_failure(abort_code = spend_vault::ENoAllowance)]
fun usdc_cap_spend_suit_aborts_no_allowance() {
    // A USDC-only cap, spend<SUIT> -> code 2 (the runtime coin-type gate).
    let mut s = ts::begin(OWNER);
    let (_vid, _cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(SPENDER);
    let mut v = u::take_vault(&s);
    let clk = u::take_clock(&s);
    let cap = ts::take_from_address<SpenderCap>(&s, SPENDER);
    let b = spend_vault::spend<SUIT>(&mut v, &cap, 100, &clk, s.ctx()); // code 2
    destroy(b);
    abort
}

#[test]
fun cross_type_other_coin_spends_after_grant() {
    // Granting the second coin makes spend<SUIT> succeed; the gate is purely the
    // (cap, coin) entry presence, not the cap object.
    let mut s = ts::begin(OWNER);
    let (vid, cid) = build_usdc_suit_cap(&mut s);
    let _ = vid;
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_address<SpenderCap>(&s, SPENDER);
        let b = spend_vault::spend<SUIT>(&mut v, &cap, 100, &clk, s.ctx());
        assert_eq!(b.value(), 100);
        assert_eq!(spend_vault::allowance<SUIT>(&v, cid), 200);
        destroy(b);
        ts::return_to_address(SPENDER, cap);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

// === PER-(cap,coin) NO-RESET ===

#[test]
fun revoke_usdc_leaves_suit_live() {
    // Set USDC+SUIT on one cap, revoke<USDC> -> SUIT still live + identical.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = build_usdc_suit_cap(&mut s);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let was = spend_vault::revoke<USDC>(&mut v, &oc, cid, s.ctx());
        assert!(was);
        assert!(!spend_vault::contains<USDC>(&v, cid)); // USDC removed
        assert!(spend_vault::contains<SUIT>(&v, cid)); // SUIT survives
        assert_eq!(spend_vault::allowance<SUIT>(&v, cid), 300);
        assert_eq!(spend_vault::expiry<SUIT>(&v, cid), MAXU64);
        ts::return_to_address(OWNER, oc);
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun update_usdc_budget_leaves_suit_bit_identical() {
    // Re-setting (cap, USDC) never touches (cap, SUIT)'s two scalars.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = build_usdc_suit_cap(&mut s);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let exp = u::start_ms() + 5_000;
        spend_vault::set_allowance<USDC>(&mut v, &oc, cid, 42, exp, option::none(), &clk, s.ctx());
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 42);
        assert_eq!(spend_vault::expiry<USDC>(&v, cid), exp);
        // SUIT entry: both scalars unchanged.
        assert_eq!(spend_vault::allowance<SUIT>(&v, cid), 300);
        assert_eq!(spend_vault::expiry<SUIT>(&v, cid), MAXU64);
        ts::return_to_address(OWNER, oc);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

// === BATCHING: N>=3 of one verb in ONE tx ===

#[test]
fun batch_three_deposits_mixed_coins_one_tx() {
    // N=3 deposits (mixed coins) in one tx, no per-tx caching assumption.
    let mut s = ts::begin(OWNER);
    s.next_tx(OWNER);
    {
        let (v, oc) = spend_vault::new(s.ctx());
        let vid = object::id(&v);
        spend_vault::deposit(&v, coin::mint_for_testing<USDC>(100, s.ctx()), s.ctx());
        spend_vault::deposit(&v, coin::mint_for_testing<SUIT>(200, s.ctx()), s.ctx());
        spend_vault::deposit(&v, coin::mint_for_testing<DEEP>(300, s.ctx()), s.ctx());
        // Three distinct-coin Deposited events emitted in this tx.
        let evs = event::events_by_type<spend_vault::Deposited>();
        assert_eq!(evs.length(), 3);
        assert!(
            evs.contains(
                &spend_vault::test_new_deposited(
                    vid,
                    type_name::with_defining_ids<USDC>(),
                    100,
                    OWNER,
                ),
            ),
        );
        assert!(
            evs.contains(
                &spend_vault::test_new_deposited(
                    vid,
                    type_name::with_defining_ids<SUIT>(),
                    200,
                    OWNER,
                ),
            ),
        );
        assert!(
            evs.contains(
                &spend_vault::test_new_deposited(
                    vid,
                    type_name::with_defining_ids<DEEP>(),
                    300,
                    OWNER,
                ),
            ),
        );
        spend_vault::share(v);
        transfer::public_transfer(oc, OWNER);
    };
    s.end();
}

#[test]
fun batch_three_mint_caps_yields_distinct_ids_one_tx() {
    // N=3 mint_cap in one tx -> 3 DISTINCT cap_ids (no first-call caching).
    let mut s = ts::begin(OWNER);
    s.next_tx(OWNER);
    {
        let (v, oc) = spend_vault::new(s.ctx());
        let c1 = spend_vault::mint_cap(&v, &oc, s.ctx());
        let c2 = spend_vault::mint_cap(&v, &oc, s.ctx());
        let c3 = spend_vault::mint_cap(&v, &oc, s.ctx());
        let id1 = object::id(&c1);
        let id2 = object::id(&c2);
        let id3 = object::id(&c3);
        assert!(id1 != id2);
        assert!(id2 != id3);
        assert!(id1 != id3);
        // Three SpenderCapMinted events in the one tx.
        let evs = event::events_by_type<spend_vault::SpenderCapMinted>();
        assert_eq!(evs.length(), 3);
        spend_vault::delete_orphaned_cap(c1);
        spend_vault::delete_orphaned_cap(c2);
        spend_vault::delete_orphaned_cap(c3);
        spend_vault::share(v);
        transfer::public_transfer(oc, OWNER);
    };
    s.end();
}

#[test]
fun batch_three_set_allowance_across_coins_one_tx() {
    // N=3 set_allowance across 3 coins on one cap in one tx, all create.
    let mut s = ts::begin(OWNER);
    s.next_tx(OWNER);
    {
        let (mut v, oc) = spend_vault::new(s.ctx());
        let clk = u::clock_at(u::start_ms(), s.ctx());
        let cap = spend_vault::mint_cap(&v, &oc, s.ctx());
        let cid = object::id(&cap);
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
        spend_vault::set_allowance<DEEP>(
            &mut v,
            &oc,
            cid,
            300,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        // All three independent budgets land on the one cap.
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 100);
        assert_eq!(spend_vault::allowance<SUIT>(&v, cid), 200);
        assert_eq!(spend_vault::allowance<DEEP>(&v, cid), 300);
        // granted_coin_types records all three.
        assert_eq!(spend_vault::granted_coin_types(&v).length(), 3);
        // Three AllowanceSet events in the one tx.
        let evs = event::events_by_type<spend_vault::AllowanceSet>();
        assert_eq!(evs.length(), 3);
        spend_vault::delete_orphaned_cap(cap);
        spend_vault::share(v);
        transfer::public_transfer(oc, OWNER);
        clk.share_for_testing();
    };
    s.end();
}

#[test]
fun batch_three_revokes_one_tx() {
    // N=3 revoke across 3 coins on one cap in one tx, all succeed.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = build_three_coin_cap(&mut s);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let w1 = spend_vault::revoke<USDC>(&mut v, &oc, cid, s.ctx());
        let w2 = spend_vault::revoke<SUIT>(&mut v, &oc, cid, s.ctx());
        let w3 = spend_vault::revoke<DEEP>(&mut v, &oc, cid, s.ctx());
        assert!(w1 && w2 && w3); // all three present, all removed
        assert!(!spend_vault::contains<USDC>(&v, cid));
        assert!(!spend_vault::contains<SUIT>(&v, cid));
        assert!(!spend_vault::contains<DEEP>(&v, cid));
        // Three Revoked events in the one tx.
        let evs = event::events_by_type<spend_vault::Revoked>();
        assert_eq!(evs.length(), 3);
        ts::return_to_address(OWNER, oc);
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun batch_mixed_sequence_deposit_spend_one_tx() {
    // A mixed interleaving in ONE tx (deposit, then spend) composes: no
    // one-call-per-tx assumption.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = build_usdc_suit_cap(&mut s); // USDC=500, SUIT=300, both funded
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_address<SpenderCap>(&s, SPENDER);
        // deposit (permissionless), then spend USDC, all in one tx.
        spend_vault::deposit(&v, coin::mint_for_testing<USDC>(1_000, s.ctx()), s.ctx());
        let b = spend_vault::spend<USDC>(&mut v, &cap, 200, &clk, s.ctx());
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 300);
        destroy(b);
        ts::return_to_address(SPENDER, cap);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

// === SEQUENCING: the two sequential orderings ===

#[test]
fun sequence_spend_then_revoke_both_succeed() {
    // Spend sequenced BEFORE revoke -> spend succeeds (non-retroactive), then
    // revoke removes the entry. The deterministic "spend wins" ordering.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 10_000, 500, MAXU64);
    // tx1: spender draws 200.
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_address<SpenderCap>(&s, SPENDER);
        let b = spend_vault::spend<USDC>(&mut v, &cap, 200, &clk, s.ctx());
        assert_eq!(b.value(), 200);
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 300);
        destroy(b);
        ts::return_to_address(SPENDER, cap);
        u::return_vault(v);
        u::return_clock(clk);
    };
    // tx2: owner revokes; the prior spend stands, the entry is now gone.
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let was = spend_vault::revoke<USDC>(&mut v, &oc, cid, s.ctx());
        assert!(was);
        assert!(!spend_vault::contains<USDC>(&v, cid));
        ts::return_to_address(OWNER, oc);
        u::return_vault(v);
    };
    s.end();
}

#[test, expected_failure(abort_code = spend_vault::ENoAllowance)]
fun sequence_revoke_then_spend_aborts_no_allowance() {
    // Revoke sequenced BEFORE spend -> the entry is gone, spend aborts code 2.
    // The opposite ordering of the same race; deterministic.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 10_000, 500, MAXU64);
    // tx1: owner revokes first.
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let was = spend_vault::revoke<USDC>(&mut v, &oc, cid, s.ctx());
        assert!(was);
        ts::return_to_address(OWNER, oc);
        u::return_vault(v);
    };
    // tx2: the spender's spend now finds no entry -> ENoAllowance.
    s.next_tx(SPENDER);
    let mut v = u::take_vault(&s);
    let clk = u::take_clock(&s);
    let cap = ts::take_from_address<SpenderCap>(&s, SPENDER);
    let b = spend_vault::spend<USDC>(&mut v, &cap, 100, &clk, s.ctx()); // code 2
    destroy(b);
    abort
}

// === Helpers ===

/// One tx: a SECOND vault funded + granted USDC=500 to a fresh cap sent to SPENDER.
/// Returns (vault_id, cap_id). (The first vault came from setup_granted.)
fun make_second_vault(s: &mut ts::Scenario): (ID, ID) {
    s.next_tx(OWNER);
    let clk = u::clock_at(u::start_ms(), s.ctx());
    let (mut v, oc) = spend_vault::new(s.ctx());
    let vid = object::id(&v);
    spend_vault::deposit(&v, coin::mint_for_testing<USDC>(10_000, s.ctx()), s.ctx());
    let cap = spend_vault::mint_cap(&v, &oc, s.ctx());
    let cid = object::id(&cap);
    spend_vault::set_allowance<USDC>(&mut v, &oc, cid, 500, MAXU64, option::none(), &clk, s.ctx());
    transfer::public_transfer(cap, SPENDER);
    spend_vault::share(v);
    transfer::public_transfer(oc, OWNER);
    clk.share_for_testing();
    (vid, cid)
}

/// One tx: a vault funded with USDC=10_000, two caps X and Y each granted USDC=500,
/// both sent to SPENDER. Returns (vid, cid_x, cid_y).
fun two_cap_vault(s: &mut ts::Scenario): (ID, ID, ID) {
    let clk = u::clock_at(u::start_ms(), s.ctx());
    let (mut v, oc) = spend_vault::new(s.ctx());
    let vid = object::id(&v);
    spend_vault::deposit(&v, coin::mint_for_testing<USDC>(10_000, s.ctx()), s.ctx());
    let capx = spend_vault::mint_cap(&v, &oc, s.ctx());
    let cidx = object::id(&capx);
    let capy = spend_vault::mint_cap(&v, &oc, s.ctx());
    let cidy = object::id(&capy);
    spend_vault::set_allowance<USDC>(&mut v, &oc, cidx, 500, MAXU64, option::none(), &clk, s.ctx());
    spend_vault::set_allowance<USDC>(&mut v, &oc, cidy, 500, MAXU64, option::none(), &clk, s.ctx());
    transfer::public_transfer(capx, SPENDER);
    transfer::public_transfer(capy, SPENDER);
    spend_vault::share(v);
    transfer::public_transfer(oc, OWNER);
    clk.share_for_testing();
    (vid, cidx, cidy)
}

/// One tx: a vault funded USDC + SUIT, one cap granted USDC=500 and SUIT=300, sent to
/// SPENDER. Returns (vid, cid).
fun build_usdc_suit_cap(s: &mut ts::Scenario): (ID, ID) {
    let clk = u::clock_at(u::start_ms(), s.ctx());
    let (mut v, oc) = spend_vault::new(s.ctx());
    let vid = object::id(&v);
    spend_vault::deposit(&v, coin::mint_for_testing<USDC>(10_000, s.ctx()), s.ctx());
    spend_vault::deposit(&v, coin::mint_for_testing<SUIT>(10_000, s.ctx()), s.ctx());
    let cap = spend_vault::mint_cap(&v, &oc, s.ctx());
    let cid = object::id(&cap);
    spend_vault::set_allowance<USDC>(&mut v, &oc, cid, 500, MAXU64, option::none(), &clk, s.ctx());
    spend_vault::set_allowance<SUIT>(&mut v, &oc, cid, 300, MAXU64, option::none(), &clk, s.ctx());
    transfer::public_transfer(cap, SPENDER);
    spend_vault::share(v);
    transfer::public_transfer(oc, OWNER);
    clk.share_for_testing();
    (vid, cid)
}

/// One tx: a vault granting one cap USDC=100, SUIT=200, DEEP=300. Returns (vid, cid).
fun build_three_coin_cap(s: &mut ts::Scenario): (ID, ID) {
    let clk = u::clock_at(u::start_ms(), s.ctx());
    let (mut v, oc) = spend_vault::new(s.ctx());
    let vid = object::id(&v);
    let cap = spend_vault::mint_cap(&v, &oc, s.ctx());
    let cid = object::id(&cap);
    spend_vault::set_allowance<USDC>(&mut v, &oc, cid, 100, MAXU64, option::none(), &clk, s.ctx());
    spend_vault::set_allowance<SUIT>(&mut v, &oc, cid, 200, MAXU64, option::none(), &clk, s.ctx());
    spend_vault::set_allowance<DEEP>(&mut v, &oc, cid, 300, MAXU64, option::none(), &clk, s.ctx());
    transfer::public_transfer(cap, SPENDER);
    spend_vault::share(v);
    transfer::public_transfer(oc, OWNER);
    clk.share_for_testing();
    (vid, cid)
}

// withdraw<T>: partial owner exit, exact-value delivery as Balance<T>.
//
// Covers the partial-withdraw surface: Balance<T> return linearity, the owner
// gate (EWrongOwnerCap first), EZeroAmount on a partial withdraw, abort
// precedence by position (owner gate before zero-amount), exact partial
// delivery with no skim or retention, the consumable Balance<T> egress routing
// onward via deposit_balance, batching multiple withdraws in one tx, the owner
// exit consulting only the cap binding and pool (never the ledger, so no
// spender state can block it), and a single Withdrawn event emitted post-draw.
//
// withdraw_all (full drain) and the native pool-short aborts are not covered
// here: pool-balance effects need an AccumulatorRoot, which the unit-test
// VM cannot construct, so over-withdraw and withdraw-from-empty succeed; those
// are not exercised by this package's tests.
module openzeppelin_allowance::spend_vault_withdraw_tests;

use openzeppelin_allowance::spend_vault::{Self, OwnerCap};
use openzeppelin_allowance::sv_test_utils::{Self as u, USDC};
use std::type_name;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario as ts;

const OWNER: address = @0xA;
const SPENDER: address = @0xB;
const MAXU64: u64 = 18_446_744_073_709_551_615;

// === Happy path: exact value out + Withdrawn event ===

#[test]
fun withdraw_partial_delivers_exact_value_and_emits() {
    // withdraw<USDC>(300) from a 1000 pool returns exactly 300, no skim, and
    // emits exactly one Withdrawn carrying the actual amount.
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);

        let bal = spend_vault::withdraw<USDC>(&mut v, &oc, 300, s.ctx());
        assert_eq!(bal.value(), 300); // exact delivery

        let evs = event::events_by_type<spend_vault::Withdrawn>();
        assert_eq!(evs.length(), 1);
        assert_eq!(
            evs[0],
            spend_vault::test_new_withdrawn(vid, type_name::with_defining_ids<USDC>(), 300, OWNER),
        );

        destroy(bal);
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    s.end();
}

// === The Balance<T> egress is consumable and routes onward ===

#[test]
fun withdraw_output_routes_back_via_deposit_balance() {
    // The withdrawn Balance<T> folds straight back through deposit_balance (the
    // symmetric ingress), proving it is a real consumable linear value, not a
    // phantom.
    let mut s = ts::begin(OWNER);
    let _vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);

        let mut vmut = v;
        let bal = spend_vault::withdraw<USDC>(&mut vmut, &oc, 300, s.ctx());
        spend_vault::deposit_balance<USDC>(&vmut, bal, s.ctx()); // consumes the Balance

        ts::return_to_sender(&s, oc);
        u::return_vault(vmut);
    };
    s.end();
}

// === Multiple withdraws batch in one tx (never sole PTB step) ===

#[test]
fun withdraw_multiple_in_one_tx_succeed() {
    // The module assumes no sole-caller / sole-step; three withdraws in one tx
    // each deliver their exact amount and emit their own Withdrawn.
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);

        let b1 = spend_vault::withdraw<USDC>(&mut v, &oc, 100, s.ctx());
        let b2 = spend_vault::withdraw<USDC>(&mut v, &oc, 250, s.ctx());
        let b3 = spend_vault::withdraw<USDC>(&mut v, &oc, 50, s.ctx());
        assert_eq!(b1.value(), 100);
        assert_eq!(b2.value(), 250);
        assert_eq!(b3.value(), 50);

        // Three distinct Withdrawn events; check the last by value.
        let evs = event::events_by_type<spend_vault::Withdrawn>();
        assert_eq!(evs.length(), 3);
        assert_eq!(
            evs[2],
            spend_vault::test_new_withdrawn(vid, type_name::with_defining_ids<USDC>(), 50, OWNER),
        );

        destroy(b1);
        destroy(b2);
        destroy(b3);
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    s.end();
}

// === Owner exit consults only the cap binding, never the ledger ===

#[test]
fun withdraw_succeeds_with_maximal_adversarial_ledger() {
    // Build a vault carrying a live grant, a suspended grant, and an unlimited
    // grant across three caps; withdraw still succeeds (no ledger consult). No
    // spender state can block the owner exit. Non-root path only.
    let mut s = ts::begin(OWNER);
    let clk = u::clock_at(u::start_ms(), s.ctx());
    let (mut v, oc) = spend_vault::new(s.ctx());
    let vid = object::id(&v);
    spend_vault::deposit(&v, sui::coin::mint_for_testing<USDC>(1_000, s.ctx()), s.ctx());
    // cap A: a live finite grant.
    let cap_a = spend_vault::mint_cap(&v, &oc, s.ctx());
    let cid_a = object::id(&cap_a);
    spend_vault::set_allowance<USDC>(
        &mut v,
        &oc,
        cid_a,
        500,
        MAXU64,
        option::none(),
        &clk,
        s.ctx(),
    );
    // cap B: a suspended grant (remaining == 0).
    let cap_b = spend_vault::mint_cap(&v, &oc, s.ctx());
    let cid_b = object::id(&cap_b);
    spend_vault::set_allowance<USDC>(&mut v, &oc, cid_b, 0, MAXU64, option::none(), &clk, s.ctx());
    // cap C: an unlimited grant (remaining == u64::MAX sentinel).
    let cap_c = spend_vault::mint_cap(&v, &oc, s.ctx());
    let cid_c = object::id(&cap_c);
    spend_vault::set_allowance<USDC>(
        &mut v,
        &oc,
        cid_c,
        MAXU64,
        MAXU64,
        option::none(),
        &clk,
        s.ctx(),
    );
    transfer::public_transfer(cap_a, SPENDER);
    transfer::public_transfer(cap_b, SPENDER);
    transfer::public_transfer(cap_c, SPENDER);
    spend_vault::share(v);
    transfer::public_transfer(oc, OWNER);
    clk.share_for_testing();

    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        // Despite the live + suspended ledger entries across three caps, the owner
        // exits cleanly: withdraw never reads the ledger.
        let bal = spend_vault::withdraw<USDC>(&mut v, &oc, 800, s.ctx());
        assert_eq!(bal.value(), 800);
        let evs = event::events_by_type<spend_vault::Withdrawn>();
        assert_eq!(evs.length(), 1);
        assert_eq!(
            evs[0],
            spend_vault::test_new_withdrawn(vid, type_name::with_defining_ids<USDC>(), 800, OWNER),
        );
        destroy(bal);
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    s.end();
}

// === Aborts (exact codes) ===

#[test, expected_failure(abort_code = spend_vault::EZeroAmount)]
fun withdraw_zero_amount_aborts() {
    // Zero is meaningless on a partial withdraw.
    let mut s = ts::begin(OWNER);
    let _vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let _bal = spend_vault::withdraw<USDC>(&mut v, &oc, 0, s.ctx());
        abort
    }
}

#[test, expected_failure(abort_code = spend_vault::EWrongOwnerCap)]
fun withdraw_foreign_owner_cap_aborts() {
    // An OwnerCap bound to a different vault is rejected by the first check.
    let mut s = ts::begin(OWNER);
    let _vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    s.next_tx(OWNER);
    {
        let mut va = u::take_vault(&s);
        // a fresh, unrelated vault + its owner cap (the foreign cap)
        let (_vb, foreign_oc) = spend_vault::new(s.ctx());
        let _bal = spend_vault::withdraw<USDC>(&mut va, &foreign_oc, 100, s.ctx());
        abort
    }
}

// === Precedence (firing order is by position, not code magnitude) ===

#[test, expected_failure(abort_code = spend_vault::EWrongOwnerCap)]
fun precedence_wrong_owner_cap_beats_zero_amount() {
    // Foreign owner cap AND amount 0: the owner gate (position 1) beats the
    // zero-amount check (position 2).
    let mut s = ts::begin(OWNER);
    let _vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    s.next_tx(OWNER);
    {
        let mut va = u::take_vault(&s);
        let (_vb, foreign_oc) = spend_vault::new(s.ctx());
        // wrong vault AND zero amount -> owner gate wins
        let _bal = spend_vault::withdraw<USDC>(&mut va, &foreign_oc, 0, s.ctx());
        abort
    }
}

// === Helpers ===

/// One withdraw of `amount` in a fresh OWNER tx, asserting the delivered value.
fun withdraw_n(s: &mut ts::Scenario, amount: u64) {
    s.next_tx(OWNER);
    let mut v = u::take_vault(s);
    let oc = ts::take_from_sender<OwnerCap>(s);
    let bal = spend_vault::withdraw<USDC>(&mut v, &oc, amount, s.ctx());
    assert_eq!(bal.value(), amount);
    destroy(bal);
    ts::return_to_sender(s, oc);
    u::return_vault(v);
}

#[test]
fun withdraw_across_txs_each_delivers_exact() {
    // Repeated partial withdraws across txs each deliver exactly `amount` (the
    // unit VM lets each draw succeed regardless of pool).
    let mut s = ts::begin(OWNER);
    let _vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    withdraw_n(&mut s, 300);
    withdraw_n(&mut s, 400);
    withdraw_n(&mut s, 300);
    s.end();
}

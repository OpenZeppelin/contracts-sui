// Composability and ledger-shape coverage: atomic single-PTB lifecycle shapes,
// Balance<T> round-trips both ways, never-sole-caller PTB batching, single-tx
// deposit-then-spend, BudgetKey composite-key independence, and the two-caps-sum
// footgun at the cap level.
//
// Pool-balance effects need a live AccumulatorRoot, which the unit-test VM cannot
// construct; pool conservation and the same-PTB under-drain edge require a live
// network and are not exercised by this package's tests.
module openzeppelin_allowance::spend_vault_composability_tests;

use openzeppelin_allowance::spend_vault::{Self, Vault, OwnerCap, SpenderCap};
use openzeppelin_allowance::sv_test_utils::{Self as u, USDC, SUIT, DEEP};
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::coin;
use sui::test_scenario as ts;

const OWNER: address = @0xA;
const SPENDER: address = @0xB;
const MAXU64: u64 = 18_446_744_073_709_551_615;

// === The full create+fund+grant+share+handoff composes in one PTB ===

#[test]
fun atomic_lifecycle_multi_coin_one_ptb() {
    let mut s = ts::begin(OWNER);
    let (vid, cid) = {
        let clk = u::clock_at(u::start_ms(), s.ctx());
        let (mut v, oc) = spend_vault::new(s.ctx());
        let vid = object::id(&v);
        // fund two coins, mint one cap, grant two budgets, share, hand off -- all one tx
        spend_vault::deposit(&v, coin::mint_for_testing<USDC>(1_000, s.ctx()), s.ctx());
        spend_vault::deposit(&v, coin::mint_for_testing<SUIT>(2_000, s.ctx()), s.ctx());
        let cap = spend_vault::mint_cap(&v, &oc, s.ctx());
        let cid = object::id(&cap);
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
        spend_vault::set_allowance<SUIT>(
            &mut v,
            &oc,
            cid,
            700,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        spend_vault::share(v);
        transfer::public_transfer(oc, OWNER);
        transfer::public_transfer(cap, SPENDER);
        clk.share_for_testing();
        (vid, cid)
    };
    // both grants live after the one-PTB setup
    s.next_tx(SPENDER);
    {
        let v = u::take_vault(&s);
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 500);
        assert_eq!(spend_vault::allowance<SUIT>(&v, cid), 700);
        assert_eq!(spend_vault::granted_coin_types(&v).length(), 2);
        let _ = vid;
        u::return_vault(v);
    };
    s.end();
}

// === Deposit-then-spend in the SAME tx ===

#[test]
fun deposit_then_spend_same_tx() {
    // Grant 1_000 budget but only 100 pool; in one tx deposit 400 more then spend
    // 500. The redeem path reads the live accumulator, so the same-tx credit is
    // spendable. The unit VM does not gate the pool, so this asserts the ordering
    // composes, returning exactly amount.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 100, 1_000, MAXU64);
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        spend_vault::deposit(&v, coin::mint_for_testing<USDC>(400, s.ctx()), s.ctx());
        let bal = spend_vault::spend<USDC>(&mut v, &cap, 500, &clk, s.ctx());
        assert_eq!(bal.value(), 500);
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 500);
        destroy(bal);
        ts::return_to_sender(&s, cap);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

// === Balance<T> round-trips both ways ===

#[test]
fun spend_output_redeposited_same_vault() {
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        let bal = spend_vault::spend<USDC>(&mut v, &cap, 200, &clk, s.ctx());
        spend_vault::deposit_balance<USDC>(&v, bal, s.ctx()); // egress folds back in
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 300);
        ts::return_to_sender(&s, cap);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

#[test]
fun withdraw_output_routed_into_second_vault() {
    // OUT of vault A (withdraw -> Balance<T>) and straight IN to vault B
    // (deposit_balance), zero glue. Both ledger-side; pool conservation requires a live network and is not exercised here.
    let mut s = ts::begin(OWNER);
    let _a = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    s.next_tx(OWNER);
    let b_id = {
        let (vb, ocb) = spend_vault::new(s.ctx());
        let bid = object::id(&vb);
        spend_vault::share(vb);
        transfer::public_transfer(ocb, @0xC); // B's owner cap elsewhere so OWNER holds only A's
        bid
    };
    s.next_tx(OWNER);
    {
        // vault A is the first shared Vault; take both shared vaults distinctly
        let mut va = ts::take_shared_by_id<Vault>(&s, _a);
        let vb = ts::take_shared_by_id<Vault>(&s, b_id);
        let oca = u::take_owner_cap(&s, OWNER);
        let bal = spend_vault::withdraw<USDC>(&mut va, &oca, 300, s.ctx());
        spend_vault::deposit_balance<USDC>(&vb, bal, s.ctx());
        ts::return_to_address(OWNER, oca);
        ts::return_shared(va);
        ts::return_shared(vb);
    };
    s.end();
}

#[test]
fun deposit_balance_ingress_from_raw_balance() {
    // Ingress: a Balance<T> the integrator controls folds in via deposit_balance.
    let mut s = ts::begin(OWNER);
    let _vid = u::new_funded_vault<USDC>(&mut s, OWNER, 0);
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        let b = balance::create_for_testing<USDC>(750);
        spend_vault::deposit_balance<USDC>(&v, b, s.ctx());
        u::return_vault(v);
    };
    s.end();
}

// === BudgetKey composite key gives N independent entries ===

#[test]
fun one_cap_three_coins_three_independent_entries() {
    // Allowance is per-(cap,coin) and reads return scalars; the BudgetKey
    // {cap_id, coin_type} keys distinct entries: one cap holds three independent
    // Allowance values; touching one leaves the others bit-identical.
    let mut s = ts::begin(OWNER);
    let cid = {
        let clk = u::clock_at(u::start_ms(), s.ctx());
        let (mut v, oc) = spend_vault::new(s.ctx());
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
        spend_vault::share(v);
        transfer::public_transfer(oc, OWNER);
        transfer::public_transfer(cap, SPENDER);
        clk.share_for_testing();
        cid
    };
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        // three distinct keys -> three distinct values
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 100);
        assert_eq!(spend_vault::allowance<SUIT>(&v, cid), 200);
        assert_eq!(spend_vault::allowance<DEEP>(&v, cid), 300);
        // mutate only SUIT
        spend_vault::set_allowance<SUIT>(
            &mut v,
            &oc,
            cid,
            999,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 100); // untouched
        assert_eq!(spend_vault::allowance<SUIT>(&v, cid), 999); // changed
        assert_eq!(spend_vault::allowance<DEEP>(&v, cid), 300); // untouched
        ts::return_to_address(OWNER, oc);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

// === Two caps = two summing budgets (footgun lives at cap level) ===

#[test]
fun two_caps_same_coin_independent_summing_budgets() {
    let mut s = ts::begin(OWNER);
    let (cid1, cid2) = {
        let clk = u::clock_at(u::start_ms(), s.ctx());
        let (mut v, oc) = spend_vault::new(s.ctx());
        spend_vault::deposit(&v, coin::mint_for_testing<USDC>(10_000, s.ctx()), s.ctx());
        let cap1 = spend_vault::mint_cap(&v, &oc, s.ctx());
        let cap2 = spend_vault::mint_cap(&v, &oc, s.ctx());
        let cid1 = object::id(&cap1);
        let cid2 = object::id(&cap2);
        // two independent USDC budgets on one vault; they SUM from the pool's view
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid1,
            500,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid2,
            500,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        transfer::public_transfer(cap1, SPENDER);
        transfer::public_transfer(cap2, @0xC);
        spend_vault::share(v);
        transfer::public_transfer(oc, OWNER);
        clk.share_for_testing();
        (cid1, cid2)
    };
    // distinct cap_ids => distinct entries; drawing on one never touches the other
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        let b = spend_vault::spend<USDC>(&mut v, &cap, 400, &clk, s.ctx());
        assert_eq!(spend_vault::allowance<USDC>(&v, cid1), 100);
        assert_eq!(spend_vault::allowance<USDC>(&v, cid2), 500); // cap2 untouched
        destroy(b);
        ts::return_to_sender(&s, cap);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

// === Never-sole-caller: batched same-function calls in one tx ===

#[test]
fun batched_mint_caps_yield_distinct_ids() {
    let mut s = ts::begin(OWNER);
    let _vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let c1 = spend_vault::mint_cap(&v, &oc, s.ctx());
        let c2 = spend_vault::mint_cap(&v, &oc, s.ctx());
        let c3 = spend_vault::mint_cap(&v, &oc, s.ctx());
        let id1 = object::id(&c1);
        let id2 = object::id(&c2);
        let id3 = object::id(&c3);
        assert!(id1 != id2 && id2 != id3 && id1 != id3);
        spend_vault::delete_orphaned_cap(c1);
        spend_vault::delete_orphaned_cap(c2);
        spend_vault::delete_orphaned_cap(c3);
        ts::return_to_address(OWNER, oc);
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun batched_deposits_and_grants_one_tx() {
    let mut s = ts::begin(OWNER);
    let cid = {
        let clk = u::clock_at(u::start_ms(), s.ctx());
        let (mut v, oc) = spend_vault::new(s.ctx());
        // N deposits (mixed coins) + N grants across coins, one tx
        spend_vault::deposit(&v, coin::mint_for_testing<USDC>(100, s.ctx()), s.ctx());
        spend_vault::deposit(&v, coin::mint_for_testing<SUIT>(100, s.ctx()), s.ctx());
        spend_vault::deposit(&v, coin::mint_for_testing<DEEP>(100, s.ctx()), s.ctx());
        let cap = spend_vault::mint_cap(&v, &oc, s.ctx());
        let cid = object::id(&cap);
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            10,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        spend_vault::set_allowance<SUIT>(
            &mut v,
            &oc,
            cid,
            20,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        spend_vault::set_allowance<DEEP>(
            &mut v,
            &oc,
            cid,
            30,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        spend_vault::share(v);
        transfer::public_transfer(oc, OWNER);
        transfer::public_transfer(cap, SPENDER);
        clk.share_for_testing();
        cid
    };
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        assert_eq!(spend_vault::granted_coin_types(&v).length(), 3);
        assert_eq!(spend_vault::allowance<DEEP>(&v, cid), 30);
        u::return_vault(v);
    };
    s.end();
}

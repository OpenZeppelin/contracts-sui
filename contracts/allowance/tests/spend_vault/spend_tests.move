// spend<T>: the cap-gated, exact-amount-or-abort draw.
//
// Covers the unit-level surface of spend<T>: exact-amount delivery and exact
// ledger decrement, the u64::MAX unlimited sentinel (never decremented), expiry
// boundary and no-expiry sentinel, the per-(cap,coin) cumulative ceiling, the
// runtime coin-type gate, abort codes and their firing precedence, bearer-cap
// behavior, and cross-cap/cross-type isolation.
//
// Pool-balance effects (the native pool-short abort at `redeem_funds` and the
// atomic revert of the pre-decrement) need a live AccumulatorRoot, which the
// unit-test VM cannot construct; they are not exercised by this package's tests (they require a live network).
module openzeppelin_allowance::spend_vault_spend_tests;

use openzeppelin_allowance::spend_vault::{Self, SpenderCap};
use openzeppelin_allowance::sv_test_utils::{Self as u, USDC, SUIT, FOO};
use std::type_name;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario as ts;

const OWNER: address = @0xA;
const SPENDER: address = @0xB;
const THIEF: address = @0xBAD;
const MAXU64: u64 = 18_446_744_073_709_551_615;

// === Happy path: exact amount, exact decrement, Spent event ===

#[test]
fun spend_partial_delivers_exact_and_decrements() {
    let mut s = ts::begin(OWNER);
    let (vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);

        let bal = spend_vault::spend<USDC>(&mut v, &cap, 300, &clk, s.ctx());
        assert_eq!(bal.value(), 300); // exact amount out
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 200); // exact decrement

        // exactly one Spent with the post-call raw remaining.
        let evs = event::events_by_type<spend_vault::Spent>();
        assert_eq!(evs.length(), 1);
        assert_eq!(
            evs[0],
            spend_vault::test_new_spent(
                vid,
                cid,
                type_name::with_defining_ids<USDC>(),
                300,
                200,
                SPENDER,
            ),
        );

        destroy(bal);
        ts::return_to_sender(&s, cap);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

#[test]
fun spend_full_budget_to_zero_keeps_entry() {
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);

        let bal = spend_vault::spend<USDC>(&mut v, &cap, 500, &clk, s.ctx());
        assert_eq!(bal.value(), 500);
        // drained-to-zero entry STAYS (suspended, not removed).
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 0);
        assert!(spend_vault::contains<USDC>(&v, cid));

        destroy(bal);
        ts::return_to_sender(&s, cap);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

#[test]
fun spend_cumulative_draws_sum_to_budget() {
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 10_000, 500, MAXU64);
    // three draws summing to exactly the budget.
    spend_n(&mut s, cid, 200, 300);
    spend_n(&mut s, cid, 200, 100);
    spend_n(&mut s, cid, 100, 0);
    s.end();
}

#[test]
fun spend_deposit_then_spend_same_grant() {
    // a credit is spendable; here the deposit is in setup, the spend in the next
    // tx (cross-tx credit persists in the VM).
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 400, 1_000, MAXU64);
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        let bal = spend_vault::spend<USDC>(&mut v, &cap, 400, &clk, s.ctx());
        assert_eq!(bal.value(), 400);
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 600);
        destroy(bal);
        ts::return_to_sender(&s, cap);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

#[test]
fun spend_output_routes_back_via_deposit_balance() {
    // the Balance<T> egress folds straight back through deposit_balance.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        let bal = spend_vault::spend<USDC>(&mut v, &cap, 300, &clk, s.ctx());
        spend_vault::deposit_balance<USDC>(&v, bal, s.ctx()); // consumes the Balance
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 200);
        ts::return_to_sender(&s, cap);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

// === Sentinels (unlimited budget) ===

#[test]
fun spend_unlimited_never_decrements() {
    let mut s = ts::begin(OWNER);
    let (vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 10_000, MAXU64, MAXU64);
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);

        let b1 = spend_vault::spend<USDC>(&mut v, &cap, 4_000, &clk, s.ctx());
        let b2 = spend_vault::spend<USDC>(&mut v, &cap, 5_000, &clk, s.ctx());
        // remaining stays the sentinel; Spent.remaining reports u64::MAX.
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), MAXU64);
        let evs = event::events_by_type<spend_vault::Spent>();
        assert_eq!(
            evs[evs.length() - 1],
            spend_vault::test_new_spent(
                vid,
                cid,
                type_name::with_defining_ids<USDC>(),
                5_000,
                MAXU64,
                SPENDER,
            ),
        );

        destroy(b1);
        destroy(b2);
        ts::return_to_sender(&s, cap);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

#[test]
fun spend_near_sentinel_finite_decrements_normally() {
    // MAX-1 is an ordinary finite budget, NOT the sentinel.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 10, MAXU64 - 1, MAXU64);
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        let bal = spend_vault::spend<USDC>(&mut v, &cap, 1, &clk, s.ctx());
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), MAXU64 - 2);
        destroy(bal);
        ts::return_to_sender(&s, cap);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

// Given a no-expiry grant (expires_at_ms == u64::MAX) and the clock pushed to
// u64::MAX, the spend still succeeds: with clock == expiry the `clock < expiry`
// comparison is false, so success rides entirely on the `expires_at_ms ==
// u64::MAX` no-expiry sentinel short-circuit.
#[test]
fun spend_no_expiry_sentinel_succeeds_at_max_clock() {
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 10_000, 1_000, u::no_expiry());
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let mut clk = u::take_clock(&s);
        // clock == expiry == u64::MAX: `clock < expiry` is false, so success rides
        // entirely on the `expires_at_ms == u64::MAX` short-circuit.
        clk.set_for_testing(MAXU64);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        let b = spend_vault::spend<USDC>(&mut v, &cap, 1_000, &clk, s.ctx());
        assert_eq!(b.value(), 1_000);
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 0);
        destroy(b);
        ts::return_to_sender(&s, cap);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

// === Multi-coin one cap (per-coin independence) ===

#[test]
fun spend_two_coins_one_cap_independent() {
    let mut s = ts::begin(OWNER);
    // Build a cap with USDC=500 and SUIT=300 in one tx.
    let (vid, cid) = build_two_coin_cap(&mut s);
    let _ = vid;
    // spend USDC 200 -> USDC 300, SUIT untouched
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        let b = spend_vault::spend<USDC>(&mut v, &cap, 200, &clk, s.ctx());
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 300);
        assert_eq!(spend_vault::allowance<SUIT>(&v, cid), 300); // SUIT bit-identical
        destroy(b);
        // spend SUIT 100 -> SUIT 200, USDC unchanged
        let b2 = spend_vault::spend<SUIT>(&mut v, &cap, 100, &clk, s.ctx());
        assert_eq!(spend_vault::allowance<SUIT>(&v, cid), 200);
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 300);
        destroy(b2);
        ts::return_to_sender(&s, cap);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

// === Bearer cap + sender-independence ===

#[test]
fun spend_works_for_new_holder_after_transfer() {
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    // SPENDER leaks the cap to THIEF.
    s.next_tx(SPENDER);
    {
        let cap = ts::take_from_sender<SpenderCap>(&s);
        transfer::public_transfer(cap, THIEF);
    };
    // THIEF (an unrelated sender) spends identically: cap-gated, never sender-gated.
    s.next_tx(THIEF);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        let b = spend_vault::spend<USDC>(&mut v, &cap, 500, &clk, s.ctx());
        assert_eq!(b.value(), 500);
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 0);
        destroy(b);
        ts::return_to_sender(&s, cap);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

// Given one cap budgeted for USDC+SUIT leaked to an unrelated holder, when the
// holder spends each coin it drains BOTH: the bearer blast radius is the sum of
// the cap's per-coin budgets, with no holder-identity check (cap-gated, never
// sender-gated).
#[test]
fun spend_leaked_cap_drains_both_coins() {
    let mut s = ts::begin(OWNER);
    let (vid, cid) = build_two_coin_cap(&mut s); // USDC=500, SUIT=300 at SPENDER
    let _ = vid;
    // SPENDER leaks the cap to THIEF.
    s.next_tx(SPENDER);
    {
        let cap = ts::take_from_sender<SpenderCap>(&s);
        transfer::public_transfer(cap, THIEF);
    };
    // THIEF drains BOTH coins through the one leaked cap.
    s.next_tx(THIEF);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        let bu = spend_vault::spend<USDC>(&mut v, &cap, 500, &clk, s.ctx());
        let bs = spend_vault::spend<SUIT>(&mut v, &cap, 300, &clk, s.ctx());
        assert_eq!(bu.value(), 500);
        assert_eq!(bs.value(), 300);
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 0);
        assert_eq!(spend_vault::allowance<SUIT>(&v, cid), 0);
        destroy(bu);
        destroy(bs);
        ts::return_to_sender(&s, cap);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

// === Aborts (exact codes) ===

#[test, expected_failure(abort_code = spend_vault::EWrongVault)]
fun spend_wrong_vault_cap_aborts() {
    let mut s = ts::begin(OWNER);
    let (_vid, _cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(SPENDER);
    {
        let mut va = u::take_vault(&s);
        let clk = u::take_clock(&s);
        // a cap bound to a DIFFERENT vault
        let (vb, ocb) = spend_vault::new(s.ctx());
        let foreign = spend_vault::mint_cap(&vb, &ocb, s.ctx());
        let _b = spend_vault::spend<USDC>(&mut va, &foreign, 100, &clk, s.ctx()); // EWrongVault
        abort
    }
}

#[test, expected_failure(abort_code = spend_vault::ENoAllowance)]
fun spend_never_granted_coin_aborts_no_allowance() {
    // cap budgeted for USDC only; spend<FOO> -> ENoAllowance.
    let mut s = ts::begin(OWNER);
    let (_vid, _cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        let _b = spend_vault::spend<FOO>(&mut v, &cap, 100, &clk, s.ctx()); // code 2
        abort
    }
}

#[test, expected_failure(abort_code = spend_vault::EAllowanceExpired)]
fun spend_at_exact_expiry_ms_aborts() {
    // closed boundary: a spend in the exact ms of expiry fails.
    let mut s = ts::begin(OWNER);
    let exp = u::start_ms() + 1_000;
    let (_vid, _cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, exp);
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let mut clk = u::take_clock(&s);
        clk.set_for_testing(exp); // now == expires_at_ms
        let cap = ts::take_from_sender<SpenderCap>(&s);
        let _b = spend_vault::spend<USDC>(&mut v, &cap, 100, &clk, s.ctx()); // code 3
        abort
    }
}

#[test]
fun spend_one_ms_before_expiry_succeeds() {
    let mut s = ts::begin(OWNER);
    let exp = u::start_ms() + 1_000;
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, exp);
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let mut clk = u::take_clock(&s);
        clk.set_for_testing(exp - 1);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        let b = spend_vault::spend<USDC>(&mut v, &cap, 100, &clk, s.ctx());
        assert_eq!(b.value(), 100);
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 400);
        destroy(b);
        ts::return_to_sender(&s, cap);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

#[test, expected_failure(abort_code = spend_vault::EZeroAmount)]
fun spend_zero_amount_aborts() {
    let mut s = ts::begin(OWNER);
    let (_vid, _cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        let _b = spend_vault::spend<USDC>(&mut v, &cap, 0, &clk, s.ctx()); // code 5
        abort
    }
}

#[test, expected_failure(abort_code = spend_vault::EAllowanceExceeded)]
fun spend_over_budget_aborts() {
    let mut s = ts::begin(OWNER);
    let (_vid, _cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 10_000, 500, MAXU64);
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        let _b = spend_vault::spend<USDC>(&mut v, &cap, 501, &clk, s.ctx()); // code 4
        abort
    }
}

#[test, expected_failure(abort_code = spend_vault::EAllowanceExceeded)]
fun spend_suspended_at_zero_aborts_exceeded_not_no_allowance() {
    // a suspended (remaining==0) entry is code 4, NOT code 2.
    let mut s = ts::begin(OWNER);
    let (_vid, _cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 0, MAXU64);
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        let _b = spend_vault::spend<USDC>(&mut v, &cap, 1, &clk, s.ctx()); // code 4
        abort
    }
}

// === Precedence pairs (firing order is by POSITION, not code magnitude) ===

#[test, expected_failure(abort_code = spend_vault::EWrongVault)]
fun precedence_wrong_vault_beats_zero_amount() {
    let mut s = ts::begin(OWNER);
    let (_vid, _cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(SPENDER);
    {
        let mut va = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let (vb, ocb) = spend_vault::new(s.ctx());
        let foreign = spend_vault::mint_cap(&vb, &ocb, s.ctx());
        // wrong vault AND zero amount -> code 1 wins (pos 1)
        let _b = spend_vault::spend<USDC>(&mut va, &foreign, 0, &clk, s.ctx());
        abort
    }
}

#[test, expected_failure(abort_code = spend_vault::ENoAllowance)]
fun precedence_no_allowance_beats_zero_amount() {
    let mut s = ts::begin(OWNER);
    let (_vid, _cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        // wrong coin (no entry) AND zero amount -> code 2 (pos 2) wins
        let _b = spend_vault::spend<FOO>(&mut v, &cap, 0, &clk, s.ctx());
        abort
    }
}

#[test, expected_failure(abort_code = spend_vault::EAllowanceExpired)]
fun precedence_expired_beats_exceeded() {
    let mut s = ts::begin(OWNER);
    let exp = u::start_ms() + 1_000;
    let (_vid, _cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 10_000, 500, exp);
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let mut clk = u::take_clock(&s);
        clk.set_for_testing(exp + 5); // expired
        let cap = ts::take_from_sender<SpenderCap>(&s);
        // expired AND over-budget -> code 3 (pos 3) beats code 4 (pos 5)
        let _b = spend_vault::spend<USDC>(&mut v, &cap, 9_999, &clk, s.ctx());
        abort
    }
}

#[test, expected_failure(abort_code = spend_vault::EAllowanceExpired)]
fun precedence_expired_beats_zero_amount() {
    // expiry (pos 3) fires before zero-amount (pos 4): a spend of 0 on an expired
    // grant aborts EAllowanceExpired, NOT EZeroAmount.
    let mut s = ts::begin(OWNER);
    let exp = u::start_ms() + 1_000;
    let (_vid, _cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, exp);
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let mut clk = u::take_clock(&s);
        clk.set_for_testing(exp + 5); // expired
        let cap = ts::take_from_sender<SpenderCap>(&s);
        // expired AND zero amount -> code 3 (pos 3) beats EZeroAmount (pos 4)
        let _b = spend_vault::spend<USDC>(&mut v, &cap, 0, &clk, s.ctx());
        abort
    }
}

#[test, expected_failure(abort_code = spend_vault::EZeroAmount)]
fun precedence_zero_beats_exceeded() {
    // amount 0 (pos 4) fires before over-budget (pos 5), even though code 5 > code 4.
    let mut s = ts::begin(OWNER);
    let (_vid, _cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 0, MAXU64); // suspended
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        let _b = spend_vault::spend<USDC>(&mut v, &cap, 0, &clk, s.ctx()); // code 5, not 4
        abort
    }
}

// === Helpers ===

/// One spend of `amount` in a fresh SPENDER tx, asserting the post-call remaining.
fun spend_n(s: &mut ts::Scenario, cid: ID, amount: u64, expect_remaining: u64) {
    s.next_tx(SPENDER);
    let mut v = u::take_vault(s);
    let clk = u::take_clock(s);
    let cap = ts::take_from_sender<SpenderCap>(s);
    let b = spend_vault::spend<USDC>(&mut v, &cap, amount, &clk, s.ctx());
    assert_eq!(b.value(), amount);
    assert_eq!(spend_vault::allowance<USDC>(&v, cid), expect_remaining);
    destroy(b);
    ts::return_to_sender(s, cap);
    u::return_vault(v);
    u::return_clock(clk);
}

/// One tx: vault funded with USDC + SUIT, a cap granted both. Returns (vid, cid).
fun build_two_coin_cap(s: &mut ts::Scenario): (ID, ID) {
    let clk = u::clock_at(u::start_ms(), s.ctx());
    let (mut v, oc) = spend_vault::new(s.ctx());
    let vid = object::id(&v);
    spend_vault::deposit(&v, sui::coin::mint_for_testing<USDC>(10_000, s.ctx()), s.ctx());
    spend_vault::deposit(&v, sui::coin::mint_for_testing<SUIT>(10_000, s.ctx()), s.ctx());
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

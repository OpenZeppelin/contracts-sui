// Purchase-path tests for `prefunded_sale`.
//
// Covers the happy purchase (state mutation + receipt delivery, which is the
// quote+purchase single-PTB compose), the window gate, the hard-cap
// and per-buyer/per-entry caps, and the symmetric allowlist coupling
// with its single-PTB entry consume. The inventory-bound failure
// (EInsufficientInventory) is only reachable via a dishonest curve and
// lives in `prefunded_sale_curve_trust_tests`.
module openzeppelin_sale::prefunded_sale_purchase_tests;

use openzeppelin_finance::vesting_wallet_linear::{Linear, Params as VParams};
use openzeppelin_sale::allowlist::{Self, AllowlistAdmin};
use openzeppelin_sale::fixed_rate_curve::{Self, FixedRateCurve, Params as FrcParams};
use openzeppelin_sale::prefunded_sale::{Self, PrefundedSale};
use openzeppelin_sale::receipt::Receipt;
use openzeppelin_sale::refund_vault;
use openzeppelin_sale::test_utils::{Self as u, SALE, USDC};
use std::unit_test::{assert_eq, destroy};
use sui::clock::Clock;
use sui::event;
use sui::test_scenario::{Self as ts, Scenario};

// === Test-Only Helpers ===

// Build an Active sale with a per-buyer cap (rate 1, hard_cap 1_000, no soft
// cap, inventory 1_000). Leaves sale + vault shared, cap with ADMIN.
fun setup_with_per_buyer_cap(test: &mut Scenario, clk: &Clock, per_buyer: u64) {
    let ctx = test.ctx();
    let (mut sale, cap) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(
        fixed_rate_curve::params(1, 1),
        1_000,
        0,
        u::opens(),
        u::closes(),
        ctx,
    );
    sale.deposit(u::sale_balance(1_000));
    sale.set_per_buyer_cap(per_buyer, ctx);
    let (vault, vault_cap) = refund_vault::new<USDC>(ctx);
    sale.pair_refund_vault(&vault, vault_cap);
    let ticket = fixed_rate_curve::activation_ticket(&sale);
    sale.share_and_activate(vault, ticket, clk);
    transfer::public_transfer(cap, u::admin());
}

// Purchase `paid` via an allowlist entry minted for `buyer` with `max_amount`.
// Must run in a tx whose sender is `buyer`.
fun buy_with_entry(
    sale: &mut PrefundedSale<FixedRateCurve, FrcParams, SALE, USDC, Linear, VParams>,
    test: &mut Scenario,
    buyer: address,
    max_amount: u64,
    paid: u64,
    clk: &Clock,
) {
    let admin = test.take_from_address<AllowlistAdmin<SALE>>(u::admin());
    let entry = admin.new_entry(buyer, max_amount);
    let quote = fixed_rate_curve::quote(sale, u::pay_balance(paid));
    sale.purchase(quote, option::some(entry), clk, test.ctx());
    ts::return_to_address(u::admin(), admin);
}

// === Happy path ===

#[test]
fun purchase_delivers_receipt_and_updates_state() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 2, 1_000, 0, 2_000);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    let sale_id = object::id(&sale);
    u::buy(&mut sale, 100, &clk, test.ctx());
    assert_eq!(sale.raised(), 100);
    assert_eq!(sale.total_allocated(), 200); // rate 2
    assert_eq!(sale.proceeds_amount(), 100);
    assert_eq!(sale.inventory_remaining(), 1_800);
    // Purchased is emitted once for the buy. The receipt is delivered inside this tx (not
    // takeable until the next tx) and events do not survive a tx boundary, so read the
    // event's receipt_id here, assert the full payload against it, then cross-check that id
    // against the delivered receipt in the next tx.
    let purchased = event::events_by_type<prefunded_sale::Purchased<SALE, USDC>>();
    assert_eq!(purchased.length(), 1);
    let receipt_id = purchased[0].test_purchased_receipt_id();
    assert_eq!(
        purchased[0],
        prefunded_sale::test_new_purchased<SALE, USDC>(
            sale_id,
            u::buyer(),
            receipt_id,
            100, // paid
            200, // allocation (rate 2)
            100, // raised_after
            u::opens(), // purchased_at_ms
        ),
    );
    u::return_sale(sale);

    // Receipt landed with the buyer carrying the right data, and its id is the one the
    // event reported.
    test.next_tx(u::buyer());
    let r = test.take_from_address<Receipt<SALE>>(u::buyer());
    assert_eq!(object::id(&r), receipt_id);
    assert_eq!(r.buyer(), u::buyer());
    assert_eq!(r.paid(), 100);
    assert_eq!(r.allocation(), 200);
    destroy(r);

    destroy(clk);
    test.end();
}

// Boundary: a purchase that brings raised exactly to hard_cap succeeds.
#[test]
fun purchase_at_exact_hard_cap_ok() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    u::buy(&mut sale, 1_000, &clk, test.ctx());
    assert_eq!(sale.raised(), 1_000);
    assert!(sale.has_reached_hard_cap());
    assert_eq!(sale.inventory_remaining(), 0);
    u::return_sale(sale);

    destroy(clk);
    test.end();
}

// === Phase gate ===

// purchase requires Active: it aborts once the sale has been finalized (the
// phase guard sits ahead of the window check).
#[test, expected_failure(abort_code = prefunded_sale::ENotActive)]
fun purchase_after_finalize_aborts() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    clk.set_for_testing(5_001);

    test.next_tx(u::admin());
    {
        let mut sale = u::take_sale(&test);
        let mut vault = u::take_vault(&test);
        sale.finalize(&mut vault, &clk);
        u::return_sale(sale);
        u::return_vault(vault);
    };

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    u::buy(&mut sale, 100, &clk, test.ctx()); // aborts: ENotActive
    abort
}

// === Window gate ===

// A purchase before opens_at_ms is rejected.
#[test, expected_failure(abort_code = prefunded_sale::ESaleWindowClosed)]
fun purchase_before_open_aborts() {
    let (mut test, clk) = u::setup(); // clk parked at opens() = 1_000
    // Window [2_000, 5_000]: activation at 1_000 is allowed (pre-open), but a
    // purchase at 1_000 is before the window.
    u::create_and_activate_full(&mut test, &clk, 1, 1_000, 0, 2_000, 5_000, 1_000, false);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    u::buy(&mut sale, 10, &clk, test.ctx()); // aborts: ESaleWindowClosed
    abort
}

// A purchase after closes_at_ms is rejected.
#[test, expected_failure(abort_code = prefunded_sale::ESaleWindowClosed)]
fun purchase_after_close_aborts() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    clk.set_for_testing(5_001); // past closes_at_ms

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    u::buy(&mut sale, 10, &clk, test.ctx()); // aborts
    abort
}

// Boundary: a purchase at exactly closes_at_ms succeeds. The window is inclusive
// on the upper edge (now <= closes_at_ms), unlike finalize/cancel_after_close
// which are strict (now > closes_at_ms). Guards that off-by-one.
#[test]
fun purchase_at_exact_close_ok() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    clk.set_for_testing(u::closes()); // now == closes_at_ms

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    u::buy(&mut sale, 10, &clk, test.ctx());
    assert_eq!(sale.raised(), 10);
    u::return_sale(sale);
    destroy(clk);
    test.end();
}

// === Hard cap ===

#[test, expected_failure(abort_code = prefunded_sale::EHardCapExceeded)]
fun purchase_exceeds_hard_cap_aborts() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    u::buy(&mut sale, 1_001, &clk, test.ctx()); // aborts
    abort
}

// === Per-buyer cap ===

// Cumulative payments within the cap across multiple purchases succeed.
#[test]
fun per_buyer_cap_allows_up_to_cap() {
    let (mut test, clk) = u::setup();
    setup_with_per_buyer_cap(&mut test, &clk, 100);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    u::buy(&mut sale, 60, &clk, test.ctx());
    u::buy(&mut sale, 40, &clk, test.ctx()); // cumulative 100 == cap
    assert_eq!(sale.raised(), 100);
    u::return_sale(sale);

    destroy(clk);
    test.end();
}

// A purchase pushing cumulative payment over the cap is rejected.
#[test, expected_failure(abort_code = prefunded_sale::EPerBuyerCapExceeded)]
fun per_buyer_cap_exceeded_aborts() {
    let (mut test, clk) = u::setup();
    setup_with_per_buyer_cap(&mut test, &clk, 100);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    u::buy(&mut sale, 100, &clk, test.ctx());
    u::buy(&mut sale, 1, &clk, test.ctx()); // aborts: over cap
    abort
}

// === Allowlist coupling ===

// Happy: an allowlist sale accepts a purchase carrying a valid entry.
#[test]
fun allowlist_purchase_with_entry_succeeds() {
    let (mut test, clk) = u::setup();
    u::create_and_activate_full(
        &mut test,
        &clk,
        1,
        1_000,
        0,
        u::opens(),
        u::closes(),
        1_000,
        true,
    );

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    buy_with_entry(&mut sale, &mut test, u::buyer(), 0, 100, &clk); // max 0 = no per-entry cap
    assert_eq!(sale.raised(), 100);
    u::return_sale(sale);

    destroy(clk);
    test.end();
}

// An allowlist sale rejects a purchase with no entry.
#[test, expected_failure(abort_code = prefunded_sale::EAllowlistRequired)]
fun allowlist_required_but_none_aborts() {
    let (mut test, clk) = u::setup();
    u::create_and_activate_full(
        &mut test,
        &clk,
        1,
        1_000,
        0,
        u::opens(),
        u::closes(),
        1_000,
        true,
    );

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    u::buy(&mut sale, 100, &clk, test.ctx()); // aborts: no entry
    abort
}

// A non-allowlist sale rejects a purchase that carries an entry.
#[test, expected_failure(abort_code = prefunded_sale::EAllowlistNotRequired)]
fun allowlist_not_required_but_provided_aborts() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    // Craft an admin + entry for this sale (no allowlist enabled on it).
    let admin = allowlist::new_admin<SALE>(object::id(&sale), test.ctx());
    let entry = admin.new_entry(u::buyer(), 0);
    let quote = fixed_rate_curve::quote(&sale, u::pay_balance(100));
    sale.purchase(quote, option::some(entry), &clk, test.ctx()); // aborts
    abort
}

// The per-entry cap (max_amount) bounds a single purchase.
#[test, expected_failure(abort_code = prefunded_sale::EPerEntryCapExceeded)]
fun per_entry_cap_exceeded_aborts() {
    let (mut test, clk) = u::setup();
    u::create_and_activate_full(
        &mut test,
        &clk,
        1,
        1_000,
        0,
        u::opens(),
        u::closes(),
        1_000,
        true,
    );

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    buy_with_entry(&mut sale, &mut test, u::buyer(), 50, 51, &clk); // 51 > max 50
    abort
}

// Boundary: paying exactly the entry's max_amount is allowed (the guard is paid <= max).
#[test]
fun per_entry_cap_exact_boundary_ok() {
    let (mut test, clk) = u::setup();
    u::create_and_activate_full(
        &mut test,
        &clk,
        1,
        1_000,
        0,
        u::opens(),
        u::closes(),
        1_000,
        true,
    );

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    buy_with_entry(&mut sale, &mut test, u::buyer(), 50, 50, &clk); // paid == max 50
    assert_eq!(sale.raised(), 50);
    u::return_sale(sale);

    destroy(clk);
    test.end();
}

// A quote minted for a different sale is rejected - the quote-side analogue of the
// activation-ticket sale-id check.
#[test, expected_failure(abort_code = prefunded_sale::EQuoteSaleMismatch)]
fun purchase_with_foreign_quote_aborts() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000); // sale A (shared)

    test.next_tx(u::buyer());
    let mut sale_a = u::take_sale(&test);
    // Sale B - same type, never activated; its quote pins B's id, not A's.
    let (sale_b, _cap_b) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(
        fixed_rate_curve::params(1, 1),
        1_000,
        0,
        u::opens(),
        u::closes(),
        test.ctx(),
    );
    let foreign_quote = fixed_rate_curve::quote(&sale_b, u::pay_balance(10));
    sale_a.purchase(foreign_quote, option::none(), &clk, test.ctx()); // aborts: EQuoteSaleMismatch
    abort
}

// === Views ===

// is_open reflects the purchase window while Active: false before opens_at_ms,
// true within [opens_at_ms, closes_at_ms] (inclusive on both edges), false past close.
#[test]
fun is_open_reflects_window() {
    let (mut test, mut clk) = u::setup(); // clk parked at 1_000
    // Window [2_000, 5_000]: activation at 1_000 is pre-open and allowed.
    u::create_and_activate_full(&mut test, &clk, 1, 1_000, 0, 2_000, 5_000, 1_000, false);

    test.next_tx(u::buyer());
    let sale = u::take_sale(&test);
    assert!(!sale.is_open(&clk)); // now 1_000 < opens 2_000
    clk.set_for_testing(3_000);
    assert!(sale.is_open(&clk)); // within window
    clk.set_for_testing(5_000);
    assert!(sale.is_open(&clk)); // inclusive upper edge
    clk.set_for_testing(5_001);
    assert!(!sale.is_open(&clk)); // past close
    u::return_sale(sale);

    destroy(clk);
    test.end();
}

// is_open is false once the sale leaves Active, even while the clock is still
// inside the purchase window. Hitting the hard cap lets finalize close the sale
// early (now <= closes_at_ms), so the clock stays in-window and only the phase
// change flips is_open.
#[test]
fun is_open_false_when_not_active() {
    let (mut test, clk) = u::setup(); // clk parked at opens() = 1_000, in window
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);

    test.next_tx(u::buyer());
    {
        let mut sale = u::take_sale(&test);
        u::buy(&mut sale, 1_000, &clk, test.ctx()); // raised == hard_cap
        u::return_sale(sale);
    };

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let mut vault = u::take_vault(&test);
    assert!(sale.is_open(&clk)); // still Active, in-window
    sale.finalize(&mut vault, &clk); // early close on hard cap, clock still in-window
    assert!(!sale.is_open(&clk)); // Finalized dominates the in-window clock
    u::return_sale(sale);
    u::return_vault(vault);

    destroy(clk);
    test.end();
}

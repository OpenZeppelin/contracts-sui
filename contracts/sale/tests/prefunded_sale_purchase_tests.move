// Purchase-path tests for `prefunded_sale` (INV-13, INV-15, INV-21, INV-22,
// INV-30, INV-31).
//
// Covers the happy purchase (state mutation + receipt delivery, which is the
// quote+purchase single-PTB compose of INV-30), the window gate, the hard-cap
// and per-buyer/per-entry caps, and the symmetric allowlist coupling (INV-15)
// with its single-PTB entry consume (INV-31). The inventory-bound failure
// (INV-21 / EInsufficientInventory) is only reachable via a dishonest curve and
// lives in `prefunded_sale_curve_trust_tests`.
module openzeppelin_sale::prefunded_sale_purchase_tests;

use openzeppelin_finance::vesting_wallet_linear::Params as VParams;
use openzeppelin_sale::allowlist::{Self, AllowlistAdmin};
use openzeppelin_sale::fixed_rate_curve::{Self, FixedRateCurve, Params as FrcParams};
use openzeppelin_sale::prefunded_sale::{Self, PrefundedSale};
use openzeppelin_sale::receipt::Receipt;
use openzeppelin_sale::refund_vault;
use openzeppelin_sale::test_utils::{Self as tu, SALE, USDC};
use std::unit_test::{assert_eq, destroy};
use sui::clock::Clock;
use sui::test_scenario::{Self as ts, Scenario};

// === Test-Only Helpers ===

// Build an Active sale with a per-buyer cap (rate 1, hard_cap 1_000, no soft
// cap, inventory 1_000). Leaves sale + vault shared, cap with ADMIN.
fun setup_with_per_buyer_cap(test: &mut Scenario, clk: &Clock, per_buyer: u64) {
    let ctx = test.ctx();
    let (mut sale, cap) = prefunded_sale::create_sale<FixedRateCurve, FrcParams, SALE, USDC, VParams>(
        fixed_rate_curve::params(1),
        1_000,
        0,
        tu::opens(),
        tu::closes(),
        ctx,
    );
    sale.deposit(tu::sale_balance(1_000));
    sale.set_per_buyer_cap(per_buyer, ctx);
    let (vault, vault_cap) = refund_vault::new<USDC>(ctx);
    sale.pair_refund_vault(&vault, vault_cap);
    let ticket = fixed_rate_curve::activation_ticket(&sale);
    sale.share_and_activate(ticket, clk);
    refund_vault::share(vault);
    transfer::public_transfer(cap, tu::admin());
}

// Purchase `paid` via an allowlist entry minted for `buyer` with `max_amount`.
// Must run in a tx whose sender is `buyer`.
fun buy_with_entry(
    sale: &mut PrefundedSale<FixedRateCurve, FrcParams, SALE, USDC, VParams>,
    test: &mut Scenario,
    buyer: address,
    max_amount: u64,
    paid: u64,
    clk: &Clock,
) {
    let admin = test.take_from_address<AllowlistAdmin<SALE>>(tu::admin());
    let entry = admin.new_entry(buyer, max_amount);
    let quote = fixed_rate_curve::quote(sale, tu::pay_balance(paid));
    sale.purchase(quote, option::some(entry), clk, test.ctx());
    ts::return_to_address(tu::admin(), admin);
}

// === Happy path (INV-13, INV-21, INV-22, INV-30) ===

#[test]
fun purchase_delivers_receipt_and_updates_state() {
    let (mut test, clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 2, 1_000, 0, 2_000);

    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(&test);
    tu::buy(&mut sale, 100, &clk, test.ctx());
    assert_eq!(sale.raised(), 100);
    assert_eq!(sale.total_allocated(), 200); // rate 2
    assert_eq!(sale.proceeds_amount(), 100);
    assert_eq!(sale.inventory_remaining(), 1_800);
    tu::return_sale(sale);

    // Receipt landed with the buyer carrying the right data.
    test.next_tx(tu::buyer());
    let r = test.take_from_address<Receipt<SALE>>(tu::buyer());
    assert_eq!(r.buyer(), tu::buyer());
    assert_eq!(r.paid(), 100);
    assert_eq!(r.allocation(), 200);
    destroy(r);

    destroy(clk);
    test.end();
}

// Boundary: a purchase that brings raised exactly to hard_cap succeeds.
#[test]
fun purchase_at_exact_hard_cap_ok() {
    let (mut test, clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);

    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(&test);
    tu::buy(&mut sale, 1_000, &clk, test.ctx());
    assert_eq!(sale.raised(), 1_000);
    assert_eq!(sale.has_reached_hard_cap(), true);
    assert_eq!(sale.inventory_remaining(), 0);
    tu::return_sale(sale);

    destroy(clk);
    test.end();
}

// === Window gate (INV-13) ===

// A purchase before opens_at_ms is rejected.
#[test, expected_failure(abort_code = prefunded_sale::ESaleWindowClosed)]
fun purchase_before_open_aborts() {
    let (mut test, clk) = tu::setup(); // clk parked at opens() = 1_000
    // Window [2_000, 5_000]: activation at 1_000 is allowed (pre-open), but a
    // purchase at 1_000 is before the window.
    tu::create_and_activate_full(&mut test, &clk, 1, 1_000, 0, 2_000, 5_000, 1_000, false);

    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(&test);
    tu::buy(&mut sale, 10, &clk, test.ctx()); // aborts: ESaleWindowClosed
    tu::return_sale(sale);
    destroy(clk);
    test.end();
}

// A purchase after closes_at_ms is rejected.
#[test, expected_failure(abort_code = prefunded_sale::ESaleWindowClosed)]
fun purchase_after_close_aborts() {
    let (mut test, mut clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    clk.set_for_testing(5_001); // past closes_at_ms

    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(&test);
    tu::buy(&mut sale, 10, &clk, test.ctx()); // aborts
    tu::return_sale(sale);
    destroy(clk);
    test.end();
}

// === Hard cap (INV-13, INV-22) ===

#[test, expected_failure(abort_code = prefunded_sale::EHardCapExceeded)]
fun purchase_exceeds_hard_cap_aborts() {
    let (mut test, clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);

    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(&test);
    tu::buy(&mut sale, 1_001, &clk, test.ctx()); // aborts
    tu::return_sale(sale);
    destroy(clk);
    test.end();
}

// === Per-buyer cap (INV-13) ===

// Cumulative payments within the cap across multiple purchases succeed.
#[test]
fun per_buyer_cap_allows_up_to_cap() {
    let (mut test, clk) = tu::setup();
    setup_with_per_buyer_cap(&mut test, &clk, 100);

    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(&test);
    tu::buy(&mut sale, 60, &clk, test.ctx());
    tu::buy(&mut sale, 40, &clk, test.ctx()); // cumulative 100 == cap
    assert_eq!(sale.raised(), 100);
    tu::return_sale(sale);

    destroy(clk);
    test.end();
}

// A purchase pushing cumulative payment over the cap is rejected.
#[test, expected_failure(abort_code = prefunded_sale::EPerBuyerCapExceeded)]
fun per_buyer_cap_exceeded_aborts() {
    let (mut test, clk) = tu::setup();
    setup_with_per_buyer_cap(&mut test, &clk, 100);

    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(&test);
    tu::buy(&mut sale, 100, &clk, test.ctx());
    tu::buy(&mut sale, 1, &clk, test.ctx()); // aborts: over cap
    tu::return_sale(sale);
    destroy(clk);
    test.end();
}

// === Allowlist coupling (INV-15, INV-31) ===

// Happy: an allowlist sale accepts a purchase carrying a valid entry.
#[test]
fun allowlist_purchase_with_entry_succeeds() {
    let (mut test, clk) = tu::setup();
    tu::create_and_activate_full(&mut test, &clk, 1, 1_000, 0, tu::opens(), tu::closes(), 1_000, true);

    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(&test);
    buy_with_entry(&mut sale, &mut test, tu::buyer(), 0, 100, &clk); // max 0 = no per-entry cap
    assert_eq!(sale.raised(), 100);
    tu::return_sale(sale);

    destroy(clk);
    test.end();
}

// An allowlist sale rejects a purchase with no entry.
#[test, expected_failure(abort_code = prefunded_sale::EAllowlistRequired)]
fun allowlist_required_but_none_aborts() {
    let (mut test, clk) = tu::setup();
    tu::create_and_activate_full(&mut test, &clk, 1, 1_000, 0, tu::opens(), tu::closes(), 1_000, true);

    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(&test);
    tu::buy(&mut sale, 100, &clk, test.ctx()); // aborts: no entry
    tu::return_sale(sale);
    destroy(clk);
    test.end();
}

// A non-allowlist sale rejects a purchase that carries an entry.
#[test, expected_failure(abort_code = prefunded_sale::EAllowlistNotRequired)]
fun allowlist_not_required_but_provided_aborts() {
    let (mut test, clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);

    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(&test);
    // Craft an admin + entry for this sale (no allowlist enabled on it).
    let admin = allowlist::new_admin<SALE>(object::id(&sale), test.ctx());
    let entry = admin.new_entry(tu::buyer(), 0);
    let quote = fixed_rate_curve::quote(&sale, tu::pay_balance(100));
    sale.purchase(quote, option::some(entry), &clk, test.ctx()); // aborts
    destroy(admin);
    tu::return_sale(sale);
    destroy(clk);
    test.end();
}

// The per-entry cap (max_amount) bounds a single purchase.
#[test, expected_failure(abort_code = prefunded_sale::EPerEntryCapExceeded)]
fun per_entry_cap_exceeded_aborts() {
    let (mut test, clk) = tu::setup();
    tu::create_and_activate_full(&mut test, &clk, 1, 1_000, 0, tu::opens(), tu::closes(), 1_000, true);

    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(&test);
    buy_with_entry(&mut sale, &mut test, tu::buyer(), 50, 51, &clk); // 51 > max 50
    tu::return_sale(sale);
    destroy(clk);
    test.end();
}

// Close-transition tests for `prefunded_sale`.
//
// finalize (success), cancel_after_close (permissionless soft-cap miss), and
// cancel_emergency (admin, in-window) each enforce their economic
// preconditions. After cancel, the proceeds move into the vault
// (vault.locked == raised, proceeds == 0) and the vault flips to Refunding;
// after finalize the vault flips to Closed. Terminal phases reject re-entry.
module openzeppelin_sale::prefunded_sale_lifecycle_tests;

use openzeppelin_finance::vesting_wallet_linear::{Linear, Params as VParams};
use openzeppelin_sale::fixed_rate_curve::{Self, FixedRateCurve, Params as FrcParams};
use openzeppelin_sale::prefunded_sale::{Self, PrefundedSale};
use openzeppelin_sale::refund_vault;
use openzeppelin_sale::test_utils::{Self as u, SALE, USDC};
use std::unit_test::{assert_eq, destroy};
use sui::clock::Clock;
use sui::event;
use sui::test_scenario::Scenario;

// === Test-Only Helpers ===

// Buy `paid` as the buyer in a fresh tx, leaving the sale shared again.
fun buy_once(test: &mut Scenario, clk: &Clock, paid: u64) {
    test.next_tx(u::buyer());
    let mut sale = u::take_sale(test);
    u::buy(&mut sale, paid, clk, test.ctx());
    u::return_sale(sale);
}

// === finalize ===

// Window closed with soft cap met -> Finalized, vault Closed.
#[test]
fun finalize_after_close_succeeds() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 500, 1_000);
    buy_once(&mut test, &clk, 500);
    clk.set_for_testing(5_001);

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let mut vault = u::take_vault(&test);
    sale.finalize(&mut vault, &clk);
    assert!(sale.is_finalized());
    assert!(vault.is_closed());
    assert_eq!(sale.proceeds_amount(), 500); // proceeds stay until withdrawn

    let finalized = event::events_by_type<prefunded_sale::SaleFinalized<SALE, USDC>>();
    assert_eq!(finalized.length(), 1);
    assert_eq!(
        finalized[0],
        prefunded_sale::test_new_sale_finalized<SALE, USDC>(object::id(&sale), 500, 5_001),
    );
    // finalize flips the paired vault Active -> Closed.
    let changed = event::events_by_type<refund_vault::VaultStateChanged<USDC>>();
    assert_eq!(changed.length(), 1);
    assert_eq!(
        changed[0],
        refund_vault::test_new_vault_state_changed<USDC>(
            object::id(&vault),
            refund_vault::test_state_active(),
            refund_vault::test_state_closed(),
        ),
    );

    u::return_sale(sale);
    u::return_vault(vault);

    destroy(clk);
    test.end();
}

// Hard cap reached -> finalize allowed early, before the window closes.
#[test]
fun finalize_early_when_hard_cap_reached() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 1_000); // raised == hard_cap, still in window

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let mut vault = u::take_vault(&test);
    sale.finalize(&mut vault, &clk);
    assert!(sale.is_finalized());
    u::return_sale(sale);
    u::return_vault(vault);

    destroy(clk);
    test.end();
}

// Window still open and hard cap not reached -> cannot finalize.
#[test, expected_failure(abort_code = prefunded_sale::ESaleWindowStillOpen)]
fun finalize_window_open_not_sold_out_aborts() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 500);

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let mut vault = u::take_vault(&test);
    sale.finalize(&mut vault, &clk); // aborts
    abort
}

// Boundary: at exactly closes_at_ms the window is still open for finalize
// (the guard is strict, now > closes_at_ms), so a non-sold-out sale cannot
// finalize yet. Mirror of purchase_at_exact_close_ok, which is inclusive.
#[test, expected_failure(abort_code = prefunded_sale::ESaleWindowStillOpen)]
fun finalize_at_exact_close_not_sold_out_aborts() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 500);
    clk.set_for_testing(u::closes()); // now == closes_at_ms

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let mut vault = u::take_vault(&test);
    sale.finalize(&mut vault, &clk); // aborts: window still open at the boundary
    abort
}

// Soft cap not met at close -> cannot finalize.
#[test, expected_failure(abort_code = prefunded_sale::ESoftCapNotMet)]
fun finalize_soft_cap_not_met_aborts() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 500, 1_000);
    buy_once(&mut test, &clk, 300);
    clk.set_for_testing(5_001);

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let mut vault = u::take_vault(&test);
    sale.finalize(&mut vault, &clk); // aborts
    abort
}

// Finalized is terminal: a second finalize aborts on the phase guard.
#[test, expected_failure(abort_code = prefunded_sale::ENotActive)]
fun finalize_twice_aborts() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 500);
    clk.set_for_testing(5_001);

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let mut vault = u::take_vault(&test);
    sale.finalize(&mut vault, &clk);
    sale.finalize(&mut vault, &clk); // aborts: ENotActive
    abort
}

// === cancel_after_close ===

// Window closed below the soft cap -> Cancelled, proceeds routed to the vault.
#[test]
fun cancel_after_close_succeeds_and_routes_proceeds() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 500, 1_000);
    buy_once(&mut test, &clk, 300);
    clk.set_for_testing(5_001);

    test.next_tx(u::buyer()); // permissionless
    let mut sale = u::take_sale(&test);
    let mut vault = u::take_vault(&test);
    sale.cancel_after_close(&mut vault, &clk);
    assert!(sale.is_cancelled());
    assert!(vault.is_refunding());
    assert_eq!(vault.value(), 300); // locked == raised
    assert_eq!(sale.proceeds_amount(), 0); // proceeds drained

    let cancelled = event::events_by_type<prefunded_sale::SaleCancelled<SALE, USDC>>();
    assert_eq!(cancelled.length(), 1);
    assert_eq!(
        cancelled[0],
        prefunded_sale::test_new_sale_cancelled<SALE, USDC>(
            object::id(&sale),
            300,
            prefunded_sale::test_cancel_reason_soft_cap_missed(),
            5_001,
        ),
    );
    // do_cancel routes proceeds into the vault (VaultDeposited 300) then flips Active -> Refunding.
    let deposits = event::events_by_type<refund_vault::VaultDeposited<USDC>>();
    assert_eq!(deposits.length(), 1);
    assert_eq!(
        deposits[0],
        refund_vault::test_new_vault_deposited<USDC>(object::id(&vault), 300, 300),
    );
    let changed = event::events_by_type<refund_vault::VaultStateChanged<USDC>>();
    assert_eq!(changed.length(), 1);
    assert_eq!(
        changed[0],
        refund_vault::test_new_vault_state_changed<USDC>(
            object::id(&vault),
            refund_vault::test_state_active(),
            refund_vault::test_state_refunding(),
        ),
    );

    u::return_sale(sale);
    u::return_vault(vault);

    destroy(clk);
    test.end();
}

// Soft cap met -> cannot cancel after close (must finalize).
#[test, expected_failure(abort_code = prefunded_sale::ESoftCapMet)]
fun cancel_after_close_soft_cap_met_aborts() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 500, 1_000);
    buy_once(&mut test, &clk, 600);
    clk.set_for_testing(5_001);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    let mut vault = u::take_vault(&test);
    sale.cancel_after_close(&mut vault, &clk); // aborts
    abort
}

// Window still open -> cannot cancel_after_close.
#[test, expected_failure(abort_code = prefunded_sale::ESaleWindowStillOpen)]
fun cancel_after_close_window_open_aborts() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 500, 1_000);
    buy_once(&mut test, &clk, 100);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    let mut vault = u::take_vault(&test);
    sale.cancel_after_close(&mut vault, &clk); // aborts
    abort
}

// cancel_after_close requires Active: it aborts once the sale is Finalized.
#[test, expected_failure(abort_code = prefunded_sale::ENotActive)]
fun cancel_after_close_when_finalized_aborts() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 500);
    clk.set_for_testing(5_001);

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let mut vault = u::take_vault(&test);
    sale.finalize(&mut vault, &clk);
    sale.cancel_after_close(&mut vault, &clk); // aborts: ENotActive
    abort
}

// === cancel_emergency ===

// In-window emergency cancel by admin -> Cancelled, proceeds routed.
#[test]
fun cancel_emergency_succeeds() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 100);

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let mut vault = u::take_vault(&test);
    let cap = u::take_cap(&test);
    sale.cancel_emergency(&cap, &mut vault, &clk);
    assert!(sale.is_cancelled());
    assert_eq!(vault.value(), 100);

    let cancelled = event::events_by_type<prefunded_sale::SaleCancelled<SALE, USDC>>();
    assert_eq!(cancelled.length(), 1);
    assert_eq!(
        cancelled[0],
        prefunded_sale::test_new_sale_cancelled<SALE, USDC>(
            object::id(&sale),
            100,
            prefunded_sale::test_cancel_reason_admin_emergency(),
            u::opens(),
        ),
    );

    u::return_sale(sale);
    u::return_vault(vault);
    u::return_cap(cap);

    destroy(clk);
    test.end();
}

// Emergency cancel with zero raised: do_cancel routes an empty proceeds balance
// through the vault's deposit (the zero-value no-op path) and still cancels cleanly.
#[test]
fun cancel_emergency_zero_raised_succeeds() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    // No purchase: raised == 0.

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let mut vault = u::take_vault(&test);
    let cap = u::take_cap(&test);
    sale.cancel_emergency(&cap, &mut vault, &clk);
    assert!(sale.is_cancelled());
    assert!(vault.is_refunding());
    assert_eq!(vault.value(), 0);

    // Zero proceeds -> the vault deposit is a no-op and emits no VaultDeposited; the sale
    // still cancels (SaleCancelled with raised == 0) and the vault still flips to Refunding.
    assert_eq!(event::events_by_type<refund_vault::VaultDeposited<USDC>>().length(), 0);
    let cancelled = event::events_by_type<prefunded_sale::SaleCancelled<SALE, USDC>>();
    assert_eq!(cancelled.length(), 1);
    assert_eq!(
        cancelled[0],
        prefunded_sale::test_new_sale_cancelled<SALE, USDC>(
            object::id(&sale),
            0,
            prefunded_sale::test_cancel_reason_admin_emergency(),
            u::opens(),
        ),
    );

    u::return_sale(sale);
    u::return_vault(vault);
    u::return_cap(cap);

    destroy(clk);
    test.end();
}

// Boundary + 2nd disjunct: at exactly closes_at_ms the window is still open for an
// emergency cancel (guard is inclusive, now <= closes_at_ms), and a configured-but-unmet
// soft cap (raised < soft_cap, the right side of `soft_cap == 0 || raised < soft_cap`)
// still permits it. cancel_emergency_succeeds covers the soft_cap == 0 disjunct at opens.
#[test]
fun cancel_emergency_at_exact_close_soft_cap_unmet_succeeds() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 500, 1_000);
    buy_once(&mut test, &clk, 300); // raised 300 < soft_cap 500
    clk.set_for_testing(u::closes()); // now == closes_at_ms

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let mut vault = u::take_vault(&test);
    let cap = u::take_cap(&test);
    sale.cancel_emergency(&cap, &mut vault, &clk);
    assert!(sale.is_cancelled());
    assert_eq!(vault.value(), 300);

    u::return_sale(sale);
    u::return_vault(vault);
    u::return_cap(cap);
    destroy(clk);
    test.end();
}

// A cap that does not match the sale is rejected.
#[test, expected_failure(abort_code = prefunded_sale::EWrongAdminCap)]
fun cancel_emergency_wrong_cap_aborts() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 100);

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let mut vault = u::take_vault(&test);
    // A throwaway sale just to obtain a foreign (mismatching) admin cap.
    let (_foreign_sale, foreign_cap) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(
        fixed_rate_curve::params(1),
        1_000,
        0,
        u::opens(),
        u::closes(),
        test.ctx(),
    );
    sale.cancel_emergency(&foreign_cap, &mut vault, &clk); // aborts: EWrongAdminCap
    abort
}

// Emergency cancel after the window has closed is rejected.
#[test, expected_failure(abort_code = prefunded_sale::EEmergencyCancelAfterClose)]
fun cancel_emergency_after_close_aborts() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 100);
    clk.set_for_testing(5_001);

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let mut vault = u::take_vault(&test);
    let cap = u::take_cap(&test);
    sale.cancel_emergency(&cap, &mut vault, &clk); // aborts
    abort
}

// A sold-out sale cannot be emergency-cancelled (must finalize).
#[test, expected_failure(abort_code = prefunded_sale::ESaleAlreadyComplete)]
fun cancel_emergency_hard_cap_reached_aborts() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 1_000); // raised == hard_cap

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let mut vault = u::take_vault(&test);
    let cap = u::take_cap(&test);
    sale.cancel_emergency(&cap, &mut vault, &clk); // aborts
    abort
}

// A sale that has met its soft cap cannot be emergency-cancelled.
#[test, expected_failure(abort_code = prefunded_sale::ESoftCapMet)]
fun cancel_emergency_soft_cap_met_aborts() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 500, 1_000);
    buy_once(&mut test, &clk, 500); // raised >= soft_cap

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let mut vault = u::take_vault(&test);
    let cap = u::take_cap(&test);
    sale.cancel_emergency(&cap, &mut vault, &clk); // aborts
    abort
}

// cancel_emergency requires Active: with a valid cap it still aborts once the
// sale is Finalized (the phase guard sits after the cap check).
#[test, expected_failure(abort_code = prefunded_sale::ENotActive)]
fun cancel_emergency_when_finalized_aborts() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 500);
    clk.set_for_testing(5_001);

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let mut vault = u::take_vault(&test);
    let cap = u::take_cap(&test);
    sale.finalize(&mut vault, &clk);
    sale.cancel_emergency(&cap, &mut vault, &clk); // aborts: ENotActive
    abort
}

// === Wrong-vault guards on close paths ===
//
// finalize / cancel_after_close / cancel_emergency each re-assert that the passed
// vault is the one paired with the sale, so a caller cannot substitute a
// valid-but-unpaired vault at close time. Each test drives the sale to the point
// where the vault check is reached, then passes a foreign vault.

// finalize rejects a vault that is not the paired one (reached after the
// window/soft-cap guards pass).
#[test, expected_failure(abort_code = prefunded_sale::EWrongVault)]
fun finalize_wrong_vault_aborts() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 500, 1_000);
    buy_once(&mut test, &clk, 500); // soft cap met
    clk.set_for_testing(5_001); // window closed

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let (mut foreign_vault, _foreign_cap) = refund_vault::new<USDC>(test.ctx());
    sale.finalize(&mut foreign_vault, &clk); // aborts: EWrongVault
    abort
}

// cancel_after_close rejects a vault that is not the paired one (reached after the
// window/soft-cap guards pass).
#[test, expected_failure(abort_code = prefunded_sale::EWrongVault)]
fun cancel_after_close_wrong_vault_aborts() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 500, 1_000);
    buy_once(&mut test, &clk, 300); // below soft cap
    clk.set_for_testing(5_001); // window closed

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    let (mut foreign_vault, _foreign_cap) = refund_vault::new<USDC>(test.ctx());
    sale.cancel_after_close(&mut foreign_vault, &clk); // aborts: EWrongVault
    abort
}

// cancel_emergency rejects a vault that is not the paired one (reached after the
// cap/phase/window/cap-guard checks pass).
#[test, expected_failure(abort_code = prefunded_sale::EWrongVault)]
fun cancel_emergency_wrong_vault_aborts() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 100); // in-window, below hard cap, no soft cap

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let cap = u::take_cap(&test);
    let (mut foreign_vault, _foreign_cap) = refund_vault::new<USDC>(test.ctx());
    sale.cancel_emergency(&cap, &mut foreign_vault, &clk); // aborts: EWrongVault
    abort
}

// === Views ===

// has_reached_soft_cap: false while raised < soft_cap, true once raised >= soft_cap,
// and always true when no soft cap is configured (soft_cap == 0).
#[test]
fun has_reached_soft_cap_tracks_raised() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 500, 1_000);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    assert!(!sale.has_reached_soft_cap()); // raised 0 < 500
    u::buy(&mut sale, 500, &clk, test.ctx());
    assert!(sale.has_reached_soft_cap()); // raised 500 >= 500
    u::return_sale(sale);

    destroy(clk);
    test.end();
}

// With no soft cap configured the sale reads as having met it from the start.
#[test]
fun has_reached_soft_cap_true_without_soft_cap() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000); // soft_cap == 0

    test.next_tx(u::buyer());
    let sale = u::take_sale(&test);
    assert!(sale.has_reached_soft_cap()); // raised 0 >= 0
    u::return_sale(sale);

    destroy(clk);
    test.end();
}

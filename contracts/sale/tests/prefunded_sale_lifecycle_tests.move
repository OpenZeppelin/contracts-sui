// Close-transition tests for `prefunded_sale`.
//
// finalize (success), cancel_after_close (permissionless soft-cap miss), and
// cancel_emergency (admin, in-window) each enforce their economic
// preconditions. After cancel, the proceeds move into the vault
// (vault.locked == raised, proceeds == 0) and the vault flips to Refunding;
// after finalize the vault flips to Closed. Terminal phases reject re-entry.
module openzeppelin_sale::prefunded_sale_lifecycle_tests;

use openzeppelin_finance::vesting_wallet_linear::Params as VParams;
use openzeppelin_sale::fixed_rate_curve::{Self, FixedRateCurve, Params as FrcParams};
use openzeppelin_sale::prefunded_sale::{Self, PrefundedSale};
use openzeppelin_sale::refund_vault;
use openzeppelin_sale::test_utils::{Self as tu, SALE, USDC};
use std::unit_test::{assert_eq, destroy};
use sui::clock::Clock;
use sui::event;
use sui::test_scenario::Scenario;

// === Test-Only Helpers ===

// Buy `paid` as the buyer in a fresh tx, leaving the sale shared again.
fun buy_once(test: &mut Scenario, clk: &Clock, paid: u64) {
    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(test);
    tu::buy(&mut sale, paid, clk, test.ctx());
    tu::return_sale(sale);
}

// === finalize ===

// Window closed with soft cap met -> Finalized, vault Closed.
#[test]
fun finalize_after_close_succeeds() {
    let (mut test, mut clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 500, 1_000);
    buy_once(&mut test, &clk, 500);
    clk.set_for_testing(5_001);

    test.next_tx(tu::admin());
    let mut sale = tu::take_sale(&test);
    let mut vault = tu::take_vault(&test);
    sale.finalize(&mut vault, &clk);
    assert_eq!(sale.phase().is_finalized(), true);
    assert_eq!(vault.is_closed(), true);
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

    tu::return_sale(sale);
    tu::return_vault(vault);

    destroy(clk);
    test.end();
}

// Hard cap reached -> finalize allowed early, before the window closes.
#[test]
fun finalize_early_when_hard_cap_reached() {
    let (mut test, clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 1_000); // raised == hard_cap, still in window

    test.next_tx(tu::admin());
    let mut sale = tu::take_sale(&test);
    let mut vault = tu::take_vault(&test);
    sale.finalize(&mut vault, &clk);
    assert_eq!(sale.phase().is_finalized(), true);
    tu::return_sale(sale);
    tu::return_vault(vault);

    destroy(clk);
    test.end();
}

// Window still open and hard cap not reached -> cannot finalize.
#[test, expected_failure(abort_code = prefunded_sale::ESaleWindowStillOpen)]
fun finalize_window_open_not_sold_out_aborts() {
    let (mut test, clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 500);

    test.next_tx(tu::admin());
    let mut sale = tu::take_sale(&test);
    let mut vault = tu::take_vault(&test);
    sale.finalize(&mut vault, &clk); // aborts
    tu::return_sale(sale);
    tu::return_vault(vault);
    destroy(clk);
    test.end();
}

// Soft cap not met at close -> cannot finalize.
#[test, expected_failure(abort_code = prefunded_sale::ESoftCapNotMet)]
fun finalize_soft_cap_not_met_aborts() {
    let (mut test, mut clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 500, 1_000);
    buy_once(&mut test, &clk, 300);
    clk.set_for_testing(5_001);

    test.next_tx(tu::admin());
    let mut sale = tu::take_sale(&test);
    let mut vault = tu::take_vault(&test);
    sale.finalize(&mut vault, &clk); // aborts
    tu::return_sale(sale);
    tu::return_vault(vault);
    destroy(clk);
    test.end();
}

// Finalized is terminal: a second finalize aborts on the phase guard.
#[test, expected_failure(abort_code = openzeppelin_sale::phase::ENotActive)]
fun finalize_twice_aborts() {
    let (mut test, mut clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 500);
    clk.set_for_testing(5_001);

    test.next_tx(tu::admin());
    let mut sale = tu::take_sale(&test);
    let mut vault = tu::take_vault(&test);
    sale.finalize(&mut vault, &clk);
    sale.finalize(&mut vault, &clk); // aborts: ENotActive
    tu::return_sale(sale);
    tu::return_vault(vault);
    destroy(clk);
    test.end();
}

// === cancel_after_close ===

// Window closed below the soft cap -> Cancelled, proceeds routed to the vault.
#[test]
fun cancel_after_close_succeeds_and_routes_proceeds() {
    let (mut test, mut clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 500, 1_000);
    buy_once(&mut test, &clk, 300);
    clk.set_for_testing(5_001);

    test.next_tx(tu::buyer()); // permissionless
    let mut sale = tu::take_sale(&test);
    let mut vault = tu::take_vault(&test);
    sale.cancel_after_close(&mut vault, &clk);
    assert_eq!(sale.phase().is_cancelled(), true);
    assert_eq!(vault.is_refunding(), true);
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
    // do_cancel routes proceeds into the vault (VaultDeposit 300) then flips Active -> Refunding.
    let deposits = event::events_by_type<refund_vault::VaultDeposit<USDC>>();
    assert_eq!(deposits.length(), 1);
    assert_eq!(
        deposits[0],
        refund_vault::test_new_vault_deposit<USDC>(object::id(&vault), 300, 300),
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

    tu::return_sale(sale);
    tu::return_vault(vault);

    destroy(clk);
    test.end();
}

// Soft cap met -> cannot cancel after close (must finalize).
#[test, expected_failure(abort_code = prefunded_sale::ESoftCapMet)]
fun cancel_after_close_soft_cap_met_aborts() {
    let (mut test, mut clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 500, 1_000);
    buy_once(&mut test, &clk, 600);
    clk.set_for_testing(5_001);

    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(&test);
    let mut vault = tu::take_vault(&test);
    sale.cancel_after_close(&mut vault, &clk); // aborts
    tu::return_sale(sale);
    tu::return_vault(vault);
    destroy(clk);
    test.end();
}

// Window still open -> cannot cancel_after_close.
#[test, expected_failure(abort_code = prefunded_sale::ESaleWindowStillOpen)]
fun cancel_after_close_window_open_aborts() {
    let (mut test, clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 500, 1_000);
    buy_once(&mut test, &clk, 100);

    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(&test);
    let mut vault = tu::take_vault(&test);
    sale.cancel_after_close(&mut vault, &clk); // aborts
    tu::return_sale(sale);
    tu::return_vault(vault);
    destroy(clk);
    test.end();
}

// === cancel_emergency ===

// In-window emergency cancel by admin -> Cancelled, proceeds routed.
#[test]
fun cancel_emergency_succeeds() {
    let (mut test, clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 100);

    test.next_tx(tu::admin());
    let mut sale = tu::take_sale(&test);
    let mut vault = tu::take_vault(&test);
    let cap = tu::take_cap(&test);
    sale.cancel_emergency(&cap, &mut vault, &clk);
    assert_eq!(sale.phase().is_cancelled(), true);
    assert_eq!(vault.value(), 100);

    let cancelled = event::events_by_type<prefunded_sale::SaleCancelled<SALE, USDC>>();
    assert_eq!(cancelled.length(), 1);
    assert_eq!(
        cancelled[0],
        prefunded_sale::test_new_sale_cancelled<SALE, USDC>(
            object::id(&sale),
            100,
            prefunded_sale::test_cancel_reason_admin_emergency(),
            tu::opens(),
        ),
    );

    tu::return_sale(sale);
    tu::return_vault(vault);
    tu::return_cap(cap);

    destroy(clk);
    test.end();
}

// Emergency cancel with zero raised: do_cancel routes an empty proceeds balance
// through the vault's deposit (the zero-value no-op path) and still cancels cleanly.
#[test]
fun cancel_emergency_zero_raised_succeeds() {
    let (mut test, clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    // No purchase: raised == 0.

    test.next_tx(tu::admin());
    let mut sale = tu::take_sale(&test);
    let mut vault = tu::take_vault(&test);
    let cap = tu::take_cap(&test);
    sale.cancel_emergency(&cap, &mut vault, &clk);
    assert_eq!(sale.phase().is_cancelled(), true);
    assert_eq!(vault.is_refunding(), true);
    assert_eq!(vault.value(), 0);

    // Zero proceeds -> the vault deposit is a no-op and emits no VaultDeposit; the sale
    // still cancels (SaleCancelled with raised == 0) and the vault still flips to Refunding.
    assert_eq!(event::events_by_type<refund_vault::VaultDeposit<USDC>>().length(), 0);
    let cancelled = event::events_by_type<prefunded_sale::SaleCancelled<SALE, USDC>>();
    assert_eq!(cancelled.length(), 1);
    assert_eq!(
        cancelled[0],
        prefunded_sale::test_new_sale_cancelled<SALE, USDC>(
            object::id(&sale),
            0,
            prefunded_sale::test_cancel_reason_admin_emergency(),
            tu::opens(),
        ),
    );

    tu::return_sale(sale);
    tu::return_vault(vault);
    tu::return_cap(cap);

    destroy(clk);
    test.end();
}

// A cap that does not match the sale is rejected.
#[test, expected_failure(abort_code = prefunded_sale::EWrongAdminCap)]
fun cancel_emergency_wrong_cap_aborts() {
    let (mut test, clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 100);

    test.next_tx(tu::admin());
    let mut sale = tu::take_sale(&test);
    let mut vault = tu::take_vault(&test);
    // A throwaway sale just to obtain a foreign (mismatching) admin cap.
    let (foreign_sale, foreign_cap) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        VParams,
    >(
        fixed_rate_curve::params(1),
        1_000,
        0,
        tu::opens(),
        tu::closes(),
        test.ctx(),
    );
    sale.cancel_emergency(&foreign_cap, &mut vault, &clk); // aborts: EWrongAdminCap
    destroy(foreign_sale);
    destroy(foreign_cap);
    tu::return_sale(sale);
    tu::return_vault(vault);
    destroy(clk);
    test.end();
}

// Emergency cancel after the window has closed is rejected.
#[test, expected_failure(abort_code = prefunded_sale::EEmergencyCancelAfterClose)]
fun cancel_emergency_after_close_aborts() {
    let (mut test, mut clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 100);
    clk.set_for_testing(5_001);

    test.next_tx(tu::admin());
    let mut sale = tu::take_sale(&test);
    let mut vault = tu::take_vault(&test);
    let cap = tu::take_cap(&test);
    sale.cancel_emergency(&cap, &mut vault, &clk); // aborts
    tu::return_sale(sale);
    tu::return_vault(vault);
    tu::return_cap(cap);
    destroy(clk);
    test.end();
}

// A sold-out sale cannot be emergency-cancelled (must finalize).
#[test, expected_failure(abort_code = prefunded_sale::ESaleAlreadyComplete)]
fun cancel_emergency_hard_cap_reached_aborts() {
    let (mut test, clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 1_000); // raised == hard_cap

    test.next_tx(tu::admin());
    let mut sale = tu::take_sale(&test);
    let mut vault = tu::take_vault(&test);
    let cap = tu::take_cap(&test);
    sale.cancel_emergency(&cap, &mut vault, &clk); // aborts
    tu::return_sale(sale);
    tu::return_vault(vault);
    tu::return_cap(cap);
    destroy(clk);
    test.end();
}

// A sale that has met its soft cap cannot be emergency-cancelled.
#[test, expected_failure(abort_code = prefunded_sale::ESoftCapMet)]
fun cancel_emergency_soft_cap_met_aborts() {
    let (mut test, clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 500, 1_000);
    buy_once(&mut test, &clk, 500); // raised >= soft_cap

    test.next_tx(tu::admin());
    let mut sale = tu::take_sale(&test);
    let mut vault = tu::take_vault(&test);
    let cap = tu::take_cap(&test);
    sale.cancel_emergency(&cap, &mut vault, &clk); // aborts
    tu::return_sale(sale);
    tu::return_vault(vault);
    tu::return_cap(cap);
    destroy(clk);
    test.end();
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
    let (mut test, mut clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 500, 1_000);
    buy_once(&mut test, &clk, 500); // soft cap met
    clk.set_for_testing(5_001); // window closed

    test.next_tx(tu::admin());
    let mut sale = tu::take_sale(&test);
    let (mut foreign_vault, foreign_cap) = refund_vault::new<USDC>(test.ctx());
    sale.finalize(&mut foreign_vault, &clk); // aborts: EWrongVault

    destroy(foreign_vault);
    destroy(foreign_cap);
    tu::return_sale(sale);
    destroy(clk);
    test.end();
}

// cancel_after_close rejects a vault that is not the paired one (reached after the
// window/soft-cap guards pass).
#[test, expected_failure(abort_code = prefunded_sale::EWrongVault)]
fun cancel_after_close_wrong_vault_aborts() {
    let (mut test, mut clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 500, 1_000);
    buy_once(&mut test, &clk, 300); // below soft cap
    clk.set_for_testing(5_001); // window closed

    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(&test);
    let (mut foreign_vault, foreign_cap) = refund_vault::new<USDC>(test.ctx());
    sale.cancel_after_close(&mut foreign_vault, &clk); // aborts: EWrongVault

    destroy(foreign_vault);
    destroy(foreign_cap);
    tu::return_sale(sale);
    destroy(clk);
    test.end();
}

// cancel_emergency rejects a vault that is not the paired one (reached after the
// cap/phase/window/cap-guard checks pass).
#[test, expected_failure(abort_code = prefunded_sale::EWrongVault)]
fun cancel_emergency_wrong_vault_aborts() {
    let (mut test, clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 100); // in-window, below hard cap, no soft cap

    test.next_tx(tu::admin());
    let mut sale = tu::take_sale(&test);
    let cap = tu::take_cap(&test);
    let (mut foreign_vault, foreign_cap) = refund_vault::new<USDC>(test.ctx());
    sale.cancel_emergency(&cap, &mut foreign_vault, &clk); // aborts: EWrongVault

    destroy(foreign_vault);
    destroy(foreign_cap);
    tu::return_cap(cap);
    tu::return_sale(sale);
    destroy(clk);
    test.end();
}

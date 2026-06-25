// Close-transition tests for `prefunded_sale` (INV-16, INV-20, INV-22, INV-25,
// INV-28, INV-29).
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
use openzeppelin_sale::test_utils::{Self as tu, SALE, USDC};
use std::unit_test::{assert_eq, destroy};
use sui::clock::Clock;
use sui::test_scenario::Scenario;

// === Test-Only Helpers ===

// Buy `paid` as the buyer in a fresh tx, leaving the sale shared again.
fun buy_once(test: &mut Scenario, clk: &Clock, paid: u64) {
    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(test);
    tu::buy(&mut sale, paid, clk, test.ctx());
    tu::return_sale(sale);
}

// === finalize (INV-16, INV-20, INV-29) ===

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

// Finalized is terminal: a second finalize aborts on the phase guard (INV-20).
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

// === cancel_after_close (INV-16, INV-20, INV-22, INV-25) ===

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
    assert_eq!(vault.value(), 300); // INV-22/25/26: locked == raised
    assert_eq!(sale.proceeds_amount(), 0); // proceeds drained
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

// === cancel_emergency (INV-16, INV-28) ===

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
    let (foreign_sale, foreign_cap) = prefunded_sale::create_sale<FixedRateCurve, FrcParams, SALE, USDC, VParams>(
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

// INV-28: a sold-out sale cannot be emergency-cancelled (must finalize).
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

// INV-28: a sale that has met its soft cap cannot be emergency-cancelled.
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

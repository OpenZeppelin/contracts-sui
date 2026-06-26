// Redemption + admin-withdrawal tests for `prefunded_sale`.
//
// claim / claim_all / claim_into_vesting (success path), refund (failure path),
// and the admin withdrawals. Buyer redemption is permissionless and does not
// depend on the admin cap: every claim/refund here runs in a buyer tx
// without taking the cap. Conservation and inventory/refund solvency
// are pinned by exact-value assertions.
module openzeppelin_sale::prefunded_sale_claim_refund_tests;

use openzeppelin_finance::vesting_wallet::VestingWallet;
use openzeppelin_finance::vesting_wallet_linear::{Self, Linear, Params as VParams};
use openzeppelin_sale::fixed_rate_curve::{Self, FixedRateCurve, Params as FrcParams};
use openzeppelin_sale::prefunded_sale::{Self, PrefundedSale};
use openzeppelin_sale::receipt::{Self, Receipt};
use openzeppelin_sale::refund_vault;
use openzeppelin_sale::test_utils::{Self as tu, SALE, USDC};
use std::unit_test::{assert_eq, destroy};
use sui::clock::Clock;
use sui::test_scenario::Scenario;

// === Test-Only Helpers ===

fun buy_once(test: &mut Scenario, clk: &Clock, paid: u64) {
    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(test);
    tu::buy(&mut sale, paid, clk, test.ctx());
    tu::return_sale(sale);
}

// Advance past close and finalize as admin (soft cap must already be met).
fun finalize_now(test: &mut Scenario, clk: &mut Clock) {
    clk.set_for_testing(5_001);
    test.next_tx(tu::admin());
    let mut sale = tu::take_sale(test);
    let mut vault = tu::take_vault(test);
    sale.finalize(&mut vault, clk);
    tu::return_sale(sale);
    tu::return_vault(vault);
}

// Advance past close and cancel as the (permissionless) caller.
fun cancel_now(test: &mut Scenario, clk: &mut Clock) {
    clk.set_for_testing(5_001);
    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(test);
    let mut vault = tu::take_vault(test);
    sale.cancel_after_close(&mut vault, clk);
    tu::return_sale(sale);
    tu::return_vault(vault);
}

// Build an Active sale carrying an issuer-defined vesting schedule (4 monthly-ish
// steps), rate 1, no soft cap, inventory 1_000.
fun setup_vesting_sale(test: &mut Scenario, clk: &Clock) {
    let ctx = test.ctx();
    let (mut sale, cap) = prefunded_sale::create_sale<
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
        ctx,
    );
    sale.deposit(tu::sale_balance(1_000));
    sale.set_vesting_schedule_params(vesting_wallet_linear::params(0, 0, 1_000, 4));
    let (vault, vault_cap) = refund_vault::new<USDC>(ctx);
    sale.pair_refund_vault(&vault, vault_cap);
    let ticket = fixed_rate_curve::activation_ticket(&sale);
    sale.share_and_activate(ticket, clk);
    refund_vault::share(vault);
    transfer::public_transfer(cap, tu::admin());
}

// === claim ===

#[test]
fun claim_returns_allocation_and_draws_inventory() {
    let (mut test, mut clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 2, 1_000, 0, 2_000);
    buy_once(&mut test, &clk, 100); // alloc = 200
    finalize_now(&mut test, &mut clk);

    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(&test);
    let r = test.take_from_address<Receipt<SALE>>(tu::buyer());
    let payout = sale.claim(r, test.ctx());
    assert_eq!(payout.value(), 200);
    assert_eq!(sale.total_allocated(), 0);
    assert_eq!(sale.inventory_total(), 1_800); // 2_000 - 200 drawn
    destroy(payout);
    tu::return_sale(sale);

    destroy(clk);
    test.end();
}

#[test]
fun claim_all_sums_receipts() {
    let (mut test, mut clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 100);
    buy_once(&mut test, &clk, 250);
    finalize_now(&mut test, &mut clk);

    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(&test);
    let r1 = test.take_from_address<Receipt<SALE>>(tu::buyer());
    let r2 = test.take_from_address<Receipt<SALE>>(tu::buyer());
    let payout = sale.claim_all(vector[r1, r2], test.ctx());
    assert_eq!(payout.value(), 350);
    assert_eq!(sale.total_allocated(), 0);
    destroy(payout);
    tu::return_sale(sale);

    destroy(clk);
    test.end();
}

// claim by a non-buyer is rejected.
#[test, expected_failure(abort_code = prefunded_sale::EBuyerOnly)]
fun claim_wrong_buyer_aborts() {
    let (mut test, mut clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 100);
    finalize_now(&mut test, &mut clk);

    test.next_tx(tu::buyer2()); // wrong sender
    let mut sale = tu::take_sale(&test);
    let r = test.take_from_address<Receipt<SALE>>(tu::buyer());
    let payout = sale.claim(r, test.ctx()); // aborts: EBuyerOnly
    destroy(payout);
    tu::return_sale(sale);
    destroy(clk);
    test.end();
}

// A receipt issued by a different sale is rejected.
#[test, expected_failure(abort_code = prefunded_sale::EReceiptSaleMismatch)]
fun claim_foreign_receipt_aborts() {
    let (mut test, mut clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 100);
    finalize_now(&mut test, &mut clk);

    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(&test);
    // A receipt minted against a foreign sale id (package-internal helper).
    let foreign = receipt::new_receipt<SALE>(
        object::id_from_address(@0xDEAD),
        tu::buyer(),
        100,
        100,
        1_000,
        test.ctx(),
    );
    let payout = sale.claim(foreign, test.ctx()); // aborts: EReceiptSaleMismatch
    destroy(payout);
    tu::return_sale(sale);
    destroy(clk);
    test.end();
}

// claim before the sale is finalized is rejected.
#[test, expected_failure(abort_code = openzeppelin_sale::phase::ENotFinalized)]
fun claim_before_finalize_aborts() {
    let (mut test, clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 100);

    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(&test);
    let r = test.take_from_address<Receipt<SALE>>(tu::buyer());
    let payout = sale.claim(r, test.ctx()); // aborts: ENotFinalized
    destroy(payout);
    tu::return_sale(sale);
    destroy(clk);
    test.end();
}

// === Vesting routing ===

// A vesting-attached sale rejects the plain claim path.
#[test, expected_failure(abort_code = prefunded_sale::EClaimRequiresVesting)]
fun claim_with_vesting_attached_aborts() {
    let (mut test, mut clk) = tu::setup();
    setup_vesting_sale(&mut test, &clk);
    buy_once(&mut test, &clk, 100);
    finalize_now(&mut test, &mut clk);

    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(&test);
    let r = test.take_from_address<Receipt<SALE>>(tu::buyer());
    let payout = sale.claim(r, test.ctx()); // aborts: EClaimRequiresVesting
    destroy(payout);
    tu::return_sale(sale);
    destroy(clk);
    test.end();
}

// claim_into_vesting funds a wallet with the allocation, beneficiary = buyer.
#[test]
fun claim_into_vesting_returns_funded_wallet() {
    let (mut test, mut clk) = tu::setup();
    setup_vesting_sale(&mut test, &clk);
    buy_once(&mut test, &clk, 100); // rate 1 -> alloc 100
    finalize_now(&mut test, &mut clk);

    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(&test);
    let r = test.take_from_address<Receipt<SALE>>(tu::buyer());
    let wallet: VestingWallet<Linear, VParams, SALE> = prefunded_sale::claim_into_vesting<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        VParams,
        Linear,
    >(&mut sale, r, test.ctx());
    assert_eq!(wallet.balance(), 100);
    assert_eq!(wallet.beneficiary(), tu::buyer());
    assert_eq!(sale.total_allocated(), 0);
    destroy(wallet);
    tu::return_sale(sale);

    destroy(clk);
    test.end();
}

// claim_all_into_vesting funds one wallet with the summed allocations.
#[test]
fun claim_all_into_vesting_sums_into_one_wallet() {
    let (mut test, mut clk) = tu::setup();
    setup_vesting_sale(&mut test, &clk);
    buy_once(&mut test, &clk, 100);
    buy_once(&mut test, &clk, 250);
    finalize_now(&mut test, &mut clk);

    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(&test);
    let r1 = test.take_from_address<Receipt<SALE>>(tu::buyer());
    let r2 = test.take_from_address<Receipt<SALE>>(tu::buyer());
    let wallet: VestingWallet<Linear, VParams, SALE> = prefunded_sale::claim_all_into_vesting<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        VParams,
        Linear,
    >(&mut sale, vector[r1, r2], test.ctx());
    assert_eq!(wallet.balance(), 350);
    assert_eq!(wallet.beneficiary(), tu::buyer());
    assert_eq!(sale.total_allocated(), 0);
    destroy(wallet);
    tu::return_sale(sale);

    destroy(clk);
    test.end();
}

// claim_into_vesting on a non-vesting sale is rejected.
#[test, expected_failure(abort_code = prefunded_sale::ENoVestingScheduleAttached)]
fun claim_into_vesting_without_schedule_aborts() {
    let (mut test, mut clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 100);
    finalize_now(&mut test, &mut clk);

    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(&test);
    let r = test.take_from_address<Receipt<SALE>>(tu::buyer());
    let wallet: VestingWallet<Linear, VParams, SALE> = prefunded_sale::claim_into_vesting<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        VParams,
        Linear,
    >(&mut sale, r, test.ctx()); // aborts: ENoVestingScheduleAttached
    destroy(wallet);
    tu::return_sale(sale);
    destroy(clk);
    test.end();
}

// === refund ===

#[test]
fun refund_returns_paid_and_draws_vault() {
    let (mut test, mut clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 500, 1_000);
    buy_once(&mut test, &clk, 300); // below soft cap
    cancel_now(&mut test, &mut clk);

    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(&test);
    let mut vault = tu::take_vault(&test);
    let r = test.take_from_address<Receipt<SALE>>(tu::buyer());
    let payment = sale.refund(&mut vault, r, test.ctx());
    assert_eq!(payment.value(), 300);
    assert_eq!(vault.value(), 0); // drained exactly
    assert_eq!(sale.total_allocated(), 0);
    destroy(payment);
    tu::return_sale(sale);
    tu::return_vault(vault);

    destroy(clk);
    test.end();
}

#[test, expected_failure(abort_code = prefunded_sale::EBuyerOnly)]
fun refund_wrong_buyer_aborts() {
    let (mut test, mut clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 500, 1_000);
    buy_once(&mut test, &clk, 300);
    cancel_now(&mut test, &mut clk);

    test.next_tx(tu::buyer2()); // wrong sender
    let mut sale = tu::take_sale(&test);
    let mut vault = tu::take_vault(&test);
    let r = test.take_from_address<Receipt<SALE>>(tu::buyer());
    let payment = sale.refund(&mut vault, r, test.ctx()); // aborts
    destroy(payment);
    tu::return_sale(sale);
    tu::return_vault(vault);
    destroy(clk);
    test.end();
}

// refund is rejected unless the sale is Cancelled.
#[test, expected_failure(abort_code = openzeppelin_sale::phase::ENotCancelled)]
fun refund_before_cancel_aborts() {
    let (mut test, clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 100);

    test.next_tx(tu::buyer());
    let mut sale = tu::take_sale(&test);
    let mut vault = tu::take_vault(&test);
    let r = test.take_from_address<Receipt<SALE>>(tu::buyer());
    let payment = sale.refund(&mut vault, r, test.ctx()); // aborts: ENotCancelled
    destroy(payment);
    tu::return_sale(sale);
    tu::return_vault(vault);
    destroy(clk);
    test.end();
}

// === withdraw_proceeds ===

#[test]
fun withdraw_proceeds_returns_raised() {
    let (mut test, mut clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 400);
    finalize_now(&mut test, &mut clk);

    test.next_tx(tu::admin());
    let mut sale = tu::take_sale(&test);
    let cap = tu::take_cap(&test);
    let proceeds = sale.withdraw_proceeds(&cap);
    assert_eq!(proceeds.value(), 400);
    assert_eq!(sale.proceeds_amount(), 0);
    destroy(proceeds);
    tu::return_sale(sale);
    tu::return_cap(cap);

    destroy(clk);
    test.end();
}

#[test, expected_failure(abort_code = prefunded_sale::EWrongAdminCap)]
fun withdraw_proceeds_wrong_cap_aborts() {
    let (mut test, mut clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 400);
    finalize_now(&mut test, &mut clk);

    test.next_tx(tu::admin());
    let mut sale = tu::take_sale(&test);
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
    let proceeds = sale.withdraw_proceeds(&foreign_cap); // aborts
    destroy(proceeds);
    destroy(foreign_sale);
    destroy(foreign_cap);
    tu::return_sale(sale);
    destroy(clk);
    test.end();
}

// withdraw_proceeds requires Finalized (not Active).
#[test, expected_failure(abort_code = openzeppelin_sale::phase::ENotFinalized)]
fun withdraw_proceeds_before_finalize_aborts() {
    let (mut test, clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 400);

    test.next_tx(tu::admin());
    let mut sale = tu::take_sale(&test);
    let cap = tu::take_cap(&test);
    let proceeds = sale.withdraw_proceeds(&cap); // aborts: ENotFinalized
    destroy(proceeds);
    tu::return_sale(sale);
    tu::return_cap(cap);
    destroy(clk);
    test.end();
}

// === withdraw_unsold_inventory ===

// Only the unallocated slack is withdrawn; outstanding allocations stay backed.
#[test]
fun withdraw_unsold_returns_only_slack() {
    let (mut test, mut clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 2, 1_000, 0, 2_000);
    buy_once(&mut test, &clk, 100); // alloc 200
    finalize_now(&mut test, &mut clk);

    test.next_tx(tu::admin());
    let mut sale = tu::take_sale(&test);
    let cap = tu::take_cap(&test);
    let unsold = sale.withdraw_unsold_inventory(&cap);
    assert_eq!(unsold.value(), 1_800); // 2_000 - 200 allocated
    assert_eq!(sale.inventory_remaining(), 0);
    assert_eq!(sale.total_allocated(), 200); // receipt still backed
    destroy(unsold);
    tu::return_sale(sale);
    tu::return_cap(cap);

    destroy(clk);
    test.end();
}

#[test, expected_failure(abort_code = prefunded_sale::EWrongAdminCap)]
fun withdraw_unsold_wrong_cap_aborts() {
    let (mut test, mut clk) = tu::setup();
    tu::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 100);
    finalize_now(&mut test, &mut clk);

    test.next_tx(tu::admin());
    let mut sale = tu::take_sale(&test);
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
    let unsold = sale.withdraw_unsold_inventory(&foreign_cap); // aborts
    destroy(unsold);
    destroy(foreign_sale);
    destroy(foreign_cap);
    tu::return_sale(sale);
    destroy(clk);
    test.end();
}

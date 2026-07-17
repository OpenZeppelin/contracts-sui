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
use openzeppelin_sale::test_utils::{Self as u, SALE, USDC};
use std::unit_test::{assert_eq, destroy};
use sui::clock::Clock;
use sui::event;
use sui::test_scenario::Scenario;

// === Test-Only Helpers ===

fun buy_once(test: &mut Scenario, clk: &Clock, paid: u64) {
    test.next_tx(u::buyer());
    let mut sale = u::take_sale(test);
    u::buy(&mut sale, paid, clk, test.ctx());
    u::return_sale(sale);
}

// Advance past close and finalize as admin (soft cap must already be met).
#[test_only] // allows accepting &mut Clock
fun finalize_now(test: &mut Scenario, clk: &mut Clock) {
    clk.set_for_testing(5_001);
    test.next_tx(u::admin());
    let mut sale = u::take_sale(test);
    let mut vault = u::take_vault(test);
    sale.finalize(&mut vault, clk);
    u::return_sale(sale);
    u::return_vault(vault);
}

// Advance past close and cancel as the (permissionless) caller.
#[test_only] // allows accepting &mut Clock
fun cancel_now(test: &mut Scenario, clk: &mut Clock) {
    clk.set_for_testing(5_001);
    test.next_tx(u::buyer());
    let mut sale = u::take_sale(test);
    let mut vault = u::take_vault(test);
    sale.cancel_after_close(&mut vault, clk);
    u::return_sale(sale);
    u::return_vault(vault);
}

// Build an Active sale carrying the given issuer-defined vesting schedule, rate 1,
// no soft cap, inventory 1_000.
fun setup_vesting_sale_with(test: &mut Scenario, clk: &Clock, params: VParams) {
    let ctx = test.ctx();
    let (mut sale, cap) = prefunded_sale::create_sale<
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
        ctx,
    );
    sale.deposit(u::sale_balance(1_000));
    sale.set_vesting_schedule_params(params);
    let (vault, vault_cap) = refund_vault::new<USDC>(ctx);
    sale.pair_refund_vault(&vault, vault_cap);
    let ticket = fixed_rate_curve::activation_ticket(&sale);
    sale.share_and_activate(vault, ticket, clk);
    transfer::public_transfer(cap, u::admin());
}

// A vesting sale with the default 4-step (monthly-ish) schedule.
fun setup_vesting_sale(test: &mut Scenario, clk: &Clock) {
    setup_vesting_sale_with(test, clk, vesting_wallet_linear::params(0, 0, 1_000, 4));
}

// === claim ===

#[test]
fun claim_returns_allocation_and_draws_inventory() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 2, 1_000, 0, 2_000);
    buy_once(&mut test, &clk, 100); // alloc = 200
    finalize_now(&mut test, &mut clk);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    let r = test.take_from_address<Receipt<SALE>>(u::buyer());
    let receipt_id = object::id(&r);
    let payout = sale.claim(r, test.ctx());
    assert_eq!(payout.value(), 200);
    assert_eq!(sale.total_allocated(), 0);
    assert_eq!(sale.inventory_total(), 1_800); // 2_000 - 200 drawn

    let claimed = event::events_by_type<prefunded_sale::Claimed<SALE, USDC>>();
    assert_eq!(claimed.length(), 1);
    assert_eq!(
        claimed[0],
        prefunded_sale::test_new_claimed<SALE, USDC>(
            object::id(&sale),
            u::buyer(),
            receipt_id,
            200,
        ),
    );
    destroy(payout);
    u::return_sale(sale);

    destroy(clk);
    test.end();
}

#[test]
fun claim_all_sums_receipts() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 100);
    buy_once(&mut test, &clk, 250);
    finalize_now(&mut test, &mut clk);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    let r1 = test.take_from_address<Receipt<SALE>>(u::buyer());
    let r2 = test.take_from_address<Receipt<SALE>>(u::buyer());
    let payout = sale.claim_all(vector[r1, r2], test.ctx());
    assert_eq!(payout.value(), 350);
    assert_eq!(sale.total_allocated(), 0);
    destroy(payout);
    u::return_sale(sale);

    destroy(clk);
    test.end();
}

// claim by a non-buyer is rejected.
#[test, expected_failure(abort_code = prefunded_sale::EBuyerOnly)]
fun claim_wrong_buyer_aborts() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 100);
    finalize_now(&mut test, &mut clk);

    test.next_tx(u::buyer2()); // wrong sender
    let mut sale = u::take_sale(&test);
    let r = test.take_from_address<Receipt<SALE>>(u::buyer());
    let _payout = sale.claim(r, test.ctx()); // aborts: EBuyerOnly
    abort
}

// A receipt issued by a different sale is rejected.
#[test, expected_failure(abort_code = prefunded_sale::EReceiptSaleMismatch)]
fun claim_foreign_receipt_aborts() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 100);
    finalize_now(&mut test, &mut clk);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    // A receipt minted against a foreign sale id (package-internal helper).
    let foreign = receipt::new_receipt<SALE>(
        object::id_from_address(@0xDEAD),
        u::buyer(),
        100,
        100,
        1_000,
        test.ctx(),
    );
    let _payout = sale.claim(foreign, test.ctx()); // aborts: EReceiptSaleMismatch
    abort
}

// claim before the sale is finalized is rejected.
#[test, expected_failure(abort_code = prefunded_sale::ENotFinalized)]
fun claim_before_finalize_aborts() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 100);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    let r = test.take_from_address<Receipt<SALE>>(u::buyer());
    let _payout = sale.claim(r, test.ctx()); // aborts: ENotFinalized
    abort
}

// claim_all before the sale is finalized is rejected (the batch guard in
// claim_all_internal, ahead of the per-receipt claim_internal guard).
#[test, expected_failure(abort_code = prefunded_sale::ENotFinalized)]
fun claim_all_before_finalize_aborts() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 100);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    let r = test.take_from_address<Receipt<SALE>>(u::buyer());
    let _payout = sale.claim_all(vector[r], test.ctx()); // aborts: ENotFinalized
    abort
}

// === Vesting routing ===

// A vesting-attached sale rejects the plain claim path.
#[test, expected_failure(abort_code = prefunded_sale::EClaimRequiresVesting)]
fun claim_with_vesting_attached_aborts() {
    let (mut test, mut clk) = u::setup();
    setup_vesting_sale(&mut test, &clk);
    buy_once(&mut test, &clk, 100);
    finalize_now(&mut test, &mut clk);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    let r = test.take_from_address<Receipt<SALE>>(u::buyer());
    let _payout = sale.claim(r, test.ctx()); // aborts: EClaimRequiresVesting
    abort
}

// The batch claim path enforces the same non-vesting requirement as `claim`.
#[test, expected_failure(abort_code = prefunded_sale::EClaimRequiresVesting)]
fun claim_all_with_vesting_attached_aborts() {
    let (mut test, mut clk) = u::setup();
    setup_vesting_sale(&mut test, &clk);
    buy_once(&mut test, &clk, 100);
    finalize_now(&mut test, &mut clk);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    let r = test.take_from_address<Receipt<SALE>>(u::buyer());
    let _payout = sale.claim_all(vector[r], test.ctx()); // aborts: EClaimRequiresVesting
    abort
}

// claim_into_vesting funds a wallet with the allocation, beneficiary = buyer.
#[test]
fun claim_into_vesting_returns_funded_wallet() {
    let (mut test, mut clk) = u::setup();
    setup_vesting_sale(&mut test, &clk);
    buy_once(&mut test, &clk, 100); // rate 1 -> alloc 100
    finalize_now(&mut test, &mut clk);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    let r = test.take_from_address<Receipt<SALE>>(u::buyer());
    let (wallet, destroy_cap) = prefunded_sale::claim_into_vesting<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(&mut sale, r, test.ctx());
    assert_eq!(wallet.balance(), 100);
    assert_eq!(wallet.beneficiary(), u::buyer());
    assert_eq!(sale.total_allocated(), 0);
    destroy(wallet);
    destroy(destroy_cap);
    u::return_sale(sale);

    destroy(clk);
    test.end();
}

// claim_all_into_vesting funds one wallet with the summed allocations.
#[test]
fun claim_all_into_vesting_sums_into_one_wallet() {
    let (mut test, mut clk) = u::setup();
    setup_vesting_sale(&mut test, &clk);
    buy_once(&mut test, &clk, 100);
    buy_once(&mut test, &clk, 250);
    finalize_now(&mut test, &mut clk);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    let r1 = test.take_from_address<Receipt<SALE>>(u::buyer());
    let r2 = test.take_from_address<Receipt<SALE>>(u::buyer());
    let (wallet, destroy_cap) = prefunded_sale::claim_all_into_vesting<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(&mut sale, vector[r1, r2], test.ctx());
    assert_eq!(wallet.balance(), 350);
    assert_eq!(wallet.beneficiary(), u::buyer());
    assert_eq!(sale.total_allocated(), 0);
    destroy(wallet);
    destroy(destroy_cap);
    u::return_sale(sale);

    destroy(clk);
    test.end();
}

// Regression (H-1): the vesting lockup cannot be bypassed. `claim_into_vesting` pins
// the sale's `Linear` witness (the `&mut sale` argument unifies the function's
// `VestingWitness` with the sale's), so the buyer must release through the honest
// curve, which enforces the cliff. Right after finalize nothing is releasable; only
// after the cliff elapses does the allocation unlock. A buyer-supplied witness that
// ignored the schedule would not type-check, so the "release everything immediately"
// attack has no on-chain path.
#[test]
fun vesting_lockup_holds_through_pinned_witness() {
    let (mut test, mut clk) = u::setup();
    // Cliff one full period long: nothing vests until start(=OPENS) + 100_000.
    setup_vesting_sale_with(
        &mut test,
        &clk,
        vesting_wallet_linear::params(u::opens(), 100_000, 100_000, 1),
    );
    buy_once(&mut test, &clk, 100); // rate 1 -> alloc 100
    finalize_now(&mut test, &mut clk); // clk -> 5_001, still far below the cliff

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    let r = test.take_from_address<Receipt<SALE>>(u::buyer());
    let (wallet, destroy_cap) = prefunded_sale::claim_into_vesting<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(&mut sale, r, test.ctx());

    // Cliff not reached: the honest curve releases nothing (the exploit wanted 100 here).
    assert_eq!(vesting_wallet_linear::releasable(&wallet, &clk), 0);

    // Past the cliff: the full allocation unlocks - on the issuer's schedule, not early.
    clk.set_for_testing(u::opens() + 100_000);
    assert_eq!(vesting_wallet_linear::releasable(&wallet, &clk), 100);

    destroy(wallet);
    destroy(destroy_cap);
    u::return_sale(sale);
    destroy(clk);
    test.end();
}

// claim_into_vesting on a non-vesting sale is rejected.
#[test, expected_failure(abort_code = prefunded_sale::ENoVestingScheduleAttached)]
fun claim_into_vesting_without_schedule_aborts() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 100);
    finalize_now(&mut test, &mut clk);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    let r = test.take_from_address<Receipt<SALE>>(u::buyer());
    let (_wallet, _destroy_cap) = prefunded_sale::claim_into_vesting<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(&mut sale, r, test.ctx()); // aborts: ENoVestingScheduleAttached
    abort
}

// The batch vesting path enforces the same schedule requirement as claim_into_vesting.
#[test, expected_failure(abort_code = prefunded_sale::ENoVestingScheduleAttached)]
fun claim_all_into_vesting_without_schedule_aborts() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 100);
    finalize_now(&mut test, &mut clk);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    let r = test.take_from_address<Receipt<SALE>>(u::buyer());
    let (_wallet, _destroy_cap) = prefunded_sale::claim_all_into_vesting<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(&mut sale, vector[r], test.ctx()); // aborts: ENoVestingScheduleAttached
    abort
}

// === refund ===

#[test]
fun refund_returns_paid_and_draws_vault() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 500, 1_000);
    buy_once(&mut test, &clk, 300); // below soft cap
    cancel_now(&mut test, &mut clk);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    let mut vault = u::take_vault(&test);
    let r = test.take_from_address<Receipt<SALE>>(u::buyer());
    let receipt_id = object::id(&r);
    let payment = sale.refund(&mut vault, r, test.ctx());
    assert_eq!(payment.value(), 300);
    assert_eq!(vault.value(), 0); // drained exactly
    assert_eq!(sale.total_allocated(), 0);

    let refunded = event::events_by_type<prefunded_sale::Refunded<SALE, USDC>>();
    assert_eq!(refunded.length(), 1);
    assert_eq!(
        refunded[0],
        prefunded_sale::test_new_refunded<SALE, USDC>(
            object::id(&sale),
            u::buyer(),
            receipt_id,
            300,
        ),
    );
    // refund releases the payment out of the vault (VaultRelease 300, nothing left).
    let releases = event::events_by_type<refund_vault::VaultRelease<USDC>>();
    assert_eq!(releases.length(), 1);
    assert_eq!(releases[0], refund_vault::test_new_vault_release<USDC>(object::id(&vault), 300, 0));
    destroy(payment);
    u::return_sale(sale);
    u::return_vault(vault);

    destroy(clk);
    test.end();
}

// refund has its own receipt-sale check (ahead of the buyer check): a receipt
// from a different sale is rejected even on the cancel path.
#[test, expected_failure(abort_code = prefunded_sale::EReceiptSaleMismatch)]
fun refund_foreign_receipt_aborts() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 500, 1_000);
    buy_once(&mut test, &clk, 300); // below soft cap
    cancel_now(&mut test, &mut clk);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    let mut vault = u::take_vault(&test);
    // A receipt minted against a foreign sale id (package-internal helper).
    let foreign = receipt::new_receipt<SALE>(
        object::id_from_address(@0xDEAD),
        u::buyer(),
        300,
        300,
        1_000,
        test.ctx(),
    );
    let _payment = sale.refund(&mut vault, foreign, test.ctx()); // aborts: EReceiptSaleMismatch
    abort
}

#[test, expected_failure(abort_code = prefunded_sale::EBuyerOnly)]
fun refund_wrong_buyer_aborts() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 500, 1_000);
    buy_once(&mut test, &clk, 300);
    cancel_now(&mut test, &mut clk);

    test.next_tx(u::buyer2()); // wrong sender
    let mut sale = u::take_sale(&test);
    let mut vault = u::take_vault(&test);
    let r = test.take_from_address<Receipt<SALE>>(u::buyer());
    let _payment = sale.refund(&mut vault, r, test.ctx()); // aborts
    abort
}

// refund is rejected unless the sale is Cancelled.
#[test, expected_failure(abort_code = prefunded_sale::ENotCancelled)]
fun refund_before_cancel_aborts() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 100);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    let mut vault = u::take_vault(&test);
    let r = test.take_from_address<Receipt<SALE>>(u::buyer());
    let _payment = sale.refund(&mut vault, r, test.ctx()); // aborts: ENotCancelled
    abort
}

// refund rejects a vault that is not the paired one (reached after the phase /
// receipt-sale / buyer checks pass).
#[test, expected_failure(abort_code = prefunded_sale::EWrongVault)]
fun refund_wrong_vault_aborts() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 500, 1_000);
    buy_once(&mut test, &clk, 300); // below soft cap
    cancel_now(&mut test, &mut clk);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    let (mut foreign_vault, _foreign_cap) = refund_vault::new<USDC>(test.ctx());
    let r = test.take_from_address<Receipt<SALE>>(u::buyer());
    let _payment = sale.refund(&mut foreign_vault, r, test.ctx()); // aborts: EWrongVault
    abort
}

// === refund_all ===

// refund_all sums the paid amounts of several receipts into one payment and
// releases exactly that much from the vault.
#[test]
fun refund_all_sums_receipts() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 500, 1_000);
    buy_once(&mut test, &clk, 100);
    buy_once(&mut test, &clk, 250); // raised 350 < soft cap 500
    cancel_now(&mut test, &mut clk);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    let mut vault = u::take_vault(&test);
    let r1 = test.take_from_address<Receipt<SALE>>(u::buyer());
    let r2 = test.take_from_address<Receipt<SALE>>(u::buyer());
    let payment = sale.refund_all(&mut vault, vector[r1, r2], test.ctx());
    assert_eq!(payment.value(), 350);
    assert_eq!(vault.value(), 0); // drained exactly
    assert_eq!(sale.total_allocated(), 0);
    destroy(payment);
    u::return_sale(sale);
    u::return_vault(vault);

    destroy(clk);
    test.end();
}

// refund_all before the sale is cancelled is rejected (the batch's own phase guard,
// ahead of the per-receipt guard in `refund`).
#[test, expected_failure(abort_code = prefunded_sale::ENotCancelled)]
fun refund_all_before_cancel_aborts() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 100);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    let mut vault = u::take_vault(&test);
    let r = test.take_from_address<Receipt<SALE>>(u::buyer());
    let _payment = sale.refund_all(&mut vault, vector[r], test.ctx()); // aborts: ENotCancelled
    abort
}

// refund_all with no receipts returns an empty balance (the batch loop is a no-op).
#[test]
fun refund_all_empty_returns_zero() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 500, 1_000);
    buy_once(&mut test, &clk, 300); // below soft cap
    cancel_now(&mut test, &mut clk);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    let mut vault = u::take_vault(&test);
    let payment = sale.refund_all(&mut vault, vector<Receipt<SALE>>[], test.ctx());
    assert_eq!(payment.value(), 0);
    destroy(payment);
    u::return_sale(sale);
    u::return_vault(vault);

    destroy(clk);
    test.end();
}

// === withdraw_proceeds ===

#[test]
fun withdraw_proceeds_returns_raised() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 400);
    finalize_now(&mut test, &mut clk);

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let cap = u::take_cap(&test);
    let proceeds = sale.withdraw_proceeds(&cap);
    assert_eq!(proceeds.value(), 400);
    assert_eq!(sale.proceeds_amount(), 0);

    let withdrawn = event::events_by_type<prefunded_sale::ProceedsWithdrawn<SALE, USDC>>();
    assert_eq!(withdrawn.length(), 1);
    assert_eq!(
        withdrawn[0],
        prefunded_sale::test_new_proceeds_withdrawn<SALE, USDC>(object::id(&sale), 400),
    );
    destroy(proceeds);
    u::return_sale(sale);
    u::return_cap(cap);

    destroy(clk);
    test.end();
}

// A second withdrawal (proceeds already drained) is a no-op: returns an empty
// balance and emits no additional ProceedsWithdrawn event.
#[test]
fun withdraw_proceeds_twice_second_is_noop() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 400);
    finalize_now(&mut test, &mut clk);

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let cap = u::take_cap(&test);
    let first = sale.withdraw_proceeds(&cap);
    let second = sale.withdraw_proceeds(&cap);
    assert_eq!(first.value(), 400);
    assert_eq!(second.value(), 0);

    // Only the first (non-zero) withdrawal emitted an event.
    let withdrawn = event::events_by_type<prefunded_sale::ProceedsWithdrawn<SALE, USDC>>();
    assert_eq!(withdrawn.length(), 1);

    destroy(first);
    destroy(second);
    u::return_sale(sale);
    u::return_cap(cap);
    destroy(clk);
    test.end();
}

#[test, expected_failure(abort_code = prefunded_sale::EWrongAdminCap)]
fun withdraw_proceeds_wrong_cap_aborts() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 400);
    finalize_now(&mut test, &mut clk);

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
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
    let _proceeds = sale.withdraw_proceeds(&foreign_cap); // aborts
    abort
}

// withdraw_proceeds requires Finalized (not Active).
#[test, expected_failure(abort_code = prefunded_sale::ENotFinalized)]
fun withdraw_proceeds_before_finalize_aborts() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 400);

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let cap = u::take_cap(&test);
    let _proceeds = sale.withdraw_proceeds(&cap); // aborts: ENotFinalized
    abort
}

// === withdraw_unsold_inventory ===

// Only the unallocated slack is withdrawn; outstanding allocations stay backed.
#[test]
fun withdraw_unsold_returns_only_slack() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 2, 1_000, 0, 2_000);
    buy_once(&mut test, &clk, 100); // alloc 200
    finalize_now(&mut test, &mut clk);

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let cap = u::take_cap(&test);
    let unsold = sale.withdraw_unsold_inventory(&cap);
    assert_eq!(unsold.value(), 1_800); // 2_000 - 200 allocated
    assert_eq!(sale.inventory_remaining(), 0);
    assert_eq!(sale.total_allocated(), 200); // receipt still backed

    let withdrawn = event::events_by_type<prefunded_sale::InventoryWithdrawn<SALE, USDC>>();
    assert_eq!(withdrawn.length(), 1);
    assert_eq!(
        withdrawn[0],
        prefunded_sale::test_new_inventory_withdrawn<SALE, USDC>(object::id(&sale), 1_800),
    );
    destroy(unsold);
    u::return_sale(sale);
    u::return_cap(cap);

    destroy(clk);
    test.end();
}

// A second withdrawal (slack already drained) is a no-op: returns an empty balance
// and emits no additional InventoryWithdrawn event.
#[test]
fun withdraw_unsold_twice_second_is_noop() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 2, 1_000, 0, 2_000);
    buy_once(&mut test, &clk, 100); // alloc 200
    finalize_now(&mut test, &mut clk);

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let cap = u::take_cap(&test);
    let first = sale.withdraw_unsold_inventory(&cap);
    let second = sale.withdraw_unsold_inventory(&cap);
    assert_eq!(first.value(), 1_800);
    assert_eq!(second.value(), 0);

    // Only the first (non-zero) withdrawal emitted an event.
    let withdrawn = event::events_by_type<prefunded_sale::InventoryWithdrawn<SALE, USDC>>();
    assert_eq!(withdrawn.length(), 1);

    destroy(first);
    destroy(second);
    u::return_sale(sale);
    u::return_cap(cap);
    destroy(clk);
    test.end();
}

#[test, expected_failure(abort_code = prefunded_sale::EWrongAdminCap)]
fun withdraw_unsold_wrong_cap_aborts() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 100);
    finalize_now(&mut test, &mut clk);

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
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
    let _unsold = sale.withdraw_unsold_inventory(&foreign_cap); // aborts
    abort
}

// withdraw_unsold_inventory is valid in the Cancelled terminal phase (not only
// Finalized), and the admin recovers freed inventory as buyers refund: each refund
// releases the receipt's allocation back into the withdrawable slack.
#[test]
fun withdraw_unsold_in_cancelled_recovers_freed_inventory() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 2, 1_000, 500, 2_000);
    buy_once(&mut test, &clk, 300); // alloc = 600; raised 300 < soft cap 500
    cancel_now(&mut test, &mut clk);

    // Admin withdraws only the truly-unsold slack; the outstanding receipt stays backed.
    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let cap = u::take_cap(&test);
    let slack = sale.withdraw_unsold_inventory(&cap);
    assert_eq!(slack.value(), 1_400); // 2_000 - 600 allocated
    assert_eq!(sale.total_allocated(), 600);
    assert_eq!(sale.inventory_remaining(), 0);
    destroy(slack);
    u::return_sale(sale);
    u::return_cap(cap);

    // Buyer refunds: the allocation is released back into inventory slack.
    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    let mut vault = u::take_vault(&test);
    let r = test.take_from_address<Receipt<SALE>>(u::buyer());
    let payment = sale.refund(&mut vault, r, test.ctx());
    assert_eq!(payment.value(), 300);
    assert_eq!(sale.total_allocated(), 0);
    destroy(payment);
    u::return_sale(sale);
    u::return_vault(vault);

    // Admin can now recover the freed allocation.
    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let cap = u::take_cap(&test);
    let freed = sale.withdraw_unsold_inventory(&cap);
    assert_eq!(freed.value(), 600);
    assert_eq!(sale.inventory_total(), 0);
    destroy(freed);
    u::return_sale(sale);
    u::return_cap(cap);

    destroy(clk);
    test.end();
}

// withdraw_unsold_inventory is phase-gated to terminal states; calling it while the
// sale is still Active aborts (ENotTerminal) - the sibling of withdraw_proceeds's
// ENotFinalized guard, which was the only terminal-gate failure previously tested.
#[test, expected_failure(abort_code = prefunded_sale::ENotTerminal)]
fun withdraw_unsold_before_terminal_aborts() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    buy_once(&mut test, &clk, 100);

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let cap = u::take_cap(&test);
    let _unsold = sale.withdraw_unsold_inventory(&cap); // aborts: ENotTerminal (still Active)
    abort
}

// claim_all with no receipts returns an empty balance (the batch loop is a no-op).
#[test]
fun claim_all_empty_returns_zero() {
    let (mut test, mut clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);
    // No purchases; soft_cap 0, so finalize succeeds once the window closes.
    finalize_now(&mut test, &mut clk);

    test.next_tx(u::buyer());
    let mut sale = u::take_sale(&test);
    let payout = sale.claim_all(vector<Receipt<SALE>>[], test.ctx());
    assert_eq!(payout.value(), 0);
    destroy(payout);
    u::return_sale(sale);

    destroy(clk);
    test.end();
}

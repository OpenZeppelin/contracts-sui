module openzeppelin_sale::example_kyc_registry_tests;

use openzeppelin_finance::vesting_wallet;
use openzeppelin_finance::vesting_wallet_linear::{Self as linear, Linear, Params as VParams};
use openzeppelin_sale::example_kyc_registry::{Self, KycRegistry, KycAdminCap};
use openzeppelin_sale::fixed_rate_curve::{Self, FixedRateCurve, Params as FrcParams};
use openzeppelin_sale::prefunded_sale::{Self, PrefundedSale};
use openzeppelin_sale::receipt::Receipt;
use openzeppelin_sale::refund_vault::{Self, RefundVault};
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::clock::{Self, Clock};
use sui::test_scenario as ts;

/// The sale token (distributed into a vesting wallet at claim).
public struct SALE has drop {}
/// The payment coin (collected as proceeds / refunded on a soft-cap miss).
public struct USDC has drop {}

const ADMIN: address = @0xAD; // issuer + compliance operator
const BUYER: address = @0xB0B;

// A compliance-gated strategic round: fixed rate, cumulative per-buyer cap, a soft
// cap, and a linear vesting lockup that begins when the window closes.
const RATE: u64 = 2; // SALE per 1 USDC
const HARD_CAP: u64 = 1_000;
const SOFT_CAP: u64 = 300;
const PER_BUYER_CAP: u64 = 400; // cumulative anti-whale bound, enforced by the sale
const INVENTORY: u64 = 2_000; // == HARD_CAP * RATE
const OPENS: u64 = 1_000;
const CLOSES: u64 = 5_000;
const VEST_START: u64 = 5_000; // lockup begins at close
const VEST_DURATION: u64 = 4_000;

// === Setup helpers ===

// Spelled-out concrete sale type (Move 2024 has no type aliases).
fun take_sale(
    scenario: &ts::Scenario,
): PrefundedSale<FixedRateCurve, FrcParams, SALE, USDC, Linear, VParams> {
    ts::take_shared<PrefundedSale<FixedRateCurve, FrcParams, SALE, USDC, Linear, VParams>>(scenario)
}

// Issuer flow, threaded as one transaction: create the strategic-round sale, fund it,
// configure the cumulative per-buyer cap and the vesting lockup, enable the allowlist,
// wrap the returned admin in a KYC registry, then pair a vault and activate. Leaves the
// sale, vault, and registry shared; the sale + KYC caps go to ADMIN.
fun launch(scenario: &mut ts::Scenario, clk: &Clock) {
    let ctx = scenario.ctx();
    let (mut sale, sale_cap) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(
        fixed_rate_curve::params(RATE),
        HARD_CAP,
        SOFT_CAP,
        OPENS,
        CLOSES,
        ctx,
    );
    sale.deposit(balance::create_for_testing<SALE>(INVENTORY));
    sale.set_per_buyer_cap(PER_BUYER_CAP, ctx);
    sale.set_vesting_schedule(linear::vesting_schedule_continuous(VEST_START, 0, VEST_DURATION));

    // The single mint authority never leaves the shared registry.
    let allow_admin = sale.enable_allowlist(ctx);
    let kyc_cap = example_kyc_registry::new(allow_admin, ctx);

    let (vault, vault_cap) = refund_vault::new<USDC>(ctx);
    sale.pair_refund_vault(&vault, vault_cap);
    let ticket = fixed_rate_curve::activation_ticket(&sale);
    sale.share_and_activate(vault, ticket, clk);

    transfer::public_transfer(sale_cap, ADMIN);
    transfer::public_transfer(kyc_cap, ADMIN);
}

// Operator clears `buyer` on the registry (cap-gated).
fun approve(scenario: &mut ts::Scenario, buyer: address) {
    scenario.next_tx(ADMIN);
    let mut registry = scenario.take_shared<KycRegistry<SALE>>();
    let cap = scenario.take_from_sender<KycAdminCap>();
    registry.approve(&cap, buyer);
    ts::return_shared(registry);
    ts::return_to_address(ADMIN, cap);
}

// A cleared buyer self-serves an `AllowEntry` and spends it on `purchase`, all in one
// PTB - exactly how a wallet would compose the two calls.
fun buy(scenario: &mut ts::Scenario, buyer: address, paid: u64, clk: &Clock) {
    scenario.next_tx(buyer);
    let registry = scenario.take_shared<KycRegistry<SALE>>();
    let mut sale = take_sale(scenario);
    let entry = example_kyc_registry::request_entry(&registry, scenario.ctx());
    let quote = fixed_rate_curve::quote(&sale, balance::create_for_testing<USDC>(paid));
    sale.purchase(quote, option::some(entry), clk, scenario.ctx());
    ts::return_shared(sale);
    ts::return_shared(registry);
}

// === Tests ===

// End-to-end happy path: a KYC-cleared buyer purchases, the sale finalizes, and the
// allocation is redeemed into a vesting wallet whose lockup releases on schedule. The
// KYC decision made at `approve` carries all the way to the buyer-bound wallet.
#[test]
fun cleared_buyer_purchases_and_vests() {
    let mut scenario = ts::begin(ADMIN);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(OPENS);

    launch(&mut scenario, &clk);
    approve(&mut scenario, BUYER);
    buy(&mut scenario, BUYER, PER_BUYER_CAP, &clk); // 400 USDC: meets soft cap, hits per-buyer cap

    // Window closes above the soft cap -> permissionless finalize.
    clk.set_for_testing(CLOSES + 1);
    scenario.next_tx(ADMIN);
    {
        let mut sale = take_sale(&scenario);
        let mut vault = scenario.take_shared<RefundVault<USDC>>();
        sale.finalize(&mut vault, &clk);
        ts::return_shared(sale);
        ts::return_shared(vault);
    };

    // Buyer redeems the receipt into a vesting wallet (the only path on a vesting sale).
    scenario.next_tx(BUYER);
    let mut sale = take_sale(&scenario);
    let receipt = scenario.take_from_sender<Receipt<SALE>>();
    let (wallet, destroy_cap) = prefunded_sale::claim_into_vesting(
        &mut sale,
        receipt,
        scenario.ctx(),
    );
    ts::return_shared(sale);

    // The wallet holds the full allocation and is bound to the buyer.
    assert_eq!(wallet.balance(), PER_BUYER_CAP * RATE); // 800 SALE
    assert_eq!(wallet.beneficiary(), BUYER);

    // The lockup releases linearly over the vesting window. Just after it starts
    // (the clock is at CLOSES + 1), nothing has vested yet.
    assert_eq!(linear::releasable(&wallet, &clk), 0);
    clk.set_for_testing(VEST_START + VEST_DURATION / 2);
    assert_eq!(linear::releasable(&wallet, &clk), PER_BUYER_CAP * RATE / 2); // 400 SALE
    clk.set_for_testing(VEST_START + VEST_DURATION);
    assert_eq!(linear::releasable(&wallet, &clk), PER_BUYER_CAP * RATE); // 800 SALE

    destroy(wallet);
    destroy(destroy_cap);
    destroy(clk);
    scenario.end();
}

// Losing the KycAdminCap does not brick purchases. The mint authority lives inside the
// shared registry, so a buyer cleared before the loss can still self-serve an entry and
// buy - only future approvals and revocations are forfeited. This is the structural
// improvement over holding the raw `AllowlistAdmin`, whose loss aborts every purchase.
#[test]
fun lost_admin_cap_does_not_block_cleared_buyer() {
    let mut scenario = ts::begin(ADMIN);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(OPENS);

    launch(&mut scenario, &clk);
    approve(&mut scenario, BUYER);

    // The operator irrecoverably loses the cap (modelled by destroying it).
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<KycAdminCap>();
    destroy(cap);

    // The already-cleared buyer purchases anyway: `request_entry` reads the wrapped
    // admin in the shared registry and needs no cap.
    buy(&mut scenario, BUYER, PER_BUYER_CAP, &clk);

    // The buyer received their receipt for the full purchase.
    scenario.next_tx(BUYER);
    let sale = take_sale(&scenario);
    let receipt = scenario.take_from_sender<Receipt<SALE>>();
    assert_eq!(sale.raised(), PER_BUYER_CAP);
    assert_eq!(receipt.paid(), PER_BUYER_CAP);
    assert_eq!(receipt.allocation(), PER_BUYER_CAP * RATE);
    ts::return_shared(sale);

    destroy(receipt);
    destroy(clk);
    scenario.end();
}

// An address that was never cleared cannot mint an entry, so it can never purchase.
#[test, expected_failure(abort_code = example_kyc_registry::EBuyerNotApproved)]
fun uncleared_buyer_cannot_request_entry() {
    let mut scenario = ts::begin(ADMIN);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(OPENS);

    launch(&mut scenario, &clk);

    // No `approve` for BUYER: requesting an entry aborts.
    scenario.next_tx(BUYER);
    let registry = scenario.take_shared<KycRegistry<SALE>>();
    let _entry = example_kyc_registry::request_entry(&registry, scenario.ctx());

    abort
}

// Revocation is forward-looking: once dropped, a buyer can no longer mint entries.
#[test, expected_failure(abort_code = example_kyc_registry::EBuyerNotApproved)]
fun revoked_buyer_cannot_request_entry() {
    let mut scenario = ts::begin(ADMIN);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(OPENS);

    launch(&mut scenario, &clk);
    approve(&mut scenario, BUYER);

    scenario.next_tx(ADMIN);
    let mut registry = scenario.take_shared<KycRegistry<SALE>>();
    let cap = scenario.take_from_sender<KycAdminCap>();
    registry.revoke(&cap, BUYER);
    ts::return_shared(registry);
    ts::return_to_address(ADMIN, cap);

    scenario.next_tx(BUYER);
    let registry = scenario.take_shared<KycRegistry<SALE>>();
    let _entry = example_kyc_registry::request_entry(&registry, scenario.ctx());

    abort
}

// A soft-cap miss cancels the sale; a cleared buyer recovers exactly what they paid.
#[test]
fun soft_cap_miss_refunds_cleared_buyer() {
    let mut scenario = ts::begin(ADMIN);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(OPENS);

    launch(&mut scenario, &clk);
    approve(&mut scenario, BUYER);
    buy(&mut scenario, BUYER, 200, &clk); // 200 < SOFT_CAP

    // Window closes below the soft cap -> permissionless cancel.
    clk.set_for_testing(CLOSES + 1);
    scenario.next_tx(ADMIN);
    {
        let mut sale = take_sale(&scenario);
        let mut vault = scenario.take_shared<RefundVault<USDC>>();
        sale.cancel_after_close(&mut vault, &clk);
        ts::return_shared(sale);
        ts::return_shared(vault);
    };

    // Buyer refunds against the receipt.
    scenario.next_tx(BUYER);
    let mut sale = take_sale(&scenario);
    let mut vault = scenario.take_shared<RefundVault<USDC>>();
    let receipt = scenario.take_from_sender<Receipt<SALE>>();
    let refund = sale.refund(&mut vault, receipt, scenario.ctx());
    assert_eq!(refund.value(), 200);
    ts::return_shared(sale);
    ts::return_shared(vault);

    destroy(refund);
    destroy(clk);
    scenario.end();
}

// A cap from one registry cannot manage a different registry.
#[test, expected_failure(abort_code = example_kyc_registry::EWrongRegistry)]
fun foreign_cap_cannot_approve() {
    let mut scenario = ts::begin(ADMIN);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(OPENS);

    // Two independent strategic rounds; capture registry A before B exists.
    launch(&mut scenario, &clk);
    scenario.next_tx(ADMIN);
    let id_a = ts::most_recent_id_shared<KycRegistry<SALE>>().destroy_some();

    launch(&mut scenario, &clk);
    scenario.next_tx(ADMIN);

    let mut registry_a = scenario.take_shared_by_id<KycRegistry<SALE>>(id_a);
    // ADMIN holds two caps; the most recent belongs to registry B.
    let cap_b = scenario.take_from_sender<KycAdminCap>();

    registry_a.approve(&cap_b, BUYER);

    abort
}

// `approve` / `revoke` toggle membership and are each idempotent.
#[test]
fun approve_and_revoke_toggle_membership() {
    let mut scenario = ts::begin(ADMIN);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(OPENS);

    launch(&mut scenario, &clk);

    scenario.next_tx(ADMIN);
    let mut registry = scenario.take_shared<KycRegistry<SALE>>();
    let cap = scenario.take_from_sender<KycAdminCap>();

    assert!(!registry.is_approved(BUYER));
    assert_eq!(registry.approved_count(), 0);

    registry.approve(&cap, BUYER);
    registry.approve(&cap, BUYER); // idempotent
    assert!(registry.is_approved(BUYER));
    assert_eq!(registry.approved_count(), 1);

    registry.revoke(&cap, BUYER);
    registry.revoke(&cap, BUYER); // idempotent
    assert!(!registry.is_approved(BUYER));
    assert_eq!(registry.approved_count(), 0);

    ts::return_shared(registry);
    ts::return_to_address(ADMIN, cap);
    destroy(clk);
    scenario.end();
}

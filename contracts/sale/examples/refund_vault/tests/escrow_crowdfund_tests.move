// Tests for the standalone refundable-escrow crowdfund example.
//
// They pin the two settlement paths the vault's state machine forks into -
// success (Active -> Closed, whole pot to the beneficiary) and failure
// (Active -> Refunding, each backer reclaims their exact pledge) - plus the
// accounting the example exists to demonstrate: the campaign's per-backer
// ledger stays in lockstep with the vault's pooled balance, so refunds are
// exact and cannot be double-spent. Failing tests cover the full error surface.
//
// Payouts leave via `balance::send_funds`, crediting address balances that the
// unit-test VM cannot read back as coins; following the finance `example_splitter`
// and `vesting_wallet` convention, each payout is attested by its event (amount +
// recipient) together with the vault draining to zero.
//
// Self-contained: a local coin marker and `test_scenario` for the shared
// campaign + vault.
module openzeppelin_sale::example_escrow_crowdfund_tests;

use openzeppelin_sale::example_escrow_crowdfund::{
    Self as crowdfund,
    Campaign,
    CampaignFinalized,
    Refunded,
};
use openzeppelin_sale::refund_vault::{Self, RefundVault};
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::clock::{Self, Clock};
use sui::event;
use sui::test_scenario::{Self as ts, Scenario};

// === Markers ===

/// The pledge coin.
public struct USDC has drop {}

const CREATOR: address = @0xC0;
const BENEFICIARY: address = @0xBE;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const CAROL: address = @0xCa401;

const GOAL: u64 = 1_000;
const OPENS: u64 = 1_000;
const DEADLINE: u64 = 5_000;
const AFTER_DEADLINE: u64 = 5_001;

// === Success path ===

// Goal met by two backers: finalize credits the entire pot to the beneficiary
// and closes the vault. Nothing is left behind.
#[test]
fun success_pays_beneficiary() {
    let mut scenario = ts::begin(CREATOR);
    let mut clock = new_clock(&mut scenario);

    open_default(&mut scenario, &clock, GOAL);
    pledge_as(&mut scenario, &clock, ALICE, 600);
    pledge_as(&mut scenario, &clock, BOB, 500); // total 1_100 >= goal

    clock.set_for_testing(AFTER_DEADLINE);

    scenario.next_tx(CAROL); // permissionless: any caller settles
    let mut campaign = ts::take_shared<Campaign<USDC>>(&scenario);
    let mut vault = ts::take_shared<RefundVault<USDC>>(&scenario);
    let campaign_id = object::id(&campaign);
    assert_eq!(vault.value(), 1_100);

    campaign.finalize(&mut vault, &clock);

    // The vault is drained and closed; the pot went to the beneficiary.
    assert_eq!(vault.value(), 0);
    assert!(vault.is_closed());
    assert_finalized(campaign_id, 1_100, BENEFICIARY);

    ts::return_shared(campaign);
    ts::return_shared(vault);
    destroy(clock);
    scenario.end();
}

// A pledge exactly equal to the goal succeeds (the `>=` boundary).
#[test]
fun goal_met_exactly_succeeds() {
    let mut scenario = ts::begin(CREATOR);
    let mut clock = new_clock(&mut scenario);

    open_default(&mut scenario, &clock, GOAL);
    pledge_as(&mut scenario, &clock, ALICE, GOAL);

    clock.set_for_testing(AFTER_DEADLINE);

    scenario.next_tx(ALICE);
    let mut campaign = ts::take_shared<Campaign<USDC>>(&scenario);
    let mut vault = ts::take_shared<RefundVault<USDC>>(&scenario);
    let campaign_id = object::id(&campaign);

    campaign.finalize(&mut vault, &clock);

    assert_eq!(vault.value(), 0);
    assert_finalized(campaign_id, GOAL, BENEFICIARY);

    ts::return_shared(campaign);
    ts::return_shared(vault);
    destroy(clock);
    scenario.end();
}

// === Failure path ===

// Goal missed: cancel opens refunding and each backer reclaims exactly what they
// pledged, draining the vault to zero.
#[test]
fun miss_refunds_each_backer_exactly() {
    let mut scenario = ts::begin(CREATOR);
    let mut clock = new_clock(&mut scenario);

    open_default(&mut scenario, &clock, GOAL);
    pledge_as(&mut scenario, &clock, ALICE, 300);
    pledge_as(&mut scenario, &clock, BOB, 200); // total 500 < goal

    clock.set_for_testing(AFTER_DEADLINE);
    cancel_by(&mut scenario, &clock, CAROL); // permissionless

    refund_backer(&mut scenario, ALICE, 300);
    refund_backer(&mut scenario, BOB, 200);

    // Vault fully drained after both refunds.
    scenario.next_tx(CREATOR);
    let vault = ts::take_shared<RefundVault<USDC>>(&scenario);
    assert_eq!(vault.value(), 0);
    assert!(vault.is_refunding());
    ts::return_shared(vault);

    destroy(clock);
    scenario.end();
}

// Repeated pledges by one backer accumulate into a single ledger entry, and one
// refund returns the whole cumulative amount.
#[test]
fun repeated_pledges_accumulate_then_refund_in_full() {
    let mut scenario = ts::begin(CREATOR);
    let mut clock = new_clock(&mut scenario);

    open_default(&mut scenario, &clock, GOAL);
    pledge_as(&mut scenario, &clock, ALICE, 100);
    pledge_as(&mut scenario, &clock, ALICE, 250); // total 350 < goal

    // Ledger reflects the accumulated pledge.
    scenario.next_tx(ALICE);
    let campaign = ts::take_shared<Campaign<USDC>>(&scenario);
    assert_eq!(campaign.pledge_of(ALICE), 350);
    ts::return_shared(campaign);

    clock.set_for_testing(AFTER_DEADLINE);
    cancel_by(&mut scenario, &clock, ALICE);

    refund_backer(&mut scenario, ALICE, 350);

    // The ledger entry is cleared by the refund.
    scenario.next_tx(ALICE);
    let campaign = ts::take_shared<Campaign<USDC>>(&scenario);
    assert_eq!(campaign.pledge_of(ALICE), 0);
    ts::return_shared(campaign);

    destroy(clock);
    scenario.end();
}

// === open validation ===

#[test, expected_failure(abort_code = crowdfund::EZeroGoal)]
fun open_zero_goal_aborts() {
    let mut scenario = ts::begin(CREATOR);
    let clock = new_clock(&mut scenario);
    let _ = crowdfund::open<USDC>(BENEFICIARY, 0, DEADLINE, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = crowdfund::EDeadlineInPast)]
fun open_deadline_in_past_aborts() {
    let mut scenario = ts::begin(CREATOR);
    let clock = new_clock(&mut scenario); // set to OPENS
    let _ = crowdfund::open<USDC>(BENEFICIARY, GOAL, OPENS, &clock, scenario.ctx());
    abort
}

// === pledge validation ===

#[test, expected_failure(abort_code = crowdfund::ECampaignClosed)]
fun pledge_after_deadline_aborts() {
    let mut scenario = ts::begin(CREATOR);
    let mut clock = new_clock(&mut scenario);
    open_default(&mut scenario, &clock, GOAL);

    clock.set_for_testing(AFTER_DEADLINE);
    pledge_as(&mut scenario, &clock, ALICE, 100);
    abort
}

#[test, expected_failure(abort_code = crowdfund::EZeroPledge)]
fun pledge_zero_aborts() {
    let mut scenario = ts::begin(CREATOR);
    let clock = new_clock(&mut scenario);
    open_default(&mut scenario, &clock, GOAL);

    scenario.next_tx(ALICE);
    let mut campaign = ts::take_shared<Campaign<USDC>>(&scenario);
    let mut vault = ts::take_shared<RefundVault<USDC>>(&scenario);
    campaign.pledge(&mut vault, balance::zero<USDC>(), &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = crowdfund::EWrongVault)]
fun pledge_wrong_vault_aborts() {
    let mut scenario = ts::begin(CREATOR);
    let clock = new_clock(&mut scenario);
    open_default(&mut scenario, &clock, GOAL);

    scenario.next_tx(ALICE);
    let mut campaign = ts::take_shared<Campaign<USDC>>(&scenario);
    // A foreign vault, not the one the campaign was opened with.
    let (mut wrong_vault, _wrong_cap) = refund_vault::new<USDC>(scenario.ctx());
    campaign.pledge(&mut wrong_vault, pay(100), &clock, scenario.ctx());
    abort
}

// === finalize / cancel validation ===

#[test, expected_failure(abort_code = crowdfund::EBeforeDeadline)]
fun finalize_before_deadline_aborts() {
    let mut scenario = ts::begin(CREATOR);
    let clock = new_clock(&mut scenario);
    open_default(&mut scenario, &clock, GOAL);
    pledge_as(&mut scenario, &clock, ALICE, GOAL);

    finalize_by(&mut scenario, &clock, ALICE); // still before deadline
    abort
}

#[test, expected_failure(abort_code = crowdfund::EGoalNotMet)]
fun finalize_goal_not_met_aborts() {
    let mut scenario = ts::begin(CREATOR);
    let mut clock = new_clock(&mut scenario);
    open_default(&mut scenario, &clock, GOAL);
    pledge_as(&mut scenario, &clock, ALICE, 500); // < goal

    clock.set_for_testing(AFTER_DEADLINE);
    finalize_by(&mut scenario, &clock, ALICE);
    abort
}

#[test, expected_failure(abort_code = crowdfund::EBeforeDeadline)]
fun cancel_before_deadline_aborts() {
    let mut scenario = ts::begin(CREATOR);
    let clock = new_clock(&mut scenario);
    open_default(&mut scenario, &clock, GOAL);

    cancel_by(&mut scenario, &clock, ALICE); // still before deadline
    abort
}

#[test, expected_failure(abort_code = crowdfund::EGoalMet)]
fun cancel_goal_met_aborts() {
    let mut scenario = ts::begin(CREATOR);
    let mut clock = new_clock(&mut scenario);
    open_default(&mut scenario, &clock, GOAL);
    pledge_as(&mut scenario, &clock, ALICE, GOAL); // == goal

    clock.set_for_testing(AFTER_DEADLINE);
    cancel_by(&mut scenario, &clock, ALICE);
    abort
}

// === refund validation ===

// Refunding before the campaign is cancelled hits the vault's own state gate:
// the vault is still Active, not Refunding.
#[test, expected_failure(abort_code = refund_vault::ENotRefundingState)]
fun refund_before_cancel_aborts() {
    let mut scenario = ts::begin(CREATOR);
    let mut clock = new_clock(&mut scenario);
    open_default(&mut scenario, &clock, GOAL);
    pledge_as(&mut scenario, &clock, ALICE, 500);

    clock.set_for_testing(AFTER_DEADLINE); // deadline passed, but no cancel yet
    scenario.next_tx(ALICE);
    let mut campaign = ts::take_shared<Campaign<USDC>>(&scenario);
    let mut vault = ts::take_shared<RefundVault<USDC>>(&scenario);
    campaign.refund(&mut vault, scenario.ctx());
    abort
}

// A caller who never pledged has nothing to refund.
#[test, expected_failure(abort_code = crowdfund::ENoPledge)]
fun refund_without_pledge_aborts() {
    let mut scenario = ts::begin(CREATOR);
    let mut clock = new_clock(&mut scenario);
    open_default(&mut scenario, &clock, GOAL);
    pledge_as(&mut scenario, &clock, ALICE, 500);

    clock.set_for_testing(AFTER_DEADLINE);
    cancel_by(&mut scenario, &clock, CREATOR);

    // BOB never pledged.
    scenario.next_tx(BOB);
    let mut campaign = ts::take_shared<Campaign<USDC>>(&scenario);
    let mut vault = ts::take_shared<RefundVault<USDC>>(&scenario);
    campaign.refund(&mut vault, scenario.ctx());
    abort
}

// A second refund by the same backer finds the ledger entry already cleared.
#[test, expected_failure(abort_code = crowdfund::ENoPledge)]
fun double_refund_aborts() {
    let mut scenario = ts::begin(CREATOR);
    let mut clock = new_clock(&mut scenario);
    open_default(&mut scenario, &clock, GOAL);
    pledge_as(&mut scenario, &clock, ALICE, 500);

    clock.set_for_testing(AFTER_DEADLINE);
    cancel_by(&mut scenario, &clock, ALICE);

    refund_backer(&mut scenario, ALICE, 500);

    // Second attempt: entry was removed by the first refund.
    scenario.next_tx(ALICE);
    let mut campaign = ts::take_shared<Campaign<USDC>>(&scenario);
    let mut vault = ts::take_shared<RefundVault<USDC>>(&scenario);
    campaign.refund(&mut vault, scenario.ctx());
    abort
}

// === Helpers ===

fun new_clock(scenario: &mut Scenario): Clock {
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(OPENS);
    clock
}

fun pay(amount: u64): balance::Balance<USDC> {
    balance::create_for_testing<USDC>(amount)
}

fun open_default(scenario: &mut Scenario, clock: &Clock, goal: u64) {
    let _ = crowdfund::open<USDC>(BENEFICIARY, goal, DEADLINE, clock, scenario.ctx());
}

fun pledge_as(scenario: &mut Scenario, clock: &Clock, backer: address, amount: u64) {
    scenario.next_tx(backer);
    let mut campaign = ts::take_shared<Campaign<USDC>>(scenario);
    let mut vault = ts::take_shared<RefundVault<USDC>>(scenario);
    campaign.pledge(&mut vault, pay(amount), clock, scenario.ctx());
    ts::return_shared(campaign);
    ts::return_shared(vault);
}

fun finalize_by(scenario: &mut Scenario, clock: &Clock, caller: address) {
    scenario.next_tx(caller);
    let mut campaign = ts::take_shared<Campaign<USDC>>(scenario);
    let mut vault = ts::take_shared<RefundVault<USDC>>(scenario);
    campaign.finalize(&mut vault, clock);
    ts::return_shared(campaign);
    ts::return_shared(vault);
}

fun cancel_by(scenario: &mut Scenario, clock: &Clock, caller: address) {
    scenario.next_tx(caller);
    let mut campaign = ts::take_shared<Campaign<USDC>>(scenario);
    let mut vault = ts::take_shared<RefundVault<USDC>>(scenario);
    campaign.cancel(&mut vault, clock);
    ts::return_shared(campaign);
    ts::return_shared(vault);
}

// Refund `backer` and attest, via the `Refunded` event, that exactly `expected`
// was credited back to them.
fun refund_backer(scenario: &mut Scenario, backer: address, expected: u64) {
    scenario.next_tx(backer);
    let mut campaign = ts::take_shared<Campaign<USDC>>(scenario);
    let mut vault = ts::take_shared<RefundVault<USDC>>(scenario);
    let campaign_id = object::id(&campaign);
    campaign.refund(&mut vault, scenario.ctx());

    let refunded = event::events_by_type<Refunded<USDC>>();
    assert_eq!(refunded.length(), 1);
    assert_eq!(refunded[0], crowdfund::test_new_refunded<USDC>(campaign_id, backer, expected));

    ts::return_shared(campaign);
    ts::return_shared(vault);
}

// Attest the single `CampaignFinalized` event emitted in the current transaction.
fun assert_finalized(campaign_id: ID, raised: u64, beneficiary: address) {
    let finalized = event::events_by_type<CampaignFinalized<USDC>>();
    assert_eq!(finalized.length(), 1);
    assert_eq!(
        finalized[0],
        crowdfund::test_new_campaign_finalized<USDC>(campaign_id, raised, beneficiary),
    );
}

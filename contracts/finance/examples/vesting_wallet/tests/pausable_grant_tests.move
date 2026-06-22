module openzeppelin_finance::example_pausable_grant_tests;

use openzeppelin_finance::example_pausable_grant::{Self, PausableGrant, GrantAdminCap};
use openzeppelin_finance::vesting_wallet::{Self, VestingWallet};
use openzeppelin_finance::vesting_wallet_linear::{Self as linear, Linear, Params};
use std::unit_test::{assert_eq, destroy};
use sui::coin::{Self, Coin};
use sui::test_scenario as ts;

/// Phantom coin marker for the vested asset.
public struct USDC has drop {}

const EMPLOYER: address = @0xE;
const BENEFICIARY: address = @0xB0B;

const START_MS: u64 = 1_000;
const DURATION_MS: u64 = 4_000;
const TOTAL: u64 = 1_000_000;

// Build a continuous-linear wallet, fund it, wrap it in a pausable grant, and share.
// The grant stays generic over the curve - it only sees `VestingWallet<Linear, ..>`.
fun create_grant(scenario: &mut ts::Scenario) {
    let params = linear::params_continuous(START_MS, 0, DURATION_MS);
    let mut wallet = vesting_wallet::new<Linear, Params, USDC>(
        params,
        BENEFICIARY,
        scenario.ctx(),
    );
    wallet.deposit(coin::mint_for_testing<USDC>(TOTAL, scenario.ctx()));
    let cap = example_pausable_grant::new(wallet, scenario.ctx());
    transfer::public_transfer(cap, EMPLOYER);
}

// Evaluate the curve through the grant's immutable `inner()` view, then release
// through the grant's own `release`. The caller never touches `&mut inner`.
fun release(
    grant: &mut PausableGrant<Linear, Params, USDC>,
    clock: &sui::clock::Clock,
    ctx: &mut TxContext,
) {
    let vested = linear::vested_amount(grant.inner(), clock);
    grant.release(&vested, ctx);
}

// Happy path: a curve-agnostic release flows through the wrapper to the beneficiary.
#[test]
fun release_flows_through_wrapper_to_beneficiary() {
    let mut scenario = ts::begin(EMPLOYER);
    let mut clock = sui::clock::create_for_testing(scenario.ctx());

    create_grant(&mut scenario);
    scenario.next_tx(BENEFICIARY);

    let mut grant = scenario.take_shared<PausableGrant<Linear, Params, USDC>>();
    assert!(!grant.is_paused());

    // Halfway through the linear schedule: half is releasable.
    clock.set_for_testing(START_MS + DURATION_MS / 2);
    release(&mut grant, &clock, scenario.ctx());

    scenario.next_tx(BENEFICIARY);
    let paid = scenario.take_from_address<Coin<USDC>>(BENEFICIARY);
    assert_eq!(paid.value(), TOTAL / 2);

    destroy(paid);
    ts::return_shared(grant);
    sui::clock::destroy_for_testing(clock);
    scenario.end();
}

// While paused, `release` aborts `EPaused` even though the curve has vested funds.
#[test, expected_failure(abort_code = example_pausable_grant::EPaused)]
fun release_aborts_while_paused() {
    let mut scenario = ts::begin(EMPLOYER);
    let mut clock = sui::clock::create_for_testing(scenario.ctx());

    create_grant(&mut scenario);
    scenario.next_tx(EMPLOYER);

    let mut grant = scenario.take_shared<PausableGrant<Linear, Params, USDC>>();
    let cap = scenario.take_from_sender<GrantAdminCap>();

    grant.pause(&cap);
    assert!(grant.is_paused());

    clock.set_for_testing(START_MS + DURATION_MS / 2);
    release(&mut grant, &clock, scenario.ctx());

    abort
}

// Pausing then resuming restores releases: the frozen stream continues where it left
// off, and what accrued during the pause is still claimable afterward.
#[test]
fun resume_restores_releases() {
    let mut scenario = ts::begin(EMPLOYER);
    let mut clock = sui::clock::create_for_testing(scenario.ctx());

    create_grant(&mut scenario);
    scenario.next_tx(EMPLOYER);

    let mut grant = scenario.take_shared<PausableGrant<Linear, Params, USDC>>();
    let cap = scenario.take_from_sender<GrantAdminCap>();

    // Pause before any release, let the schedule run to the end, then resume.
    grant.pause(&cap);
    clock.set_for_testing(START_MS + DURATION_MS);
    grant.resume(&cap);

    // The full total is now releasable in one go.
    release(&mut grant, &clock, scenario.ctx());

    scenario.next_tx(BENEFICIARY);
    let paid = scenario.take_from_address<Coin<USDC>>(BENEFICIARY);
    assert_eq!(paid.value(), TOTAL);

    destroy(paid);
    destroy(cap);
    ts::return_shared(grant);
    sui::clock::destroy_for_testing(clock);
    scenario.end();
}

// Teardown through the wrapper: the admin dissolves the grant with `unwrap`, recovering
// the bare wallet, then the curve module finalizes teardown. `linear::destroy` is
// beneficiary-gated, so the admin first forwards the drained wallet to the beneficiary -
// the custodial-holder hand-off linear's teardown docs describe.
#[test]
fun unwrap_then_curve_teardown() {
    let mut scenario = ts::begin(EMPLOYER);
    let mut clock = sui::clock::create_for_testing(scenario.ctx());

    create_grant(&mut scenario);
    scenario.next_tx(BENEFICIARY);

    // Drain the grant at the end of the schedule.
    let mut grant = scenario.take_shared<PausableGrant<Linear, Params, USDC>>();
    clock.set_for_testing(START_MS + DURATION_MS);
    release(&mut grant, &clock, scenario.ctx());

    // Admin dissolves the wrapper, recovering the bare wallet, and forwards it to the
    // beneficiary so the beneficiary-gated curve teardown can run.
    scenario.next_tx(EMPLOYER);
    let cap = scenario.take_from_sender<GrantAdminCap>();
    let wallet = grant.unwrap(cap);
    transfer::public_transfer(wallet, BENEFICIARY);

    // Beneficiary finalizes: permissionless `destroy_empty` for the receipt, then the
    // curve's witness-gated `destroy`.
    scenario.next_tx(BENEFICIARY);
    let wallet = scenario.take_from_sender<VestingWallet<Linear, Params, USDC>>();
    let receipt = wallet.destroy_empty();
    linear::destroy(receipt, &clock, scenario.ctx());

    sui::clock::destroy_for_testing(clock);
    scenario.end();
}

// An admin cap from one grant cannot unwrap a different grant.
#[test, expected_failure(abort_code = example_pausable_grant::EWrongGrant)]
fun foreign_cap_cannot_unwrap() {
    let mut scenario = ts::begin(EMPLOYER);

    // Two independent grants; the cap from the second is taken below.
    create_grant(&mut scenario);
    scenario.next_tx(EMPLOYER);
    let id_a = ts::most_recent_id_shared<PausableGrant<Linear, Params, USDC>>().destroy_some();

    create_grant(&mut scenario);
    scenario.next_tx(EMPLOYER);

    let grant_a = ts::take_shared_by_id<PausableGrant<Linear, Params, USDC>>(&scenario, id_a);
    // The sender holds two caps; the most recent one belongs to grant B.
    let cap_b = scenario.take_from_sender<GrantAdminCap>();

    let wallet = grant_a.unwrap(cap_b);
    transfer::public_transfer(wallet, BENEFICIARY);

    abort
}

// An admin cap from one grant cannot pause a different grant.
#[test, expected_failure(abort_code = example_pausable_grant::EWrongGrant)]
fun foreign_cap_cannot_pause() {
    let mut scenario = ts::begin(EMPLOYER);

    // Two independent grants; the cap from the second is taken below.
    create_grant(&mut scenario);
    scenario.next_tx(EMPLOYER);
    let id_a = ts::most_recent_id_shared<PausableGrant<Linear, Params, USDC>>().destroy_some();

    create_grant(&mut scenario);
    scenario.next_tx(EMPLOYER);

    let mut grant_a = ts::take_shared_by_id<PausableGrant<Linear, Params, USDC>>(&scenario, id_a);
    // The sender holds two caps; the most recent one belongs to grant B.
    let cap_b = scenario.take_from_sender<GrantAdminCap>();

    grant_a.pause(&cap_b);

    abort
}

// An admin cap from one grant cannot resume a different grant.
#[test, expected_failure(abort_code = example_pausable_grant::EWrongGrant)]
fun foreign_cap_cannot_resume() {
    let mut scenario = ts::begin(EMPLOYER);

    // Two independent grants; the cap from the second is taken below.
    create_grant(&mut scenario);
    scenario.next_tx(EMPLOYER);
    let id_a = ts::most_recent_id_shared<PausableGrant<Linear, Params, USDC>>().destroy_some();

    create_grant(&mut scenario);
    scenario.next_tx(EMPLOYER);

    let mut grant_a = ts::take_shared_by_id<PausableGrant<Linear, Params, USDC>>(&scenario, id_a);
    // The sender holds two caps; the most recent one belongs to grant B.
    let cap_b = scenario.take_from_sender<GrantAdminCap>();

    grant_a.resume(&cap_b);

    abort
}

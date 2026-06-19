module openzeppelin_finance::example_vesting_quadratic_tests;

use openzeppelin_finance::example_vesting_quadratic::{Self as quadratic, Quadratic, Params};
use openzeppelin_finance::vesting_wallet::{Self, VestingWallet};
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

// Build, fund, and share a quadratic-vesting wallet by composing the schedule module
// (`params`) with `vesting_wallet` directly - the schedule module never wraps `new`,
// `deposit`, or `public_share_object`.
fun create_and_share(scenario: &mut ts::Scenario) {
    let params = quadratic::params(START_MS, DURATION_MS);
    let mut wallet = vesting_wallet::new<Quadratic, Params, USDC>(
        params,
        BENEFICIARY,
        scenario.ctx(),
    );
    wallet.deposit(coin::mint_for_testing<USDC>(TOTAL, scenario.ctx()));
    transfer::public_share_object(wallet);
}

// Happy path: the integrator drives the full lifecycle across both modules. The curve
// is zero before start, follows total*(elapsed/duration)^2 mid-schedule, and clamps
// to the total at the end.
#[test]
fun compose_create_fund_and_release_across_modules() {
    let mut scenario = ts::begin(EMPLOYER);
    let mut clock = sui::clock::create_for_testing(scenario.ctx());

    create_and_share(&mut scenario);
    scenario.next_tx(BENEFICIARY);

    let mut wallet = scenario.take_shared<VestingWallet<Quadratic, Params, USDC>>();

    // Before start: nothing vested.
    clock.set_for_testing(START_MS);
    assert_eq!(quadratic::releasable(&wallet, &clock), 0);

    // Quarter way through (elapsed/duration = 1/4): vested = total * 1/16.
    clock.set_for_testing(START_MS + DURATION_MS / 4);
    assert_eq!(quadratic::releasable(&wallet, &clock), TOTAL / 16);

    // Halfway (1/2): vested = total * 1/4. Release it; the beneficiary is paid the
    // cumulative-minus-released portion.
    clock.set_for_testing(START_MS + DURATION_MS / 2);
    assert_eq!(quadratic::releasable(&wallet, &clock), TOTAL / 4);
    let vested = quadratic::vested_amount(&wallet, &clock);
    vesting_wallet::release(&mut wallet, &vested, scenario.ctx());
    assert_eq!(wallet.released(), TOTAL / 4);

    // After end: everything remaining is releasable, draining the wallet.
    clock.set_for_testing(START_MS + DURATION_MS);
    assert_eq!(quadratic::releasable(&wallet, &clock), TOTAL - TOTAL / 4);
    quadratic_release(&mut wallet, &clock, scenario.ctx());
    assert_eq!(wallet.released(), TOTAL);
    assert_eq!(wallet.balance(), 0);

    // The beneficiary received exactly the total across the two releases.
    scenario.next_tx(BENEFICIARY);
    let paid = scenario.take_from_address<Coin<USDC>>(BENEFICIARY);
    let paid_2 = scenario.take_from_address<Coin<USDC>>(BENEFICIARY);
    assert_eq!(paid.value() + paid_2.value(), TOTAL);

    destroy(paid);
    destroy(paid_2);
    ts::return_shared(wallet);
    sui::clock::destroy_for_testing(clock);
    scenario.end();
}

// The curve is monotonically non-decreasing: vested(t2) >= vested(t1) for t2 > t1,
// across the whole schedule. (Sampled at every 1/8 of the duration.)
#[test]
fun curve_is_monotonic() {
    let mut scenario = ts::begin(EMPLOYER);
    let mut clock = sui::clock::create_for_testing(scenario.ctx());

    create_and_share(&mut scenario);
    scenario.next_tx(BENEFICIARY);

    let wallet = scenario.take_shared<VestingWallet<Quadratic, Params, USDC>>();

    let mut prev = 0;
    let mut step = 0;
    while (step <= 8) {
        clock.set_for_testing(START_MS + DURATION_MS * step / 8);
        let now = quadratic::releasable(&wallet, &clock);
        assert!(now >= prev);
        prev = now;
        step = step + 1;
    };

    ts::return_shared(wallet);
    sui::clock::destroy_for_testing(clock);
    scenario.end();
}

// A deposit made after the schedule starts participates retroactively: the curve
// re-derives `total` from `balance + released` on every call.
#[test]
fun late_deposit_vests_at_current_proportion() {
    let mut scenario = ts::begin(EMPLOYER);
    let mut clock = sui::clock::create_for_testing(scenario.ctx());

    create_and_share(&mut scenario);
    scenario.next_tx(BENEFICIARY);

    let mut wallet = scenario.take_shared<VestingWallet<Quadratic, Params, USDC>>();

    // Halfway through, top up by the original total. New total is 2*TOTAL, and the
    // halfway proportion (1/4) applies to all of it.
    clock.set_for_testing(START_MS + DURATION_MS / 2);
    wallet.deposit(coin::mint_for_testing<USDC>(TOTAL, scenario.ctx()));
    assert_eq!(quadratic::releasable(&wallet, &clock), 2 * TOTAL / 4);

    ts::return_shared(wallet);
    sui::clock::destroy_for_testing(clock);
    scenario.end();
}

// `params` rejects a zero duration.
#[test, expected_failure(abort_code = quadratic::EZeroDuration)]
fun params_rejects_zero_duration() {
    quadratic::params(START_MS, 0);
}

// `params` rejects a schedule whose end would overflow `u64`.
#[test, expected_failure(abort_code = quadratic::EScheduleOverflow)]
fun params_rejects_overflowing_end() {
    quadratic::params(std::u64::max_value!(), 1);
}

// Evaluate the curve and release in one step - the common path, composed at the call
// site rather than wrapped in the schedule module.
fun quadratic_release(
    wallet: &mut VestingWallet<Quadratic, Params, USDC>,
    clock: &sui::clock::Clock,
    ctx: &mut TxContext,
) {
    let vested = quadratic::vested_amount(wallet, clock);
    vesting_wallet::release(wallet, &vested, ctx);
}

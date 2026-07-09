module openzeppelin_finance::example_vesting_quadratic_tests;

use openzeppelin_finance::example_vesting_quadratic::{Self as quadratic, Quadratic, Params};
use openzeppelin_finance::vesting_wallet::{Self, VestingWallet, DestroyCap, Released};
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::event;
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
    let (mut wallet, cap) = vesting_wallet::new<Quadratic, Params, USDC>(
        params,
        BENEFICIARY,
        scenario.ctx(),
    );
    wallet.deposit(balance::create_for_testing<USDC>(TOTAL));
    transfer::public_share_object(wallet);
    // Park the teardown cap with the beneficiary; the teardown test takes it from there.
    transfer::public_transfer(cap, BENEFICIARY);
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
    let wallet_id = object::id(&wallet);

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
    wallet.release(&vested);
    assert_eq!(wallet.released(), TOTAL / 4);

    // After end: everything remaining is releasable, draining the wallet.
    clock.set_for_testing(START_MS + DURATION_MS);
    assert_eq!(quadratic::releasable(&wallet, &clock), TOTAL - TOTAL / 4);
    quadratic_release(&mut wallet, &clock);
    assert_eq!(wallet.released(), TOTAL);
    assert_eq!(wallet.balance(), 0);

    // The beneficiary was paid exactly the total across the two releases, attested
    // by the two `Released` events: TOTAL / 4 then the remainder.
    let released = event::events_by_type<Released<Quadratic, USDC>>();
    assert_eq!(released.length(), 2);
    assert_eq!(
        released[0],
        vesting_wallet::test_new_released<Quadratic, USDC>(wallet_id, BENEFICIARY, TOTAL / 4),
    );
    assert_eq!(
        released[1],
        vesting_wallet::test_new_released<Quadratic, USDC>(
            wallet_id,
            BENEFICIARY,
            TOTAL - TOTAL / 4,
        ),
    );

    ts::return_shared(wallet);
    destroy(clock);
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
    destroy(clock);
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
    wallet.deposit(balance::create_for_testing<USDC>(TOTAL));
    assert_eq!(quadratic::releasable(&wallet, &clock), 2 * TOTAL / 4);

    ts::return_shared(wallet);
    destroy(clock);
    scenario.end();
}

// The schedule readers expose the otherwise-private `Params` to integrators.
#[test]
fun schedule_getters_expose_params() {
    let mut scenario = ts::begin(EMPLOYER);

    create_and_share(&mut scenario);
    scenario.next_tx(BENEFICIARY);

    let wallet = scenario.take_shared<VestingWallet<Quadratic, Params, USDC>>();
    assert_eq!(quadratic::start_ms(&wallet), START_MS);
    assert_eq!(quadratic::duration_ms(&wallet), DURATION_MS);
    assert_eq!(quadratic::end_ms(&wallet), START_MS + DURATION_MS);

    ts::return_shared(wallet);
    scenario.end();
}

// Teardown is composed across modules too: the integrator drains the wallet, calls the
// permissionless `vesting_wallet::destroy_empty` for a receipt, then hands it to this
// module's witness-gated `destroy` to finalize.
#[test]
fun compose_destroy_after_drain() {
    let mut scenario = ts::begin(EMPLOYER);
    let mut clock = sui::clock::create_for_testing(scenario.ctx());

    create_and_share(&mut scenario);
    scenario.next_tx(BENEFICIARY);

    let mut wallet = scenario.take_shared<VestingWallet<Quadratic, Params, USDC>>();
    let wallet_id = object::id(&wallet);

    // Run to the end and drain the wallet.
    clock.set_for_testing(START_MS + DURATION_MS);
    quadratic_release(&mut wallet, &clock);
    assert_eq!(wallet.balance(), 0);

    // The single release paid the full total to the beneficiary.
    let released = event::events_by_type<Released<Quadratic, USDC>>();
    assert_eq!(released.length(), 1);
    assert_eq!(
        released[0],
        vesting_wallet::test_new_released<Quadratic, USDC>(wallet_id, BENEFICIARY, TOTAL),
    );

    // Permissionless half reclaims the storage rebate; the gated half consumes the
    // receipt with the wallet's `DestroyCap` (parked with the beneficiary by
    // `create_and_share`) and enforces the ended gate.
    // TODO: use `destroy_empty` with a real `AccumulatorRoot` once
    // `accumulator::create_for_testing` ships in the published Sui mainnet framework.
    let cap = scenario.take_from_sender<DestroyCap>();
    let receipt = wallet.destroy_empty_for_testing();
    quadratic::destroy(receipt, cap, &clock);

    destroy(clock);
    scenario.end();
}

// `destroy` vetoes a teardown attempted before the schedule has ended, reverting the
// whole PTB (including the `destroy_empty` that produced the receipt).
#[test, expected_failure(abort_code = quadratic::ENotEnded)]
fun destroy_aborts_before_end() {
    let mut scenario = ts::begin(BENEFICIARY);
    let mut clock = sui::clock::create_for_testing(scenario.ctx());

    // An unfunded wallet is already empty, so `destroy_empty` succeeds - but the clock
    // sits before the schedule's end, so `destroy` aborts on the ended gate.
    let (wallet, cap) = vesting_wallet::new<Quadratic, Params, USDC>(
        quadratic::params(START_MS, DURATION_MS),
        BENEFICIARY,
        scenario.ctx(),
    );
    clock.set_for_testing(START_MS + DURATION_MS - 1);

    // TODO: use `destroy_empty` with a real `AccumulatorRoot` once
    // `accumulator::create_for_testing` ships in the published Sui mainnet framework.
    let receipt = wallet.destroy_empty_for_testing();
    quadratic::destroy(receipt, cap, &clock);

    abort
}

// Teardown is authorized by the matching `DestroyCap`, not the caller's address: a cap
// minted for a different wallet is rejected even on a drained, ended wallet. (Replaces
// the old beneficiary-gate test - the curve no longer checks `ctx.sender()`.)
#[test, expected_failure(abort_code = vesting_wallet::EWrongCap)]
fun destroy_rejects_wrong_cap() {
    let mut scenario = ts::begin(EMPLOYER);
    let mut clock = sui::clock::create_for_testing(scenario.ctx());

    let (wallet, _cap) = vesting_wallet::new<Quadratic, Params, USDC>(
        quadratic::params(START_MS, DURATION_MS),
        BENEFICIARY,
        scenario.ctx(),
    );
    // A second, independent wallet's cap is foreign to the first.
    let (_other, other_cap) = vesting_wallet::new<Quadratic, Params, USDC>(
        quadratic::params(START_MS, DURATION_MS),
        BENEFICIARY,
        scenario.ctx(),
    );
    clock.set_for_testing(START_MS + DURATION_MS); // after end, so the ended gate cannot fire first

    // TODO: use `destroy_empty` with a real `AccumulatorRoot` once
    // `accumulator::create_for_testing` ships in the published Sui mainnet framework.
    let receipt = wallet.destroy_empty_for_testing();
    quadratic::destroy(receipt, other_cap, &clock);

    abort
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
) {
    let vested = quadratic::vested_amount(wallet, clock);
    wallet.release(&vested);
}

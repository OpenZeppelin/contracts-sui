module openzeppelin_access::example_timelocked_treasury_tests;

use openzeppelin_access::delayed_transfer::{Self as delayed, DelayedTransferWrapper};
use openzeppelin_access::example_timelocked_treasury::{Self as vault, Treasury, TreasuryKey};
use std::unit_test::{assert_eq, destroy};
use sui::clock;
use sui::coin;
use sui::sui::SUI;
use sui::test_scenario as ts;

const OWNER: address = @0xA;
const NEW_OWNER: address = @0xB;

// Three-day custody delay, in milliseconds.
const DELAY: u64 = 3 * 24 * 60 * 60 * 1_000;

// Operation never waits, but a custody change does: withdraw through the wrapper
// immediately, then move the key to a new owner only after the delay elapses.
#[test]
fun scheduled_transfer_executes_after_delay() {
    let mut scenario = ts::begin(OWNER);
    let mut clock = clock::create_for_testing(scenario.ctx());

    let key = vault::new(coin::mint_for_testing<SUI>(1_000, scenario.ctx()), scenario.ctx());
    delayed::wrap(key, DELAY, OWNER, scenario.ctx());

    scenario.next_tx(OWNER);
    let mut wrapper = scenario.take_from_sender<DelayedTransferWrapper<TreasuryKey>>();

    // Day-to-day withdrawal works without waiting on the timelock.
    let mut treasury = scenario.take_shared<Treasury>();
    destroy(treasury.withdraw_wrapped(&wrapper, 100, scenario.ctx()));
    assert_eq!(treasury.available(), 900);
    ts::return_shared(treasury);

    // Custody change: schedule, wait out the delay, then execute.
    wrapper.schedule_transfer(NEW_OWNER, &clock, scenario.ctx());
    clock.increment_for_testing(DELAY);
    wrapper.execute_transfer(&clock, scenario.ctx());

    // The new owner now controls the treasury through the wrapper.
    scenario.next_tx(NEW_OWNER);
    let mut wrapper = scenario.take_from_sender<DelayedTransferWrapper<TreasuryKey>>();
    let mut treasury = scenario.take_shared<Treasury>();
    destroy(treasury.withdraw_wrapped(&wrapper, 50, scenario.ctx()));
    assert_eq!(treasury.available(), 850);
    ts::return_shared(treasury);

    // Tidy up by reclaiming the bare key (itself delayed) and discarding it.
    wrapper.schedule_unwrap(&clock, scenario.ctx());
    clock.increment_for_testing(DELAY);
    destroy(wrapper.unwrap(&clock, scenario.ctx()));

    destroy(clock);
    scenario.end();
}

// Self-recovery: the holder schedules an unwrap, waits, and pulls the bare key back out.
#[test]
fun scheduled_unwrap_recovers_the_key() {
    let mut scenario = ts::begin(OWNER);
    let mut clock = clock::create_for_testing(scenario.ctx());

    let key = vault::new(coin::mint_for_testing<SUI>(1_000, scenario.ctx()), scenario.ctx());
    delayed::wrap(key, DELAY, OWNER, scenario.ctx());

    scenario.next_tx(OWNER);
    let mut wrapper = scenario.take_from_sender<DelayedTransferWrapper<TreasuryKey>>();
    wrapper.schedule_unwrap(&clock, scenario.ctx());
    clock.increment_for_testing(DELAY);
    let key = wrapper.unwrap(&clock, scenario.ctx());

    // With the bare key reclaimed, the owner withdraws directly.
    let mut treasury = scenario.take_shared<Treasury>();
    destroy(treasury.withdraw(&key, 200, scenario.ctx()));
    assert_eq!(treasury.available(), 800);
    ts::return_shared(treasury);

    destroy(key);
    destroy(clock);
    scenario.end();
}

// Executing before the delay elapses is rejected.
#[test, expected_failure(abort_code = delayed::EDelayNotElapsed)]
fun execute_before_delay_aborts() {
    let mut scenario = ts::begin(OWNER);
    let mut clock = clock::create_for_testing(scenario.ctx());

    let key = vault::new(coin::mint_for_testing<SUI>(100, scenario.ctx()), scenario.ctx());
    delayed::wrap(key, DELAY, OWNER, scenario.ctx());

    scenario.next_tx(OWNER);
    let mut wrapper = scenario.take_from_sender<DelayedTransferWrapper<TreasuryKey>>();
    wrapper.schedule_transfer(NEW_OWNER, &clock, scenario.ctx());

    // One millisecond short of the deadline.
    clock.increment_for_testing(DELAY - 1);
    wrapper.execute_transfer(&clock, scenario.ctx());

    abort
}

// Cancelling clears the pending slot, so a fresh action can be scheduled afterwards.
#[test]
fun cancel_clears_pending_schedule() {
    let mut scenario = ts::begin(OWNER);
    let mut clock = clock::create_for_testing(scenario.ctx());

    let key = vault::new(coin::mint_for_testing<SUI>(100, scenario.ctx()), scenario.ctx());
    delayed::wrap(key, DELAY, OWNER, scenario.ctx());

    scenario.next_tx(OWNER);
    let mut wrapper = scenario.take_from_sender<DelayedTransferWrapper<TreasuryKey>>();
    wrapper.schedule_transfer(NEW_OWNER, &clock, scenario.ctx());
    wrapper.cancel_schedule();

    // The slot is free again: scheduling an unwrap would abort if it were not.
    wrapper.schedule_unwrap(&clock, scenario.ctx());
    clock.increment_for_testing(DELAY);
    destroy(wrapper.unwrap(&clock, scenario.ctx()));

    destroy(clock);
    scenario.end();
}

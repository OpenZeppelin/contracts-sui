module openzeppelin_utils::faucet_tests;

use openzeppelin_utils::faucet::{new, issue_claim_cap, Faucet, ClaimCap};
use openzeppelin_utils::rare_coin::{Self, RARE_COIN};
use openzeppelin_utils::rate_limiter;
use std::unit_test::{destroy, assert_eq};
use sui::coin::Coin;
use sui::test_scenario as ts;

const HOUR: u64 = 60 * 60 * 1000;

// Happy path: two holders claim against their own personal buckets and the shared global window.
// Each limiter debits independently, and the personal buckets refill over time.
#[test]
fun users_claim_when_respecting_all_limits() {
    let admin = @0xA;
    let user_1 = @0xB;
    let user_2 = @0xC;

    let mut scenario = ts::begin(admin);
    let mut clock = sui::clock::create_for_testing(scenario.ctx());

    rare_coin::init_for_testing(scenario.ctx());
    scenario.next_tx(admin);

    let rare_coins = scenario.take_from_sender<Coin<RARE_COIN>>();
    let admin_cap = new(rare_coins, &clock, scenario.ctx());

    scenario.next_tx(admin);

    // User 1: Personal cap of 60, refilling 10/sec.
    issue_claim_cap(&admin_cap, user_1, 60, 10, 1_000, &clock, scenario.ctx());
    // User 2: Personal cap of 50, refilling 15/sec.
    issue_claim_cap(&admin_cap, user_2, 50, 15, 1_000, &clock, scenario.ctx());

    scenario.next_tx(user_1);

    let mut faucet = scenario.take_shared<Faucet>();
    let mut cap_1 = scenario.take_from_sender<ClaimCap>();
    // The personal allowance binds well below the 100 global window.
    assert_eq!(cap_1.personal_allowance(&clock), 60);
    destroy(faucet.claim(&mut cap_1, 60, &clock, scenario.ctx()));
    assert_eq!(cap_1.personal_allowance(&clock), 0);
    // The global window only saw 60 consumed, so it still has 40.
    assert_eq!(faucet.global_allowance(&clock), 40);
    ts::return_shared(faucet);

    // The faucet will still permit the other user to claim.
    scenario.next_tx(user_2);

    let mut faucet = scenario.take_shared<Faucet>();
    let mut cap_2 = scenario.take_from_sender<ClaimCap>();

    assert_eq!(cap_2.personal_allowance(&clock), 50);
    destroy(faucet.claim(&mut cap_2, 40, &clock, scenario.ctx()));
    assert_eq!(cap_2.personal_allowance(&clock), 10);
    // The global window is now empty.
    assert_eq!(faucet.global_allowance(&clock), 0);

    // Confirm personal buckets refill appropriately.
    clock.increment_for_testing(2_000);
    assert_eq!(cap_1.personal_allowance(&clock), 20);
    assert_eq!(cap_2.personal_allowance(&clock), 40);

    destroy(cap_1);
    destroy(cap_2);
    destroy(admin_cap);
    ts::return_shared(faucet);
    sui::clock::destroy_for_testing(clock);
    scenario.end();
}

// When the personal bucket is the tighter limiter, `claim` aborts on the *personal* check (the
// first `consume_or_abort`) even though the global window still has room.
#[test, expected_failure(abort_code = rate_limiter::ERateLimited)]
fun personal_limit_binds_even_if_global_allows() {
    let admin = @0xA;
    let user = @0xB;

    let mut scenario = ts::begin(admin);
    let clock = sui::clock::create_for_testing(scenario.ctx());

    rare_coin::init_for_testing(scenario.ctx());
    scenario.next_tx(admin);

    let rare_coins = scenario.take_from_sender<Coin<RARE_COIN>>();
    let admin_cap = new(rare_coins, &clock, scenario.ctx());

    scenario.next_tx(admin);

    // User 1: Personal cap of 60, refilling 10/sec.
    issue_claim_cap(&admin_cap, user, 60, 10, 1_000, &clock, scenario.ctx());

    scenario.next_tx(user);

    let mut faucet = scenario.take_shared<Faucet>();
    let mut cap = scenario.take_from_sender<ClaimCap>();
    // The personal allowance binds well below the 100 global window.
    assert_eq!(cap.personal_allowance(&clock), 60);
    // But it hits the personal limit, thus aborting.
    destroy(faucet.claim(&mut cap, 100, &clock, scenario.ctx()));

    abort
}

// The mirror image of the previous test: when the personal bucket has room but the global
// window is empty, `claim` aborts on the *global* limiter (the second `consume_or_abort`).
#[test, expected_failure(abort_code = rate_limiter::ERateLimited)]
fun global_limit_binds_even_if_personal_allows() {
    let admin = @0xA;
    let user = @0xB;

    let mut scenario = ts::begin(admin);
    let clock = sui::clock::create_for_testing(scenario.ctx());

    rare_coin::init_for_testing(scenario.ctx());
    scenario.next_tx(admin);

    let rare_coins = scenario.take_from_sender<Coin<RARE_COIN>>();
    let admin_cap = new(rare_coins, &clock, scenario.ctx());

    scenario.next_tx(admin);

    // Personal cap of 200 — deliberately above the 100 global window, so the global cap binds first.
    issue_claim_cap(&admin_cap, user, 200, 10, 1_000, &clock, scenario.ctx());

    scenario.next_tx(user);

    let mut faucet = scenario.take_shared<Faucet>();
    let mut cap = scenario.take_from_sender<ClaimCap>();
    // Drain the global window to zero; the personal bucket still has 100 left.
    destroy(faucet.claim(&mut cap, 100, &clock, scenario.ctx()));
    assert_eq!(cap.personal_allowance(&clock), 100);
    assert_eq!(faucet.global_allowance(&clock), 0);
    // Personal allows this, but the global window is empty, so the global limiter aborts.
    destroy(faucet.claim(&mut cap, 1, &clock, scenario.ctx()));

    abort
}

// The global limiter is a fixed window: once a full `HOUR` elapses it rolls over to the
// full hourly allowance, regardless of how much was consumed in the prior window.
#[test]
fun global_window_resets_after_an_hour() {
    let admin = @0xA;
    let user = @0xB;

    let mut scenario = ts::begin(admin);
    let mut clock = sui::clock::create_for_testing(scenario.ctx());

    rare_coin::init_for_testing(scenario.ctx());
    scenario.next_tx(admin);

    let rare_coins = scenario.take_from_sender<Coin<RARE_COIN>>();
    let admin_cap = new(rare_coins, &clock, scenario.ctx());

    scenario.next_tx(admin);

    // Personal cap well above the global window so the global window is the only thing under test.
    issue_claim_cap(&admin_cap, user, 200, 10, 1_000, &clock, scenario.ctx());

    scenario.next_tx(user);

    let mut faucet = scenario.take_shared<Faucet>();
    let mut cap = scenario.take_from_sender<ClaimCap>();
    // Exhaust the global window.
    destroy(faucet.claim(&mut cap, 100, &clock, scenario.ctx()));
    assert_eq!(faucet.global_allowance(&clock), 0);

    // After a full hour the window rolls over to the full hourly allowance.
    clock.increment_for_testing(HOUR);
    assert_eq!(faucet.global_allowance(&clock), 100);

    // And claims succeed again against the fresh window.
    destroy(faucet.claim(&mut cap, 50, &clock, scenario.ctx()));
    assert_eq!(faucet.global_allowance(&clock), 50);

    destroy(cap);
    destroy(admin_cap);
    ts::return_shared(faucet);
    sui::clock::destroy_for_testing(clock);
    scenario.end();
}

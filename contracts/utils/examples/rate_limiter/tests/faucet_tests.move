module openzeppelin_utils::faucet_tests;

use openzeppelin_utils::faucet::{Self, new, issue_claim_cap, Faucet, ClaimCap};
use openzeppelin_utils::rare_coin::{Self, RARE_COIN};
use openzeppelin_utils::rate_limiter;
use std::unit_test::{destroy, assert_eq};
use sui::coin::{Self, Coin};
use sui::test_scenario as ts;

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

    let mut faucet = scenario.take_shared<Faucet>();
    // User 1: Personal cap of 60, refilling 10/sec.
    issue_claim_cap(&admin_cap, user_1, 60, 10, 1_000, &clock, scenario.ctx());
    // User 2: Personal cap of 50, refilling 15/sec.
    issue_claim_cap(&admin_cap, user_2, 50, 15, 1_000, &clock, scenario.ctx());

    scenario.next_tx(user_1);

    let mut cap_1 = scenario.take_from_sender<ClaimCap>();
    // The personal allowance binds well below the 100 global window.
    assert_eq!(cap_1.personal_allowance(&clock), 60);
    destroy(faucet.claim(&mut cap_1, 60, &clock, scenario.ctx()));
    assert_eq!(cap_1.personal_allowance(&clock), 0);
    // The global window only saw 60 consumed, so it still has 40.
    assert_eq!(faucet.global_allowance(&clock), 40);

    // the faucet will still permit the other user to claim
    scenario.next_tx(user_2);
    let mut cap_2 = scenario.take_from_sender<ClaimCap>();
    assert_eq!(cap_2.personal_allowance(&clock), 50);
    destroy(faucet.claim(&mut cap_2, 40, &clock, scenario.ctx()));
    assert_eq!(cap_2.personal_allowance(&clock), 10);
    // The global window is now empty
    assert_eq!(faucet.global_allowance(&clock), 0);

    // Confirm personal buckets refill appropriately
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

    let mut faucet = scenario.take_shared<Faucet>();
    // User 1: Personal cap of 60, refilling 10/sec.
    issue_claim_cap(&admin_cap, user, 60, 10, 1_000, &clock, scenario.ctx());

    scenario.next_tx(user);

    let mut cap = scenario.take_from_sender<ClaimCap>();
    // The personal allowance binds well below the 100 global window.
    assert_eq!(cap.personal_allowance(&clock), 60);
    // But it hits the personal limit, thus aborting
    destroy(faucet.claim(&mut cap, 100, &clock, scenario.ctx()));

    abort
}

module openzeppelin_utils::staking_vault_tests;

use openzeppelin_utils::rate_limiter;
use openzeppelin_utils::staking_vault::{new, StakingVault};
use std::unit_test::{destroy, assert_eq};
use sui::coin;
use sui::sui::SUI;
use sui::test_scenario as ts;

const UNBOND_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1000; // 7 days

#[test]
fun stake_unstake_then_claim_after_cooldown() {
    let staker = @0xA;

    let mut scenario = ts::begin(staker);
    let mut clock = sui::clock::create_for_testing(scenario.ctx());

    new(UNBOND_DELAY_MS, scenario.ctx());

    scenario.next_tx(staker);

    let mut vault = scenario.take_shared<StakingVault>();
    let payment = coin::mint_for_testing<SUI>(1_000, scenario.ctx());
    let receipt = vault.stake(payment, scenario.ctx());
    assert_eq!(receipt.amount(), 1_000);

    // Begin unstaking: the ticket's gate is armed to release a full delay from now.
    let ticket = vault.initiate_unstake(receipt, &clock, scenario.ctx());
    assert!(!ticket.is_claimable(&clock));

    // Once the unbonding delay elapses, the gate releases and the coins can be claimed.
    clock.increment_for_testing(UNBOND_DELAY_MS);
    assert!(ticket.is_claimable(&clock));

    let coins = ticket.claim(&clock, scenario.ctx());
    assert_eq!(coins.value(), 1_000);

    destroy(coins);
    ts::return_shared(vault);
    sui::clock::destroy_for_testing(clock);
    scenario.end();
}

#[test, expected_failure(abort_code = rate_limiter::ERateLimited)]
fun claim_before_cooldown_elapses_aborts() {
    let staker = @0xA;

    let mut scenario = ts::begin(staker);
    let clock = sui::clock::create_for_testing(scenario.ctx());

    new(UNBOND_DELAY_MS, scenario.ctx());

    scenario.next_tx(staker);

    let mut vault = scenario.take_shared<StakingVault>();
    let payment = coin::mint_for_testing<SUI>(1_000, scenario.ctx());
    let receipt = vault.stake(payment, scenario.ctx());

    let ticket = vault.initiate_unstake(receipt, &clock, scenario.ctx());
    assert!(!ticket.is_claimable(&clock));
    // The gate has not released yet, so claiming aborts `ERateLimited`.
    destroy(ticket.claim(&clock, scenario.ctx()));

    abort
}

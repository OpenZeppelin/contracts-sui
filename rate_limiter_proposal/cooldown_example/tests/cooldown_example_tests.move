#[test_only]
module cooldown_example::cooldown_example_tests;

use cooldown_example::cooldown;
use cooldown_example::vault;
use std::unit_test::assert_eq;
use sui::clock;
use sui::coin;
use sui::test_scenario;

#[test]
fun partial_withdrawal_succeeds() {
    let owner = @0x21;
    let withdrawer_a = @0x22;
    let withdrawer_b = @0x23;
    let mut test = test_scenario::begin(owner);
    let initial_vault = coin::mint_for_testing<sui::sui::SUI>(0, test.ctx());
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    // The owner creates a shared vault and a cooldown-based policy.
    vault::create_and_share(initial_vault, 0, 10, test.ctx());

    // Each depositor gets a separate cooldown state for future withdrawals.
    test.next_tx(withdrawer_a);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<cooldown::Policy<vault::WithdrawTag>>();
    let deposit_a = coin::mint_for_testing<sui::sui::SUI>(70, test.ctx());
    let state_a = vault::deposit(&mut vault, &policy, deposit_a, &clk, test.ctx());
    transfer::public_transfer(state_a, withdrawer_a);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);

    test.next_tx(withdrawer_b);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<cooldown::Policy<vault::WithdrawTag>>();
    let deposit_b = coin::mint_for_testing<sui::sui::SUI>(40, test.ctx());
    let state_b = vault::deposit(&mut vault, &policy, deposit_b, &clk, test.ctx());
    transfer::public_transfer(state_b, withdrawer_b);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);

    // Withdrawer A performs a first withdrawal and immediately enters cooldown.
    test.next_tx(withdrawer_a);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<cooldown::Policy<vault::WithdrawTag>>();
    let mut state_a = test.take_from_sender<cooldown::State<vault::WithdrawTag>>();
    let withdrawn = vault::withdraw(&mut vault, &policy, &mut state_a, 30, &clk, test.ctx());

    assert_eq!(coin::value(&withdrawn), 30);
    assert_eq!(vault::value(&vault), 80);
    assert_eq!(cooldown::available(&policy, &state_a, &clk), 0);

    coin::burn_for_testing(withdrawn);
    transfer::public_transfer(state_a, withdrawer_a);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);

    // Withdrawer B is unaffected because their cooldown state is separate.
    test.next_tx(withdrawer_b);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<cooldown::Policy<vault::WithdrawTag>>();
    let mut state_b = test.take_from_sender<cooldown::State<vault::WithdrawTag>>();
    let other = vault::withdraw(&mut vault, &policy, &mut state_b, 30, &clk, test.ctx());
    assert_eq!(coin::value(&other), 30);
    assert_eq!(vault::value(&vault), 50);

    coin::burn_for_testing(other);
    cooldown::destroy_state(state_b);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);

    // Once the cooldown expires, A can withdraw again.
    test.next_tx(withdrawer_a);
    clk.set_for_testing(10);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<cooldown::Policy<vault::WithdrawTag>>();
    let mut state_a = test.take_from_sender<cooldown::State<vault::WithdrawTag>>();
    let withdrawn_again = vault::withdraw(&mut vault, &policy, &mut state_a, 25, &clk, test.ctx());
    assert_eq!(coin::value(&withdrawn_again), 25);
    assert_eq!(vault::value(&vault), 25);

    coin::burn_for_testing(withdrawn_again);
    cooldown::destroy_state(state_a);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);

    // The owner removes the leftover funds so the shared vault ends empty.
    test.next_tx(owner);
    let mut vault = test.take_shared<vault::Vault>();
    let leftover = vault::withdraw_unchecked(&mut vault, 25, test.ctx());
    coin::burn_for_testing(leftover);
    test_scenario::return_shared(vault);

    clock::destroy_for_testing(clk);
    test.end();
}

#[test, expected_failure(abort_code = cooldown::ERateLimited)]
fun withdrawal_is_rate_limited() {
    let owner = @0x41;
    let withdrawer_a = @0x42;
    let withdrawer_b = @0x43;
    let mut test = test_scenario::begin(owner);
    let initial_vault = coin::mint_for_testing<sui::sui::SUI>(0, test.ctx());
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    // The owner creates the shared vault and cooldown policy.
    vault::create_and_share(initial_vault, 0, 10, test.ctx());

    // Both withdrawers deposit and receive distinct cooldown state objects.
    test.next_tx(withdrawer_a);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<cooldown::Policy<vault::WithdrawTag>>();
    let deposit_a = coin::mint_for_testing<sui::sui::SUI>(60, test.ctx());
    let state_a = vault::deposit(&mut vault, &policy, deposit_a, &clk, test.ctx());
    transfer::public_transfer(state_a, withdrawer_a);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);

    test.next_tx(withdrawer_b);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<cooldown::Policy<vault::WithdrawTag>>();
    let deposit_b = coin::mint_for_testing<sui::sui::SUI>(40, test.ctx());
    let state_b = vault::deposit(&mut vault, &policy, deposit_b, &clk, test.ctx());
    transfer::public_transfer(state_b, withdrawer_b);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);

    // Withdrawer B succeeds first to show their cooldown is independent from A's.
    test.next_tx(withdrawer_b);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<cooldown::Policy<vault::WithdrawTag>>();
    let mut state_b = test.take_from_sender<cooldown::State<vault::WithdrawTag>>();
    let first = vault::withdraw(&mut vault, &policy, &mut state_b, 30, &clk, test.ctx());
    coin::burn_for_testing(first);
    cooldown::destroy_state(state_b);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);

    // Withdrawer A succeeds once, then immediately tries again before cooldown ends.
    test.next_tx(withdrawer_a);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<cooldown::Policy<vault::WithdrawTag>>();
    let mut state_a = test.take_from_sender<cooldown::State<vault::WithdrawTag>>();
    let first = vault::withdraw(&mut vault, &policy, &mut state_a, 30, &clk, test.ctx());
    coin::burn_for_testing(first);
    let failed = vault::withdraw(&mut vault, &policy, &mut state_a, 20, &clk, test.ctx());
    coin::burn_for_testing(failed);

    cooldown::destroy_state(state_a);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);

    clock::destroy_for_testing(clk);
    test.end();
}

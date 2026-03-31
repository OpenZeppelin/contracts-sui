#[test_only]
module fixed_window_example::fixed_window_example_tests;

use fixed_window_example::fixed_window;
use fixed_window_example::vault;
use std::unit_test::assert_eq;
use sui::clock;
use sui::coin;
use sui::test_scenario;

#[test]
fun partial_withdrawal_succeeds() {
    let owner = @0x11;
    let withdrawer_a = @0x12;
    let withdrawer_b = @0x13;
    let mut test = test_scenario::begin(owner);
    let initial_vault = coin::mint_for_testing<sui::sui::SUI>(0, test.ctx());
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    // The owner creates one shared vault and a fixed-window policy.
    vault::create_and_share(initial_vault, 0, 100, 50, test.ctx());

    // Each deposit mints a separate limiter state for that withdrawer.
    test.next_tx(withdrawer_a);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<fixed_window::Policy<vault::WithdrawTag>>();
    let deposit_a = coin::mint_for_testing<sui::sui::SUI>(70, test.ctx());
    let state_a = vault::deposit(&mut vault, &policy, deposit_a, &clk, test.ctx());
    transfer::public_transfer(state_a, withdrawer_a);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);

    test.next_tx(withdrawer_b);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<fixed_window::Policy<vault::WithdrawTag>>();
    let deposit_b = coin::mint_for_testing<sui::sui::SUI>(40, test.ctx());
    let state_b = vault::deposit(&mut vault, &policy, deposit_b, &clk, test.ctx());
    transfer::public_transfer(state_b, withdrawer_b);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);

    // Withdrawer A uses part of their quota inside the current window.
    test.next_tx(withdrawer_a);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<fixed_window::Policy<vault::WithdrawTag>>();
    let mut state_a = test.take_from_sender<fixed_window::State<vault::WithdrawTag>>();
    let withdrawn = vault::withdraw(&mut vault, &policy, &mut state_a, 30, &clk, test.ctx());

    assert_eq!(coin::value(&withdrawn), 30);
    assert_eq!(vault::value(&vault), 80);
    assert_eq!(fixed_window::available(&policy, &state_a, &clk), 20);

    coin::burn_for_testing(withdrawn);
    transfer::public_transfer(state_a, withdrawer_a);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);

    // Withdrawer B still has a fresh window because their state is independent.
    test.next_tx(withdrawer_b);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<fixed_window::Policy<vault::WithdrawTag>>();
    let mut state_b = test.take_from_sender<fixed_window::State<vault::WithdrawTag>>();
    let other = vault::withdraw(&mut vault, &policy, &mut state_b, 30, &clk, test.ctx());
    assert_eq!(coin::value(&other), 30);
    assert_eq!(vault::value(&vault), 50);

    coin::burn_for_testing(other);
    fixed_window::destroy_state(state_b);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);

    // Moving into the next window resets A's available quota.
    test.next_tx(withdrawer_a);
    clk.set_for_testing(100);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<fixed_window::Policy<vault::WithdrawTag>>();
    let mut state_a = test.take_from_sender<fixed_window::State<vault::WithdrawTag>>();
    assert_eq!(fixed_window::available(&policy, &state_a, &clk), 50);
    let withdrawn_again = vault::withdraw(&mut vault, &policy, &mut state_a, 30, &clk, test.ctx());
    assert_eq!(coin::value(&withdrawn_again), 30);
    assert_eq!(vault::value(&vault), 20);

    coin::burn_for_testing(withdrawn_again);
    fixed_window::destroy_state(state_a);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);

    // The owner removes the remaining balance so the test can clean up.
    test.next_tx(owner);
    let mut vault = test.take_shared<vault::Vault>();
    let leftover = vault::withdraw_unchecked(&mut vault, 20, test.ctx());
    coin::burn_for_testing(leftover);
    test_scenario::return_shared(vault);

    clock::destroy_for_testing(clk);
    test.end();
}

#[test, expected_failure(abort_code = fixed_window::ERateLimited)]
fun withdrawal_is_rate_limited() {
    let owner = @0x31;
    let withdrawer_a = @0x32;
    let withdrawer_b = @0x33;
    let mut test = test_scenario::begin(owner);
    let initial_vault = coin::mint_for_testing<sui::sui::SUI>(0, test.ctx());
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    // The owner creates the shared vault and a 50-coin window limit.
    vault::create_and_share(initial_vault, 0, 100, 50, test.ctx());

    // Both withdrawers deposit into the same vault and get distinct state objects.
    test.next_tx(withdrawer_a);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<fixed_window::Policy<vault::WithdrawTag>>();
    let deposit_a = coin::mint_for_testing<sui::sui::SUI>(60, test.ctx());
    let state_a = vault::deposit(&mut vault, &policy, deposit_a, &clk, test.ctx());
    transfer::public_transfer(state_a, withdrawer_a);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);

    test.next_tx(withdrawer_b);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<fixed_window::Policy<vault::WithdrawTag>>();
    let deposit_b = coin::mint_for_testing<sui::sui::SUI>(40, test.ctx());
    let state_b = vault::deposit(&mut vault, &policy, deposit_b, &clk, test.ctx());
    transfer::public_transfer(state_b, withdrawer_b);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);

    // Withdrawer B spends some of their own window without affecting A.
    test.next_tx(withdrawer_b);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<fixed_window::Policy<vault::WithdrawTag>>();
    let mut state_b = test.take_from_sender<fixed_window::State<vault::WithdrawTag>>();
    let first = vault::withdraw(&mut vault, &policy, &mut state_b, 30, &clk, test.ctx());
    coin::burn_for_testing(first);
    fixed_window::destroy_state(state_b);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);

    // Withdrawer A tries to exceed their own current-window limit and aborts.
    test.next_tx(withdrawer_a);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<fixed_window::Policy<vault::WithdrawTag>>();
    let mut state_a = test.take_from_sender<fixed_window::State<vault::WithdrawTag>>();
    let failed = vault::withdraw(&mut vault, &policy, &mut state_a, 51, &clk, test.ctx());
    coin::burn_for_testing(failed);

    fixed_window::destroy_state(state_a);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);

    clock::destroy_for_testing(clk);
    test.end();
}

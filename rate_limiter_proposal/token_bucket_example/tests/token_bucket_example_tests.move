#[test_only]
module token_bucket_example::token_bucket_example_tests;

use std::unit_test::assert_eq;
use sui::clock;
use sui::coin;
use sui::test_scenario;
use token_bucket_example::token_bucket;
use token_bucket_example::vault;

#[test]
fun partial_withdrawal_succeeds() {
    let owner = @0x1;
    let withdrawer_a = @0x2;
    let withdrawer_b = @0x3;
    let mut test = test_scenario::begin(owner);
    let initial_vault = coin::mint_for_testing<sui::sui::SUI>(0, test.ctx());
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    // The owner publishes one shared vault and one shared token-bucket policy.
    vault::create_and_share(initial_vault, 0, 100, 1, 10, 50, test.ctx());

    // Each withdrawer deposits into the shared vault and receives their own limiter state.
    test.next_tx(withdrawer_a);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<token_bucket::Policy<vault::WithdrawTag>>();
    let deposit_a = coin::mint_for_testing<sui::sui::SUI>(60, test.ctx());
    vault::deposit(&mut vault, &policy, deposit_a, &clk, test.ctx());
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);

    test.next_tx(withdrawer_b);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<token_bucket::Policy<vault::WithdrawTag>>();
    let deposit_b = coin::mint_for_testing<sui::sui::SUI>(40, test.ctx());
    vault::deposit(&mut vault, &policy, deposit_b, &clk, test.ctx());
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);

    // Withdrawer A spends part of their own bucket.
    test.next_tx(withdrawer_a);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<token_bucket::Policy<vault::WithdrawTag>>();
    let mut state_a = test.take_from_sender<token_bucket::State<vault::WithdrawTag>>();
    let withdrawn_a = vault::withdraw(&mut vault, &policy, &mut state_a, 30, &clk, test.ctx());

    assert_eq!(coin::value(&withdrawn_a), 30);
    assert_eq!(vault::value(&vault), 70);
    assert_eq!(token_bucket::available(&policy, &state_a, &clk), 20);

    coin::burn_for_testing(withdrawn_a);
    transfer::public_transfer(state_a, withdrawer_a);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);

    // Withdrawer B uses a different state object, so A's withdrawal does not affect B.
    test.next_tx(withdrawer_b);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<token_bucket::Policy<vault::WithdrawTag>>();
    let mut state_b = test.take_from_sender<token_bucket::State<vault::WithdrawTag>>();
    let withdrawn_b = vault::withdraw(&mut vault, &policy, &mut state_b, 30, &clk, test.ctx());

    assert_eq!(coin::value(&withdrawn_b), 30);
    assert_eq!(vault::value(&vault), 40);
    assert_eq!(token_bucket::available(&policy, &state_b, &clk), 10);

    coin::burn_for_testing(withdrawn_b);
    token_bucket::destroy_state(state_b);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);

    // After time passes, withdrawer A's bucket refills and allows another withdrawal.
    test.next_tx(withdrawer_a);
    clk.set_for_testing(100);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<token_bucket::Policy<vault::WithdrawTag>>();
    let mut state_a = test.take_from_sender<token_bucket::State<vault::WithdrawTag>>();
    assert_eq!(token_bucket::available(&policy, &state_a, &clk), 30);
    let withdrawn_a_again = vault::withdraw(
        &mut vault,
        &policy,
        &mut state_a,
        25,
        &clk,
        test.ctx(),
    );
    assert_eq!(coin::value(&withdrawn_a_again), 25);
    assert_eq!(vault::value(&vault), 15);
    assert_eq!(token_bucket::available(&policy, &state_a, &clk), 0);

    coin::burn_for_testing(withdrawn_a_again);
    token_bucket::destroy_state(state_a);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);

    // The owner drains the leftover funds to leave the shared vault empty for cleanup.
    test.next_tx(owner);
    let mut vault = test.take_shared<vault::Vault>();
    let leftover = vault::withdraw_unchecked(&mut vault, 15, test.ctx());
    coin::burn_for_testing(leftover);
    test_scenario::return_shared(vault);

    clock::destroy_for_testing(clk);
    test.end();
}

#[test, expected_failure(abort_code = token_bucket::ERateLimited)]
fun withdrawal_is_rate_limited() {
    let owner = @0x7;
    let withdrawer_a = @0x8;
    let withdrawer_b = @0x9;
    let mut test = test_scenario::begin(owner);
    let initial_vault = coin::mint_for_testing<sui::sui::SUI>(0, test.ctx());
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    // The owner creates the shared vault and token-bucket policy.
    vault::create_and_share(initial_vault, 0, 50, 1, 10, 50, test.ctx());

    // Both withdrawers deposit and get separate limiter state objects.
    test.next_tx(withdrawer_a);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<token_bucket::Policy<vault::WithdrawTag>>();
    let deposit_a = coin::mint_for_testing<sui::sui::SUI>(60, test.ctx());
    vault::deposit(&mut vault, &policy, deposit_a, &clk, test.ctx());
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);

    test.next_tx(withdrawer_b);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<token_bucket::Policy<vault::WithdrawTag>>();
    let deposit_b = coin::mint_for_testing<sui::sui::SUI>(40, test.ctx());
    vault::deposit(&mut vault, &policy, deposit_b, &clk, test.ctx());
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);

    // Withdrawer B succeeds first, showing their state is independent from A's state.
    test.next_tx(withdrawer_b);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<token_bucket::Policy<vault::WithdrawTag>>();
    let mut state_b = test.take_from_sender<token_bucket::State<vault::WithdrawTag>>();
    let ok = vault::withdraw(&mut vault, &policy, &mut state_b, 30, &clk, test.ctx());
    coin::burn_for_testing(ok);
    token_bucket::destroy_state(state_b);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);

    // Withdrawer A now asks for more than their current bucket allows and aborts.
    test.next_tx(withdrawer_a);
    let mut vault = test.take_shared<vault::Vault>();
    let policy = test.take_shared<token_bucket::Policy<vault::WithdrawTag>>();
    let mut state_a = test.take_from_sender<token_bucket::State<vault::WithdrawTag>>();
    let failed = vault::withdraw(&mut vault, &policy, &mut state_a, 51, &clk, test.ctx());
    coin::burn_for_testing(failed);

    token_bucket::destroy_state(state_a);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);
    clock::destroy_for_testing(clk);
    test.end();
}

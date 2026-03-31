module cooldown_example::vault;

use cooldown_example::cooldown;
use sui::balance::{Self as balance, Balance};
use sui::clock::Clock;
use sui::coin::{Self as coin, Coin};
use sui::sui::SUI;

#[error(code = 0)]
const EInsufficientVaultBalance: vector<u8> = b"Insufficient vault balance";
#[error(code = 1)]
const EWrongPolicy: vector<u8> = b"Wrong policy";

public struct Vault has key, store {
    id: UID,
    policy_id: ID,
    balance: Balance<SUI>,
}

public struct WithdrawTag has copy, drop, store {}

public fun create_and_share(
    initial_coin: Coin<SUI>,
    version: u16,
    cooldown_ms: u64,
    ctx: &mut TxContext,
) {
    let policy = cooldown::create_policy<WithdrawTag>(version, cooldown_ms, ctx);
    let vault = Vault {
        id: object::new(ctx),
        policy_id: object::id(&policy),
        balance: coin::into_balance(initial_coin),
    };
    transfer::share_object(vault);
    transfer::public_share_object(policy);
}

public fun deposit(
    self: &mut Vault,
    policy: &cooldown::Policy<WithdrawTag>,
    deposit_coin: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_policy(self, policy);
    balance::join(&mut self.balance, coin::into_balance(deposit_coin));
    let withdrawer = tx_context::sender(ctx);
    let state = cooldown::create_for_address<WithdrawTag>(policy, withdrawer, clock, ctx);
    transfer::public_transfer(state, withdrawer);
}

public fun value(self: &Vault): u64 {
    balance::value(&self.balance)
}

public fun withdraw(
    self: &mut Vault,
    policy: &cooldown::Policy<WithdrawTag>,
    state: &mut cooldown::State<WithdrawTag>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<SUI> {
    assert_policy(self, policy);
    cooldown::consume_or_abort(policy, state, amount, clock);
    withdraw_unchecked(self, amount, ctx)
}

public fun withdraw_unchecked(self: &mut Vault, amount: u64, ctx: &mut TxContext): Coin<SUI> {
    assert!(balance::value(&self.balance) >= amount, EInsufficientVaultBalance);
    coin::from_balance(balance::split(&mut self.balance, amount), ctx)
}

public fun destroy_empty(self: Vault) {
    let Vault { id, policy_id: _, balance } = self;
    assert!(balance::value(&balance) == 0, EInsufficientVaultBalance);
    balance::destroy_zero(balance);
    id.delete();
}

fun assert_policy(self: &Vault, policy: &cooldown::Policy<WithdrawTag>) {
    assert!(self.policy_id == object::id(policy), EWrongPolicy);
}

module token_bucket_example::vault;

use sui::balance::{Self as balance, Balance};
use sui::clock::Clock;
use sui::coin::{Self as coin, Coin};
use sui::sui::SUI;
use token_bucket_example::token_bucket;

#[error(code = 0)]
const EInsufficientVaultBalance: vector<u8> = "Insufficient vault balance";
#[error(code = 1)]
const EWrongPolicy: vector<u8> = "Wrong policy";

public struct Vault has key, store {
    id: UID,
    policy_id: ID,
    balance: Balance<SUI>,
}

public struct WithdrawTag has copy, drop, store {}

public fun create_and_share(
    initial_coin: Coin<SUI>,
    version: u16,
    capacity: u64,
    refill_numerator: u64,
    refill_denominator_ms: u64,
    initial_tokens: u64,
    ctx: &mut TxContext,
) {
    let policy = token_bucket::create_policy<WithdrawTag>(
        version,
        capacity,
        refill_numerator,
        refill_denominator_ms,
        initial_tokens,
        ctx,
    );
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
    policy: &token_bucket::Policy<WithdrawTag>,
    deposit_coin: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
): token_bucket::State<WithdrawTag> {
    assert_policy(self, policy);
    balance::join(&mut self.balance, coin::into_balance(deposit_coin));
    let withdrawer = tx_context::sender(ctx);
    token_bucket::create_for_address<WithdrawTag>(
        policy,
        withdrawer,
        clock,
        ctx,
    )
}

public fun value(self: &Vault): u64 {
    balance::value(&self.balance)
}

public fun withdraw(
    self: &mut Vault,
    policy: &token_bucket::Policy<WithdrawTag>,
    state: &mut token_bucket::State<WithdrawTag>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<SUI> {
    assert_policy(self, policy);
    token_bucket::consume_or_abort(policy, state, amount, clock);
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

fun assert_policy(self: &Vault, policy: &token_bucket::Policy<WithdrawTag>) {
    assert!(self.policy_id == object::id(policy), EWrongPolicy);
}

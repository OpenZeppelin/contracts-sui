/// A cooldown that gates an action *until* a delay has elapsed.
///
/// Simple SUI staking (no yield). Staking returns a `StakeReceipt`. Initiating an unstake burns
/// the receipt and hands back an `UnstakeTicket` carrying the reserved coins behind an *armed*
/// cooldown limiter: the gate is set to release `unbond_delay_ms` in the future. `claim` consumes
/// that gate, so it aborts until the unbonding delay has elapsed. Here the cooldown is not a
/// throttle on repeated actions but a one-shot timelock in front of a single action.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `RateLimiter` primitive can be integrated. It is not production-ready and must not be
/// deployed as-is.
module openzeppelin_utils::staking_vault;

use openzeppelin_utils::rate_limiter::{Self, RateLimiter};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::sui::SUI;

// === Errors ===

#[error(code = 0)]
const EWrongVault: vector<u8> =
    "A receipt or ticket was provided for a different vault than the one that issued it";

// === Structs ===

/// Shared staking pool. `unbond_delay_ms` is the cooldown applied before staked funds can be claimed.
public struct StakingVault has key {
    id: UID,
    funds: Balance<SUI>,
    unbond_delay_ms: u64,
}

/// Proof of a staked position, held by the staker. Tracks the vault that issued it.
public struct StakeReceipt has key, store {
    id: UID,
    vault_id: ID,
    amount: u64,
}

/// Issued when unstaking begins. Releases the reserved coins only after its cooldown gate elapses.
public struct UnstakeTicket has key, store {
    id: UID,
    coins: Balance<SUI>,
    gate: RateLimiter,
}

// === Public Functions ===

/// Share a staking vault with the given unbonding delay.
public fun new(unbond_delay_ms: u64, ctx: &mut TxContext) {
    transfer::share_object(StakingVault {
        id: object::new(ctx),
        funds: balance::zero(),
        unbond_delay_ms,
    });
}

/// Stake `payment`, returning a receipt for the staked amount.
public fun stake(self: &mut StakingVault, payment: Coin<SUI>, ctx: &mut TxContext): StakeReceipt {
    let amount = payment.value();
    self.funds.join(payment.into_balance());
    StakeReceipt { id: object::new(ctx), vault_id: object::id(self), amount }
}

/// Begin unstaking: burn the receipt, reserve the coins into a ticket, and arm a cooldown that
/// releases `unbond_delay_ms` from now.
public fun initiate_unstake(
    self: &mut StakingVault,
    receipt: StakeReceipt,
    clock: &Clock,
    ctx: &mut TxContext,
): UnstakeTicket {
    let StakeReceipt { id, vault_id, amount } = receipt;
    assert!(vault_id == object::id(self), EWrongVault);
    id.delete();

    let coins = self.funds.split(amount);
    // Armed cooldown (gated seed): no charge available now, gate releases at now + delay.
    let gate = rate_limiter::new_cooldown(
        1, // capacity: a single claim
        self.unbond_delay_ms, // cooldown_ms
        clock.timestamp_ms() + self.unbond_delay_ms, // cooldown_end_ms: release time
        0, // initial_available: nothing claimable yet
        clock,
    );
    UnstakeTicket { id: object::new(ctx), coins, gate }
}

/// Claim unstaked coins. Consuming the gate aborts `ERateLimited` until the unbonding cooldown
/// has elapsed; once it has, the gate releases and the coins are returned.
public fun claim(ticket: UnstakeTicket, clock: &Clock, ctx: &mut TxContext): Coin<SUI> {
    let UnstakeTicket { id, coins, mut gate } = ticket;
    gate.consume_or_abort(1, clock);
    id.delete();
    coin::from_balance(coins, ctx)
}

// === View helpers ===

/// Whether the ticket's cooldown has elapsed and the coins can be claimed now.
public fun is_claimable(ticket: &UnstakeTicket, clock: &Clock): bool {
    ticket.gate.available(clock) > 0
}

// === Test-Only Helpers ===

/// The staked amount recorded by a receipt.
#[test_only]
public fun amount(receipt: &StakeReceipt): u64 {
    receipt.amount
}

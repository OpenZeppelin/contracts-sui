/// A `Beneficiary` object that fans a vesting wallet's payouts out to many receivers
/// by fixed weights - a worked example of pointing a wallet's `beneficiary` at an
/// object instead of a person.
///
/// A `VestingWallet`'s `beneficiary` is just an address: `release` credits the payout
/// to it via `balance::send_funds`, the funds-accumulator transfer. Point it at a
/// shared `Beneficiary` and each release settles into the object's address balance;
/// anyone can then poke `disperse` with the released amount to withdraw it from the
/// object's accumulator and split it among the receivers - crediting each via
/// `balance::send_funds` too - by their allocations, fixed at creation and free to
/// differ between receivers. Each split emits a `Dispersed` event recording the
/// per-receiver amounts.
///
/// For coins delivered the older way - `public_transfer`'d to the object's address by
/// an upstream emitter, landing as a `Receiving<Coin<C>>` - `receive_and_disperse`
/// claims that coin, turns it into a `Balance`, and fans it out the same way.
///
/// This composes with *any* curve and topology: the wallet neither knows nor cares
/// that its beneficiary is a contract. The split is per payout.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `vesting_wallet` primitive can be integrated. It is not production-ready and must
/// not be deployed as-is.
module openzeppelin_finance::example_splitter;

use openzeppelin_math::rounding;
use openzeppelin_math::u64::mul_div;
use sui::balance::{Self, Balance};
use sui::coin::Coin;
use sui::event;
use sui::transfer::Receiving;

// === Errors ===

/// The `receivers` and `weights` vectors were empty or of unequal length.
#[error(code = 0)]
const EBadConfig: vector<u8> = "Receivers and weights must be non-empty and of equal length";
/// A weight was zero; every receiver must have a positive allocation.
#[error(code = 1)]
const EZeroWeight: vector<u8> = "Every weight must be greater than zero";

// === Structs ===

/// A shared payout splitter. Set a vesting wallet's `beneficiary` to this object's
/// address; releases settle into this object's accumulator and `disperse` fans each
/// one out by weight.
public struct Beneficiary has key {
    id: UID,
    /// Payout recipients.
    receivers: vector<address>,
    /// Allocation weight per receiver, parallel to `receivers`.
    weights: vector<u64>,
    /// Cached sum of `weights`, the denominator of each receiver's share.
    total_weight: u64,
}

// === Events ===

/// Emitted once per `disperse` / `receive_and_disperse` call: the payout was split and
/// credited to `receivers` via `balance::send_funds`, in the parallel `amounts`
/// (receiver order). The amounts sum to the dispersed payout.
public struct Dispersed<phantom C> has copy, drop {
    /// The splitter object that fanned the payout out.
    splitter: ID,
    /// Recipients paid, in order.
    receivers: vector<address>,
    /// Amount credited to each receiver, parallel to `receivers`.
    amounts: vector<u64>,
}

// === Public Functions ===

/// Create and share a splitter, returning the object's address to use as a vesting
/// wallet's `beneficiary`. Allocations are fixed here and may differ per receiver.
///
/// #### Aborts
/// - `EBadConfig` if the vectors are empty or of unequal length.
/// - `EZeroWeight` if any weight is zero.
public fun new(receivers: vector<address>, weights: vector<u64>, ctx: &mut TxContext): address {
    assert!(!receivers.is_empty() && receivers.length() == weights.length(), EBadConfig);

    let mut total_weight = 0;
    weights.do_ref!(|w| {
        assert!(*w > 0, EZeroWeight);
        // SAFETY: unchecked sum, but a u64 overflow aborts here (fail-safe) - a config
        // with weights summing past u64::MAX simply cannot be created.
        total_weight = total_weight + *w;
    });

    let splitter = Beneficiary { id: object::new(ctx), receivers, weights, total_weight };
    let addr = object::id_address(&splitter);
    transfer::share_object(splitter);
    addr
}

/// Withdraw `amount` of `C` from this object's funds accumulator - where a vesting
/// wallet `release` credits its object beneficiary via `balance::send_funds` - and fan
/// it out to the receivers by weight. Permissionless. `amount` is the released amount
/// (e.g. read from the wallet's `Released` event).
///
/// #### Aborts
/// - The funds-accumulator `InsufficientFundsForWithdraw` execution status, raised at
///   `redeem_funds`, if the object's settled balance is below `amount`.
public fun disperse<C>(self: &mut Beneficiary, amount: u64) {
    let withdrawal = balance::withdraw_funds_from_object<C>(&mut self.id, amount);
    self.fan_out(balance::redeem_funds(withdrawal));
}

/// Claim one payout coin parked at this object's address - `public_transfer`'d there by
/// an upstream emitter (or a stray coin) - turn it into a `Balance`, and fan it out to
/// the receivers by weight. The coin-object counterpart to `disperse`'s accumulator
/// withdrawal. Permissionless.
public fun receive_and_disperse<C>(self: &mut Beneficiary, payout: Receiving<Coin<C>>) {
    let coin = transfer::public_receive(&mut self.id, payout);
    self.fan_out(coin.into_balance());
}

// === Private Functions ===

/// Fan one payout balance out to the receivers by weight, crediting each via
/// `balance::send_funds` (address-balance-first), and emit `Dispersed`. Conserves value
/// exactly: integer division floors each share and the last receiver absorbs the
/// remainder, so the credits sum to the balance's value with nothing created or
/// stranded as dust.
fun fan_out<C>(self: &Beneficiary, mut payout: Balance<C>) {
    let value = payout.value();
    let n = self.receivers.length();

    let mut amounts = vector[];
    let mut i = 0;
    while (i < n - 1) {
        let share = mul_div(
            value,
            self.weights[i],
            self.total_weight,
            rounding::down(),
        ).destroy_some();
        amounts.push_back(share);
        balance::send_funds(payout.split(share), self.receivers[i]);
        i = i + 1;
    };
    // The last receiver takes whatever remains, so floored shares never strand dust.
    amounts.push_back(payout.value());
    balance::send_funds(payout, self.receivers[n - 1]);

    event::emit(Dispersed<C> {
        splitter: object::id(self),
        receivers: self.receivers,
        amounts,
    });
}

// === View helpers ===

/// The configured payout recipients.
public fun receivers(self: &Beneficiary): vector<address> {
    self.receivers
}

/// The configured allocation weights, parallel to `receivers`.
public fun weights(self: &Beneficiary): vector<u64> {
    self.weights
}

/// The sum of all weights.
public fun total_weight(self: &Beneficiary): u64 {
    self.total_weight
}

// === Test Helpers ===

/// Build a `Dispersed` event value for asserting against `event::events_by_type`.
#[test_only]
public fun test_new_dispersed<C>(
    splitter: ID,
    receivers: vector<address>,
    amounts: vector<u64>,
): Dispersed<C> {
    Dispersed { splitter, receivers, amounts }
}

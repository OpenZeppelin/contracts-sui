/// A `Beneficiary` object that fans a vesting wallet's payouts out to many receivers
/// by fixed weights - a worked example of pointing a wallet's `beneficiary` at an
/// object instead of a person.
///
/// A `VestingWallet`'s `beneficiary` is just an address: `release` `public_transfer`s
/// the payout coin to it. Point it at a shared `Beneficiary` and each release lands at
/// the object's address as a `Receiving<Coin<C>>`; anyone can then poke `disperse` to
/// split that coin among the receivers by their allocations, fixed at creation and
/// free to differ between receivers.
///
/// This composes with *any* curve and topology: the wallet neither knows nor cares
/// that its beneficiary is a contract. The split is per payout, so each `release`
/// queues one more `Receiving` for `disperse` to fan out.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `vesting_wallet` primitive can be integrated. It is not production-ready and must
/// not be deployed as-is.
module openzeppelin_finance::example_splitter;

use openzeppelin_math::rounding;
use openzeppelin_math::u64::mul_div;
use sui::coin::Coin;
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
/// address; releases land here and `disperse` fans each one out by weight.
public struct Beneficiary has key {
    id: UID,
    /// Payout recipients.
    receivers: vector<address>,
    /// Allocation weight per receiver, parallel to `receivers`.
    weights: vector<u64>,
    /// Cached sum of `weights`, the denominator of each receiver's share.
    total_weight: u64,
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
        total_weight = total_weight + *w;
    });

    let splitter = Beneficiary { id: object::new(ctx), receivers, weights, total_weight };
    let addr = object::id(&splitter).id_to_address();
    transfer::share_object(splitter);
    addr
}

/// Pull one payout coin parked at this object's address (from a wallet `release`) and
/// fan it out to the receivers by weight. Permissionless. Conserves value exactly:
/// integer division floors each share and the last receiver absorbs the remainder, so
/// the transfers sum to the coin's value with nothing created or stranded as dust.
public fun disperse<C>(self: &mut Beneficiary, payout: Receiving<Coin<C>>, ctx: &mut TxContext) {
    let mut coin = transfer::public_receive(&mut self.id, payout);
    let value = coin.value();
    let n = self.receivers.length();

    let mut i = 0;
    while (i < n - 1) {
        let share = mul_div(
            value,
            self.weights[i],
            self.total_weight,
            rounding::down(),
        ).destroy_some();
        transfer::public_transfer(coin.split(share, ctx), self.receivers[i]);
        i = i + 1;
    };
    // The last receiver takes whatever remains, so floored shares never strand dust.
    transfer::public_transfer(coin, self.receivers[n - 1]);
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

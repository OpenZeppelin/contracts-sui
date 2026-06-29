/// A treasury whose withdrawal key can only change hands - or be reclaimed - after a
/// mandatory, on-chain-visible delay, using `delayed_transfer`.
///
/// A `Treasury` is a shared pool of `SUI` guarded by a single `TreasuryKey`. Rather than
/// hold that key bare, the integrator wraps it in a `DelayedTransferWrapper<TreasuryKey>`
/// with a fixed `min_delay`. From then on every custody change is announced ahead of time:
///  - **Transfer:** `schedule_transfer` records the new owner and a deadline; the move only
///    happens once `execute_transfer` is called past the deadline.
///  - **Unwrap (self-recovery):** `schedule_unwrap` arms the same delay before the holder
///    can pull the bare key back out with `unwrap`.
///  - **Cancel:** `cancel_schedule` clears a pending action before it executes.
///
/// The delay gives counterparties and monitoring a window to react before a sensitive key
/// moves. Meanwhile the key stays usable in place: `withdraw` borrows it out of the wrapper
/// with the library's `borrow`, so day-to-day operation never waits on the timelock - only
/// custody changes do.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `delayed_transfer` primitive can be integrated. It is not production-ready and must not
/// be deployed as-is.
module openzeppelin_access::example_timelocked_treasury;

use openzeppelin_access::delayed_transfer::DelayedTransferWrapper;
use sui::coin::{Self, Coin};
use sui::sui::SUI;

// === Errors ===

/// A treasury key was presented for a different treasury than the one it controls.
#[error(code = 0)]
const EWrongTreasury: vector<u8> = "Treasury key was issued for a different treasury";

// === Structs ===

/// Authority to withdraw from a `Treasury`. `key + store` so it can be wrapped by
/// `delayed_transfer`. Bound to one treasury via `treasury_id`, so a key only ever draws
/// from the treasury that minted it.
public struct TreasuryKey has key, store {
    id: UID,
    /// Id of the `Treasury` this key controls.
    treasury_id: ID,
}

/// A shared pool of funds that only the `TreasuryKey` holder may draw from.
public struct Treasury has key {
    id: UID,
    funds: sui::balance::Balance<SUI>,
}

// === Public Functions ===

/// Stand up a treasury funded with `initial`, share it, and return its `TreasuryKey` for
/// the caller to wrap with `delayed_transfer::wrap`.
///
/// #### Parameters
/// - `initial`: Coins seeding the pool.
/// - `ctx`: Transaction context.
///
/// #### Returns
/// - The `TreasuryKey` controlling the freshly shared `Treasury`.
public fun new(initial: Coin<SUI>, ctx: &mut TxContext): TreasuryKey {
    let treasury = Treasury { id: object::new(ctx), funds: initial.into_balance() };
    let key = TreasuryKey { id: object::new(ctx), treasury_id: object::id(&treasury) };
    transfer::share_object(treasury);
    key
}

/// Withdraw `amount`, presenting the treasury's bound key as authorization.
///
/// #### Parameters
/// - `self`: The treasury to draw from.
/// - `key`: The key bound to this treasury.
/// - `amount`: Units to withdraw.
/// - `ctx`: Transaction context.
///
/// #### Returns
/// - A `Coin<SUI>` for `amount`.
///
/// #### Aborts
/// - `EWrongTreasury` if `key` is not the key bound to this treasury.
public fun withdraw(
    self: &mut Treasury,
    key: &TreasuryKey,
    amount: u64,
    ctx: &mut TxContext,
): Coin<SUI> {
    assert!(key.treasury_id == object::id(self), EWrongTreasury);
    coin::from_balance(self.funds.split(amount), ctx)
}

/// Withdraw using a key that is still inside its delayed-transfer wrapper, borrowing it
/// with the library's `borrow`. Operation does not wait on the custody timelock.
///
/// #### Parameters
/// - `self`: The treasury to draw from.
/// - `wrapper`: The wrapper holding the treasury key.
/// - `amount`: Units to withdraw.
/// - `ctx`: Transaction context.
///
/// #### Returns
/// - A `Coin<SUI>` for `amount`.
public fun withdraw_wrapped(
    self: &mut Treasury,
    wrapper: &DelayedTransferWrapper<TreasuryKey>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<SUI> {
    self.withdraw(wrapper.borrow(), amount, ctx)
}

// === View helpers ===

/// The treasury's current balance.
public fun available(self: &Treasury): u64 {
    self.funds.value()
}

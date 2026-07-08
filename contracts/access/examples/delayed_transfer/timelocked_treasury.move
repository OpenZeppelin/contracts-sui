/// A treasury whose withdrawal key is held under an opt-in custody policy built on
/// `delayed_transfer`: once the key is wrapped, every custody change - handing it to a
/// new owner or reclaiming it bare - must be scheduled and survive an on-chain-visible
/// delay.
///
/// A `Treasury` is a shared pool of `SUI` guarded by a single `TreasuryKey`. The key is
/// an ordinary `key + store` object (the wrapper requires `store`), so a *bare* key
/// transfers freely and `withdraw` accepts it directly - the delay cannot be forced on a
/// key that was never wrapped. The guarantee comes from adopting the policy: wrap the key
/// in a `DelayedTransferWrapper<TreasuryKey>` immediately at creation (as the tests do),
/// and from then on every custody change is announced ahead of time:
///  - **Transfer:** `schedule_transfer` records the new owner and a deadline; the move only
///    happens once `execute_transfer` is called past the deadline.
///  - **Unwrap (self-recovery):** `schedule_unwrap` arms the same delay before the holder
///    can pull the bare key back out with `unwrap` - so even *exiting* the policy is
///    announced, but the recovered bare key bypasses the wrapper from then on.
///  - **Cancel:** `cancel_schedule` clears a pending action before it executes.
///
/// The delay gives counterparties and monitoring a window to react before a sensitive key
/// moves. Meanwhile the key stays usable in place: `withdraw_wrapped` borrows it out of
/// the wrapper with the library's `borrow`, so day-to-day operation never waits on the
/// timelock - only custody changes do.
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
///
/// #### Aborts
/// - `EWrongTreasury` if the wrapped key is not bound to this treasury.
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

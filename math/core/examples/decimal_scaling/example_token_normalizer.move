/// A multi-asset ledger that unifies token balances with DIFFERENT decimals onto a
/// single high-precision basis, then converts back to native units for payouts.
///
/// Many DeFi systems accept several assets that do not share a decimal convention:
/// a USDC-style stablecoin uses 6 decimals while a native Sui-style coin uses 9.
/// Adding their raw `u64` amounts directly would be meaningless - `1_000_000` (1 USDC
/// at 6 decimals) and `1_000_000` (0.001 of a 9-decimal coin) are wildly different
/// economic values. This ledger fixes that by normalizing every deposit onto a common
/// 18-decimal `u256` basis (the precision EVM systems use), summing there, and only
/// converting back to a concrete `u64` native amount at the moment of payout.
///
/// The two conversions come straight from `openzeppelin_math::decimal_scaling`:
///
/// - `safe_upcast_balance(amount, source_decimals, target_decimals)` lifts a native
///   `u64` amount onto the `u256` basis. Scaling *up* (e.g. 6 -> 18) is exact: no
///   economic value is lost.
/// - `safe_downcast_balance(raw_amount, source_decimals, target_decimals)` brings a
///   `u256` basis amount back to a `u64` native amount. Scaling *down* (e.g. 18 -> 6)
///   TRUNCATES toward zero - sub-unit dust below the target's precision is dropped,
///   never rounded up. This is the standard anti-inflation policy in token systems.
///
/// The ledger tracks one unified `u256` balance and remembers each asset's native
/// decimals so payouts can convert back. State is bounded: a fixed pair of named
/// `u256` accumulators, never a growing collection.
///
/// Each step is a separate `public fun` so an integrator can see exactly which value
/// flows through each conversion and where truncation can bite.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `decimal_scaling` primitive can be integrated. It is not production-ready and must
/// not be deployed as-is.
module openzeppelin_math::example_token_normalizer;

use openzeppelin_math::decimal_scaling;
use sui::event;

// === Errors ===

/// An admin cap was presented for a different ledger than the one it controls.
#[error(code = 0)]
const EWrongLedger: vector<u8> = "Admin cap was issued for a different ledger";

/// A payout asked for more value than the unified balance holds.
#[error(code = 1)]
const EInsufficientBalance: vector<u8> = "Payout exceeds the unified ledger balance";

// === Constants ===

/// The common high-precision basis every balance is normalized to. 18 decimals matches
/// the EVM convention and leaves ample headroom above the 6-9 decimals Sui coins use.
const NORMALIZED_DECIMALS: u8 = 18;

/// Decimals of the first supported asset (a USDC-style 6-decimal stablecoin).
const STABLE_DECIMALS: u8 = 6;

/// Decimals of the second supported asset (a native 9-decimal coin).
const NATIVE_DECIMALS: u8 = 9;

// === Structs ===

/// A shared ledger holding one unified balance, normalized to `NORMALIZED_DECIMALS`.
///
/// Deposits of either asset are upcast onto this basis and summed, so a single `u256`
/// field captures the combined economic value of both heterogeneous assets.
public struct MultiAssetLedger has key {
    id: UID,
    /// Combined balance of every deposit, all expressed at `NORMALIZED_DECIMALS`.
    normalized_balance: u256,
}

/// Authority to record deposits and draw payouts against the ledger. Bound to its
/// ledger by id so a cap minted for one ledger cannot act on another.
public struct LedgerAdminCap has key, store {
    id: UID,
    ledger_id: ID,
}

// === Events ===

/// Emitted whenever a deposit is normalized onto the basis and added to the ledger.
public struct Deposited has copy, drop {
    ledger_id: ID,
    /// Native amount supplied by the caller, in the asset's own decimals.
    native_amount: u64,
    /// Decimal convention of the deposited asset.
    source_decimals: u8,
    /// The same value re-expressed on the `NORMALIZED_DECIMALS` basis.
    normalized_amount: u256,
}

// === Public Functions ===

/// Share a fresh, empty ledger and return its admin cap to the caller.
public fun new(ctx: &mut TxContext): LedgerAdminCap {
    let ledger = MultiAssetLedger { id: object::new(ctx), normalized_balance: 0 };
    let cap = LedgerAdminCap { id: object::new(ctx), ledger_id: object::id(&ledger) };
    transfer::share_object(ledger);
    cap
}

/// Record a deposit of the 6-decimal stablecoin. The native `u64` amount is upcast to
/// the 18-decimal basis (exact, no loss) and added to the unified balance.
///
/// #### Aborts
/// - `EWrongLedger` if `cap` controls a different ledger.
public fun deposit_stable(self: &mut MultiAssetLedger, cap: &LedgerAdminCap, native_amount: u64) {
    self.deposit(cap, native_amount, STABLE_DECIMALS);
}

/// Record a deposit of the 9-decimal native coin. The native `u64` amount is upcast to
/// the 18-decimal basis (exact, no loss) and added to the unified balance.
///
/// #### Aborts
/// - `EWrongLedger` if `cap` controls a different ledger.
public fun deposit_native(self: &mut MultiAssetLedger, cap: &LedgerAdminCap, native_amount: u64) {
    self.deposit(cap, native_amount, NATIVE_DECIMALS);
}

/// Compute the native `u64` payout for a 6-decimal stablecoin withdrawal of
/// `normalized_amount` (expressed on the basis) and deduct it from the ledger.
///
/// Returns the truncated native amount: downcasting from 18 to 6 decimals drops any
/// sub-6-decimal dust toward zero. The full `normalized_amount` is still deducted from
/// the basis balance, so the dropped dust stays in the ledger rather than being minted
/// into existence - the anti-inflation invariant downcasting exists to protect.
///
/// #### Aborts
/// - `EWrongLedger` if `cap` controls a different ledger.
/// - `EInsufficientBalance` if `normalized_amount` exceeds the unified balance.
public fun payout_stable(
    self: &mut MultiAssetLedger,
    cap: &LedgerAdminCap,
    normalized_amount: u256,
): u64 {
    self.payout(cap, normalized_amount, STABLE_DECIMALS)
}

/// Compute the native `u64` payout for a 9-decimal native withdrawal of
/// `normalized_amount` (expressed on the basis) and deduct it from the ledger.
///
/// Like `payout_stable`, the returned native amount is truncated toward zero when the
/// basis carries finer precision than the target's 9 decimals.
///
/// #### Aborts
/// - `EWrongLedger` if `cap` controls a different ledger.
/// - `EInsufficientBalance` if `normalized_amount` exceeds the unified balance.
public fun payout_native(
    self: &mut MultiAssetLedger,
    cap: &LedgerAdminCap,
    normalized_amount: u256,
): u64 {
    self.payout(cap, normalized_amount, NATIVE_DECIMALS)
}

// === View helpers ===

/// The combined balance of every deposit, expressed on the `NORMALIZED_DECIMALS` basis.
public fun normalized_balance(self: &MultiAssetLedger): u256 {
    self.normalized_balance
}

/// Project the unified balance down to a native `u64` amount in the stablecoin's 6
/// decimals, without mutating the ledger. Truncates sub-unit dust toward zero.
public fun stable_balance(self: &MultiAssetLedger): u64 {
    decimal_scaling::safe_downcast_balance(
        self.normalized_balance,
        NORMALIZED_DECIMALS,
        STABLE_DECIMALS,
    )
}

/// Project the unified balance down to a native `u64` amount in the native coin's 9
/// decimals, without mutating the ledger. Truncates sub-unit dust toward zero.
public fun native_balance(self: &MultiAssetLedger): u64 {
    decimal_scaling::safe_downcast_balance(
        self.normalized_balance,
        NORMALIZED_DECIMALS,
        NATIVE_DECIMALS,
    )
}

/// Upcast a native `u64` amount in `source_decimals` onto the `NORMALIZED_DECIMALS`
/// basis. A pure helper an integrator can call off the ledger to pre-compute a sum.
public fun to_normalized(native_amount: u64, source_decimals: u8): u256 {
    decimal_scaling::safe_upcast_balance(native_amount, source_decimals, NORMALIZED_DECIMALS)
}

// === Private Functions ===

/// Shared deposit path: upcast `native_amount` from `source_decimals` to the basis,
/// add it to the unified balance, and emit a `Deposited` event. Upcasting is exact, so
/// no value is lost folding a 6- or 9-decimal amount into the 18-decimal balance.
fun deposit(
    self: &mut MultiAssetLedger,
    cap: &LedgerAdminCap,
    native_amount: u64,
    source_decimals: u8,
) {
    assert!(cap.ledger_id == object::id(self), EWrongLedger);

    let normalized_amount = decimal_scaling::safe_upcast_balance(
        native_amount,
        source_decimals,
        NORMALIZED_DECIMALS,
    );
    self.normalized_balance = self.normalized_balance + normalized_amount;

    event::emit(Deposited {
        ledger_id: object::id(self),
        native_amount,
        source_decimals,
        normalized_amount,
    });
}

/// Shared payout path: deduct `normalized_amount` from the basis balance, then downcast
/// it to a native `u64` amount in `target_decimals`. Deducting on the basis (before the
/// lossy downcast) keeps truncated dust inside the ledger instead of paying it out.
fun payout(
    self: &mut MultiAssetLedger,
    cap: &LedgerAdminCap,
    normalized_amount: u256,
    target_decimals: u8,
): u64 {
    assert!(cap.ledger_id == object::id(self), EWrongLedger);
    assert!(normalized_amount <= self.normalized_balance, EInsufficientBalance);

    self.normalized_balance = self.normalized_balance - normalized_amount;
    decimal_scaling::safe_downcast_balance(normalized_amount, NORMALIZED_DECIMALS, target_decimals)
}

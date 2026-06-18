/// The built-in linear-with-cliff schedule for `vesting_wallet` - a reference curve
/// and the template downstream schedule modules copy.
///
/// This module declares the `Linear` witness and its `Params`, plus the full
/// integrator API around them (`new` / `vested_amount` / `release` / `destroy` and
/// friends). It implements OpenZeppelin's linear-with-cliff curve on top of the
/// curve-agnostic `vesting_wallet` primitive. An integrator who just wants linear
/// vesting touches only this module - they never construct a bare wallet or mint a
/// `VestedAmount` by hand.
///
/// # Why a separate module
///
/// Struct fields are module-private in Move, so only this module can construct a
/// `Linear` or a `Params` value, and therefore only this module can build a
/// `VestingWallet<Linear, Params, C>` (via `vesting_wallet::new`, which takes the
/// `Params` by value) or mint a `VestedAmount<Linear>` (via
/// `vesting_wallet::mint_vested_amount`, which takes the `Linear` witness). Keeping
/// the curve in its own module - rather than baking it into the primitive - leaves
/// room for additional schedule types (cliff-only, stepped, exponential, …) that
/// follow this same shape without bloating `vesting_wallet`.
///
/// # The curve
///
/// - Pre-start (`now < start_ms`): zero.
/// - Pre-cliff (`cliff_ms > 0` and `now < start_ms + cliff_ms`): zero. At the cliff
///   boundary the value jumps directly to the linear-from-start proportion - the
///   cliff gates the curve, it does not shift it.
/// - Mid-schedule: linear in elapsed time, computed with a u128 intermediate.
/// - Post-end: clamped to the wallet's total (`balance + released`).
///
/// The total is re-derived on every call from `balance + released`, so deposits
/// made at `t > start_ms` immediately participate in vesting at the current
/// proportion.
module openzeppelin_finance::vesting_wallet_linear;

use openzeppelin_finance::vesting_wallet::{Self, VestingWallet, VestedAmount};
use std::u64::mul_div;
use sui::clock::Clock;

// === Errors ===

/// `duration_ms` was zero; a schedule must span a positive duration.
#[error(code = 0)]
const EZeroDuration: vector<u8> = "Duration must be greater than zero";
/// `cliff_ms` exceeded `duration_ms`; the cliff must fall within the schedule.
#[error(code = 1)]
const EInvalidCliff: vector<u8> = "Cliff must not exceed duration";
/// `start_ms + duration_ms` would overflow `u64`.
#[error(code = 2)]
const EScheduleOverflow: vector<u8> = "Schedule end (start + duration) would overflow u64";
/// `destroy` was called before the schedule's end (`start_ms + duration_ms`).
#[error(code = 3)]
const ENotEnded: vector<u8> = "Schedule has not ended yet";

// === Structs ===

/// The schedule witness for the linear-with-cliff curve. Empty and `drop`-only: it
/// carries no data and exists solely as the authority token `vesting_wallet`
/// requires. Declared here, so only this module can construct a `Linear` and
/// therefore only this module can mint a `VestedAmount<Linear>` or tear down a
/// `VestingWallet<Linear, Params, C>`.
public struct Linear has drop {}

/// The linear-with-cliff parameters, stored in the wallet.
public struct Params has copy, drop, store {
    /// Timestamp (ms) at which vesting begins. Before this, zero is vested.
    start_ms: u64,
    /// Length of the vesting period (ms); the schedule ends at `start_ms + duration_ms`.
    duration_ms: u64,
    /// Cliff length (ms from `start_ms`); `0` means no cliff. Nothing vests until
    /// `start_ms + cliff_ms`, at which point the curve jumps to its
    /// linear-from-start proportion.
    cliff_ms: u64,
}

// === Constructors ===

/// Build a `VestingWallet<Linear, Params, C>` on the linear-with-cliff schedule.
/// Returns the wallet by value so the caller can chain deposit and topology
/// selection in one PTB. Use `create_and_share` for the common "share immediately"
/// case.
///
/// #### Parameters
/// - `beneficiary`: Address that every release pays out to.
/// - `start_ms`: Timestamp (ms) at which vesting begins.
/// - `cliff_ms`: Cliff length (ms from `start_ms`); `0` for no cliff.
/// - `duration_ms`: Length of the vesting period (ms).
/// - `ctx`: Transaction context.
///
/// #### Returns
/// - A fresh, unfunded `VestingWallet<Linear, Params, C>` owned by the caller.
///
/// #### Aborts
/// - `EZeroDuration` if `duration_ms == 0`.
/// - `EInvalidCliff` if `cliff_ms > duration_ms`.
/// - `EScheduleOverflow` if `start_ms + duration_ms` would overflow `u64`.
public fun new<C>(
    beneficiary: address,
    start_ms: u64,
    cliff_ms: u64,
    duration_ms: u64,
    ctx: &mut TxContext,
): VestingWallet<Linear, Params, C> {
    assert!(duration_ms > 0, EZeroDuration);
    assert!(cliff_ms <= duration_ms, EInvalidCliff);
    assert!(duration_ms <= std::u64::max_value!() - start_ms, EScheduleOverflow);

    vesting_wallet::new(Params { start_ms, duration_ms, cliff_ms }, beneficiary, ctx)
}

/// Sugar for the common case: build a linear wallet and immediately share it.
/// Parameters and aborts are identical to `new`; the wallet is made shared via
/// `transfer::public_share_object` instead of being returned.
public fun create_and_share<C>(
    beneficiary: address,
    start_ms: u64,
    cliff_ms: u64,
    duration_ms: u64,
    ctx: &mut TxContext,
) {
    let wallet = new<C>(beneficiary, start_ms, cliff_ms, duration_ms, ctx);
    transfer::public_share_object(wallet);
}

// === Curve evaluation & release ===

/// Evaluate the linear curve at `clock.timestamp_ms()` and mint the resulting
/// cumulative vested total as a `VestedAmount<Linear>`. See the module docs for the
/// piecewise curve definition.
///
/// #### Returns
/// - A `VestedAmount<Linear>` for `wallet` at the current clock, ready to pass to
///   `vesting_wallet::release` (or this module's `release`).
public fun vested_amount<C>(
    wallet: &VestingWallet<Linear, Params, C>,
    clock: &Clock,
): VestedAmount<Linear> {
    wallet.mint_vested_amount(
        Linear {},
        vested_amount_raw(wallet, clock),
    )
}

/// Evaluate the linear curve and release the not-yet-released portion in one
/// call - the common path for the linear schedule.
public fun release<C>(
    wallet: &mut VestingWallet<Linear, Params, C>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let v = vested_amount(wallet, clock);
    wallet.release(&v, ctx);
}

/// How much `release` would pay out right now, without the caller minting a
/// `VestedAmount`. The client-friendly "what can I claim?" query.
///
/// #### Returns
/// - The amount currently releasable to the beneficiary at `clock.timestamp_ms()`.
public fun releasable<C>(wallet: &VestingWallet<Linear, Params, C>, clock: &Clock): u64 {
    wallet.releasable(&vested_amount(wallet, clock))
}

/// Tear down a drained, ended linear wallet: reclaim its storage rebate and drop
/// the `Linear` schedule. Wraps `vesting_wallet::destroy_empty` and additionally
/// requires the schedule to have ended.
///
/// #### Parameters
/// - `wallet`: The wallet to destroy. Must hold a zero balance.
/// - `clock`: Sui `Clock`, used to check the schedule has ended.
///
/// #### Aborts
/// - `ENotEmpty` if the wallet still holds a balance (from `destroy_empty`).
/// - `ENotEnded` if called before the schedule's end (`start_ms + duration_ms`).
public fun destroy<C>(wallet: VestingWallet<Linear, Params, C>, clock: &Clock) {
    // Require the schedule to have ended before teardown: destruction is
    // permissionless, so otherwise an empty wallet could be destroyed ahead of a
    // pending deposit, front-running funding intended to arrive later.
    assert!(clock.timestamp_ms() >= end(&wallet), ENotEnded);
    let Params { .. } = wallet.destroy_empty(Linear {});
}

// === View helpers ===

/// Timestamp (ms) at which vesting begins.
public fun start<C>(wallet: &VestingWallet<Linear, Params, C>): u64 {
    wallet.schedule_params().start_ms
}

/// Length of the vesting period (ms).
public fun duration<C>(wallet: &VestingWallet<Linear, Params, C>): u64 {
    wallet.schedule_params().duration_ms
}

/// Timestamp (ms) at which the schedule ends (`start_ms + duration_ms`).
public fun end<C>(wallet: &VestingWallet<Linear, Params, C>): u64 {
    let params = wallet.schedule_params();
    params.start_ms + params.duration_ms
}

/// Read the configured cliff length (ms from `start_ms`). `0` means no cliff.
public fun cliff<C>(wallet: &VestingWallet<Linear, Params, C>): u64 {
    wallet.schedule_params().cliff_ms
}

// === Private Functions ===

/// The linear curve's cumulative vested total at the current clock, as a `u64`.
fun vested_amount_raw<C>(wallet: &VestingWallet<Linear, Params, C>, clock: &Clock): u64 {
    let now = clock.timestamp_ms();
    let Params { start_ms, duration_ms, cliff_ms } = wallet.schedule_params();

    if (now < start_ms) {
        0
    } else if (cliff_ms > 0 && now < start_ms + cliff_ms) {
        0
    } else {
        // SAFETY: depositing has a check ensuring no balance overflow can occur.
        let total = wallet.balance() + wallet.released();
        // SAFETY: construction guarantees `start_ms + duration_ms` fit in u64.
        if (now >= start_ms + duration_ms) {
            total
        } else {
            let elapsed = now - start_ms;
            // SAFETY: `now < start_ms + duration_ms`, so `elapsed < duration_ms`:
            // the result stays strictly below `total` until the end.
            mul_div(total, elapsed, duration_ms)
        }
    }
}

// === Test-Only Helpers ===

/// Build a `Params` value for asserting against `event::events_by_type` (the
/// `Params` fields are module-private, so tests cannot construct one directly).
#[test_only]
public fun test_params(start_ms: u64, cliff_ms: u64, duration_ms: u64): Params {
    Params { start_ms, duration_ms, cliff_ms }
}

/// The built-in linear-with-cliff schedule for `vesting_wallet` — a reference
/// curve and the template downstream schedule modules copy.
///
/// This module declares the `Linear` schedule struct and the full integrator
/// API around it (`new` / `vested` / `release` / `destroy` and friends). It
/// implements OpenZeppelin's linear-with-cliff curve on top of the
/// curve-agnostic `vesting_wallet` primitive. An integrator who just wants
/// linear vesting touches only this module — they never construct a bare wallet
/// or mint a `VestedAmount` by hand.
///
/// # Why a separate module
///
/// Struct fields are module-private in Move, so only the module that declares
/// `Linear` can construct a `Linear` value, and therefore only this module can
/// build a `VestingWallet<Linear, Params, T>` (via `vesting_wallet::new`, which takes
/// the schedule by value) or mint a `VestedAmount<Linear>` (via
/// `vesting_wallet::mint_vested`). Keeping `Linear` in its own module — rather
/// than baking it into the primitive — leaves room for additional schedule
/// types (cliff-only, stepped, exponential, …) that follow this same shape
/// without bloating `vesting_wallet`.
///
/// # The curve
///
/// * Pre-start (`now < start_ms`): zero.
/// * Pre-cliff (`cliff_ms > 0` and `now < start_ms + cliff_ms`): zero. At the
///   cliff boundary the value jumps directly to the linear-from-start
///   proportion — the cliff gates the curve, it does not shift it.
/// * Mid-schedule: linear in elapsed time, computed with a u128 intermediate.
/// * Post-end: clamped to the wallet's total (`balance + released`).
///
/// The total is re-derived on every call from `balance + released`, so deposits
/// made at `t > start_ms` immediately participate in vesting at the current
/// proportion.
module openzeppelin_finance::linear_schedule;

use openzeppelin_finance::vesting_wallet::{Self, VestingWallet, VestedAmount};
use sui::clock::Clock;

// === Errors ===

const EZeroDuration: u64 = 0;
const EInvalidCliff: u64 = 1;
const ENotEnded: u64 = 2;

// === Types ===

/// The linear-with-cliff schedule (OpenZeppelin's `VestingWallet` shape).
/// `cliff_ms` is the only curve-specific parameter. Declared here, so only this
/// module can construct a `Linear` and therefore only this module can build a
/// `VestingWallet<Linear, Params, T>` or mint a `VestedAmount<Linear>`.
public struct Linear has drop {}

/// The linear-with-cliff params.
public struct Params has copy, drop, store {
    start_ms: u64,
    duration_ms: u64,
    cliff_ms: u64,
}

// === Constructors ===

/// Build a `VestingWallet<Linear, Params, T>` on the linear-with-cliff schedule.
/// Validates the cliff and returns the wallet by value so the caller can chain
/// deposit and topology selection in one PTB. Use `create_and_share` for the
/// common "share immediately" case.
public fun new<T>(
    beneficiary: address,
    start_ms: u64,
    cliff_ms: u64,
    duration_ms: u64,
    ctx: &mut TxContext,
): VestingWallet<Linear, Params, T> {
    assert!(duration_ms > 0, EZeroDuration);
    assert!(cliff_ms <= duration_ms, EInvalidCliff);

    vesting_wallet::new(Params { start_ms, duration_ms, cliff_ms }, beneficiary, ctx)
}

/// Sugar for the common case: build a linear wallet and share it in one call.
public fun create_and_share<T>(
    beneficiary: address,
    start_ms: u64,
    cliff_ms: u64,
    duration_ms: u64,
    ctx: &mut TxContext,
) {
    let wallet = new<T>(beneficiary, start_ms, cliff_ms, duration_ms, ctx);
    transfer::public_share_object(wallet);
}

// === Curve evaluation & release ===

/// The linear schedule curve evaluated at `clock.timestamp_ms()`. See the
/// module docs for the piecewise definition.
public fun vested<C>(
    wallet: &VestingWallet<Linear, Params, C>,
    clock: &Clock,
): VestedAmount<Linear> {
    wallet.mint_vested(
        Linear {},
        wallet.schedule_params(),
        linear_amount(wallet, clock),
    )
}

/// Evaluate the linear curve and release the not-yet-released portion in one
/// call — the common path for the linear schedule.
public fun release<C>(
    wallet: &mut VestingWallet<Linear, Params, C>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let v = vested(wallet, clock);
    wallet.release(v, ctx);
}

/// How much `release` would pay out right now, without minting a
/// `VestedAmount`. The client-friendly "what can I claim?" query.
public fun releasable<T>(wallet: &VestingWallet<Linear, Params, T>, clock: &Clock): u64 {
    linear_amount(wallet, clock) - wallet.released()
}

/// Tear down a drained, ended linear wallet: reclaim storage and drop the
/// `Linear` schedule. Wraps `vesting_wallet::destroy_empty`.
public fun destroy<T>(wallet: VestingWallet<Linear, Params, T>, clock: &Clock) {
    let Params { start_ms, duration_ms, cliff_ms: _ } = wallet.destroy_empty(Linear {});
    // QUESTION: should we remove this check, as it might only matter that the balance == 0?
    assert!(clock.timestamp_ms() >= start_ms + duration_ms, ENotEnded);
}

// === Accessors ===

public fun start<T>(wallet: &VestingWallet<Linear, Params, T>): u64 {
    wallet.schedule_params().start_ms
}

public fun duration<T>(wallet: &VestingWallet<Linear, Params, T>): u64 {
    wallet.schedule_params().duration_ms
}

public fun end<T>(wallet: &VestingWallet<Linear, Params, T>): u64 {
    let params = wallet.schedule_params();
    params.start_ms + params.duration_ms
}

/// Read the configured cliff length (ms from `start_ms`). `0` means no cliff.
public fun cliff<T>(wallet: &VestingWallet<Linear, Params, T>): u64 {
    wallet.schedule_params().cliff_ms
}

// === Internal ===

/// The linear curve's cumulative vested total at the current clock, as a `u64`.
/// Shared by `vested` and `releasable`.
fun linear_amount<T>(wallet: &VestingWallet<Linear, Params, T>, clock: &Clock): u64 {
    let now = clock.timestamp_ms();
    let Params { start_ms, duration_ms, cliff_ms } = wallet.schedule_params();

    if (now < start_ms) {
        0
    } else if (cliff_ms > 0 && now < start_ms + cliff_ms) {
        0
    } else {
        let total = wallet.balance() + wallet.released();
        if (now >= start_ms + duration_ms) {
            total
        } else {
            let elapsed = (now - start_ms) as u128;
            let v = ((total as u128) * elapsed) / (duration_ms as u128);
            v as u64
        }
    }
}

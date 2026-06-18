/// A discrete stepped (tranche) schedule for `vesting_wallet` - the "1/N every
/// period, after an optional cliff" curve that dominates real token grants.
///
/// This module declares the `Stepped` witness and its `Params`, plus the full
/// integrator API around them (`new` / `vested_amount` / `release` / `destroy` and
/// friends). It is a sibling of `linear_schedule`: same shape, same authority
/// model, a different curve. An integrator who wants tranche vesting touches only
/// this module - they never construct a bare wallet or mint a `VestedAmount` by
/// hand.
///
/// # Why a separate module
///
/// Struct fields are module-private in Move, so only this module can construct a
/// `Stepped` or a `Params` value, and therefore only this module can build a
/// `VestingWallet<Stepped, Params, C>` (via `vesting_wallet::new`, which takes the
/// `Params` by value) or mint a `VestedAmount<Stepped>` (via
/// `vesting_wallet::mint_vested_amount`, which takes the `Stepped` witness). See
/// `vesting_wallet`'s docs for the full rationale.
///
/// # The curve
///
/// Funds unlock in `steps` equal tranches, one every `period_ms`, so the schedule
/// runs for `period_ms * steps` and ends at `start_ms + period_ms * steps`.
///
/// - Pre-start (`now < start_ms`): zero.
/// - Pre-cliff (`cliff_ms > 0` and `now < start_ms + cliff_ms`): zero. The cliff
///   *gates* the staircase; it does not shift it. At the cliff boundary the curve
///   jumps straight to the value for however many full periods have already elapsed
///   - so a cliff longer than one period releases several tranches at once as a
///   catch-up, then resumes its regular cadence.
/// - Mid-schedule: a staircase. With `k` full periods elapsed
///   (`k = (now - start_ms) / period_ms`, `0 <= k < steps`), the cumulative vested
///   total is `total * k / steps`, computed with a u128 intermediate. The value is
///   flat across a period and steps up at each boundary.
/// - Post-end: clamped to the wallet's total (`balance + released`).
///
/// The total is re-derived on every call from `balance + released`, so deposits
/// made at `t > start_ms` immediately participate at the current step proportion.
module openzeppelin_finance::stepped_schedule;

use openzeppelin_finance::vesting_wallet::{Self, VestingWallet, VestedAmount};
use openzeppelin_math::rounding;
use openzeppelin_math::u64::mul_div;
use sui::clock::Clock;

// === Errors ===

/// `period_ms` was zero; each tranche must span a positive period.
#[error(code = 0)]
const EZeroPeriod: vector<u8> = "Period must be greater than zero";
/// `steps` was zero; a schedule must have at least one tranche.
#[error(code = 1)]
const EZeroSteps: vector<u8> = "Steps must be greater than zero";
/// `cliff_ms` exceeded the schedule duration (`period_ms * steps`); the cliff must
/// fall within the schedule.
#[error(code = 2)]
const EInvalidCliff: vector<u8> = "Cliff must not exceed duration";
/// `period_ms * steps`, or `start_ms` plus that duration, would overflow `u64`.
#[error(code = 3)]
const EScheduleOverflow: vector<u8> = "Schedule end (start + period * steps) would overflow u64";
/// `destroy` was called before the schedule's end (`start_ms + period_ms * steps`).
#[error(code = 4)]
const ENotEnded: vector<u8> = "Schedule has not ended yet";

// === Structs ===

/// The schedule witness for the stepped curve. Empty and `drop`-only: it carries no
/// data and exists solely as the authority token `vesting_wallet` requires.
/// Declared here, so only this module can construct a `Stepped` and therefore only
/// this module can mint a `VestedAmount<Stepped>` or tear down a
/// `VestingWallet<Stepped, Params, C>`.
public struct Stepped has drop {}

/// The stepped-schedule parameters, stored in the wallet.
public struct Params has copy, drop, store {
    /// Timestamp (ms) at which vesting begins. Before this, zero is vested.
    start_ms: u64,
    /// Length of each tranche period (ms); a new step unlocks every `period_ms`.
    period_ms: u64,
    /// Number of equal tranches; the schedule ends at `start_ms + period_ms * steps`.
    steps: u64,
    /// Cliff length (ms from `start_ms`); `0` means no cliff. Nothing vests until
    /// `start_ms + cliff_ms`, at which point the curve jumps to the staircase value
    /// for the periods elapsed so far.
    cliff_ms: u64,
}

// === Constructors ===

/// Build a `VestingWallet<Stepped, Params, C>` on the stepped schedule. Returns the
/// wallet by value so the caller can chain deposit and topology selection in one
/// PTB. Use `create_and_share` for the common "share immediately" case.
///
/// #### Parameters
/// - `beneficiary`: Address that every release pays out to.
/// - `start_ms`: Timestamp (ms) at which vesting begins.
/// - `cliff_ms`: Cliff length (ms from `start_ms`); `0` for no cliff.
/// - `period_ms`: Length of each tranche period (ms).
/// - `steps`: Number of equal tranches.
/// - `ctx`: Transaction context.
///
/// #### Returns
/// - A fresh, unfunded `VestingWallet<Stepped, Params, C>` owned by the caller.
///
/// #### Aborts
/// - `EZeroPeriod` if `period_ms == 0`.
/// - `EZeroSteps` if `steps == 0`.
/// - `EScheduleOverflow` if `period_ms * steps`, or `start_ms` plus that duration,
///   would overflow `u64`.
/// - `EInvalidCliff` if `cliff_ms > period_ms * steps`.
public fun new<C>(
    beneficiary: address,
    start_ms: u64,
    cliff_ms: u64,
    period_ms: u64,
    steps: u64,
    ctx: &mut TxContext,
): VestingWallet<Stepped, Params, C> {
    assert!(period_ms > 0, EZeroPeriod);
    assert!(steps > 0, EZeroSteps);

    let max = std::u64::max_value!();
    assert!(period_ms <= max / steps, EScheduleOverflow);
    let duration = period_ms * steps;
    assert!(cliff_ms <= duration, EInvalidCliff);
    assert!(duration <= max - start_ms, EScheduleOverflow);

    vesting_wallet::new(Params { start_ms, period_ms, steps, cliff_ms }, beneficiary, ctx)
}

/// Sugar for the common case: build a stepped wallet and immediately share it.
/// Parameters and aborts are identical to `new`; the wallet is made shared via
/// `transfer::public_share_object` instead of being returned.
public fun create_and_share<C>(
    beneficiary: address,
    start_ms: u64,
    cliff_ms: u64,
    period_ms: u64,
    steps: u64,
    ctx: &mut TxContext,
) {
    let wallet = new<C>(beneficiary, start_ms, cliff_ms, period_ms, steps, ctx);
    transfer::public_share_object(wallet);
}

// === Curve evaluation & release ===

/// Evaluate the stepped curve at `clock.timestamp_ms()` and mint the resulting
/// cumulative vested total as a `VestedAmount<Stepped>`. See the module docs for the
/// piecewise curve definition.
///
/// #### Returns
/// - A `VestedAmount<Stepped>` for `wallet` at the current clock, ready to pass to
///   `vesting_wallet::release` (or this module's `release`).
public fun vested_amount<C>(
    wallet: &VestingWallet<Stepped, Params, C>,
    clock: &Clock,
): VestedAmount<Stepped> {
    wallet.mint_vested_amount(
        Stepped {},
        vested_amount_raw(wallet, clock),
    )
}

/// Evaluate the stepped curve and release the not-yet-released portion in one
/// call - the common path for the stepped schedule.
public fun release<C>(
    wallet: &mut VestingWallet<Stepped, Params, C>,
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
public fun releasable<C>(wallet: &VestingWallet<Stepped, Params, C>, clock: &Clock): u64 {
    wallet.releasable(&vested_amount(wallet, clock))
}

/// Tear down a drained, ended stepped wallet: reclaim its storage rebate and drop
/// the `Stepped` schedule. Wraps `vesting_wallet::destroy_empty` and additionally
/// requires the schedule to have ended.
///
/// #### Parameters
/// - `wallet`: The wallet to destroy. Must hold a zero balance.
/// - `clock`: Sui `Clock`, used to check the schedule has ended.
///
/// #### Aborts
/// - `ENotEmpty` if the wallet still holds a balance (from `destroy_empty`).
/// - `ENotEnded` if called before the schedule's end (`start_ms + period_ms * steps`).
public fun destroy<C>(wallet: VestingWallet<Stepped, Params, C>, clock: &Clock) {
    // Require the schedule to have ended before teardown: destruction is
    // permissionless, so otherwise an empty wallet could be destroyed ahead of a
    // pending deposit, front-running funding intended to arrive later.
    assert!(clock.timestamp_ms() >= end(&wallet), ENotEnded);
    let Params { .. } = wallet.destroy_empty(Stepped {});
}

// === View helpers ===

/// Timestamp (ms) at which vesting begins.
public fun start<C>(wallet: &VestingWallet<Stepped, Params, C>): u64 {
    wallet.schedule_params().start_ms
}

/// Length of each tranche period (ms).
public fun period<C>(wallet: &VestingWallet<Stepped, Params, C>): u64 {
    wallet.schedule_params().period_ms
}

/// Number of equal tranches.
public fun steps<C>(wallet: &VestingWallet<Stepped, Params, C>): u64 {
    wallet.schedule_params().steps
}

/// Length of the vesting period (ms): `period_ms * steps`.
public fun duration<C>(wallet: &VestingWallet<Stepped, Params, C>): u64 {
    let params = wallet.schedule_params();
    params.period_ms * params.steps
}

/// Timestamp (ms) at which the schedule ends (`start_ms + period_ms * steps`).
public fun end<C>(wallet: &VestingWallet<Stepped, Params, C>): u64 {
    let params = wallet.schedule_params();
    params.start_ms + params.period_ms * params.steps
}

/// Read the configured cliff length (ms from `start_ms`). `0` means no cliff.
public fun cliff<C>(wallet: &VestingWallet<Stepped, Params, C>): u64 {
    wallet.schedule_params().cliff_ms
}

// === Private Functions ===

/// The stepped curve's cumulative vested total at the current clock, as a `u64`.
fun vested_amount_raw<C>(wallet: &VestingWallet<Stepped, Params, C>, clock: &Clock): u64 {
    let now = clock.timestamp_ms();
    let Params { start_ms, period_ms, steps, cliff_ms } = wallet.schedule_params();

    if (now < start_ms) {
        0
    } else if (cliff_ms > 0 && now < start_ms + cliff_ms) {
        0
    } else {
        let total = wallet.balance() + wallet.released();
        // SAFETY: construction guarantees `period_ms * steps` and`start_ms + period_ms * steps`
        // fit in u64, so neither arithmetic here overflows.
        if (now >= start_ms + period_ms * steps) {
            total
        } else {
            let elapsed_steps = (now - start_ms) / period_ms;
            // SAFETY: `now < start_ms + period_ms * steps`, so `elapsed_steps < steps`:
            // the staircase value stays strictly below `total` until the post-end clamp.
            mul_div(total, elapsed_steps, steps, rounding::down()).destroy_some()
        }
    }
}

// === Test-Only Helpers ===

/// Build a `Params` value for asserting against `event::events_by_type` (the
/// `Params` fields are module-private, so tests cannot construct one directly).
#[test_only]
public fun test_params(start_ms: u64, cliff_ms: u64, period_ms: u64, steps: u64): Params {
    Params { start_ms, period_ms, steps, cliff_ms }
}

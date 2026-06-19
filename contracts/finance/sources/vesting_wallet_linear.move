/// The stepped (tranche) schedule for `vesting_wallet` - the "1/N every period,
/// after an optional cliff" curve that dominates real token grants, with continuous
/// linear-with-cliff vesting available as its `period_ms = 1` limit.
///
/// This module declares the `Linear` witness and its `Params`, plus the full
/// integrator API around them (`params` / `params_continuous` / `new` /
/// `new_continuous` / `vested_amount` / `release` / `destroy` and friends). It
/// implements the curve on top of the curve-agnostic `vesting_wallet` primitive:
/// `params` validates and builds a tranche schedule (`period_ms`, `steps`), `new` is
/// sugar that hands that `Params` to `vesting_wallet::new`, and `params_continuous` /
/// `new_continuous` are the continuous linear (`period_ms = 1`) analogs. An integrator who wants the wallet built for them touches only this module -
/// they never construct a bare wallet or mint a `VestedAmount` by hand. A
/// curve-agnostic protocol that drives the bare `vesting_wallet` primitive itself
/// takes only `params` and mints the wallet on its own (see "Why a separate module").
///
/// # Why a separate module
///
/// Struct fields are module-private in Move, so only this module can construct a
/// `Linear` or a `Params` value, and therefore only this module can build a
/// `VestingWallet<Linear, Params, C>` (via `vesting_wallet::new`, which takes the
/// `Params` by value) or mint a `VestedAmount<Linear>` (via
/// `vesting_wallet::mint_vested_amount`, which takes the `Linear` witness). See
/// `vesting_wallet`'s docs for the full rationale.
///
/// The public `params` constructor is the seam this gives an external protocol: it
/// hands out a *validated* `Params` without surrendering the witness, so a
/// curve-agnostic wrapper can call `vesting_wallet::new<Linear, Params, C>` itself -
/// choosing its own topology and nesting - while curve evaluation and teardown, which
/// need `Linear`, stay gated to this module.
///
/// # The curve
///
/// Funds unlock in `steps` equal tranches, one every `period_ms`, so the schedule
/// runs for `period_ms * steps` and ends at `start_ms + period_ms * steps`.
/// `new_continuous` is the `period_ms = 1` limit, where every millisecond is its own
/// tranche and the staircase collapses to a straight line.
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
module openzeppelin_finance::vesting_wallet_linear;

use openzeppelin_finance::vesting_wallet::{Self, VestingWallet, VestedAmount};
use std::u64::mul_div;
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
/// `destroy` was called by an address other than the wallet's beneficiary.
#[error(code = 5)]
const ENotBeneficiary: vector<u8> = "Only the beneficiary may destroy the wallet";

// === Structs ===

/// The schedule witness for the stepped curve. Empty and `drop`-only: it carries no
/// data and exists solely as the authority token `vesting_wallet` requires.
/// Declared here, so only this module can construct a `Linear` and therefore only
/// this module can mint a `VestedAmount<Linear>` or tear down a
/// `VestingWallet<Linear, Params, C>`.
public struct Linear has drop {}

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

/// Build a validated `Params` value for the stepped (tranche) schedule, running the
/// same construction guards as `new`. This is the only way to obtain a `Params`
/// outside this module (its fields are module-private), so a curve-agnostic protocol
/// that drives the bare `vesting_wallet` primitive directly can mint the wallet
/// itself - `vesting_wallet::new<Linear, Params, C>(params(..), beneficiary, ctx)` -
/// without routing wallet creation through this module's `new`. `new` is sugar over
/// exactly this path.
///
/// #### Parameters
/// - `start_ms`: Timestamp (ms) at which vesting begins.
/// - `cliff_ms`: Cliff length (ms from `start_ms`); `0` for no cliff.
/// - `period_ms`: Length of each tranche period (ms).
/// - `steps`: Number of equal tranches.
///
/// #### Returns
/// - A validated `Params` for the stepped schedule.
///
/// #### Aborts
/// - `EZeroPeriod` if `period_ms == 0`.
/// - `EZeroSteps` if `steps == 0`.
/// - `EScheduleOverflow` if `period_ms * steps`, or `start_ms` plus that duration,
///   would overflow `u64`.
/// - `EInvalidCliff` if `cliff_ms > period_ms * steps`.
public fun params(start_ms: u64, cliff_ms: u64, period_ms: u64, steps: u64): Params {
    assert!(period_ms > 0, EZeroPeriod);
    assert!(steps > 0, EZeroSteps);

    let max = std::u64::max_value!();
    assert!(period_ms <= max / steps, EScheduleOverflow);
    let duration = period_ms * steps;
    assert!(cliff_ms <= duration, EInvalidCliff);
    assert!(duration <= max - start_ms, EScheduleOverflow);

    Params { start_ms, period_ms, steps, cliff_ms }
}

/// Build a validated `Params` value for the continuous linear-with-cliff schedule:
/// the stepped curve in the `period_ms = 1` limit (`steps = duration_ms`). The
/// `params_continuous`-to-`params` relationship mirrors `new_continuous`-to-`new`, so
/// a curve-agnostic protocol can drive `vesting_wallet::new` with a continuous
/// schedule without routing through this module's `new_continuous`.
///
/// #### Parameters
/// - `start_ms`: Timestamp (ms) at which vesting begins.
/// - `cliff_ms`: Cliff length (ms from `start_ms`); `0` for no cliff.
/// - `duration_ms`: Length of the vesting period (ms).
///
/// #### Returns
/// - A validated `Params` for the continuous linear schedule.
///
/// #### Aborts
/// - `EZeroSteps` if `duration_ms == 0`.
/// - `EInvalidCliff` if `cliff_ms > duration_ms`.
/// - `EScheduleOverflow` if `start_ms + duration_ms` would overflow `u64`.
public fun params_continuous(start_ms: u64, cliff_ms: u64, duration_ms: u64): Params {
    // The continuous curve is the stepped curve with one tranche per millisecond.
    // A zero `duration_ms` becomes zero `steps`, so `params` rejects it with `EZeroSteps`.
    params(start_ms, cliff_ms, 1, duration_ms)
}

/// Build a `VestingWallet<Linear, Params, C>` on the stepped (tranche) schedule.
/// Returns the wallet by value so the caller can chain deposit and topology
/// selection in one PTB. Use `create_and_share` for the common "share immediately"
/// case.
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
/// - A fresh, unfunded `VestingWallet<Linear, Params, C>` owned by the caller.
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
): VestingWallet<Linear, Params, C> {
    vesting_wallet::new(params(start_ms, cliff_ms, period_ms, steps), beneficiary, ctx)
}

/// Sugar for a continuous linear-with-cliff schedule: the stepped curve in the
/// `period_ms = 1` limit (`steps = duration_ms`), where every millisecond is its own
/// tranche and the curve rises linearly. Use `new` directly for coarser tranches.
/// Returns the wallet by value; use `create_and_share` for the common "share
/// immediately" case.
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
/// - `EZeroSteps` if `duration_ms == 0`.
/// - `EInvalidCliff` if `cliff_ms > duration_ms`.
/// - `EScheduleOverflow` if `start_ms + duration_ms` would overflow `u64`.
public fun new_continuous<C>(
    beneficiary: address,
    start_ms: u64,
    cliff_ms: u64,
    duration_ms: u64,
    ctx: &mut TxContext,
): VestingWallet<Linear, Params, C> {
    vesting_wallet::new(params_continuous(start_ms, cliff_ms, duration_ms), beneficiary, ctx)
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

/// Evaluate the stepped curve and release the not-yet-released portion in one
/// call - the common path for the stepped schedule.
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

/// Tear down a drained, ended stepped wallet: reclaim its storage rebate and drop
/// the `Linear` schedule. Wraps `vesting_wallet::destroy_empty` and additionally
/// requires the schedule to have ended and the caller to be the beneficiary.
///
/// Both extra gates guard against stranding an in-flight deposit. The ended gate
/// stops an empty wallet being destroyed ahead of a pending deposit, front-running
/// funding intended to arrive later. The beneficiary gate addresses the residual
/// case: a coin `public_transfer`'d to the wallet's address but not yet
/// `receive_and_deposit`'d is invisible to `destroy_empty`'s empty check, so a
/// permissionless teardown would let an arbitrary actor strand such a deposit and
/// pocket the storage rebate. Restricting teardown to the beneficiary keeps both the
/// strand risk and the rebate with the only party harmed by it.
///
/// #### Parameters
/// - `wallet`: The wallet to destroy. Must hold a zero balance.
/// - `clock`: Sui `Clock`, used to check the schedule has ended.
/// - `ctx`: Transaction context, used to check the caller is the beneficiary.
///
/// #### Aborts
/// - `ENotEmpty` if the wallet still holds a balance (from `destroy_empty`).
/// - `ENotEnded` if called before the schedule's end (`start_ms + period_ms * steps`).
/// - `ENotBeneficiary` if the caller is not the wallet's beneficiary.
public fun destroy<C>(wallet: VestingWallet<Linear, Params, C>, clock: &Clock, ctx: &TxContext) {
    assert!(clock.timestamp_ms() >= end(&wallet), ENotEnded);
    assert!(ctx.sender() == wallet.beneficiary(), ENotBeneficiary);
    let Params { .. } = wallet.destroy_empty(Linear {});
}

// === View helpers ===

/// Timestamp (ms) at which vesting begins.
public fun start<C>(wallet: &VestingWallet<Linear, Params, C>): u64 {
    wallet.schedule_params().start_ms
}

/// Length of each tranche period (ms).
public fun period<C>(wallet: &VestingWallet<Linear, Params, C>): u64 {
    wallet.schedule_params().period_ms
}

/// Number of equal tranches.
public fun steps<C>(wallet: &VestingWallet<Linear, Params, C>): u64 {
    wallet.schedule_params().steps
}

/// Length of the vesting period (ms): `period_ms * steps`.
public fun duration<C>(wallet: &VestingWallet<Linear, Params, C>): u64 {
    let params = wallet.schedule_params();
    params.period_ms * params.steps
}

/// Timestamp (ms) at which the schedule ends (`start_ms + period_ms * steps`).
public fun end<C>(wallet: &VestingWallet<Linear, Params, C>): u64 {
    let params = wallet.schedule_params();
    params.start_ms + params.period_ms * params.steps
}

/// Read the configured cliff length (ms from `start_ms`). `0` means no cliff.
public fun cliff<C>(wallet: &VestingWallet<Linear, Params, C>): u64 {
    wallet.schedule_params().cliff_ms
}

// === Private Functions ===

/// The stepped curve's cumulative vested total at the current clock, as a `u64`.
fun vested_amount_raw<C>(wallet: &VestingWallet<Linear, Params, C>, clock: &Clock): u64 {
    let now = clock.timestamp_ms();
    let Params { start_ms, period_ms, steps, cliff_ms } = wallet.schedule_params();

    if (now < start_ms) {
        0
    } else if (cliff_ms > 0 && now < start_ms + cliff_ms) {
        0
    } else {
        // SAFETY: depositing has a check ensuring no balance overflow can occur.
        let total = wallet.balance() + wallet.released();
        // SAFETY: construction guarantees `period_ms * steps` and`start_ms + period_ms * steps`
        // fit in u64, so neither arithmetic here overflows.
        if (now >= start_ms + period_ms * steps) {
            total
        } else {
            let elapsed_steps = (now - start_ms) / period_ms;
            // SAFETY: `now < start_ms + period_ms * steps`, so `elapsed_steps < steps`:
            // the staircase value stays strictly below `total` until the post-end clamp.
            mul_div(total, elapsed_steps, steps)
        }
    }
}

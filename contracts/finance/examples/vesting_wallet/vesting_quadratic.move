/// A backloaded (quadratic) vesting curve for `vesting_wallet` - a worked example of
/// a custom schedule that ships *only* the curve logic and no wallet wrapping.
///
/// `vesting_wallet_linear` wraps the whole wallet lifecycle (`new`, `release`,
/// `destroy`, ...) behind its own API. This module deliberately does the opposite: it
/// exposes only the operations that *require* the schedule's private types - a
/// `params` constructor (the `Params` fields are module-private), `vested_amount`
/// (minting needs the `Quadratic` witness), and `destroy` (consuming the teardown
/// receipt needs the witness too). Everything else - creating, funding, releasing, and
/// inspecting the wallet - the integrator drives by calling `vesting_wallet` directly
/// and composing the modules in a single PTB. See the tests for the end-to-end
/// composition.
///
/// The curve is `vested = total * (elapsed / duration)^2`, clamped to `total` at the
/// end: it vests slowly early and accelerates toward the deadline. It is
/// monotonically non-decreasing and bounded above by `total = balance + released` -
/// the two properties the primitive requires of a curve. The specific shape is
/// incidental; the point is the integration boundary.
///
/// # Teardown is the one lifecycle step that can't be fully composed
///
/// `vesting_wallet::destroy_empty` is permissionless, so the integrator can call it
/// directly to drain a wallet's storage rebate and get a `DestroyReceipt`. But the
/// receipt is a hot potato that only `vesting_wallet::consume_receipt` can retire, and
/// that call takes the witness `S` by value. This module cannot expose a bare
/// `public fun witness(): Quadratic` - that would let any module forge a
/// `VestedAmount<Quadratic>` and over-release. So the receipt-consuming half *must*
/// live here, as the single thin witness-gated `destroy` below. It is also where the
/// curve gets to veto a teardown: `destroy` aborts unless the schedule has ended,
/// reverting the whole PTB (including the `destroy_empty` that produced the receipt).
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `vesting_wallet` primitive can be integrated. It is not production-ready and must
/// not be deployed as-is.
module openzeppelin_finance::example_vesting_quadratic;

use openzeppelin_finance::vesting_wallet::{VestingWallet, VestedAmount, DestroyReceipt, DestroyCap};
use openzeppelin_math::rounding;
use openzeppelin_math::u64::mul_div;
use sui::clock::Clock;

// === Errors ===

/// `duration_ms` was zero; a schedule must span a positive duration.
#[error(code = 0)]
const EZeroDuration: vector<u8> = "Duration must be greater than zero";

/// `start_ms + duration_ms` would overflow `u64`.
#[error(code = 1)]
const EScheduleOverflow: vector<u8> = "Schedule end (start + duration) would overflow u64";

/// `destroy` was called before the schedule's end (`start_ms + duration_ms`).
#[error(code = 2)]
const ENotEnded: vector<u8> = "Schedule has not ended yet";

// === Structs ===

/// The schedule witness. Empty and `drop`-only: only this module can construct it, so
/// only this module can mint a `VestedAmount<Quadratic>`.
public struct Quadratic has drop {}

/// The curve's stored parameters. Fields are module-private, so only this module can
/// build one - which is exactly the authority `vesting_wallet::new` relies on.
public struct Params has copy, drop, store {
    /// Timestamp (ms) at which vesting begins.
    start_ms: u64,
    /// Length of the vesting period (ms).
    duration_ms: u64,
}

// === Public Functions ===

/// Validate and build the curve's parameters. This is the *only* constructor the
/// integrator needs from this module: they pass the returned `Params` straight into
/// `vesting_wallet::new<Quadratic, Params, C>` themselves - this module never wraps
/// wallet creation.
///
/// #### Aborts
/// - `EZeroDuration` if `duration_ms == 0`.
/// - `EScheduleOverflow` if `start_ms + duration_ms` would overflow `u64`.
public fun params(start_ms: u64, duration_ms: u64): Params {
    assert!(duration_ms > 0, EZeroDuration);
    assert!(duration_ms <= std::u64::max_value!() - start_ms, EScheduleOverflow);
    Params { start_ms, duration_ms }
}

/// Evaluate the quadratic curve at the current clock and mint the cumulative vested
/// total as a `VestedAmount<Quadratic>`, ready for `vesting_wallet::release`. Minting
/// is witness-gated, so this is the one release-path step that must live here; the
/// integrator calls `vesting_wallet::release` directly with the result.
public fun vested_amount<C>(
    wallet: &VestingWallet<Quadratic, Params, C>,
    clock: &Clock,
): VestedAmount<Quadratic> {
    wallet.mint_vested_amount(Quadratic {}, vested_amount_raw(wallet, clock))
}

/// What `release` would pay out right now - the client-friendly "what can I claim?"
/// query. A read-only view; it mutates nothing.
public fun releasable<C>(wallet: &VestingWallet<Quadratic, Params, C>, clock: &Clock): u64 {
    wallet.releasable(&vested_amount(wallet, clock))
}

/// Finalize teardown of a drained quadratic wallet by consuming the `DestroyReceipt`
/// that `vesting_wallet::destroy_empty` returns, together with the wallet's
/// `DestroyCap`. `destroy_empty` is the permissionless half (it reclaims the storage
/// rebate); this is the gated other half - only this module holds `Quadratic`, so only
/// it can unwrap the receipt - and it additionally requires the schedule to have ended.
/// Because the receipt is a hot potato consumed in the same PTB that produced it, a
/// failed gate here (or in the core cap check) aborts and reverts the whole teardown,
/// including the `destroy_empty` call.
///
/// Teardown authority is the `DestroyCap`, not the caller's address - this is the core
/// primitive's gate, so this curve does not (and must not) re-implement it as a
/// `ctx.sender() == beneficiary` check, which could never be satisfied for a wallet
/// whose beneficiary is an object address. The cap holder bears the strand risk for any
/// coin sent to the wallet's address but not yet `receive_and_deposit`'d, and must
/// sweep settled address-balance funds before `destroy_empty` accepts the teardown. The
/// ended gate stops a teardown ahead of a deposit intended to arrive later.
///
/// #### Aborts
/// - `EWrongCap` if `cap` was minted for a different wallet.
/// - `ENotEnded` if called before the schedule's end (`start_ms + duration_ms`).
public fun destroy(receipt: DestroyReceipt<Quadratic, Params>, cap: DestroyCap, clock: &Clock) {
    let params = receipt.consume_receipt(cap, Quadratic {});
    assert!(clock.timestamp_ms() >= params.calculate_end(), ENotEnded);
}

// === View helpers ===

/// Timestamp (ms) at which vesting begins. `Params` fields are module-private, so
/// these readers are the only way for an integrator to inspect the schedule.
public fun start_ms<C>(wallet: &VestingWallet<Quadratic, Params, C>): u64 {
    wallet.schedule_params().start_ms
}

/// Length of the vesting period (ms).
public fun duration_ms<C>(wallet: &VestingWallet<Quadratic, Params, C>): u64 {
    wallet.schedule_params().duration_ms
}

/// Timestamp (ms) at which the schedule ends (`start_ms + duration_ms`).
public fun end_ms<C>(wallet: &VestingWallet<Quadratic, Params, C>): u64 {
    wallet.schedule_params().calculate_end()
}

// === Private Functions ===

/// The schedule's end timestamp (ms), `start_ms + duration_ms`, derived from `Params`
/// alone so `destroy` can check it after the wallet is already gone.
fun calculate_end(params: &Params): u64 {
    params.start_ms + params.duration_ms
}

/// The quadratic curve's cumulative vested total at the current clock.
fun vested_amount_raw<C>(wallet: &VestingWallet<Quadratic, Params, C>, clock: &Clock): u64 {
    let Params { start_ms, duration_ms } = wallet.schedule_params();
    let now = clock.timestamp_ms();

    if (now <= start_ms) {
        return 0
    };

    // SAFETY: depositing has a check ensuring no balance overflow can occur.
    let total = wallet.balance() + wallet.released();
    // SAFETY: construction guarantees `start_ms + duration_ms` fit in u64.
    if (now >= start_ms + duration_ms) {
        // Post-end: clamp to the wallet's total.
        total
    } else {
        // SAFETY: total * (elapsed / duration)^2, via two `mul_div`s so the squared ratio
        // never leaves u64. `elapsed < duration`, so the result stays below `total`.
        let elapsed = now - start_ms;
        mul_div(
            mul_div(total, elapsed, duration_ms, rounding::down()).destroy_some(),
            elapsed,
            duration_ms,
            rounding::down(),
        ).destroy_some()
    }
}

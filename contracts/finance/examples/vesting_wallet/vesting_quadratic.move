/// A backloaded (quadratic) vesting curve for `vesting_wallet` - a worked example of
/// a custom schedule that ships *only* the curve logic and no wallet wrapping.
///
/// `vesting_wallet_linear` wraps the whole wallet lifecycle (`new`, `release`,
/// `destroy`, ...) behind its own API. This module deliberately does the opposite: it
/// exposes only the two operations that *require* the schedule's private types - a
/// `params` constructor (the `Params` fields are module-private) and `vested_amount`
/// (minting needs the `Quadratic` witness). Everything else - creating, funding,
/// releasing, and inspecting the wallet - the integrator drives by calling
/// `vesting_wallet` directly and composing the two modules in a single PTB. See the
/// tests for the end-to-end composition.
///
/// The curve is `vested = total * (elapsed / duration)^2`, clamped to `total` at the
/// end: it vests slowly early and accelerates toward the deadline. It is
/// monotonically non-decreasing and bounded above by `total = balance + released` -
/// the two properties the primitive requires of a curve. The specific shape is
/// incidental; the point is the integration boundary.
///
/// # Teardown is the one operation that can't be composed
///
/// `vesting_wallet::destroy_empty` takes the witness `S` by value, and this module
/// cannot expose a bare `public fun witness(): Quadratic` - that would let any module
/// forge a `VestedAmount<Quadratic>` and over-release. So a schedule module that ships
/// *no* wrapping either omits teardown (its wallets are never reclaimed) or adds a
/// single thin witness-gated `destroy`. This example takes the former path and leaves
/// teardown out, to keep the surface to pure curve logic.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `vesting_wallet` primitive can be integrated. It is not production-ready and must
/// not be deployed as-is.
module openzeppelin_finance::example_vesting_quadratic;

use openzeppelin_finance::vesting_wallet::{VestingWallet, VestedAmount};
use std::u64::mul_div;
use sui::clock::Clock;

// === Errors ===

/// `duration_ms` was zero; a schedule must span a positive duration.
#[error(code = 0)]
const EZeroDuration: vector<u8> = "Duration must be greater than zero";
/// `start_ms + duration_ms` would overflow `u64`.
#[error(code = 1)]
const EScheduleOverflow: vector<u8> = "Schedule end (start + duration) would overflow u64";

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

// === View helpers ===

/// Timestamp (ms) at which vesting begins. `Params` fields are module-private, so
/// these readers are the only way for an integrator to inspect the schedule.
public fun start<C>(wallet: &VestingWallet<Quadratic, Params, C>): u64 {
    wallet.schedule_params().start_ms
}

/// Length of the vesting period (ms).
public fun duration<C>(wallet: &VestingWallet<Quadratic, Params, C>): u64 {
    wallet.schedule_params().duration_ms
}

/// Timestamp (ms) at which the schedule ends (`start_ms + duration_ms`).
public fun end<C>(wallet: &VestingWallet<Quadratic, Params, C>): u64 {
    let params = wallet.schedule_params();
    params.start_ms + params.duration_ms
}

// === Private Functions ===

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
        // total * (elapsed / duration)^2, via two `mul_div`s so the squared ratio
        // never leaves u64. `elapsed < duration`, so the result stays below `total`.
        let elapsed = now - start_ms;
        mul_div(mul_div(total, elapsed, duration_ms), elapsed, duration_ms)
    }
}

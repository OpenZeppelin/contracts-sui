/// A graded (unequal-tranche) schedule for `vesting_wallet` - the "release different
/// percentages at different times" curve, e.g. 10% at 6 months, then 40% at 1 year,
/// then 100% at 2 years. Where `vesting_wallet_linear` unlocks equal tranches on a
/// fixed cadence, this curve unlocks a caller-defined cumulative percentage at each of
/// a caller-defined set of time offsets.
///
/// This module declares the `Graded` witness and its `Params`, plus the full
/// integrator API around them (`new` / `vested_amount` / `release` / `destroy` and
/// friends). It implements the curve on top of the curve-agnostic `vesting_wallet`
/// primitive: an integrator who wants graded vesting touches only this module - they
/// never construct a bare wallet or mint a `VestedAmount` by hand.
///
/// # Why a separate module
///
/// Struct fields are module-private in Move, so only this module can construct a
/// `Graded` or a `Params` value, and therefore only this module can build a
/// `VestingWallet<Graded, Params, C>` (via `vesting_wallet::new`, which takes the
/// `Params` by value) or mint a `VestedAmount<Graded>` (via
/// `vesting_wallet::mint_vested_amount`, which takes the `Graded` witness). See
/// `vesting_wallet`'s docs for the full rationale.
///
/// # The curve
///
/// The schedule is a list of `stages`, each a `(offset_ms, cumulative_bps)` pair given
/// as two parallel vectors. `offset_ms` is milliseconds from `start_ms`;
/// `cumulative_bps` is the cumulative fraction vested *at and after* that offset, in
/// basis points (`10_000` bps = 100%). Both vectors are validated at construction to
/// be strictly increasing, with the final `cumulative_bps` exactly `10_000` so the
/// schedule eventually vests the entire balance.
///
/// - Pre-start (`now < start_ms`): zero.
/// - Mid-schedule: the value steps up at each stage offset and is flat between
///   offsets. With `k` the highest stage whose offset has elapsed
///   (`offsets_ms[k] <= now - start_ms`), the cumulative vested total is
///   `total * cumulative_bps[k] / 10_000`, computed with a u128 intermediate. Before
///   the first stage's offset, the value is zero.
/// - Post-end: once the last stage's offset has elapsed, `cumulative_bps` is `10_000`,
///   so the value clamps to the wallet's total (`balance + released`).
///
/// The total is re-derived on every call from `balance + released`, so deposits made
/// at `t > start_ms` immediately participate at the current stage proportion.
///
/// # No separate cliff
///
/// Unlike `vesting_wallet_linear`, this curve has no dedicated `cliff` parameter: with
/// arbitrary stage offsets a cliff is redundant. A "nothing until month 6, then 25%"
/// cliff is just the first stage `(6 months, 2_500 bps)`; the curve already reads zero
/// before the first stage offset.
module openzeppelin_finance::vesting_wallet_graded;

use openzeppelin_finance::vesting_wallet::{Self, VestingWallet, VestedAmount};
use std::u64::mul_div;
use sui::clock::Clock;

// === Constants ===

/// Basis-point denominator: `10_000` bps == 100%. The final `cumulative_bps` must
/// equal this so the schedule vests the full balance.
const BPS_DENOMINATOR: u64 = 10_000;

// === Errors ===

/// The schedule had no stages; a schedule must have at least one `(offset, bps)` pair.
#[error(code = 0)]
const EEmptySchedule: vector<u8> = "Schedule must have at least one stage";
/// `offsets_ms` and `cumulative_bps` had different lengths; each offset needs exactly
/// one cumulative percentage.
#[error(code = 1)]
const ELengthMismatch: vector<u8> = "offsets_ms and cumulative_bps must have equal length";
/// `offsets_ms` was not strictly increasing; stage offsets must be ordered and distinct.
#[error(code = 2)]
const EUnsortedOffsets: vector<u8> = "Stage offsets must be strictly increasing";
/// `cumulative_bps` was not strictly increasing from a positive first value; each stage
/// must vest strictly more than the previous one.
#[error(code = 3)]
const EInvalidBps: vector<u8> = "Cumulative bps must be strictly increasing and positive";
/// The final `cumulative_bps` was not exactly `10_000`; the schedule must eventually
/// vest the full balance.
#[error(code = 4)]
const EIncompleteSchedule: vector<u8> = "Final cumulative bps must be 10000 (100%)";
/// `start_ms` plus the last stage offset would overflow `u64`.
#[error(code = 5)]
const EScheduleOverflow: vector<u8> = "Schedule end (start + last offset) would overflow u64";
/// `destroy` was called before the schedule's end (`start_ms + last offset`).
#[error(code = 6)]
const ENotEnded: vector<u8> = "Schedule has not ended yet";

// === Structs ===

/// The schedule witness for the graded curve. Empty and `drop`-only: it carries no
/// data and exists solely as the authority token `vesting_wallet` requires. Declared
/// here, so only this module can construct a `Graded` and therefore only this module
/// can mint a `VestedAmount<Graded>` or tear down a `VestingWallet<Graded, Params, C>`.
public struct Graded has drop {}

/// The graded-schedule parameters, stored in the wallet. The two vectors are parallel:
/// stage `i` unlocks `cumulative_bps[i]` of the total at `start_ms + offsets_ms[i]`.
/// Both are validated at construction (see `new`).
public struct Params has copy, drop, store {
    /// Timestamp (ms) at which vesting begins. Before this, zero is vested.
    start_ms: u64,
    /// Per-stage offsets (ms from `start_ms`), strictly increasing. `offsets_ms[i]` is
    /// when stage `i` unlocks.
    offsets_ms: vector<u64>,
    /// Per-stage cumulative fraction vested in basis points, strictly increasing with
    /// the final entry exactly `10_000`. `cumulative_bps[i]` is the total fraction
    /// vested once stage `i`'s offset has elapsed.
    cumulative_bps: vector<u64>,
}

// === Constructors ===

/// Build a `VestingWallet<Graded, Params, C>` on a graded schedule. Returns the wallet
/// by value so the caller can chain deposit and topology selection in one PTB. Use
/// `create_and_share` for the common "share immediately" case.
///
/// The two vectors are parallel: stage `i` unlocks a cumulative `cumulative_bps[i]` of
/// the wallet's total at `start_ms + offsets_ms[i]`.
///
/// #### Parameters
/// - `beneficiary`: Address that every release pays out to.
/// - `start_ms`: Timestamp (ms) at which vesting begins.
/// - `offsets_ms`: Per-stage offsets (ms from `start_ms`), strictly increasing.
/// - `cumulative_bps`: Per-stage cumulative basis points, strictly increasing and
///   positive, with the final entry exactly `10_000`.
/// - `ctx`: Transaction context.
///
/// #### Returns
/// - A fresh, unfunded `VestingWallet<Graded, Params, C>` owned by the caller.
///
/// #### Aborts
/// - `EEmptySchedule` if `offsets_ms` is empty.
/// - `ELengthMismatch` if the two vectors have different lengths.
/// - `EUnsortedOffsets` if `offsets_ms` is not strictly increasing.
/// - `EInvalidBps` if `cumulative_bps` is not strictly increasing from a positive
///   first value.
/// - `EIncompleteSchedule` if the final `cumulative_bps` is not `10_000`.
/// - `EScheduleOverflow` if `start_ms` plus the last offset would overflow `u64`.
public fun new<C>(
    beneficiary: address,
    start_ms: u64,
    offsets_ms: vector<u64>,
    cumulative_bps: vector<u64>,
    ctx: &mut TxContext,
): VestingWallet<Graded, Params, C> {
    let n = offsets_ms.length();
    assert!(n > 0, EEmptySchedule);
    assert!(cumulative_bps.length() == n, ELengthMismatch);

    // Walk the stages once, checking both vectors are strictly increasing. Seeding
    // `last_bps` at 0 forces the first cumulative bps to be positive; the offset check
    // skips index 0 since the first offset has no predecessor (0 is a valid first
    // offset - it unlocks at `start_ms`).
    let mut i = 0;
    let mut last_off = 0;
    let mut last_bps = 0;
    while (i < n) {
        let off = offsets_ms[i];
        let bps = cumulative_bps[i];
        if (i > 0) assert!(off > last_off, EUnsortedOffsets);
        assert!(bps > last_bps, EInvalidBps);
        last_off = off;
        last_bps = bps;
        i = i + 1;
    };
    // The final cumulative bps is the largest (strictly increasing), so requiring it to
    // equal `10_000` also guarantees every earlier entry is below `10_000`.
    assert!(last_bps == BPS_DENOMINATOR, EIncompleteSchedule);

    // `last_off` now holds the last offset; the schedule end must fit in u64.
    assert!(last_off <= std::u64::max_value!() - start_ms, EScheduleOverflow);

    vesting_wallet::new(Params { start_ms, offsets_ms, cumulative_bps }, beneficiary, ctx)
}

/// Sugar for the common case: build a graded wallet and immediately share it.
/// Parameters and aborts are identical to `new`; the wallet is made shared via
/// `transfer::public_share_object` instead of being returned.
public fun create_and_share<C>(
    beneficiary: address,
    start_ms: u64,
    offsets_ms: vector<u64>,
    cumulative_bps: vector<u64>,
    ctx: &mut TxContext,
) {
    let wallet = new<C>(beneficiary, start_ms, offsets_ms, cumulative_bps, ctx);
    transfer::public_share_object(wallet);
}

// === Curve evaluation & release ===

/// Evaluate the graded curve at `clock.timestamp_ms()` and mint the resulting
/// cumulative vested total as a `VestedAmount<Graded>`. See the module docs for the
/// piecewise curve definition.
///
/// #### Returns
/// - A `VestedAmount<Graded>` for `wallet` at the current clock, ready to pass to
///   `vesting_wallet::release` (or this module's `release`).
public fun vested_amount<C>(
    wallet: &VestingWallet<Graded, Params, C>,
    clock: &Clock,
): VestedAmount<Graded> {
    wallet.mint_vested_amount(
        Graded {},
        vested_amount_raw(wallet, clock),
    )
}

/// Evaluate the graded curve and release the not-yet-released portion in one call -
/// the common path for the graded schedule.
public fun release<C>(
    wallet: &mut VestingWallet<Graded, Params, C>,
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
public fun releasable<C>(wallet: &VestingWallet<Graded, Params, C>, clock: &Clock): u64 {
    wallet.releasable(&vested_amount(wallet, clock))
}

/// Tear down a drained, ended graded wallet: reclaim its storage rebate and drop the
/// `Graded` schedule. Wraps `vesting_wallet::destroy_empty` and additionally requires
/// the schedule to have ended.
///
/// #### Parameters
/// - `wallet`: The wallet to destroy. Must hold a zero balance.
/// - `clock`: Sui `Clock`, used to check the schedule has ended.
///
/// #### Aborts
/// - `ENotEmpty` if the wallet still holds a balance (from `destroy_empty`).
/// - `ENotEnded` if called before the schedule's end (`start_ms + last offset`).
public fun destroy<C>(wallet: VestingWallet<Graded, Params, C>, clock: &Clock) {
    // Require the schedule to have ended before teardown: destruction is permissionless,
    // so otherwise an empty wallet could be destroyed ahead of a pending deposit,
    // front-running funding intended to arrive later.
    assert!(clock.timestamp_ms() >= end(&wallet), ENotEnded);
    let Params { .. } = wallet.destroy_empty(Graded {});
}

// === View helpers ===

/// Timestamp (ms) at which vesting begins.
public fun start<C>(wallet: &VestingWallet<Graded, Params, C>): u64 {
    wallet.schedule_params().start_ms
}

/// Per-stage offsets (ms from `start_ms`).
public fun offsets<C>(wallet: &VestingWallet<Graded, Params, C>): vector<u64> {
    wallet.schedule_params().offsets_ms
}

/// Per-stage cumulative basis points.
public fun cumulative_bps<C>(wallet: &VestingWallet<Graded, Params, C>): vector<u64> {
    wallet.schedule_params().cumulative_bps
}

/// Number of stages in the schedule.
public fun stage_count<C>(wallet: &VestingWallet<Graded, Params, C>): u64 {
    wallet.schedule_params().offsets_ms.length()
}

/// Length of the vesting period (ms): the last stage offset.
public fun duration<C>(wallet: &VestingWallet<Graded, Params, C>): u64 {
    let offsets_ms = wallet.schedule_params().offsets_ms;
    offsets_ms[offsets_ms.length() - 1]
}

/// Timestamp (ms) at which the schedule ends (`start_ms + last offset`).
public fun end<C>(wallet: &VestingWallet<Graded, Params, C>): u64 {
    let Params { start_ms, offsets_ms, .. } = wallet.schedule_params();
    start_ms + offsets_ms[offsets_ms.length() - 1]
}

// === Private Functions ===

/// The graded curve's cumulative vested total at the current clock, as a `u64`.
fun vested_amount_raw<C>(wallet: &VestingWallet<Graded, Params, C>, clock: &Clock): u64 {
    let now = clock.timestamp_ms();
    let Params { start_ms, offsets_ms, cumulative_bps } = wallet.schedule_params();

    if (now < start_ms) {
        0
    } else {
        let elapsed = now - start_ms;
        // Highest stage whose offset has elapsed determines the cumulative bps; stays 0
        // before the first stage offset. Vesting schedules have few stages, so a linear
        // scan is both simplest and cheap.
        let n = offsets_ms.length();
        let mut bps = 0;
        let mut i = 0;
        while (i < n && offsets_ms[i] <= elapsed) {
            bps = cumulative_bps[i];
            i = i + 1;
        };

        if (bps == 0) {
            0
        } else {
            // SAFETY: depositing has a check ensuring no balance overflow can occur.
            let total = wallet.balance() + wallet.released();
            // SAFETY: `bps <= BPS_DENOMINATOR` (construction caps it at `10_000`), and
            // `mul_div` uses a u128 intermediate, so `total * bps` cannot overflow. At
            // the last stage `bps == BPS_DENOMINATOR`, so this clamps exactly to `total`.
            mul_div(total, bps, BPS_DENOMINATOR)
        }
    }
}

// === Test-Only Helpers ===

/// Build a `Params` value for asserting against `event::events_by_type` (the `Params`
/// fields are module-private, so tests cannot construct one directly).
#[test_only]
public fun test_params(
    start_ms: u64,
    offsets_ms: vector<u64>,
    cumulative_bps: vector<u64>,
): Params {
    Params { start_ms, offsets_ms, cumulative_bps }
}

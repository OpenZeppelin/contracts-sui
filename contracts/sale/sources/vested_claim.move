/// Library-side consumer for `VestedAllocation<S, VestingScheduleParams>`.
///
/// `prefunded_sale::claim_into_vesting` returns a `VestedAllocation<S, VestingScheduleParams>`
/// hot-potato whose inner `Coin<S>` cannot be extracted outside the
/// library (the carrier has no `drop`/`key`/`store` and its fields are
/// private to `sale.move`). The functions in this module are the only
/// disposal paths. Each one converts the allocation into a
/// `VestingWallet<S>` that honors the sale's recorded schedule, so the
/// buyer cannot fast-path around vesting by skipping this step.
///
/// ### Topologies
///
/// `into_shared_wallet` shares the resulting wallet. Anyone can poke
/// `release`; the wallet always pays out to the recorded beneficiary
/// (the buyer's purchase address). Use when a relay, scheduler, or
/// wallet UI should trigger release without the buyer being online.
///
/// `into_owned_wallet` transfers the wallet to the buyer instead. Only
/// the buyer's transactions can pass `&mut`, so only the buyer can
/// drive release. The vendored wallet has no beneficiary migration, so
/// the original beneficiary is the only address that will ever receive
/// payouts regardless of who holds the wallet object.
///
/// ### Why this lives in the library
///
/// Closing the "buyer calls `prefunded_sale::claim` and skips vesting"
/// bypass requires that the only path producing a `Coin<S>` for a
/// vested sale also enforces the schedule. That has to live next to
/// `prefunded_sale` in the audited library, not in integrator code
/// where a malicious or sloppy integration could expose a coin-leaking
/// shortcut.
///
/// Different wallet shapes (milestone, hybrid, clawback-capable) would
/// be siblings of this module - each one a library-side consumer with
/// its own audit story. v1 ships the vesting-schedule-agnostic shape.
module openzeppelin_sale::vested_claim;

use openzeppelin_finance::vesting_wallet::{Self, VestingWallet};
use openzeppelin_sale::vested_allocation::VestedAllocation;
use sui::coin;

/// Consume a `VestedAllocation<S, VestingScheduleParams>` into a fresh
/// `VestingWallet<S>` matching the sale's schedule.
public fun into_wallet<Witness: drop, VestingScheduleParams: copy + drop + store, S>(
    allocation: VestedAllocation<S, VestingScheduleParams>,
    ctx: &mut TxContext,
): VestingWallet<Witness, VestingScheduleParams, S> {
    let (balance, schedule_params, beneficiary, _sale_id) = allocation.unpack_vested_allocation();
    let mut wallet = vesting_wallet::new<Witness, VestingScheduleParams, S>(
        schedule_params,
        beneficiary,
        ctx,
    );
    wallet.deposit(coin::from_balance(balance, ctx));
    wallet
}

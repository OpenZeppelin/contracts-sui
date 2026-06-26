module openzeppelin_finance::vesting_wallet_linear_tests;

use openzeppelin_finance::vesting_wallet::{Self, VestingWallet, Created, Released, Destroyed};
use openzeppelin_finance::vesting_wallet_linear::{Self, Linear, Params};
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::clock::{Self, Clock};
use sui::coin;
use sui::event;
use sui::test_scenario::{Self, Scenario};

use fun fund as VestingWallet.fund;
use fun vested as VestingWallet.vested;

/// Phantom coin marker for the vested asset.
public struct USDC has drop {}

const BENEFICIARY: address = @0xB0B;

// === Test-Only Helpers ===

fun setup(t0: u64): (Scenario, Clock) {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(t0);
    (test, clk)
}

fun new_stepped(
    start: u64,
    cliff: u64,
    period: u64,
    steps: u64,
    ctx: &mut TxContext,
): VestingWallet<Linear, Params, USDC> {
    vesting_wallet_linear::new<USDC>(BENEFICIARY, start, cliff, period, steps, ctx)
}

fun new_continuous(
    start: u64,
    cliff: u64,
    duration: u64,
    ctx: &mut TxContext,
): VestingWallet<Linear, Params, USDC> {
    vesting_wallet_linear::new_continuous<USDC>(BENEFICIARY, start, cliff, duration, ctx)
}

fun fund(wallet: &mut VestingWallet<Linear, Params, USDC>, amount: u64) {
    wallet.deposit(balance::create_for_testing(amount));
}

/// The curve's cumulative vested total at the given clock.
fun vested(wallet: &VestingWallet<Linear, Params, USDC>, clk: &Clock): u64 {
    vesting_wallet_linear::vested_amount(wallet, clk).amount()
}

// ====================================================================
// Stepped schedule (`new`)
// ====================================================================

// === Construction guards ===

// A zero period is rejected.
#[test, expected_failure(abort_code = vesting_wallet_linear::EZeroPeriod)]
fun new_rejects_zero_period() {
    let mut ctx = tx_context::dummy();
    // `new` aborts before returning; `destroy` only satisfies the type checker.
    destroy(new_stepped(0, 0, 0, 4, &mut ctx));
}

// A zero step count is rejected.
#[test, expected_failure(abort_code = vesting_wallet_linear::EZeroSteps)]
fun new_rejects_zero_steps() {
    let mut ctx = tx_context::dummy();
    destroy(new_stepped(0, 0, 1000, 0, &mut ctx));
}

// A cliff longer than the schedule duration (period * steps) is rejected.
#[test, expected_failure(abort_code = vesting_wallet_linear::EInvalidCliff)]
fun new_rejects_cliff_exceeding_duration() {
    let mut ctx = tx_context::dummy();
    // duration = 1000 * 4 = 4000; cliff 4001 exceeds it.
    destroy(new_stepped(0, 4001, 1000, 4, &mut ctx));
}

// A schedule whose duration (period * steps) would overflow u64 is rejected.
#[test, expected_failure(abort_code = vesting_wallet_linear::EScheduleOverflow)]
fun new_rejects_duration_overflow() {
    let mut ctx = tx_context::dummy();
    destroy(new_stepped(0, 0, std::u64::max_value!(), 2, &mut ctx));
}

// A schedule whose end (start + period * steps) would overflow u64 is rejected.
#[test, expected_failure(abort_code = vesting_wallet_linear::EScheduleOverflow)]
fun new_rejects_end_overflow() {
    let mut ctx = tx_context::dummy();
    destroy(new_stepped(std::u64::max_value!() - 999, 0, 1000, 1, &mut ctx));
}

// Boundary: a schedule whose end is exactly u64::MAX is valid and `end_ms()`
// does not abort.
#[test]
fun new_accepts_end_at_u64_max_boundary() {
    let mut ctx = tx_context::dummy();
    let max = std::u64::max_value!();

    let wallet = new_stepped(max - 1000, 0, 1000, 1, &mut ctx);
    assert_eq!(vesting_wallet_linear::end_ms(&wallet), max);

    destroy(wallet);
}

// Accept boundary: cliff == duration is allowed; nothing vests until the end,
// then the curve jumps straight to the full total.
#[test]
fun new_accepts_cliff_equal_to_duration() {
    let (mut test, mut clk) = setup(0);

    // duration = 1000 * 4 = 4000.
    let mut wallet = new_stepped(0, 4000, 1000, 4, test.ctx());
    wallet.fund(1000);

    clk.set_for_testing(3999);
    assert_eq!(wallet.vested(&clk), 0); // still gated by the cliff
    clk.set_for_testing(4000);
    assert_eq!(wallet.vested(&clk), 1000); // cliff boundary == end: full total

    destroy(wallet);
    destroy(clk);
    test.end();
}

// === Construction state & topology ===

// `Created` is emitted exactly once with the full payload asserted, and the params
// are readable through the accessors.
#[test]
fun new_sets_params_and_emits_created() {
    let (mut test, clk) = setup(0);

    let wallet = new_stepped(100, 250, 1000, 4, test.ctx());

    assert_eq!(vesting_wallet_linear::start_ms(&wallet), 100);
    assert_eq!(vesting_wallet_linear::cliff_ms(&wallet), 250);
    assert_eq!(vesting_wallet_linear::period_ms(&wallet), 1000);
    assert_eq!(vesting_wallet_linear::steps(&wallet), 4);
    assert_eq!(vesting_wallet_linear::duration_ms(&wallet), 4000);
    assert_eq!(vesting_wallet_linear::end_ms(&wallet), 4100);

    let created = event::events_by_type<Created<Linear, Params, USDC>>();
    assert_eq!(created.length(), 1);
    assert_eq!(
        created[0],
        vesting_wallet::test_new_created<Linear, Params, USDC>(
            object::id(&wallet),
            BENEFICIARY,
            vesting_wallet_linear::params(100, 250, 1000, 4),
        ),
    );

    destroy(wallet);
    destroy(clk);
    test.end();
}

// `params` is the seam for a curve-agnostic protocol: it hands out a validated
// `Params` that drives the bare `vesting_wallet` primitive directly, producing a
// wallet equivalent to one built by `new` - the accessors and curve read the same.
#[test]
fun params_drives_bare_primitive() {
    let (mut test, mut clk) = setup(0);

    let p = vesting_wallet_linear::params(100, 250, 1000, 4);
    let mut wallet = vesting_wallet::new<Linear, Params, USDC>(p, BENEFICIARY, test.ctx());
    wallet.fund(1000);

    assert_eq!(vesting_wallet_linear::start_ms(&wallet), 100);
    assert_eq!(vesting_wallet_linear::cliff_ms(&wallet), 250);
    assert_eq!(vesting_wallet_linear::period_ms(&wallet), 1000);
    assert_eq!(vesting_wallet_linear::steps(&wallet), 4);
    assert_eq!(vesting_wallet_linear::end_ms(&wallet), 4100);

    // The curve evaluates identically to a `new`-built wallet: one step elapsed at
    // t = 1100 (100 start + 1000 period), so 1000 * 1 / 4 = 250.
    clk.set_for_testing(1100);
    assert_eq!(wallet.vested(&clk), 250);

    destroy(wallet);
    destroy(clk);
    test.end();
}

// The construction guards in `params` are exercised through `new` above; `new`
// delegates validation to `params`, so a guard reached via `params` directly aborts
// with the same code.
#[test, expected_failure(abort_code = vesting_wallet_linear::EZeroPeriod)]
fun params_rejects_zero_period() {
    vesting_wallet_linear::params(0, 0, 0, 4);
}

// `create_and_share` puts the wallet into the shared topology.
#[test]
fun create_and_share_shares_wallet() {
    let (mut test, clk) = setup(0);

    vesting_wallet_linear::create_and_share<USDC>(BENEFICIARY, 0, 0, 1000, 4, test.ctx());

    test.next_tx(@0x1);
    let wallet = test.take_shared<VestingWallet<Linear, Params, USDC>>();
    assert_eq!(wallet.beneficiary(), BENEFICIARY);
    assert_eq!(vesting_wallet_linear::duration_ms(&wallet), 4000);
    test_scenario::return_shared(wallet);

    destroy(clk);
    test.end();
}

// `create_and_share_continuous` puts a continuous wallet into the shared topology.
#[test]
fun create_and_share_continuous_shares_wallet() {
    let (mut test, clk) = setup(0);

    vesting_wallet_linear::create_and_share_continuous<USDC>(BENEFICIARY, 0, 0, 4000, test.ctx());

    test.next_tx(@0x1);
    let wallet = test.take_shared<VestingWallet<Linear, Params, USDC>>();
    assert_eq!(wallet.beneficiary(), BENEFICIARY);
    assert_eq!(vesting_wallet_linear::duration_ms(&wallet), 4000);
    assert_eq!(vesting_wallet_linear::period_ms(&wallet), 1);
    test_scenario::return_shared(wallet);

    destroy(clk);
    test.end();
}

// === Curve shape ===

// Before `start_ms`, the curve is zero and does not underflow.
#[test]
fun vested_amount_pre_start_is_zero() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_stepped(1000, 0, 1000, 4, test.ctx());
    wallet.fund(1000);

    clk.set_for_testing(999);
    assert_eq!(wallet.vested(&clk), 0);

    destroy(wallet);
    destroy(clk);
    test.end();
}

// The staircase: the value is flat within a period and steps up at each boundary.
// 4 steps of 1000ms over a total of 1000 => 250 per tranche.
#[test]
fun vested_amount_is_a_staircase() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_stepped(0, 0, 1000, 4, test.ctx());
    wallet.fund(1000);

    // First period [0, 1000): zero steps elapsed, nothing vested.
    clk.set_for_testing(0);
    assert_eq!(wallet.vested(&clk), 0);
    clk.set_for_testing(999);
    assert_eq!(wallet.vested(&clk), 0);

    // First boundary: one step => 1000 * 1 / 4 = 250, flat across the period.
    clk.set_for_testing(1000);
    assert_eq!(wallet.vested(&clk), 250);
    clk.set_for_testing(1999);
    assert_eq!(wallet.vested(&clk), 250);

    // Second boundary: two steps => 500.
    clk.set_for_testing(2000);
    assert_eq!(wallet.vested(&clk), 500);

    // Third boundary: three steps => 750.
    clk.set_for_testing(3000);
    assert_eq!(wallet.vested(&clk), 750);

    destroy(wallet);
    destroy(clk);
    test.end();
}

// With a cliff shorter than one period, the staircase is gated to zero until the
// cliff and resumes its regular cadence after.
#[test]
fun vested_amount_pre_cliff_is_zero() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_stepped(0, 500, 1000, 4, test.ctx());
    wallet.fund(1000);

    clk.set_for_testing(0);
    assert_eq!(wallet.vested(&clk), 0);
    clk.set_for_testing(499);
    assert_eq!(wallet.vested(&clk), 0);
    // At the cliff: still inside the first period, so zero steps have elapsed.
    clk.set_for_testing(500);
    assert_eq!(wallet.vested(&clk), 0);
    // First boundary still vests normally.
    clk.set_for_testing(1000);
    assert_eq!(wallet.vested(&clk), 250);

    destroy(wallet);
    destroy(clk);
    test.end();
}

// The key cliff behavior: a cliff spanning several periods releases those tranches
// at once as a catch-up jump, then the staircase resumes its cadence.
#[test]
fun vested_amount_at_cliff_jumps_to_catch_up() {
    let (mut test, mut clk) = setup(0);

    // 8 steps of 1000ms (duration 8000); cliff at 3000 spans 3 full periods.
    let mut wallet = new_stepped(0, 3000, 1000, 8, test.ctx());
    wallet.fund(8000);

    clk.set_for_testing(2999);
    assert_eq!(wallet.vested(&clk), 0); // gated by the cliff
    // At the cliff boundary: 3 periods elapsed => 8000 * 3 / 8 = 3000, all at once.
    clk.set_for_testing(3000);
    assert_eq!(wallet.vested(&clk), 3000);
    // Regular cadence resumes: 4th boundary => 8000 * 4 / 8 = 4000.
    clk.set_for_testing(4000);
    assert_eq!(wallet.vested(&clk), 4000);

    destroy(wallet);
    destroy(clk);
    test.end();
}

// At and after the end the curve clamps to the wallet total.
#[test]
fun vested_amount_post_end_clamps_to_total() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_stepped(0, 0, 1000, 4, test.ctx());
    wallet.fund(1000);

    // Last boundary is the end (start + period * steps = 4000): full total.
    clk.set_for_testing(4000);
    assert_eq!(wallet.vested(&clk), 1000);
    clk.set_for_testing(4001);
    assert_eq!(wallet.vested(&clk), 1000);
    clk.set_for_testing(std::u64::max_value!());
    assert_eq!(wallet.vested(&clk), 1000);

    destroy(wallet);
    destroy(clk);
    test.end();
}

// The curve is non-decreasing as the clock advances.
#[test]
fun vested_amount_is_nondecreasing_in_time() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_stepped(0, 1000, 1000, 4, test.ctx());
    wallet.fund(1000);

    let mut prev = 0;
    vector[0u64, 500, 1000, 1500, 2000, 3000, 4000, 5000].do!(|sample| {
        clk.set_for_testing(sample);
        let current = wallet.vested(&clk);
        assert!(current >= prev);
        prev = current;
    });

    destroy(wallet);
    destroy(clk);
    test.end();
}

// The curve math uses a u128 intermediate, so the worst case
// (total = u64::MAX, last step before the end) does not overflow and fits in u64.
#[test]
fun vested_amount_uses_u128_intermediate_at_max() {
    let (mut test, mut clk) = setup(0);
    let max = std::u64::max_value!();

    // 2 steps of (max / 2) each: duration = max - 1 (max is odd), end = max - 1.
    let half = max / 2;
    let mut wallet = new_stepped(0, 0, half, 2, test.ctx());
    wallet.fund(max);

    // One step elapsed: max * 1 / 2 = floor(max / 2), with no overflow and no abort.
    clk.set_for_testing(half);
    assert_eq!(wallet.vested(&clk), max / 2);

    destroy(wallet);
    destroy(clk);
    test.end();
}

// A deposit made after start immediately participates at the current step
// proportion - the total is re-derived, not captured at construction.
#[test]
fun deposit_vests_as_if_from_start() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_stepped(0, 0, 1000, 4, test.ctx());

    clk.set_for_testing(2000); // two steps elapsed
    assert_eq!(wallet.vested(&clk), 0); // nothing deposited yet

    wallet.fund(1000);
    // two of four steps elapsed, so half the fresh deposit is already vested.
    assert_eq!(wallet.vested(&clk), 500);

    destroy(wallet);
    destroy(clk);
    test.end();
}

// === Release ===

// A mid-schedule release pays the staircase portion to the beneficiary, conserves
// the ledger, and is callable by an unrelated sender.
#[test]
fun release_pays_step_portion_and_is_permissionless() {
    let mut test = test_scenario::begin(@0xCAFE); // unrelated sender
    let mut clk = clock::create_for_testing(test.ctx());

    let mut wallet = new_stepped(0, 0, 1000, 4, test.ctx());
    let wallet_id = object::id(&wallet);
    wallet.fund(1000);

    clk.set_for_testing(2000); // two steps => 500
    vesting_wallet_linear::release(&mut wallet, &clk);

    assert_eq!(wallet.released(), 500);
    assert_eq!(wallet.balance(), 500);

    let released = event::events_by_type<Released<Linear, USDC>>();
    assert_eq!(released.length(), 1);
    assert_eq!(
        released[0],
        vesting_wallet::test_new_released<Linear, USDC>(wallet_id, BENEFICIARY, 500),
    );

    destroy(wallet);

    destroy(clk);
    test.end();
}

// Releasing again within the same period is a no-op: the staircase is flat, so no
// new tranche has vested (this idempotency also makes concurrent shared-object
// releases safe).
#[test]
fun release_then_release_within_same_period_is_noop() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_stepped(0, 0, 1000, 4, test.ctx());
    wallet.fund(1000);

    clk.set_for_testing(1000); // one step => 250
    vesting_wallet_linear::release(&mut wallet, &clk);
    assert_eq!(wallet.released(), 250);
    assert_eq!(event::events_by_type<Released<Linear, USDC>>().length(), 1);

    // Still in the same period: nothing new, no event, no change.
    test.next_tx(@0x1);
    clk.set_for_testing(1999);
    vesting_wallet_linear::release(&mut wallet, &clk);
    assert_eq!(wallet.released(), 250);
    assert_eq!(wallet.balance(), 750);
    assert_eq!(event::events_by_type<Released<Linear, USDC>>().length(), 0);

    destroy(wallet);
    destroy(clk);
    test.end();
}

// The `releasable` view matches what `release` actually pays, and reads zero
// immediately after a release at the same clock.
#[test]
fun releasable_view_matches_release() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_stepped(0, 0, 1000, 4, test.ctx());
    wallet.fund(1000);

    clk.set_for_testing(2000); // two steps => 500
    assert_eq!(vesting_wallet_linear::releasable(&wallet, &clk), 500);

    vesting_wallet_linear::release(&mut wallet, &clk);
    assert_eq!(vesting_wallet_linear::releasable(&wallet, &clk), 0);

    destroy(wallet);
    destroy(clk);
    test.end();
}

// The `releasable` view reads zero before the schedule opens (pre-start) and while
// the cliff still gates it (pre-cliff), asserted directly on the view rather than
// transitively through `release`. The wallet is funded and the cliff spans several
// periods, so a non-gated curve would report a non-zero amount - the zero is the gate
// doing its job, not an empty balance.
#[test]
fun releasable_is_zero_pre_start_and_pre_cliff() {
    let (mut test, mut clk) = setup(0);

    // Opens at 1000; cliff at start + 3000 spans 3 full periods.
    let mut wallet = new_stepped(1000, 3000, 1000, 8, test.ctx());
    wallet.fund(8000);

    clk.set_for_testing(999); // pre-start
    assert_eq!(vesting_wallet_linear::releasable(&wallet, &clk), 0);

    clk.set_for_testing(3000); // past start, 2 periods elapsed, still before the cliff (4000)
    assert_eq!(vesting_wallet_linear::releasable(&wallet, &clk), 0);

    destroy(wallet);
    destroy(clk);
    test.end();
}

// After the end the whole total is releasable, and once drained nothing more is.
#[test]
fun full_release_after_end_then_releasable_zero() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_stepped(0, 0, 1000, 4, test.ctx());
    wallet.fund(1000);

    clk.set_for_testing(4000);
    vesting_wallet_linear::release(&mut wallet, &clk);
    assert_eq!(wallet.released(), 1000);
    assert_eq!(wallet.balance(), 0);
    assert_eq!(vesting_wallet_linear::releasable(&wallet, &clk), 0);

    destroy(wallet);
    destroy(clk);
    test.end();
}

// === Teardown ===

// A drained, ended wallet can be torn down and emits `Destroyed`.
#[test]
fun destroy_after_end_on_empty_wallet() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_stepped(0, 0, 1000, 4, test.ctx());
    let wallet_id = object::id(&wallet);
    wallet.fund(1000);

    clk.set_for_testing(4000);
    vesting_wallet_linear::release(&mut wallet, &clk);
    assert_eq!(wallet.balance(), 0);

    test.next_tx(BENEFICIARY);
    let receipt = wallet.destroy_empty();
    vesting_wallet_linear::destroy(receipt, &clk, test.ctx());

    let destroyed = event::events_by_type<Destroyed<Linear, USDC>>();
    assert_eq!(destroyed.length(), 1);
    assert_eq!(
        destroyed[0],
        vesting_wallet::test_new_destroyed<Linear, USDC>(wallet_id, BENEFICIARY, 1000),
    );

    destroy(clk);
    test.end();
}

// Tearing down before the schedule end aborts, even on an empty wallet.
#[test, expected_failure(abort_code = vesting_wallet_linear::ENotEnded)]
fun destroy_rejects_before_end() {
    let (mut test, mut clk) = setup(0);

    let wallet = new_stepped(0, 0, 1000, 4, test.ctx());
    clk.set_for_testing(3999);
    let receipt = wallet.destroy_empty();
    vesting_wallet_linear::destroy(receipt, &clk, test.ctx());
    abort
}

// Tearing down a wallet that still holds a balance aborts. Clock is after end and
// the caller is the beneficiary, so neither the ended nor the beneficiary gate can
// fire - only the empty-balance gate from the primitive.
#[test, expected_failure(abort_code = vesting_wallet::ENotEmpty)]
fun destroy_rejects_nonempty_balance() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_stepped(0, 0, 1000, 4, test.ctx());
    wallet.fund(1);
    clk.set_for_testing(5000); // after end, so the ended gate cannot fire
    test.next_tx(BENEFICIARY);
    let receipt = wallet.destroy_empty();
    vesting_wallet_linear::destroy(receipt, &clk, test.ctx());
    abort
}

// Only the beneficiary may tear down the wallet; any other caller aborts even on a
// drained, ended wallet.
#[test, expected_failure(abort_code = vesting_wallet_linear::ENotBeneficiary)]
fun destroy_rejects_non_beneficiary() {
    let (mut test, mut clk) = setup(0);

    let wallet = new_stepped(0, 0, 1000, 4, test.ctx());
    clk.set_for_testing(5000); // after end, so the ended gate cannot fire
    test.next_tx(@0xCAFE); // not the beneficiary
    let receipt = wallet.destroy_empty();
    vesting_wallet_linear::destroy(receipt, &clk, test.ctx());
    abort
}

// === Composability ===

// create + deposit + release compose in a single transaction.
#[test]
fun create_deposit_release_in_one_flow() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_stepped(0, 0, 1000, 4, test.ctx());
    wallet.fund(1000);
    clk.set_for_testing(2000); // two steps => 500
    vesting_wallet_linear::release(&mut wallet, &clk);

    assert_eq!(wallet.released(), 500);
    assert_eq!(wallet.balance(), 500);

    destroy(wallet);
    destroy(clk);
    test.end();
}

// === Early-release resistance ===

// An attacker poking `release` before the schedule opens, and again inside the
// first (zero-step) period, moves no funds: the curve reads 0 throughout, so
// `release` short-circuits on a zero releasable - no payout, no event, balance
// untouched.
#[test]
fun release_before_first_step_moves_no_funds() {
    let (mut test, mut clk) = setup(0);

    // Opens at 1000, first tranche at 2000.
    let mut wallet = new_stepped(1000, 0, 1000, 4, test.ctx());
    wallet.fund(1_000_000);

    clk.set_for_testing(999); // pre-start
    vesting_wallet_linear::release(&mut wallet, &clk);
    clk.set_for_testing(1000); // at start, first period, zero steps elapsed
    vesting_wallet_linear::release(&mut wallet, &clk);
    clk.set_for_testing(1999); // one ms before the first tranche
    vesting_wallet_linear::release(&mut wallet, &clk);

    assert_eq!(wallet.released(), 0);
    assert_eq!(wallet.balance(), 1_000_000);
    assert_eq!(event::events_by_type<Released<Linear, USDC>>().length(), 0);

    destroy(wallet);
    destroy(clk);
    test.end();
}

// ====================================================================
// Continuous schedule (`new_continuous`)
// ====================================================================

// === Construction guards ===

// A zero duration maps to zero steps, so it is rejected by the step guard.
#[test, expected_failure(abort_code = vesting_wallet_linear::EZeroSteps)]
fun new_continuous_rejects_zero_duration() {
    let mut ctx = tx_context::dummy();
    // `new_continuous` aborts before returning; `destroy` only satisfies the type checker.
    destroy(new_continuous(0, 0, 0, &mut ctx));
}

// A cliff longer than the duration is rejected.
#[test, expected_failure(abort_code = vesting_wallet_linear::EInvalidCliff)]
fun new_continuous_rejects_cliff_exceeding_duration() {
    let mut ctx = tx_context::dummy();
    destroy(new_continuous(0, 1001, 1000, &mut ctx));
}

// A schedule whose end (start + duration) would overflow u64 is rejected.
#[test, expected_failure(abort_code = vesting_wallet_linear::EScheduleOverflow)]
fun new_continuous_rejects_schedule_overflow() {
    let mut ctx = tx_context::dummy();
    destroy(new_continuous(std::u64::max_value!(), 0, 1, &mut ctx));
}

// Boundary: a schedule whose end is exactly u64::MAX is valid and `end_ms()`
// does not abort.
#[test]
fun new_continuous_accepts_end_at_u64_max_boundary() {
    let mut ctx = tx_context::dummy();
    let max = std::u64::max_value!();

    let wallet = new_continuous(max - 1000, 0, 1000, &mut ctx);
    assert_eq!(vesting_wallet_linear::end_ms(&wallet), max);

    destroy(wallet);
}

// Accept boundary (continuous): cliff == duration is allowed; nothing vests until
// the end, then the curve jumps straight to the full total. Mirrors the stepped
// `new_accepts_cliff_equal_to_duration`.
#[test]
fun new_continuous_accepts_cliff_equal_to_duration() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_continuous(0, 1000, 1000, test.ctx());
    wallet.fund(1000);

    clk.set_for_testing(999);
    assert_eq!(wallet.vested(&clk), 0); // still gated by the cliff
    clk.set_for_testing(1000);
    assert_eq!(wallet.vested(&clk), 1000); // cliff boundary == end: full total

    destroy(wallet);
    destroy(clk);
    test.end();
}

// `new_continuous` is the `period = 1`, `steps = duration` limit of the stepped curve.
#[test]
fun new_continuous_sets_period_one_and_steps_duration() {
    let (mut test, clk) = setup(0);

    let wallet = new_continuous(100, 250, 1000, test.ctx());

    assert_eq!(vesting_wallet_linear::start_ms(&wallet), 100);
    assert_eq!(vesting_wallet_linear::cliff_ms(&wallet), 250);
    assert_eq!(vesting_wallet_linear::period_ms(&wallet), 1);
    assert_eq!(vesting_wallet_linear::steps(&wallet), 1000);
    assert_eq!(vesting_wallet_linear::duration_ms(&wallet), 1000);
    assert_eq!(vesting_wallet_linear::end_ms(&wallet), 1100);

    destroy(wallet);
    destroy(clk);
    test.end();
}

// `params_continuous` is the curve-agnostic seam for a continuous schedule: it yields
// the `period = 1`, `steps = duration` `Params` that drives the bare primitive
// directly, equivalent to a `new_continuous`-built wallet.
#[test]
fun params_continuous_drives_bare_primitive() {
    let (mut test, clk) = setup(0);

    let p = vesting_wallet_linear::params_continuous(100, 250, 1000);
    let wallet = vesting_wallet::new<Linear, Params, USDC>(p, BENEFICIARY, test.ctx());

    assert_eq!(vesting_wallet_linear::start_ms(&wallet), 100);
    assert_eq!(vesting_wallet_linear::cliff_ms(&wallet), 250);
    assert_eq!(vesting_wallet_linear::period_ms(&wallet), 1);
    assert_eq!(vesting_wallet_linear::steps(&wallet), 1000);
    assert_eq!(vesting_wallet_linear::end_ms(&wallet), 1100);

    destroy(wallet);
    destroy(clk);
    test.end();
}

// A zero duration is rejected, mirroring `new_continuous`.
#[test, expected_failure(abort_code = vesting_wallet_linear::EZeroSteps)]
fun params_continuous_rejects_zero_duration() {
    vesting_wallet_linear::params_continuous(0, 0, 0);
}

// === Curve shape ===

// At now == start_ms with no cliff the elapsed time is 0, so the curve reads 0 -
// the lower edge of the continuous branch.
#[test]
fun vested_amount_continuous_at_exact_start_is_zero() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_continuous(1000, 0, 1000, test.ctx());
    wallet.fund(1000);

    clk.set_for_testing(1000); // now == start_ms, elapsed == 0
    assert_eq!(wallet.vested(&clk), 0);

    destroy(wallet);
    destroy(clk);
    test.end();
}

// The key cliff behavior: at the cliff boundary the curve jumps from 0 to the
// linear-from-start proportion `total * cliff / duration`.
#[test]
fun vested_amount_continuous_at_cliff_jumps_to_proportional() {
    let (mut test, mut clk) = setup(0);

    // total = 1000, cliff = 1000, duration = 4000  =>  jump to 1000 * 1000 / 4000 = 250
    let mut wallet = new_continuous(0, 1000, 4000, test.ctx());
    wallet.fund(1000);

    clk.set_for_testing(999);
    assert_eq!(wallet.vested(&clk), 0);
    clk.set_for_testing(1000);
    assert_eq!(wallet.vested(&clk), 250);

    destroy(wallet);
    destroy(clk);
    test.end();
}

// Between cliff and end the curve is linear from start.
#[test]
fun vested_amount_continuous_is_linear_mid_schedule() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_continuous(0, 1000, 4000, test.ctx());
    wallet.fund(1000);

    clk.set_for_testing(2000);
    assert_eq!(wallet.vested(&clk), 500); // 1000 * 2000 / 4000
    clk.set_for_testing(3000);
    assert_eq!(wallet.vested(&clk), 750); // 1000 * 3000 / 4000

    destroy(wallet);
    destroy(clk);
    test.end();
}

// The curve math uses a u128 intermediate, so the worst case
// (total = duration = u64::MAX) does not overflow and the final value fits in u64.
#[test]
fun vested_amount_continuous_uses_u128_intermediate_at_max() {
    let (mut test, mut clk) = setup(0);
    let max = std::u64::max_value!();

    let mut wallet = new_continuous(0, 0, max, test.ctx());
    wallet.fund(max);

    clk.set_for_testing(max - 1);
    // max * (max - 1) / max == max - 1, with no overflow and no abort.
    assert_eq!(wallet.vested(&clk), max - 1);

    destroy(wallet);
    destroy(clk);
    test.end();
}

// === Composability ===

// receive_and_deposit + release compose in a single transaction - the
// emission-schedule / payroll path where a coin is claimed from the wallet's address
// and the vested portion is released in one go.
#[test]
fun receive_and_deposit_then_release_in_one_flow() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());

    let wallet = new_continuous(0, 0, 1000, test.ctx());
    let wallet_addr = object::id_address(&wallet);
    transfer::public_share_object(wallet);

    // An upstream emitter sends a coin to the wallet's object address.
    test.next_tx(@0x1);
    let coin = coin::mint_for_testing<USDC>(1000, test.ctx());
    let coin_id = object::id(&coin);
    transfer::public_transfer(coin, wallet_addr);

    // One transaction: claim the coin AND release the vested portion.
    test.next_tx(@0x1);
    let mut wallet = test.take_shared<VestingWallet<Linear, Params, USDC>>();
    let receiving = test_scenario::receiving_ticket_by_id<coin::Coin<USDC>>(coin_id);
    wallet.receive_and_deposit(receiving);
    clk.set_for_testing(500);
    vesting_wallet_linear::release(&mut wallet, &clk);

    assert_eq!(wallet.released(), 500);
    assert_eq!(wallet.balance(), 500);

    test_scenario::return_shared(wallet);
    destroy(clk);
    test.end();
}

// === Early-release resistance ===

// The subtlest "early release" shape: deposit more *after* a partial release, then
// claim again at the same clock. The fresh deposit vests retroactively at the elapsed
// proportion (documented behavior), but the payout is always exactly the live curve
// over the current total and is fully balance-backed - the second release never
// aborts and never pays more than the wallet holds. So nothing leaves ahead of the
// curve; the late deposit simply funds its own (proportional) unlock.
#[test]
fun retroactive_deposit_never_over_releases() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_continuous(0, 0, 100, test.ctx());
    wallet.fund(100);

    clk.set_for_testing(50);
    vesting_wallet_linear::release(&mut wallet, &clk); // floor(100 * 50 / 100) = 50
    assert_eq!(wallet.released(), 50);
    assert_eq!(wallet.balance(), 50);

    // Late deposit; total is now 200, re-derived fresh at call time.
    wallet.fund(100);
    let releasable = vesting_wallet_linear::releasable(&wallet, &clk);
    assert_eq!(releasable, 50); // floor(200 * 50 / 100) = 100 cumulative, minus 50 already released
    assert!(releasable <= wallet.balance()); // never exceeds the balance backing it

    vesting_wallet_linear::release(&mut wallet, &clk); // does not abort, does not over-pay
    assert_eq!(wallet.released(), 100);
    assert_eq!(wallet.balance(), 100);
    assert_eq!(wallet.balance() + wallet.released(), 200); // conserved: nothing minted from nowhere

    destroy(wallet);
    destroy(clk);
    test.end();
}

// The only arithmetic that could lift the curve above the schedule is the
// `balance + released` total. Releasing funds out and re-funding could otherwise
// drive that sum past u64::MAX; the `deposit` guard (`EOverflow`) rejects the
// offending refund up front, so the sum can never overflow and the release path is
// never bricked.
#[test, expected_failure(abort_code = vesting_wallet::EBalanceOverflow)]
fun overflowing_refund_is_rejected_at_deposit() {
    let (mut test, mut clk) = setup(0);
    let max = std::u64::max_value!();

    let mut wallet = new_continuous(0, 0, max, test.ctx());
    wallet.fund(max);

    clk.set_for_testing(1);
    vesting_wallet_linear::release(&mut wallet, &clk); // releases 1; balance = max - 1, released = 1

    // balance + released == max already; refunding the released 1 would overflow it,
    // so the deposit is rejected here rather than bricking a later release.
    wallet.fund(1);
    abort
}

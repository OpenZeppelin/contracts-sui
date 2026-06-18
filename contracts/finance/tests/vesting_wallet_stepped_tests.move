#[test_only]
module openzeppelin_finance::vesting_wallet_stepped_tests;

use openzeppelin_finance::vesting_wallet_stepped::{Self, Stepped, Params};
use openzeppelin_finance::vesting_wallet::{Self, VestingWallet, Created, Released, Destroyed};
use std::unit_test::{assert_eq, destroy};
use sui::clock::{Self, Clock};
use sui::coin;
use sui::event;
use sui::test_scenario::{Self, Scenario};

use fun fund as VestingWallet.fund;
use fun vested as VestingWallet.vested;

/// Phantom coin marker for the vested asset.
public struct USDC has drop {}

const BENEFICIARY: address = @0xB0B;

// === Test helpers ===

fun setup(t0: u64): (Scenario, Clock) {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(t0);
    (test, clk)
}

fun teardown(test: Scenario, clk: Clock) {
    destroy(clk);
    test.end();
}

fun new_stepped(
    start: u64,
    cliff: u64,
    period: u64,
    steps: u64,
    ctx: &mut TxContext,
): VestingWallet<Stepped, Params, USDC> {
    vesting_wallet_stepped::new<USDC>(BENEFICIARY, start, cliff, period, steps, ctx)
}

fun fund(wallet: &mut VestingWallet<Stepped, Params, USDC>, amount: u64, ctx: &mut TxContext) {
    wallet.deposit(coin::mint_for_testing<USDC>(amount, ctx));
}

/// The curve's cumulative vested total at the given clock.
fun vested(wallet: &VestingWallet<Stepped, Params, USDC>, clk: &Clock): u64 {
    vesting_wallet_stepped::vested_amount(wallet, clk).amount()
}

// === Construction guards ===

// A zero period is rejected.
#[test, expected_failure(abort_code = vesting_wallet_stepped::EZeroPeriod)]
fun new_rejects_zero_period() {
    let mut ctx = tx_context::dummy();
    // `new` aborts before returning; `destroy` only satisfies the type checker.
    destroy(new_stepped(0, 0, 0, 4, &mut ctx));
}

// A zero step count is rejected.
#[test, expected_failure(abort_code = vesting_wallet_stepped::EZeroSteps)]
fun new_rejects_zero_steps() {
    let mut ctx = tx_context::dummy();
    destroy(new_stepped(0, 0, 1000, 0, &mut ctx));
}

// A cliff longer than the schedule duration (period * steps) is rejected.
#[test, expected_failure(abort_code = vesting_wallet_stepped::EInvalidCliff)]
fun new_rejects_cliff_exceeding_duration() {
    let mut ctx = tx_context::dummy();
    // duration = 1000 * 4 = 4000; cliff 4001 exceeds it.
    destroy(new_stepped(0, 4001, 1000, 4, &mut ctx));
}

// A schedule whose duration (period * steps) would overflow u64 is rejected.
#[test, expected_failure(abort_code = vesting_wallet_stepped::EScheduleOverflow)]
fun new_rejects_duration_overflow() {
    let mut ctx = tx_context::dummy();
    destroy(new_stepped(0, 0, std::u64::max_value!(), 2, &mut ctx));
}

// A schedule whose end (start + period * steps) would overflow u64 is rejected.
#[test, expected_failure(abort_code = vesting_wallet_stepped::EScheduleOverflow)]
fun new_rejects_end_overflow() {
    let mut ctx = tx_context::dummy();
    destroy(new_stepped(std::u64::max_value!() - 999, 0, 1000, 1, &mut ctx));
}

// Boundary: a schedule whose end is exactly u64::MAX is valid and `end()`
// does not abort.
#[test]
fun new_accepts_end_at_u64_max_boundary() {
    let mut ctx = tx_context::dummy();
    let max = std::u64::max_value!();

    let wallet = new_stepped(max - 1000, 0, 1000, 1, &mut ctx);
    assert_eq!(vesting_wallet_stepped::end(&wallet), max);

    destroy(wallet);
}

// Accept boundary: cliff == duration is allowed; nothing vests until the end,
// then the curve jumps straight to the full total.
#[test]
fun new_accepts_cliff_equal_to_duration() {
    let (mut test, mut clk) = setup(0);

    // duration = 1000 * 4 = 4000.
    let mut wallet = new_stepped(0, 4000, 1000, 4, test.ctx());
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(3999);
    assert_eq!(wallet.vested(&clk), 0); // still gated by the cliff
    clk.set_for_testing(4000);
    assert_eq!(wallet.vested(&clk), 1000); // cliff boundary == end: full total

    destroy(wallet);
    teardown(test, clk);
}

// === Construction state & topology ===

// `Created` is emitted exactly once with the full payload asserted, and the params
// are readable through the accessors.
#[test]
fun new_sets_params_and_emits_created() {
    let (mut test, clk) = setup(0);

    let wallet = new_stepped(100, 250, 1000, 4, test.ctx());

    assert_eq!(vesting_wallet_stepped::start(&wallet), 100);
    assert_eq!(vesting_wallet_stepped::cliff(&wallet), 250);
    assert_eq!(vesting_wallet_stepped::period(&wallet), 1000);
    assert_eq!(vesting_wallet_stepped::steps(&wallet), 4);
    assert_eq!(vesting_wallet_stepped::duration(&wallet), 4000);
    assert_eq!(vesting_wallet_stepped::end(&wallet), 4100);

    let created = event::events_by_type<Created<Stepped, Params, USDC>>();
    assert_eq!(created.length(), 1);
    assert_eq!(
        created[0],
        vesting_wallet::test_new_created<Stepped, Params, USDC>(
            object::id(&wallet),
            BENEFICIARY,
            vesting_wallet_stepped::test_params(100, 250, 1000, 4),
        ),
    );

    destroy(wallet);
    teardown(test, clk);
}

// `create_and_share` puts the wallet into the shared topology.
#[test]
fun create_and_share_shares_wallet() {
    let (mut test, clk) = setup(0);

    vesting_wallet_stepped::create_and_share<USDC>(BENEFICIARY, 0, 0, 1000, 4, test.ctx());

    test.next_tx(@0x1);
    let wallet = test.take_shared<VestingWallet<Stepped, Params, USDC>>();
    assert_eq!(wallet.beneficiary(), BENEFICIARY);
    assert_eq!(vesting_wallet_stepped::duration(&wallet), 4000);
    test_scenario::return_shared(wallet);

    teardown(test, clk);
}

// === Curve shape ===

// Before `start_ms`, the curve is zero and does not underflow.
#[test]
fun vested_amount_pre_start_is_zero() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_stepped(1000, 0, 1000, 4, test.ctx());
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(999);
    assert_eq!(wallet.vested(&clk), 0);

    destroy(wallet);
    teardown(test, clk);
}

// The staircase: the value is flat within a period and steps up at each boundary.
// 4 steps of 1000ms over a total of 1000 => 250 per tranche.
#[test]
fun vested_amount_is_a_staircase() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_stepped(0, 0, 1000, 4, test.ctx());
    wallet.fund(1000, test.ctx());

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
    teardown(test, clk);
}

// With a cliff shorter than one period, the staircase is gated to zero until the
// cliff and resumes its regular cadence after.
#[test]
fun vested_amount_pre_cliff_is_zero() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_stepped(0, 500, 1000, 4, test.ctx());
    wallet.fund(1000, test.ctx());

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
    teardown(test, clk);
}

// The key cliff behavior: a cliff spanning several periods releases those tranches
// at once as a catch-up jump, then the staircase resumes its cadence.
#[test]
fun vested_amount_at_cliff_jumps_to_catch_up() {
    let (mut test, mut clk) = setup(0);

    // 8 steps of 1000ms (duration 8000); cliff at 3000 spans 3 full periods.
    let mut wallet = new_stepped(0, 3000, 1000, 8, test.ctx());
    wallet.fund(8000, test.ctx());

    clk.set_for_testing(2999);
    assert_eq!(wallet.vested(&clk), 0); // gated by the cliff
    // At the cliff boundary: 3 periods elapsed => 8000 * 3 / 8 = 3000, all at once.
    clk.set_for_testing(3000);
    assert_eq!(wallet.vested(&clk), 3000);
    // Regular cadence resumes: 4th boundary => 8000 * 4 / 8 = 4000.
    clk.set_for_testing(4000);
    assert_eq!(wallet.vested(&clk), 4000);

    destroy(wallet);
    teardown(test, clk);
}

// At and after the end the curve clamps to the wallet total.
#[test]
fun vested_amount_post_end_clamps_to_total() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_stepped(0, 0, 1000, 4, test.ctx());
    wallet.fund(1000, test.ctx());

    // Last boundary is the end (start + period * steps = 4000): full total.
    clk.set_for_testing(4000);
    assert_eq!(wallet.vested(&clk), 1000);
    clk.set_for_testing(4001);
    assert_eq!(wallet.vested(&clk), 1000);
    clk.set_for_testing(std::u64::max_value!());
    assert_eq!(wallet.vested(&clk), 1000);

    destroy(wallet);
    teardown(test, clk);
}

// The curve is non-decreasing as the clock advances.
#[test]
fun vested_amount_is_nondecreasing_in_time() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_stepped(0, 1000, 1000, 4, test.ctx());
    wallet.fund(1000, test.ctx());

    let samples = vector[0u64, 500, 1000, 1500, 2000, 3000, 4000, 5000];
    let mut prev = 0;
    let mut i = 0;
    while (i < samples.length()) {
        clk.set_for_testing(samples[i]);
        let current = wallet.vested(&clk);
        assert!(current >= prev);
        prev = current;
        i = i + 1;
    };

    destroy(wallet);
    teardown(test, clk);
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
    wallet.fund(max, test.ctx());

    // One step elapsed: max * 1 / 2 = floor(max / 2), with no overflow and no abort.
    clk.set_for_testing(half);
    assert_eq!(wallet.vested(&clk), max / 2);

    destroy(wallet);
    teardown(test, clk);
}

// A deposit made after start immediately participates at the current step
// proportion - the total is re-derived, not captured at construction.
#[test]
fun deposit_vests_as_if_from_start() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_stepped(0, 0, 1000, 4, test.ctx());

    clk.set_for_testing(2000); // two steps elapsed
    assert_eq!(wallet.vested(&clk), 0); // nothing deposited yet

    wallet.fund(1000, test.ctx());
    // two of four steps elapsed, so half the fresh deposit is already vested.
    assert_eq!(wallet.vested(&clk), 500);

    destroy(wallet);
    teardown(test, clk);
}

// === Release through the stepped curve ===

// A mid-schedule release pays the staircase portion to the beneficiary, conserves
// the ledger, and is callable by an unrelated sender.
#[test]
fun release_pays_step_portion_and_is_permissionless() {
    let mut test = test_scenario::begin(@0xCAFE); // unrelated sender
    let mut clk = clock::create_for_testing(test.ctx());

    let mut wallet = new_stepped(0, 0, 1000, 4, test.ctx());
    let wallet_id = object::id(&wallet);
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(2000); // two steps => 500
    vesting_wallet_stepped::release(&mut wallet, &clk, test.ctx());

    assert_eq!(wallet.released(), 500);
    assert_eq!(wallet.balance(), 500);

    let released = event::events_by_type<Released<Stepped, USDC>>();
    assert_eq!(released.length(), 1);
    assert_eq!(
        released[0],
        vesting_wallet::test_new_released<Stepped, USDC>(wallet_id, BENEFICIARY, 500),
    );

    destroy(wallet);

    test.next_tx(BENEFICIARY);
    let coin = test.take_from_sender<coin::Coin<USDC>>();
    assert_eq!(coin.value(), 500);
    destroy(coin);

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
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(1000); // one step => 250
    vesting_wallet_stepped::release(&mut wallet, &clk, test.ctx());
    assert_eq!(wallet.released(), 250);
    assert_eq!(event::events_by_type<Released<Stepped, USDC>>().length(), 1);

    // Still in the same period: nothing new, no event, no change.
    test.next_tx(@0x1);
    clk.set_for_testing(1999);
    vesting_wallet_stepped::release(&mut wallet, &clk, test.ctx());
    assert_eq!(wallet.released(), 250);
    assert_eq!(wallet.balance(), 750);
    assert_eq!(event::events_by_type<Released<Stepped, USDC>>().length(), 0);

    destroy(wallet);
    teardown(test, clk);
}

// The `releasable` view matches what `release` actually pays, and reads zero
// immediately after a release at the same clock.
#[test]
fun releasable_view_matches_release() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_stepped(0, 0, 1000, 4, test.ctx());
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(2000); // two steps => 500
    assert_eq!(vesting_wallet_stepped::releasable(&wallet, &clk), 500);

    vesting_wallet_stepped::release(&mut wallet, &clk, test.ctx());
    assert_eq!(vesting_wallet_stepped::releasable(&wallet, &clk), 0);

    destroy(wallet);
    teardown(test, clk);
}

// After the end the whole total is releasable, and once drained nothing more is.
#[test]
fun full_release_after_end_then_releasable_zero() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_stepped(0, 0, 1000, 4, test.ctx());
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(4000);
    vesting_wallet_stepped::release(&mut wallet, &clk, test.ctx());
    assert_eq!(wallet.released(), 1000);
    assert_eq!(wallet.balance(), 0);
    assert_eq!(vesting_wallet_stepped::releasable(&wallet, &clk), 0);

    destroy(wallet);
    teardown(test, clk);
}

// === Teardown ===

// A drained, ended wallet can be torn down and emits `Destroyed`.
#[test]
fun destroy_after_end_on_empty_wallet() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_stepped(0, 0, 1000, 4, test.ctx());
    let wallet_id = object::id(&wallet);
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(4000);
    vesting_wallet_stepped::release(&mut wallet, &clk, test.ctx());
    assert_eq!(wallet.balance(), 0);

    test.next_tx(@0x1);
    vesting_wallet_stepped::destroy(wallet, &clk);

    let destroyed = event::events_by_type<Destroyed<Stepped, USDC>>();
    assert_eq!(destroyed.length(), 1);
    assert_eq!(
        destroyed[0],
        vesting_wallet::test_new_destroyed<Stepped, USDC>(wallet_id, BENEFICIARY, 1000),
    );

    teardown(test, clk);
}

// Tearing down before the schedule end aborts, even on an empty wallet.
#[test, expected_failure(abort_code = vesting_wallet_stepped::ENotEnded)]
fun destroy_rejects_before_end() {
    let (mut test, mut clk) = setup(0);

    let wallet = new_stepped(0, 0, 1000, 4, test.ctx());
    clk.set_for_testing(3999);
    vesting_wallet_stepped::destroy(wallet, &clk);
    abort
}

// Tearing down a wallet that still holds a balance aborts (the empty-balance
// gate from the primitive fires before the ended gate).
#[test, expected_failure(abort_code = vesting_wallet::ENotEmpty)]
fun destroy_rejects_nonempty_balance() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_stepped(0, 0, 1000, 4, test.ctx());
    wallet.fund(1, test.ctx());
    clk.set_for_testing(5000); // after end, so only the balance gate can fire
    vesting_wallet_stepped::destroy(wallet, &clk);
    abort
}

// === Composability ===

// create + deposit + release compose in a single transaction.
#[test]
fun create_deposit_release_in_one_flow() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_stepped(0, 0, 1000, 4, test.ctx());
    wallet.fund(1000, test.ctx());
    clk.set_for_testing(2000); // two steps => 500
    vesting_wallet_stepped::release(&mut wallet, &clk, test.ctx());

    assert_eq!(wallet.released(), 500);
    assert_eq!(wallet.balance(), 500);

    destroy(wallet);
    teardown(test, clk);
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
    wallet.fund(1_000_000, test.ctx());

    clk.set_for_testing(999); // pre-start
    vesting_wallet_stepped::release(&mut wallet, &clk, test.ctx());
    clk.set_for_testing(1000); // at start, first period, zero steps elapsed
    vesting_wallet_stepped::release(&mut wallet, &clk, test.ctx());
    clk.set_for_testing(1999); // one ms before the first tranche
    vesting_wallet_stepped::release(&mut wallet, &clk, test.ctx());

    assert_eq!(wallet.released(), 0);
    assert_eq!(wallet.balance(), 1_000_000);
    assert_eq!(event::events_by_type<Released<Stepped, USDC>>().length(), 0);

    destroy(wallet);
    teardown(test, clk);
}

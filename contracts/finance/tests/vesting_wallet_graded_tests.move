#[test_only]
module openzeppelin_finance::vesting_wallet_graded_tests;

use openzeppelin_finance::vesting_wallet_graded::{Self, Graded, Params};
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

// A 4-stage schedule unlocking unequal cumulative percentages:
// 10% at 1000ms, 30% at 2000ms, 60% at 3000ms, 100% at 4000ms.
fun new_graded(start: u64, ctx: &mut TxContext): VestingWallet<Graded, Params, USDC> {
    vesting_wallet_graded::new<USDC>(
        BENEFICIARY,
        start,
        vector[1000, 2000, 3000, 4000],
        vector[1000, 3000, 6000, 10000],
        ctx,
    )
}

fun fund(wallet: &mut VestingWallet<Graded, Params, USDC>, amount: u64, ctx: &mut TxContext) {
    wallet.deposit(coin::mint_for_testing<USDC>(amount, ctx));
}

/// The curve's cumulative vested total at the given clock.
fun vested(wallet: &VestingWallet<Graded, Params, USDC>, clk: &Clock): u64 {
    vesting_wallet_graded::vested_amount(wallet, clk).amount()
}

// === Construction guards ===

// An empty schedule is rejected.
#[test, expected_failure(abort_code = vesting_wallet_graded::EEmptySchedule)]
fun new_rejects_empty_schedule() {
    let mut ctx = tx_context::dummy();
    // `new` aborts before returning; `destroy` only satisfies the type checker.
    destroy(vesting_wallet_graded::new<USDC>(BENEFICIARY, 0, vector[], vector[], &mut ctx));
}

// Mismatched vector lengths are rejected.
#[test, expected_failure(abort_code = vesting_wallet_graded::ELengthMismatch)]
fun new_rejects_length_mismatch() {
    let mut ctx = tx_context::dummy();
    destroy(vesting_wallet_graded::new<USDC>(
        BENEFICIARY,
        0,
        vector[1000, 2000],
        vector[10000],
        &mut ctx,
    ));
}

// Non-increasing offsets are rejected (equal offsets count as unsorted).
#[test, expected_failure(abort_code = vesting_wallet_graded::EUnsortedOffsets)]
fun new_rejects_unsorted_offsets() {
    let mut ctx = tx_context::dummy();
    destroy(vesting_wallet_graded::new<USDC>(
        BENEFICIARY,
        0,
        vector[2000, 1000],
        vector[5000, 10000],
        &mut ctx,
    ));
}

// A zero first cumulative bps is rejected (must be strictly positive).
#[test, expected_failure(abort_code = vesting_wallet_graded::EInvalidBps)]
fun new_rejects_zero_first_bps() {
    let mut ctx = tx_context::dummy();
    destroy(vesting_wallet_graded::new<USDC>(
        BENEFICIARY,
        0,
        vector[1000, 2000],
        vector[0, 10000],
        &mut ctx,
    ));
}

// Non-increasing cumulative bps are rejected.
#[test, expected_failure(abort_code = vesting_wallet_graded::EInvalidBps)]
fun new_rejects_unsorted_bps() {
    let mut ctx = tx_context::dummy();
    destroy(vesting_wallet_graded::new<USDC>(
        BENEFICIARY,
        0,
        vector[1000, 2000, 3000],
        vector[6000, 3000, 10000],
        &mut ctx,
    ));
}

// A schedule whose final cumulative bps is below 10000 is rejected.
#[test, expected_failure(abort_code = vesting_wallet_graded::EIncompleteSchedule)]
fun new_rejects_incomplete_schedule() {
    let mut ctx = tx_context::dummy();
    destroy(vesting_wallet_graded::new<USDC>(
        BENEFICIARY,
        0,
        vector[1000, 2000],
        vector[5000, 9000],
        &mut ctx,
    ));
}

// A schedule whose final cumulative bps exceeds 10000 is rejected: strictly increasing
// to a value above 10000 cannot also end at 10000, so the bps guard fires.
#[test, expected_failure(abort_code = vesting_wallet_graded::EInvalidBps)]
fun new_rejects_bps_above_denominator() {
    let mut ctx = tx_context::dummy();
    destroy(vesting_wallet_graded::new<USDC>(
        BENEFICIARY,
        0,
        vector[1000, 2000, 3000],
        vector[5000, 12000, 10000],
        &mut ctx,
    ));
}

// A schedule whose end (start + last offset) would overflow u64 is rejected.
#[test, expected_failure(abort_code = vesting_wallet_graded::EScheduleOverflow)]
fun new_rejects_end_overflow() {
    let mut ctx = tx_context::dummy();
    destroy(vesting_wallet_graded::new<USDC>(
        BENEFICIARY,
        std::u64::max_value!() - 999,
        vector[1000],
        vector[10000],
        &mut ctx,
    ));
}

// Boundary: a schedule whose end is exactly u64::MAX is valid and `end()` does not abort.
#[test]
fun new_accepts_end_at_u64_max_boundary() {
    let mut ctx = tx_context::dummy();
    let max = std::u64::max_value!();

    let wallet = vesting_wallet_graded::new<USDC>(
        BENEFICIARY,
        max - 1000,
        vector[1000],
        vector[10000],
        &mut ctx,
    );
    assert_eq!(vesting_wallet_graded::end(&wallet), max);

    destroy(wallet);
}

// A single-stage schedule (everything unlocks at one offset) is valid.
#[test]
fun new_accepts_single_stage() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = vesting_wallet_graded::new<USDC>(
        BENEFICIARY,
        0,
        vector[1000],
        vector[10000],
        test.ctx(),
    );
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(999);
    assert_eq!(wallet.vested(&clk), 0);
    clk.set_for_testing(1000);
    assert_eq!(wallet.vested(&clk), 1000); // cliff-like: full total at the single offset

    destroy(wallet);
    teardown(test, clk);
}

// A first offset of 0 unlocks its stage immediately at `start_ms`.
#[test]
fun new_accepts_zero_first_offset() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = vesting_wallet_graded::new<USDC>(
        BENEFICIARY,
        100,
        vector[0, 1000],
        vector[2000, 10000],
        test.ctx(),
    );
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(99);
    assert_eq!(wallet.vested(&clk), 0); // pre-start
    clk.set_for_testing(100);
    assert_eq!(wallet.vested(&clk), 200); // at start, first stage (20%) already unlocked

    destroy(wallet);
    teardown(test, clk);
}

// === Construction state & topology ===

// `Created` is emitted exactly once with the full payload asserted, and the params are
// readable through the accessors.
#[test]
fun new_sets_params_and_emits_created() {
    let (mut test, clk) = setup(0);

    let wallet = new_graded(100, test.ctx());

    assert_eq!(vesting_wallet_graded::start(&wallet), 100);
    assert_eq!(vesting_wallet_graded::offsets(&wallet), vector[1000, 2000, 3000, 4000]);
    assert_eq!(vesting_wallet_graded::cumulative_bps(&wallet), vector[1000, 3000, 6000, 10000]);
    assert_eq!(vesting_wallet_graded::stage_count(&wallet), 4);
    assert_eq!(vesting_wallet_graded::duration(&wallet), 4000);
    assert_eq!(vesting_wallet_graded::end(&wallet), 4100);

    let created = event::events_by_type<Created<Graded, Params, USDC>>();
    assert_eq!(created.length(), 1);
    assert_eq!(
        created[0],
        vesting_wallet::test_new_created<Graded, Params, USDC>(
            object::id(&wallet),
            BENEFICIARY,
            vesting_wallet_graded::test_params(
                100,
                vector[1000, 2000, 3000, 4000],
                vector[1000, 3000, 6000, 10000],
            ),
        ),
    );

    destroy(wallet);
    teardown(test, clk);
}

// `create_and_share` puts the wallet into the shared topology.
#[test]
fun create_and_share_shares_wallet() {
    let (mut test, clk) = setup(0);

    vesting_wallet_graded::create_and_share<USDC>(
        BENEFICIARY,
        0,
        vector[1000, 2000, 3000, 4000],
        vector[1000, 3000, 6000, 10000],
        test.ctx(),
    );

    test.next_tx(@0x1);
    let wallet = test.take_shared<VestingWallet<Graded, Params, USDC>>();
    assert_eq!(wallet.beneficiary(), BENEFICIARY);
    assert_eq!(vesting_wallet_graded::duration(&wallet), 4000);
    test_scenario::return_shared(wallet);

    teardown(test, clk);
}

// === Curve shape ===

// Before `start_ms`, the curve is zero and does not underflow.
#[test]
fun vested_amount_pre_start_is_zero() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_graded(1000, test.ctx());
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(999);
    assert_eq!(wallet.vested(&clk), 0);

    destroy(wallet);
    teardown(test, clk);
}

// The graded staircase: unequal jumps at each stage offset, flat in between.
#[test]
fun vested_amount_is_a_graded_staircase() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_graded(0, test.ctx());
    wallet.fund(1000, test.ctx());

    // Before the first stage: nothing.
    clk.set_for_testing(0);
    assert_eq!(wallet.vested(&clk), 0);
    clk.set_for_testing(999);
    assert_eq!(wallet.vested(&clk), 0);

    // Stage 1 (10%): flat across the interval.
    clk.set_for_testing(1000);
    assert_eq!(wallet.vested(&clk), 100);
    clk.set_for_testing(1999);
    assert_eq!(wallet.vested(&clk), 100);

    // Stage 2 (30%).
    clk.set_for_testing(2000);
    assert_eq!(wallet.vested(&clk), 300);

    // Stage 3 (60%).
    clk.set_for_testing(3000);
    assert_eq!(wallet.vested(&clk), 600);

    destroy(wallet);
    teardown(test, clk);
}

// At and after the end the curve clamps to the wallet total.
#[test]
fun vested_amount_post_end_clamps_to_total() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_graded(0, test.ctx());
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(4000); // last stage offset: 100%
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

    let mut wallet = new_graded(0, test.ctx());
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

// The curve math uses a u128 intermediate, so the worst case (total = u64::MAX, a
// stage below the end) does not overflow and fits in u64.
#[test]
fun vested_amount_uses_u128_intermediate_at_max() {
    let (mut test, mut clk) = setup(0);
    let max = std::u64::max_value!();

    // 50% at 1000ms, 100% at 2000ms.
    let mut wallet = vesting_wallet_graded::new<USDC>(
        BENEFICIARY,
        0,
        vector[1000, 2000],
        vector[5000, 10000],
        test.ctx(),
    );
    wallet.fund(max, test.ctx());

    clk.set_for_testing(1000); // 50% of max = floor(max * 5000 / 10000)
    assert_eq!(wallet.vested(&clk), max / 2);

    destroy(wallet);
    teardown(test, clk);
}

// A deposit made after start immediately participates at the current stage proportion -
// the total is re-derived, not captured at construction.
#[test]
fun deposit_vests_as_if_from_start() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_graded(0, test.ctx());

    clk.set_for_testing(2000); // stage 2: 30%
    assert_eq!(wallet.vested(&clk), 0); // nothing deposited yet

    wallet.fund(1000, test.ctx());
    assert_eq!(wallet.vested(&clk), 300); // 30% of the fresh deposit is already vested

    destroy(wallet);
    teardown(test, clk);
}

// === Release ===

// A mid-schedule release pays the graded portion to the beneficiary, conserves the
// ledger, and is callable by an unrelated sender.
#[test]
fun release_pays_stage_portion_and_is_permissionless() {
    let mut test = test_scenario::begin(@0xCAFE); // unrelated sender
    let mut clk = clock::create_for_testing(test.ctx());

    let mut wallet = new_graded(0, test.ctx());
    let wallet_id = object::id(&wallet);
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(2000); // stage 2: 30% => 300
    vesting_wallet_graded::release(&mut wallet, &clk, test.ctx());

    assert_eq!(wallet.released(), 300);
    assert_eq!(wallet.balance(), 700);

    let released = event::events_by_type<Released<Graded, USDC>>();
    assert_eq!(released.length(), 1);
    assert_eq!(
        released[0],
        vesting_wallet::test_new_released<Graded, USDC>(wallet_id, BENEFICIARY, 300),
    );

    destroy(wallet);

    test.next_tx(BENEFICIARY);
    let coin = test.take_from_sender<coin::Coin<USDC>>();
    assert_eq!(coin.value(), 300);
    destroy(coin);

    destroy(clk);
    test.end();
}

// Releasing again within the same stage is a no-op: the curve is flat, so no new
// portion has vested (this idempotency also makes concurrent shared-object releases
// safe).
#[test]
fun release_then_release_within_same_stage_is_noop() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_graded(0, test.ctx());
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(1000); // stage 1: 10% => 100
    vesting_wallet_graded::release(&mut wallet, &clk, test.ctx());
    assert_eq!(wallet.released(), 100);
    assert_eq!(event::events_by_type<Released<Graded, USDC>>().length(), 1);

    // Still in the same stage: nothing new, no event, no change.
    test.next_tx(@0x1);
    clk.set_for_testing(1999);
    vesting_wallet_graded::release(&mut wallet, &clk, test.ctx());
    assert_eq!(wallet.released(), 100);
    assert_eq!(wallet.balance(), 900);
    assert_eq!(event::events_by_type<Released<Graded, USDC>>().length(), 0);

    destroy(wallet);
    teardown(test, clk);
}

// The `releasable` view matches what `release` actually pays, and reads zero
// immediately after a release at the same clock.
#[test]
fun releasable_view_matches_release() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_graded(0, test.ctx());
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(3000); // stage 3: 60% => 600
    assert_eq!(vesting_wallet_graded::releasable(&wallet, &clk), 600);

    vesting_wallet_graded::release(&mut wallet, &clk, test.ctx());
    assert_eq!(vesting_wallet_graded::releasable(&wallet, &clk), 0);

    destroy(wallet);
    teardown(test, clk);
}

// After the end the whole total is releasable, and once drained nothing more is.
#[test]
fun full_release_after_end_then_releasable_zero() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_graded(0, test.ctx());
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(4000);
    vesting_wallet_graded::release(&mut wallet, &clk, test.ctx());
    assert_eq!(wallet.released(), 1000);
    assert_eq!(wallet.balance(), 0);
    assert_eq!(vesting_wallet_graded::releasable(&wallet, &clk), 0);

    destroy(wallet);
    teardown(test, clk);
}

// === Teardown ===

// A drained, ended wallet can be torn down and emits `Destroyed`.
#[test]
fun destroy_after_end_on_empty_wallet() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_graded(0, test.ctx());
    let wallet_id = object::id(&wallet);
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(4000);
    vesting_wallet_graded::release(&mut wallet, &clk, test.ctx());
    assert_eq!(wallet.balance(), 0);

    test.next_tx(@0x1);
    vesting_wallet_graded::destroy(wallet, &clk);

    let destroyed = event::events_by_type<Destroyed<Graded, USDC>>();
    assert_eq!(destroyed.length(), 1);
    assert_eq!(
        destroyed[0],
        vesting_wallet::test_new_destroyed<Graded, USDC>(wallet_id, BENEFICIARY, 1000),
    );

    teardown(test, clk);
}

// Tearing down before the schedule end aborts, even on an empty wallet.
#[test, expected_failure(abort_code = vesting_wallet_graded::ENotEnded)]
fun destroy_rejects_before_end() {
    let (mut test, mut clk) = setup(0);

    let wallet = new_graded(0, test.ctx());
    clk.set_for_testing(3999);
    vesting_wallet_graded::destroy(wallet, &clk);
    abort
}

// Tearing down a wallet that still holds a balance aborts (the empty-balance gate from
// the primitive fires before the ended gate).
#[test, expected_failure(abort_code = vesting_wallet::ENotEmpty)]
fun destroy_rejects_nonempty_balance() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_graded(0, test.ctx());
    wallet.fund(1, test.ctx());
    clk.set_for_testing(5000); // after end, so only the balance gate can fire
    vesting_wallet_graded::destroy(wallet, &clk);
    abort
}

// === Composability ===

// create + deposit + release compose in a single transaction.
#[test]
fun create_deposit_release_in_one_flow() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_graded(0, test.ctx());
    wallet.fund(1000, test.ctx());
    clk.set_for_testing(2000); // stage 2: 30% => 300
    vesting_wallet_graded::release(&mut wallet, &clk, test.ctx());

    assert_eq!(wallet.released(), 300);
    assert_eq!(wallet.balance(), 700);

    destroy(wallet);
    teardown(test, clk);
}

// === Early-release resistance ===

// An attacker poking `release` before the schedule opens, and again before the first
// stage, moves no funds: the curve reads 0 throughout, so `release` short-circuits on a
// zero releasable - no payout, no event, balance untouched.
#[test]
fun release_before_first_stage_moves_no_funds() {
    let (mut test, mut clk) = setup(0);

    // Opens at 1000, first stage at +1000 (== 2000 absolute).
    let mut wallet = new_graded(1000, test.ctx());
    wallet.fund(1_000_000, test.ctx());

    clk.set_for_testing(999); // pre-start
    vesting_wallet_graded::release(&mut wallet, &clk, test.ctx());
    clk.set_for_testing(1000); // at start, before the first stage
    vesting_wallet_graded::release(&mut wallet, &clk, test.ctx());
    clk.set_for_testing(1999); // one ms before the first stage
    vesting_wallet_graded::release(&mut wallet, &clk, test.ctx());

    assert_eq!(wallet.released(), 0);
    assert_eq!(wallet.balance(), 1_000_000);
    assert_eq!(event::events_by_type<Released<Graded, USDC>>().length(), 0);

    destroy(wallet);
    teardown(test, clk);
}

// The subtlest "early release" shape: deposit more *after* a partial release, then claim
// again at the same clock. The fresh deposit vests retroactively at the elapsed
// proportion (documented behavior), but the payout is always exactly the live curve over
// the current total and is fully balance-backed - the second release never aborts and
// never pays more than the wallet holds.
#[test]
fun retroactive_deposit_never_over_releases() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_graded(0, test.ctx());
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(2000); // stage 2: 30% => 300
    vesting_wallet_graded::release(&mut wallet, &clk, test.ctx());
    assert_eq!(wallet.released(), 300);
    assert_eq!(wallet.balance(), 700);

    // Late deposit; total is now 2000, re-derived fresh at call time.
    wallet.fund(1000, test.ctx());
    let releasable = vesting_wallet_graded::releasable(&wallet, &clk);
    assert_eq!(releasable, 300); // 30% of 2000 = 600 cumulative, minus 300 already released
    assert!(releasable <= wallet.balance()); // never exceeds the balance backing it

    vesting_wallet_graded::release(&mut wallet, &clk, test.ctx());
    assert_eq!(wallet.released(), 600);
    assert_eq!(wallet.balance(), 1400);
    assert_eq!(wallet.balance() + wallet.released(), 2000); // conserved: nothing minted from nowhere

    destroy(wallet);
    teardown(test, clk);
}

// Releasing funds out and re-funding could otherwise drive `balance + released` past
// u64::MAX; the `deposit` guard rejects the offending refund up front.
#[test, expected_failure(abort_code = vesting_wallet::EBalanceOverflow)]
fun overflowing_refund_is_rejected_at_deposit() {
    let (mut test, mut clk) = setup(0);
    let max = std::u64::max_value!();

    let mut wallet = vesting_wallet_graded::new<USDC>(
        BENEFICIARY,
        0,
        vector[1, max],
        vector[1, 10000],
        test.ctx(),
    );
    wallet.fund(max, test.ctx());

    clk.set_for_testing(1); // stage 1: floor(max * 1 / 10000) releasable
    vesting_wallet_graded::release(&mut wallet, &clk, test.ctx());

    // Refunding the released amount would push balance + released past max, so the
    // deposit is rejected here rather than bricking a later release.
    wallet.fund(max, test.ctx());
    abort
}

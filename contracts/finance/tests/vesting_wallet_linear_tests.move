#[test_only]
module openzeppelin_finance::vesting_wallet_linear_tests;

use openzeppelin_finance::vesting_wallet_linear::{Self, Linear, Params};
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

fun new_linear(
    start: u64,
    cliff: u64,
    duration: u64,
    ctx: &mut TxContext,
): VestingWallet<Linear, Params, USDC> {
    vesting_wallet_linear::new<USDC>(BENEFICIARY, start, cliff, duration, ctx)
}

fun fund(wallet: &mut VestingWallet<Linear, Params, USDC>, amount: u64, ctx: &mut TxContext) {
    wallet.deposit(coin::mint_for_testing<USDC>(amount, ctx));
}

/// The curve's cumulative vested total at the given clock.
fun vested(wallet: &VestingWallet<Linear, Params, USDC>, clk: &Clock): u64 {
    vesting_wallet_linear::vested_amount(wallet, clk).amount()
}

// === Construction guards ===

// A zero duration is rejected.
#[test, expected_failure(abort_code = vesting_wallet_linear::EZeroDuration)]
fun new_rejects_zero_duration() {
    let mut ctx = tx_context::dummy();
    // `new` aborts before returning; `destroy` only satisfies the type checker.
    destroy(new_linear(0, 0, 0, &mut ctx));
}

// A cliff longer than the duration is rejected.
#[test, expected_failure(abort_code = vesting_wallet_linear::EInvalidCliff)]
fun new_rejects_cliff_exceeding_duration() {
    let mut ctx = tx_context::dummy();
    destroy(new_linear(0, 1001, 1000, &mut ctx));
}

// A schedule whose end (start + duration) would overflow u64 is rejected.
#[test, expected_failure(abort_code = vesting_wallet_linear::EScheduleOverflow)]
fun new_rejects_schedule_overflow() {
    let mut ctx = tx_context::dummy();
    destroy(new_linear(std::u64::max_value!(), 0, 1, &mut ctx));
}

// Boundary: a schedule whose end is exactly u64::MAX is valid and `end()`
// does not abort.
#[test]
fun new_accepts_end_at_u64_max_boundary() {
    let mut ctx = tx_context::dummy();
    let max = std::u64::max_value!();

    let wallet = new_linear(max - 1000, 0, 1000, &mut ctx);
    assert_eq!(vesting_wallet_linear::end(&wallet), max);

    destroy(wallet);
}

// Accept boundary: cliff == duration is allowed; nothing vests until the end,
// then the curve jumps straight to the full total.
#[test]
fun new_accepts_cliff_equal_to_duration() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_linear(0, 1000, 1000, test.ctx());
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(999);
    assert_eq!(wallet.vested(&clk), 0); // still gated by the cliff
    clk.set_for_testing(1000);
    assert_eq!(wallet.vested(&clk), 1000); // cliff boundary == end: total * 1000 / 1000

    destroy(wallet);
    teardown(test, clk);
}

// === Construction state & topology ===

// `Created` is emitted exactly once with the full payload asserted, and the params
// are readable through the accessors.
#[test]
fun new_sets_params_and_emits_created() {
    let (mut test, clk) = setup(0);

    let wallet = new_linear(100, 250, 1000, test.ctx());

    assert_eq!(vesting_wallet_linear::start(&wallet), 100);
    assert_eq!(vesting_wallet_linear::cliff(&wallet), 250);
    assert_eq!(vesting_wallet_linear::duration(&wallet), 1000);
    assert_eq!(vesting_wallet_linear::end(&wallet), 1100);

    let created = event::events_by_type<Created<Linear, Params, USDC>>();
    assert_eq!(created.length(), 1);
    assert_eq!(
        created[0],
        vesting_wallet::test_new_created<Linear, Params, USDC>(
            object::id(&wallet),
            BENEFICIARY,
            vesting_wallet_linear::test_params(100, 250, 1000),
        ),
    );

    destroy(wallet);
    teardown(test, clk);
}

// `create_and_share` puts the wallet into the shared topology.
#[test]
fun create_and_share_shares_wallet() {
    let (mut test, clk) = setup(0);

    vesting_wallet_linear::create_and_share<USDC>(BENEFICIARY, 0, 0, 1000, test.ctx());

    test.next_tx(@0x1);
    let wallet = test.take_shared<VestingWallet<Linear, Params, USDC>>();
    assert_eq!(wallet.beneficiary(), BENEFICIARY);
    assert_eq!(vesting_wallet_linear::duration(&wallet), 1000);
    test_scenario::return_shared(wallet);

    teardown(test, clk);
}

// === Curve shape ===

// Before `start_ms`, the curve is zero and does not underflow.
#[test]
fun vested_amount_pre_start_is_zero() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_linear(1000, 0, 1000, test.ctx());
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(999);
    assert_eq!(wallet.vested(&clk), 0);

    destroy(wallet);
    teardown(test, clk);
}

// Lower boundary: at now == start_ms with no cliff the elapsed time is 0,
// so the curve reads exactly 0 - the lower edge of the linear branch.
#[test]
fun vested_amount_at_exact_start_is_zero() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_linear(1000, 0, 1000, test.ctx());
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(1000); // now == start_ms, elapsed == 0
    assert_eq!(wallet.vested(&clk), 0);

    destroy(wallet);
    teardown(test, clk);
}

// With a cliff, nothing vests before the cliff boundary.
#[test]
fun vested_amount_pre_cliff_is_zero() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_linear(0, 1000, 4000, test.ctx());
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(0);
    assert_eq!(wallet.vested(&clk), 0);
    clk.set_for_testing(999);
    assert_eq!(wallet.vested(&clk), 0);

    destroy(wallet);
    teardown(test, clk);
}

// The key cliff behavior: at the cliff boundary the curve jumps from 0
// to the linear-from-start proportion `total * cliff / duration`.
#[test]
fun vested_amount_at_cliff_jumps_to_proportional() {
    let (mut test, mut clk) = setup(0);

    // total = 1000, cliff = 1000, duration = 4000  =>  jump to 1000 * 1000 / 4000 = 250
    let mut wallet = new_linear(0, 1000, 4000, test.ctx());
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(999);
    assert_eq!(wallet.vested(&clk), 0);
    clk.set_for_testing(1000);
    assert_eq!(wallet.vested(&clk), 250);

    destroy(wallet);
    teardown(test, clk);
}

// Between cliff and end the curve is linear from start.
#[test]
fun vested_amount_is_linear_mid_schedule() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_linear(0, 1000, 4000, test.ctx());
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(2000);
    assert_eq!(wallet.vested(&clk), 500); // 1000 * 2000 / 4000
    clk.set_for_testing(3000);
    assert_eq!(wallet.vested(&clk), 750); // 1000 * 3000 / 4000

    destroy(wallet);
    teardown(test, clk);
}

// At and after the end the curve clamps to the wallet total.
#[test]
fun vested_amount_post_end_clamps_to_total() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_linear(0, 0, 4000, test.ctx());
    wallet.fund(1000, test.ctx());

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

    let mut wallet = new_linear(0, 1000, 4000, test.ctx());
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
// (total = duration = u64::MAX) does not overflow and the final value fits in u64.
#[test]
fun vested_amount_uses_u128_intermediate_at_max() {
    let (mut test, mut clk) = setup(0);
    let max = std::u64::max_value!();

    let mut wallet = new_linear(0, 0, max, test.ctx());
    wallet.fund(max, test.ctx());

    clk.set_for_testing(max - 1);
    // max * (max - 1) / max == max - 1, with no overflow and no abort.
    assert_eq!(wallet.vested(&clk), max - 1);

    destroy(wallet);
    teardown(test, clk);
}

// A deposit made after start immediately participates in vesting at the
// current proportion - the total is re-derived, not captured at construction.
#[test]
fun deposit_vests_as_if_from_start() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_linear(0, 0, 1000, test.ctx());

    clk.set_for_testing(500);
    assert_eq!(wallet.vested(&clk), 0); // nothing deposited yet

    wallet.fund(1000, test.ctx());
    // half the window has elapsed, so half the fresh deposit is already vested.
    assert_eq!(wallet.vested(&clk), 500);

    destroy(wallet);
    teardown(test, clk);
}

// === Release through the linear curve ===

// A mid-schedule release pays the linear portion to the
// beneficiary, conserves the ledger, and is callable by an unrelated sender.
#[test]
fun release_pays_linear_portion_and_is_permissionless() {
    let mut test = test_scenario::begin(@0xCAFE); // unrelated sender
    let mut clk = clock::create_for_testing(test.ctx());

    let mut wallet = new_linear(0, 0, 1000, test.ctx());
    let wallet_id = object::id(&wallet);
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(400);
    vesting_wallet_linear::release(&mut wallet, &clk, test.ctx());

    assert_eq!(wallet.released(), 400);
    assert_eq!(wallet.balance(), 600);

    let released = event::events_by_type<Released<Linear, USDC>>();
    assert_eq!(released.length(), 1);
    assert_eq!(
        released[0],
        vesting_wallet::test_new_released<Linear, USDC>(wallet_id, BENEFICIARY, 400),
    );

    destroy(wallet);

    test.next_tx(BENEFICIARY);
    let coin = test.take_from_sender<coin::Coin<USDC>>();
    assert_eq!(coin.value(), 400);
    destroy(coin);

    destroy(clk);
    test.end();
}

// Releasing again at the same clock is a no-op (this
// idempotency is also what makes concurrent shared-object releases safe).
#[test]
fun release_then_release_at_same_clock_is_noop() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_linear(0, 0, 1000, test.ctx());
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(400);
    vesting_wallet_linear::release(&mut wallet, &clk, test.ctx());
    assert_eq!(wallet.released(), 400);
    assert_eq!(event::events_by_type<Released<Linear, USDC>>().length(), 1);

    // Second release at the same clock: nothing new, no event, no change.
    test.next_tx(@0x1);
    vesting_wallet_linear::release(&mut wallet, &clk, test.ctx());
    assert_eq!(wallet.released(), 400);
    assert_eq!(wallet.balance(), 600);
    assert_eq!(event::events_by_type<Released<Linear, USDC>>().length(), 0);

    destroy(wallet);
    teardown(test, clk);
}

// The `releasable` view matches what `release` actually pays, and reads
// zero immediately after a release at the same clock.
#[test]
fun releasable_view_matches_release() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_linear(0, 0, 1000, test.ctx());
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(400);
    assert_eq!(vesting_wallet_linear::releasable(&wallet, &clk), 400);

    vesting_wallet_linear::release(&mut wallet, &clk, test.ctx());
    assert_eq!(vesting_wallet_linear::releasable(&wallet, &clk), 0);

    destroy(wallet);
    teardown(test, clk);
}

// After the end the whole total is releasable, and once drained
// nothing more is releasable.
#[test]
fun full_release_after_end_then_releasable_zero() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_linear(0, 0, 1000, test.ctx());
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(1000);
    vesting_wallet_linear::release(&mut wallet, &clk, test.ctx());
    assert_eq!(wallet.released(), 1000);
    assert_eq!(wallet.balance(), 0);
    assert_eq!(vesting_wallet_linear::releasable(&wallet, &clk), 0);

    destroy(wallet);
    teardown(test, clk);
}

// === Teardown ===

// A drained, ended wallet can be torn down and
// emits `Destroyed`.
#[test]
fun destroy_after_end_on_empty_wallet() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_linear(0, 0, 1000, test.ctx());
    let wallet_id = object::id(&wallet);
    wallet.fund(1000, test.ctx());

    clk.set_for_testing(1000);
    vesting_wallet_linear::release(&mut wallet, &clk, test.ctx());
    assert_eq!(wallet.balance(), 0);

    test.next_tx(@0x1);
    vesting_wallet_linear::destroy(wallet, &clk);

    let destroyed = event::events_by_type<Destroyed<Linear, USDC>>();
    assert_eq!(destroyed.length(), 1);
    assert_eq!(
        destroyed[0],
        vesting_wallet::test_new_destroyed<Linear, USDC>(wallet_id, BENEFICIARY, 1000),
    );

    teardown(test, clk);
}

// Tearing down before the schedule end aborts, even on an empty wallet.
#[test, expected_failure(abort_code = vesting_wallet_linear::ENotEnded)]
fun destroy_rejects_before_end() {
    let (mut test, mut clk) = setup(0);

    let wallet = new_linear(0, 0, 1000, test.ctx());
    clk.set_for_testing(999);
    vesting_wallet_linear::destroy(wallet, &clk);
    abort
}

// Tearing down a wallet that still holds a balance aborts (the empty-balance
// gate from the primitive fires before the ended gate).
#[test, expected_failure(abort_code = vesting_wallet::ENotEmpty)]
fun destroy_rejects_nonempty_balance() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_linear(0, 0, 1000, test.ctx());
    wallet.fund(1, test.ctx());
    clk.set_for_testing(2000); // after end, so only the balance gate can fire
    vesting_wallet_linear::destroy(wallet, &clk);
    abort
}

// === Composability ===

// create + deposit + release compose in a single transaction.
#[test]
fun create_deposit_release_in_one_flow() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_linear(0, 0, 1000, test.ctx());
    wallet.fund(1000, test.ctx());
    clk.set_for_testing(500);
    vesting_wallet_linear::release(&mut wallet, &clk, test.ctx());

    assert_eq!(wallet.released(), 500);
    assert_eq!(wallet.balance(), 500);

    destroy(wallet);
    teardown(test, clk);
}

// receive_and_deposit + release compose in a single transaction - the
// emission-schedule / payroll path where a coin is claimed from the wallet's address
// and the vested portion is released in one go.
#[test]
fun receive_and_deposit_then_release_in_one_flow() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());

    let wallet = new_linear(0, 0, 1000, test.ctx());
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
    vesting_wallet_linear::release(&mut wallet, &clk, test.ctx());

    assert_eq!(wallet.released(), 500);
    assert_eq!(wallet.balance(), 500);

    test_scenario::return_shared(wallet);
    destroy(clk);
    test.end();
}

// === Early-release resistance ===

// An attacker poking `release` before the schedule opens, and again inside the cliff
// window, moves no funds: the curve reads 0 throughout that region, so `release`
// short-circuits on a zero releasable - no payout, no `Released` event, balance
// untouched. This is the direct "release before the curve vests anything" attempt.
#[test]
fun release_before_cliff_moves_no_funds() {
    let (mut test, mut clk) = setup(0);

    // Opens at 1000, cliff boundary at 1500, ends at 2000.
    let mut wallet = new_linear(1000, 500, 1000, test.ctx());
    wallet.fund(1_000_000, test.ctx());

    clk.set_for_testing(999); // pre-start
    vesting_wallet_linear::release(&mut wallet, &clk, test.ctx());
    clk.set_for_testing(1000); // at start, still inside the cliff
    vesting_wallet_linear::release(&mut wallet, &clk, test.ctx());
    clk.set_for_testing(1499); // one ms before the cliff boundary
    vesting_wallet_linear::release(&mut wallet, &clk, test.ctx());

    assert_eq!(wallet.released(), 0);
    assert_eq!(wallet.balance(), 1_000_000);
    assert_eq!(event::events_by_type<Released<Linear, USDC>>().length(), 0);

    destroy(wallet);
    teardown(test, clk);
}

// The subtlest "early release" shape: deposit more *after* a partial release, then
// claim again at the same clock. The fresh deposit vests retroactively at the elapsed
// proportion (documented behavior), but the payout is always exactly the live curve
// over the current total and is fully balance-backed - the second release never
// aborts and never pays more than the wallet holds. So nothing leaves ahead of the
// curve; the late deposit simply funds its own (proportional) unlock.
#[test]
fun retroactive_deposit_never_over_releases() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_linear(0, 0, 100, test.ctx());
    wallet.fund(100, test.ctx());

    clk.set_for_testing(50);
    vesting_wallet_linear::release(&mut wallet, &clk, test.ctx()); // floor(100 * 50 / 100) = 50
    assert_eq!(wallet.released(), 50);
    assert_eq!(wallet.balance(), 50);

    // Late deposit; total is now 200, re-derived fresh at call time.
    wallet.fund(100, test.ctx());
    let releasable = vesting_wallet_linear::releasable(&wallet, &clk);
    assert_eq!(releasable, 50); // floor(200 * 50 / 100) = 100 cumulative, minus 50 already released
    assert!(releasable <= wallet.balance()); // never exceeds the balance backing it

    vesting_wallet_linear::release(&mut wallet, &clk, test.ctx()); // does not abort, does not over-pay
    assert_eq!(wallet.released(), 100);
    assert_eq!(wallet.balance(), 100);
    assert_eq!(wallet.balance() + wallet.released(), 200); // conserved: nothing minted from nowhere

    destroy(wallet);
    teardown(test, clk);
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

    let mut wallet = new_linear(0, 0, max, test.ctx());
    wallet.fund(max, test.ctx());

    clk.set_for_testing(1);
    vesting_wallet_linear::release(&mut wallet, &clk, test.ctx()); // releases 1; balance = max - 1, released = 1

    // balance + released == max already; refunding the released 1 would overflow it,
    // so the deposit is rejected here rather than bricking a later release.
    wallet.fund(1, test.ctx());
    abort
}

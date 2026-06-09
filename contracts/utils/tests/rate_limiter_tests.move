#[test_only]
module openzeppelin_utils::rate_limiter_tests;

use openzeppelin_utils::rate_limiter;
use std::unit_test::assert_eq;
use sui::clock::{Self, Clock};
use sui::test_scenario::{Self, Scenario};

fun setup(t0: u64): (Scenario, Clock) {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(t0);
    (test, clk)
}

fun teardown(test: Scenario, clk: Clock) {
    clk.destroy_for_testing();
    test.end();
}

// === Bucket ===

#[test]
fun bucket_starts_full_and_refills_over_time() {
    let (test, mut clk) = setup(0);

    // Create a bucket with capacity 30, refilling 5 every 10 ms.
    let mut rl = rate_limiter::new_bucket(30, 5, 10, 30, clk.timestamp_ms(), &clk);
    assert_eq!(rl.available(&clk), 30);

    // Consuming 20 leaves 10 tokens.
    rl.consume_or_abort(20, &clk);
    assert_eq!(rl.available(&clk), 10);

    // After 20 ms, two refill steps (2 * 5 = 10) are credited back.
    clk.set_for_testing(20);
    assert_eq!(rl.available(&clk), 20);

    // Refill is capped at the configured capacity.
    clk.set_for_testing(1000);
    assert_eq!(rl.available(&clk), 30);

    teardown(test, clk);
}

#[test]
fun bucket_with_tokens_can_start_empty_and_accrue() {
    let (test, mut clk) = setup(0);

    // Start empty: no headroom until the first refill interval elapses.
    let mut rl = rate_limiter::new_bucket(10, 2, 5, 0, clk.timestamp_ms(), &clk);
    assert_eq!(rl.available(&clk), 0);
    assert!(!rl.try_consume(1, &clk));

    // After one refill interval, 2 tokens are credited.
    clk.set_for_testing(5);
    assert_eq!(rl.available(&clk), 2);

    teardown(test, clk);
}

#[test, expected_failure(abort_code = rate_limiter::EInitialAboveCapacity)]
fun bucket_with_tokens_rejects_initial_above_capacity() {
    let (_test, clk) = setup(0);
    rate_limiter::new_bucket(10, 1, 10, 11, clk.timestamp_ms(), &clk);
    abort
}

#[test]
fun bucket_try_consume_returns_false_when_empty() {
    let (test, clk) = setup(0);

    let mut rl = rate_limiter::new_bucket(10, 1, 100, 10, clk.timestamp_ms(), &clk);
    assert!(rl.try_consume(10, &clk));
    // No refill has happened yet, so the next consume fails without aborting.
    assert!(!rl.try_consume(1, &clk));

    teardown(test, clk);
}

#[test, expected_failure(abort_code = rate_limiter::ERateLimited)]
fun bucket_consume_or_abort_aborts_when_empty() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_bucket(5, 1, 10, 5, clk.timestamp_ms(), &clk);
    rl.consume_or_abort(10, &clk);
    abort
}

// === Overflow-interval discard ===
//
// A bucket sitting at capacity while whole refill intervals elapse must treat those
// intervals as overflow and discard them. Concretely, after a single drain at `now`,
// a second consume at the SAME `now` must not succeed - the elapsed intervals that
// were absorbed as overflow cannot reappear as fresh headroom.

#[test]
fun bucket_full_discards_overflow_intervals_at_same_timestamp() {
    // capacity 10, refill 1 every 100ms, starts full at t=1_000_000.
    // 10 intervals elapse with the bucket already at capacity → all 10 are overflow.
    // A single try_consume(10) at t=1_001_000 must drain the bucket; a second
    // consume at the same t must fail.
    let (test, mut clk) = setup(1_000_000);

    let mut rl = rate_limiter::new_bucket(10, 1, 100, 10, clk.timestamp_ms(), &clk);
    clk.set_for_testing(1_001_000);

    assert!(rl.try_consume(10, &clk));
    assert_eq!(rl.available(&clk), 0);
    assert!(!rl.try_consume(1, &clk));

    teardown(test, clk);
}

#[test]
fun bucket_partial_fill_discards_overflow_intervals_at_same_timestamp() {
    // capacity 10, refill 1 every 100ms, starts at 8 tokens at t=1_000_000.
    // Over 1000 ms (10 intervals): the first 2 intervals fill the bucket
    // (reaches 10 at t=1_000_200), the remaining 8 are overflow.
    // A single try_consume(10) at t=1_001_000 must drain the bucket; a second
    // consume at the same t must fail.
    let (test, mut clk) = setup(1_000_000);

    let mut rl = rate_limiter::new_bucket(10, 1, 100, 8, clk.timestamp_ms(), &clk);
    clk.set_for_testing(1_001_000);

    assert!(rl.try_consume(10, &clk));
    assert_eq!(rl.available(&clk), 0);
    assert!(!rl.try_consume(1, &clk));

    // One additional refill interval after the drain should credit exactly one token.
    // If overflow intervals had been preserved as anchor drift instead of discarded,
    // `available` here would jump to 9 (the 8 discarded intervals + 1 new).
    clk.set_for_testing(1_001_100);
    assert_eq!(rl.available(&clk), 1);
    assert!(rl.try_consume(1, &clk));
    assert!(!rl.try_consume(1, &clk));

    teardown(test, clk);
}

// === Fixed Window ===

#[test]
fun fixed_window_can_start_with_partial_available() {
    let (test, mut clk) = setup(0);

    // Start with 1 of 3 units available; the first window is partially consumed.
    let mut rl = rate_limiter::new_fixed_window(3, 100, 0, 1, &clk);
    assert_eq!(rl.available(&clk), 1);

    rl.consume_or_abort(1, &clk);
    assert_eq!(rl.available(&clk), 0);
    assert!(!rl.try_consume(1, &clk));

    // After a full window, `available` resets to capacity.
    clk.set_for_testing(100);
    assert_eq!(rl.available(&clk), 3);

    teardown(test, clk);
}

#[test, expected_failure(abort_code = rate_limiter::EInitialAboveCapacity)]
fun fixed_window_rejects_initial_above_capacity() {
    let (_test, clk) = setup(0);
    rate_limiter::new_fixed_window(5, 100, 0, 6, &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EWindowAnchorInFuture)]
fun fixed_window_rejects_anchor_in_future() {
    let (_test, clk) = setup(50);
    rate_limiter::new_fixed_window(5, 100, 51, 5, &clk);
    abort
}

#[test]
fun fixed_window_counts_per_window_and_resets_on_boundary() {
    let (test, mut clk) = setup(0);

    // 3 consumes per 100 ms window.
    let mut rl = rate_limiter::new_fixed_window(3, 100, 0, 3, &clk);
    assert_eq!(rl.available(&clk), 3);

    rl.consume_or_abort(1, &clk);
    rl.consume_or_abort(1, &clk);
    assert_eq!(rl.available(&clk), 1);

    // Still inside the first window: fourth consume is blocked.
    assert!(!rl.try_consume(2, &clk));

    // Crossing into the next window resets usage back to full capacity.
    clk.set_for_testing(150);
    assert_eq!(rl.available(&clk), 3);
    rl.consume_or_abort(3, &clk);
    assert_eq!(rl.available(&clk), 0);

    teardown(test, clk);
}

// === Cooldown ===

#[test]
fun cooldown_can_start_with_partial_available() {
    let (test, clk) = setup(0);

    // Start with 2 of 5 units already consumed.
    let mut rl = rate_limiter::new_cooldown(5, 50, 3, 0, &clk);
    assert_eq!(rl.available(&clk), 3);

    rl.consume_or_abort(3, &clk);
    assert_eq!(rl.available(&clk), 0);
    assert!(!rl.try_consume(1, &clk));

    teardown(test, clk);
}

#[test, expected_failure(abort_code = rate_limiter::EInitialAboveCapacity)]
fun cooldown_rejects_initial_above_capacity() {
    let (_test, clk) = setup(0);
    rate_limiter::new_cooldown(5, 50, 6, 0, &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::ECooldownArmedWithTokens)]
fun cooldown_rejects_armed_gate_with_tokens() {
    // initial_available > 0 with cooldown_end_ms in the future is contradictory:
    // the hot path consults cooldown_end_ms only when available == 0, so the seeded
    // deadline would be silently dropped the next time the batch drains.
    let (_test, clk) = setup(50);
    rate_limiter::new_cooldown(5, 50, 3, 100, &clk);
    abort
}

#[test]
fun cooldown_accepts_stale_gate_with_tokens() {
    // A non-zero cooldown_end_ms that's already in the past is harmless: the gate
    // would project as released anyway, and it will be overwritten on the next drain.
    let (test, clk) = setup(100);
    let rl = rate_limiter::new_cooldown(5, 50, 3, 50, &clk);
    assert_eq!(rl.available(&clk), 3);
    teardown(test, clk);
}

#[test]
fun cooldown_accepts_zero_initial_and_zero_end() {
    // With both `initial_available == 0` and `cooldown_end_ms == 0` the limiter acts
    // as if available was appropriately set.
    let (test, clk) = setup(0);
    let rl = rate_limiter::new_cooldown(5, 50, 0, 0, &clk);
    assert_eq!(rl.available(&clk), 5);
    teardown(test, clk);
}

#[test]
fun cooldown_zero_initial_with_armed_gate_releases_on_elapse() {
    // Seeding an in-flight gate: `initial_available = 0` is allowed when
    // `cooldown_end_ms > 0` (e.g. when reconstructing a limiter mid-throttle).
    let (test, mut clk) = setup(0);

    let mut rl = rate_limiter::new_cooldown(5, 50, 0, 100, &clk);
    assert_eq!(rl.available(&clk), 0);
    assert!(!rl.try_consume(1, &clk));

    // Before the seeded deadline: still gated.
    clk.set_for_testing(99);
    assert_eq!(rl.available(&clk), 0);

    // At the seeded deadline: gate releases to full capacity.
    clk.set_for_testing(100);
    assert_eq!(rl.available(&clk), 5);
    assert!(rl.try_consume(5, &clk));

    teardown(test, clk);
}

#[test]
fun cooldown_requires_elapsed_time_between_consumes() {
    let (test, mut clk) = setup(100);

    // 50 ms cooldown between single-unit consumes (capacity 1 => cooldown after each).
    let mut rl = rate_limiter::new_cooldown(1, 50, 1, 0, &clk);
    assert_eq!(rl.available(&clk), 1);

    // First consume succeeds.
    rl.consume_or_abort(1, &clk);
    assert_eq!(rl.available(&clk), 0);

    // Before the cooldown elapses, consumes are rejected.
    clk.set_for_testing(140);
    assert!(!rl.try_consume(1, &clk));

    // After the cooldown, a consume succeeds again.
    clk.set_for_testing(150);
    assert_eq!(rl.available(&clk), 1);
    rl.consume_or_abort(1, &clk);

    teardown(test, clk);
}

#[test]
fun cooldown_decrements_available_by_amount_until_drained_then_gates() {
    let (test, mut clk) = setup(0);

    // Capacity 5: try_consume(amount) decrements `available` by `amount`,
    // until `available == 0`, then the cooldown gates.
    let mut rl = rate_limiter::new_cooldown(5, 50, 5, 0, &clk);
    assert!(rl.try_consume(2, &clk));
    assert_eq!(rl.available(&clk), 3);
    assert!(rl.try_consume(1, &clk));
    assert_eq!(rl.available(&clk), 2);
    assert!(rl.try_consume(2, &clk)); // drains to 0 - gate arms
    assert_eq!(rl.available(&clk), 0);
    assert!(!rl.try_consume(1, &clk));

    // After cooldown elapses, the budget resets to full capacity.
    clk.set_for_testing(50);
    assert_eq!(rl.available(&clk), 5);
    assert!(rl.try_consume(5, &clk));
    assert_eq!(rl.available(&clk), 0);

    teardown(test, clk);
}

#[test]
fun cooldown_rejects_amount_exceeding_available() {
    let (test, clk) = setup(0);

    // Picking an `amount` that fits is the caller's responsibility; oversized requests
    // are rejected without changing state.
    let mut rl = rate_limiter::new_cooldown(5, 50, 5, 0, &clk);
    assert!(rl.try_consume(3, &clk));
    assert_eq!(rl.available(&clk), 2);

    // Asking more than the remaining `available` fails.
    assert!(!rl.try_consume(3, &clk));
    assert_eq!(rl.available(&clk), 2);

    // Asking more than the configured capacity also fails.
    assert!(!rl.try_consume(99, &clk));
    assert_eq!(rl.available(&clk), 2);

    // The remaining headroom is still spendable.
    assert!(rl.try_consume(2, &clk));
    assert_eq!(rl.available(&clk), 0);

    teardown(test, clk);
}

#[test]
fun try_consume_with_zero_amount_returns_false_bucket() {
    let (test, clk) = setup(0);
    let mut rl = rate_limiter::new_bucket(10, 1, 10, 10, clk.timestamp_ms(), &clk);
    assert!(!rl.try_consume(0, &clk));
    teardown(test, clk);
}

#[test]
fun try_consume_with_zero_amount_returns_false_fixed_window() {
    let (test, clk) = setup(0);
    let mut rl = rate_limiter::new_fixed_window(10, 100, 0, 10, &clk);
    assert!(!rl.try_consume(0, &clk));
    teardown(test, clk);
}

#[test]
fun try_consume_with_zero_amount_returns_false_cooldown() {
    let (test, clk) = setup(0);
    let mut rl = rate_limiter::new_cooldown(10, 50, 10, 0, &clk);
    assert!(!rl.try_consume(0, &clk));
    teardown(test, clk);
}

// === Constructor config validation ===

#[test, expected_failure(abort_code = rate_limiter::EZeroCapacity)]
fun new_bucket_rejects_zero_capacity() {
    let (_test, clk) = setup(0);
    rate_limiter::new_bucket(0, 1, 1, 0, clk.timestamp_ms(), &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EZeroRefillAmount)]
fun new_bucket_rejects_zero_refill_amount() {
    let (_test, clk) = setup(0);
    rate_limiter::new_bucket(10, 0, 1, 10, clk.timestamp_ms(), &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EZeroRefillInterval)]
fun new_bucket_rejects_zero_refill_interval_ms() {
    let (_test, clk) = setup(0);
    rate_limiter::new_bucket(10, 1, 0, 10, clk.timestamp_ms(), &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EBucketAnchorInFuture)]
fun new_bucket_rejects_anchor_in_future() {
    let (_test, clk) = setup(50);
    rate_limiter::new_bucket(10, 1, 10, 10, 51, &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EZeroCapacity)]
fun new_fixed_window_rejects_zero_capacity() {
    let (_test, clk) = setup(0);
    rate_limiter::new_fixed_window(0, 100, 0, 0, &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EZeroWindow)]
fun new_fixed_window_rejects_zero_window_ms() {
    let (_test, clk) = setup(0);
    rate_limiter::new_fixed_window(10, 0, 0, 10, &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EZeroCooldown)]
fun new_cooldown_rejects_zero_cooldown_ms() {
    let (_test, clk) = setup(0);
    rate_limiter::new_cooldown(1, 0, 1, 0, &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EZeroCapacity)]
fun new_cooldown_rejects_zero_capacity() {
    let (_test, clk) = setup(0);
    rate_limiter::new_cooldown(0, 50, 0, 0, &clk);
    abort
}

// === All-or-nothing failure semantics ===

#[test]
fun bucket_failed_try_consume_does_not_drain_state() {
    let (test, clk) = setup(0);

    // Long refill interval keeps accrual out of the picture.
    let mut rl = rate_limiter::new_bucket(10, 1, 1_000_000, 10, clk.timestamp_ms(), &clk);
    rl.consume_or_abort(5, &clk);
    assert_eq!(rl.available(&clk), 5);

    // Asking more than available must return false without touching state.
    assert!(!rl.try_consume(8, &clk));
    assert_eq!(rl.available(&clk), 5);

    // The 5 unconsumed tokens are still spendable.
    assert!(rl.try_consume(5, &clk));
    assert_eq!(rl.available(&clk), 0);

    teardown(test, clk);
}

#[test]
fun fixed_window_failed_try_consume_does_not_advance_used() {
    let (test, clk) = setup(0);

    let mut rl = rate_limiter::new_fixed_window(5, 100, 0, 5, &clk);
    rl.consume_or_abort(3, &clk);
    assert_eq!(rl.available(&clk), 2);

    assert!(!rl.try_consume(4, &clk));
    assert_eq!(rl.available(&clk), 2);

    // Remaining headroom is fully usable.
    assert!(rl.try_consume(2, &clk));
    assert_eq!(rl.available(&clk), 0);

    teardown(test, clk);
}

#[test]
fun cooldown_failed_try_consume_does_not_reset_anchor() {
    let (test, mut clk) = setup(0);

    let mut rl = rate_limiter::new_cooldown(1, 100, 1, 0, &clk);
    assert!(rl.try_consume(1, &clk)); // cooldown_end_ms = 100

    // Failed call mid-cooldown must NOT push the deadline forward.
    clk.set_for_testing(50);
    assert!(!rl.try_consume(1, &clk));

    // If the failed call had re-anchored, the deadline would now be 150.
    // It stayed at 100, so the cooldown elapses exactly at t=100.
    clk.set_for_testing(100);
    assert!(rl.try_consume(1, &clk));

    teardown(test, clk);
}

// === available() reflects pending time transitions after failed try_consume ===
//
// Failed `try_consume` is observably a no-op: no anchor advance, no balance change.
// `available()` projects accrual / window rollover / gate release on read, so a failed
// consume that crosses a time boundary still reports the up-to-date headroom via
// `available()` - it just doesn't persist the projection.

#[test]
fun bucket_available_returns_up_to_date_accrual_even_on_failed_try_consume() {
    let (test, mut clk) = setup(0);

    // Empty bucket, 1 token / 10 ms.
    let mut rl = rate_limiter::new_bucket(10, 1, 10, 0, clk.timestamp_ms(), &clk);

    // 50 ms in: 5 tokens accrued under the old anchor. An oversized request fails
    // without mutating state, but `available()` projects the accrual on read.
    clk.set_for_testing(50);
    assert!(!rl.try_consume(99, &clk));
    assert_eq!(rl.available(&clk), 5);

    // The accrued tokens are immediately spendable at the same `now`.
    assert!(rl.try_consume(5, &clk));
    assert_eq!(rl.available(&clk), 0);

    teardown(test, clk);
}

#[test]
fun fixed_window_available_reflects_rollover_after_failed_try_consume() {
    let (test, mut clk) = setup(0);

    let mut rl = rate_limiter::new_fixed_window(5, 100, 0, 5, &clk);
    rl.consume_or_abort(3, &clk);
    assert_eq!(rl.available(&clk), 2);

    // Cross the window boundary with an oversized request. The failed consume does NOT
    // mutate state, but `available()` projects the rollover and reports the fresh window.
    clk.set_for_testing(100);
    assert!(!rl.try_consume(6, &clk));
    assert_eq!(rl.available(&clk), 5);

    teardown(test, clk);
}

#[test]
fun cooldown_available_reflects_release_after_failed_try_consume() {
    let (test, mut clk) = setup(0);

    let mut rl = rate_limiter::new_cooldown(5, 50, 5, 0, &clk);
    assert!(rl.try_consume(5, &clk)); // arms the gate: deadline = 50, available = 0

    // Past the deadline, attempt an oversized consume. The failed consume does NOT
    // mutate state, but `available()` projects the gate release and reports the
    // fresh batch.
    clk.set_for_testing(50);
    assert!(!rl.try_consume(6, &clk));
    assert_eq!(rl.available(&clk), 5);

    teardown(test, clk);
}

// === Fractional time preservation ===

#[test]
fun bucket_preserves_subinterval_time_across_consumes() {
    let (test, mut clk) = setup(0);

    // Refill 1 token every 10 ms, starting empty.
    let mut rl = rate_limiter::new_bucket(10, 1, 10, 0, clk.timestamp_ms(), &clk);

    // 15 ms elapsed → exactly 1 token credited; 5 ms of fractional time must carry over.
    clk.set_for_testing(15);
    assert!(rl.try_consume(1, &clk));

    // After consume, last_refill_ms = 10 (not 15). At t=20 a full new 10-ms step has
    // elapsed since 10 → 1 token credited. If fractional time were discarded
    // (last_refill_ms = 15), only 5 ms would have elapsed and available would be 0.
    clk.set_for_testing(20);
    assert_eq!(rl.available(&clk), 1);

    teardown(test, clk);
}

// === Overflow safety ===

#[test]
fun bucket_no_overflow_with_huge_refill_amount() {
    let (test, mut clk) = setup(0);

    // refill_amount > capacity. Naive `elapsed_steps * refill_amount` would overflow
    // u64 at modest elapsed counts; the fill branch in `bucket_accrue` writes
    // `capacity` directly without computing the product.
    let huge_refill = 1_000_000_000_000_000_000;
    let rl = rate_limiter::new_bucket(1_000_000, huge_refill, 1, 0, clk.timestamp_ms(), &clk);

    clk.set_for_testing(20);
    assert_eq!(rl.available(&clk), 1_000_000);

    teardown(test, clk);
}

#[test]
fun bucket_no_overflow_under_extreme_clock_advance() {
    let (test, mut clk) = setup(0);

    // capacity = u64::MAX - 1 with refill_amount = 1 - exercises the fill branch under the
    // largest plausible elapsed-step count without any product overflow.
    let cap = 18446744073709551614;
    let rl = rate_limiter::new_bucket(cap, 1, 1, 0, clk.timestamp_ms(), &clk);

    // elapsed_steps ≈ u64::MAX → fill branch must produce `capacity` without overflow.
    clk.set_for_testing(18446744073709551615);
    assert_eq!(rl.available(&clk), cap);

    teardown(test, clk);
}

#[test]
fun fixed_window_try_consume_max_amount_returns_false() {
    let (test, clk) = setup(0);

    // The check is `amount > capacity - used` (not `used + amount > capacity`), so
    // u64::MAX is rejected without overflowing.
    let mut rl = rate_limiter::new_fixed_window(10, 100, 0, 10, &clk);
    assert!(!rl.try_consume(18446744073709551615, &clk));
    // State unchanged on rejection.
    assert_eq!(rl.available(&clk), 10);

    teardown(test, clk);
}

// === Anchor-based window grid ===

#[test]
fun fixed_window_first_window_has_full_length_at_nonzero_creation() {
    let (test, mut clk) = setup(99);

    // Creation at t=99 with window_ms=100. First window is [99, 199), not the
    // wall-clock-aligned [0, 100) the previous design produced.
    let mut rl = rate_limiter::new_fixed_window(5, 100, 99, 5, &clk);
    rl.consume_or_abort(3, &clk);

    // Wall-clock alignment would have rolled at t=100 (start of [100, 200)). With the
    // anchor at 99, no roll yet → `used` still 3.
    clk.set_for_testing(100);
    assert_eq!(rl.available(&clk), 2);

    // Still inside the first window all the way to t=198.
    clk.set_for_testing(198);
    assert_eq!(rl.available(&clk), 2);

    // Exactly one full window length elapsed → roll fires on next try_consume.
    clk.set_for_testing(199);
    assert_eq!(rl.available(&clk), 5);
    assert!(rl.try_consume(5, &clk));
    assert_eq!(rl.available(&clk), 0);

    teardown(test, clk);
}

// === available() consistency ===

#[test]
fun bucket_available_predicts_try_consume() {
    let (test, clk) = setup(50);

    let mut rl = rate_limiter::new_bucket(20, 5, 10, 20, clk.timestamp_ms(), &clk);
    let avail = rl.available(&clk);
    assert_eq!(avail, 20);
    assert!(rl.try_consume(avail, &clk));
    assert_eq!(rl.available(&clk), 0);

    teardown(test, clk);
}

#[test]
fun fixed_window_available_predicts_try_consume() {
    let (test, clk) = setup(0);

    let mut rl = rate_limiter::new_fixed_window(7, 100, 0, 7, &clk);
    let avail = rl.available(&clk);
    assert_eq!(avail, 7);
    assert!(rl.try_consume(avail, &clk));
    assert_eq!(rl.available(&clk), 0);

    teardown(test, clk);
}

#[test]
fun cooldown_available_predicts_try_consume() {
    let (test, clk) = setup(0);

    // available == N ⇒ try_consume(amount) succeeds whenever amount ≤ N
    // (uniform with Bucket / FixedWindow).
    let mut rl = rate_limiter::new_cooldown(7, 50, 7, 0, &clk);
    let avail = rl.available(&clk);
    assert_eq!(avail, 7);
    assert!(rl.try_consume(avail, &clk));
    assert_eq!(rl.available(&clk), 0);

    teardown(test, clk);
}

#[test]
fun try_consume_of_available_returns_false_when_drained() {
    // The `try_consume(self.available(clock), clock)` idiom silently returns false when
    // the limiter is empty: available() returns 0 and try_consume(0) is rejected.
    // Guard with `if n > 0 { self.try_consume(n, clock) }`.
    let (test, clk) = setup(0);
    let mut rl = rate_limiter::new_bucket(10, 1, 1_000_000, 10, clk.timestamp_ms(), &clk);
    rl.consume_or_abort(10, &clk);
    let n = rl.available(&clk);
    assert!(!rl.try_consume(n, &clk));
    teardown(test, clk);
}

#[test]
fun fixed_window_try_consume_of_available_returns_false_when_exhausted() {
    // Same footgun as `try_consume_of_available_returns_false_when_drained` but for
    // FixedWindow: available() returns 0 inside an exhausted window before rollover.
    let (test, clk) = setup(0);
    let mut rl = rate_limiter::new_fixed_window(5, 100, 0, 5, &clk);
    rl.consume_or_abort(5, &clk);
    let n = rl.available(&clk);
    assert!(!rl.try_consume(n, &clk));
    teardown(test, clk);
}

#[test]
fun cooldown_try_consume_of_available_returns_false_when_gated() {
    // Same footgun as `try_consume_of_available_returns_false_when_drained` but for
    // Cooldown: available() returns 0 while the gate is armed (deadline not yet elapsed).
    let (test, clk) = setup(0);
    let mut rl = rate_limiter::new_cooldown(5, 50, 5, 0, &clk);
    rl.consume_or_abort(5, &clk); // drains and arms the gate
    let n = rl.available(&clk);
    assert!(!rl.try_consume(n, &clk));
    teardown(test, clk);
}

// === consume_or_abort across variants ===

#[test, expected_failure(abort_code = rate_limiter::ERateLimited)]
fun fixed_window_consume_or_abort_aborts_when_full() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_fixed_window(2, 100, 0, 2, &clk);
    rl.consume_or_abort(2, &clk);
    rl.consume_or_abort(1, &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::ERateLimited)]
fun cooldown_consume_or_abort_aborts_when_in_cooldown() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_cooldown(1, 100, 1, 0, &clk);
    rl.consume_or_abort(1, &clk);
    rl.consume_or_abort(1, &clk);
    abort
}

// === Getters ===

#[test]
fun getters_return_constructor_values() {
    let (test, clk) = setup(0);

    let b = rate_limiter::new_bucket(30, 5, 10, 30, clk.timestamp_ms(), &clk);
    assert_eq!(b.capacity(), 30);
    assert_eq!(b.refill_amount(), 5);
    assert_eq!(b.refill_interval_ms(), 10);
    assert_eq!(b.last_refill_ms(&clk), clk.timestamp_ms());

    let fw = rate_limiter::new_fixed_window(7, 100, 0, 7, &clk);
    assert_eq!(fw.capacity(), 7);
    assert_eq!(fw.window_ms(), 100);
    assert_eq!(fw.window_start_ms(&clk), 0);

    let cd = rate_limiter::new_cooldown(5, 50, 5, 0, &clk);
    assert_eq!(cd.capacity(), 5);
    assert_eq!(cd.cooldown_ms(), 50);
    assert_eq!(cd.cooldown_end_ms(), 0);

    teardown(test, clk);
}

#[test]
fun cooldown_end_ms_getter_observes_arm_after_drain() {
    let (test, mut clk) = setup(0);

    let mut rl = rate_limiter::new_cooldown(1, 100, 1, 0, &clk);
    assert_eq!(rl.cooldown_end_ms(), 0);

    clk.set_for_testing(10);
    assert!(rl.try_consume(1, &clk));
    // Drain arms the gate at now + cooldown_ms = 10 + 100 = 110.
    assert_eq!(rl.cooldown_end_ms(), 110);

    teardown(test, clk);
}

#[test]
fun is_variant_predicates_are_exclusive_and_correct() {
    let (test, clk) = setup(0);

    // Each predicate is true for its own variant and false for the other two; none abort.
    let b = rate_limiter::new_bucket(10, 1, 10, 10, clk.timestamp_ms(), &clk);
    assert!(b.is_bucket());
    assert!(!b.is_fixed_window());
    assert!(!b.is_cooldown());

    let fw = rate_limiter::new_fixed_window(5, 100, 0, 5, &clk);
    assert!(!fw.is_bucket());
    assert!(fw.is_fixed_window());
    assert!(!fw.is_cooldown());

    let cd = rate_limiter::new_cooldown(5, 50, 5, 0, &clk);
    assert!(!cd.is_bucket());
    assert!(!cd.is_fixed_window());
    assert!(cd.is_cooldown());

    teardown(test, clk);
}

#[test]
fun is_variant_predicate_guards_variant_typed_getter() {
    // The intended use: branch on the predicate before calling a variant-typed getter that
    // would otherwise abort EWrongVariant on a mismatch.
    let (test, clk) = setup(0);

    let rl = rate_limiter::new_cooldown(5, 50, 5, 0, &clk);
    let v = if (rl.is_bucket()) rl.refill_amount()
    else if (rl.is_cooldown()) rl.cooldown_ms()
    else rl.window_ms();
    assert_eq!(v, 50); // resolved via is_cooldown() -> cooldown_ms(), no abort

    teardown(test, clk);
}

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun refill_amount_on_non_bucket_aborts() {
    let (_test, clk) = setup(0);
    let cd = rate_limiter::new_cooldown(1, 50, 1, 0, &clk);
    cd.refill_amount();
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun refill_interval_ms_on_non_bucket_aborts() {
    let (_test, clk) = setup(0);
    let fw = rate_limiter::new_fixed_window(5, 100, 0, 5, &clk);
    fw.refill_interval_ms();
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun last_refill_ms_on_non_bucket_aborts() {
    let (_test, clk) = setup(0);
    let cd = rate_limiter::new_cooldown(1, 50, 1, 0, &clk);
    cd.last_refill_ms(&clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun window_start_ms_on_non_fixed_window_aborts() {
    let (_test, clk) = setup(0);
    let b = rate_limiter::new_bucket(10, 1, 10, 10, clk.timestamp_ms(), &clk);
    b.window_start_ms(&clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun window_ms_on_non_fixed_window_aborts() {
    let (_test, clk) = setup(0);
    let cd = rate_limiter::new_cooldown(1, 50, 1, 0, &clk);
    cd.window_ms();
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun cooldown_ms_on_non_cooldown_aborts() {
    let (_test, clk) = setup(0);
    let fw = rate_limiter::new_fixed_window(5, 100, 0, 5, &clk);
    fw.cooldown_ms();
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun cooldown_end_ms_on_non_cooldown_aborts() {
    let (_test, clk) = setup(0);
    let b = rate_limiter::new_bucket(10, 1, 10, 10, clk.timestamp_ms(), &clk);
    b.cooldown_end_ms();
    abort
}

// === Construction-time anchor boundaries ===

#[test]
fun bucket_with_past_anchor_credits_elapsed_time_on_first_read() {
    // `last_refill_ms < now` is accepted: elapsed intervals since the past anchor are
    // credited the next time accrual is projected, with `initial_available` as the
    // starting balance.
    let (test, clk) = setup(100);

    // Anchor 50 ms in the past, empty start, 1 token / 10 ms. 5 intervals already elapsed.
    let rl = rate_limiter::new_bucket(10, 1, 10, 0, 50, &clk);
    // Projected anchor advances by the 5 elapsed intervals: 50 + 5*10 = 100.
    assert_eq!(rl.last_refill_ms(&clk), 100);
    assert_eq!(rl.available(&clk), 5);

    teardown(test, clk);
}

#[test]
fun cooldown_accepts_gate_at_exact_now_with_tokens() {
    // The constructor's gate-with-tokens check is `cooldown_end_ms <= now`, so
    // `cooldown_end_ms == now` with `initial_available > 0` is the inclusive boundary
    // and must be accepted.
    let (test, clk) = setup(100);
    let rl = rate_limiter::new_cooldown(5, 50, 3, 100, &clk);
    assert_eq!(rl.available(&clk), 3);
    teardown(test, clk);
}

// === Reconfigure via construct-fresh ===
//
// With reconfigure removed, callers express any policy by reading state via the getters,
// computing the desired fields, and overwriting the field with a freshly constructed
// limiter. These tests pin down the two most common patterns.

#[test]
fun reconfigure_bucket_via_construct_fresh_project_and_reanchor() {
    let (test, mut clk) = setup(0);

    // Old rate: 10 tokens / 10 ms, starts empty.
    let mut rl = rate_limiter::new_bucket(100, 10, 10, 0, clk.timestamp_ms(), &clk);

    // 50 ms in, want to switch to capacity=200 with the same projected balance, anchored
    // at now. `available(clock)` projects the 50 tokens accrued under the old rate; we
    // pass that as the new `initial_available` and reconstruct.
    clk.set_for_testing(50);
    let projected = rl.available(&clk);
    rl = rate_limiter::new_bucket(200, 100, 1, projected, clk.timestamp_ms(), &clk);

    // Same balance as before, no retroactive new-rate credit.
    assert_eq!(rl.available(&clk), 50);

    teardown(test, clk);
}

#[test]
fun reconfigure_fixed_window_via_construct_fresh_preserve_anchor() {
    let (test, mut clk) = setup(0);

    // 5 units per 100 ms, anchored at 0.
    let mut rl = rate_limiter::new_fixed_window(5, 100, 0, 5, &clk);
    rl.consume_or_abort(2, &clk);
    assert_eq!(rl.available(&clk), 3);

    // Mid-window, shrink capacity to 4 while preserving the existing window anchor and
    // the projected `available` clamped to the new capacity.
    clk.set_for_testing(50);
    let anchor = rl.window_start_ms(&clk);
    let projected = rl.available(&clk);
    let new_cap = 4;
    let initial = if (projected < new_cap) projected else new_cap;
    rl = rate_limiter::new_fixed_window(new_cap, 100, anchor, initial, &clk);

    // Same window as before — rollover still lands at t=100.
    assert_eq!(rl.available(&clk), 3);
    clk.set_for_testing(99);
    assert_eq!(rl.available(&clk), 3);
    clk.set_for_testing(100);
    assert_eq!(rl.available(&clk), new_cap);

    teardown(test, clk);
}

#[test]
fun reconfigure_cooldown_via_construct_fresh_preserve_in_flight_gate() {
    let (test, mut clk) = setup(0);

    // Capacity 3, cooldown 50, fully available.
    let mut rl = rate_limiter::new_cooldown(3, 50, 3, 0, &clk);
    assert!(rl.try_consume(3, &clk)); // arms gate at cooldown_end_ms = 50

    // Mid-throttle: keep the in-flight deadline, just change cooldown_ms (which only
    // affects FUTURE arms). Preserve `cooldown_end_ms` via the getter so the active wait
    // runs to completion under the old schedule.
    clk.set_for_testing(20);
    let end = rl.cooldown_end_ms();
    rl = rate_limiter::new_cooldown(3, 500, 0, end, &clk);

    // Original deadline still in effect.
    clk.set_for_testing(49);
    assert_eq!(rl.available(&clk), 0);
    clk.set_for_testing(50);
    assert_eq!(rl.available(&clk), 3);

    // Next arm uses the NEW cooldown_ms = 500.
    assert!(rl.try_consume(3, &clk));
    assert_eq!(rl.cooldown_end_ms(), 550);

    teardown(test, clk);
}

// INV-A1 (fail-closed under clock regression) is intentionally not tested here: the only
// way to set the test clock is `clock::set_for_testing`, which itself asserts
// `timestamp_ms >= current`, refusing to move the clock backward. The regression scenario
// the invariant guards against (a non-monotonic clock underflowing `now - anchor`) is
// therefore unreachable through the test framework, mirroring the real `Clock`'s
// monotonicity guarantee. The fail-closed posture rests on Move's native u64 underflow
// abort, which cannot be exercised without violating that guarantee.

// === Fail-closed on cooldown deadline overflow (INV-A3) ===
//
// Arming the gate computes `cooldown_end_ms = now + cooldown_ms`. A `cooldown_ms` near
// `u64::MAX` overflows this addition at any nonzero clock. The module enforces only
// positivity on `cooldown_ms` (INV-R3) and trusts the operator to pick a policy-reasonable
// value; overflow is fail-closed (abort), never a wrapped backward deadline. The arming
// site guards it explicitly, so the abort carries the named `ECooldownDeadlineOverflow`
// code rather than a generic arithmetic error.

#[test, expected_failure(abort_code = rate_limiter::ECooldownDeadlineOverflow)]
fun cooldown_arming_aborts_on_deadline_overflow() {
    // cooldown_ms = u64::MAX, clock at 1. Draining `available` to 0 arms the gate and
    // computes `1 + u64::MAX`, which overflows.
    let (_test, clk) = setup(1);
    let mut rl = rate_limiter::new_cooldown(5, std::u64::max_value!(), 5, 0, &clk);
    rl.try_consume(5, &clk);
    abort
}

// === PTB composability (INV-C2) ===
//
// Multiple consumes within a single PTB compose identically to the same calls split across
// separate PTBs, modulo the shared clock reading: there is no transaction-scoped accumulator
// and no PTB-local hidden accounting. Equivalently, at a fixed `now`, splitting a total
// consume into several calls yields the same committed state as one call for the sum.

#[test]
fun consumes_at_one_timestamp_have_no_txn_scoped_accumulator() {
    let (test, clk) = setup(0);

    // Two identical buckets; long refill interval keeps accrual out of the picture.
    let mut split = rate_limiter::new_bucket(10, 1, 1_000_000, 10, clk.timestamp_ms(), &clk);
    let mut whole = rate_limiter::new_bucket(10, 1, 1_000_000, 10, clk.timestamp_ms(), &clk);

    // `split` drains 6 via three calls at the same `now`; `whole` drains 6 in one call.
    assert!(split.try_consume(1, &clk));
    assert!(split.try_consume(2, &clk));
    assert!(split.try_consume(3, &clk));
    assert!(whole.try_consume(6, &clk));

    // Identical committed state — the per-call decomposition leaves no residue.
    assert_eq!(split.available(&clk), whole.available(&clk));
    assert_eq!(split.available(&clk), 4);

    teardown(test, clk);
}

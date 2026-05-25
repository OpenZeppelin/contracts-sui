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

#[test, expected_failure(abort_code = rate_limiter::EBucketAnchorInFuture)]
fun bucket_rejects_anchor_in_future() {
    let (_test, clk) = setup(50);
    rate_limiter::new_bucket(10, 1, 10, 10, 51, &clk);
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

#[test]
fun bucket_reconfigure_clamps_tokens_to_new_capacity() {
    let (test, clk) = setup(0);

    // Bucket at full capacity 100.
    let mut rl = rate_limiter::new_bucket(100, 10, 10, 100, clk.timestamp_ms(), &clk);
    assert_eq!(rl.available(&clk), 100);

    // Shrink capacity to 40; stored tokens must be clamped down.
    rl.reconfigure_bucket(40, 10, 10, rate_limiter::bucket_policy_project_and_reanchor(), &clk);
    assert_eq!(rl.available(&clk), 40);

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
    // as if the gate had already released: `available` projects to capacity.
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

#[test, expected_failure(abort_code = rate_limiter::EInvalidAmount)]
fun try_consume_with_zero_amount_aborts() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_bucket(10, 1, 10, 10, clk.timestamp_ms(), &clk);
    rl.try_consume(0, &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EInvalidAmount)]
fun try_consume_with_zero_amount_aborts_fixed_window() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_fixed_window(10, 100, 0, 10, &clk);
    rl.try_consume(0, &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EInvalidAmount)]
fun try_consume_with_zero_amount_aborts_cooldown() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_cooldown(10, 50, 10, 0, &clk);
    rl.try_consume(0, &clk);
    abort
}

// === Reconfigure variant guards ===

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun reconfigure_bucket_on_non_bucket_aborts() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_cooldown(1, 50, 1, 0, &clk);
    rl.reconfigure_bucket(10, 1, 10, rate_limiter::bucket_policy_project_and_reanchor(), &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun reconfigure_fixed_window_on_non_fixed_window_aborts() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_bucket(10, 1, 10, 10, clk.timestamp_ms(), &clk);
    rl.reconfigure_fixed_window(
        5,
        100,
        rate_limiter::fixed_window_policy_project_and_reanchor(),
        &clk,
    );
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun reconfigure_cooldown_on_non_cooldown_aborts() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_bucket(10, 1, 10, 10, clk.timestamp_ms(), &clk);
    rl.reconfigure_cooldown(1, 50, rate_limiter::cooldown_policy_project_and_reanchor(), &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun reconfigure_bucket_priority_variant_over_invalid_config() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_cooldown(1, 50, 1, 0, &clk);
    // All-zero config would trip a config-validation error if the variant arm matched, but
    // the limiter is Cooldown, so EWrongVariant must fire first.
    rl.reconfigure_bucket(0, 0, 0, rate_limiter::bucket_policy_project_and_reanchor(), &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun reconfigure_fixed_window_priority_variant_over_invalid_config() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_cooldown(1, 50, 1, 0, &clk);
    rl.reconfigure_fixed_window(
        0,
        0,
        rate_limiter::fixed_window_policy_project_and_reanchor(),
        &clk,
    );
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun reconfigure_cooldown_priority_variant_over_invalid_config() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_bucket(10, 1, 10, 10, clk.timestamp_ms(), &clk);
    rl.reconfigure_cooldown(0, 0, rate_limiter::cooldown_policy_project_and_reanchor(), &clk);
    abort
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

// === Reconfigure config validation ===

#[test, expected_failure(abort_code = rate_limiter::EZeroCapacity)]
fun reconfigure_bucket_rejects_zero_capacity() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_bucket(10, 1, 10, 10, clk.timestamp_ms(), &clk);
    rl.reconfigure_bucket(0, 1, 1, rate_limiter::bucket_policy_project_and_reanchor(), &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EZeroWindow)]
fun reconfigure_fixed_window_rejects_zero_window_ms() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_fixed_window(10, 100, 0, 10, &clk);
    rl.reconfigure_fixed_window(
        10,
        0,
        rate_limiter::fixed_window_policy_project_and_reanchor(),
        &clk,
    );
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EZeroCooldown)]
fun reconfigure_cooldown_rejects_zero_cooldown_ms() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_cooldown(1, 50, 1, 0, &clk);
    rl.reconfigure_cooldown(1, 0, rate_limiter::cooldown_policy_project_and_reanchor(), &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EZeroRefillAmount)]
fun reconfigure_bucket_rejects_zero_refill_amount() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_bucket(10, 1, 10, 10, clk.timestamp_ms(), &clk);
    rl.reconfigure_bucket(10, 0, 10, rate_limiter::bucket_policy_project_and_reanchor(), &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EZeroRefillInterval)]
fun reconfigure_bucket_rejects_zero_refill_interval_ms() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_bucket(10, 1, 10, 10, clk.timestamp_ms(), &clk);
    rl.reconfigure_bucket(10, 1, 0, rate_limiter::bucket_policy_project_and_reanchor(), &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EZeroCapacity)]
fun reconfigure_fixed_window_rejects_zero_capacity() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_fixed_window(10, 100, 0, 10, &clk);
    rl.reconfigure_fixed_window(
        0,
        100,
        rate_limiter::fixed_window_policy_project_and_reanchor(),
        &clk,
    );
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EZeroCapacity)]
fun reconfigure_cooldown_rejects_zero_capacity() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_cooldown(1, 50, 1, 0, &clk);
    rl.reconfigure_cooldown(0, 50, rate_limiter::cooldown_policy_project_and_reanchor(), &clk);
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

// === Reconfigure under old rules first ===

#[test]
fun bucket_reconfigure_accrues_under_old_rate_first() {
    let (test, mut clk) = setup(0);

    // Old rate: 10 tokens / 10 ms, starting empty.
    let mut rl = rate_limiter::new_bucket(100, 10, 10, 0, clk.timestamp_ms(), &clk);

    // 50 ms elapsed → under OLD rate, 5 steps × 10 = 50 tokens accrued.
    clk.set_for_testing(50);
    rl.reconfigure_bucket(200, 100, 1, rate_limiter::bucket_policy_project_and_reanchor(), &clk);

    // OLD rate must be applied to the prior 50 ms; 50 tokens - not the 200 we'd see
    // if the new rate (50 ms × 100/1 ms = 5000, capped at new cap 200) were applied
    // retroactively.
    assert_eq!(rl.available(&clk), 50);

    teardown(test, clk);
}

#[test]
fun fixed_window_reconfigure_rolls_under_old_window_first() {
    let (test, mut clk) = setup(0);

    let mut rl = rate_limiter::new_fixed_window(10, 100, 0, 10, &clk);
    rl.consume_or_abort(7, &clk);

    // 150 ms in → one full OLD window (100 ms) has elapsed. Reconfigure must roll
    // forward under the OLD `window_ms` first (resetting `used`) before installing
    // the new config.
    clk.set_for_testing(150);
    rl.reconfigure_fixed_window(
        20,
        300,
        rate_limiter::fixed_window_policy_project_and_reanchor(),
        &clk,
    );

    // Without the OLD-window rollover, `used` would still be 7 (clamped to new cap 20),
    // making available = 13. With it, used = 0 and available = 20.
    assert_eq!(rl.available(&clk), 20);

    teardown(test, clk);
}

// === Cooldown reconfigure resets in-flight deadline ===

#[test]
fun cooldown_reconfigure_resets_in_flight_deadline() {
    let (test, mut clk) = setup(0);

    let mut rl = rate_limiter::new_cooldown(1, 50, 1, 0, &clk);
    assert!(rl.try_consume(1, &clk)); // cooldown_end_ms = 50, available = 0

    // Reconfigure mid-cooldown with a longer cooldown. The in-flight deadline does NOT
    // carry over; `cooldown_end_ms` is reset to `now + new_cooldown_ms = 20 + 100 = 120`.
    clk.set_for_testing(20);
    rl.reconfigure_cooldown(1, 100, rate_limiter::cooldown_policy_project_and_reanchor(), &clk);

    // Past the OLD deadline of 50: still gated under the new schedule.
    clk.set_for_testing(50);
    assert_eq!(rl.available(&clk), 0);

    // Just before the new deadline: still gated.
    clk.set_for_testing(119);
    assert_eq!(rl.available(&clk), 0);

    // At the new deadline: gate releases.
    clk.set_for_testing(120);
    assert_eq!(rl.available(&clk), 1);
    assert!(rl.try_consume(1, &clk)); // arms a fresh gate with NEW cooldown_ms=100

    // The fresh gate uses the new cooldown: 120 + 100 = 220.
    clk.set_for_testing(219);
    assert_eq!(rl.available(&clk), 0);
    clk.set_for_testing(220);
    assert_eq!(rl.available(&clk), 1);

    teardown(test, clk);
}

// === Reconfigure resets the variant's timing anchor to now ===

#[test]
fun bucket_reconfigure_resets_refill_anchor() {
    let (test, mut clk) = setup(0);

    // Refill 10 tokens every 10 ms, starting empty.
    let mut rl = rate_limiter::new_bucket(100, 10, 10, 0, clk.timestamp_ms(), &clk);

    // 5 ms in - no whole step has elapsed, so accrual under the old rules credits 0.
    // Reconfigure with the same config: under the new logic, `last_refill_ms` is reset
    // to `now = 5`, discarding the 5 ms of sub-interval remainder.
    clk.set_for_testing(5);
    rl.reconfigure_bucket(100, 10, 10, rate_limiter::bucket_policy_project_and_reanchor(), &clk);
    assert_eq!(rl.available(&clk), 0);

    // 10 ms after the reconfigure call - exactly one step under the new anchor. If the
    // remainder had been preserved (last_refill_ms = 0), we'd already be at t=10 = one
    // full step from 0 here at t=10, but instead the next step lands at t=15.
    clk.set_for_testing(10);
    assert_eq!(rl.available(&clk), 0);

    clk.set_for_testing(15);
    assert_eq!(rl.available(&clk), 10);

    teardown(test, clk);
}

#[test]
fun bucket_reconfigure_to_faster_rate_discards_old_subinterval() {
    let (test, mut clk) = setup(0);

    // Old config: 1 token per 1_000 ms, capacity 1_000, starts empty.
    let mut rl = rate_limiter::new_bucket(1_000, 1, 1_000, 0, clk.timestamp_ms(), &clk);

    // 1 ms before the first OLD step would have fired. No accrual under old rules.
    // Reconfigure to a much faster refill (1 token per 10 ms). Sub-interval (999 ms
    // of the old 1_000-ms step) is discarded: the new anchor is `now = 999`.
    clk.set_for_testing(999);
    rl.reconfigure_bucket(1_000, 1, 10, rate_limiter::bucket_policy_project_and_reanchor(), &clk);

    // 1 ms after the reconfigure call - only 1 ms under the new 10-ms interval, so no
    // step has fired and no token has been credited. If the old sub-interval had been
    // preserved (last_refill_ms still at 0), the new rate would have retroactively
    // credited (1_000 - 0) / 10 = 100 tokens.
    clk.set_for_testing(1_000);
    assert_eq!(rl.available(&clk), 0);
    assert!(!rl.try_consume(1, &clk));

    // First credit under the new schedule lands at `now + 10 = 1_009`.
    clk.set_for_testing(1_009);
    assert_eq!(rl.available(&clk), 1);

    teardown(test, clk);
}

#[test]
fun fixed_window_reconfigure_resets_window_anchor() {
    let (test, mut clk) = setup(0);

    // 10 units per 100 ms window.
    let mut rl = rate_limiter::new_fixed_window(10, 100, 0, 10, &clk);
    rl.consume_or_abort(5, &clk);
    assert_eq!(rl.available(&clk), 5);

    // 50 ms in - still inside the first window under the old rules (no rollover). The
    // remaining `available` (5) is clamped to the new capacity (10), so it carries over.
    // The new anchor is `now = 50`, so the next window begins at t=150.
    clk.set_for_testing(50);
    rl.reconfigure_fixed_window(
        10,
        100,
        rate_limiter::fixed_window_policy_project_and_reanchor(),
        &clk,
    );
    assert_eq!(rl.available(&clk), 5);

    // At t=100 the OLD anchor (window_start=0) would have rolled to a fresh window of 10.
    // With the new anchor at 50, no rollover yet - `available` stays at 5.
    clk.set_for_testing(100);
    assert_eq!(rl.available(&clk), 5);

    clk.set_for_testing(149);
    assert_eq!(rl.available(&clk), 5);

    // 100 ms after the reconfigure call - first roll under the new anchor.
    clk.set_for_testing(150);
    assert_eq!(rl.available(&clk), 10);

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

#[test, expected_failure(abort_code = rate_limiter::EInvalidAmount)]
fun try_consume_of_available_aborts_when_drained() {
    // The `try_consume(self.available(clock), clock)` idiom is unsafe when the limiter
    // is empty: available() returns 0 and try_consume(0) aborts EInvalidAmount.
    // Callers must guard with `if n > 0 { ... }`.
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_bucket(10, 1, 1_000_000, 10, clk.timestamp_ms(), &clk);
    rl.consume_or_abort(10, &clk);
    let n = rl.available(&clk);
    rl.try_consume(n, &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EInvalidAmount)]
fun fixed_window_try_consume_of_available_aborts_when_exhausted() {
    // Same footgun as `try_consume_of_available_aborts_when_drained` but for FixedWindow:
    // available() returns 0 inside an exhausted window before rollover, and try_consume(0)
    // aborts EInvalidAmount.
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_fixed_window(5, 100, 0, 5, &clk);
    rl.consume_or_abort(5, &clk);
    let n = rl.available(&clk);
    rl.try_consume(n, &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EInvalidAmount)]
fun cooldown_try_consume_of_available_aborts_when_gated() {
    // Same footgun as `try_consume_of_available_aborts_when_drained` but for Cooldown:
    // available() returns 0 while the gate is armed (deadline not yet elapsed), and
    // try_consume(0) aborts EInvalidAmount.
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_cooldown(5, 50, 5, 0, &clk);
    rl.consume_or_abort(5, &clk); // drains and arms the gate
    let n = rl.available(&clk);
    rl.try_consume(n, &clk);
    abort
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

// === Cooldown reconfigure clamps `used` ===

#[test]
fun cooldown_reconfigure_clamps_available_to_new_capacity() {
    let (test, clk) = setup(0);

    let mut rl = rate_limiter::new_cooldown(10, 100, 10, 0, &clk);
    rl.consume_or_abort(1, &clk);
    assert_eq!(rl.available(&clk), 9);

    // Shrink capacity below current `available`; clamp keeps `available <= capacity`.
    rl.reconfigure_cooldown(5, 100, rate_limiter::cooldown_policy_project_and_reanchor(), &clk);
    assert_eq!(rl.available(&clk), 5);

    teardown(test, clk);
}

#[test]
fun cooldown_reconfigure_capacity_increase_preserves_available() {
    // When post-clamp `available > 0` (here: `available=3` clamped against `new_cap=10`
    // is a no-op), `cooldown_end_ms` is left untouched. The new `cooldown_ms` only
    // becomes observable when the next drain arms a fresh gate.
    let (test, mut clk) = setup(0);

    let mut rl = rate_limiter::new_cooldown(5, 50, 3, 0, &clk);
    assert_eq!(rl.available(&clk), 3);

    // Increase capacity (3 <= 10 => min-clamp is a no-op). cooldown_ms also bumped.
    rl.reconfigure_cooldown(10, 100, rate_limiter::cooldown_policy_project_and_reanchor(), &clk);
    assert_eq!(rl.available(&clk), 3);

    // Drain the current batch; gate arms under the NEW cooldown_ms (deadline = 0 + 100).
    rl.consume_or_abort(3, &clk);
    assert_eq!(rl.available(&clk), 0);

    // Just before the new deadline: still gated.
    clk.set_for_testing(99);
    assert!(!rl.try_consume(1, &clk));

    // At the new deadline: fresh batch under the new capacity.
    clk.set_for_testing(100);
    assert_eq!(rl.available(&clk), 10);

    teardown(test, clk);
}

#[test]
fun cooldown_reconfigure_realizes_released_gate_without_rearming() {
    // When `available == 0` but the prior `cooldown_end_ms` has already elapsed, the gate
    // is no longer in flight. Reconfigure must project the release forward under the old
    // config (resetting `available` to the old capacity) instead of treating stale
    // `available == 0` as a still-armed gate and starting a fresh wait.
    let (test, mut clk) = setup(0);

    let mut rl = rate_limiter::new_cooldown(3, 50, 3, 0, &clk);
    assert!(rl.try_consume(3, &clk)); // cooldown_end_ms = 50, available = 0

    // Let the original cooldown elapse naturally without consuming.
    clk.set_for_testing(60);
    assert_eq!(rl.available(&clk), 3); // gate has released

    // Reconfigure now: stored available is 0, but the prior deadline (50) has passed,
    // so projection realizes the release and `available` becomes the old capacity (3),
    // then clamps to the new capacity (5).
    rl.reconfigure_cooldown(5, 100, rate_limiter::cooldown_policy_project_and_reanchor(), &clk);
    assert_eq!(rl.available(&clk), 3);

    // No fresh gate was armed: the next consume must succeed immediately.
    assert!(rl.try_consume(3, &clk));

    teardown(test, clk);
}

#[test]
fun cooldown_failed_try_consume_does_not_skew_reconfigure() {
    // A failed `try_consume` between drain and reconfigure must produce the same persisted
    // state as no probe at all - try_consume failure is observably a no-op, even across a
    // subsequent reconfigure that inspects the gate state.
    let (test, mut clk) = setup(0);

    let mut rl_probed = rate_limiter::new_cooldown(10, 100, 10, 0, &clk);
    let mut rl_unprobed = rate_limiter::new_cooldown(10, 100, 10, 0, &clk);

    // Both drain at t=10 → available=0, cooldown_end_ms=110.
    clk.set_for_testing(10);
    rl_probed.consume_or_abort(10, &clk);
    rl_unprobed.consume_or_abort(10, &clk);

    // Only `rl_probed` is hit with an oversized request after the gate releases.
    clk.set_for_testing(200);
    assert!(!rl_probed.try_consume(15, &clk));

    // Both reconfigure under a longer cooldown.
    clk.set_for_testing(201);
    rl_probed.reconfigure_cooldown(
        10,
        500,
        rate_limiter::cooldown_policy_project_and_reanchor(),
        &clk,
    );
    rl_unprobed.reconfigure_cooldown(
        10,
        500,
        rate_limiter::cooldown_policy_project_and_reanchor(),
        &clk,
    );

    // Both paths must agree: the prior gate had released, so `available` is realized to
    // the old capacity and no fresh gate is armed under the new cooldown.
    assert_eq!(rl_probed.available(&clk), 10);
    assert_eq!(rl_unprobed.available(&clk), 10);

    // Both must spend immediately without waiting on a re-armed deadline.
    assert!(rl_probed.try_consume(10, &clk));
    assert!(rl_unprobed.try_consume(10, &clk));

    teardown(test, clk);
}

// === FixedWindow reconfigure clamps `used` ===

#[test]
fun fixed_window_reconfigure_clamps_available_to_new_capacity() {
    let (test, clk) = setup(0);

    let mut rl = rate_limiter::new_fixed_window(10, 100, 0, 10, &clk);
    rl.consume_or_abort(2, &clk);
    assert_eq!(rl.available(&clk), 8);

    // Shrinking capacity below current `available` must clamp `available` down.
    rl.reconfigure_fixed_window(
        5,
        100,
        rate_limiter::fixed_window_policy_project_and_reanchor(),
        &clk,
    );
    assert_eq!(rl.available(&clk), 5);

    teardown(test, clk);
}

#[test]
fun fixed_window_failed_try_consume_does_not_skew_reconfigure() {
    // A failed `try_consume` that crosses a window boundary must produce the same
    // persisted state as no probe at all - try_consume failure is observably a no-op,
    // even across a subsequent reconfigure that inspects the window anchor.
    let (test, mut clk) = setup(0);

    let mut rl_probed = rate_limiter::new_fixed_window(5, 100, 0, 5, &clk);
    let mut rl_unprobed = rate_limiter::new_fixed_window(5, 100, 0, 5, &clk);

    // Both consume 3 at t=10 → available=2, window_start_ms=0.
    clk.set_for_testing(10);
    rl_probed.consume_or_abort(3, &clk);
    rl_unprobed.consume_or_abort(3, &clk);

    // Only `rl_probed` is hit with an oversized request after the window crosses.
    clk.set_for_testing(100);
    assert!(!rl_probed.try_consume(6, &clk));

    // Both reconfigure under the same new config.
    clk.set_for_testing(150);
    rl_probed.reconfigure_fixed_window(
        10,
        100,
        rate_limiter::fixed_window_policy_project_and_reanchor(),
        &clk,
    );
    rl_unprobed.reconfigure_fixed_window(
        10,
        100,
        rate_limiter::fixed_window_policy_project_and_reanchor(),
        &clk,
    );

    // Both paths must agree: the prior window had crossed under the old window_ms,
    // so available is realized to the new capacity (fresh window).
    assert_eq!(rl_probed.available(&clk), 10);
    assert_eq!(rl_unprobed.available(&clk), 10);

    teardown(test, clk);
}

// === Reconfigure policy variants ===

// --- Bucket policies ---

#[test]
fun bucket_install_only_preserves_anchor() {
    let (test, mut clk) = setup(0);

    // Empty bucket, 1 token / 10 ms. At t=5, install a much faster refill (1 / 1 ms)
    // without touching the anchor. The OLD anchor at t=0 is still in effect, so the new
    // schedule retroactively credits 5 steps × 1 token on the next available() projection.
    let mut rl = rate_limiter::new_bucket(10, 1, 10, 0, clk.timestamp_ms(), &clk);
    clk.set_for_testing(5);
    rl.reconfigure_bucket(10, 1, 1, rate_limiter::bucket_policy_install_only(), &clk);

    // Stale anchor + new schedule: 5 / 1 = 5 steps credited under the new config.
    assert_eq!(rl.available(&clk), 5);

    teardown(test, clk);
}

#[test]
fun bucket_reset_clears_state_and_anchors_now() {
    let (test, mut clk) = setup(0);

    let mut rl = rate_limiter::new_bucket(10, 1, 10, 0, clk.timestamp_ms(), &clk);
    clk.set_for_testing(5);
    rl.reconfigure_bucket(20, 5, 100, rate_limiter::bucket_policy_reset(), &clk);

    // Reset fills `available` to new capacity and anchors the refill counter at `now`.
    assert_eq!(rl.available(&clk), 20);

    // Anchor at 5; first tick under the new schedule lands at 5 + 100 = 105.
    rl.consume_or_abort(20, &clk);
    clk.set_for_testing(104);
    assert_eq!(rl.available(&clk), 0);
    clk.set_for_testing(105);
    assert_eq!(rl.available(&clk), 5);

    teardown(test, clk);
}

#[test]
fun bucket_preserve_phase_keeps_old_anchor_phase() {
    let (test, mut clk) = setup(0);

    // 1 token / 10 ms, starts empty. 5 ms in, reconfigure with the SAME config under
    // PreservePhase. ProjectAndReanchor would push the next tick to t=15. PreservePhase
    // keeps the floor-aligned anchor at 0, so the next tick still lands at t=10.
    let mut rl = rate_limiter::new_bucket(10, 1, 10, 0, clk.timestamp_ms(), &clk);
    clk.set_for_testing(5);
    rl.reconfigure_bucket(10, 1, 10, rate_limiter::bucket_policy_preserve_phase(), &clk);

    clk.set_for_testing(9);
    assert_eq!(rl.available(&clk), 0);
    clk.set_for_testing(10);
    assert_eq!(rl.available(&clk), 1);

    teardown(test, clk);
}

#[test]
fun bucket_proportional_scales_sub_interval_phase() {
    let (test, mut clk) = setup(1000);

    // 1 token / 100 ms, starts empty. Anchor at 1000. 50 ms in, 50% through the first
    // interval. Reconfigure interval to 200 ms under Proportional: back-date the anchor
    // so we're still 50% through under the new schedule.
    //   elapsed_new = 50 * 200 / 100 = 100
    //   last_refill_ms = 1050 - 100 = 950
    //   next tick at 950 + 200 = 1150.
    let mut rl = rate_limiter::new_bucket(10, 1, 100, 0, clk.timestamp_ms(), &clk);
    clk.set_for_testing(1050);
    rl.reconfigure_bucket(10, 1, 200, rate_limiter::bucket_policy_proportional(), &clk);

    clk.set_for_testing(1149);
    assert_eq!(rl.available(&clk), 0);
    clk.set_for_testing(1150);
    assert_eq!(rl.available(&clk), 1);

    teardown(test, clk);
}

// --- FixedWindow policies ---

#[test]
fun fixed_window_install_only_preserves_anchor() {
    let (test, mut clk) = setup(0);

    // Capacity 10 per 100 ms window. Consume 5, then at t=50 install a 50 ms window
    // without re-anchoring. Old anchor at 0 + new window=50: one full step has elapsed,
    // so available() projects a rollover to the new capacity.
    let mut rl = rate_limiter::new_fixed_window(10, 100, 0, 10, &clk);
    rl.consume_or_abort(5, &clk);
    clk.set_for_testing(50);
    rl.reconfigure_fixed_window(10, 50, rate_limiter::fixed_window_policy_install_only(), &clk);

    assert_eq!(rl.available(&clk), 10);

    teardown(test, clk);
}

#[test]
fun fixed_window_reset_clears_anchor() {
    let (test, mut clk) = setup(0);

    let mut rl = rate_limiter::new_fixed_window(10, 100, 0, 10, &clk);
    rl.consume_or_abort(7, &clk);
    clk.set_for_testing(50);
    rl.reconfigure_fixed_window(20, 100, rate_limiter::fixed_window_policy_reset(), &clk);

    // Fresh state under new capacity; anchor at 50, next rollover at 150.
    assert_eq!(rl.available(&clk), 20);
    rl.consume_or_abort(20, &clk);
    clk.set_for_testing(149);
    assert_eq!(rl.available(&clk), 0);
    clk.set_for_testing(150);
    assert_eq!(rl.available(&clk), 20);

    teardown(test, clk);
}

#[test]
fun fixed_window_proportional_scales_phase_to_new_window() {
    let (test, mut clk) = setup(1000);

    // 10 units / 100 ms window. Consume 5; at t=1050 (50% through) reconfigure to a
    // 200 ms window under Proportional.
    //   elapsed_new = 50 * 200 / 100 = 100
    //   window_start_ms = 1050 - 100 = 950
    //   next rollover at 950 + 200 = 1150.
    let mut rl = rate_limiter::new_fixed_window(10, 100, 1000, 10, &clk);
    rl.consume_or_abort(5, &clk);
    clk.set_for_testing(1050);
    rl.reconfigure_fixed_window(
        10,
        200,
        rate_limiter::fixed_window_policy_proportional(),
        &clk,
    );

    // Same fraction remaining; clamp leaves available at 5.
    assert_eq!(rl.available(&clk), 5);
    clk.set_for_testing(1149);
    assert_eq!(rl.available(&clk), 5);
    clk.set_for_testing(1150);
    assert_eq!(rl.available(&clk), 10);

    teardown(test, clk);
}

// --- Cooldown policies ---

#[test]
fun cooldown_install_only_preserves_in_flight_deadline() {
    let (test, mut clk) = setup(0);

    // Drain to arm the gate at deadline=50.
    let mut rl = rate_limiter::new_cooldown(1, 50, 1, 0, &clk);
    assert!(rl.try_consume(1, &clk));

    // InstallOnly updates cooldown_ms to 200 but leaves the active deadline at 50.
    clk.set_for_testing(20);
    rl.reconfigure_cooldown(1, 200, rate_limiter::cooldown_policy_install_only(), &clk);

    // Active wait uses the old deadline.
    clk.set_for_testing(49);
    assert_eq!(rl.available(&clk), 0);
    clk.set_for_testing(50);
    assert_eq!(rl.available(&clk), 1);

    // Next arm uses the new cooldown_ms = 200.
    assert!(rl.try_consume(1, &clk));
    clk.set_for_testing(249);
    assert_eq!(rl.available(&clk), 0);
    clk.set_for_testing(250);
    assert_eq!(rl.available(&clk), 1);

    teardown(test, clk);
}

#[test]
fun cooldown_reset_clears_active_gate() {
    let (test, mut clk) = setup(0);

    let mut rl = rate_limiter::new_cooldown(2, 50, 2, 0, &clk);
    assert!(rl.try_consume(2, &clk)); // gate armed, deadline = 50

    clk.set_for_testing(20);
    rl.reconfigure_cooldown(5, 100, rate_limiter::cooldown_policy_reset(), &clk);

    // Reset wipes the gate and the available counter is replenished to new capacity.
    assert_eq!(rl.available(&clk), 5);

    teardown(test, clk);
}

#[test]
fun cooldown_preserve_active_gate_locks_in_old_deadline() {
    let (test, mut clk) = setup(0);

    let mut rl = rate_limiter::new_cooldown(1, 50, 1, 0, &clk);
    assert!(rl.try_consume(1, &clk)); // deadline = 50

    // Even a much longer new cooldown does not extend the active wait.
    clk.set_for_testing(20);
    rl.reconfigure_cooldown(
        1,
        1000,
        rate_limiter::cooldown_policy_preserve_active_gate(),
        &clk,
    );

    clk.set_for_testing(49);
    assert_eq!(rl.available(&clk), 0);
    clk.set_for_testing(50);
    assert_eq!(rl.available(&clk), 1);
    assert!(rl.try_consume(1, &clk));

    // Future arms pick up the new cooldown_ms = 1000.
    clk.set_for_testing(1049);
    assert_eq!(rl.available(&clk), 0);
    clk.set_for_testing(1050);
    assert_eq!(rl.available(&clk), 1);

    teardown(test, clk);
}

#[test]
fun cooldown_rebase_active_gate_recomputes_deadline_under_new_cooldown() {
    let (test, mut clk) = setup(0);

    let mut rl = rate_limiter::new_cooldown(1, 50, 1, 0, &clk);
    assert!(rl.try_consume(1, &clk)); // arm_time = 0, deadline = 50

    // Rebased deadline = arm_time + new_cooldown_ms = 0 + 200 = 200.
    clk.set_for_testing(20);
    rl.reconfigure_cooldown(1, 200, rate_limiter::cooldown_policy_rebase_active_gate(), &clk);

    clk.set_for_testing(199);
    assert_eq!(rl.available(&clk), 0);
    clk.set_for_testing(200);
    assert_eq!(rl.available(&clk), 1);

    teardown(test, clk);
}

#[test]
fun cooldown_rebase_active_gate_no_extend_clamps_to_old_deadline_on_grow() {
    let (test, mut clk) = setup(0);

    let mut rl = rate_limiter::new_cooldown(1, 50, 1, 0, &clk);
    assert!(rl.try_consume(1, &clk)); // deadline = 50

    // Grow cooldown to 200: rebased would be 200, clamped to old (50). No extension.
    clk.set_for_testing(20);
    rl.reconfigure_cooldown(
        1,
        200,
        rate_limiter::cooldown_policy_rebase_active_gate_no_extend(),
        &clk,
    );

    clk.set_for_testing(49);
    assert_eq!(rl.available(&clk), 0);
    clk.set_for_testing(50);
    assert_eq!(rl.available(&clk), 1);

    teardown(test, clk);
}

#[test]
fun cooldown_rebase_active_gate_no_extend_shortens_on_shrink() {
    let (test, mut clk) = setup(0);

    let mut rl = rate_limiter::new_cooldown(1, 1000, 1, 0, &clk);
    assert!(rl.try_consume(1, &clk)); // deadline = 1000

    // Shrink cooldown to 500: rebased = 500 < old (1000), so the new deadline applies.
    clk.set_for_testing(100);
    rl.reconfigure_cooldown(
        1,
        500,
        rate_limiter::cooldown_policy_rebase_active_gate_no_extend(),
        &clk,
    );

    clk.set_for_testing(499);
    assert_eq!(rl.available(&clk), 0);
    clk.set_for_testing(500);
    assert_eq!(rl.available(&clk), 1);

    teardown(test, clk);
}

#[test]
fun cooldown_proportional_scales_remaining_wait() {
    let (test, mut clk) = setup(0);

    let mut rl = rate_limiter::new_cooldown(1, 100, 1, 0, &clk);
    assert!(rl.try_consume(1, &clk)); // deadline = 100

    // 50% through (t=50). Reconfigure to cd=200.
    // time_left_new = 50 * 200 / 100 = 100 ⇒ new deadline = 50 + 100 = 150.
    clk.set_for_testing(50);
    rl.reconfigure_cooldown(1, 200, rate_limiter::cooldown_policy_proportional(), &clk);

    clk.set_for_testing(149);
    assert_eq!(rl.available(&clk), 0);
    clk.set_for_testing(150);
    assert_eq!(rl.available(&clk), 1);

    teardown(test, clk);
}

// === Getters ===

#[test]
fun getters_return_constructor_values() {
    let (test, clk) = setup(0);

    let b = rate_limiter::new_bucket(30, 5, 10, 30, clk.timestamp_ms(), &clk);
    assert_eq!(b.capacity(), 30);
    assert_eq!(b.refill_amount(), 5);
    assert_eq!(b.refill_interval_ms(), 10);
    assert_eq!(b.last_refill_ms(), clk.timestamp_ms());

    let fw = rate_limiter::new_fixed_window(7, 100, 0, 7, &clk);
    assert_eq!(fw.capacity(), 7);
    assert_eq!(fw.window_ms(), 100);
    assert_eq!(fw.window_start_ms(), 0);

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

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun refill_amount_on_non_bucket_aborts() {
    let (_test, clk) = setup(0);
    let cd = rate_limiter::new_cooldown(1, 50, 1, 0, &clk);
    cd.refill_amount();
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun window_start_ms_on_non_fixed_window_aborts() {
    let (_test, clk) = setup(0);
    let b = rate_limiter::new_bucket(10, 1, 10, 10, clk.timestamp_ms(), &clk);
    b.window_start_ms();
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun cooldown_end_ms_on_non_cooldown_aborts() {
    let (_test, clk) = setup(0);
    let b = rate_limiter::new_bucket(10, 1, 10, 10, clk.timestamp_ms(), &clk);
    b.cooldown_end_ms();
    abort
}

// === Reconfigure via construct-fresh path ===
//
// The rich constructors + getters let integrators express any carry-over semantics by
// reading current state, computing the desired field values, and overwriting the field
// with a freshly built limiter. These tests pin down a few representative patterns.

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
    let anchor = rl.window_start_ms();
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

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
    let mut rl = rate_limiter::new_bucket(30, 5, 10, 30, &clk);
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
    let mut rl = rate_limiter::new_bucket(10, 2, 5, 0, &clk);
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
    rate_limiter::new_bucket(10, 1, 10, 11, &clk);
    abort
}

#[test]
fun bucket_try_consume_returns_false_when_empty() {
    let (test, clk) = setup(0);

    let mut rl = rate_limiter::new_bucket(10, 1, 100, 10, &clk);
    assert!(rl.try_consume(10, &clk));
    // No refill has happened yet, so the next consume fails without aborting.
    assert!(!rl.try_consume(1, &clk));

    teardown(test, clk);
}

#[test, expected_failure(abort_code = rate_limiter::ERateLimited)]
fun bucket_consume_or_abort_aborts_when_empty() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_bucket(5, 1, 10, 5, &clk);
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

    let mut rl = rate_limiter::new_bucket(10, 1, 100, 10, &clk);
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

    let mut rl = rate_limiter::new_bucket(10, 1, 100, 8, &clk);
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
    let mut rl = rate_limiter::new_bucket(100, 10, 10, 100, &clk);
    assert_eq!(rl.available(&clk), 100);

    // Shrink capacity to 40; stored tokens must be clamped down.
    rl.reconfigure_bucket(40, 10, 10, &clk);
    assert_eq!(rl.available(&clk), 40);

    teardown(test, clk);
}

// === Fixed Window ===

#[test]
fun fixed_window_counts_per_window_and_resets_on_boundary() {
    let (test, mut clk) = setup(0);

    // 3 consumes per 100 ms window.
    let mut rl = rate_limiter::new_fixed_window(3, 100, &clk);
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
fun cooldown_requires_elapsed_time_between_consumes() {
    let (test, mut clk) = setup(100);

    // 50 ms cooldown between single-unit consumes (capacity 1 => cooldown after each).
    let mut rl = rate_limiter::new_cooldown(1, 50);
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
    let mut rl = rate_limiter::new_cooldown(5, 50);
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
    let mut rl = rate_limiter::new_cooldown(5, 50);
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
    let mut rl = rate_limiter::new_bucket(10, 1, 10, 10, &clk);
    rl.try_consume(0, &clk);
    abort
}

// === Reconfigure variant guards ===

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun reconfigure_bucket_on_non_bucket_aborts() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_cooldown(1, 50);
    rl.reconfigure_bucket(10, 1, 10, &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun reconfigure_fixed_window_on_non_fixed_window_aborts() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_bucket(10, 1, 10, 10, &clk);
    rl.reconfigure_fixed_window(5, 100, &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun reconfigure_cooldown_on_non_cooldown_aborts() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_bucket(10, 1, 10, 10, &clk);
    rl.reconfigure_cooldown(1, 50, &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun reconfigure_bucket_priority_variant_over_invalid_config() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_cooldown(1, 50);
    // All-zero config would trip a config-validation error if the variant arm matched, but
    // the limiter is Cooldown, so EWrongVariant must fire first.
    rl.reconfigure_bucket(0, 0, 0, &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun reconfigure_fixed_window_priority_variant_over_invalid_config() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_cooldown(1, 50);
    rl.reconfigure_fixed_window(0, 0, &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun reconfigure_cooldown_priority_variant_over_invalid_config() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_bucket(10, 1, 10, 10, &clk);
    rl.reconfigure_cooldown(0, 0, &clk);
    abort
}

// === Constructor config validation ===

#[test, expected_failure(abort_code = rate_limiter::EZeroCapacity)]
fun new_bucket_rejects_zero_capacity() {
    let (_test, clk) = setup(0);
    rate_limiter::new_bucket(0, 1, 1, 0, &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EZeroRefillAmount)]
fun new_bucket_rejects_zero_refill_amount() {
    let (_test, clk) = setup(0);
    rate_limiter::new_bucket(10, 0, 1, 10, &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EZeroRefillInterval)]
fun new_bucket_rejects_zero_refill_interval_ms() {
    let (_test, clk) = setup(0);
    rate_limiter::new_bucket(10, 1, 0, 10, &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EZeroCapacity)]
fun new_fixed_window_rejects_zero_capacity() {
    let (_test, clk) = setup(0);
    rate_limiter::new_fixed_window(0, 100, &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EZeroWindow)]
fun new_fixed_window_rejects_zero_window_ms() {
    let (_test, clk) = setup(0);
    rate_limiter::new_fixed_window(10, 0, &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EZeroCooldown)]
fun new_cooldown_rejects_zero_cooldown_ms() {
    rate_limiter::new_cooldown(1, 0);
}

#[test, expected_failure(abort_code = rate_limiter::EZeroCapacity)]
fun new_cooldown_rejects_zero_capacity() {
    rate_limiter::new_cooldown(0, 50);
}

// === Reconfigure config validation ===

#[test, expected_failure(abort_code = rate_limiter::EZeroCapacity)]
fun reconfigure_bucket_rejects_zero_capacity() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_bucket(10, 1, 10, 10, &clk);
    rl.reconfigure_bucket(0, 1, 1, &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EZeroWindow)]
fun reconfigure_fixed_window_rejects_zero_window_ms() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_fixed_window(10, 100, &clk);
    rl.reconfigure_fixed_window(10, 0, &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EZeroCooldown)]
fun reconfigure_cooldown_rejects_zero_cooldown_ms() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_cooldown(1, 50);
    rl.reconfigure_cooldown(1, 0, &clk);
    abort
}

// === All-or-nothing failure semantics ===

#[test]
fun bucket_failed_try_consume_does_not_drain_state() {
    let (test, clk) = setup(0);

    // Long refill interval keeps accrual out of the picture.
    let mut rl = rate_limiter::new_bucket(10, 1, 1_000_000, 10, &clk);
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

    let mut rl = rate_limiter::new_fixed_window(5, 100, &clk);
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

    let mut rl = rate_limiter::new_cooldown(1, 100);
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

// === Fractional time preservation ===

#[test]
fun bucket_preserves_subinterval_time_across_consumes() {
    let (test, mut clk) = setup(0);

    // Refill 1 token every 10 ms, starting empty.
    let mut rl = rate_limiter::new_bucket(10, 1, 10, 0, &clk);

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
    let mut rl = rate_limiter::new_bucket(100, 10, 10, 0, &clk);

    // 50 ms elapsed → under OLD rate, 5 steps × 10 = 50 tokens accrued.
    clk.set_for_testing(50);
    rl.reconfigure_bucket(200, 100, 1, &clk);

    // OLD rate must be applied to the prior 50 ms; 50 tokens - not the 200 we'd see
    // if the new rate (50 ms × 100/1 ms = 5000, capped at new cap 200) were applied
    // retroactively.
    assert_eq!(rl.available(&clk), 50);

    teardown(test, clk);
}

#[test]
fun fixed_window_reconfigure_rolls_under_old_window_first() {
    let (test, mut clk) = setup(0);

    let mut rl = rate_limiter::new_fixed_window(10, 100, &clk);
    rl.consume_or_abort(7, &clk);

    // 150 ms in → one full OLD window (100 ms) has elapsed. Reconfigure must roll
    // forward under the OLD `window_ms` first (resetting `used`) before installing
    // the new config.
    clk.set_for_testing(150);
    rl.reconfigure_fixed_window(20, 300, &clk);

    // Without the OLD-window rollover, `used` would still be 7 (clamped to new cap 20),
    // making available = 13. With it, used = 0 and available = 20.
    assert_eq!(rl.available(&clk), 20);

    teardown(test, clk);
}

// === Cooldown reconfigure preserves in-flight deadline ===

#[test]
fun cooldown_reconfigure_preserves_in_flight_deadline() {
    let (test, mut clk) = setup(0);

    let mut rl = rate_limiter::new_cooldown(1, 50);
    assert!(rl.try_consume(1, &clk)); // cooldown_end_ms = 50

    // Reconfigure with a longer cooldown while the gate is in-flight. The deadline
    // is preserved at its original value (50) - the new `cooldown_ms` does NOT
    // retroactively shift the in-flight gate. The new value applies to the *next*
    // gate armed after this one releases.
    rl.reconfigure_cooldown(1, 100, &clk);

    // Just before the original deadline: still gated.
    clk.set_for_testing(49);
    assert_eq!(rl.available(&clk), 0);

    // At the original deadline: gate releases under the OLD cooldown.
    clk.set_for_testing(50);
    assert_eq!(rl.available(&clk), 1);
    assert!(rl.try_consume(1, &clk)); // arms a fresh gate with NEW cooldown_ms=100

    // The fresh gate uses the new cooldown: 50 + 100 = 150.
    clk.set_for_testing(149);
    assert_eq!(rl.available(&clk), 0);
    clk.set_for_testing(150);
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
    let rl = rate_limiter::new_bucket(1_000_000, huge_refill, 1, 0, &clk);

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
    let rl = rate_limiter::new_bucket(cap, 1, 1, 0, &clk);

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
    let mut rl = rate_limiter::new_fixed_window(10, 100, &clk);
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
    let mut rl = rate_limiter::new_fixed_window(5, 100, &clk);
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

    let mut rl = rate_limiter::new_bucket(20, 5, 10, 20, &clk);
    let avail = rl.available(&clk);
    assert_eq!(avail, 20);
    assert!(rl.try_consume(avail, &clk));
    assert_eq!(rl.available(&clk), 0);

    teardown(test, clk);
}

#[test]
fun fixed_window_available_predicts_try_consume() {
    let (test, clk) = setup(0);

    let mut rl = rate_limiter::new_fixed_window(7, 100, &clk);
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
    let mut rl = rate_limiter::new_cooldown(7, 50);
    let avail = rl.available(&clk);
    assert_eq!(avail, 7);
    assert!(rl.try_consume(avail, &clk));
    assert_eq!(rl.available(&clk), 0);

    teardown(test, clk);
}

// === consume_or_abort across variants ===

#[test, expected_failure(abort_code = rate_limiter::ERateLimited)]
fun fixed_window_consume_or_abort_aborts_when_full() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_fixed_window(2, 100, &clk);
    rl.consume_or_abort(2, &clk);
    rl.consume_or_abort(1, &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::ERateLimited)]
fun cooldown_consume_or_abort_aborts_when_in_cooldown() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_cooldown(1, 100);
    rl.consume_or_abort(1, &clk);
    rl.consume_or_abort(1, &clk);
    abort
}

// === Cooldown reconfigure clamps `used` ===

#[test]
fun cooldown_reconfigure_clamps_available_to_new_capacity() {
    let (test, clk) = setup(0);

    let mut rl = rate_limiter::new_cooldown(10, 100);
    rl.consume_or_abort(1, &clk);
    assert_eq!(rl.available(&clk), 9);

    // Shrink capacity below current `available`; clamp keeps `available <= capacity`.
    rl.reconfigure_cooldown(5, 100, &clk);
    assert_eq!(rl.available(&clk), 5);

    teardown(test, clk);
}

#[test]
fun cooldown_reconfigure_rearms_when_drained_and_deadline_elapsed() {
    // When `available == 0` and the prior `cooldown_end_ms` has already elapsed,
    // `reconfigure_cooldown` arms a fresh deadline at `now + cooldown_ms` instead of
    // letting the next `try_consume` reset to capacity for free.
    let (test, mut clk) = setup(0);

    let mut rl = rate_limiter::new_cooldown(1, 50);
    assert!(rl.try_consume(1, &clk)); // cooldown_end_ms = 50, available = 0

    // Let the original cooldown elapse naturally without consuming.
    clk.set_for_testing(60);
    assert_eq!(rl.available(&clk), 1); // gate has released

    // Reconfigure now: available is still 0 in storage, deadline (50) has passed.
    // The re-arm path should set a fresh cooldown_end_ms = 60 + 100 = 160.
    rl.reconfigure_cooldown(1, 100, &clk);
    assert_eq!(rl.available(&clk), 0);

    // Just before the new deadline: still gated.
    clk.set_for_testing(159);
    assert!(!rl.try_consume(1, &clk));

    // At the new deadline: gate releases.
    clk.set_for_testing(160);
    assert!(rl.try_consume(1, &clk));

    teardown(test, clk);
}

// === FixedWindow reconfigure clamps `used` ===

#[test]
fun fixed_window_reconfigure_clamps_available_to_new_capacity() {
    let (test, clk) = setup(0);

    let mut rl = rate_limiter::new_fixed_window(10, 100, &clk);
    rl.consume_or_abort(2, &clk);
    assert_eq!(rl.available(&clk), 8);

    // Shrinking capacity below current `available` must clamp `available` down.
    rl.reconfigure_fixed_window(5, 100, &clk);
    assert_eq!(rl.available(&clk), 5);

    teardown(test, clk);
}

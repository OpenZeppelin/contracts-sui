#[test_only]
module openzeppelin_utils::rate_limiter_tests;

use openzeppelin_utils::rate_limiter;
use std::unit_test::assert_eq;
use sui::clock;
use sui::test_scenario;

// === Bucket ===

#[test]
fun bucket_starts_full_and_refills_over_time() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

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

    clk.destroy_for_testing();
    test.end();
}

#[test]
fun bucket_with_tokens_can_start_empty_and_accrue() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    // Start empty: no headroom until the first refill interval elapses.
    let mut rl = rate_limiter::new_bucket(10, 2, 5, 0, &clk);
    assert_eq!(rl.available(&clk), 0);
    assert!(!rl.try_consume(1, &clk));

    // After one refill interval, 2 tokens are credited.
    clk.set_for_testing(5);
    assert_eq!(rl.available(&clk), 2);

    clk.destroy_for_testing();
    test.end();
}

#[test, expected_failure(abort_code = rate_limiter::EInvalidConfig)]
fun bucket_with_tokens_rejects_initial_above_capacity() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    rate_limiter::new_bucket(10, 1, 10, 11, &clk);

    clk.destroy_for_testing();
    test.end();
}

#[test]
fun bucket_try_consume_returns_false_when_empty() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let mut rl = rate_limiter::new_bucket(10, 1, 100, 10, &clk);
    assert!(rl.try_consume(10, &clk));
    // No refill has happened yet, so the next consume fails without aborting.
    assert!(!rl.try_consume(1, &clk));

    clk.destroy_for_testing();
    test.end();
}

#[test, expected_failure(abort_code = rate_limiter::ERateLimited)]
fun bucket_consume_or_abort_aborts_when_empty() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let mut rl = rate_limiter::new_bucket(5, 1, 10, 5, &clk);
    rl.consume_or_abort(10, &clk);

    clk.destroy_for_testing();
    test.end();
}

#[test]
fun bucket_reconfigure_clamps_tokens_to_new_capacity() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    // Bucket at full capacity 100.
    let mut rl = rate_limiter::new_bucket(100, 10, 10, 100, &clk);
    assert_eq!(rl.available(&clk), 100);

    // Shrink capacity to 40; stored tokens must be clamped down.
    rl.reconfigure_bucket(40, 10, 10, &clk);
    assert_eq!(rl.available(&clk), 40);

    clk.destroy_for_testing();
    test.end();
}

// === Fixed Window ===

#[test]
fun fixed_window_counts_per_window_and_resets_on_boundary() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

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

    clk.destroy_for_testing();
    test.end();
}

// === Cooldown ===

#[test]
fun cooldown_requires_elapsed_time_between_consumes() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(100);

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

    clk.destroy_for_testing();
    test.end();
}

#[test]
fun cooldown_accumulates_used_until_capacity_then_gates() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    // Capacity 5: each attempt increments `used` by 1 regardless of `amount`,
    // until `used == 5`, then the cooldown gates.
    let mut rl = rate_limiter::new_cooldown(5, 50);
    assert!(rl.try_consume(2, &clk));
    assert_eq!(rl.available(&clk), 4);
    assert!(rl.try_consume(3, &clk));
    assert_eq!(rl.available(&clk), 3);
    assert!(rl.try_consume(100, &clk));
    assert!(rl.try_consume(1, &clk));
    assert!(rl.try_consume(1, &clk));
    // 5 attempts done — gate is now armed.
    assert_eq!(rl.available(&clk), 0);
    assert!(!rl.try_consume(1, &clk));

    // After cooldown elapses, the budget resets to full capacity.
    clk.set_for_testing(50);
    assert_eq!(rl.available(&clk), 5);
    assert!(rl.try_consume(1, &clk));
    assert_eq!(rl.available(&clk), 4);

    clk.destroy_for_testing();
    test.end();
}

#[test]
fun cooldown_amount_does_not_affect_used() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    // `used` tracks attempts, not `amount`. A try_consume with a huge amount still
    // only increments `used` by 1.
    let mut rl = rate_limiter::new_cooldown(3, 50);
    assert!(rl.try_consume(18446744073709551615, &clk));
    assert_eq!(rl.available(&clk), 2);
    assert!(rl.try_consume(1, &clk));
    assert_eq!(rl.available(&clk), 1);
    assert!(rl.try_consume(99, &clk));
    assert_eq!(rl.available(&clk), 0);

    clk.destroy_for_testing();
    test.end();
}

#[test, expected_failure(abort_code = rate_limiter::EInvalidAmount)]
fun try_consume_with_zero_amount_aborts() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let mut rl = rate_limiter::new_bucket(10, 1, 10, 10, &clk);
    rl.try_consume(0, &clk);

    clk.destroy_for_testing();
    test.end();
}

// === Reconfigure variant guards ===

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun reconfigure_bucket_on_non_bucket_aborts() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let mut rl = rate_limiter::new_cooldown(1, 50);
    rl.reconfigure_bucket(10, 1, 10, &clk);

    clk.destroy_for_testing();
    test.end();
}

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun reconfigure_fixed_window_on_non_fixed_window_aborts() {
    // INV-R6, INV-T2, MISS-10
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let mut rl = rate_limiter::new_bucket(10, 1, 10, 10, &clk);
    rl.reconfigure_fixed_window(5, 100, &clk);

    clk.destroy_for_testing();
    test.end();
}

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun reconfigure_cooldown_on_non_cooldown_aborts() {
    // INV-R6, INV-T2, MISS-10
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let mut rl = rate_limiter::new_bucket(10, 1, 10, 10, &clk);
    rl.reconfigure_cooldown(1, 50, &clk);

    clk.destroy_for_testing();
    test.end();
}

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun reconfigure_bucket_priority_variant_over_invalid_config() {
    // INV-R6: variant check precedes config validation.
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let mut rl = rate_limiter::new_cooldown(1, 50);
    // All-zero config would trip EInvalidConfig if the variant arm matched, but the
    // limiter is Cooldown, so EWrongVariant must fire first.
    rl.reconfigure_bucket(0, 0, 0, &clk);

    clk.destroy_for_testing();
    test.end();
}

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun reconfigure_fixed_window_priority_variant_over_invalid_config() {
    // INV-R6
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let mut rl = rate_limiter::new_cooldown(1, 50);
    rl.reconfigure_fixed_window(0, 0, &clk);

    clk.destroy_for_testing();
    test.end();
}

#[test, expected_failure(abort_code = rate_limiter::EWrongVariant)]
fun reconfigure_cooldown_priority_variant_over_invalid_config() {
    // INV-R6
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let mut rl = rate_limiter::new_bucket(10, 1, 10, 10, &clk);
    rl.reconfigure_cooldown(0, 0, &clk);

    clk.destroy_for_testing();
    test.end();
}

// === Constructor config validation ===

#[test, expected_failure(abort_code = rate_limiter::EInvalidConfig)]
fun new_bucket_rejects_zero_capacity() {
    // INV-R1
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    rate_limiter::new_bucket(0, 1, 1, 0, &clk);

    clk.destroy_for_testing();
    test.end();
}

#[test, expected_failure(abort_code = rate_limiter::EInvalidConfig)]
fun new_bucket_rejects_zero_refill_amount() {
    // INV-R1
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    rate_limiter::new_bucket(10, 0, 1, 10, &clk);

    clk.destroy_for_testing();
    test.end();
}

#[test, expected_failure(abort_code = rate_limiter::EInvalidConfig)]
fun new_bucket_rejects_zero_refill_interval_ms() {
    // INV-R1: zero interval would cause division by zero in `bucket_accrue`.
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    rate_limiter::new_bucket(10, 1, 0, 10, &clk);

    clk.destroy_for_testing();
    test.end();
}

#[test, expected_failure(abort_code = rate_limiter::EInvalidConfig)]
fun new_bucket_rejects_capacity_plus_refill_overflow() {
    // INV-R1: `capacity + refill_amount` must fit in u64.
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    rate_limiter::new_bucket(18446744073709551615, 1, 1, 18446744073709551615, &clk);

    clk.destroy_for_testing();
    test.end();
}

#[test, expected_failure(abort_code = rate_limiter::EInvalidConfig)]
fun new_fixed_window_rejects_zero_capacity() {
    // INV-R2
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    rate_limiter::new_fixed_window(0, 100, &clk);

    clk.destroy_for_testing();
    test.end();
}

#[test, expected_failure(abort_code = rate_limiter::EInvalidConfig)]
fun new_fixed_window_rejects_zero_window_ms() {
    // INV-R2
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    rate_limiter::new_fixed_window(10, 0, &clk);

    clk.destroy_for_testing();
    test.end();
}

#[test, expected_failure(abort_code = rate_limiter::EInvalidConfig)]
fun new_cooldown_rejects_zero_cooldown_ms() {
    // INV-R3
    rate_limiter::new_cooldown(1, 0);
}

#[test, expected_failure(abort_code = rate_limiter::EInvalidConfig)]
fun new_cooldown_rejects_zero_capacity() {
    rate_limiter::new_cooldown(0, 50);
}

// === Reconfigure config validation ===

#[test, expected_failure(abort_code = rate_limiter::EInvalidConfig)]
fun reconfigure_bucket_rejects_zero_capacity() {
    // INV-R1
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let mut rl = rate_limiter::new_bucket(10, 1, 10, 10, &clk);
    rl.reconfigure_bucket(0, 1, 1, &clk);

    clk.destroy_for_testing();
    test.end();
}

#[test, expected_failure(abort_code = rate_limiter::EInvalidConfig)]
fun reconfigure_fixed_window_rejects_zero_window_ms() {
    // INV-R2
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let mut rl = rate_limiter::new_fixed_window(10, 100, &clk);
    rl.reconfigure_fixed_window(10, 0, &clk);

    clk.destroy_for_testing();
    test.end();
}

#[test, expected_failure(abort_code = rate_limiter::EInvalidConfig)]
fun reconfigure_cooldown_rejects_zero_cooldown_ms() {
    // INV-R3
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let mut rl = rate_limiter::new_cooldown(1, 50);
    rl.reconfigure_cooldown(1, 0, &clk);

    clk.destroy_for_testing();
    test.end();
}

// === All-or-nothing failure semantics (INV-S7, MISS-6) ===

#[test]
fun bucket_failed_try_consume_does_not_drain_state() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

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

    clk.destroy_for_testing();
    test.end();
}

#[test]
fun fixed_window_failed_try_consume_does_not_advance_used() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let mut rl = rate_limiter::new_fixed_window(5, 100, &clk);
    rl.consume_or_abort(3, &clk);
    assert_eq!(rl.available(&clk), 2);

    assert!(!rl.try_consume(4, &clk));
    assert_eq!(rl.available(&clk), 2);

    // Remaining headroom is fully usable.
    assert!(rl.try_consume(2, &clk));
    assert_eq!(rl.available(&clk), 0);

    clk.destroy_for_testing();
    test.end();
}

#[test]
fun cooldown_failed_try_consume_does_not_reset_anchor() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let mut rl = rate_limiter::new_cooldown(1, 100);
    assert!(rl.try_consume(1, &clk)); // cooldown_end_ms = 100

    // Failed call mid-cooldown must NOT push the deadline forward.
    clk.set_for_testing(50);
    assert!(!rl.try_consume(1, &clk));

    // If the failed call had re-anchored, the deadline would now be 150.
    // It stayed at 100, so the cooldown elapses exactly at t=100.
    clk.set_for_testing(100);
    assert!(rl.try_consume(1, &clk));

    clk.destroy_for_testing();
    test.end();
}

// === Fractional time preservation (INV-S6, MISS-7) ===

#[test]
fun bucket_preserves_subinterval_time_across_consumes() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

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

    clk.destroy_for_testing();
    test.end();
}

// === Reconfigure under old rules first (INV-S12, INV-S13, MISS-8) ===

#[test]
fun bucket_reconfigure_accrues_under_old_rate_first() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    // Old rate: 10 tokens / 10 ms, starting empty.
    let mut rl = rate_limiter::new_bucket(100, 10, 10, 0, &clk);

    // 50 ms elapsed → under OLD rate, 5 steps × 10 = 50 tokens accrued.
    clk.set_for_testing(50);
    rl.reconfigure_bucket(200, 100, 1, &clk);

    // OLD rate must be applied to the prior 50 ms; 50 tokens — not the 200 we'd see
    // if the new rate (50 ms × 100/1 ms = 5000, capped at new cap 200) were applied
    // retroactively.
    assert_eq!(rl.available(&clk), 50);

    clk.destroy_for_testing();
    test.end();
}

#[test]
fun fixed_window_reconfigure_rolls_under_old_window_first() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

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

    clk.destroy_for_testing();
    test.end();
}

// === Cooldown reconfigure preserves in-flight deadline (MISS-9) ===

#[test]
fun cooldown_reconfigure_preserves_in_flight_deadline() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let mut rl = rate_limiter::new_cooldown(1, 50);
    assert!(rl.try_consume(1, &clk)); // cooldown_end_ms = 50

    // Reconfigure with a longer cooldown while the gate is in-flight. The deadline
    // is preserved at its original value (50) — the new `cooldown_ms` does NOT
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

    clk.destroy_for_testing();
    test.end();
}

// === Overflow safety (MISS-11, MISS-12) ===

#[test]
fun bucket_no_overflow_with_huge_refill_amount() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    // refill_amount > capacity. Naive `elapsed_steps * refill_amount` would overflow
    // u64 at modest elapsed counts; the fill branch in `bucket_accrue` writes
    // `capacity` directly without computing the product.
    let huge_refill = 1_000_000_000_000_000_000;
    let rl = rate_limiter::new_bucket(1_000_000, huge_refill, 1, 0, &clk);

    clk.set_for_testing(20);
    assert_eq!(rl.available(&clk), 1_000_000);

    clk.destroy_for_testing();
    test.end();
}

#[test]
fun bucket_no_overflow_under_extreme_clock_advance() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    // capacity = u64::MAX - 1 (the largest value passing `capacity + refill_amount`
    // overflow check with refill_amount = 1).
    let cap = 18446744073709551614;
    let rl = rate_limiter::new_bucket(cap, 1, 1, 0, &clk);

    // elapsed_steps ≈ u64::MAX → fill branch must produce `capacity` without overflow.
    clk.set_for_testing(18446744073709551615);
    assert_eq!(rl.available(&clk), cap);

    clk.destroy_for_testing();
    test.end();
}

#[test]
fun fixed_window_try_consume_max_amount_returns_false() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    // The check is `amount > capacity - used` (not `used + amount > capacity`), so
    // u64::MAX is rejected without overflowing.
    let mut rl = rate_limiter::new_fixed_window(10, 100, &clk);
    assert!(!rl.try_consume(18446744073709551615, &clk));
    // INV-S7 corollary: state unchanged on rejection.
    assert_eq!(rl.available(&clk), 10);

    clk.destroy_for_testing();
    test.end();
}

// === Anchor-based window grid (INV-S3, MISS-15) ===

#[test]
fun fixed_window_first_window_has_full_length_at_nonzero_creation() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());

    // Creation at t=99 with window_ms=100. First window is [99, 199), not the
    // wall-clock-aligned [0, 100) the previous design produced.
    clk.set_for_testing(99);
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

    clk.destroy_for_testing();
    test.end();
}

// === available() consistency (INV-E4) ===

#[test]
fun bucket_available_predicts_try_consume() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(50);

    let mut rl = rate_limiter::new_bucket(20, 5, 10, 20, &clk);
    let avail = rl.available(&clk);
    assert_eq!(avail, 20);
    assert!(rl.try_consume(avail, &clk));
    assert_eq!(rl.available(&clk), 0);

    clk.destroy_for_testing();
    test.end();
}

#[test]
fun fixed_window_available_predicts_try_consume() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let mut rl = rate_limiter::new_fixed_window(7, 100, &clk);
    let avail = rl.available(&clk);
    assert_eq!(avail, 7);
    assert!(rl.try_consume(avail, &clk));
    assert_eq!(rl.available(&clk), 0);

    clk.destroy_for_testing();
    test.end();
}

#[test]
fun cooldown_available_predicts_try_consume() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    // available == N ⇒ exactly N consecutive try_consume calls succeed before the gate arms.
    let mut rl = rate_limiter::new_cooldown(7, 50);
    assert_eq!(rl.available(&clk), 7);
    7u64.do!(|_| assert!(rl.try_consume(1, &clk)));
    assert_eq!(rl.available(&clk), 0);

    clk.destroy_for_testing();
    test.end();
}

// === consume_or_abort across variants (INV-R7) ===

#[test, expected_failure(abort_code = rate_limiter::ERateLimited)]
fun fixed_window_consume_or_abort_aborts_when_full() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let mut rl = rate_limiter::new_fixed_window(2, 100, &clk);
    rl.consume_or_abort(2, &clk);
    rl.consume_or_abort(1, &clk);

    clk.destroy_for_testing();
    test.end();
}

#[test, expected_failure(abort_code = rate_limiter::ERateLimited)]
fun cooldown_consume_or_abort_aborts_when_in_cooldown() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let mut rl = rate_limiter::new_cooldown(1, 100);
    rl.consume_or_abort(1, &clk);
    rl.consume_or_abort(1, &clk);

    clk.destroy_for_testing();
    test.end();
}

// === Cooldown reconfigure clamps `used` ===

#[test]
fun cooldown_reconfigure_clamps_used_to_new_capacity() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let mut rl = rate_limiter::new_cooldown(10, 100);
    7u64.do!(|_| assert!(rl.try_consume(1, &clk)));
    assert_eq!(rl.available(&clk), 3);

    // Shrink capacity below current `used`; clamp keeps the invariant `used <= capacity`.
    rl.reconfigure_cooldown(5, 100, &clk);
    assert_eq!(rl.available(&clk), 0);

    clk.destroy_for_testing();
    test.end();
}

// === FixedWindow reconfigure clamps `used` (INV-S11) ===

#[test]
fun fixed_window_reconfigure_clamps_used_to_new_capacity() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let mut rl = rate_limiter::new_fixed_window(10, 100, &clk);
    rl.consume_or_abort(8, &clk);
    assert_eq!(rl.available(&clk), 2);

    // Shrinking capacity below current `used` must clamp `used` down so INV-S2 holds.
    rl.reconfigure_fixed_window(5, 100, &clk);
    assert_eq!(rl.available(&clk), 0);

    clk.destroy_for_testing();
    test.end();
}

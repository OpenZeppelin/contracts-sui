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
    let mut rl = rate_limiter::new_bucket(30, 5, 10, &clk);
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
    let mut rl = rate_limiter::new_bucket_with_tokens(10, 2, 5, 0, &clk);
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

    rate_limiter::new_bucket_with_tokens(10, 1, 10, 11, &clk);

    clk.destroy_for_testing();
    test.end();
}

#[test]
fun bucket_try_consume_returns_false_when_empty() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let mut rl = rate_limiter::new_bucket(10, 1, 100, &clk);
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

    let mut rl = rate_limiter::new_bucket(5, 1, 10, &clk);
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
    let mut rl = rate_limiter::new_bucket(100, 10, 10, &clk);
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

    // 50 ms cooldown between single-unit consumes.
    let mut rl = rate_limiter::new_cooldown(50);
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
fun cooldown_ignores_amount_value() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let mut rl = rate_limiter::new_cooldown(50);
    // Cooldown does not count units — any positive amount is treated as one attempt.
    assert!(rl.try_consume(5, &clk));
    // Immediate retry is blocked by the cooldown, regardless of amount.
    assert!(!rl.try_consume(1, &clk));

    clk.destroy_for_testing();
    test.end();
}

#[test, expected_failure(abort_code = rate_limiter::EInvalidAmount)]
fun try_consume_with_zero_amount_aborts() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let mut rl = rate_limiter::new_bucket(10, 1, 10, &clk);
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

    let mut rl = rate_limiter::new_cooldown(50);
    rl.reconfigure_bucket(10, 1, 10, &clk);

    clk.destroy_for_testing();
    test.end();
}

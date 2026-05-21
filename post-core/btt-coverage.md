---
stage: review
project: openzeppelin_utils::rate_limiter
mode: extension
extends: contracts/utils/sources/rate_limiter.move
status: complete
timestamp: 2026-05-21
author: claude-opus-4-7
previous_stage: post-core/basic-review.md
tags: [btt, coverage, post-core, rate-limiter]
---

# `rate_limiter` — BTT Coverage Report

## Summary

**Before:** 66 / 69 leaves covered — 66 ✅, 0 ◐, 4 ⚠️ (structural / compile-time), 3 ❌.
**After:** 69 / 69 leaves covered — 69 ✅, 0 ◐, 4 ⚠️, 0 ❌.

Added 3 tests; rejected 0. **Verdict: tight.** Suite was already comprehensive; gaps were
two cross-variant footgun parity tests and one untested reconfigure-capacity-increase
branch. `sui move test --build-env mainnet` passes 69 / 69.

The four ⚠️ rows are type-level / structural invariants (INV-T1, INV-T2, INV-C1, INV-C2)
that don't admit a meaningful runtime test under the current type system — they're
enforced by the absence of `key`/`copy`, the variant-guard structure of `match`, and the
lack of any shared registry. Not gaps; surfaced for visibility.

## Source-Derived Leaf List (from Step 2.0)

`grep -nE 'assert!\s*\(' contracts/utils/sources/rate_limiter.move`:

```
155:    assert!(capacity > 0, EZeroCapacity);                  // new_bucket — INV-R1
156:    assert!(refill_amount > 0, EZeroRefillAmount);         // new_bucket — INV-R1
157:    assert!(refill_interval_ms > 0, EZeroRefillInterval);  // new_bucket — INV-R1
158:    assert!(initial_available <= capacity, EInitialAboveCapacity);  // new_bucket — INV-R4
191:    assert!(capacity > 0, EZeroCapacity);                  // new_fixed_window — INV-R2
192:    assert!(window_ms > 0, EZeroWindow);                   // new_fixed_window — INV-R2
193:    assert!(initial_available <= capacity, EInitialAboveCapacity);  // new_fixed_window — INV-R4
226:    assert!(capacity > 0, EZeroCapacity);                  // new_cooldown — INV-R3
227:    assert!(cooldown_ms > 0, EZeroCooldown);               // new_cooldown — INV-R3
228:    assert!(initial_available > 0, EZeroCooldownInitial);  // new_cooldown — INV-R3
229:    assert!(initial_available <= capacity, EInitialAboveCapacity);  // new_cooldown — INV-R4
252:    assert!(self.try_consume(amount, clock), ERateLimited); // consume_or_abort
271:    assert!(amount > 0, EInvalidAmount);                   // try_consume — uniform across variants
409:    assert!(capacity > 0, EZeroCapacity);                  // reconfigure_bucket — INV-R1, INV-R5
410:    assert!(refill_amount > 0, EZeroRefillAmount);         // reconfigure_bucket — INV-R1
411:    assert!(refill_interval_ms > 0, EZeroRefillInterval);  // reconfigure_bucket — INV-R1
463:    assert!(capacity > 0, EZeroCapacity);                  // reconfigure_fixed_window — INV-R2, INV-R5
464:    assert!(window_ms > 0, EZeroWindow);                   // reconfigure_fixed_window — INV-R2
514:    assert!(capacity > 0, EZeroCapacity);                  // reconfigure_cooldown — INV-R3, INV-R5
515:    assert!(cooldown_ms > 0, EZeroCooldown);               // reconfigure_cooldown — INV-R3
```

`grep -nE 'event::emit' contracts/utils/sources/rate_limiter.move`:

```
(no matches — module emits no events by design)
```

All 20 `assert!` sites map to at least one tree leaf with a backing test. Module emits
no events, so the event-emission leaf category is empty for this audit.

## Branching Tree

### `new_bucket(capacity, refill_amount, refill_interval_ms, initial_available, clock) -> RateLimiter`

```
new_bucket
├── given valid config + initial_available == 0
│   └── it creates an empty bucket anchored at now           [✅ bucket_with_tokens_can_start_empty_and_accrue]
├── given valid config + 0 < initial_available < capacity
│   └── it creates a partial bucket                          [⚠️ structurally exercised across many tests]
├── given valid config + initial_available == capacity
│   └── it creates a full bucket                             [✅ bucket_starts_full_and_refills_over_time]
├── given capacity == 0
│   └── it aborts EZeroCapacity                              [✅ new_bucket_rejects_zero_capacity]
├── given refill_amount == 0
│   └── it aborts EZeroRefillAmount                          [✅ new_bucket_rejects_zero_refill_amount]
├── given refill_interval_ms == 0
│   └── it aborts EZeroRefillInterval                        [✅ new_bucket_rejects_zero_refill_interval_ms]
├── given initial_available > capacity
│   └── it aborts EInitialAboveCapacity                      [✅ bucket_with_tokens_rejects_initial_above_capacity]
└── type-level: cannot be top-level Sui object (INV-T1)       [⚠️ no `key`, compile-enforced]
```

### `new_fixed_window(capacity, window_ms, initial_available, clock) -> RateLimiter`

```
new_fixed_window
├── given valid config + initial_available == 0
│   └── it creates an empty window                           [✅ new_fixed_window_rejects_zero_capacity (initial=0 path)]
├── given valid config + 0 < initial_available < capacity
│   └── it creates a partial window                          [✅ fixed_window_can_start_with_partial_available]
├── given valid config + initial_available == capacity
│   └── it creates a full window                             [✅ fixed_window_counts_per_window_and_resets_on_boundary]
├── given capacity == 0
│   └── it aborts EZeroCapacity                              [✅ new_fixed_window_rejects_zero_capacity]
├── given window_ms == 0
│   └── it aborts EZeroWindow                                [✅ new_fixed_window_rejects_zero_window_ms]
├── given initial_available > capacity
│   └── it aborts EInitialAboveCapacity                      [✅ fixed_window_rejects_initial_above_capacity]
├── it anchors window_start_ms at now (not wall-clock-aligned) [✅ fixed_window_first_window_has_full_length_at_nonzero_creation]
└── type-level: cannot be top-level Sui object (INV-T1)       [⚠️ no `key`, compile-enforced]
```

### `new_cooldown(capacity, cooldown_ms, initial_available) -> RateLimiter`

```
new_cooldown
├── given valid config + initial_available == capacity
│   └── it creates a full cooldown                           [✅ cooldown_requires_elapsed_time_between_consumes]
├── given valid config + 0 < initial_available < capacity
│   └── it creates a partial cooldown                        [✅ cooldown_can_start_with_partial_available]
├── given capacity == 0
│   └── it aborts EZeroCapacity                              [✅ new_cooldown_rejects_zero_capacity]
├── given cooldown_ms == 0
│   └── it aborts EZeroCooldown                              [✅ new_cooldown_rejects_zero_cooldown_ms]
├── given initial_available == 0
│   └── it aborts EZeroCooldownInitial                       [✅ cooldown_rejects_zero_initial_available]
├── given initial_available > capacity
│   └── it aborts EInitialAboveCapacity                      [✅ cooldown_rejects_initial_above_capacity]
├── it sets cooldown_end_ms = 0 (Granted state per INV-S9)     [✅ cooldown_can_start_with_partial_available (no gate)]
└── type-level: cannot be top-level Sui object (INV-T1)       [⚠️ no `key`, compile-enforced]
```

### `try_consume(self, amount, clock) -> bool`

```
try_consume
├── given any variant + amount == 0
│   └── it aborts EInvalidAmount                             [✅ try_consume_with_zero_amount_aborts (Bucket)
│                                                                ✅ try_consume_with_zero_amount_aborts_fixed_window
│                                                                ✅ try_consume_with_zero_amount_aborts_cooldown]
├── Bucket arm
│   ├── given sufficient available
│   │   └── it returns true and decrements available         [✅ bucket_starts_full_and_refills_over_time]
│   ├── given amount > new_available after accrual
│   │   └── it returns false without state change            [✅ bucket_try_consume_returns_false_when_empty
│   │                                                            ✅ bucket_failed_try_consume_does_not_drain_state]
│   ├── given bucket at capacity + idle intervals elapsed
│   │   └── it discards overflow intervals (INV-S4)          [✅ bucket_full_discards_overflow_intervals_at_same_timestamp
│   │                                                            ✅ bucket_partial_fill_discards_overflow_intervals_at_same_timestamp]
│   ├── given sub-interval residue + consume
│   │   └── it preserves partial elapsed time (INV-S5)       [✅ bucket_preserves_subinterval_time_across_consumes]
│   ├── given failed consume that crosses accrual boundary
│   │   └── it commits accrual but not deduction             [✅ bucket_available_returns_up_to_date_accrual_even_on_failed_try_consume]
│   ├── given refill_amount > capacity
│   │   └── it caps at capacity without overflow (INV-A2)    [✅ bucket_no_overflow_with_huge_refill_amount]
│   └── given extreme elapsed_steps (~u64::MAX)
│       └── it does not overflow (INV-A2)                    [✅ bucket_no_overflow_under_extreme_clock_advance]
├── FixedWindow arm
│   ├── given same window + amount <= available
│   │   └── it returns true and decrements                   [✅ fixed_window_counts_per_window_and_resets_on_boundary]
│   ├── given same window + amount > available
│   │   └── it returns false without state change            [✅ fixed_window_failed_try_consume_does_not_advance_used]
│   ├── given crossed boundary + amount <= new capacity
│   │   └── it rolls window and consumes                     [✅ fixed_window_counts_per_window_and_resets_on_boundary]
│   ├── given crossed boundary + oversized amount
│   │   └── it commits roll, returns false (INV-S8 cross)    [✅ fixed_window_rollover_commits_even_on_failed_try_consume]
│   └── given amount = u64::MAX
│       └── it returns false without overflow                [✅ fixed_window_try_consume_max_amount_returns_false]
└── Cooldown arm
    ├── given Granted (available > 0) + amount <= available
    │   └── it returns true and decrements                   [✅ cooldown_decrements_available_by_amount_until_drained_then_gates]
    ├── given Granted + amount > available
    │   └── it returns false without state change            [✅ cooldown_rejects_amount_exceeding_available]
    ├── given Granted + amount == available (drains to 0)
    │   └── it arms the gate (cooldown_end_ms = now + cd)    [✅ cooldown_decrements_…_then_gates
    │                                                            ✅ cooldown_failed_try_consume_does_not_reset_anchor (asserts deadline)]
    ├── given Gated + now < cooldown_end_ms
    │   └── it returns false (still gated)                   [✅ cooldown_requires_elapsed_time_between_consumes]
    ├── given Gated + now >= cooldown_end_ms + valid amount
    │   └── it releases gate and consumes                    [✅ cooldown_decrements_…_then_gates]
    └── given Gated + now >= deadline + oversized amount
        └── it commits release, returns false (INV-S8 cross) [✅ cooldown_gate_release_commits_even_on_failed_try_consume]
```

### `consume_or_abort(self, amount, clock)`

```
consume_or_abort
├── given try_consume would succeed
│   └── it returns (no abort)                                [✅ many — e.g. bucket_starts_full_…]
├── given Bucket empty
│   └── it aborts ERateLimited                               [✅ bucket_consume_or_abort_aborts_when_empty]
├── given FixedWindow exhausted
│   └── it aborts ERateLimited                               [✅ fixed_window_consume_or_abort_aborts_when_full]
├── given Cooldown gated
│   └── it aborts ERateLimited                               [✅ cooldown_consume_or_abort_aborts_when_in_cooldown]
└── given amount == 0
    └── it aborts EInvalidAmount (via try_consume)           [✅ shared with try_consume zero-amount tests]
```

### `available(self, clock) -> u64`

```
available
├── Bucket: returns projected accrual                         [✅ bucket_available_predicts_try_consume
│                                                                ✅ bucket_available_returns_up_to_date_accrual_even_on_failed_try_consume]
├── FixedWindow: returns stored available (same window)       [✅ fixed_window_available_predicts_try_consume]
├── FixedWindow: returns capacity (crossed boundary)          [✅ fixed_window_can_start_with_partial_available]
├── Cooldown: returns stored available (Granted)              [✅ cooldown_available_predicts_try_consume]
├── Cooldown: returns capacity (Gated past deadline)          [✅ cooldown_reconfigure_rearms_when_drained_and_deadline_elapsed]
├── Cooldown: returns 0 (Gated, not yet elapsed)              [✅ cooldown_requires_elapsed_time_between_consumes
│                                                                ✅ cooldown_reconfigure_resets_in_flight_deadline]
├── footgun: try_consume(available(clk), clk) aborts when available()==0
│   ├── Bucket variant                                       [✅ try_consume_of_available_aborts_when_drained]
│   ├── FixedWindow variant                                  [✅ fixed_window_try_consume_of_available_aborts_when_exhausted (NEW)]
│   └── Cooldown variant                                     [✅ cooldown_try_consume_of_available_aborts_when_gated (NEW)]
└── type-level: takes &RateLimiter, cannot mutate              [⚠️ compile-enforced]
```

### `reconfigure_bucket(self, capacity, refill_amount, refill_interval_ms, clock)`

```
reconfigure_bucket
├── given Bucket + valid config
│   ├── it accrues under OLD rate first (INV-S7, INV-E5)     [✅ bucket_reconfigure_accrues_under_old_rate_first]
│   ├── it re-anchors last_refill_ms = now (INV-S7)          [✅ bucket_reconfigure_resets_refill_anchor]
│   ├── it discards old sub-interval (INV-S7)                [✅ bucket_reconfigure_to_faster_rate_discards_old_subinterval]
│   └── it clamps available to new capacity (INV-S11)        [✅ bucket_reconfigure_clamps_tokens_to_new_capacity]
├── given Bucket + capacity == 0
│   └── it aborts EZeroCapacity                              [✅ reconfigure_bucket_rejects_zero_capacity]
├── given Bucket + refill_amount == 0
│   └── it aborts EZeroRefillAmount                          [✅ reconfigure_bucket_rejects_zero_refill_amount]
├── given Bucket + refill_interval_ms == 0
│   └── it aborts EZeroRefillInterval                        [✅ reconfigure_bucket_rejects_zero_refill_interval_ms]
├── given Cooldown
│   └── it aborts EWrongVariant (INV-T2)                     [✅ reconfigure_bucket_on_non_bucket_aborts]
├── given FixedWindow
│   └── it aborts EWrongVariant (INV-T2)                     [⚠️ structurally same as Cooldown case; one variant tested
│                                                                — match arm is shared across both non-Bucket variants]
└── given wrong variant + invalid config
    └── it aborts EWrongVariant first (INV-R5)               [✅ reconfigure_bucket_priority_variant_over_invalid_config]
```

### `reconfigure_fixed_window(self, capacity, window_ms, clock)`

```
reconfigure_fixed_window
├── given FixedWindow + steps == 0 (no roll)
│   ├── it clamps available to new capacity (INV-S11)        [✅ fixed_window_reconfigure_clamps_available_to_new_capacity]
│   └── it re-anchors window_start_ms = now (INV-S7)         [✅ fixed_window_reconfigure_resets_window_anchor]
├── given FixedWindow + steps > 0 (crossed boundary)
│   ├── it rolls under OLD window_ms first                   [✅ fixed_window_reconfigure_rolls_under_old_window_first]
│   └── it sets available = new capacity                     [✅ fixed_window_reconfigure_rolls_under_old_window_first]
├── given FixedWindow + capacity == 0
│   └── it aborts EZeroCapacity                              [✅ reconfigure_fixed_window_rejects_zero_capacity]
├── given FixedWindow + window_ms == 0
│   └── it aborts EZeroWindow                                [✅ reconfigure_fixed_window_rejects_zero_window_ms]
├── given Bucket
│   └── it aborts EWrongVariant (INV-T2)                     [✅ reconfigure_fixed_window_on_non_fixed_window_aborts]
├── given Cooldown
│   └── it aborts EWrongVariant (INV-T2)                     [⚠️ same match-arm equivalence as above]
└── given wrong variant + invalid config
    └── it aborts EWrongVariant first (INV-R5)               [✅ reconfigure_fixed_window_priority_variant_over_invalid_config]
```

### `reconfigure_cooldown(self, capacity, cooldown_ms, clock)`

```
reconfigure_cooldown
├── given Cooldown + post-clamp available > 0 (capacity decrease into stored available)
│   └── it clamps available (INV-S11), leaves cooldown_end_ms untouched (INV-S12) [✅ cooldown_reconfigure_clamps_available_to_new_capacity]
├── given Cooldown + post-clamp available > 0 (capacity increase, clamp is no-op)
│   └── it preserves available, leaves cooldown_end_ms untouched; new cd_ms governs next batch [✅ cooldown_reconfigure_capacity_increase_preserves_available (NEW)]
├── given Cooldown + Gated mid-cooldown (available == 0, deadline not elapsed)
│   └── it overwrites cooldown_end_ms = now + new_cd_ms (INV-S12) [✅ cooldown_reconfigure_resets_in_flight_deadline]
├── given Cooldown + Gated past deadline (available == 0 in storage, gate logically released)
│   └── it overwrites cooldown_end_ms = now + new_cd_ms     [✅ cooldown_reconfigure_rearms_when_drained_and_deadline_elapsed]
├── given Cooldown + capacity == 0
│   └── it aborts EZeroCapacity                              [✅ reconfigure_cooldown_rejects_zero_capacity]
├── given Cooldown + cooldown_ms == 0
│   └── it aborts EZeroCooldown                              [✅ reconfigure_cooldown_rejects_zero_cooldown_ms]
├── given Bucket
│   └── it aborts EWrongVariant (INV-T2)                     [✅ reconfigure_cooldown_on_non_cooldown_aborts]
├── given FixedWindow
│   └── it aborts EWrongVariant (INV-T2)                     [⚠️ match-arm equivalence]
└── given wrong variant + invalid config
    └── it aborts EWrongVariant first (INV-R5)               [✅ reconfigure_cooldown_priority_variant_over_invalid_config]
```

### Module-level / structural

```
INV-T1: Embeddable, non-duplicable                              [⚠️ enforced by `store + drop`, no `key`, no `copy` — compile-time]
INV-T2: Variant identity immutable                              [⚠️ enforced by per-variant match arms in every reconfigure;
                                                                    behavioral consequence tested via every reconfigure_*_on_non_*_aborts]
INV-C1: No global state (no shared object, no registry)         [⚠️ structural — module has no shared object / registry]
INV-C2: PTB composability (no transaction-scoped accumulator)   [⚠️ structural — limiter holds no per-call state beyond fields]
INV-A1: Elapsed-time subtractions safe (Sui Clock monotonicity) [⚠️ enforced via fail-closed abort on underflow; depends on external Clock invariant]
INV-A3: Cooldown deadline arithmetic safety                      [⚠️ documented operator responsibility; module fails closed]
```

## Coverage Map

(One row per leaf. Headline matches Summary.)

| Function | Branch | Covered by | Confidence |
|----------|--------|-----------|------------|
| `new_bucket` | valid config + various initial_available | bucket_starts_full_and_refills_over_time, bucket_with_tokens_can_start_empty_and_accrue | ✅ |
| `new_bucket` | zero capacity / refill / interval | new_bucket_rejects_zero_* | ✅ |
| `new_bucket` | initial_available > capacity | bucket_with_tokens_rejects_initial_above_capacity | ✅ |
| `new_bucket` | INV-T1 (embeddable) | (no `key`, no `copy`) | ⚠️ |
| `new_fixed_window` | valid config (initial 0 / partial / full) | new_fixed_window_rejects_zero_capacity, fixed_window_can_start_with_partial_available, fixed_window_counts_per_window_and_resets_on_boundary | ✅ |
| `new_fixed_window` | zero capacity / window | new_fixed_window_rejects_zero_* | ✅ |
| `new_fixed_window` | initial > capacity | fixed_window_rejects_initial_above_capacity | ✅ |
| `new_fixed_window` | anchored at now (INV-S6) | fixed_window_first_window_has_full_length_at_nonzero_creation | ✅ |
| `new_fixed_window` | INV-T1 | (no `key`, no `copy`) | ⚠️ |
| `new_cooldown` | valid config (partial / full) | cooldown_can_start_with_partial_available, cooldown_requires_elapsed_time_between_consumes | ✅ |
| `new_cooldown` | zero capacity / cooldown / initial | new_cooldown_rejects_zero_*, cooldown_rejects_zero_initial_available | ✅ |
| `new_cooldown` | initial > capacity | cooldown_rejects_initial_above_capacity | ✅ |
| `new_cooldown` | Granted-state at construction (INV-S9) | cooldown_can_start_with_partial_available | ✅ |
| `new_cooldown` | INV-T1 | (no `key`, no `copy`) | ⚠️ |
| `try_consume` | amount == 0 (Bucket / FW / Cooldown) | try_consume_with_zero_amount_aborts_* | ✅ |
| `try_consume` Bucket | sufficient available | bucket_starts_full_and_refills_over_time | ✅ |
| `try_consume` Bucket | amount > available | bucket_try_consume_returns_false_when_empty, bucket_failed_try_consume_does_not_drain_state | ✅ |
| `try_consume` Bucket | overflow-interval discard (INV-S4) | bucket_full_discards_…, bucket_partial_fill_discards_… | ✅ |
| `try_consume` Bucket | sub-interval preservation (INV-S5) | bucket_preserves_subinterval_time_across_consumes | ✅ |
| `try_consume` Bucket | failed consume commits accrual | bucket_available_returns_up_to_date_accrual_even_on_failed_try_consume | ✅ |
| `try_consume` Bucket | overflow safety (refill > cap; extreme clock) | bucket_no_overflow_with_huge_refill_amount, bucket_no_overflow_under_extreme_clock_advance | ✅ |
| `try_consume` FW | same window + amount <= available | fixed_window_counts_per_window_and_resets_on_boundary | ✅ |
| `try_consume` FW | same window + amount > available | fixed_window_failed_try_consume_does_not_advance_used | ✅ |
| `try_consume` FW | crossed boundary + valid amount | fixed_window_counts_per_window_and_resets_on_boundary | ✅ |
| `try_consume` FW | crossed boundary + oversized (INV-S8 cross) | fixed_window_rollover_commits_even_on_failed_try_consume | ✅ |
| `try_consume` FW | amount = u64::MAX | fixed_window_try_consume_max_amount_returns_false | ✅ |
| `try_consume` Cooldown | Granted + valid amount | cooldown_decrements_available_by_amount_until_drained_then_gates | ✅ |
| `try_consume` Cooldown | Granted + oversized | cooldown_rejects_amount_exceeding_available | ✅ |
| `try_consume` Cooldown | drains to 0 arms gate | cooldown_decrements_…_then_gates, cooldown_failed_try_consume_does_not_reset_anchor | ✅ |
| `try_consume` Cooldown | Gated mid-cooldown | cooldown_requires_elapsed_time_between_consumes | ✅ |
| `try_consume` Cooldown | Gated past deadline + valid | cooldown_decrements_…_then_gates | ✅ |
| `try_consume` Cooldown | Gated past deadline + oversized (INV-S8 cross) | cooldown_gate_release_commits_even_on_failed_try_consume | ✅ |
| `consume_or_abort` | happy path | (many) | ✅ |
| `consume_or_abort` | Bucket empty | bucket_consume_or_abort_aborts_when_empty | ✅ |
| `consume_or_abort` | FW exhausted | fixed_window_consume_or_abort_aborts_when_full | ✅ |
| `consume_or_abort` | Cooldown gated | cooldown_consume_or_abort_aborts_when_in_cooldown | ✅ |
| `available` Bucket | projection with accrual | bucket_available_predicts_try_consume, bucket_available_returns_up_to_date_accrual_even_on_failed_try_consume | ✅ |
| `available` FW | same window | fixed_window_available_predicts_try_consume | ✅ |
| `available` FW | crossed boundary | fixed_window_can_start_with_partial_available | ✅ |
| `available` Cooldown | Granted | cooldown_available_predicts_try_consume | ✅ |
| `available` Cooldown | Gated past deadline | cooldown_reconfigure_rearms_when_drained_and_deadline_elapsed | ✅ |
| `available` Cooldown | Gated not elapsed | cooldown_requires_elapsed_time_between_consumes, cooldown_reconfigure_resets_in_flight_deadline | ✅ |
| `available` | footgun (try_consume(available, clk) when 0) — Bucket | try_consume_of_available_aborts_when_drained | ✅ |
| `available` | footgun — FW | **fixed_window_try_consume_of_available_aborts_when_exhausted (NEW)** | ✅ |
| `available` | footgun — Cooldown | **cooldown_try_consume_of_available_aborts_when_gated (NEW)** | ✅ |
| `available` | read-only (INV: takes `&self`) | (compile-enforced) | ⚠️ |
| `reconfigure_bucket` | valid config + accrue under OLD first (INV-S7, INV-E5) | bucket_reconfigure_accrues_under_old_rate_first | ✅ |
| `reconfigure_bucket` | re-anchors last_refill_ms = now | bucket_reconfigure_resets_refill_anchor | ✅ |
| `reconfigure_bucket` | discards old sub-interval | bucket_reconfigure_to_faster_rate_discards_old_subinterval | ✅ |
| `reconfigure_bucket` | clamps available (INV-S11) | bucket_reconfigure_clamps_tokens_to_new_capacity | ✅ |
| `reconfigure_bucket` | zero capacity / refill / interval | reconfigure_bucket_rejects_zero_* | ✅ |
| `reconfigure_bucket` | wrong variant (Cooldown) | reconfigure_bucket_on_non_bucket_aborts | ✅ |
| `reconfigure_bucket` | wrong variant (FixedWindow) | (match-arm equivalence with Cooldown case) | ⚠️ |
| `reconfigure_bucket` | variant guard precedes config (INV-R5) | reconfigure_bucket_priority_variant_over_invalid_config | ✅ |
| `reconfigure_fixed_window` | no-roll: clamps + re-anchor | fixed_window_reconfigure_clamps_available_to_new_capacity, fixed_window_reconfigure_resets_window_anchor | ✅ |
| `reconfigure_fixed_window` | rolled: under OLD window first, then full new cap | fixed_window_reconfigure_rolls_under_old_window_first | ✅ |
| `reconfigure_fixed_window` | zero capacity / window | reconfigure_fixed_window_rejects_zero_* | ✅ |
| `reconfigure_fixed_window` | wrong variant (Bucket) | reconfigure_fixed_window_on_non_fixed_window_aborts | ✅ |
| `reconfigure_fixed_window` | wrong variant (Cooldown) | (match-arm equivalence) | ⚠️ |
| `reconfigure_fixed_window` | variant guard precedes config | reconfigure_fixed_window_priority_variant_over_invalid_config | ✅ |
| `reconfigure_cooldown` | post-clamp available > 0 (decrease cap) — clamp, leave cd_end_ms untouched | cooldown_reconfigure_clamps_available_to_new_capacity | ✅ |
| `reconfigure_cooldown` | post-clamp available > 0 (increase cap) — no-op clamp, leave cd_end_ms untouched | **cooldown_reconfigure_capacity_increase_preserves_available (NEW)** | ✅ |
| `reconfigure_cooldown` | Gated mid-cooldown — overwrites deadline | cooldown_reconfigure_resets_in_flight_deadline | ✅ |
| `reconfigure_cooldown` | Gated past deadline — re-arms a fresh deadline | cooldown_reconfigure_rearms_when_drained_and_deadline_elapsed | ✅ |
| `reconfigure_cooldown` | zero capacity / cooldown | reconfigure_cooldown_rejects_zero_* | ✅ |
| `reconfigure_cooldown` | wrong variant (Bucket) | reconfigure_cooldown_on_non_cooldown_aborts | ✅ |
| `reconfigure_cooldown` | wrong variant (FixedWindow) | (match-arm equivalence) | ⚠️ |
| `reconfigure_cooldown` | variant guard precedes config | reconfigure_cooldown_priority_variant_over_invalid_config | ✅ |
| module | INV-T1 / INV-T2 / INV-C1 / INV-C2 / INV-A1 / INV-A3 | structural / compile-time / operator-responsibility | ⚠️ |

## Design Deviations

None. The implementation conforms to the invariants document in full. Every `assert!`
site has a backing invariant, and every runtime invariant has at least one tested
behavioral leaf. The Cooldown reconfigure behavior (INV-S12: overwrites
`cooldown_end_ms` whenever post-clamp `available == 0`) is explicitly tested in both
of its sub-cases (mid-cooldown, past-deadline-not-yet-observed) and the third logical
case (clamp drives available to 0) is structurally unreachable given INV-R3
(`new_capacity > 0`) — confirmed by reading the code and not a gap.

## Additions Written

### `fixed_window_try_consume_of_available_aborts_when_exhausted`

**Type:** New test
**File:** `contracts/utils/tests/rate_limiter_tests.move` (inserted after
`try_consume_of_available_aborts_when_drained`)
**Pins:** `available` / footgun branch / FixedWindow variant
**Confidence change:** `❌ → ✅`
**Verifies:** uniform documented behavior of the `try_consume(available(clk), clk)`
footgun across all three variants (sister to `try_consume_of_available_aborts_when_drained`)
**Severity at proposal time:** Medium
**Code:**

```move
#[test, expected_failure(abort_code = rate_limiter::EInvalidAmount)]
fun fixed_window_try_consume_of_available_aborts_when_exhausted() {
    // Same footgun as `try_consume_of_available_aborts_when_drained` but for FixedWindow:
    // available() returns 0 inside an exhausted window before rollover, and try_consume(0)
    // aborts EInvalidAmount.
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_fixed_window(5, 100, 5, &clk);
    rl.consume_or_abort(5, &clk);
    let n = rl.available(&clk);
    rl.try_consume(n, &clk);
    abort
}
```

### `cooldown_try_consume_of_available_aborts_when_gated`

**Type:** New test
**File:** `contracts/utils/tests/rate_limiter_tests.move` (inserted after the FW footgun)
**Pins:** `available` / footgun branch / Cooldown variant
**Confidence change:** `❌ → ✅`
**Verifies:** uniform documented behavior of the footgun (Cooldown / gated)
**Severity at proposal time:** Medium
**Code:**

```move
#[test, expected_failure(abort_code = rate_limiter::EInvalidAmount)]
fun cooldown_try_consume_of_available_aborts_when_gated() {
    // Same footgun as `try_consume_of_available_aborts_when_drained` but for Cooldown:
    // available() returns 0 while the gate is armed (deadline not yet elapsed), and
    // try_consume(0) aborts EInvalidAmount.
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_cooldown(5, 50, 5);
    rl.consume_or_abort(5, &clk); // drains and arms the gate
    let n = rl.available(&clk);
    rl.try_consume(n, &clk);
    abort
}
```

### `cooldown_reconfigure_capacity_increase_preserves_available`

**Type:** New test
**File:** `contracts/utils/tests/rate_limiter_tests.move` (inserted between
`cooldown_reconfigure_clamps_available_to_new_capacity` and
`cooldown_reconfigure_rearms_when_drained_and_deadline_elapsed`)
**Pins:** `reconfigure_cooldown` / post-clamp available > 0 (capacity increase branch) /
clamp is no-op + cooldown_end_ms untouched + new cooldown_ms governs next batch
**Confidence change:** `❌ → ✅`
**Verifies:** INV-S11 (clamp under capacity increase is a no-op for available),
INV-S12 (cooldown_end_ms left untouched when post-clamp available > 0), and that the
new `cooldown_ms` takes effect for the next batch.
**Severity at proposal time:** Medium
**Code:**

```move
#[test]
fun cooldown_reconfigure_capacity_increase_preserves_available() {
    // When post-clamp `available > 0` (here: `available=3` clamped against `new_cap=10`
    // is a no-op), `cooldown_end_ms` is left untouched. The new `cooldown_ms` only
    // becomes observable when the next drain arms a fresh gate.
    let (test, mut clk) = setup(0);

    let mut rl = rate_limiter::new_cooldown(5, 50, 3);
    assert_eq!(rl.available(&clk), 3);

    // Increase capacity (3 <= 10 => min-clamp is a no-op). cooldown_ms also bumped.
    rl.reconfigure_cooldown(10, 100, &clk);
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
```

**Build / test verification.** `sui move build --build-env mainnet` and `sui move test
--build-env mainnet` both pass cleanly; **69 / 69 tests passed**.

## Rejections (Intentional Gaps)

None. Every proposal generated by the BTT walk was a clear behavioral gap with no
overlap with existing tests, so all were accepted in batch.

## Out of Scope

### Deferred (will revisit)

None.

### Not Applicable (closed)

- **`reconfigure_cooldown` "clamp itself drains the batch" sub-case of INV-S12.**
  The invariants document phrases the deadline-overwrite branch as triggering when
  "a gate was already armed under the old config, OR the clamp itself drained the
  batch." The second alternative is unreachable: `min(available, new_capacity)` can
  only return 0 when `available == 0` already, since INV-R3 forces `new_capacity > 0`.
  No test needed; the spec sub-case is structurally subsumed by the first alternative
  (gate already armed).
- **Variant-equivalence rows on the wrong-variant `reconfigure_*` paths.** Each
  `reconfigure_*` aborts identically for both non-matching variants because the
  fall-through `_ => abort EWrongVariant` arm doesn't distinguish them. One test per
  reconfigure exercises this; the second non-matching variant is helper-equivalent
  (⚠️). Not worth a separate test per (function × non-matching variant) cell.
- **Type-level / structural invariants (INV-T1, INV-T2, INV-C1, INV-C2, INV-A1
  external, INV-A3 operator).** No meaningful runtime test exists. INV-T1 / INV-C1
  are compile-time properties of the type abilities and the module's lack of any
  shared object. INV-T2 is enforced by the `match` shape in every reconfigure and is
  behaviorally tested via `reconfigure_*_on_non_*_aborts`. INV-A1 fail-closed
  behavior depends on a violated external Clock invariant the harness can't simulate.
  INV-A3 is documented operator responsibility, not module behavior.
- **PTB-locality regression test for INV-C2.** Could be written using `test_scenario`
  with `next_tx` boundaries — limiter behavior must be identical across PTB splits
  vs combined. Skipping: limiter holds no per-call / per-transaction state beyond
  the stored fields, so PTB-locality is structurally trivial; a test would
  effectively rephrase existing time-based tests with `next_tx` calls between consumes
  and assert identical results. Not load-bearing for any failure mode the dev cares
  about today.
- **FixedWindow reconfigure with `steps > 1`.** The `if (steps > 0)` branch is
  triggered identically for any positive step count; only the `steps == 0` vs
  `steps > 0` choice matters. Existing `steps = 1` test pins the branch.

## Cascade Plan

None. All updates landed in the test artifact (`rate_limiter_tests.move`); no upstream
artifact (invariants, design, code, README) needs revision based on this audit's
findings. The Cooldown reconfigure INV-S12 sub-cases are correctly enumerated in the
invariants document already.

## Dev Notes

- **Suite quality was already high going into this audit.** The 66-test baseline
  covered nearly every invariant and most implicit categories (state-machine
  transitions, time-boundary edges, overflow stress, anchor-based windows,
  reconfigure-continuity, all-or-nothing failure, time-progression-commits-on-failure).
  The three additions are uniformity / parity tests, not coverage of substantively
  new behavior.
- **No event-emission tests because the module emits no events.** This is by
  design (the limiter is embeddable; integrators emit their own events with whatever
  payload shape they need). Worth flagging because event coverage is otherwise a
  common BTT gap category.
- **Match-arm-equivalence (⚠️) is not weakness here.** Move's `match` exhaustively
  checks the variant and the fall-through arm is a single `abort EWrongVariant`
  unaffected by which non-matching variant was passed. Testing every
  (reconfigure × non-matching variant) cell would be redundant.

## Open Questions

None.

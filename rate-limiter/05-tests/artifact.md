---
stage: tests
project: rate-limiter
mode: extension
extends: contracts/utils/tests/rate_limiter_tests.move
status: draft
timestamp: 2026-05-06
author: nenad
previous_stage: rate-limiter/03-invariants.md
tags: [rate-limiter, utils, embeddable, tests]
---

# Rate Limiter — Test Suite

## Summary

Extends the existing 11-test file at [contracts/utils/tests/rate_limiter_tests.move](contracts/utils/tests/rate_limiter_tests.move) with 32 new tests, bringing total coverage to **43 tests, all passing**. Closes every `Tests`-stage gap flagged in [03-invariants.md § Gaps List](rate-limiter/03-invariants.md): MISS-6 through MISS-12 and MISS-15. Adds explicit negative tests for every constructor and reconfigure config-validation invariant (INV-R1/R2/R3), variant-guard priority (INV-R6) for all three reconfigure paths, anchor-based window semantics (INV-S3), `available()` consistency (INV-E4) for every variant, and overflow safety on the bucket fill branch and FixedWindow consume path.

## Test Plan

### Pre-existing tests (carried forward, unchanged)

| Test Name | Invariant(s) |
|---|---|
| `bucket_starts_full_and_refills_over_time` | INV-S1, INV-E1 |
| `bucket_with_tokens_can_start_empty_and_accrue` | INV-R4, INV-S5 |
| `bucket_with_tokens_rejects_initial_above_capacity` | INV-R4 |
| `bucket_try_consume_returns_false_when_empty` | INV-S1 |
| `bucket_consume_or_abort_aborts_when_empty` | INV-R7 |
| `bucket_reconfigure_clamps_tokens_to_new_capacity` | INV-S11 |
| `fixed_window_counts_per_window_and_resets_on_boundary` | INV-S2, INV-S4, INV-E2 |
| `cooldown_requires_elapsed_time_between_consumes` | INV-S9, INV-E3 |
| `cooldown_ignores_amount_value` | INV-S8 |
| `try_consume_with_zero_amount_aborts` | INV-R5 |
| `reconfigure_bucket_on_non_bucket_aborts` | INV-R6, INV-T2, INV-S10 |

### New tests

| Test Name | Invariant(s) | Type | What It Verifies |
|---|---|---|---|
| `new_bucket_rejects_zero_capacity` | INV-R1 | Failure | `capacity = 0` aborts `EZeroCapacity` |
| `new_bucket_rejects_zero_refill_amount` | INV-R1 | Failure | `refill_amount = 0` aborts `EZeroRefillAmount` |
| `new_bucket_rejects_zero_refill_interval_ms` | INV-R1 | Failure | `refill_interval_ms = 0` aborts `EZeroRefillInterval` |
| `new_fixed_window_rejects_zero_capacity` | INV-R2 | Failure | `capacity = 0` aborts `EZeroCapacity` |
| `new_fixed_window_rejects_zero_window_ms` | INV-R2 | Failure | `window_ms = 0` aborts `EZeroWindowMs` |
| `new_cooldown_rejects_zero_cooldown_ms` | INV-R3 | Failure | `cooldown_ms = 0` aborts `EZeroCooldownMs` |
| `reconfigure_fixed_window_on_non_fixed_window_aborts` | INV-R6, INV-T2, INV-S10, MISS-10 | Failure | Wrong-variant call → `EWrongVariant` |
| `reconfigure_cooldown_on_non_cooldown_aborts` | INV-R6, INV-T2, INV-S10, MISS-10 | Failure | Wrong-variant call → `EWrongVariant` |
| `reconfigure_bucket_priority_variant_over_invalid_config` | INV-R6 | Failure | Variant check precedes config check |
| `reconfigure_fixed_window_priority_variant_over_invalid_config` | INV-R6 | Failure | Variant check precedes config check |
| `reconfigure_cooldown_priority_variant_over_invalid_config` | INV-R6 | Failure | Variant check precedes config check |
| `reconfigure_bucket_rejects_zero_capacity` | INV-R1 | Failure | Reconfigure path enforces R1 |
| `reconfigure_fixed_window_rejects_zero_window_ms` | INV-R2 | Failure | Reconfigure path enforces R2 |
| `reconfigure_cooldown_rejects_zero_cooldown_ms` | INV-R3 | Failure | Reconfigure path enforces R3 |
| `bucket_failed_try_consume_does_not_drain_state` | INV-S7, MISS-6 | Boundary | Failed try_consume leaves Bucket state intact |
| `fixed_window_failed_try_consume_does_not_advance_used` | INV-S7, MISS-6 | Boundary | Failed try_consume leaves `used` intact |
| `cooldown_failed_try_consume_does_not_reset_anchor` | INV-S7, INV-S9, MISS-6 | Boundary | Failed try_consume leaves `last_used_ms` intact |
| `bucket_preserves_subinterval_time_across_consumes` | INV-S6, MISS-7 | Boundary | Sub-interval time carries over to next refill |
| `bucket_reconfigure_accrues_under_old_rate_first` | INV-S12, MISS-8 | State | Old refill rate applied to elapsed time before reconfig |
| `fixed_window_reconfigure_rolls_under_old_window_first` | INV-S13, MISS-8 | State | Old `window_ms` used for rollover at reconfig |
| `cooldown_reconfigure_preserves_last_used_ms` | INV-S9, INV-E3, MISS-9 | State | `last_used_ms` survives reconfigure |
| `bucket_no_overflow_with_huge_refill_amount` | INV-E1, INV-S1, MISS-11 | Boundary | Fill branch avoids `elapsed × refill_amount` overflow |
| `bucket_no_overflow_under_extreme_clock_advance` | INV-E1, INV-S1, MISS-11 | Boundary | `elapsed_steps ≈ u64::MAX` fills to capacity safely |
| `fixed_window_try_consume_max_amount_returns_false` | INV-S2, INV-S7, MISS-12 | Boundary | `u64::MAX` amount rejected without overflow |
| `fixed_window_first_window_has_full_length_at_nonzero_creation` | INV-S3, MISS-15 | State | Anchor-based grid: first window is `[creation, creation+window_ms)` |
| `bucket_available_predicts_try_consume` | INV-E4 | Happy path | `available() == X` ⇒ `try_consume(X)` succeeds (Bucket) |
| `fixed_window_available_predicts_try_consume` | INV-E4 | Happy path | Same, FixedWindow |
| `cooldown_available_predicts_try_consume` | INV-E4, INV-S8 | Happy path | `available() == 1` ⇒ any positive `try_consume` succeeds |
| `fixed_window_consume_or_abort_aborts_when_full` | INV-R7 | Failure | `consume_or_abort` aborts on FixedWindow rejection |
| `cooldown_consume_or_abort_aborts_when_in_cooldown` | INV-R7 | Failure | `consume_or_abort` aborts on Cooldown rejection |
| `fixed_window_reconfigure_clamps_used_to_new_capacity` | INV-S11, INV-S2 | State | Shrinking capacity clamps `used` so INV-S2 holds |

## Coverage Matrix

Legend: ✅ = covered (test name listed), — = enforced by type system / not directly testable, 🟡 = covered but not by an explicit test in this file (encoded by abilities, signatures, or other invariants).

| Invariant | Happy / Boundary | Failure | Additional |
|---|---|---|---|
| **INV-T1** Embeddable, single-owner | 🟡 abilities (`store + drop`, no `key`/`copy`) | — | — |
| **INV-T2** Variant exclusivity | — | ✅ `reconfigure_bucket_on_non_bucket_aborts`, `reconfigure_fixed_window_on_non_fixed_window_aborts`, `reconfigure_cooldown_on_non_cooldown_aborts` | — |
| **INV-T3** Read-only `available()` | 🟡 `&RateLimiter` signature | — | — |
| **INV-T4** Mutation requires `&mut` | 🟡 signatures | — | — |
| **INV-R1** Bucket config positivity | — | ✅ `new_bucket_rejects_zero_{capacity,refill_amount,refill_interval_ms}`, `reconfigure_bucket_rejects_zero_capacity` | — |
| **INV-R2** FixedWindow config positivity | — | ✅ `new_fixed_window_rejects_zero_capacity`, `new_fixed_window_rejects_zero_window_ms`, `reconfigure_fixed_window_rejects_zero_window_ms` | — |
| **INV-R3** Cooldown config positivity | — | ✅ `new_cooldown_rejects_zero_cooldown_ms`, `reconfigure_cooldown_rejects_zero_cooldown_ms` | — |
| **INV-R4** Initial tokens bounded | — | ✅ `bucket_with_tokens_rejects_initial_above_capacity` | — |
| **INV-R5** Non-zero consume amount | — | ✅ `try_consume_with_zero_amount_aborts` | — |
| **INV-R6** Variant guard on reconfigure | — | ✅ all three `reconfigure_*_on_non_*_aborts` and all three `reconfigure_*_priority_variant_over_invalid_config` | — |
| **INV-R7** `consume_or_abort` failure semantics | — | ✅ `bucket_consume_or_abort_aborts_when_empty`, `fixed_window_consume_or_abort_aborts_when_full`, `cooldown_consume_or_abort_aborts_when_in_cooldown` | — |
| **INV-S1** Bucket capacity bound | ✅ `bucket_starts_full_and_refills_over_time`, `bucket_no_overflow_with_huge_refill_amount`, `bucket_no_overflow_under_extreme_clock_advance` | — | ✅ `bucket_reconfigure_clamps_tokens_to_new_capacity` |
| **INV-S2** FixedWindow capacity bound | ✅ `fixed_window_counts_per_window_and_resets_on_boundary`, `fixed_window_try_consume_max_amount_returns_false` | — | ✅ `fixed_window_reconfigure_clamps_used_to_new_capacity` |
| **INV-S3** Anchor-based window grid | ✅ `fixed_window_first_window_has_full_length_at_nonzero_creation` | — | — |
| **INV-S4** Window monotonicity | ✅ implicit in `fixed_window_counts_per_window_and_resets_on_boundary` | — | — |
| **INV-S5** Bucket refill anchor monotonicity | ✅ implicit in `bucket_preserves_subinterval_time_across_consumes`, `bucket_with_tokens_can_start_empty_and_accrue` | — | — |
| **INV-S6** Fractional time preservation (Bucket) | ✅ `bucket_preserves_subinterval_time_across_consumes` | — | — |
| **INV-S7** All-or-nothing consume | ✅ `bucket_failed_try_consume_does_not_drain_state`, `fixed_window_failed_try_consume_does_not_advance_used`, `cooldown_failed_try_consume_does_not_reset_anchor` | — | — |
| **INV-S8** Cooldown first-fire flexibility | ✅ `cooldown_ignores_amount_value`, `cooldown_available_predicts_try_consume` | — | — |
| **INV-S9** Cooldown last-used monotonicity | ✅ `cooldown_requires_elapsed_time_between_consumes`, `cooldown_reconfigure_preserves_last_used_ms` | — | — |
| **INV-S10** Reconfigure preserves variant | — | ✅ all three `reconfigure_*_on_non_*_aborts` | — |
| **INV-S11** Reconfigure clamps state to new bounds | ✅ `bucket_reconfigure_clamps_tokens_to_new_capacity`, `fixed_window_reconfigure_clamps_used_to_new_capacity` | — | — |
| **INV-S12** Reconfigure accrues under old rules first (Bucket) | ✅ `bucket_reconfigure_accrues_under_old_rate_first` | — | — |
| **INV-S13** Reconfigure rolls forward under old window first (FixedWindow) | ✅ `fixed_window_reconfigure_rolls_under_old_window_first` | — | — |
| **INV-E1** Bucket long-run rate ceiling | ✅ `bucket_starts_full_and_refills_over_time`, `bucket_no_overflow_*` | — | — |
| **INV-E2** FixedWindow per-window cap | ✅ `fixed_window_counts_per_window_and_resets_on_boundary` | — | — |
| **INV-E3** Cooldown minimum gap | ✅ `cooldown_requires_elapsed_time_between_consumes`, `cooldown_reconfigure_preserves_last_used_ms` | — | — |
| **INV-E4** `available()` consistency | ✅ `bucket_available_predicts_try_consume`, `fixed_window_available_predicts_try_consume`, `cooldown_available_predicts_try_consume` | — | — |
| **INV-C1** No global state | 🟡 by absence of global API | — | — |
| **INV-C2** Re-entrant under PTB | 🟡 not unit-testable; see Out of Scope | — | — |

## Test Notes

- **All 43 tests pass under `sui move test`.** Total runtime is dominated by the standard framework startup; no slow tests.
- **u64 boundary values** are written as decimal literals (`18446744073709551615` for `u64::MAX`, `18446744073709551614` for `u64::MAX - 1`) to keep the file standalone — `std::u64::max_value!()` would also work but adds a dependency.
- **Failure-path verification.** For INV-S7, the cleanest pattern is "ask for more than allowed, then ask for exactly the allowed amount and confirm it succeeds." This proves the failure case didn't drain state without needing to reach into private fields.
- **Reconfigure-under-old-rules tests** distinguish the correct behavior from the most plausible bug (using new config retroactively / new `window_ms` for rollover) by choosing config values where the expected and incorrect outcomes differ by a wide margin.
- **Anchor-based window** test is constructed at `t = 99` with `window_ms = 100`. The previous wall-clock-aligned design would have rolled at `t = 100`; the anchored design holds the first window until `t = 199`. The test asserts the anchored behavior at four distinct timestamps to lock in the semantics.
- **Variant-guard priority** is tested by combining a wrong variant with a config that would also trip a config-validation error. Whichever check fires first determines the abort code, and the test fixes that on `EWrongVariant`.

## Out of Scope

- **INV-C2 (Re-entrant under PTB)** — verifying that two `consume_or_abort` calls in a single PTB compose identically to two separate transactions requires testnet/E2E execution, not unit tests. Recorded by the invariants document; deferred to integration tests at the integrating-protocol level.
- **INV-T1, INV-T3, INV-T4 direct verification** — type-level invariants are encoded by abilities and borrow kinds; attempting to violate them produces compile errors, which can't be expressed as `#[test]` functions. The Move compiler is the test.
- **INV-C1 (No global state)** — encoded by the absence of `key` and any global registry. Not directly unit-testable.
- **Concurrency / multi-sender PTB scenarios** — out of scope for a primitive that delegates authorization entirely to the parent's `&mut`; meaningful only when integrated into a parent object whose own access-control model is the unit under test.
- **Fuzzing / property-based long-run tests for INV-E1** — the invariants doc notes "no long-run / fuzzed test exists" for the bucket rate ceiling. Sui Move has no built-in property-testing framework; covered by targeted unit tests at boundaries (extreme refill amount, extreme clock advance) instead.
- **`available()` for `Cooldown` returning `1` vs another sentinel** — Open Question 3 in the invariants document. Today `1` is verified by `cooldown_available_predicts_try_consume`; if the design changes the sentinel, this test must be updated.

## Dev Notes

- **Coverage of the originally-flagged Tests-stage gaps.** Every `MISS-N` flagged in `03-invariants.md § Gaps List` for the Tests stage now has an explicit test (MISS-6, 7, 8, 9, 10, 11, 12, 15). Code-stage MISS-1 through MISS-5 were already resolved; their fixes are exercised by the boundary tests added here (`bucket_no_overflow_*`, `fixed_window_try_consume_max_amount_returns_false`, `fixed_window_first_window_has_full_length_at_nonzero_creation`, `fixed_window_reconfigure_rolls_under_old_window_first`).
- **No deviations from the invariants document.** Tests verify the implementation as currently merged on branch `rate-limiter`; no missing invariants were discovered while writing tests, no boundary conditions needed correction, no API ergonomics issues surfaced.
- **`new_bucket_rejects_capacity_plus_refill_overflow` exercises the implementation's `checked_add` assert.** The invariants document states (Out of Scope, line 624) that "configs only need positivity," but the implementation is stricter: `assert_bucket_config!` also requires `capacity.checked_add(refill_amount).is_some()`. This is a small documentation drift — the runtime check is more restrictive than the invariant statement. Recommend reconciling in a future invariants revision (Open Question; non-blocking).
- **Test naming follows the existing convention** (`{variant}_{behavior}_{condition}`, e.g. `bucket_failed_try_consume_does_not_drain_state`). Section headers (`// === ... ===`) group related tests for readability.
- **`u64::MAX` literal vs `std::u64::max_value!()`** — chose decimal literals for self-containment; either is acceptable. If the team prefers the macro, search for `18446744073709551614` and `18446744073709551615`.

## Open Questions

1. **Should the invariants document's Out of Scope (line 624) be tightened to reflect the `capacity + refill_amount` no-overflow assert?** Current wording says "configs only need positivity"; the implementation requires positivity AND a no-overflow check. Either remove the assert (and rely purely on the two-branch arithmetic) or amend the invariant. Non-blocking — the test pins the current behavior either way.
2. **Should we add an explicit unit test that hammers a Bucket with many small consumes over a long window to spot-check INV-E1's long-run rate ceiling?** Currently bounded by the boundary tests; a fuzz-like loop test is not in scope here but would harden the rate-ceiling guarantee. Recommend: defer to a future hardening pass, or add as a `#[test]` if the team prefers belt-and-suspenders coverage.
3. **No PTB/integration tests are in this file.** Per the workflow's Out of Scope, INV-C2 needs integration-level verification. Tracking expectation: a downstream protocol that embeds the limiter should add a PTB-level scenario test as part of its own test suite.

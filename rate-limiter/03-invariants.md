---
stage: invariants
project: rate-limiter
mode: extension
extends: contracts/utils/sources/rate_limiter.move
status: draft
timestamp: 2026-05-06
author: nenad
previous_stage: null
tags: [rate-limiter, utils, embeddable]
---

# Rate Limiter — Invariants

## Summary

Embeddable rate-limiting primitive (`store + drop`) with three variants — `Bucket`, `FixedWindow`, `Cooldown` — sharing one API. Authorization is delegated entirely to whoever holds `&mut` to the embedded field. This artifact captures 4 type-level, 7 runtime, 13 state-transition, 4 economic, and 2 composability invariants enforced by the implementation. Earlier-flagged u64 overflow paths (MISS-1/2/3) and the `FixedWindow` reconfigure quirk (MISS-5) are resolved in code.

This is a **post-refactor revision** (2026-05-06) reconciling the document with several code refactors:
- `new_bucket_with_tokens` was folded into `new_bucket`, which now takes an `initial_available` argument.
- The `Cooldown` variant tracks `cooldown_end_ms` (the absolute release deadline) instead of `last_used_ms` (the last consume timestamp). `available` (a "remaining" counter) replaces the old `used` (a "consumed" counter) across all variants.
- `roll_window` was inlined into `try_consume` and `reconfigure_fixed_window`.
- The variant-guard precedence in all three `reconfigure_*` paths was made explicit (config asserts run inside the matching arm; the wildcard arm aborts first on wrong variant).

## Type-Level Invariants

### INV-T1: Embeddable, single-owner

**Category:** Type-level

**Statement:** A `RateLimiter` value cannot be a top-level Sui object and cannot be duplicated. It exists only as a field of some parent value.

**Applies to:** the `RateLimiter` enum.

**Enforcement mechanism:**
- Type system: `has drop, store` — explicitly no `key`, no `copy`.
- Runtime check: n/a.
- Test: not directly testable; encoded by abilities.

**Violation scenario:** Two distinct objects share the same limiter state, allowing each to consume the full capacity independently — silent over-issuance.

**Severity:** Critical

---

### INV-T2: Variant exclusivity

**Category:** Type-level

**Statement:** A `RateLimiter` is exactly one of `Bucket | FixedWindow | Cooldown`. The variant is fixed at construction; only the matching `reconfigure_*` accepts it, and reconfigure cannot change the variant.

**Applies to:** all of the public API.

**Enforcement mechanism:**
- Type system: enum `match` is exhaustive.
- Runtime check: `EWrongVariant` aborts in `reconfigure_*` when the variant is wrong (INV-R6).
- Test: [`reconfigure_bucket_on_non_bucket_aborts`](contracts/utils/tests/rate_limiter_tests.move#L238), [`reconfigure_fixed_window_on_non_fixed_window_aborts`](contracts/utils/tests/rate_limiter_tests.move#L251), [`reconfigure_cooldown_on_non_cooldown_aborts`](contracts/utils/tests/rate_limiter_tests.move#L265).

**Violation scenario:** A limiter built as `Cooldown` is reconfigured into a `Bucket`, silently changing the rate-limiting policy without consumer awareness.

**Severity:** High

---

### INV-T3: Read-only `available()`

**Category:** Type-level

**Statement:** `available(&RateLimiter, &Clock)` cannot mutate limiter state.

**Applies to:** [`available`](contracts/utils/sources/rate_limiter.move#L205).

**Enforcement mechanism:**
- Type system: `&RateLimiter` immutable borrow.
- Runtime check: n/a.
- Test: not directly testable; encoded by borrow.

**Violation scenario:** A read path "consumes" capacity, draining the limiter through inspection.

**Severity:** Critical

---

### INV-T4: Mutation requires `&mut`

**Category:** Type-level

**Statement:** All state-changing functions (`try_consume`, `consume_or_abort`, `reconfigure_*`) require `&mut RateLimiter`. Authorization is delegated entirely to the holder of the parent object's `&mut`.

**Applies to:** all hot-path and reconfigure functions.

**Enforcement mechanism:**
- Type system: `&mut` borrow.
- Runtime check: n/a.
- Test: encoded by signatures.

**Violation scenario:** Anyone with a read borrow could consume capacity — would defeat the entire delegation model.

**Severity:** Critical

## Runtime Invariants

### INV-R1: Bucket config positivity and no-overflow

**Category:** Runtime

**Statement:** On `new_bucket` and `reconfigure_bucket`: `capacity > 0 ∧ refill_amount > 0 ∧ refill_interval_ms > 0 ∧ capacity + refill_amount fits in u64`. The `checked_add` requirement is stricter than pure positivity — it bounds away the only addition in `bucket_accrue` whose operands aren't proven ≤ `capacity`.

**Applies to:** `new_bucket`, `reconfigure_bucket`.

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: `assert_bucket_config!` → `EInvalidConfig`.
- Test: [`new_bucket_rejects_zero_capacity`](contracts/utils/tests/rate_limiter_tests.move#L325), [`new_bucket_rejects_zero_refill_amount`](contracts/utils/tests/rate_limiter_tests.move#L338), [`new_bucket_rejects_zero_refill_interval_ms`](contracts/utils/tests/rate_limiter_tests.move#L351), [`new_bucket_rejects_capacity_plus_refill_overflow`](contracts/utils/tests/rate_limiter_tests.move#L364), [`reconfigure_bucket_rejects_zero_capacity`](contracts/utils/tests/rate_limiter_tests.move#L416).

**Violation scenario:** `refill_interval_ms = 0` causes division by zero in `bucket_accrue`. `capacity = 0` makes the bucket permanently empty. `refill_amount = 0` would also divide by zero in `bucket_accrue`'s `headroom / refill_amount`. `capacity + refill_amount` overflow would invalidate the safety argument for the under-fill branch's `available + credit ≤ capacity` upper bound.

**Severity:** Critical

---

### INV-R2: FixedWindow config positivity

**Category:** Runtime

**Statement:** On `new_fixed_window` and `reconfigure_fixed_window`: `capacity > 0 ∧ window_ms > 0`.

**Applies to:** `new_fixed_window`, `reconfigure_fixed_window`.

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: `assert_fixed_window_config!` → `EInvalidConfig`.
- Test: [`new_fixed_window_rejects_zero_capacity`](contracts/utils/tests/rate_limiter_tests.move#L377), [`new_fixed_window_rejects_zero_window_ms`](contracts/utils/tests/rate_limiter_tests.move#L390), [`reconfigure_fixed_window_rejects_zero_window_ms`](contracts/utils/tests/rate_limiter_tests.move#L430).

**Violation scenario:** `window_ms = 0` causes division-by-zero in the `try_consume` window-roll computation. `capacity = 0` makes every consume fail.

**Severity:** Critical

---

### INV-R3: Cooldown config positivity

**Category:** Runtime

**Statement:** On `new_cooldown` and `reconfigure_cooldown`: `capacity > 0 ∧ cooldown_ms > 0`.

**Applies to:** `new_cooldown`, `reconfigure_cooldown`.

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: `assert_cooldown_config!` → `EInvalidConfig`.
- Test: [`new_cooldown_rejects_zero_capacity`](contracts/utils/tests/rate_limiter_tests.move#L409), [`new_cooldown_rejects_zero_cooldown_ms`](contracts/utils/tests/rate_limiter_tests.move#L403), [`reconfigure_cooldown_rejects_zero_cooldown_ms`](contracts/utils/tests/rate_limiter_tests.move#L444).

**Violation scenario:** `cooldown_ms = 0` would make every consume succeed, defeating the purpose of the variant. `capacity = 0` would freeze the limiter forever (no capacity to grant). No upper bound is enforced on `cooldown_ms`; see Operator Responsibilities below for the `now + cooldown_ms` overflow caveat.

**Severity:** High

---

### INV-R4: Initial available bounded (Bucket)

**Category:** Runtime

**Statement:** On `new_bucket`: `initial_available ≤ capacity`. This is the knob that lets integrators start a bucket empty (forces a pre-roll wait) or partly full.

**Applies to:** [`new_bucket`](contracts/utils/sources/rate_limiter.move#L95).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: [`assert!(initial_available <= capacity, EInvalidConfig)`](contracts/utils/sources/rate_limiter.move#L103).
- Test: [`bucket_with_tokens_rejects_initial_above_capacity`](contracts/utils/tests/rate_limiter_tests.move#L57), [`bucket_with_tokens_can_start_empty_and_accrue`](contracts/utils/tests/rate_limiter_tests.move#L38).

**Violation scenario:** Bucket starts above its own capacity, violating INV-S1 from the very first call.

**Severity:** Critical

---

### INV-R5: Non-zero consume amount

**Category:** Runtime

**Statement:** `try_consume(amount, ..)` requires `amount > 0`. Zero is treated as a programmer error, not a rate-limit condition. (For `Cooldown`, `available` decrements by exactly 1 per call regardless of `amount` — see INV-S8 — so zero would be especially confusing if it were silently accepted.)

**Applies to:** [`try_consume`](contracts/utils/sources/rate_limiter.move#L152), [`consume_or_abort`](contracts/utils/sources/rate_limiter.move#L144).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: [`assert!(amount > 0, EInvalidAmount)`](contracts/utils/sources/rate_limiter.move#L153).
- Test: [`try_consume_with_zero_amount_aborts`](contracts/utils/tests/rate_limiter_tests.move#L223).

**Violation scenario:** Behavior on zero would diverge across variants (Bucket: trivially succeeds; FixedWindow: succeeds without changing `available`; Cooldown: still gates and decrements by 1), making the API non-uniform.

**Severity:** Medium

---

### INV-R6: Variant guard on reconfigure

**Category:** Runtime

**Statement:** `reconfigure_bucket` aborts on non-`Bucket`, `reconfigure_fixed_window` aborts on non-`FixedWindow`, `reconfigure_cooldown` aborts on non-`Cooldown`. Variant check has priority over config validation: a wrong-variant call always aborts with `EWrongVariant`, even when the supplied config would also be invalid.

**Applies to:** all `reconfigure_*` functions.

**Enforcement mechanism:**
- Type system: n/a (could be enforced with separate types, but the enum design rejects that).
- Runtime check: `assert_*_config!` is invoked *inside* the matching arm, so the wildcard `_ => abort EWrongVariant` arm fires first on wrong variant.
- Test: [`reconfigure_bucket_on_non_bucket_aborts`](contracts/utils/tests/rate_limiter_tests.move#L238), [`reconfigure_fixed_window_on_non_fixed_window_aborts`](contracts/utils/tests/rate_limiter_tests.move#L251), [`reconfigure_cooldown_on_non_cooldown_aborts`](contracts/utils/tests/rate_limiter_tests.move#L265), plus three priority tests at L279/L295/L309.

**Violation scenario:** A `Cooldown` reconfigured via `reconfigure_bucket` would silently change variant — see INV-T2.

**Severity:** High

---

### INV-R7: `consume_or_abort` failure semantics

**Category:** Runtime

**Statement:** `consume_or_abort(amount, clk)` aborts with `ERateLimited` iff `try_consume(amount, clk)` would return `false` for the same arguments and state.

**Applies to:** [`consume_or_abort`](contracts/utils/sources/rate_limiter.move#L144).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: implementation literally calls `try_consume` and asserts.
- Test: [`bucket_consume_or_abort_aborts_when_empty`](contracts/utils/tests/rate_limiter_tests.move#L84), [`fixed_window_consume_or_abort_aborts_when_full`](contracts/utils/tests/rate_limiter_tests.move#L775), [`cooldown_consume_or_abort_aborts_when_in_cooldown`](contracts/utils/tests/rate_limiter_tests.move#L789).

**Violation scenario:** Consumers couldn't predict whether to use `try_consume` or `consume_or_abort` — the latter would diverge from the former.

**Severity:** Medium

## State Transition Invariants

### INV-S1: Bucket capacity bound

**Category:** State transition

**Statement:** For any `Bucket` reachable through the public API, `available ≤ capacity` after every operation.

**Applies to:** all `Bucket` state mutations.

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: [`bucket_accrue`](contracts/utils/sources/rate_limiter.move#L371) returns `available + credit ≤ capacity` in the under-fill branch (proved via `credit ≤ headroom`) and writes `capacity` directly in the fill branch; `try_consume` only deducts after `new_available ≥ amount`; `reconfigure_bucket` clamps `new_available.min(capacity)`.
- Test: [`bucket_starts_full_and_refills_over_time`](contracts/utils/tests/rate_limiter_tests.move#L12), [`bucket_reconfigure_clamps_tokens_to_new_capacity`](contracts/utils/tests/rate_limiter_tests.move#L97), [`bucket_no_overflow_with_huge_refill_amount`](contracts/utils/tests/rate_limiter_tests.move#L636), [`bucket_no_overflow_under_extreme_clock_advance`](contracts/utils/tests/rate_limiter_tests.move#L655).

**Violation scenario:** `available > capacity` would let a bucket burst past its configured maximum after a long idle period.

**Severity:** Critical

---

### INV-S2: FixedWindow capacity bound

**Category:** State transition

**Statement:** For any `FixedWindow` reachable through the public API, `available ≤ capacity` after every operation.

**Applies to:** all `FixedWindow` state mutations.

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: `amount > available` short-circuits before decrementing (subtraction-form, no overflow); window roll resets `available = capacity`; `reconfigure_fixed_window` does `available.min(new_capacity)`.
- Test: [`fixed_window_counts_per_window_and_resets_on_boundary`](contracts/utils/tests/rate_limiter_tests.move#L117), [`fixed_window_reconfigure_clamps_available_to_new_capacity`](contracts/utils/tests/rate_limiter_tests.move#L858), [`fixed_window_try_consume_max_amount_returns_false`](contracts/utils/tests/rate_limiter_tests.move#L674).

**Violation scenario:** Per-window cap is exceeded; INV-E2 fails.

**Severity:** Critical

---

### INV-S3: Anchor-based window grid

**Category:** State transition

**Statement:** Windows are anchored at the limiter's creation time, not at wall-clock multiples of `window_ms`. After construction, `window_start_ms = creation_ms`; thereafter `window_start_ms` advances only by integer multiples of the *current* `window_ms` (via the inline window-roll computation in `try_consume` and `reconfigure_fixed_window`). Consequence: at any point, `window_start_ms = anchor + k * window_ms` for some `k ≥ 0`, where `anchor` is the creation timestamp under the original `window_ms` (or, after a `reconfigure_fixed_window`, the position rolled forward under the previous `window_ms`).

`reconfigure_fixed_window` first runs the window-roll under the OLD `window_ms` (preserving INV-S13), then installs the new config; subsequent advances use the new `window_ms` from the rolled-forward anchor.

**Applies to:** `FixedWindow`.

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: construction sets `window_start_ms = clock.timestamp_ms()` (no wall-clock alignment). The advance computation `let steps = (now - window_start_ms) / window_ms; if steps != 0 { window_start_ms += steps * window_ms; available = capacity }` is inlined identically in `try_consume` and `reconfigure_fixed_window` (with the latter using the current `window_ms` *before* it is overwritten).
- Test: [`fixed_window_first_window_has_full_length_at_nonzero_creation`](contracts/utils/tests/rate_limiter_tests.move#L693).

**Violation scenario:** A wall-clock-aligned design (the previous behavior) makes the first window arbitrarily short — if the limiter is created at `t = 99` with `window_ms = 100`, the first window is only 1 ms long. The anchored design guarantees every window has length exactly `window_ms`. Misaligning `window_start_ms` (e.g. by setting it to a value that isn't `anchor + k * window_ms`) would let an attacker reset `available` more frequently than once per `window_ms`, exceeding INV-E2.

**Severity:** High

---

### INV-S4: Window monotonicity

**Category:** State transition

**Statement:** `window_start_ms` is non-decreasing across `try_consume` and `reconfigure_fixed_window` calls.

**Applies to:** [`FixedWindow`](contracts/utils/sources/rate_limiter.move#L66).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: the inline advance is `steps * window_ms` where `steps = (now - window_start_ms) / window_ms ≥ 0`, and it is only written when `steps > 0`. Both `try_consume` and `reconfigure_fixed_window` use this pattern; neither moves `window_start_ms` backward.
- Test: implicit in [`fixed_window_counts_per_window_and_resets_on_boundary`](contracts/utils/tests/rate_limiter_tests.move#L117), [`fixed_window_reconfigure_rolls_under_old_window_first`](contracts/utils/tests/rate_limiter_tests.move#L575).

**Violation scenario:** Going backward inside `try_consume` would re-enter a window where capacity has already been spent.

**Severity:** High

---

### INV-S5: Bucket refill anchor monotonicity

**Category:** State transition

**Statement:** `last_refill_ms` is non-decreasing across `try_consume` and `reconfigure_bucket`.

**Applies to:** [`Bucket`](contracts/utils/sources/rate_limiter.move#L57).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: `bucket_accrue` returns the original `last_refill_ms` on `elapsed_steps == 0`; otherwise advances by `steps * refill_interval_ms ≥ 0`. The Sui `Clock` is monotonic, so `now - last_refill_ms` does not underflow.
- Test: implicit in [`bucket_preserves_subinterval_time_across_consumes`](contracts/utils/tests/rate_limiter_tests.move#L528), [`bucket_with_tokens_can_start_empty_and_accrue`](contracts/utils/tests/rate_limiter_tests.move#L38).

**Violation scenario:** A backward `last_refill_ms` would re-credit already-credited intervals.

**Severity:** Critical

---

### INV-S6: Fractional time preservation (Bucket)

**Category:** State transition

**Statement:** After accrual, `last_refill_ms ≡ original_last_refill_ms (mod refill_interval_ms)`. Sub-interval time elapsed but not yet credited is never discarded — it accrues toward the next step.

**Applies to:** `bucket_accrue`.

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: advance is always `steps * refill_interval_ms` where `steps` is an integer step count (either `elapsed_steps` in the under-fill branch, or `q`/`q+1` in the fill-to-capacity branch). In every case, `last_refill_ms ≡ original (mod refill_interval_ms)`.
- Test: [`bucket_preserves_subinterval_time_across_consumes`](contracts/utils/tests/rate_limiter_tests.move#L528).

**Violation scenario:** If implemented as `last_refill_ms = now`, a caller spamming consumes faster than `refill_interval_ms` would forfeit fractional time on every call, dramatically reducing the effective refill rate.

**Severity:** High

---

### INV-S7: All-or-nothing consume

**Category:** State transition

**Statement:** When `try_consume` returns `false`, the limiter's logical state is unchanged from before the call. Internal accrual / window-roll computations may have run, but no capacity has been deducted and (in the failure path) no anchors have been written.

**Applies to:** [`try_consume`](contracts/utils/sources/rate_limiter.move#L152).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: each variant arm returns `false` *before* mutating state on the failure path. Bucket: `if (new_available < amount) return false` *before* writing `*last_refill_ms` or `*available`. FixedWindow: window-roll writes occur first (when applicable), but the failure branch `if (amount > *available) return false` doesn't decrement `available`. Cooldown: `if (now < *cooldown_end_ms) return false` *before* the `*available = *capacity` reset.
- Test: [`bucket_failed_try_consume_does_not_drain_state`](contracts/utils/tests/rate_limiter_tests.move#L460), [`fixed_window_failed_try_consume_does_not_advance_used`](contracts/utils/tests/rate_limiter_tests.move#L483), [`cooldown_failed_try_consume_does_not_reset_anchor`](contracts/utils/tests/rate_limiter_tests.move#L504).

**Note:** For `FixedWindow`, the inline window-roll *does* persist the new `window_start_ms` and reset `available = capacity` even if the subsequent `amount > available` check fails. This is deliberate and consistent with `available()`'s read-only semantics in spirit: once time has crossed a window boundary, the new window has begun, regardless of whether a consume succeeds inside it. It does not violate INV-S7 because the per-window cap (INV-E2) is unchanged: the new window legitimately starts with `available = capacity`.

**Severity:** High

---

### INV-S8: Cooldown grant/gate state machine

**Category:** State transition

**Statement:** A `Cooldown` is in one of two logical states:
- **Granted:** `available > 0` — the next `try_consume(amount > 0, _)` succeeds and decrements `available` by exactly 1 (the `amount` value is irrelevant beyond the `> 0` check). At construction `available = capacity`, so the limiter starts in this state.
- **Gated:** `available == 0` — `try_consume` returns `false` until `now ≥ cooldown_end_ms`, at which point a single call resets `available = capacity` and consumes (transitioning back to Granted, with `available = capacity - 1`).

`cooldown_end_ms` is a don't-care field while `available > 0`; it is only read in the Gated state. Initial value `0` is therefore safe — it is never observed before being written.

**Applies to:** [`Cooldown`](contracts/utils/sources/rate_limiter.move#L80).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: `try_consume` Cooldown arm in [rate_limiter.move:186-197](contracts/utils/sources/rate_limiter.move#L186-L197) — `if (*available == 0) { if (now < *cooldown_end_ms) return false; *available = *capacity }`, then unconditional `*available = *available - 1`, then arm `*cooldown_end_ms = now + *cooldown_ms` only when the decrement reaches 0.
- Test: [`cooldown_accumulates_used_until_capacity_then_gates`](contracts/utils/tests/rate_limiter_tests.move#L173), [`cooldown_amount_does_not_affect_used`](contracts/utils/tests/rate_limiter_tests.move#L203), [`cooldown_available_predicts_try_consume`](contracts/utils/tests/rate_limiter_tests.move#L757).

**Violation scenario:** Reading `cooldown_end_ms` while in the Granted state would gate spuriously on a fresh limiter (since `cooldown_end_ms = 0` initially). The current code only reads it inside the `available == 0` branch, so this is structurally avoided.

**Severity:** High

---

### INV-S9: Cooldown deadline monotonicity

**Category:** State transition

**Statement:** Once `cooldown_end_ms` is armed (set by a consume that drains `available` to 0), no subsequent `try_consume` succeeds until `now ≥ cooldown_end_ms`. After release, the next `cooldown_end_ms` (armed by the next drain to 0) is `≥ now ≥ previous cooldown_end_ms`. `cooldown_end_ms` therefore is non-decreasing across successful consumes that drain the limiter.

**Applies to:** [`Cooldown`](contracts/utils/sources/rate_limiter.move#L80).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: gate `now ≥ cooldown_end_ms` is required for success while `available == 0`. Each fresh `cooldown_end_ms` is set as `now + cooldown_ms`, where `now` is the current monotonic chain timestamp.
- Test: [`cooldown_requires_elapsed_time_between_consumes`](contracts/utils/tests/rate_limiter_tests.move#L146), [`cooldown_failed_try_consume_does_not_reset_anchor`](contracts/utils/tests/rate_limiter_tests.move#L504).

**Violation scenario:** Backward `cooldown_end_ms` would collapse the gate.

**Severity:** High

---

### INV-S10: Reconfigure preserves variant

**Category:** State transition

**Statement:** No reconfigure path changes which variant the limiter is. To switch variant, the integrator must construct a fresh `RateLimiter` and overwrite the field.

**Applies to:** all `reconfigure_*` functions.

**Enforcement mechanism:**
- Type system: every reconfigure arm matches exactly one variant; the wildcard branch aborts.
- Runtime check: `EWrongVariant` (INV-R6).
- Test: covered by all three `reconfigure_*_on_non_*_aborts` tests at L238/L251/L265.

**Violation scenario:** Silent variant change — a `Bucket` becomes a `Cooldown` mid-flight, completely changing the semantics of `consume`.

**Severity:** Critical

---

### INV-S11: Reconfigure clamps state to new bounds

**Category:** State transition

**Statement:** When capacity shrinks: `reconfigure_bucket` clamps `available.min(new_capacity)`; `reconfigure_fixed_window` clamps `available.min(new_capacity)`; `reconfigure_cooldown` clamps `available.min(new_capacity)`. INV-S1, INV-S2, and INV-S8's `available ≤ capacity` discipline hold post-reconfigure.

**Applies to:** [`reconfigure_bucket`](contracts/utils/sources/rate_limiter.move#L244), [`reconfigure_fixed_window`](contracts/utils/sources/rate_limiter.move#L284), [`reconfigure_cooldown`](contracts/utils/sources/rate_limiter.move#L324).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: `.min(capacity)` in all three reconfigure paths.
- Test: [`bucket_reconfigure_clamps_tokens_to_new_capacity`](contracts/utils/tests/rate_limiter_tests.move#L97), [`fixed_window_reconfigure_clamps_available_to_new_capacity`](contracts/utils/tests/rate_limiter_tests.move#L858), [`cooldown_reconfigure_clamps_available_to_new_capacity`](contracts/utils/tests/rate_limiter_tests.move#L805).

**Violation scenario:** `available > new_capacity` would let a Bucket / FixedWindow / Cooldown burst above its new ceiling immediately after reconfigure.

**Severity:** Critical

---

### INV-S12: Reconfigure accrues under old rules first (Bucket)

**Category:** State transition

**Statement:** `reconfigure_bucket` applies the *previous* `refill_amount`/`refill_interval_ms` to all elapsed time before the new config takes effect. The new rate applies only to time after the reconfigure.

**Applies to:** [`reconfigure_bucket`](contracts/utils/sources/rate_limiter.move#L244).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: `bucket_accrue` is called with the *current* config fields (`*cap_field`, `*refill_amount_field`, `*refill_interval_field`) *before* they are overwritten with the new config.
- Test: [`bucket_reconfigure_accrues_under_old_rate_first`](contracts/utils/tests/rate_limiter_tests.move#L553).

**Violation scenario:** Retroactively applying a new rate would let an operator backdate increased capacity, violating economic invariants for the past period.

**Severity:** High

---

### INV-S13: Reconfigure rolls forward under old window first (FixedWindow)

**Category:** State transition

**Statement:** `reconfigure_fixed_window` advances `window_start_ms` and resets `available = new_capacity` according to the *previous* `window_ms` (any number of full old-window steps that have elapsed) *before* the new `window_ms` is installed. The new window grid then anchors at the rolled-forward `window_start_ms`.

**Applies to:** `reconfigure_fixed_window`.

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: the inline window-roll computation reads `*window_field` (the OLD `window_ms`) for `steps = (now - *window_start_ms) / *window_field`, then writes `*window_start_ms += steps * *window_field` — both *before* the new `window_ms` overwrites `*window_field`.
- Test: [`fixed_window_reconfigure_rolls_under_old_window_first`](contracts/utils/tests/rate_limiter_tests.move#L575).

**Violation scenario:** Using the new `window_ms` for the rollover decision (the previous bug) could move `window_start_ms` backward when widening, carrying old-window usage into a wider new window — letting a fresh wider window admit only `new_capacity - used_under_old_window` of its budget on the first turn after reconfigure, surprising integrators and potentially breaking INV-E2's spirit across the reconfigure boundary.

**Severity:** High

## Economic / Protocol Invariants

### INV-E1: Bucket long-run rate ceiling

**Category:** Economic

**Statement:** Over any interval `Δt`, the maximum number of tokens consumable from a `Bucket` is at most `capacity + ⌊Δt / refill_interval_ms⌋ * refill_amount`. The bucket cannot generate value out of thin air.

**Applies to:** `Bucket` lifecycle.

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: implied by INV-S1 + accrual formula.
- Test: covered partially by [`bucket_starts_full_and_refills_over_time`](contracts/utils/tests/rate_limiter_tests.move#L12), [`bucket_no_overflow_with_huge_refill_amount`](contracts/utils/tests/rate_limiter_tests.move#L636), [`bucket_no_overflow_under_extreme_clock_advance`](contracts/utils/tests/rate_limiter_tests.move#L655). No long-run / fuzzed test exists.

**Violation scenario:** Over-issuance — the central economic guarantee a rate limiter exists to provide. The previously reachable overflow paths (MISS-1, MISS-2) are now closed.

**Severity:** Critical

---

### INV-E2: FixedWindow per-window cap

**Category:** Economic

**Statement:** No more than `capacity` units consumed within any `[anchor + k·window_ms, anchor + (k+1)·window_ms)` window, where `anchor` is determined by INV-S3.

**Applies to:** `FixedWindow` lifecycle.

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: implied by INV-S2 + INV-S3 + INV-S4.
- Test: [`fixed_window_counts_per_window_and_resets_on_boundary`](contracts/utils/tests/rate_limiter_tests.move#L117), [`fixed_window_first_window_has_full_length_at_nonzero_creation`](contracts/utils/tests/rate_limiter_tests.move#L693).

**Violation scenario:** Per-window cap exceeded. The previously reachable overflow path (MISS-3) is now closed.

**Severity:** Critical

---

### INV-E3: Cooldown minimum gap

**Category:** Economic

**Statement:** When `Cooldown` transitions from Gated back to Granted (i.e. a successful consume after the gate was armed), at least `cooldown_ms` (the value at the time the gate was armed) has elapsed since the consume that armed the gate.

**Applies to:** `Cooldown` lifecycle.

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: gate `now ≥ cooldown_end_ms` in `try_consume`, where `cooldown_end_ms = arming_now + cooldown_ms_at_arming_time`.
- Test: [`cooldown_requires_elapsed_time_between_consumes`](contracts/utils/tests/rate_limiter_tests.move#L146), [`cooldown_reconfigure_preserves_in_flight_deadline`](contracts/utils/tests/rate_limiter_tests.move#L600).

**Violation scenario:** Cooldown can be bypassed, defeating throttling for the variant.

**Severity:** Critical

---

### INV-E4: `available()` consistency

**Category:** Economic

**Statement:** If `available(&clk) ≥ amount` and no clock change or other call intervenes, then `try_consume(amount, &clk)` returns `true`. For `Cooldown`, `available` is "number of consecutive `try_consume` calls that will succeed before the gate arms" — so `available == N` ⇒ exactly `N` successive `try_consume(_, &clk)` calls succeed before the gate engages, regardless of `amount`.

**Applies to:** [`available`](contracts/utils/sources/rate_limiter.move#L205), [`try_consume`](contracts/utils/sources/rate_limiter.move#L152).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: same accrual / window-roll / gate logic in both functions.
- Test: [`bucket_available_predicts_try_consume`](contracts/utils/tests/rate_limiter_tests.move#L725), [`fixed_window_available_predicts_try_consume`](contracts/utils/tests/rate_limiter_tests.move#L741), [`cooldown_available_predicts_try_consume`](contracts/utils/tests/rate_limiter_tests.move#L757).

**Violation scenario:** Read-then-act consumers see ghost capacity that vanishes on the actual call.

**Severity:** High

## Composability Invariants

### INV-C1: No global state

**Category:** Composability

**Statement:** A `RateLimiter` requires no shared object, no registry, and no PTB ordering. Its scope is the parent value that owns it.

**Applies to:** entire module.

**Enforcement mechanism:**
- Type system: `store + drop`, no `key`.
- Runtime check: n/a.
- Test: not directly testable; encoded by absence of global API.

**Violation scenario:** Coupling between integrators using the limiter — one consumer's actions affecting another's quota.

**Severity:** Critical (for the design's central premise)

---

### INV-C2: Re-entrant under PTB

**Category:** Composability

**Statement:** Multiple `consume_*` calls in a single PTB compose naturally. Each call independently re-reads the clock and updates state. There is no transaction-scoped accumulator.

**Applies to:** [`try_consume`](contracts/utils/sources/rate_limiter.move#L152), [`consume_or_abort`](contracts/utils/sources/rate_limiter.move#L144).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: every call uses `clock.timestamp_ms()` afresh; state is only the embedded fields.
- Test: PTB-level testing not in scope of this module's unit tests.

**Violation scenario:** Bundling two consumes in a single PTB would behave differently from the same calls split across two PTBs — surprising and integration-hostile.

**Severity:** High

## Existing Invariants (Extension Mode)

This is an extension-mode artifact — invariants were extracted from the merged implementation on branch `rate-limiter`. There are no pre-existing invariants to preserve or modify.

### Preserved
None — first invariants pass on this module.

### Modified
None.

### New
All invariants in this artifact.

## Invariant Coverage Matrix

| Function | Invariants | Enforcement |
|----------|-----------|-------------|
| `new_bucket` | INV-T1, INV-T2, INV-R1, INV-R4, INV-S1, INV-S5 | Type + Runtime |
| `new_fixed_window` | INV-T1, INV-T2, INV-R2, INV-S2, INV-S3 | Type + Runtime |
| `new_cooldown` | INV-T1, INV-T2, INV-R3, INV-S8 | Type + Runtime |
| `try_consume` | INV-T4, INV-R5, INV-S1, INV-S2, INV-S3, INV-S4, INV-S5, INV-S6, INV-S7, INV-S8, INV-S9, INV-E1, INV-E2, INV-E3, INV-C2 | Type + Runtime |
| `consume_or_abort` | INV-T4, INV-R5, INV-R7 + all of `try_consume` | Type + Runtime |
| `available` | INV-T3, INV-E4 | Type only |
| `reconfigure_bucket` | INV-T4, INV-R1, INV-R6, INV-S5, INV-S10, INV-S11, INV-S12 | Type + Runtime |
| `reconfigure_fixed_window` | INV-T4, INV-R2, INV-R6, INV-S2, INV-S3, INV-S4, INV-S10, INV-S11, INV-S13 | Type + Runtime |
| `reconfigure_cooldown` | INV-T4, INV-R3, INV-R6, INV-S8, INV-S10, INV-S11 | Type + Runtime |

## Operator Responsibilities (Out of Scope for the module)

- **Cooldown deadline overflow.** `try_consume` for `Cooldown` computes `cooldown_end_ms = now + cooldown_ms`. Sui's `Clock` is monotonic and bounded well below `u64::MAX`, but `cooldown_ms` near `u64::MAX` would overflow this addition. Operators must pick `cooldown_ms` such that `now + cooldown_ms` cannot overflow at any plausible chain timestamp during the limiter's lifetime — any policy-meaningful value (seconds to days to years in ms) satisfies this trivially. The module enforces only positivity (INV-R3); no upper-bound assert is added because there is no useful `u64` ceiling that captures "policy-reasonable."
- **Clock authenticity.** The module trusts `&Clock`; it does not defend against a malicious shared-clock substitute (Sui's `Clock` is a singleton shared object, so this is a Sui-platform property).
- **Authorization / access control inside the module.** Delegated to the parent object holding the field (INV-T4). The module makes no claim about who *should* be allowed to call `&mut` paths.

## Out of Scope

- **Global / cross-limiter rate guarantees.** Each limiter is independent; no cross-limiter aggregate cap. Out of scope by design (INV-C1).
- **Persistence of `RateLimiter` across object lifecycles.** When the parent object is destroyed, the limiter is dropped (`has drop`). Out of scope: any "frozen state" or "transferable consumption history" use case.

## Dev Notes

- **Authorization model is the central design decision.** The limiter delegates 100% of access control to the holder of `&mut` to the parent field. This is what makes the primitive embeddable, registry-less, and PTB-friendly. Any future "shared rate limiter" feature would require fundamentally different primitives.
- **Clock is assumed monotonic.** Sui's `Clock` is monotonic in practice; the module relies on this and uses `now - last_*` directly. If `now < last_*` ever held, the subtraction would underflow and abort — this is a fail-closed posture rather than a silent absorption.
- **Overflow surfaces closed by implementation, not config bounds.** `bucket_accrue`'s two-branch structure bounds every intermediate product and sum by `capacity` (no upper bound on `capacity` or `refill_amount` required beyond `checked_add`). FixedWindow's hot-path comparison (`amount > capacity - available`) uses subtraction so no addition can overflow. Cooldown is the one exception (`now + cooldown_ms`); operators handle it (see Operator Responsibilities).
- **Anchor-based windows.** `FixedWindow` windows are `[creation + k * window_ms, creation + (k+1) * window_ms)`. The first window always has length exactly `window_ms` (in the previous wall-clock-aligned design it could be arbitrarily short). On `reconfigure_fixed_window`, the new window grid anchors at the rolled-forward `window_start_ms` under the OLD `window_ms`.
- **Cooldown stores `available` and `cooldown_end_ms`, not `used` and `last_used_ms`.** The current design tracks remaining capacity directly and stores the absolute release deadline; the gate predicate is `now < cooldown_end_ms`. This is symmetric with the other variants' `available` field.

## Open Questions

1. ~~**Should the overflow paths (MISS-1/2/3) be fixed with saturating arithmetic, with explicit upper-bound asserts on config, or both?**~~ **Resolved (2026-05-06):** neither — `bucket_accrue` was rewritten so all products and sums are bounded by `capacity`, and `try_consume` comparisons were reformulated as subtraction. Configs need positivity plus the `capacity + refill_amount` no-overflow check (Bucket).
2. ~~**Is the FixedWindow "widening absorbs prior usage" behavior (MISS-5) intended?**~~ **Resolved (2026-05-06):** windows are now anchored at creation time (INV-S3); `reconfigure_fixed_window` rolls forward under the OLD `window_ms` before installing the new config, never moves `window_start_ms` backward.
3. **Should `available()` for `Cooldown` while in the Gated state but post-deadline return `capacity` or something else?** Today it returns `capacity` (the full grant the next consume will receive). This matches the INV-E4 statement.
4. **Should the variant guard pattern (`reconfigure_bucket` aborts on non-Bucket) be replaced with a "reconfigure_or_replace" that always works by overwriting?** Probably no — the abort makes the integrator's intent explicit. But worth noting as an alternative.

## Gaps List (referenced by Dev Notes and Open Questions)

| ID | Severity | Stage to fix | Description |
|---|---|---|---|
| MISS-1 | Critical | Code Draft | ✅ **Resolved.** `bucket_accrue` rewritten with two branches: under-fill (`elapsed_steps ≤ q`) bounds `elapsed_steps * refill_amount ≤ headroom ≤ capacity`; fill (`elapsed_steps > q`) writes `capacity` directly. No intermediate sum can exceed `capacity`. |
| MISS-2 | Critical | Code Draft | ✅ **Resolved.** Follows from MISS-1 fix: `available + credit ≤ capacity` in the under-fill branch; the fill branch never computes the sum. |
| MISS-3 | Critical | Code Draft | ✅ **Resolved.** `try_consume` for `FixedWindow` now uses `amount > *available` directly (and the prior-formulation overflow risk no longer exists since `available` already encodes "remaining"). |
| MISS-4 | Low | Code Draft | ✅ **Resolved (and reframed).** Cooldown gate is now `now < cooldown_end_ms` (`cooldown_end_ms` set as `now + cooldown_ms`). The prior `now - last < cooldown_ms` subtraction-form is no longer applicable. Operators handle the `now + cooldown_ms` overflow (see Operator Responsibilities). |
| MISS-5 | High | Code Draft | ✅ **Resolved.** `reconfigure_fixed_window` now uses the inline window-roll under the OLD `window_ms` *before* installing the new config. Window grid is anchored to creation time (INV-S3). |
| MISS-6 | Medium | Tests | ✅ **Resolved.** [`bucket_failed_try_consume_does_not_drain_state`](contracts/utils/tests/rate_limiter_tests.move#L460), [`fixed_window_failed_try_consume_does_not_advance_used`](contracts/utils/tests/rate_limiter_tests.move#L483), [`cooldown_failed_try_consume_does_not_reset_anchor`](contracts/utils/tests/rate_limiter_tests.move#L504). |
| MISS-7 | Medium | Tests | ✅ **Resolved.** [`bucket_preserves_subinterval_time_across_consumes`](contracts/utils/tests/rate_limiter_tests.move#L528). |
| MISS-8 | Medium | Tests | ✅ **Resolved.** [`bucket_reconfigure_accrues_under_old_rate_first`](contracts/utils/tests/rate_limiter_tests.move#L553), [`fixed_window_reconfigure_rolls_under_old_window_first`](contracts/utils/tests/rate_limiter_tests.move#L575). |
| MISS-9 | Medium | Tests | ✅ **Resolved.** [`cooldown_reconfigure_preserves_in_flight_deadline`](contracts/utils/tests/rate_limiter_tests.move#L600), [`cooldown_reconfigure_rearms_when_drained_and_deadline_elapsed`](contracts/utils/tests/rate_limiter_tests.move#L823). |
| MISS-10 | Medium | Tests | ✅ **Resolved.** All three `reconfigure_*_on_non_*_aborts` tests at L238/L251/L265, plus the variant-priority tests at L279/L295/L309. |
| MISS-11 | Critical | Tests | ✅ **Resolved.** [`bucket_no_overflow_with_huge_refill_amount`](contracts/utils/tests/rate_limiter_tests.move#L636), [`bucket_no_overflow_under_extreme_clock_advance`](contracts/utils/tests/rate_limiter_tests.move#L655). |
| MISS-12 | Critical | Tests | ✅ **Resolved.** [`fixed_window_try_consume_max_amount_returns_false`](contracts/utils/tests/rate_limiter_tests.move#L674). |
| MISS-13 | Low | Docs | ✅ **Resolved.** Module-level doc comment now states the operator's `cooldown_ms` overflow responsibility; clock-monotonic assumption documented in Dev Notes. |
| MISS-14 | Low | Docs | ✅ **Resolved.** Module-level doc and INV-T4 / INV-C1 call out the delegated authorization model. |
| MISS-15 | Medium | Tests | ✅ **Resolved.** [`fixed_window_first_window_has_full_length_at_nonzero_creation`](contracts/utils/tests/rate_limiter_tests.move#L693). |

## Revision Log

**2026-05-06 (post-refactor reconciliation)** — Document re-aligned with the merged implementation after a series of code refactors. Key reconciliations:

- `new_bucket_with_tokens` removed; `new_bucket` now takes an `initial_available` argument. INV-R4 rewritten accordingly.
- `Cooldown` field renames: `last_used_ms` → `cooldown_end_ms` (with inverted semantics — absolute deadline rather than last-consume timestamp); `used` → `available` (a remaining counter). INV-S8 / INV-S9 / INV-E3 rewritten; INV-S11 extended to cover the Cooldown clamp; INV-S8 now describes the two-state (Granted / Gated) machine.
- `roll_window` helper inlined into `try_consume` and `reconfigure_fixed_window`. INV-S3 / INV-S4 / INV-S13 enforcement language updated.
- `assert_cooldown_config!` requires `capacity > 0` in addition to `cooldown_ms > 0`. INV-R3 statement extended.
- INV-R1 statement now includes the `checked_add` overflow guard alongside positivity.
- INV-S7 now documents the `FixedWindow` window-roll persistence on the failure path explicitly (the roll is observable, but does not violate INV-E2 because the new window legitimately starts with full capacity).
- Test names and line numbers updated throughout the coverage matrix to match [`rate_limiter_tests.move`](contracts/utils/tests/rate_limiter_tests.move) as of 2026-05-06.
- New section **Operator Responsibilities** captures the `cooldown_ms` overflow caveat that the module deliberately does not enforce.
- All `MISS-N` entries from the Tests stage are now marked resolved with test references; `MISS-13` and `MISS-14` (docs) are resolved by the module-level doc comment update.

**2026-05-06 (initial code-stage fixes)** — Code-stage fixes applied to resolve MISS-1, MISS-2, MISS-3, MISS-4, MISS-5. Summary preserved in Open Questions 1 and 2.

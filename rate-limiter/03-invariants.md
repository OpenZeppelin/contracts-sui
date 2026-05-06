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

Embeddable rate-limiting primitive (`store + drop`) with three variants — `Bucket`, `FixedWindow`, `Cooldown` — sharing one API. Authorization is delegated entirely to whoever holds `&mut` to the embedded field. This artifact captures 4 type-level, 7 runtime, 13 state-transition, 4 economic, and 2 composability invariants extracted from the existing implementation, plus 14 gaps (3 critical: u64 overflow paths in `Bucket` accrual and `FixedWindow` consume).

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
- Test: [`reconfigure_bucket_on_non_bucket_aborts`](contracts/utils/tests/rate_limiter_tests.move#L203). Missing for `reconfigure_fixed_window` and `reconfigure_cooldown` (MISS-10).

**Violation scenario:** A limiter built as `Cooldown` is reconfigured into a `Bucket`, silently changing the rate-limiting policy without consumer awareness.

**Severity:** High

---

### INV-T3: Read-only `available()`

**Category:** Type-level

**Statement:** `available(&RateLimiter, &Clock)` cannot mutate limiter state.

**Applies to:** [`available`](contracts/utils/sources/rate_limiter.move#L186).

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

### INV-R1: Bucket config positivity

**Category:** Runtime

**Statement:** On `new_bucket*` and `reconfigure_bucket`: `capacity > 0 ∧ refill_amount > 0 ∧ refill_interval_ms > 0`.

**Applies to:** [`new_bucket`](contracts/utils/sources/rate_limiter.move#L72), [`new_bucket_with_tokens`](contracts/utils/sources/rate_limiter.move#L86), [`reconfigure_bucket`](contracts/utils/sources/rate_limiter.move#L222).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: [`assert_bucket_config!`](contracts/utils/sources/rate_limiter.move#L307-L311) → `EInvalidConfig`.
- Test: implicit via successful constructions; no explicit negative tests.

**Violation scenario:** `refill_interval_ms = 0` causes division by zero in `bucket_accrue`. `capacity = 0` makes the bucket permanently empty. `refill_amount = 0` makes refill a no-op forever.

**Severity:** Critical

---

### INV-R2: FixedWindow config positivity

**Category:** Runtime

**Statement:** On `new_fixed_window` and `reconfigure_fixed_window`: `capacity > 0 ∧ window_ms > 0`.

**Applies to:** [`new_fixed_window`](contracts/utils/sources/rate_limiter.move#L105), [`reconfigure_fixed_window`](contracts/utils/sources/rate_limiter.move#L262).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: [`assert_fixed_window_config!`](contracts/utils/sources/rate_limiter.move#L313-L316) → `EInvalidConfig`.
- Test: no explicit negative tests.

**Violation scenario:** `window_ms = 0` causes modulo-by-zero in `align_window`. `capacity = 0` makes every consume fail.

**Severity:** Critical

---

### INV-R3: Cooldown config positivity

**Category:** Runtime

**Statement:** On `new_cooldown` and `reconfigure_cooldown`: `cooldown_ms > 0`.

**Applies to:** [`new_cooldown`](contracts/utils/sources/rate_limiter.move#L116), [`reconfigure_cooldown`](contracts/utils/sources/rate_limiter.move#L295).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: `assert!(cooldown_ms > 0, EInvalidConfig)`.
- Test: no explicit negative tests.

**Violation scenario:** `cooldown_ms = 0` would make every consume succeed, defeating the purpose of the variant.

**Severity:** High

---

### INV-R4: Initial tokens bounded

**Category:** Runtime

**Statement:** On `new_bucket_with_tokens`: `initial_tokens ≤ capacity`.

**Applies to:** [`new_bucket_with_tokens`](contracts/utils/sources/rate_limiter.move#L86).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: [`assert!(initial_tokens <= capacity, EInvalidConfig)`](contracts/utils/sources/rate_limiter.move#L94).
- Test: [`bucket_with_tokens_rejects_initial_above_capacity`](contracts/utils/tests/rate_limiter_tests.move#L57).

**Violation scenario:** Bucket starts above its own capacity, violating INV-S1 from the very first call.

**Severity:** Critical

---

### INV-R5: Non-zero consume amount

**Category:** Runtime

**Statement:** `try_consume(amount, ..)` requires `amount > 0`. Zero is treated as a programmer error, not a rate-limit condition.

**Applies to:** [`try_consume`](contracts/utils/sources/rate_limiter.move#L136), [`consume_or_abort`](contracts/utils/sources/rate_limiter.move#L128).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: [`assert!(amount > 0, EInvalidAmount)`](contracts/utils/sources/rate_limiter.move#L137).
- Test: [`try_consume_with_zero_amount_aborts`](contracts/utils/tests/rate_limiter_tests.move#L189).

**Violation scenario:** Without this check, behavior on zero would diverge across variants (Bucket: trivially succeeds; FixedWindow: succeeds without changing `used`; Cooldown: still gates), making the API non-uniform.

**Severity:** Medium

---

### INV-R6: Variant guard on reconfigure

**Category:** Runtime

**Statement:** `reconfigure_bucket` aborts on non-`Bucket`, `reconfigure_fixed_window` aborts on non-`FixedWindow`, `reconfigure_cooldown` aborts on non-`Cooldown`.

**Applies to:** all `reconfigure_*` functions.

**Enforcement mechanism:**
- Type system: n/a (could be enforced with separate types, but the enum design rejects that).
- Runtime check: `_ => abort EWrongVariant` on non-matching arms.
- Test: only [`reconfigure_bucket_on_non_bucket_aborts`](contracts/utils/tests/rate_limiter_tests.move#L203) exists; the other two paths are uncovered (MISS-10).

**Violation scenario:** A `Cooldown` reconfigured via `reconfigure_bucket` would silently change variant — see INV-T2.

**Severity:** High

---

### INV-R7: `consume_or_abort` failure semantics

**Category:** Runtime

**Statement:** `consume_or_abort(amount, clk)` aborts with `ERateLimited` iff `try_consume(amount, clk)` would return `false` for the same arguments and state.

**Applies to:** [`consume_or_abort`](contracts/utils/sources/rate_limiter.move#L128).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: implementation literally calls `try_consume` and asserts.
- Test: [`bucket_consume_or_abort_aborts_when_empty`](contracts/utils/tests/rate_limiter_tests.move#L84).

**Violation scenario:** Consumers couldn't predict whether to use `try_consume` or `consume_or_abort` — the latter would diverge from the former.

**Severity:** Medium

## State Transition Invariants

### INV-S1: Bucket capacity bound

**Category:** State transition

**Statement:** For any `Bucket` reachable through the public API, `tokens ≤ capacity` after every operation.

**Applies to:** all `Bucket` state mutations.

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: [`bucket_accrue`](contracts/utils/sources/rate_limiter.move#L329) clips with `.min(capacity)`; `try_consume` only deducts after `new_tokens >= amount`; `reconfigure_bucket` clamps `tokens.min(new_capacity)`.
- Test: [`bucket_starts_full_and_refills_over_time`](contracts/utils/tests/rate_limiter_tests.move#L12) (cap on accrual), [`bucket_reconfigure_clamps_tokens_to_new_capacity`](contracts/utils/tests/rate_limiter_tests.move#L97) (clamp on shrink).

**Violation scenario:** `tokens > capacity` would let a bucket burst past its configured maximum after a long idle period.

**Severity:** Critical

---

### INV-S2: FixedWindow capacity bound

**Category:** State transition

**Statement:** For any `FixedWindow` reachable through the public API, `used ≤ capacity` after every operation.

**Applies to:** all `FixedWindow` state mutations.

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: `used + amount > capacity` short-circuits before incrementing; window roll resets `used = 0`; `reconfigure_fixed_window` does `used.min(new_capacity)`.
- Test: [`fixed_window_counts_per_window_and_resets_on_boundary`](contracts/utils/tests/rate_limiter_tests.move#L117).

**Violation scenario:** Per-window cap is exceeded; INV-E2 fails. Note: `used + amount` itself can overflow (MISS-3).

**Severity:** Critical

---

### INV-S3: Window alignment

**Category:** State transition

**Statement:** `window_start_ms % window_ms == 0` after every operation.

**Applies to:** [`FixedWindow`](contracts/utils/sources/rate_limiter.move#L51).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: every assignment to `window_start_ms` flows through `align_window`. Construction calls `align_window(now, window_ms)`; `try_consume` uses `align_window(now, window_ms)`; `reconfigure_fixed_window` uses `align_window(*, window_ms)` in both branches.
- Test: not explicit; verified indirectly through window-rollover tests.

**Violation scenario:** Misaligned `window_start_ms` would cause off-by-some windows, allowing more than `capacity` consumes per real-world aligned window.

**Severity:** High

---

### INV-S4: Window monotonicity

**Category:** State transition

**Statement:** `window_start_ms` is non-decreasing across `try_consume` calls.

**Applies to:** [`FixedWindow`](contracts/utils/sources/rate_limiter.move#L51).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: `try_consume` only writes when `aligned > window_start_ms`. Note: `reconfigure_fixed_window` may move `window_start_ms` *backward* in the widening case (see MISS-5) — by design, but the monotonicity invariant only holds across `try_consume`, not across reconfigure.
- Test: implicit in window-rollover test.

**Violation scenario:** Going backward inside `try_consume` would re-enter a window where capacity has already been spent.

**Severity:** High

---

### INV-S5: Bucket refill anchor monotonicity

**Category:** State transition

**Statement:** `last_refill_ms` is non-decreasing across `try_consume` and `reconfigure_bucket`.

**Applies to:** [`Bucket`](contracts/utils/sources/rate_limiter.move#L42).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: `bucket_accrue` returns the original `last_refill_ms` on `now ≤ last_refill_ms` or `steps == 0`; otherwise advances by `steps * refill_interval_ms` (always ≥ 0).
- Test: not explicit.

**Violation scenario:** A backward `last_refill_ms` would re-credit already-credited intervals.

**Severity:** Critical

---

### INV-S6: Fractional time preservation (Bucket)

**Category:** State transition

**Statement:** After accrual, `last_refill_ms ≡ original_last_refill_ms (mod refill_interval_ms)`. Sub-interval time elapsed but not yet credited is never discarded — it accrues toward the next step.

**Applies to:** [`bucket_accrue`](contracts/utils/sources/rate_limiter.move#L318).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: advance is `steps * refill_interval_ms`, not `now - last_refill_ms`.
- Test: missing (MISS-7).

**Violation scenario:** If implemented as `last_refill_ms = now`, a caller spamming consumes faster than `refill_interval_ms` would forfeit fractional time on every call, dramatically reducing the effective refill rate.

**Severity:** High

---

### INV-S7: All-or-nothing consume

**Category:** State transition

**Statement:** When `try_consume` returns `false`, the limiter's logical state (capacity bucket / used count / cooldown anchor) is unchanged from before the call. Internal accrual computations may have run, but no capacity has been deducted.

**Applies to:** [`try_consume`](contracts/utils/sources/rate_limiter.move#L136).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: each variant arm returns `false` *before* mutating state on the failure path. (Bucket: `return false` before `*tokens = ..`. FixedWindow: `return false` before `*used = ..`. Cooldown: `return false` before `*last_used_ms = ..`.) Note: in `try_consume`, the Bucket arm currently does *not* persist accrual on the failure path either — which is fine for INV-S1 but means a failed consume doesn't even update `last_refill_ms` to its accrued value. This is consistent with `available()`'s read-only semantics.
- Test: missing (MISS-6).

**Violation scenario:** A caller probing capacity with `try_consume` would corrupt or drain state.

**Severity:** High

---

### INV-S8: Cooldown first-fire flexibility

**Category:** State transition

**Statement:** `last_used_ms = None` until the first successful consume. The first consume succeeds at any clock value, including `0`. After the first consume, `last_used_ms = Some(_)` and never reverts to `None`.

**Applies to:** [`Cooldown`](contracts/utils/sources/rate_limiter.move#L60).

**Enforcement mechanism:**
- Type system: `Option<u64>` distinguishes "never used" from "used at ms 0".
- Runtime check: `if (last_used_ms.is_some() && now < ..)` — the `is_some()` short-circuit lets the first call through.
- Test: covered indirectly by [`cooldown_ignores_amount_value`](contracts/utils/tests/rate_limiter_tests.move#L173) which constructs at `clock = 0` and consumes immediately.

**Violation scenario:** Storing `last_used_ms: u64` with sentinel `0` would block legitimate first consumes when the chain clock starts near 0 (test environments, clock resets).

**Severity:** Medium

---

### INV-S9: Cooldown last-used monotonicity

**Category:** State transition

**Statement:** Once `last_used_ms = Some(t)`, subsequent successful consumes set it to `t' ≥ t + cooldown_ms` (using whatever `cooldown_ms` was in effect at the time of the second consume).

**Applies to:** [`Cooldown`](contracts/utils/sources/rate_limiter.move#L60).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: gate `now ≥ last_used_ms + cooldown_ms` is required for success; on success, `last_used_ms = now`.
- Test: covered by [`cooldown_requires_elapsed_time_between_consumes`](contracts/utils/tests/rate_limiter_tests.move#L146).

**Violation scenario:** Backward `last_used_ms` would collapse the cooldown gate.

**Severity:** High

---

### INV-S10: Reconfigure preserves variant

**Category:** State transition

**Statement:** No reconfigure path changes which variant the limiter is. To switch variant, the integrator must construct a fresh `RateLimiter` and overwrite the field.

**Applies to:** all `reconfigure_*` functions.

**Enforcement mechanism:**
- Type system: every reconfigure arm matches exactly one variant; the wildcard branch aborts.
- Runtime check: `EWrongVariant` (INV-R6).
- Test: only Bucket case (MISS-10).

**Violation scenario:** Silent variant change — a `Bucket` becomes a `Cooldown` mid-flight, completely changing the semantics of `consume`.

**Severity:** Critical

---

### INV-S11: Reconfigure clamps state to new bounds

**Category:** State transition

**Statement:** When capacity shrinks: `reconfigure_bucket` clamps `tokens.min(new_capacity)`; `reconfigure_fixed_window` clamps `used.min(new_capacity)`. INV-S1 and INV-S2 hold post-reconfigure.

**Applies to:** [`reconfigure_bucket`](contracts/utils/sources/rate_limiter.move#L222), [`reconfigure_fixed_window`](contracts/utils/sources/rate_limiter.move#L262).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: `.min(capacity)` on both fields.
- Test: [`bucket_reconfigure_clamps_tokens_to_new_capacity`](contracts/utils/tests/rate_limiter_tests.move#L97). FixedWindow case missing.

**Violation scenario:** Tokens > new capacity would let a Bucket burst above its new ceiling immediately after reconfigure.

**Severity:** Critical

---

### INV-S12: Reconfigure accrues under old rules first (Bucket)

**Category:** State transition

**Statement:** `reconfigure_bucket` applies the *previous* `refill_amount`/`refill_interval_ms` to all elapsed time before the new config takes effect. The new rate applies only to time after the reconfigure.

**Applies to:** [`reconfigure_bucket`](contracts/utils/sources/rate_limiter.move#L222).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: [`bucket_accrue`](contracts/utils/sources/rate_limiter.move#L239-L246) is called with the *current* config fields *before* they're overwritten.
- Test: missing (MISS-8).

**Violation scenario:** Retroactively applying a new rate would let an operator backdate increased capacity, violating economic invariants for the past period.

**Severity:** High

---

### INV-S13: Reconfigure rolls forward under old window first (FixedWindow)

**Category:** State transition

**Statement:** `reconfigure_fixed_window` checks `align_window(now, old_window_ms)` against the existing `window_start_ms` and resets `used = 0` if a new window has begun under the old rules — *before* the new `window_ms` is installed.

**Applies to:** [`reconfigure_fixed_window`](contracts/utils/sources/rate_limiter.move#L262).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: [`if (aligned > *window_start_ms) { *window_start_ms = aligned; *used = 0; }`](contracts/utils/sources/rate_limiter.move#L277-L283) where `aligned = align_window(now, window_ms)` — note: this uses the *new* `window_ms`. **This is a deviation from the stated invariant** — see MISS-5.
- Test: missing (MISS-8).

**Violation scenario:** See MISS-5 for the actual current behavior.

**Severity:** High — implementation does not strictly match the stated invariant; behavior is defensible but worth explicit documentation or fix.

## Economic / Protocol Invariants

### INV-E1: Bucket long-run rate ceiling

**Category:** Economic

**Statement:** Over any interval `Δt`, the maximum number of tokens consumable from a `Bucket` is at most `capacity + ⌊Δt / refill_interval_ms⌋ * refill_amount`. The bucket cannot generate value out of thin air.

**Applies to:** `Bucket` lifecycle.

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: implied by INV-S1 + accrual formula.
- Test: covered partially by [`bucket_starts_full_and_refills_over_time`](contracts/utils/tests/rate_limiter_tests.move#L12). No long-run / fuzzed test exists.

**Violation scenario:** Over-issuance — the central economic guarantee a rate limiter exists to provide. Reachable today through MISS-1/MISS-2 (overflow).

**Severity:** Critical

---

### INV-E2: FixedWindow per-window cap

**Category:** Economic

**Statement:** No more than `capacity` units consumed within any aligned `[k·window_ms, (k+1)·window_ms)` window.

**Applies to:** `FixedWindow` lifecycle.

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: implied by INV-S2 + INV-S3.
- Test: [`fixed_window_counts_per_window_and_resets_on_boundary`](contracts/utils/tests/rate_limiter_tests.move#L117).

**Violation scenario:** Per-window cap exceeded. Reachable today through MISS-3 (overflow).

**Severity:** Critical

---

### INV-E3: Cooldown minimum gap

**Category:** Economic

**Statement:** Successive successful consumes are separated by at least the *current* `cooldown_ms` at the time of the second consume.

**Applies to:** `Cooldown` lifecycle.

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: gate in `try_consume`.
- Test: [`cooldown_requires_elapsed_time_between_consumes`](contracts/utils/tests/rate_limiter_tests.move#L146). Reconfigure-then-consume gap behavior is untested (MISS-9).

**Violation scenario:** Cooldown can be bypassed, defeating throttling for the variant.

**Severity:** Critical

---

### INV-E4: `available()` consistency

**Category:** Economic

**Statement:** If `available(&clk) ≥ amount` and no clock change or other call intervenes, then `try_consume(amount, &clk)` returns `true`. For `Cooldown`, `available == 1` ⇒ any positive-amount `try_consume` returns `true`.

**Applies to:** [`available`](contracts/utils/sources/rate_limiter.move#L186), [`try_consume`](contracts/utils/sources/rate_limiter.move#L136).

**Enforcement mechanism:**
- Type system: n/a.
- Runtime check: same accrual and gate logic in both functions.
- Test: not explicitly cross-checked.

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

**Applies to:** [`try_consume`](contracts/utils/sources/rate_limiter.move#L136), [`consume_or_abort`](contracts/utils/sources/rate_limiter.move#L128).

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
| `new_bucket` | INV-T1, INV-T2, INV-R1, INV-S1, INV-S5 | Type + Runtime |
| `new_bucket_with_tokens` | INV-T1, INV-T2, INV-R1, INV-R4, INV-S1, INV-S5 | Type + Runtime |
| `new_fixed_window` | INV-T1, INV-T2, INV-R2, INV-S2, INV-S3 | Type + Runtime |
| `new_cooldown` | INV-T1, INV-T2, INV-R3, INV-S8 | Type + Runtime |
| `try_consume` | INV-T4, INV-R5, INV-S1, INV-S2, INV-S3, INV-S4, INV-S5, INV-S6, INV-S7, INV-S9, INV-E1, INV-E2, INV-E3, INV-C2 | Type + Runtime |
| `consume_or_abort` | INV-T4, INV-R5, INV-R7 + all of `try_consume` | Type + Runtime |
| `available` | INV-T3, INV-E4 | Type only |
| `reconfigure_bucket` | INV-T4, INV-R1, INV-R6, INV-S5, INV-S10, INV-S11, INV-S12 | Type + Runtime |
| `reconfigure_fixed_window` | INV-T4, INV-R2, INV-R6, INV-S2, INV-S3, INV-S10, INV-S11, INV-S13 | Type + Runtime |
| `reconfigure_cooldown` | INV-T4, INV-R3, INV-R6, INV-S10 | Type + Runtime |

## Out of Scope

- **Global / cross-limiter rate guarantees.** Each limiter is independent; no cross-limiter aggregate cap. Out of scope by design (INV-C1).
- **Authorization / access control inside the module.** Delegated to the parent object holding the field (INV-T4). The module makes no claim about who *should* be allowed to call `&mut` paths.
- **Clock authenticity.** The module trusts `&Clock`; it does not defend against a malicious shared-clock substitute (Sui's `Clock` is a singleton shared object, so this is a Sui-platform property).
- **Upper bounds on `capacity`, `refill_amount`, `refill_interval_ms`, `window_ms`, `cooldown_ms` beyond positivity.** No documented upper bounds — see MISS-1/2/3 for the practical consequences.
- **Persistence of `RateLimiter` across object lifecycles.** When the parent object is destroyed, the limiter is dropped (`has drop`). Out of scope: any "frozen state" or "transferable consumption history" use case.

## Dev Notes

- **Authorization model is the central design decision.** The limiter delegates 100% of access control to the holder of `&mut` to the parent field. This is what makes the primitive embeddable, registry-less, and PTB-friendly. Any future "shared rate limiter" feature would require fundamentally different primitives.
- **Clock is assumed non-decreasing across calls.** The module silently absorbs backward clock movement (Bucket: no accrual; FixedWindow: keeps existing window; Cooldown: extends gate). This is conservative — the limiter never grants extra capacity on backward time — but it's not an explicit invariant in the code. Sui's `Clock` is monotonic in practice.
- **Integer overflow surfaces are real on adversarial config.** MISS-1/2/3 are reachable. The code currently relies on operators choosing reasonable parameters. Fixing with saturating arithmetic or explicit clamping is straightforward and recommended.
- **`reconfigure_fixed_window` widening behavior (MISS-5).** When `new_window_ms > old_window_ms` and `align_window(now, new_window_ms) ≤ window_start_ms`, the existing usage carries into a wider window whose start may have moved backward. Defensible but surprising; should be documented as intended behavior or changed to "always reset on widening".

## Open Questions

1. **Should the overflow paths (MISS-1/2/3) be fixed with saturating arithmetic, with explicit upper-bound asserts on config, or both?** Saturation is invisible to consumers; asserts surface bad config at construction time.
2. **Is the FixedWindow "widening absorbs prior usage" behavior (MISS-5) intended?** If yes, document it. If no, the fix is to always reset `used = 0` and `window_start_ms = align_window(now, new_window_ms)` on widening — at the cost of slightly different reconfigure semantics across narrow vs wide changes.
3. **Should `available()` for `Cooldown` return `1` or something else when ready?** Today it returns `1`. This is a tiny API surface choice — meaningful only for the `INV-E4` consistency property.
4. **Should the variant guard pattern (`reconfigure_bucket` aborts on non-Bucket) be replaced with a "reconfigure_or_replace" that always works by overwriting?** Probably no — the abort makes the integrator's intent explicit. But worth noting as an alternative.

## Gaps List (referenced by Dev Notes and Open Questions)

| ID | Severity | Stage to fix | Description |
|---|---|---|---|
| MISS-1 | Critical | Code Draft | `steps * refill_amount` can overflow u64 in `bucket_accrue`. Adversarial config (small `refill_interval_ms`, large `refill_amount`, long idle) reaches it. Fix: clamp `steps` or use saturating mul. |
| MISS-2 | Critical | Code Draft | `tokens + steps * refill_amount` can overflow before `.min(capacity)` clips. Same root cause as MISS-1. |
| MISS-3 | Critical | Code Draft | `*used + amount > *capacity` in `try_consume` can wrap when `amount` is near `u64::MAX` and `used` is non-zero. Fix: `amount > capacity - used`. |
| MISS-4 | Low | Code Draft (optional) | `*last_used_ms.borrow() + *cooldown_ms` in Cooldown can overflow. Practically unreachable on Sui. |
| MISS-5 | High | Code Draft (decision) | `reconfigure_fixed_window` may move `window_start_ms` backward when widening, absorbing prior usage. Document or change. |
| MISS-6 | Medium | Tests | No test confirms `try_consume` is non-mutating on failure (INV-S7). |
| MISS-7 | Medium | Tests | No test for fractional time preservation (INV-S6). |
| MISS-8 | Medium | Tests | No test for "reconfigure under old rules first" (INV-S12, INV-S13). |
| MISS-9 | Medium | Tests | No test for cooldown reconfigure preserving `last_used_ms`. |
| MISS-10 | Medium | Tests | `EWrongVariant` paths for `reconfigure_fixed_window` and `reconfigure_cooldown` are untested. |
| MISS-11 | Critical | Tests | No test for Bucket overflow paths (MISS-1/2). |
| MISS-12 | Critical | Tests | No test for FixedWindow overflow path (MISS-3). |
| MISS-13 | Low | Docs | Clock-non-monotonicity assumption is implicit, not documented. |
| MISS-14 | Low | Docs | "Authorization is delegated to parent `&mut`" is the central design decision but isn't called out as such. |

## Step-Back Suggestion (Optional)

**Target stage:** Code Draft
**Severity:** Critical — blocks production
**Issue:** MISS-1, MISS-2, MISS-3 are reachable u64 overflow paths in the current implementation that can violate INV-E1 and INV-E2 (the central economic guarantees of the module). MISS-5 is an undocumented reconfigure behavior that may or may not be intended.
**Current workaround:** This invariants document records the issues and severity. The code itself is unmodified.
**Why step-back would be better:** The fixes are small (saturating arithmetic, one comparison rewrite) and belong in the Code Draft stage. Doing them now keeps the module's invariants enforceable end-to-end before tests are written against it.

The dev decides whether to act on this. Fixing MISS-1/2/3 in the source is the recommended next move.

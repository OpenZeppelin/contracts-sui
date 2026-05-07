# Rate Limiter - Invariants

## Summary

Embeddable rate-limiting primitive (`store + drop`) with three variants - `Bucket`, `FixedWindow`, `Cooldown` - sharing one API. Authorization is delegated entirely to whoever holds `&mut` to the embedded field. This document captures 4 type-level, 7 runtime, 13 state-transition, 4 economic, and 2 composability invariants enforced by the implementation.

## Type-Level Invariants

### INV-T1: Embeddable, single-owner

**Category:** Type-level

**Statement:** A `RateLimiter` value cannot be a top-level Sui object and cannot be duplicated. It exists only as a field of some parent value.

**Enforcement:** Type system - the value has `store + drop` only; no `key` (so it cannot become a top-level object) and no `copy` (so it cannot be duplicated).

**Violation scenario:** If the limiter could be copied or shared as a top-level object, two parent objects could each hold a "copy" with its own counter. Each copy would refill and drain independently, so the same logical limiter would grant 2× (or N×) its configured capacity - silent over-issuance.

**Severity:** Critical

---

### INV-T2: Variant exclusivity

**Category:** Type-level

**Statement:** A `RateLimiter` is exactly one of `Bucket | FixedWindow | Cooldown`. The variant is fixed at construction; only the matching `reconfigure_*` accepts it, and reconfigure cannot change the variant.

**Enforcement:** Type system - exhaustive enum `match`. Runtime - the variant guard in each `reconfigure_*` aborts on a mismatched variant (see INV-R6).

**Violation scenario:** A limiter built as `Cooldown` is reconfigured into a `Bucket`, silently changing the rate-limiting policy without consumer awareness.

**Severity:** High

---

### INV-T3: Read-only `available()`

**Category:** Type-level

**Statement:** `available(&RateLimiter, &Clock)` cannot mutate limiter state.

**Enforcement:** Type system - the function takes an immutable borrow `&RateLimiter`.

**Violation scenario:** A read path "consumes" capacity, draining the limiter through inspection.

**Severity:** Critical

## Runtime Invariants

### INV-R1: Bucket config positivity

**Category:** Runtime

**Statement:** On `new_bucket` and `reconfigure_bucket`: `capacity > 0 ∧ refill_amount > 0 ∧ refill_interval_ms > 0`.

**Enforcement:** Runtime - construction and reconfigure assert positivity of all three fields and abort otherwise.

**Violation scenario:** A zero `refill_interval_ms` or `refill_amount` causes division-by-zero in the accrual computation; a zero `capacity` makes the bucket permanently empty.

**Severity:** Critical

---

### INV-R2: FixedWindow config positivity

**Category:** Runtime

**Statement:** On `new_fixed_window` and `reconfigure_fixed_window`: `capacity > 0 ∧ window_ms > 0`.

**Enforcement:** Runtime - construction and reconfigure assert positivity of both fields and abort otherwise.

**Violation scenario:** A zero `window_ms` causes division-by-zero in the window-roll computation; a zero `capacity` makes every consume fail.

**Severity:** Critical

---

### INV-R3: Cooldown config positivity

**Category:** Runtime

**Statement:** On `new_cooldown` and `reconfigure_cooldown`: `capacity > 0 ∧ cooldown_ms > 0`.

**Enforcement:** Runtime - construction and reconfigure assert positivity of both fields and abort otherwise.

**Violation scenario:** A zero `cooldown_ms` would make every consume succeed, defeating the variant; a zero `capacity` would freeze the limiter forever. No upper bound is enforced on `cooldown_ms`; see Operator Responsibilities below.

**Severity:** High

---

### INV-R4: Initial available bounded (Bucket)

**Category:** Runtime

**Statement:** On `new_bucket`: `initial_available ≤ capacity`. This is the knob that lets integrators start a bucket empty (forces a pre-roll wait) or partly full.

**Enforcement:** Runtime - construction asserts `initial_available ≤ capacity` and aborts otherwise.

**Violation scenario:** Bucket starts above its own capacity, violating INV-S1 from the very first call.

**Severity:** Critical

---

### INV-R5: Non-zero consume amount

**Category:** Runtime

**Statement:** Consume calls require `amount > 0`. Zero is treated as a programmer error, not a rate-limit condition.

**Enforcement:** Runtime - consume entry points assert `amount > 0` and abort otherwise.

**Violation scenario:** A zero-unit consume would succeed without drawing capacity down, violating the API's "consume `amount` units" contract and giving callers a no-op masquerading as a successful rate-limit decision.

**Severity:** Medium

---

### INV-R6: Variant guard on reconfigure

**Category:** Runtime

**Statement:** Each `reconfigure_*` aborts on the wrong variant. The variant check has priority over config validation: a wrong-variant call always aborts with the variant error, even when the supplied config would also be invalid.

**Enforcement:** Runtime - the config validation is performed *inside* the matching variant's arm, so the wildcard "wrong variant" arm fires first whenever the variant does not match.

**Violation scenario:** A `Cooldown` reconfigured via `reconfigure_bucket` would silently change variant - see INV-T2.

**Severity:** High

---

### INV-R7: `consume_or_abort` failure semantics

**Category:** Runtime

**Statement:** `consume_or_abort(amount, clk)` aborts iff `try_consume(amount, clk)` would return `false` for the same arguments and state.

**Enforcement:** Runtime - the implementation calls `try_consume` and asserts on its return value, so the two functions cannot diverge by construction.

**Violation scenario:** Consumers couldn't predict whether to use `try_consume` or `consume_or_abort` - the latter would diverge from the former.

**Severity:** Medium

## State Transition Invariants

### INV-S1: Bucket capacity bound

**Category:** State transition

**Statement:** For any `Bucket` reachable through the public API, `available ≤ capacity` after every operation.

**Enforcement:** Runtime - accrual is split into an under-fill branch (where the credit is bounded by remaining headroom) and a fill branch (which writes `capacity` directly), so the post-accrual value never exceeds `capacity`. Consume only deducts after checking sufficient available capacity. Reconfigure clamps `available` down to the new `capacity`.

**Violation scenario:** `available > capacity` would let a bucket burst past its configured maximum after a long idle period.

**Severity:** Critical

---

### INV-S2: FixedWindow capacity bound

**Category:** State transition

**Statement:** For any `FixedWindow` reachable through the public API, `available ≤ capacity` after every operation.

**Enforcement:** Runtime - the consume comparison is in subtraction form (overflow-safe) and short-circuits when `amount` exceeds `available`; window roll resets `available` to `capacity`; reconfigure clamps `available` down to the new `capacity`.

**Violation scenario:** Per-window cap is exceeded; INV-E2 fails.

**Severity:** Critical

---

### INV-S3: Anchor-based window grid

**Category:** State transition

**Statement:** Windows are anchored at the limiter's creation time. After construction, the window anchor equals the creation timestamp; thereafter it advances only by integer multiples of the *current* `window_ms`. Consequently, the anchor is always `creation + k · window_ms` for some `k ≥ 0` (or, after reconfigure, the anchor rolled forward under the previous `window_ms`).

`reconfigure_fixed_window` first runs the window-roll under the OLD `window_ms` (preserving INV-S13), then installs the new config; subsequent advances use the new `window_ms` from the rolled-forward anchor.

**Enforcement:** Runtime - construction sets the window anchor to the current chain timestamp (no wall-clock alignment). All subsequent advances move the anchor by an integer multiple of the *current* `window_ms`, and the same advance is used by both consume and reconfigure (with reconfigure running under the old `window_ms` before the new value is installed).

**Violation scenario:** A wall-clock-aligned design makes the first window arbitrarily short - if the limiter is created near a window boundary, the first window can collapse to a few ms. Misaligning the anchor (e.g. by setting it to a value that isn't `creation + k · window_ms`) would let an attacker reset `available` more frequently than once per `window_ms`, exceeding INV-E2.

**Severity:** High

---

### INV-S4: Window monotonicity

**Category:** State transition

**Statement:** The window anchor is non-decreasing across consume and reconfigure calls.

**Enforcement:** Runtime - the advance is always a non-negative multiple of `window_ms` (computed via integer division of elapsed time), and is only written when at least one full step has elapsed.

**Violation scenario:** Going backward inside a consume would re-enter a window where capacity has already been spent.

**Severity:** High

---

### INV-S5: Bucket refill anchor monotonicity

**Category:** State transition

**Statement:** The bucket's refill anchor is non-decreasing across consume and reconfigure.

**Enforcement:** Runtime - accrual leaves the anchor unchanged when no full step has elapsed; otherwise advances it by a non-negative multiple of `refill_interval_ms`. The chain clock is monotonic, so elapsed-time subtraction does not underflow.

**Violation scenario:** A backward refill anchor would re-credit already-credited intervals.

**Severity:** Critical

---

### INV-S6: Fractional time preservation (Bucket)

**Category:** State transition

**Statement:** After accrual, the refill anchor is congruent to its prior value mod `refill_interval_ms`. Sub-interval time elapsed but not yet credited is never discarded - it accrues toward the next step.

**Enforcement:** Runtime - the anchor advance is always an integer multiple of `refill_interval_ms`, so the residue (`anchor mod refill_interval_ms`) is preserved across every accrual.

**Violation scenario:** Snapping the anchor to "now" after every consume would forfeit the current sub-interval's accumulated time, dramatically reducing the effective refill rate under bursty load.

**Severity:** High

---

### INV-S7: All-or-nothing consume

**Category:** State transition

**Statement:** When `try_consume` returns `false`, the limiter's logical state is unchanged from before the call. Internal accrual / window-roll computations may have run, but no capacity has been deducted.

**Enforcement:** Runtime - each variant's failure branch returns `false` before mutating `available`. Bucket and Cooldown also avoid writing their anchors on failure.

**Note:** For `FixedWindow` and `Cooldown`, a time-based reset (window roll / cooldown release) persists even if the subsequent `amount > available` check fails. This is deliberate: once time has crossed the window boundary or the cooldown deadline, the new window/batch has begun regardless of whether a consume succeeds inside it. This does not violate INV-S7 because the per-window or per-batch cap (INV-E2 / INV-E3) is unchanged - the fresh window/batch legitimately starts with `available = capacity`.

**Severity:** High

---

### INV-S8: Cooldown grant/gate state machine

**Category:** State transition

**Statement:** A `Cooldown` is in one of two logical states:
- **Granted:** `available > 0` - `try_consume(amount, _)` succeeds when `amount ≤ available`, and decrements `available` by `amount`. At construction `available = capacity`, so the limiter starts in this state. Picking an `amount` appropriate to the use case is the caller's responsibility.
- **Gated:** `available == 0` - consume returns `false` until the cooldown deadline has elapsed, at which point the next call resets `available = capacity` and proceeds (succeeding when `amount ≤ capacity`, decrementing by `amount`).

A consume that decrements `available` to exactly `0` arms the gate by setting the cooldown deadline to `now + cooldown_ms`. The deadline is taken into account only in the Gated state. Initial value `0` is therefore safe - it is never observed before being written.

**Enforcement:** Runtime - the deadline is only read inside the `available == 0` branch; a successful consume that drains `available` to zero arms the next deadline; the consume rejects when `amount > available` (after any pending gate release).

**Violation scenario:** Reading the cooldown deadline while in the Granted state would gate spuriously on a fresh limiter (since the deadline is initially zero). The current code only reads it in the Gated branch, so this is structurally avoided.

**Severity:** High

---

### INV-S9: Cooldown deadline monotonicity

**Category:** State transition

**Statement:** Once the cooldown deadline is armed (set by a consume that drains `available` to 0), no subsequent consume succeeds until the deadline elapses. The deadline is non-decreasing across the consumes that arm it.

**Enforcement:** Runtime - the gate `now ≥ deadline` is required for success while gated; each fresh deadline is computed as `now + cooldown_ms`, and the chain clock is monotonic.

**Violation scenario:** A backward deadline would collapse the gate.

**Severity:** High

---

### INV-S10: Reconfigure preserves variant

**Category:** State transition

**Statement:** No reconfigure path changes which variant the limiter is. To switch variant, the integrator must construct a fresh `RateLimiter` and overwrite the field.

**Enforcement:** Type system - each reconfigure path matches exactly one variant; the wildcard branch aborts. Runtime - see INV-R6.

**Violation scenario:** Silent variant change - a `Bucket` becomes a `Cooldown` mid-flight, completely changing the semantics of `consume`.

**Severity:** Critical

---

### INV-S11: Reconfigure clamps state to new bounds

**Category:** State transition

**Statement:** When capacity shrinks, every `reconfigure_*` clamps `available` to the new `capacity`, so INV-S1, INV-S2, and INV-S8's `available ≤ capacity` discipline hold post-reconfigure.

**Enforcement:** Runtime - each reconfigure path clamps `available` to the new `capacity` before installing the new config.

**Violation scenario:** `available > new_capacity` would let any variant burst above its new ceiling immediately after reconfigure.

**Severity:** Critical

---

### INV-S12: Reconfigure accrues under old rules first (Bucket)

**Category:** State transition

**Statement:** `reconfigure_bucket` applies the *previous* `refill_amount` and `refill_interval_ms` to all elapsed time before the new config takes effect. The new rate applies only to time after the reconfigure.

**Enforcement:** Runtime - accrual runs against the current (pre-reconfigure) config fields before they are overwritten with the new values.

**Violation scenario:** Retroactively applying a new rate would let an operator backdate increased capacity, violating economic invariants for the past period.

**Severity:** High

---

### INV-S13: Reconfigure rolls forward under old window first (FixedWindow)

**Category:** State transition

**Statement:** `reconfigure_fixed_window` advances the window anchor and resets `available` to the new `capacity` according to the *previous* `window_ms` (any number of full old-window steps that have elapsed) *before* the new `window_ms` is installed. The new window grid then anchors at the rolled-forward position.

**Enforcement:** Runtime - the window-roll computation reads the current `window_ms` for the rollover decision and rewrites the anchor before the new `window_ms` is installed.

**Violation scenario:** Using the new `window_ms` for the rollover could move the anchor backward when widening, carrying old-window usage into a wider new window - letting the fresh wider window admit only a fraction of its budget on the first turn after reconfigure, breaking INV-E2's spirit across the reconfigure boundary.

**Severity:** High

## Economic / Protocol Invariants

### INV-E1: Bucket long-run rate ceiling

**Category:** Economic

**Statement:** Over any interval `Δt`, the maximum number of tokens consumable from a `Bucket` is at most `capacity + ⌊Δt / refill_interval_ms⌋ · refill_amount`. The bucket cannot generate value out of thin air.

**Enforcement:** Implied by INV-S1 plus the integer-step accrual formula.

**Violation scenario:** Over-issuance - the central economic guarantee a rate limiter exists to provide.

**Severity:** Critical

---

### INV-E2: FixedWindow per-window cap

**Category:** Economic

**Statement:** No more than `capacity` units consumed within any `[anchor + k · window_ms, anchor + (k+1) · window_ms)` window, where `anchor` is determined by INV-S3.

**Enforcement:** Implied by INV-S2 + INV-S3 + INV-S4.

**Violation scenario:** Per-window cap exceeded.

**Severity:** Critical

---

### INV-E3: Cooldown minimum gap

**Category:** Economic

**Statement:** When `Cooldown` transitions from Gated back to Granted, at least `cooldown_ms` (the value at the time the gate was armed) has elapsed since the consume that armed the gate.

**Enforcement:** Runtime - the gate `now ≥ deadline` is equired for success, where the deadline was set as `arming_now + cooldown_ms_at_arming_time`.

**Violation scenario:** Cooldown can be bypassed, defeating throttling for the variant.

**Severity:** Critical

---

### INV-E4: `available()` consistency

**Category:** Economic

**Statement:** If `available(&clk) ≥ amount` and no clock change or other call intervenes, then `try_consume(amount, &clk)` returns `true`. This holds uniformly across all three variants.

**Enforcement:** Runtime - `available()` and the consume path apply identical accrual / window-roll / gate logic, so the read predicts the next write.

**Violation scenario:** Read-then-act consumers see ghost capacity that vanishes on the actual call.

**Severity:** High

## Composability Invariants

### INV-C1: No global state

**Category:** Composability

**Statement:** A `RateLimiter` requires no shared object, no registry, and no PTB ordering. Its scope is the parent value that owns it.

**Enforcement:** Type system - `store + drop` only, no `key`, so the limiter cannot exist as a top-level Sui object. The module exposes no global API.

**Violation scenario:** Coupling between integrators using the limiter - one consumer's actions affecting another's quota.

**Severity:** Critical (for the design's central premise)

---

### INV-C2: Re-entrant under PTB

**Category:** Composability

**Statement:** Multiple consume calls in a single PTB compose naturally. Each call independently re-reads the clock and updates state. There is no transaction-scoped accumulator.

**Enforcement:** Runtime - every call re-reads the chain clock; the only state is the embedded fields of the limiter.

**Violation scenario:** Bundling two consumes in a single PTB would behave differently from the same calls split across two PTBs - surprising and integration-hostile.

**Severity:** High

## Invariant Coverage Matrix

| Function | Invariants | Enforcement |
|----------|-----------|-------------|
| `new_bucket` | INV-T1, INV-T2, INV-R1, INV-R4, INV-S1, INV-S5 | Type + Runtime |
| `new_fixed_window` | INV-T1, INV-T2, INV-R2, INV-S2, INV-S3 | Type + Runtime |
| `new_cooldown` | INV-T1, INV-T2, INV-R3, INV-S8 | Type + Runtime |
| `try_consume` | INV-R5, INV-S1, INV-S2, INV-S3, INV-S4, INV-S5, INV-S6, INV-S7, INV-S8, INV-S9, INV-E1, INV-E2, INV-E3, INV-C2 | Type + Runtime |
| `consume_or_abort` | INV-R5, INV-R7 + all of `try_consume` | Type + Runtime |
| `available` | INV-T3, INV-E4 | Type only |
| `reconfigure_bucket` | INV-R1, INV-R6, INV-S5, INV-S10, INV-S11, INV-S12 | Type + Runtime |
| `reconfigure_fixed_window` | INV-R2, INV-R6, INV-S2, INV-S3, INV-S4, INV-S10, INV-S11, INV-S13 | Type + Runtime |
| `reconfigure_cooldown` | INV-R3, INV-R6, INV-S8, INV-S10, INV-S11 | Type + Runtime |

## Operator Responsibilities (Out of Scope for the module)

- **Cooldown deadline overflow.** Cooldown computes `cooldown_end_ms = now + cooldown_ms`. Sui's `Clock` is monotonic and bounded well below `u64::MAX`, but a `cooldown_ms` near `u64::MAX` would overflow this addition. Operators must pick `cooldown_ms` such that `now + cooldown_ms` cannot overflow at any plausible chain timestamp during the limiter's lifetime - any policy-meaningful value (seconds to days to years in ms) satisfies this trivially. The module enforces only positivity (INV-R3); no upper-bound assert is added because there is no useful `u64` ceiling that captures "policy-reasonable."
- **Clock authenticity.** The module trusts `&Clock`; it does not defend against a malicious shared-clock substitute (Sui's `Clock` is a singleton shared object, so this is a Sui-platform property).
- **Authorization / access control inside the module.** Delegated to the parent object holding the field. The module makes no claim about who *should* be allowed to call `&mut` paths.

## Out of Scope

- **Global / cross-limiter rate guarantees.** Each limiter is independent; no cross-limiter aggregate cap. Out of scope by design (INV-C1).
- **Persistence of `RateLimiter` across object lifecycles.** When the parent object is destroyed, the limiter is dropped (`has drop`). Out of scope: any "frozen state" or "transferable consumption history" use case.

## Dev Notes

- **Authorization model is the central design decision.** The limiter delegates 100% of access control to the holder of `&mut` to the parent field. This is what makes the primitive embeddable, registry-less, and PTB-friendly. Any future "shared rate limiter" feature would require fundamentally different primitives.
- **Clock is assumed monotonic.** Sui's `Clock` is monotonic in practice; the module relies on this and uses elapsed-time subtraction directly. If the clock ever ran backward, the subtraction would underflow and abort - a fail-closed posture rather than a silent absorption.
- **Overflow surfaces closed by implementation, not config bounds.** Bucket accrual's two-branch structure bounds every intermediate product and sum by `capacity` (no upper bound on `capacity` or `refill_amount` required). `FixedWindow`'s hot-path comparison uses subtraction so no addition can overflow. `Cooldown` is the one exception (`now + cooldown_ms`); operators handle it (see Operator Responsibilities).
- **Anchor-based windows.** `FixedWindow` windows are `[creation + k · window_ms, creation + (k+1) · window_ms)`. The first window always has length exactly `window_ms`. On reconfigure, the new window grid anchors at the rolled-forward position under the OLD `window_ms`.
- **Cooldown stores `available` and `cooldown_end_ms`.** The design tracks remaining capacity directly and stores the absolute release deadline; the gate predicate is `now < cooldown_end_ms`. This is symmetric with the other variants' `available` field.

## Open Questions

1. **Should the variant guard pattern (`reconfigure_bucket` aborts on non-Bucket) be replaced with a "reconfigure_or_replace" that always works by overwriting?** Probably no - the abort makes the integrator's intent explicit. But worth noting as an alternative.

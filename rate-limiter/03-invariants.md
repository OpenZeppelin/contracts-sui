---
stage: invariants
project: rate-limiter
mode: extension
extends: contracts/utils/sources/rate_limiter.move
status: draft
timestamp: 2026-05-07
author: nenad
previous_stage: null
tags: [rate-limiter, utils, embeddable, invariants]
---

# Rate Limiter — Invariants

## Summary

Embeddable rate-limiting primitive (`store + drop`) with three variants — `Bucket`, `FixedWindow`, `Cooldown` — sharing one API. Authorization is delegated entirely to whoever holds `&mut` to the embedded field.

## Document Conventions

This document specifies the rate limiter as a protocol. Each invariant follows a fixed structure:

- **Statement** — a normative semantic property the limiter must satisfy. Implementation-agnostic.
- **Why it matters** — the security or economic rationale. Explains what fails if the invariant is violated.
- **Enforcement** — an abstract preservation mechanism. Describes *what* preserves the invariant, not *how* the current implementation realizes it.

Invariants describe the protocol's required guarantees. Enforcement notes describe the abstract mechanism that preserves them. Neither references arithmetic representation, control-flow structure, branch ordering, storage layout, or implementation mechanics; those belong in the implementation and its tests, not the specification.

## Type-Level Invariants

### INV-T1: Embeddable, single-owner

**Statement:** A `RateLimiter` value cannot be a top-level Sui object and cannot be duplicated. It exists only as a field of some parent value.

**Why it matters:** A duplicable or top-level limiter would let two parent objects each hold a "copy" with its own counter, multiplying the configured capacity by N — silent over-issuance of the central economic guarantee.

**Enforcement:** The type system denies the abilities required to live as a top-level Sui object or to be copied.

---

### INV-T2: Variant identity is immutable

**Statement:** A `RateLimiter` is exactly one of `Bucket | FixedWindow | Cooldown`. The variant is fixed at construction. No public path — including any `reconfigure_*` — can change it. To switch variant, the integrator must construct a fresh `RateLimiter` and overwrite the field.

**Why it matters:** A mid-flight variant swap would silently change the rate-limiting policy without consumer awareness — e.g., a `Cooldown` becoming a `Bucket` reinterprets every subsequent consume.

**Enforcement:** Variant identity is preserved across every public operation; no public path produces a value of a different variant from its input.

## Runtime Invariants

### INV-R1: Bucket config positivity

**Statement:** On `new_bucket` and `reconfigure_bucket`: `capacity > 0 ∧ refill_amount > 0 ∧ refill_interval_ms > 0`.

**Why it matters:** A zero `refill_interval_ms` or `refill_amount` leaves the accrual computation undefined; a zero `capacity` makes the bucket permanently empty. Either way, the limiter is unusable or unsafe.

**Enforcement:** Construction and reconfigure reject any `Bucket` config that does not satisfy the positivity conjunction.

---

### INV-R2: FixedWindow config positivity

**Statement:** On `new_fixed_window` and `reconfigure_fixed_window`: `capacity > 0 ∧ window_ms > 0`.

**Why it matters:** A zero `window_ms` leaves the window-roll computation undefined; a zero `capacity` makes every consume fail.

**Enforcement:** Construction and reconfigure reject any `FixedWindow` config that does not satisfy the positivity conjunction.

---

### INV-R3: Cooldown config positivity

**Statement:** On `new_cooldown` and `reconfigure_cooldown`: `capacity > 0 ∧ cooldown_ms > 0`.

**Why it matters:** A zero `cooldown_ms` defeats the variant by letting every consume succeed; a zero `capacity` freezes the limiter forever. No upper bound on `cooldown_ms` is enforced (see Operator Responsibilities).

**Enforcement:** Construction and reconfigure reject any `Cooldown` config that does not satisfy the positivity conjunction.

---

### INV-R4: Initial available bounded (Bucket)

**Statement:** On `new_bucket`: `initial_available ≤ capacity`. This is the knob that lets integrators start a bucket empty (forces a pre-roll wait) or partly full.

**Why it matters:** A bucket starting above its own capacity violates INV-S1 from the very first call, breaking the central capacity bound before any consume runs.

**Enforcement:** Construction rejects `initial_available > capacity`.

---

### INV-R5: Variant guard precedes config validation

**Statement:** Each `reconfigure_*` call validates variant identity *before* validating its supplied configuration. A wrong-variant call always aborts with the variant error, even when the supplied config would also be invalid.

**Why it matters:** This is the runtime mechanism that preserves INV-T2 across reconfigure. Without the variant check, `reconfigure_bucket` against a `Cooldown` could be used to silently change variant. Ordering the variant check first also gives integrators a stable error surface: the same wrong-variant call always produces the same diagnosis.

**Enforcement:** Variant identity is checked first; only matching-variant calls proceed to config validation.

## Arithmetic Safety Invariants

### INV-A1: Elapsed-time subtraction is safe

**Statement:** Computations of the form `now - anchor` (Bucket refill anchor, FixedWindow window anchor, Cooldown deadline check) never underflow within the limiter's reachable state.

**Why it matters:** A silent underflow would re-credit time, advance windows incorrectly, or release cooldown gates spuriously — all of which inflate the effective rate.

**Enforcement:** Every anchor stored in the limiter is non-decreasing and is set from a reading of the same monotonic clock used at the subtraction site (see Assumed (External) Invariants on clock monotonicity). If clock monotonicity is ever violated, the subtraction aborts fail-closed rather than wrapping.

---

### INV-A2: Refill accumulation is bounded (Bucket)

**Statement:** Bucket accrual never produces a value of `available` outside `[0, capacity]`. Intermediate computations of credited tokens are bounded by `capacity` before being added to `available`.

**Why it matters:** An unbounded accrual could overflow `u64` after long idle periods or aggressive `refill_amount` settings, producing wrap-around values that violate INV-S1 and INV-E1.

**Enforcement:** Credited tokens are clipped to the headroom `capacity - available` before being applied; the post-state is always within `[0, capacity]`.

---

### INV-A3: Cooldown deadline arithmetic is safe within policy-reasonable bounds

**Statement:** Computation of the cooldown deadline `now + cooldown_ms` does not overflow within the limiter's reachable state, given any policy-reasonable `cooldown_ms` and any plausible Sui chain timestamp.

**Why it matters:** An overflow would wrap the deadline backward, releasing the gate immediately and defeating INV-E3.

**Enforcement:** Sui's `Clock` is bounded well below `u64::MAX`; the module trusts this bound and aborts fail-closed on overflow rather than wrapping. Operator responsibility for selecting a policy-reasonable `cooldown_ms` is documented in Operator Responsibilities.

## State Transition Invariants

### INV-S1: Bucket capacity bound

**Statement:** For any `Bucket` reachable through the public API, `available ≤ capacity` after every operation.

**Why it matters:** `available > capacity` would let a bucket burst past its configured maximum after a long idle period, breaking the long-run rate ceiling (INV-E1).

**Enforcement:** Accrual cannot lift `available` above `capacity`; consume cannot lift `available` at all; reconfigure clamps to the new capacity (INV-S11).

---

### INV-S2: FixedWindow capacity bound

**Statement:** For any `FixedWindow` reachable through the public API, `available ≤ capacity` after every operation.

**Why it matters:** `available > capacity` would exceed the per-window cap (INV-E2).

**Enforcement:** Window rollover sets `available` to exactly `capacity`; consume cannot lift `available`; reconfigure clamps to the new capacity (INV-S11).

---

### INV-S3: Cooldown capacity bound

**Statement:** For any `Cooldown` reachable through the public API, `available ≤ capacity` after every operation.

**Why it matters:** `available > capacity` would exceed the per-batch cap (INV-E3).

**Enforcement:** Initial state is at `capacity`; gate release sets `available` to exactly `capacity`; consume cannot lift `available`; reconfigure clamps to the new capacity (INV-S11).

---

### INV-S4: No double-counting of elapsed time

**Statement:** Across all time-based variants (`Bucket`, `FixedWindow`), any elapsed wall-clock interval contributes to refill or window advancement *exactly once*. Time-derived credit (refill tokens or fresh-window resets) cannot be minted twice for the same interval.

**Why it matters:** Double-counting elapsed time is the central anti-inflation guarantee. If the same interval credited refill twice, or rolled the window twice, the effective rate would exceed the configured rate — violating INV-E1 and INV-E2.

**Enforcement:** Each variant's internal time anchor is non-decreasing and is updated atomically with the credit it grants. Once an interval has advanced the anchor, that interval is no longer reachable as elapsed time on any subsequent operation.

---

### INV-S5: Preservation of partial elapsed time (Bucket)

**Statement:** Sub-interval elapsed time that has not yet accumulated into a full refill step is preserved across consume and reconfigure operations. Time elapsed between refill step boundaries accrues toward the next step rather than being discarded.

**Why it matters:** Discarding partial elapsed time on each operation would forfeit credit under bursty load, reducing the effective refill rate below the configured rate. Frequent consumers would see strictly less throughput than the protocol promises.

**Enforcement:** The refill anchor advances only by full refill steps; the residue between the anchor and `now` is retained for future accrual.

---

### INV-S6: FixedWindow anchor discipline

**Statement:** FixedWindow windows are anchored at the limiter's creation timestamp, not at any wall-clock boundary. The window anchor is non-decreasing across all operations, and advances only by full window steps under the window length in effect at the time of advancement.

**Why it matters:** Wall-clock alignment would collapse the first window to an arbitrary fraction of `window_ms`, breaking the per-window cap on the first turn. A backward or partial-step anchor would let an attacker reset `available` more frequently than once per `window_ms`, exceeding INV-E2.

**Enforcement:** The window anchor is initialized at construction and only advances forward in whole-window steps.

---

### INV-S7: Reconfigure continuity

**Statement:** Reconfigure settles all elapsed time under the *previous* parameters before the new parameters take effect. Specifically:

- `reconfigure_bucket`: any refill credit due under the previous `refill_amount` and `refill_interval_ms` is applied before the new values are installed.
- `reconfigure_fixed_window`: any window rollovers due under the previous `window_ms` are applied (advancing the anchor and refreshing `available`) before the new `window_ms` is installed; the new window grid then continues from the rolled-forward anchor.
- `reconfigure_cooldown`: an in-flight gate (armed under the previous `cooldown_ms`) is preserved verbatim, not retroactively shifted; see INV-S12.

**Why it matters:** Applying new parameters retroactively to an unsettled interval would either backdate increased capacity (operator-side inflation) or strand consumed capacity under widened windows (consumer-side loss). Both break the protocol's promise that the rate in effect at time *t* is the rate that governs time *t*.

**Enforcement:** Time-based state transitions occur before configuration changes take effect.

---

### INV-S8: Failed consume does not deduct capacity

**Statement:** A consume operation that returns failure does not deduct from `available`. Failed consumes may, however, advance time-derived state transitions (Bucket refill, FixedWindow rollover, Cooldown gate release) that are due regardless of the consume's outcome.

**Note:** For `FixedWindow` and `Cooldown`, a time-based reset (window roll / gate release) persists even if the subsequent `amount > available` check fails. This is deliberate: once time has crossed the window boundary or the cooldown deadline, the new window/batch has begun regardless of whether a consume succeeds inside it. The per-window or per-batch cap (INV-E2 / INV-E3) is unchanged — the fresh window/batch legitimately starts with `available = capacity`.

**Why it matters:** Conflating "denied" with "charged" would let a rejection still spend down capacity, doubly penalizing the consumer. Conversely, suppressing time-based transitions on failure would let a consumer indefinitely pin the limiter in a stale state by issuing failing requests.

**Enforcement:** Time progression effects are applied independent of consume outcome; spend/accounting depletion happens only on success.

---

### INV-S9: Cooldown grant/gate state machine

**Statement:** A `Cooldown` is in one of two logical states:

- **Granted:** `available > 0` — `try_consume(amount, _)` succeeds when `amount ≤ available`, and decrements `available` by `amount`. At construction `available = capacity`, so the limiter starts in this state.
- **Gated:** `available == 0` — consume returns `false` until the cooldown deadline has elapsed, at which point the next call resets `available = capacity` and proceeds (succeeding when `amount ≤ capacity`, decrementing by `amount`).

A consume that decrements `available` to exactly `0` arms the gate by setting the cooldown deadline. The deadline is meaningful only in the Gated state.

**Why it matters:** Reading the cooldown deadline while in the Granted state would gate a fresh limiter spuriously. Conflating the two states would either over-throttle (gating in Granted) or under-throttle (granting in Gated past the deadline check).

**Enforcement:** The deadline is consulted only while gated; arming and release happen at well-defined transitions between the two states.

---

### INV-S10: Cooldown deadline monotonicity

**Statement:** Once the cooldown deadline is armed (set by a consume that drains `available` to 0), no subsequent consume succeeds until the deadline elapses. The deadline is non-decreasing across the consumes that arm it.

**Why it matters:** A backward deadline would collapse the gate, defeating INV-E3.

**Enforcement:** While gated, success requires the clock to reach the armed deadline; each fresh deadline is computed forward from the current monotonic clock.

---

### INV-S11: Reconfigure clamps state to new bounds

**Statement:** Every `reconfigure_*` ensures `available ≤ new_capacity` post-reconfigure, so the per-variant `available ≤ capacity` discipline (INV-S1, INV-S2, INV-S3) holds across reconfigure.

**Why it matters:** `available > new_capacity` would let any variant burst above its new ceiling immediately after reconfigure.

**Enforcement:** Every reconfigure path establishes `available ≤ new_capacity` before the new config takes effect.

---

### INV-S12: Reconfigure preserves in-flight cooldown deadline

**Statement:** `reconfigure_cooldown` does not retroactively shift an armed in-flight cooldown deadline. If the gate is currently armed (`available == 0 ∧ now < cooldown_end_ms`), `cooldown_end_ms` is preserved verbatim under the new `cooldown_ms`. A fresh deadline at `now + cooldown_ms` is armed only when post-clamp `available == 0` and no gate is currently in flight. When `available > 0` post-clamp, the deadline is left untouched (it is unobservable in the Granted state per INV-S9).

**Why it matters:** Lengthening `cooldown_ms` and overwriting an in-flight deadline would retroactively extend an already-engaged gate, penalizing the consumer past the originally promised release. Shortening it would prematurely release a gate the consumer expected to remain armed, violating INV-E3 across the reconfigure boundary. Conversely, *not* arming a fresh deadline when post-clamp `available == 0` and no prior gate is in flight would grant an immediate free reset on the next consume, defeating the variant.

**Enforcement:** An armed in-flight deadline survives reconfigure unchanged; a fresh deadline is armed only when the gate would otherwise be empty after the clamp.

## Economic / Protocol Invariants

### INV-E1: Bucket long-run rate ceiling

**Statement:** Over any interval `Δt`, the maximum number of tokens consumable from a `Bucket` is at most `capacity + ⌊Δt / refill_interval_ms⌋ · refill_amount`. The bucket cannot generate value out of thin air.

**Why it matters:** Over-issuance is the central failure mode a rate limiter exists to prevent.

**Enforcement:** Implied by INV-S1 plus the step-discipline imposed by INV-S4 and INV-S5.

---

### INV-E2: FixedWindow per-window cap

**Statement:** No more than `capacity` units consumed within any window of length `window_ms`, where the window grid is anchored per INV-S6.

**Why it matters:** The per-window cap is the variant's defining promise; exceeding it defeats throttling.

**Enforcement:** Implied by INV-S2, INV-S4, and INV-S6.

---

### INV-E3: Cooldown minimum gap

**Statement:** When `Cooldown` transitions from Gated back to Granted, at least `cooldown_ms` (the value at the time the gate was armed) has elapsed since the consume that armed the gate.

**Why it matters:** A bypassable cooldown defeats throttling for the variant.

**Enforcement:** Implied by INV-S10 plus INV-S12 (which prevents reconfigure from retroactively shortening the gap).

---

### INV-E4: No double-accrual of elapsed time

**Statement:** Elapsed time contributes refill credit (Bucket) or window advancement (FixedWindow) at most once. No elapsed interval can be reused to mint additional capacity or to roll an additional window.

**Why it matters:** Double-accrual is the inflation primitive: if the same elapsed interval credited capacity twice, the effective rate would exceed the configured rate without bound under repeated triggering.

**Enforcement:** Implied by INV-S4. Time-based state transitions are monotonic and consume the elapsed interval that triggered them.

---

### INV-E5: No retroactive minting on reconfigure

**Statement:** Reconfigure cannot grant capacity in the past under the new parameters. Capacity granted for any moment *t* is the capacity the parameters in effect at *t* would have granted.

**Why it matters:** A reconfigure that retroactively widened the rate would let an operator backdate increased capacity — a bypass of the bounded-issuance guarantee for any consumer who held the limiter across the reconfigure boundary.

**Enforcement:** Implied by INV-S7. All elapsed time is settled under the previous parameters before the new parameters take effect.

## Liveness Invariants

### INV-L1: Bucket eventually refills

**Statement:** Given a `Bucket` with `available < capacity` and no further consumes, the available capacity strictly increases on any operation that observes elapsed time of at least `refill_interval_ms`, and reaches `capacity` after at most `⌈(capacity - available) / refill_amount⌉` such observations.

**Why it matters:** Without an eventual-refill guarantee, the safety-side bounds could be satisfied by a degenerate limiter that never refills at all. Liveness ensures the protocol meaningfully progresses.

**Enforcement:** Refill credit is positive when at least one full refill step has elapsed (INV-R1, INV-S4); INV-S1 caps the result at `capacity`.

---

### INV-L2: FixedWindow eventually rolls into a fresh window

**Statement:** For any `FixedWindow`, the next operation observed at a time greater than or equal to `anchor + window_ms` advances the window and resets `available = capacity`.

**Why it matters:** Without an eventual-rollover guarantee, a consumer could observe `available == 0` indefinitely even after the window has logically expired.

**Enforcement:** The window anchor advances by whole-window steps whenever an operation observes that at least `window_ms` has elapsed since the anchor (INV-S6); rollover refreshes `available` to `capacity` (INV-S2).

---

### INV-L3: Cooldown eventually ungates

**Statement:** For any `Cooldown` in the Gated state with deadline `cooldown_end_ms`, the next operation observed at time `now ≥ cooldown_end_ms` releases the gate and resets `available = capacity`.

**Why it matters:** Without an eventual-release guarantee, the gate could be observed as armed indefinitely past its promised release, breaking the consumer's expected ungating cadence.

**Enforcement:** Gate release fires unconditionally on the first operation observed at or after the armed deadline (INV-S9, INV-S10).

## Composability Invariants

### INV-C1: No global state

**Statement:** A `RateLimiter` requires no shared object, no registry, and no PTB ordering. Its scope is the parent value that owns it.

**Why it matters:** Any global coupling would let one consumer's actions affect another's quota — the opposite of the primitive's design intent.

**Enforcement:** The type abilities prevent the limiter from existing as a top-level Sui object, and the module exposes no global API.

---

### INV-C2: PTB composability

**Statement:** Multiple consume calls within a single PTB compose identically to the same calls split across separate PTBs, modulo the shared clock reading. There is no transaction-scoped accumulator and no PTB-local hidden accounting.

**Why it matters:** If two consumes in one PTB behaved differently from the same calls split across two PTBs, integrators would need PTB-aware accounting — integration-hostile and surprising. (This is *not* EVM-style reentrancy; the property is about PTB-locality of state, not call-graph re-entry.)

**Enforcement:** No state is retained across calls beyond what is stored in the limiter's embedded fields; each call observes the clock independently.

## Invariant Coverage Matrix

| Function | Invariants |
|----------|-----------|
| `new_bucket` | INV-T1, INV-T2, INV-R1, INV-R4, INV-A2, INV-S1, INV-S4, INV-S5 |
| `new_fixed_window` | INV-T1, INV-T2, INV-R2, INV-S2, INV-S4, INV-S6 |
| `new_cooldown` | INV-T1, INV-T2, INV-R3, INV-A3, INV-S3, INV-S9 |
| `try_consume` | INV-A1, INV-A2, INV-A3, INV-S1, INV-S2, INV-S3, INV-S4, INV-S5, INV-S6, INV-S8, INV-S9, INV-S10, INV-E1, INV-E2, INV-E3, INV-E4, INV-L1, INV-L2, INV-L3, INV-C2 |
| `consume_or_abort` | all of `try_consume` |
| `reconfigure_bucket` | INV-T2, INV-R1, INV-R5, INV-S1, INV-S4, INV-S5, INV-S7, INV-S11, INV-E5 |
| `reconfigure_fixed_window` | INV-T2, INV-R2, INV-R5, INV-S2, INV-S4, INV-S6, INV-S7, INV-S11, INV-E5 |
| `reconfigure_cooldown` | INV-T2, INV-R3, INV-R5, INV-S3, INV-S7, INV-S9, INV-S11, INV-S12 |

## Operator Responsibilities (Out of Scope for the module)

- **Cooldown deadline overflow.** Cooldown computes `cooldown_end_ms = now + cooldown_ms`. Sui's `Clock` is monotonic and bounded well below `u64::MAX`, but a `cooldown_ms` near `u64::MAX` would overflow this addition. Operators must pick `cooldown_ms` such that `now + cooldown_ms` cannot overflow at any plausible chain timestamp during the limiter's lifetime — any policy-meaningful value (seconds to days to years in ms) satisfies this trivially. The module enforces only positivity (INV-R3); overflow is fail-closed (INV-A3).
- **Clock authenticity.** The module trusts `&Clock`; it does not defend against a malicious shared-clock substitute (Sui's `Clock` is a singleton shared object, so this is a Sui-platform property).
- **Authorization / access control inside the module.** Delegated to the parent object holding the field. The module makes no claim about who *should* be allowed to call `&mut` paths.

## Assumed (External) Invariants

- **Clock monotonicity.** Every elapsed-time computation in this module assumes `Clock::timestamp_ms()` is monotonically non-decreasing across calls. Sui's `Clock` provides this. If the assumption were ever violated, elapsed-time subtractions would underflow and abort — a fail-closed posture rather than silent corruption (INV-A1). INV-S4, INV-S6, INV-S10, and INV-E3 all rely on this.

## Out of Scope

- **Global / cross-limiter rate guarantees.** Each limiter is independent; no cross-limiter aggregate cap. Out of scope by design (INV-C1).
- **Persistence of `RateLimiter` across object lifecycles.** When the parent object is destroyed, the limiter is dropped (`has drop`). Out of scope: any "frozen state" or "transferable consumption history" use case.

## Dev Notes

- **Authorization model is the central design decision.** The limiter delegates 100% of access control to the holder of `&mut` to the parent field. This is what makes the primitive embeddable, registry-less, and PTB-friendly. Any future "shared rate limiter" feature would require fundamentally different primitives.
- **Anchor-based windows.** `FixedWindow` windows are anchored at construction (INV-S6). The first window always has length exactly `window_ms`. On reconfigure, the new window grid anchors at the rolled-forward position under the previous `window_ms` (INV-S7).
- **Cooldown stores `available` and `cooldown_end_ms`.** The design tracks remaining capacity directly and stores the absolute release deadline; the gate predicate compares the clock against the deadline. This is symmetric with the other variants' `available` field.

## Open Questions

1. **Should the variant guard pattern (`reconfigure_bucket` aborts on non-Bucket) be replaced with a "reconfigure_or_replace" that always works by overwriting?** Probably no — the abort makes the integrator's intent explicit. But worth noting as an alternative.

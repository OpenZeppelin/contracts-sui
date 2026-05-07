# Rate Limiter - Invariants

## Summary

Embeddable rate-limiting primitive (`store + drop`) with three variants - `Bucket`, `FixedWindow`, `Cooldown` - sharing one API. Authorization is delegated entirely to whoever holds `&mut` to the embedded field.

## Type-Level Invariants

### INV-T1: Embeddable, single-owner

**Statement:** A `RateLimiter` value cannot be a top-level Sui object and cannot be duplicated. It exists only as a field of some parent value.

**Why it matters:** A duplicable or top-level limiter would let two parent objects each hold a "copy" with its own counter, multiplying the configured capacity by N - silent over-issuance of the central economic guarantee.

**Enforcement:** The type system denies the abilities required to live as a top-level Sui object or to be copied.

---

### INV-T2: Variant exclusivity

**Statement:** A `RateLimiter` is exactly one of `Bucket | FixedWindow | Cooldown`. The variant is fixed at construction; no public path - including any `reconfigure_*` - can change it. To switch variant, the integrator must construct a fresh `RateLimiter` and overwrite the field.

**Why it matters:** A mid-flight variant swap would silently change the rate-limiting policy without consumer awareness - e.g., a `Cooldown` becoming a `Bucket` reinterprets every subsequent consume.

**Enforcement:** The reconfigure paths are scoped to the matched variant and never replace the enum value as a whole. Wrong-variant calls abort (see INV-R5).

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

### INV-R5: Variant guard on reconfigure

**Statement:** Each `reconfigure_*` aborts on the wrong variant. The variant check has priority over config validation: a wrong-variant call always aborts with the variant error, even when the supplied config would also be invalid.

**Why it matters:** Without this guard, `reconfigure_bucket` against a `Cooldown` could be misused to silently change variant - see INV-T2.

**Enforcement:** Wrong-variant calls take a path that aborts before any config validation runs.

## State Transition Invariants

### INV-S1: Bucket capacity bound

**Statement:** For any `Bucket` reachable through the public API, `available ≤ capacity` after every operation.

**Why it matters:** `available > capacity` would let a bucket burst past its configured maximum after a long idle period, breaking the long-run rate ceiling (INV-E1).

**Enforcement:** Accrual is bounded above by `capacity`; consume only proceeds when sufficient capacity exists; reconfigure clamping is covered by INV-S8.

---

### INV-S2: FixedWindow capacity bound

**Statement:** For any `FixedWindow` reachable through the public API, `available ≤ capacity` after every operation.

**Why it matters:** `available > capacity` would exceed the per-window cap (INV-E2).

**Enforcement:** Consume cannot deduct more than `available`; window rollover resets `available` to exactly `capacity`; reconfigure clamping is covered by INV-S8.

---

### INV-S3: Cooldown capacity bound

**Statement:** For any `Cooldown` reachable through the public API, `available ≤ capacity` after every operation.

**Why it matters:** `available > capacity` would exceed the per-batch cap (INV-E3).

**Enforcement:** Initial state is at `capacity`; consume cannot deduct more than `available`; gate release resets `available` to exactly `capacity`; reconfigure clamping is covered by INV-S8.

---

### INV-S4: Temporal accounting

**Statement:** Both time-based variants advance their internal time anchor in disciplined integer steps tied to the variant's interval, so elapsed time is neither double-counted nor discarded.

- **Bucket refill anchor.** Non-decreasing across consume and reconfigure. Each accrual either leaves the anchor unchanged (no full step has elapsed) or advances it by a non-negative integer multiple of `refill_interval_ms`. The residue `anchor mod refill_interval_ms` is preserved across every accrual, so sub-interval time elapsed but not yet credited accrues toward the next step rather than being discarded.
- **FixedWindow anchor.** Anchored at the limiter's creation timestamp (no wall-clock alignment) and non-decreasing across consume and reconfigure. Advances are non-negative integer multiples of the *current* `window_ms`. In the absence of any reconfigure that changed `window_ms`, the anchor is exactly `creation + k · window_ms` for some `k ≥ 0`; after such a reconfigure the anchor is the rolled-forward position computed under the previous `window_ms` (see INV-S10).

**Why it matters:** A backward refill anchor re-credits already-credited intervals. Snapping the refill anchor to "now" forfeits sub-interval time and reduces the effective refill rate under bursty load. A wall-clock-aligned window grid collapses the first window arbitrarily; a misaligned or backward window anchor lets attackers reset `available` more frequently than once per `window_ms`, exceeding INV-E2.

**Enforcement:** Anchors advance only in whole interval steps and never move backward. Reconfigure runs the same step-discipline under the previous interval before installing the new value.

---

### INV-S5: All-or-nothing consume

**Statement:** Failed consume operations may advance time-derived state transitions (refill, rollover, gate release), but never deduct spendable capacity.

**Note:** For `FixedWindow` and `Cooldown`, a time-based reset (window roll / cooldown release) persists even if the subsequent `amount > available` check fails. This is deliberate: once time has crossed the window boundary or the cooldown deadline, the new window/batch has begun regardless of whether a consume succeeds inside it. This does not violate INV-S5 because the per-window or per-batch cap (INV-E2 / INV-E3) is unchanged - the fresh window/batch legitimately starts with `available = capacity`.

**Why it matters:** A partial deduction on rejection would let a rate-limited caller still spend down capacity, conflating "denied" with "charged."

**Enforcement:** Each variant's rejection path returns `false` without committing any decrement to `available`.

---

### INV-S6: Cooldown grant/gate state machine

**Statement:** A `Cooldown` is in one of two logical states:
- **Granted:** `available > 0` - `try_consume(amount, _)` succeeds when `amount ≤ available`, and decrements `available` by `amount`. At construction `available = capacity`, so the limiter starts in this state. Picking an `amount` appropriate to the use case is the caller's responsibility.
- **Gated:** `available == 0` - consume returns `false` until the cooldown deadline has elapsed, at which point the next call resets `available = capacity` and proceeds (succeeding when `amount ≤ capacity`, decrementing by `amount`).

A consume that decrements `available` to exactly `0` arms the gate by setting the cooldown deadline to `now + cooldown_ms`. The deadline is meaningful only in the Gated state; its initial value `0` is therefore safe - it is never observed before being written.

**Why it matters:** Reading the cooldown deadline while in the Granted state would gate a fresh limiter spuriously (the initial deadline is zero). Conflating the two states would either over-throttle (gating in Granted) or under-throttle (granting in Gated past the deadline check).

**Enforcement:** The deadline is consulted only while gated; arming and release happen at well-defined transitions between the two states.

---

### INV-S7: Cooldown deadline monotonicity

**Statement:** Once the cooldown deadline is armed (set by a consume that drains `available` to 0), no subsequent consume succeeds until the deadline elapses. The deadline is non-decreasing across the consumes that arm it.

**Why it matters:** A backward deadline would collapse the gate, defeating INV-E3.

**Enforcement:** While gated, success requires `now ≥ deadline`; each fresh deadline is computed forward from the current monotonic clock.

---

### INV-S8: Reconfigure clamps state to new bounds

**Statement:** When capacity shrinks, every `reconfigure_*` clamps `available` to the new `capacity`, so the per-variant `available ≤ capacity` discipline (INV-S1, INV-S2, INV-S3) holds post-reconfigure.

**Why it matters:** `available > new_capacity` would let any variant burst above its new ceiling immediately after reconfigure.

**Enforcement:** Every reconfigure path establishes `available ≤ new_capacity` before the new config takes effect.

---

### INV-S9: Reconfigure accrues under old rules first (Bucket)

**Statement:** `reconfigure_bucket` applies the *previous* `refill_amount` and `refill_interval_ms` to all elapsed time before the new config takes effect. The new rate applies only to time after the reconfigure.

**Why it matters:** Retroactively applying a new rate would let an operator backdate increased capacity, violating economic invariants for the past period.

**Enforcement:** Accrual under the old config is settled before the new config is installed.

---

### INV-S10: Reconfigure rolls forward under old window first (FixedWindow)

**Statement:** `reconfigure_fixed_window` advances the window anchor and resets `available` to the new `capacity` according to the *previous* `window_ms` (any number of full old-window steps that have elapsed) *before* the new `window_ms` is installed. The new window grid then anchors at the rolled-forward position.

**Why it matters:** Using the new `window_ms` for the rollover could move the anchor backward when widening, carrying old-window usage into a wider new window - letting the fresh wider window admit only a fraction of its budget on the first turn after reconfigure, breaking INV-E2's spirit across the reconfigure boundary.

**Enforcement:** The rollover decision is made under the previous `window_ms`; the new `window_ms` only governs subsequent steps from the rolled-forward anchor.

---

### INV-S11: Reconfigure preserves in-flight cooldown deadline

**Statement:** `reconfigure_cooldown` does not retroactively shift an armed in-flight cooldown deadline. If the gate is currently armed (`available == 0 ∧ now < cooldown_end_ms`), `cooldown_end_ms` is preserved verbatim under the new `cooldown_ms`. A fresh deadline at `now + cooldown_ms` is armed only when post-clamp `available == 0` and no gate is currently in flight (`now ≥ cooldown_end_ms`). When `available > 0` post-clamp, the deadline is left untouched (it is unobservable in the Granted state per INV-S6).

**Why it matters:** Lengthening `cooldown_ms` and overwriting an in-flight deadline would retroactively extend an already-engaged gate, penalizing the consumer past the originally promised release; shortening it would prematurely release a gate the consumer expected to remain armed, violating INV-E3 across the reconfigure boundary. Conversely, *not* arming a fresh deadline when post-clamp `available == 0` and no prior gate is in flight would grant an immediate free reset on the next consume, defeating the variant.

**Enforcement:** An armed in-flight deadline survives reconfigure unchanged; a fresh deadline is armed only when the gate would otherwise be empty after the clamp.

## Economic / Protocol Invariants

### INV-E1: Bucket long-run rate ceiling

**Statement:** Over any interval `Δt`, the maximum number of tokens consumable from a `Bucket` is at most `capacity + ⌊Δt / refill_interval_ms⌋ · refill_amount`. The bucket cannot generate value out of thin air.

**Why it matters:** Over-issuance is the central failure mode a rate limiter exists to prevent.

**Enforcement:** Implied by INV-S1 plus the integer-step accrual model.

---

### INV-E2: FixedWindow per-window cap

**Statement:** No more than `capacity` units consumed within any `[anchor + k · window_ms, anchor + (k+1) · window_ms)` window, where `anchor` is determined by the FixedWindow clause of INV-S4.

**Why it matters:** The per-window cap is the variant's defining promise; exceeding it defeats throttling.

**Enforcement:** Implied by INV-S2 + INV-S4.

---

### INV-E3: Cooldown minimum gap

**Statement:** When `Cooldown` transitions from Gated back to Granted, at least `cooldown_ms` (the value at the time the gate was armed) has elapsed since the consume that armed the gate.

**Why it matters:** A bypassable cooldown defeats throttling for the variant.

**Enforcement:** Gate release requires the monotonic clock to reach the deadline armed at gate entry; INV-S11 prevents reconfigure from retroactively shortening it.

## Composability Invariants

### INV-C1: No global state

**Statement:** A `RateLimiter` requires no shared object, no registry, and no PTB ordering. Its scope is the parent value that owns it.

**Why it matters:** Any global coupling would let one consumer's actions affect another's quota - the opposite of the primitive's design intent.

**Enforcement:** The type abilities prevent the limiter from existing as a top-level Sui object, and the module exposes no global API.

---

### INV-C2: Re-entrant under PTB

**Statement:** Multiple consume calls in a single PTB compose naturally. Each call independently re-reads the clock and updates state. There is no transaction-scoped accumulator.

**Why it matters:** If two consumes in one PTB behaved differently from the same calls split across two PTBs, integrators would need PTB-aware accounting - integration-hostile and surprising.

**Enforcement:** Each call re-reads the clock and operates only on the limiter's embedded fields; no cross-call state is retained.

## Invariant Coverage Matrix

| Function | Invariants |
|----------|-----------|
| `new_bucket` | INV-T1, INV-T2, INV-R1, INV-R4, INV-S1, INV-S4 |
| `new_fixed_window` | INV-T1, INV-T2, INV-R2, INV-S2, INV-S4 |
| `new_cooldown` | INV-T1, INV-T2, INV-R3, INV-S3, INV-S6 |
| `try_consume` | INV-S1, INV-S2, INV-S3, INV-S4, INV-S5, INV-S6, INV-S7, INV-E1, INV-E2, INV-E3, INV-C2 |
| `consume_or_abort` | all of `try_consume` |
| `reconfigure_bucket` | INV-T2, INV-R1, INV-R5, INV-S1, INV-S4, INV-S8, INV-S9 |
| `reconfigure_fixed_window` | INV-T2, INV-R2, INV-R5, INV-S2, INV-S4, INV-S8, INV-S10 |
| `reconfigure_cooldown` | INV-T2, INV-R3, INV-R5, INV-S3, INV-S6, INV-S8, INV-S11 |

## Operator Responsibilities (Out of Scope for the module)

- **Cooldown deadline overflow.** Cooldown computes `cooldown_end_ms = now + cooldown_ms`. Sui's `Clock` is monotonic and bounded well below `u64::MAX`, but a `cooldown_ms` near `u64::MAX` would overflow this addition. Operators must pick `cooldown_ms` such that `now + cooldown_ms` cannot overflow at any plausible chain timestamp during the limiter's lifetime - any policy-meaningful value (seconds to days to years in ms) satisfies this trivially. The module enforces only positivity (INV-R3); no upper-bound assert is added because there is no useful `u64` ceiling that captures "policy-reasonable."
- **Clock authenticity.** The module trusts `&Clock`; it does not defend against a malicious shared-clock substitute (Sui's `Clock` is a singleton shared object, so this is a Sui-platform property).
- **Authorization / access control inside the module.** Delegated to the parent object holding the field. The module makes no claim about who *should* be allowed to call `&mut` paths.

## Assumed (External) Invariants

- **Clock monotonicity.** Every elapsed-time subtraction in this module assumes `Clock::timestamp_ms()` is monotonically non-decreasing across calls. Sui's `Clock` provides this. If the assumption were ever violated, the subtractions would underflow and abort - a fail-closed posture rather than silent corruption. INV-S4, INV-S7, and INV-E3 all rely on this.

## Out of Scope

- **Global / cross-limiter rate guarantees.** Each limiter is independent; no cross-limiter aggregate cap. Out of scope by design (INV-C1).
- **Persistence of `RateLimiter` across object lifecycles.** When the parent object is destroyed, the limiter is dropped (`has drop`). Out of scope: any "frozen state" or "transferable consumption history" use case.

## Dev Notes

- **Authorization model is the central design decision.** The limiter delegates 100% of access control to the holder of `&mut` to the parent field. This is what makes the primitive embeddable, registry-less, and PTB-friendly. Any future "shared rate limiter" feature would require fundamentally different primitives.
- **Anchor-based windows.** `FixedWindow` windows are `[creation + k · window_ms, creation + (k+1) · window_ms)`. The first window always has length exactly `window_ms`. On reconfigure, the new window grid anchors at the rolled-forward position under the OLD `window_ms`.
- **Cooldown stores `available` and `cooldown_end_ms`.** The design tracks remaining capacity directly and stores the absolute release deadline; the gate predicate is `now < cooldown_end_ms`. This is symmetric with the other variants' `available` field.

## Open Questions

1. **Should the variant guard pattern (`reconfigure_bucket` aborts on non-Bucket) be replaced with a "reconfigure_or_replace" that always works by overwriting?** Probably no - the abort makes the integrator's intent explicit. But worth noting as an alternative.

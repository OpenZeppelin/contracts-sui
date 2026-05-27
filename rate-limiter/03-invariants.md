## Summary

Embeddable rate-limiting primitive (`store + drop`) with three variants — `Bucket`, `FixedWindow`, `Cooldown` — sharing one API. Authorization is delegated entirely to whoever holds `&mut` to the embedded field. The module exposes no in-place reconfigure: changing a limiter's configuration or runtime state is done by reading current state through the getters, constructing a fresh `RateLimiter`, and overwriting the field. The library validates structural invariants on construction; the choice of reconfiguration *semantics* is the integrator's.

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

**Enforcement:** The type system denies the abilities required to live as a top-level Sui object or to be copied. The limiter has `store + drop` only.

---

### INV-T2: Variant identity is immutable

**Statement:** A `RateLimiter` is exactly one of `Bucket | FixedWindow | Cooldown`. The variant is fixed at construction. No public path can change it: the only `&mut` operations (`try_consume`, `consume_or_abort`) preserve the input variant. To switch variant — or to change any immutable configuration field — the integrator must construct a fresh `RateLimiter` and overwrite the field.

**Why it matters:** A mid-flight variant swap would silently change the rate-limiting policy without consumer awareness — e.g., a `Cooldown` becoming a `Bucket` reinterprets every subsequent consume.

**Enforcement:** Variant identity is preserved across every `&mut` operation; no public path produces a value of a different variant from its input. Reconfiguration is delegated to the integrator's reconstruct-and-overwrite pattern, which always yields a deliberately chosen variant.

## Runtime Invariants

### INV-R1: Bucket config positivity

**Statement:** On `new_bucket`: `capacity > 0 ∧ refill_amount > 0 ∧ refill_interval_ms > 0`.

**Why it matters:** A zero `refill_interval_ms` or `refill_amount` leaves the accrual computation undefined; a zero `capacity` makes the bucket permanently empty. Either way, the limiter is unusable or unsafe.

**Enforcement:** Construction rejects any `Bucket` config that does not satisfy the positivity conjunction.

---

### INV-R2: FixedWindow config positivity

**Statement:** On `new_fixed_window`: `capacity > 0 ∧ window_ms > 0`.

**Why it matters:** A zero `window_ms` leaves the window-roll computation undefined; a zero `capacity` makes every consume fail.

**Enforcement:** Construction rejects any `FixedWindow` config that does not satisfy the positivity conjunction.

---

### INV-R3: Cooldown config positivity

**Statement:** On `new_cooldown`: `capacity > 0 ∧ cooldown_ms > 0`. No upper bound on `cooldown_ms` is enforced (see Operator Responsibilities).

**Why it matters:** A zero `cooldown_ms` defeats the variant by letting every consume succeed; a zero `capacity` freezes the limiter forever.

**Enforcement:** Construction rejects any `Cooldown` config that does not satisfy the positivity conjunction.

---

### INV-R4: Initial available bounded

**Statement:** On every constructor (`new_bucket`, `new_fixed_window`, `new_cooldown`): `initial_available ≤ capacity`. This is the knob that lets integrators start a limiter empty (forcing a pre-roll wait), partly full, or full. A `Cooldown` may legitimately start with `initial_available == 0` (see INV-R6 and INV-S8 for the resulting gated/released states).

**Why it matters:** A limiter starting above its own capacity violates per-variant capacity bounds (INV-S1/S2/S3) from the very first call, breaking the central capacity guarantee before any consume runs.

**Enforcement:** Construction rejects `initial_available > capacity` on every variant.

---

### INV-R5: Time anchors are not in the future

**Statement:** On `new_bucket`: `last_refill_ms ≤ now`. On `new_fixed_window`: `window_start_ms ≤ now`. (`now` is the construction-time `Clock` reading.)

**Why it matters:** Every elapsed-time projection computes `now' - anchor` at a later call site. A future anchor combined with clock monotonicity would still leave `anchor > now'` for some interval, underflowing the subtraction (INV-A1). Rejecting future anchors at construction, plus `Clock` monotonicity, keeps `anchor ≤ now'` at every subsequent call.

**Enforcement:** Construction rejects an anchor strictly greater than the current clock reading for the two bucket-shaped variants. (Cooldown stores an absolute deadline, not an elapsed-time anchor, and is governed by INV-R6 instead.)

---

### INV-R6: Cooldown seed consistency

**Statement:** On `new_cooldown`, the combination `initial_available > 0 ∧ cooldown_end_ms > now` is rejected. Every other pairing is accepted:
- `initial_available > 0 ∧ cooldown_end_ms ≤ now` — greenfield / granted: up to `initial_available` units consumable before the first gate arms.
- `initial_available == 0 ∧ cooldown_end_ms > now` — in-flight gate: reconstructing a limiter mid-throttle.
- `initial_available == 0 ∧ cooldown_end_ms ≤ now` — released gate: projects to fully available on the next read or consume.

**Why it matters:** The hot path consults `cooldown_end_ms` only while `available == 0`. A seed with `available > 0` *and* an armed future deadline is self-contradictory: the deadline would be silently dropped the next time the batch drains, misrepresenting the limiter's state to anyone who reconstructed it expecting that gate to hold.

**Enforcement:** Construction rejects the contradictory pairing; all other seeds are admitted and interpreted by the Cooldown state machine (INV-S8).

---

### INV-R7: Consume amount positivity

**Statement:** `try_consume` and `consume_or_abort` require `amount > 0`. A zero-unit consume aborts (it is a programmer error, not a rate-limit decision), keeping behavior uniform across all three variants.

**Why it matters:** Treating `amount == 0` as a rate-limit outcome would force callers to disambiguate "denied" from "asked for nothing", and would differ per variant (a zero draw trivially "succeeds" against any non-empty state but is meaningless). Aborting makes the contract unambiguous.

**Enforcement:** The consume entry points assert positivity before any variant logic runs.

---

### INV-R8: Variant-typed getters reject the wrong variant

**Statement:** The variant-specific getters (`refill_amount`, `refill_interval_ms`, `last_refill_ms`, `window_ms`, `window_start_ms`, `cooldown_ms`, `cooldown_end_ms`) abort with the variant error when called on a limiter of a different variant. The variant-agnostic getter `capacity` never aborts.

**Why it matters:** These getters exist so an integrator can snapshot a limiter's state before reconstructing it. Returning a meaningless field from the wrong variant would let the integrator rebuild a limiter from garbage state; aborting gives a stable, self-diagnosing error surface.

**Enforcement:** Each variant-typed getter matches on the variant and aborts on any non-matching variant.

## Arithmetic Safety Invariants

### INV-A1: Elapsed-time subtraction is safe

**Statement:** Computations of the form `now - anchor` (Bucket refill anchor, FixedWindow window anchor — both on the consume path and in the projecting getters) never underflow within the limiter's reachable state.

**Why it matters:** A silent underflow would re-credit time, advance windows incorrectly, or release gates spuriously — all of which inflate the effective rate.

**Enforcement:** Constructors reject future anchors (INV-R5), and the stored anchor only ever advances forward in whole steps bounded by `now` (INV-S4, INV-S5, INV-S6). Combined with `Clock` monotonicity (see Assumed (External) Invariants), `anchor ≤ now` holds at every subtraction site. If clock monotonicity is ever violated, the subtraction aborts fail-closed rather than wrapping.

---

### INV-A2: Refill accumulation is bounded (Bucket and FixedWindow)

**Statement:** Bucket-shaped accrual never produces a value of `available` outside `[0, capacity]`. Intermediate computations of credited tokens are bounded by `capacity` before being added to `available`. This covers both `Bucket` and `FixedWindow`, which share the same accrual routine (`FixedWindow` is the special case where one elapsed window credits exactly `capacity`).

**Why it matters:** An unbounded accrual could overflow `u64` after long idle periods or aggressive `refill_amount` settings, producing wrap-around values that violate INV-S1/S2 and INV-E1.

**Enforcement:** Credited tokens are clipped to the available headroom before being applied, so the post-state always lands within `[0, capacity]`. The credit is derived such that no intermediate quantity can exceed `capacity`, keeping the accrual safe without requiring upper bounds on `capacity` or `refill_amount`.

---

### INV-A3: Cooldown deadline arithmetic is safe within policy-reasonable bounds

**Statement:** Computation of the cooldown deadline `now + cooldown_ms` at gate-arming during `try_consume` does not overflow within the limiter's reachable state, given any policy-reasonable `cooldown_ms` and any plausible Sui chain timestamp.

**Why it matters:** An overflow would wrap the deadline backward, releasing the gate immediately and defeating INV-E3.

**Enforcement:** Sui's `Clock` is bounded well below `u64::MAX`; the module trusts this bound and aborts fail-closed on overflow rather than wrapping. Operator responsibility for selecting a policy-reasonable `cooldown_ms` is documented in Operator Responsibilities.

## State Transition Invariants

### INV-S1: Bucket capacity bound

**Statement:** For any `Bucket` reachable through the public API, `available ≤ capacity` after every operation.

**Why it matters:** `available > capacity` would let a bucket burst past its configured maximum after a long idle period, breaking the long-run rate ceiling (INV-E1).

**Enforcement:** Accrual cannot lift `available` above `capacity` (INV-A2); consume cannot lift `available` at all; construction establishes `initial_available ≤ capacity` (INV-R4).

---

### INV-S2: FixedWindow capacity bound

**Statement:** For any `FixedWindow` reachable through the public API, `available ≤ capacity` after every operation.

**Why it matters:** `available > capacity` would exceed the per-window cap (INV-E2).

**Enforcement:** Window rollover sets `available` to exactly `capacity` (INV-A2); consume cannot lift `available`; construction establishes `initial_available ≤ capacity` (INV-R4).

---

### INV-S3: Cooldown capacity bound

**Statement:** For any `Cooldown` reachable through the public API, `available ≤ capacity` after every operation.

**Why it matters:** `available > capacity` would exceed the per-batch cap (INV-E3).

**Enforcement:** Construction establishes `initial_available ≤ capacity` (INV-R4); gate release sets `available` to exactly `capacity`; consume cannot lift `available`.

---

### INV-S4: No double-counting of elapsed time

**Statement:** Across the time-based variants (`Bucket`, `FixedWindow`), any elapsed wall-clock interval contributes to refill or window advancement *exactly once*. Time-derived credit (refill tokens or fresh-window resets) cannot be minted twice for the same interval.

**Why it matters:** Double-counting elapsed time is the central anti-inflation guarantee. If the same interval credited refill twice, or rolled the window twice, the effective rate would exceed the configured rate — violating INV-E1 and INV-E2.

**Enforcement:** Each variant's internal time anchor is non-decreasing and is advanced by the full number of whole steps elapsed at the moment credit is committed. Once an interval has advanced the anchor, that interval is no longer reachable as elapsed time on any subsequent operation. Intervals that elapse after the bucket reaches capacity are discarded by this same advance, so a later drain at the same `now` cannot re-mint them.

---

### INV-S5: Preservation of partial elapsed time across consume

**Statement:** Sub-interval elapsed time that has not yet accumulated into a full refill step (Bucket) or window step (FixedWindow) is preserved *across consume operations*. Time elapsed between step boundaries accrues toward the next step rather than being discarded by a consume.

**Why it matters:** Discarding partial elapsed time on each consume would forfeit credit under bursty load, reducing the effective refill rate below the configured rate. Frequent consumers would see strictly less throughput than the protocol promises.

**Enforcement:** On consume paths, the anchor advances only by full steps; the residue between the advanced anchor and `now` is retained for future accrual.

---

### INV-S6: FixedWindow anchor discipline on consume

**Statement:** On consume paths, the FixedWindow window anchor is non-decreasing and advances only by full window steps under the configured `window_ms`. The first window after construction has length exactly `window_ms`, anchored at `window_start_ms`.

**Why it matters:** A wall-clock-aligned anchor would collapse the first window to an arbitrary fraction of `window_ms`, breaking the per-window cap on the first turn. A backward or partial-step anchor would let an attacker reset `available` more frequently than once per `window_ms`, exceeding INV-E2.

**Enforcement:** On consume paths, the window anchor is initialized at construction and only advances forward in whole-window steps.

---

### INV-S7: Consume is all-or-nothing; failure persists no state

**Statement:** A `try_consume` (and therefore `consume_or_abort`) call is all-or-nothing. On success, the projected time state (Bucket/FixedWindow accrual or anchor advance, Cooldown gate release) is committed *and* `amount` is deducted. On failure (return `false`), no persisted state is mutated at all — neither the deduction, nor the anchor advance, nor the gate release.

Pending time transitions remain *observable* through `available()`, which always projects on read without mutating, but they are committed to storage only by a subsequent successful consume.

**Why it matters:** Conflating "denied" with "charged" would let a rejection still spend down capacity, doubly penalizing the consumer. Committing a partial projection on a failed consume would let a consumer's failing requests advance shared state in ways that don't correspond to any granted consumption, complicating reasoning about the limiter's committed state. All-or-nothing keeps the committed state a faithful record of granted consumption, while read-time projection ensures no time-derived credit is ever *lost* — it is simply deferred until the next successful consume re-derives it from the unchanged anchor.

**Enforcement:** Both the deduction and the time-state commit happen only on the success path; the failure path returns without writing any field.

---

### INV-S8: Cooldown grant/gate state machine

**Statement:** A `Cooldown` is interpreted, at any `now`, as one of three states:

- **Granted:** `available > 0` — `try_consume(amount, _)` succeeds when `amount ≤ available` and decrements `available` by `amount`. The stored `cooldown_end_ms` is not consulted.
- **Released:** `available == 0 ∧ now ≥ cooldown_end_ms` — the gate has elapsed; the next consume draws against a fresh batch of `capacity`, succeeding when `amount ≤ capacity` and decrementing by `amount`.
- **Gated:** `available == 0 ∧ now < cooldown_end_ms` — consume returns `false` until the deadline elapses.

A consume that decrements `available` to exactly `0` arms the gate by setting `cooldown_end_ms = now + cooldown_ms`. At construction the state follows from the seed (INV-R6): `initial_available > 0` starts Granted; `initial_available == 0` starts Gated or Released depending on `cooldown_end_ms`.

**Why it matters:** Reading the cooldown deadline while in the Granted state would gate a fresh limiter spuriously. Conflating the states would either over-throttle (gating in Granted/Released) or under-throttle (granting in Gated before the deadline).

**Enforcement:** The deadline is consulted only when `available == 0`; arming and release happen at well-defined transitions between the states. The constructor seed-consistency check (INV-R6) excludes the one contradictory starting state.

---

### INV-S9: Cooldown deadline monotonicity

**Statement:** Once the cooldown deadline is armed by a consume that drains `available` to `0`, no subsequent consume succeeds until the deadline elapses. Each fresh deadline is computed forward from the current monotonic clock at the moment it is armed, so the armed deadline is always `≥ now`.

**Why it matters:** A backward deadline would collapse the gate, defeating INV-E3.

**Enforcement:** Success in the Gated state requires the clock to reach the armed deadline; each fresh deadline is computed forward from the current monotonic clock at arm time.

## Economic / Protocol Invariants

### INV-E1: Bucket long-run rate ceiling

**Statement:** Over any interval `Δt` during which the limiter is not reconstructed, the maximum number of tokens consumable from a `Bucket` is at most `capacity + ⌊Δt / refill_interval_ms⌋ · refill_amount`. The bucket cannot generate value out of thin air.

**Why it matters:** Over-issuance is the central failure mode a rate limiter exists to prevent.

**Enforcement:** Implied by INV-S1 plus the step-discipline imposed by INV-S4 and INV-S5.

---

### INV-E2: FixedWindow per-window cap

**Statement:** No more than `capacity` units are consumed within any window of length `window_ms`, where the window grid is anchored per INV-S6 during periods in which the limiter is not reconstructed.

**Why it matters:** The per-window cap is the variant's defining promise; exceeding it defeats throttling.

**Enforcement:** Implied by INV-S2, INV-S4, and INV-S6.

---

### INV-E3: Cooldown minimum gap

**Statement:** When `Cooldown` transitions from Gated back to a fresh batch (Released), at least `cooldown_ms` has elapsed since the consume that armed the gate.

**Why it matters:** A bypassable cooldown defeats throttling for the variant.

**Enforcement:** Implied by INV-S8 and INV-S9.

---

### INV-E4: No double-accrual of elapsed time

**Statement:** Elapsed time contributes refill credit (Bucket) or window advancement (FixedWindow) at most once. No elapsed interval can be reused to mint additional capacity or to roll an additional window.

**Why it matters:** Double-accrual is the inflation primitive: if the same elapsed interval credited capacity twice, the effective rate would exceed the configured rate without bound under repeated triggering.

**Enforcement:** Implied by INV-S4. Time-based state transitions are monotonic and consume the elapsed interval that triggered them.

## Liveness Invariants

### INV-L1: Bucket eventually refills

**Statement:** Given a `Bucket` with `available < capacity` and no further consumes, the available capacity strictly increases on any operation that observes elapsed time of at least `refill_interval_ms`, and reaches `capacity` after at most `⌈(capacity - available) / refill_amount⌉` such observations.

**Why it matters:** Without an eventual-refill guarantee, the safety-side bounds could be satisfied by a degenerate limiter that never refills at all. Liveness ensures the protocol meaningfully progresses.

**Enforcement:** Refill credit is positive when at least one full refill step has elapsed (INV-R1, INV-S4); INV-S1 caps the result at `capacity`.

---

### INV-L2: FixedWindow eventually rolls into a fresh window

**Statement:** For any `FixedWindow`, the next operation observed at a time greater than or equal to `window_start_ms + window_ms` advances the window and resets `available = capacity`.

**Why it matters:** Without an eventual-rollover guarantee, a consumer could observe `available == 0` indefinitely even after the window has logically expired.

**Enforcement:** The window anchor advances by whole-window steps whenever an operation observes that at least `window_ms` has elapsed since the anchor (INV-S6); rollover refreshes `available` to `capacity` (INV-S2).

---

### INV-L3: Cooldown eventually ungates

**Statement:** For any `Cooldown` in the Gated state with deadline `cooldown_end_ms`, the next operation observed at time `now ≥ cooldown_end_ms` releases the gate: a successful consume resets `available = capacity` (less the consumed amount), and a read via `available()` reports `capacity`.

**Why it matters:** Without an eventual-release guarantee, the gate could be observed as armed indefinitely past its promised release, breaking the consumer's expected ungating cadence.

**Enforcement:** Gate release fires on the first operation observed at or after the armed deadline (INV-S8, INV-S9). On `available()` the release is projected on read; on `try_consume` it is committed only when the consume succeeds (INV-S7).

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
| --- | --- |
| `new_bucket` | INV-T1, INV-T2, INV-R1, INV-R4, INV-R5, INV-A2, INV-S1, INV-S4, INV-S5 |
| `new_fixed_window` | INV-T1, INV-T2, INV-R2, INV-R4, INV-R5, INV-S2, INV-S4, INV-S6 |
| `new_cooldown` | INV-T1, INV-T2, INV-R3, INV-R4, INV-R6, INV-S3, INV-S8 |
| `try_consume` | INV-R7, INV-A1, INV-A2, INV-A3, INV-S1, INV-S2, INV-S3, INV-S4, INV-S5, INV-S6, INV-S7, INV-S8, INV-S9, INV-E1, INV-E2, INV-E3, INV-E4, INV-L1, INV-L2, INV-L3, INV-C2 |
| `consume_or_abort` | INV-R7, all of `try_consume` |
| `available` | INV-A1, INV-A2, INV-S1, INV-S2, INV-S3, INV-S4, INV-S6, INV-S8, INV-L1, INV-L2, INV-L3 |
| `capacity` | INV-S1, INV-S2, INV-S3 |
| `refill_amount` | INV-R8 |
| `refill_interval_ms` | INV-R8 |
| `last_refill_ms` | INV-R8, INV-A1, INV-S4, INV-S5 |
| `window_ms` | INV-R8 |
| `window_start_ms` | INV-R8, INV-A1, INV-S6 |
| `cooldown_ms` | INV-R8 |
| `cooldown_end_ms` | INV-R8, INV-S8, INV-S9 |

## Operator Responsibilities (Out of Scope for the module)

- **Reconfiguration semantics.** The module provides no in-place reconfigure. To change configuration or runtime state, the integrator snapshots the current state via the getters (`available`, `capacity`, `last_refill_ms`, `window_start_ms`, `cooldown_end_ms`, ...), computes the desired new field values, constructs a fresh `RateLimiter`, and overwrites the field. Every reconfigure policy — preserve anchor, project then re-anchor, full reset, proportional carry, freeze or release an in-flight gate — is expressible in caller code. The library validates only structural invariants on construction (INV-R1 through INV-R6); the choice of *semantics* across a reconstruct boundary, including whether it grants or strands capacity, is the integrator's responsibility. Consumer-facing rate guarantees (INV-E1/E2/E3) hold *between* reconstructions, not *across* one.
- **Cooldown deadline overflow.** Cooldown computes `cooldown_end_ms = now + cooldown_ms` at gate-arming during `try_consume`. Sui's `Clock` is monotonic and bounded well below `u64::MAX`, but a `cooldown_ms` near `u64::MAX` would overflow this addition. Operators must pick `cooldown_ms` such that `now + cooldown_ms` cannot overflow at any plausible chain timestamp during the limiter's lifetime — any policy-meaningful value (seconds to days to years in ms) satisfies this trivially. The module enforces only positivity (INV-R3); overflow is fail-closed (INV-A3).
- **Anchor selection on reconstruction.** The constructors accept a caller-supplied `last_refill_ms` / `window_start_ms` (rejecting only future anchors, INV-R5) and a caller-supplied `cooldown_end_ms` / `initial_available` (rejecting only the contradictory armed-with-tokens pairing, INV-R6). A deliberately backdated anchor pre-credits elapsed time on the first projection. This is by design — it lets integrators preserve refill phase across a reconstruction — but means anti-retroactive-minting is the integrator's responsibility across a reconstruct boundary, not the module's.
- **Clock authenticity.** The module trusts `&Clock`; it does not defend against a malicious shared-clock substitute (Sui's `Clock` is a singleton shared object, so this is a Sui-platform property).
- **Authorization / access control inside the module.** Delegated to the parent object holding the field. The module makes no claim about who *should* be allowed to call `&mut` paths.

## Assumed (External) Invariants

- **Clock monotonicity.** Every elapsed-time computation in this module assumes `Clock::timestamp_ms()` is monotonically non-decreasing across calls. Sui's `Clock` provides this. If the assumption were ever violated, elapsed-time subtractions would underflow and abort — a fail-closed posture rather than silent corruption (INV-A1). INV-S4, INV-S6, INV-S9, and INV-E3 all rely on this.

## Out of Scope

- **In-place reconfiguration.** The module exposes no `reconfigure_*` functions; reconfiguration is delegated to the integrator's reconstruct-and-overwrite pattern (see Operator Responsibilities). The module does not specify or guarantee any cross-reconstruction continuity property.
- **Global / cross-limiter rate guarantees.** Each limiter is independent; no cross-limiter aggregate cap. Out of scope by design (INV-C1).
- **Persistence of `RateLimiter` across object lifecycles.** When the parent object is destroyed, the limiter is dropped (`has drop`). Out of scope: any "frozen state" or "transferable consumption history" use case.
- **Binary-compatible upgrades.** `RateLimiter` is a `public enum` embedded inside integrator-owned objects. Adding a new variant or new fields to an existing variant in a future package upgrade is not a binary-compatible change: any object that already stored a prior shape would fail to deserialize. Future evolution must preserve the current variant set and field layouts, or ship as a parallel `RateLimiterV2` type with a migration path, not as an in-place enum extension.

## Dev Notes

- **Authorization model is the central design decision.** The limiter delegates 100% of access control to the holder of `&mut` to the parent field. This is what makes the primitive embeddable, registry-less, and PTB-friendly. Any future "shared rate limiter" feature would require fundamentally different primitives.
- **Reconfigure-by-reconstruction.** Rather than ship in-place `reconfigure_*` functions with a fixed continuity policy, the module exposes the inner fields through getters and lets the integrator construct a fresh limiter with the state they want. The bucket-shaped anchor getters (`last_refill_ms`, `window_start_ms`) take a `&Clock` and return the *projected* anchor at `now`, so they pair coherently with `available(&self, clock)` for snapshotting. `cooldown_end_ms` returns the stored value as-is (a deadline does not evolve with time) and is only meaningful when `available(clock) == 0`. This keeps the module's surface minimal and pushes every reconfigure-semantics decision to the call site, where the integrator has the context to choose it.
- **Anchor-based windows.** `FixedWindow` windows are anchored at `window_start_ms` (INV-S6); the first window always has length exactly `window_ms`. `FixedWindow` shares the `Bucket` accrual routine internally — it is the case where one elapsed window credits exactly `capacity` — which is why INV-A2, INV-S4, and INV-S5 apply to both.
- **Cooldown stores `available` and `cooldown_end_ms`.** The design tracks remaining capacity directly and stores the absolute release deadline; the gate predicate compares the clock against the deadline only while `available == 0`. This is symmetric with the other variants' `available` field, and lets a `Cooldown` be reconstructed mid-throttle (`initial_available == 0` with an in-flight `cooldown_end_ms`) — subject to the seed-consistency check (INV-R6).
- **Failed consume commits nothing.** `try_consume` is all-or-nothing (INV-S7): a failed consume leaves every persisted field untouched. Pending time transitions are never lost because `available()` re-projects them on read and the next successful consume re-derives them from the unchanged anchor.

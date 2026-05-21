---
stage: review
project: openzeppelin_utils::rate_limiter
mode: standalone
extends: null
status: draft
timestamp: 2026-05-21
author: claude-opus-4-7
previous_stage: null
tags: [rate-limiter, sui, move, utils]
---

# `rate_limiter` — Basic Review Report

## Summary

**0 Critical, 0 High, 0 Medium, 6 Informational.**

The module is arithmetically sound and well-documented. The prior-review Medium
(`new_cooldown(cap, cd, 0)` silently behaving as full capacity) has been resolved
by adding `EZeroCooldownInitial` (commit `1c5b4e0`). Every public path validates
its config; the variant guard precedes config validation across all three
`reconfigure_*`; the bucket accrual overflow proof holds; and `available()` is
consistent with `try_consume()` for all variants.

Remaining findings are documentation gaps and test-coverage asymmetries. None
block publishing.

**Overall verdict:** Ready for publishing. Optional documentation / test
polish before tagging.

---

## Invariant Verification

No formal invariants document is present in the working tree (a prior
`rate-limiter/03-invariants.md` was removed in commit `850cdac`). Invariants
below were reconstructed from the module-level docs, the README, and that
prior artifact (recovered from git history) and verified against the current
implementation.

| Invariant | Enforced? | Location | Notes |
|-----------|-----------|----------|-------|
| **Type:** Embeddable, non-duplicable (`store + drop` only) | ✅ | [rate_limiter.move:84](contracts/utils/sources/rate_limiter.move#L84) | No `key`, no `copy` |
| **Type:** Variant identity immutable; no public path produces a different variant from its input | ✅ | All `reconfigure_*` match a single variant and abort `EWrongVariant` otherwise | INV preserved across reconfigure |
| **Runtime:** Bucket config positivity (`capacity, refill_amount, refill_interval_ms > 0`) | ✅ | [rate_limiter.move:147-149](contracts/utils/sources/rate_limiter.move#L147-L149), [:397-399](contracts/utils/sources/rate_limiter.move#L397-L399) | Both constructor and reconfigure |
| **Runtime:** FixedWindow config positivity (`capacity, window_ms > 0`) | ✅ | [rate_limiter.move:183-184](contracts/utils/sources/rate_limiter.move#L183-L184), [:451-452](contracts/utils/sources/rate_limiter.move#L451-L452) | |
| **Runtime:** Cooldown config positivity (`capacity, cooldown_ms > 0`) | ✅ | [rate_limiter.move:218-219](contracts/utils/sources/rate_limiter.move#L218-L219), [:502-503](contracts/utils/sources/rate_limiter.move#L502-L503) | |
| **Runtime:** `initial_available ≤ capacity` for Bucket / FixedWindow / Cooldown | ✅ | [:150](contracts/utils/sources/rate_limiter.move#L150), [:185](contracts/utils/sources/rate_limiter.move#L185), [:221](contracts/utils/sources/rate_limiter.move#L221) | |
| **Runtime:** Cooldown rejects `initial_available == 0` (post-consumption gate has nothing to attach to) | ✅ | [rate_limiter.move:220](contracts/utils/sources/rate_limiter.move#L220) | Resolves prior MED-1 |
| **Runtime:** Variant guard precedes config validation on `reconfigure_*` | ✅ | Match arm structure across all three reconfigures | Tested at `reconfigure_*_priority_variant_over_invalid_config` |
| **Arithmetic:** Elapsed-time subtractions safe under clock monotonicity | ✅ | Clock anchors set with `clock.timestamp_ms()` and non-decreasing; underflow would `abort` fail-closed | |
| **Arithmetic:** Bucket accrual stays in `[0, capacity]`; no overflow regardless of `refill_amount`, `capacity`, `elapsed_steps` | ✅ | [rate_limiter.move:541-569](contracts/utils/sources/rate_limiter.move#L541-L569) | Two-branch split: fill-branch writes `capacity` directly; under-fill branch bounded by headroom |
| **Arithmetic:** Cooldown deadline `now + cooldown_ms` overflow safety | ⚠️ Operator-side | [rate_limiter.move:306-309](contracts/utils/sources/rate_limiter.move#L306-L309), [:510-512](contracts/utils/sources/rate_limiter.move#L510-L512) | Documented as operator responsibility; module enforces only positivity; fails closed on overflow |
| **State:** `available ≤ capacity` after every public op (all three variants) | ✅ | Construction asserts; accrual caps at capacity; consume cannot lift; reconfigure clamps with `.min(capacity)` | |
| **State:** No double-counting of elapsed time (anchors monotonic, advance once per credited interval) | ✅ | Bucket `new_last = last + steps*interval`; FixedWindow anchor advances by whole steps | |
| **State:** Bucket preserves sub-interval remainder across `try_consume` | ✅ | [rate_limiter.move:560](contracts/utils/sources/rate_limiter.move#L560) | Anchor advances only by `elapsed_steps * refill_interval_ms`, not to `now` |
| **State:** Bucket discards overflow intervals (full bucket + idle time) so they cannot re-mint at next drain | ✅ | [rate_limiter.move:560](contracts/utils/sources/rate_limiter.move#L560), [:566](contracts/utils/sources/rate_limiter.move#L566) | Both branches advance `new_last` by the full `elapsed_steps * refill_interval_ms` |
| **State:** Failed `try_consume` does not deduct `available` (all variants) | ✅ | Early `return false` precedes `*available = ...` assignment | |
| **State:** Failed `try_consume` may still commit time-derived transitions (window roll / gate release) for FixedWindow / Cooldown | ✅ (by design) | [:286-293](contracts/utils/sources/rate_limiter.move#L286-L293), [:298-302](contracts/utils/sources/rate_limiter.move#L298-L302) | Bucket does NOT — asymmetric; see INFM-1 |
| **State:** Cooldown grant/gate state machine — gate armed iff `available` decremented exactly to 0 | ✅ | [rate_limiter.move:305-310](contracts/utils/sources/rate_limiter.move#L305-L310) | |
| **State:** `reconfigure_*` clamps `available` to new capacity | ✅ | All three: `.min(capacity)` or direct assignment after rollover | |
| **State:** Cooldown reconfigure semantics (resets in-flight deadline to `now + new_cooldown_ms` when post-clamp `available == 0`) | ✅ (per current spec) | [rate_limiter.move:509-513](contracts/utils/sources/rate_limiter.move#L509-L513) | Diverges from earlier draft spec which would preserve the in-flight deadline; current spec is locked in by `cooldown_reconfigure_resets_in_flight_deadline` |
| **Economic:** Long-run rate ceilings (Bucket: `capacity + ⌊Δt/interval⌋·refill`; FixedWindow: `capacity` per window; Cooldown: `capacity` per `cooldown_ms` gap) | ✅ | Implied by state invariants above | |
| **Liveness:** Refill / rollover / ungate fires on the first call observing the relevant elapsed time | ✅ | `if (elapsed_steps == 0) return ...` / `if (steps != 0)` / `now >= cooldown_end_ms` checks | |
| **Composability:** No global state, no PTB ordering, no transaction-scoped accumulator | ✅ | Embedded `store + drop` value, no `key`, no shared reads except `&Clock` | |

---

## Findings

### Critical

None.

### High

None.

### Medium

None.

### Informational

#### INFM-1: FixedWindow and Cooldown commit time transitions on a failed `try_consume`; Bucket does not

**Location:** [rate_limiter.move:266-285](contracts/utils/sources/rate_limiter.move#L266-L285) (Bucket arm),
[rate_limiter.move:286-297](contracts/utils/sources/rate_limiter.move#L286-L297) (FixedWindow arm),
[rate_limiter.move:298-312](contracts/utils/sources/rate_limiter.move#L298-L312) (Cooldown arm)

**Issue:**

For Bucket, `try_consume` commits no field updates on failure: `*available` and
`*last_refill_ms` are written only inside the success branch. For FixedWindow,
the window-rollover writes (`*window_start_ms`, `*available = *capacity`)
execute before the amount check — so a `try_consume(amount > capacity)` that
crosses a window boundary returns `false` but leaves the window advanced and
the new window fully available. For Cooldown, gate release (`*available =
*capacity`) executes before the amount check — same shape.

This is consistent with the design intent (the window/batch genuinely opened
once the boundary was crossed), but it is asymmetric across variants, and the
existing `*_failed_try_consume_does_not_*` tests only exercise the same-window
/ mid-cooldown cases, which can give a false impression of "no state change on
failure."

**Recommendation:**

1. Add cross-boundary regression tests to lock in the intended semantics:

```move
#[test]
fun fixed_window_rollover_commits_even_on_failed_try_consume() {
    let (test, mut clk) = setup(0);
    let mut rl = rate_limiter::new_fixed_window(5, 100, 5, &clk);
    rl.consume_or_abort(3, &clk); // available = 2

    clk.set_for_testing(100); // cross window boundary
    assert!(!rl.try_consume(6, &clk)); // fails (oversized) but window rolled

    assert_eq!(rl.available(&clk), 5); // new window, full capacity
    teardown(test, clk);
}

#[test]
fun cooldown_gate_release_commits_even_on_failed_try_consume() {
    let (test, mut clk) = setup(0);
    let mut rl = rate_limiter::new_cooldown(5, 50, 5);
    assert!(rl.try_consume(5, &clk)); // armed; deadline = 50

    clk.set_for_testing(50);
    assert!(!rl.try_consume(6, &clk)); // oversized; but gate releases

    assert_eq!(rl.available(&clk), 5);
    teardown(test, clk);
}
```

2. Add one sentence to the `try_consume` doc comment in
[rate_limiter.move:247-261](contracts/utils/sources/rate_limiter.move#L247-L261):
> For `FixedWindow` and `Cooldown`, window rollover and cooldown release are
> applied eagerly even if the subsequent amount check returns `false`. For
> `Bucket`, no field update happens on failure.

**Status:** Open

---

#### INFM-2: Missing `expected_failure` tests for several `reconfigure_*` validation paths

**Location:** [rate_limiter_tests.move:417-441](contracts/utils/tests/rate_limiter_tests.move#L417-L441)

**Issue:**

The reconfigure paths assert positivity on every config field, but the test
suite only covers one positivity assertion per reconfigure variant. The
following code-level assertions have no test:

| Missing test | Assertion site |
|---|---|
| `reconfigure_bucket` with zero `refill_amount` | [rate_limiter.move:398](contracts/utils/sources/rate_limiter.move#L398) |
| `reconfigure_bucket` with zero `refill_interval_ms` | [rate_limiter.move:399](contracts/utils/sources/rate_limiter.move#L399) |
| `reconfigure_fixed_window` with zero `capacity` | [rate_limiter.move:451](contracts/utils/sources/rate_limiter.move#L451) |
| `reconfigure_cooldown` with zero `capacity` | [rate_limiter.move:502](contracts/utils/sources/rate_limiter.move#L502) |

**Recommendation:** Mirror the existing constructor tests at
[rate_limiter_tests.move:372-415](contracts/utils/tests/rate_limiter_tests.move#L372-L415):

```move
#[test, expected_failure(abort_code = rate_limiter::EZeroRefillAmount)]
fun reconfigure_bucket_rejects_zero_refill_amount() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_bucket(10, 1, 10, 10, &clk);
    rl.reconfigure_bucket(10, 0, 10, &clk);
    abort
}
// ...etc for the other three
```

**Status:** Open

---

#### INFM-3: `try_consume_with_zero_amount_aborts` only exercises the Bucket variant

**Location:** [rate_limiter_tests.move:310-316](contracts/utils/tests/rate_limiter_tests.move#L310-L316)

**Issue:**

`assert!(amount > 0, EInvalidAmount)` at
[rate_limiter.move:263](contracts/utils/sources/rate_limiter.move#L263) sits
before the `match`, so it fires for every variant. The test only constructs a
Bucket, leaving FixedWindow and Cooldown branches untested for this abort code.

**Recommendation:** Add `try_consume_with_zero_amount_aborts_fixed_window` and
`try_consume_with_zero_amount_aborts_cooldown` analogous to the existing test.
Low-value individually, but cheap, and locks in the documented uniform
behavior across variants.

**Status:** Open

---

#### INFM-4: `try_consume(self.available(clock), clock)` aborts when the limiter has `available == 0`

**Location:** [rate_limiter.move:262-263](contracts/utils/sources/rate_limiter.move#L262-L263),
[rate_limiter.move:328-358](contracts/utils/sources/rate_limiter.move#L328-L358)

**Issue:**

The naive "consume everything I have" idiom

```move
let n = rl.available(clock);
rl.try_consume(n, clock);
```

aborts with `EInvalidAmount` whenever `n == 0` — i.e., whenever a Bucket is
empty, a FixedWindow is exhausted inside the current window, or a Cooldown is
actively gated. The three `*_available_predicts_try_consume` tests
([rate_limiter_tests.move:768-806](contracts/utils/tests/rate_limiter_tests.move#L768-L806))
exercise the positive case but never call `try_consume(0, ...)` after
observing `available == 0`, so the footgun is invisible from the tests.

The `try_consume` doc comment notes that zero amount is a programmer error
([rate_limiter.move:249-250](contracts/utils/sources/rate_limiter.move#L249-L250)),
but does not state explicitly that the `try_consume(available(...))` idiom is
unsafe without a guard.

**Recommendation:**

Add a brief usage note to the `available` doc comment in
[rate_limiter.move:316-327](contracts/utils/sources/rate_limiter.move#L316-L327)
(it's the most discoverable site for the pattern):

> Note: `try_consume(self.available(clock), clock)` aborts when `available()`
> returns `0`. Guard with `if n > 0 { self.try_consume(n, clock) }` or branch
> on `available()` directly.

Optionally add a test that documents the abort:

```move
#[test, expected_failure(abort_code = rate_limiter::EInvalidAmount)]
fun try_consume_of_available_aborts_when_drained() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_bucket(10, 1, 1_000, 10, &clk);
    rl.consume_or_abort(10, &clk);
    rl.try_consume(rl.available(&clk), &clk); // available()==0, aborts
    abort
}
```

**Status:** Open

---

#### INFM-5: Upgrade-safety constraint of `public enum RateLimiter` is not documented

**Location:** [rate_limiter.move:84-116](contracts/utils/sources/rate_limiter.move#L84-L116),
[CHANGELOG.md](CHANGELOG.md)

**Issue:**

`RateLimiter` is a `public enum` embedded inside integrator-owned objects.
Adding a new variant or new fields to an existing variant in a future package
upgrade would break BCS deserialization of any object that already stored a
prior shape — a general Sui/Move constraint, not a code defect. No code-bug
risk today, but maintainers may not realize the variant set is effectively
frozen post-publication. The CHANGELOG `openzeppelin_utils` block does not
flag this.

**Recommendation:**

Add a one-line note to the module-level doc (around
[rate_limiter.move:8-12](contracts/utils/sources/rate_limiter.move#L8-L12),
the "three strategies" paragraph) or to the CHANGELOG entry for the rate
limiter:

> Adding variants or fields to `RateLimiter` post-publication is not a
> binary-compatible upgrade; integrators that embed it must migrate their
> objects, or maintain a parallel `RateLimiterV2` type.

**Status:** Open (documentation gap, not a code defect)

---

#### INFM-6: `reconfigure_cooldown` always re-arms a fresh deadline when post-clamp `available == 0`

**Location:** [rate_limiter.move:489-517](contracts/utils/sources/rate_limiter.move#L489-L517),
locked in by [rate_limiter_tests.move:567-599](contracts/utils/tests/rate_limiter_tests.move#L567-L599)
and [:845-873](contracts/utils/tests/rate_limiter_tests.move#L845-L873)

**Issue:**

`reconfigure_cooldown` overwrites `cooldown_end_ms` to `now + new_cooldown_ms`
whenever post-clamp `available == 0` — three sub-cases collapse into this one
branch:

1. **Mid-cooldown gate (deadline not yet elapsed):** old deadline replaced
   with `now + new_cooldown_ms`. Lengthens or shortens the wait depending on
   `new_cooldown_ms` and elapsed time.
2. **Drained but deadline already elapsed (gate logically released, not yet
   observed):** a fresh `cooldown_ms` is armed instead of letting the next
   `try_consume` fall through to "release + reset to capacity." Consumer is
   penalized with a second cooldown.
3. **Clamp drives an already-drained-batch state into the new capacity:**
   same as case 2.

Cases 1 and 2 are intentional and tested. Case 1 (operator can shorten an
in-flight gate by reconfiguring with a shorter `cooldown_ms`) is a deliberate
operator power; case 2 is the explicit subject of
`cooldown_reconfigure_rearms_when_drained_and_deadline_elapsed`. Both are
documented in the module doc-comment at
[rate_limiter.move:471-477](contracts/utils/sources/rate_limiter.move#L471-L477)
and in the README operator notes.

Calling this out as informational because it's an unusual choice — most
"reconfigure" primitives are pass-through w.r.t. timing state. An operator
who reconfigures during normal traffic without realizing a gate is in-flight
can end up either releasing it early or extending it. Worth keeping the
explicit warning visible.

**Recommendation:**

The current docs are adequate. As a polish, consider adding a single
sentence to the `reconfigure_cooldown` doc-comment summary explicitly stating
the operator-side effect:

> Reconfigure is *not* idempotent w.r.t. an in-flight gate: calling it while
> a cooldown is armed (`available == 0`) restarts the wait from `now` under
> the new `cooldown_ms`.

No code change.

**Status:** Open (informational; documented behavior, surfaced for review
visibility)

---

## Security Checklist Results

| Category | Result | Notes |
|----------|--------|-------|
| **3.1 Access Control** | ✅ Pass | Authorization-agnostic by design; every `&mut` path is gated by whoever holds the parent object reference. Module makes no claim about who *should* call any function. |
| **3.2 Object Safety** | ✅ Pass | `store + drop` value; no `key`, no `UID`, no shared object, no dynamic fields, no ID comparisons needed. Dropping the parent drops the limiter. |
| **3.3 Arithmetic Safety** | ✅ Pass | All subtractions reduce to monotonic-clock differences, fail-closed on violation. `bucket_accrue` two-branch split avoids large products. `now + cooldown_ms` is the only documented operator-side overflow risk (INV-A3). |
| **3.4 Type Safety** | ✅ Pass | No generics, no phantom types, no witness patterns. Variant guard precedes config validation in every `reconfigure_*`, locking variant identity. |
| **3.5 Reentrancy / Composability** | ✅ Pass | No external calls, no shared objects (except `&Clock`), no cross-PTB state. Limiter scope is the parent object. |
| **3.6 Economic Security** | ✅ N/A | Module handles no coins, no balances, no value of its own. Economic guarantees are over an abstract "unit" the integrator defines. |
| **3.7 Upgrade Safety** | ⚠️ Partial | Enum structure is not forward-compatible (INFM-5). Documentation gap, not a code defect. |

---

## Test Coverage Assessment

56 tests; 100% pass. Coverage is broad and well-organized by behavior class
(constructor validation, hot-path semantics, all-or-nothing failure,
sub-interval preservation, reconfigure-under-old-rules-first, anchor-based
windows, overflow safety, `available()`/`try_consume()` consistency,
`consume_or_abort` cross-variant, cooldown reconfigure re-arm).

Gaps, all informational and all addressed in findings above:

- INFM-1: cross-boundary failed-consume not exercised for FixedWindow /
  Cooldown.
- INFM-2: four missing `reconfigure_*` config-validation tests.
- INFM-3: `EInvalidAmount` only exercised on Bucket.
- INFM-4: `try_consume(available(...))` footgun not tested.

The bucket accrual stress tests
([rate_limiter_tests.move:691-720](contracts/utils/tests/rate_limiter_tests.move#L691-L720))
covering `refill_amount > capacity` and `cap ≈ u64::MAX` are particularly
good — they pin down the two-branch overflow proof structurally rather than
spot-checking.

---

## Recommendation

- **Overall verdict:** Ready for publishing.
- **Blocking issues:** None.
- **Suggested improvements before tagging:**
  - INFM-1, INFM-2, INFM-3: low-cost test additions (≈ 8 tests, all
    short).
  - INFM-4, INFM-5, INFM-6: short doc-comment additions in the module / the
    CHANGELOG entry.
- **Defer:** Nothing material to defer.

---

## Out of Scope

- **`openzeppelin_access` modules** (`access_control`, `delayed`, `two_step`).
  Not on the rate-limiter branch's review scope; covered by prior audits per
  `audits/README.md`.
- **`openzeppelin_fp_math` and `openzeppelin_math` packages.** Out of scope
  by package; audited separately.
- **Sui `Clock` security.** Trusted as a Sui-platform property (singleton
  shared object, monotonic). The module's INV-A1 / INV-A3 fail-closed on a
  violation; no defense-in-depth needed at this layer.
- **Gas optimization.** Review targeted correctness and security only.
- **Formal verification of the bucket accrual proof.** The in-comment proof
  at [rate_limiter.move:551-563](contracts/utils/sources/rate_limiter.move#L551-L563)
  was hand-checked but not machine-verified. Sufficient for this review tier.

---

## Dev Notes

- **Cooldown initial-available ambiguity is now closed.** The fix in commit
  `1c5b4e0` (constructor rejects `initial_available == 0`) removes the entire
  surface that prior MED-1 covered. The integrator pattern for "force a wait
  before the first batch" is now correctly delegated to the enclosing object's
  lifecycle, as the module doc states at
  [rate_limiter.move:199-202](contracts/utils/sources/rate_limiter.move#L199-L202).
- **Bucket accrual is the load-bearing arithmetic.** The two-branch
  `bucket_accrue` is the highest-risk surface in the module, and the proof
  structure (under-fill branch bounded by `headroom`; fill branch writes
  `capacity` directly without computing the credit product) is robust against
  `refill_amount > capacity`, `cap ≈ u64::MAX`, and extreme `elapsed_steps`.
  The inline comments are good; the regression tests
  ([:691-720](contracts/utils/tests/rate_limiter_tests.move#L691-L720)) lock
  this in.
- **Anchor-based windows for FixedWindow are correctly aligned with the
  documented contract.** The previous wall-clock-aligned implementation
  (referenced in the test
  [:738-763](contracts/utils/tests/rate_limiter_tests.move#L738-L763))
  would have produced fractional first windows; the current anchored-at-`now`
  version is the right call and is tested.

---

## Open Questions

1. **Should the prior invariants document
   (`rate-limiter/03-invariants.md`, deleted in `850cdac`) be restored and
   updated to match the current Cooldown-reconfigure semantics (INV-S12 in
   the old doc preserved an in-flight deadline; the implementation resets
   it)?** Restoring would give downstream consumers a versioned, normative
   spec; the alternative is to rely on the module-level doc-comments + the
   tests. Out of scope for this review; flagging for the maintainer.
2. **Should the same review pass cover the recent math-module changes on
   this branch?** Per `git log main..rate-limiter`, the branch carries 68
   commits, most touching only the rate limiter. If non-rate-limiter changes
   slipped onto this branch, they should be reviewed separately or
   rebased off.

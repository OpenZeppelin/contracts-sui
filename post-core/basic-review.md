---
stage: review
project: openzeppelin_utils::rate_limiter
mode: standalone
extends: null
status: draft
timestamp: 2026-05-20
author: claude-sonnet-4-6
previous_stage: null
tags: [rate-limiter, sui, move, utils]
---

# `rate_limiter` — Basic Review Report

## Summary

**1 Medium, 5 Informational.** No Critical or High findings.

The implementation is arithmetically sound, correctly documented for most behavior,
and has good test coverage of the happy paths and many edge cases. One behavioral
inconsistency in the `Cooldown` constructor is the only finding that could surprise
an integrator in a security-relevant way. Everything else is test coverage gaps or
asymmetries that should be documented.

**Overall verdict:** Ready for publishing with the Medium fixed (or explicitly
documented as intentional).

---

## Invariant Verification

No formal invariants document exists; invariants are inferred from the module
documentation and implementation.

| Invariant | Enforced? | Location | Notes |
|-----------|-----------|----------|-------|
| `available <= capacity` at all times | ✅ Yes | All constructors assert `initial_available <= capacity`; `reconfigure_*` clamps via `.min(capacity)`; `bucket_accrue` caps at `capacity` | |
| Config fields (capacity, refill_amount, etc.) > 0 | ✅ Yes | `assert!` at top of each constructor and reconfigure | |
| `initial_available <= capacity` | ✅ Yes | `EInitialAboveCapacity` guard in all three constructors | |
| `try_consume` is all-or-nothing (no partial drain on failure) | ✅ Bucket; ⚠️ FixedWindow / Cooldown | See INFM-1 | Bucket never commits state on failure; FixedWindow/Cooldown commit window advance / available reset even on a failed consume when a time boundary is crossed |
| Bucket accrual stays overflow-safe | ✅ Yes | `bucket_accrue`: under-fill branch bounded by headroom; fill branch writes `capacity` directly | |
| `available()` agrees with `try_consume` (calling `try_consume(available())` succeeds) | ✅ Yes for Bucket/FixedWindow; ⚠️ Cooldown | See INFM-4 | When Cooldown is actively gated, `available()` returns 0 and `try_consume(0)` aborts rather than returning false |
| Cooldown gate arms when batch is drained by a consume | ✅ Yes | `try_consume` line 295-298: gate armed iff `*available == 0` after deduction | |
| `new_cooldown(cap, cd, 0)` starts with 0 available | ❌ Missing | `new_cooldown` lines 210-216 | `available()` returns `cap`; first `try_consume` succeeds immediately — see MED-1 |

---

## Findings

### Medium

#### MED-1: `new_cooldown` with `initial_available = 0` silently starts at full capacity

**Location:** [rate_limiter.move:205-216](contracts/utils/sources/rate_limiter.move#L205-L216),
[rate_limiter.move:339-344](contracts/utils/sources/rate_limiter.move#L339-L344)

**Issue:**

`new_cooldown(capacity, cooldown_ms, 0)` sets `available = 0` and
`cooldown_end_ms = 0`. At any call time `now >= 0`, both `available()` and
`try_consume` treat this as "cooldown has already elapsed" and immediately
provide the full `capacity`:

```move
// available()
if (*available > 0) *available          // false
else if (now >= *cooldown_end_ms) *capacity  // 0 >= 0 → true → returns capacity
else 0
```

```move
// try_consume
if (*available == 0) {
    if (now < *cooldown_end_ms) return false;  // 0 < 0 → false, not taken
    *available = *capacity;                    // resets to capacity before amount check
};
```

By contrast, `new_bucket(cap, ra, ri, 0, clock)` truly starts empty —
`available()` returns 0 and `try_consume` fails until accrual. The other
variants honor `initial_available = 0` as "nothing available." Cooldown does not.

**Impact:**

An integrator who calls `new_cooldown(cap, cd, 0)` expecting to start in a
"drained / locked" state — forcing callers to wait for a first cooldown before
the batch is granted — would actually give callers immediate full capacity.
There is no way to construct a `Cooldown` that starts in a gated state without
consuming first.

**Recommendation:**

Option A (simplest) — Document the behavior explicitly in `new_cooldown`'s
doc comment and in the README. Add a note that `initial_available = 0` is
semantically equivalent to `initial_available = capacity` for the Cooldown
variant: since no consume has ever drained the batch, no gate has been armed.
A warning that this differs from Bucket and FixedWindow is essential.

Option B (stricter) — Treat `cooldown_end_ms` as a sentinel for "never set"
by storing it as `Option<u64>`, or accept a `clock: Option<&Clock>` parameter
in `new_cooldown` so callers can arm the gate at construction time. This is
a larger API change.

Option A is recommended; Option B adds complexity not required by the current
design.

**Add a test to document the behavior:**
```move
#[test]
fun cooldown_with_zero_initial_available_is_immediately_grantable() {
    let (test, clk) = setup(0);
    // initial_available = 0 does NOT gate the first batch;
    // available() shows capacity immediately.
    let mut rl = rate_limiter::new_cooldown(5, 50, 0);
    assert_eq!(rl.available(&clk), 5);
    assert!(rl.try_consume(3, &clk));
    teardown(test, clk);
}
```

**Status:** Open

---

### Informational

#### INFM-1: FixedWindow and Cooldown commit state on a failed `try_consume` during a boundary crossing; Bucket does not

**Location:** [rate_limiter.move:273-283](contracts/utils/sources/rate_limiter.move#L273-L283)
(FixedWindow arm), [rate_limiter.move:285-299](contracts/utils/sources/rate_limiter.move#L285-L299) (Cooldown arm),
[rate_limiter.move:253-272](contracts/utils/sources/rate_limiter.move#L253-L272) (Bucket arm)

**Issue:**

For Bucket, state (`available`, `last_refill_ms`) is committed only if the
consume succeeds. For FixedWindow and Cooldown, state is committed in two phases:

1. Window advance / gate release — happens eagerly, before the amount check.
2. Balance deduction — happens only on success.

So a call to `try_consume(amount > capacity)` when a window just rolled or a
cooldown just elapsed returns `false` but leaves `window_start_ms` advanced and
`available = capacity`. The next call with a valid amount will succeed. The state
is always valid — the window genuinely opened and the gate genuinely released — but
the behavior is asymmetric with Bucket.

The existing tests named `*_failed_try_consume_does_not_*` only cover
mid-window and mid-cooldown cases (no boundary crossing), which pass. They would
give a false sense of "no state change on failure" if read without this context.

**Recommendation:**

1. Add cross-boundary failed-consume tests for both FixedWindow and Cooldown to
   document and lock down this behavior:

```move
#[test]
fun fixed_window_rollover_occurs_even_on_failed_try_consume() {
    let (test, mut clk) = setup(0);
    let mut rl = rate_limiter::new_fixed_window(5, 100, 5, &clk);
    rl.consume_or_abort(3, &clk); // available = 2

    // Cross window boundary with an oversized consume.
    clk.set_for_testing(100);
    assert!(!rl.try_consume(6, &clk)); // fails, but window rolled

    // Window rolled: available is now 5 (new window capacity), not 2.
    assert_eq!(rl.available(&clk), 5);
    teardown(test, clk);
}

#[test]
fun cooldown_gate_releases_even_on_failed_try_consume() {
    let (test, mut clk) = setup(0);
    let mut rl = rate_limiter::new_cooldown(5, 50, 5);
    assert!(rl.try_consume(5, &clk)); // available = 0, deadline = 50

    clk.set_for_testing(50); // deadline elapsed
    assert!(!rl.try_consume(6, &clk)); // oversized, fails; but gate releases

    // Gate has released: available is now 5.
    assert_eq!(rl.available(&clk), 5);
    teardown(test, clk);
}
```

2. Add a note in the module-level doc or in `try_consume`'s doc comment:
   "For FixedWindow and Cooldown, window rollover and cooldown release are applied
   eagerly even when the subsequent consume amount check fails. Bucket commits
   no state on failure."

**Status:** Open

---

#### INFM-2: Missing `expected_failure` tests for several `reconfigure_*` validation paths

**Location:** [rate_limiter_tests.move:410-434](contracts/utils/tests/rate_limiter_tests.move#L410-L434)

**Issue:**

The following validation assertions exist in the implementation but have no
corresponding tests:

| Missing test | Assertion in code |
|---|---|
| `reconfigure_bucket` with zero `refill_amount` | `assert!(refill_amount > 0, EZeroRefillAmount)` line 383 |
| `reconfigure_bucket` with zero `refill_interval_ms` | `assert!(refill_interval_ms > 0, EZeroRefillInterval)` line 384 |
| `reconfigure_fixed_window` with zero `capacity` | `assert!(capacity > 0, EZeroCapacity)` line 434 |
| `reconfigure_cooldown` with zero `capacity` | `assert!(capacity > 0, EZeroCapacity)` line 488 |

**Recommendation:** Add four `#[expected_failure]` tests mirroring the existing
patterns at lines 412–434. One example:

```move
#[test, expected_failure(abort_code = rate_limiter::EZeroRefillAmount)]
fun reconfigure_bucket_rejects_zero_refill_amount() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_bucket(10, 1, 10, 10, &clk);
    rl.reconfigure_bucket(10, 0, 10, &clk);
    abort
}
```

**Status:** Open

---

#### INFM-3: `try_consume_with_zero_amount_aborts` only exercises the Bucket variant

**Location:** [rate_limiter_tests.move:303-309](contracts/utils/tests/rate_limiter_tests.move#L303-L309)

**Issue:**

`EInvalidAmount` is checked as the very first line of `try_consume` (line 250),
so it fires for all variants. The test only constructs a Bucket, leaving the
FixedWindow and Cooldown branches untested for this abort code.

**Recommendation:**

```move
#[test, expected_failure(abort_code = rate_limiter::EInvalidAmount)]
fun try_consume_with_zero_amount_aborts_fixed_window() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_fixed_window(10, 100, 10, &clk);
    rl.try_consume(0, &clk);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EInvalidAmount)]
fun try_consume_with_zero_amount_aborts_cooldown() {
    let (_test, clk) = setup(0);
    let mut rl = rate_limiter::new_cooldown(10, 50, 10);
    rl.try_consume(0, &clk);
    abort
}
```

**Status:** Open

---

#### INFM-4: `try_consume(limiter.available(clock), clock)` aborts (not returns false) when Cooldown is actively gated

**Location:** [rate_limiter.move:339-344](contracts/utils/sources/rate_limiter.move#L339-L344),
[rate_limiter.move:250](contracts/utils/sources/rate_limiter.move#L250)

**Issue:**

When a Cooldown limiter is actively gated (`available == 0`, `now < cooldown_end_ms`),
`available()` returns `0`. Passing that directly to `try_consume` triggers
`EInvalidAmount` (amount == 0 is a programmer error, not a rate-limit condition),
which aborts rather than returning false.

The safe pattern — demonstrated by the `*_available_predicts_try_consume` tests —
is to call `available()` first and check it is `> 0` before calling `try_consume`.
However, this contract is not stated in the `try_consume` or `available` doc comments,
leaving the footgun undocumented.

**Recommendation:**

Add to the `available()` or `try_consume()` doc comment:
> When `available()` returns 0 (e.g., during a Cooldown gate), do not call
> `try_consume(available(), clock)` directly — it would abort with `EInvalidAmount`.
> Guard with `let a = self.available(clock); if a > 0 { self.try_consume(a, clock) }`.

**Status:** Open

---

#### INFM-5: Upgrade safety — enum structure is not forward-compatible

**Location:** [rate_limiter.move:78-110](contracts/utils/sources/rate_limiter.move#L78-L110)

**Issue:**

`RateLimiter` is a `public enum`. Adding a new variant or adding fields to an
existing variant in a future package upgrade would break any deployed object
that already stores a `RateLimiter` value — the BCS encoding would no longer
deserialize correctly. This is a general Sui/Move constraint, not a code bug,
but worth documenting for maintainers who may add strategies in the future.

**Recommendation:**

Document in CHANGELOG or a UPGRADING guide:
> Adding enum variants or new fields to existing `RateLimiter` variants requires
> a data migration for any objects that have stored a `RateLimiter`. The only
> compatible changes to this enum are adding new independent public functions.

**Status:** Open (documentation gap)

---

## Security Checklist Results

| Category | Result | Notes |
|----------|--------|-------|
| 3.1 Access Control | ✅ Pass | Module is intentionally authorization-agnostic; all mutation requires `&mut self` which gates on object ownership in the integrator's model |
| 3.2 Object Safety | ✅ Pass | Value type with `drop`; no IDs, no dynamic fields, no shared objects |
| 3.3 Arithmetic Safety | ✅ Pass | All overflow paths analyzed; `bucket_accrue` proves safety via floor-division bound; `cooldown_end_ms` overflow is operator responsibility and documented |
| 3.4 Type Safety | ✅ Pass | No generics; enum variant matching is exhaustive |
| 3.5 Reentrancy / Composability | ✅ Pass | No shared objects; no external calls from within the module |
| 3.6 Economic Security | ✅ N/A | No value or coin handling in this module |
| 3.7 Upgrade Safety | ⚠️ Partial | Enum structure precludes forward-compatible variant/field additions; not documented for maintainers (INFM-5) |

---

## Test Coverage Assessment

Overall test coverage is strong. Key scenarios covered:

- Happy-path consumption and refill for all three variants ✅
- Overflow-interval discard for Bucket (two tests) ✅
- Anchor-based window grid for FixedWindow ✅
- Cooldown deadline semantics ✅
- All-or-nothing failure semantics (mid-window / mid-cooldown) ✅
- Fractional time preservation for Bucket ✅
- Reconfigure-under-old-rules-first for Bucket and FixedWindow ✅
- Cooldown reconfigure: in-flight deadline preservation and re-arm ✅
- Overflow with extreme values (u64::MAX clock, huge refill_amount) ✅
- Constructor and reconfigure config validation — mostly covered ✅

**Gaps (all Informational):**
- INFM-1: Cross-boundary failed-consume scenarios for FixedWindow and Cooldown
- INFM-2: Four missing `reconfigure_*` validation tests
- INFM-3: Zero-amount abort for FixedWindow and Cooldown variants
- MED-1: `new_cooldown(cap, cd, 0)` behavior not tested

---

## Recommendation

- **Overall verdict:** Ready for publishing with MED-1 addressed.
- **Blocking issues:** MED-1 — either fix the behavior or document it explicitly with a test that locks in the semantics. Leaving it silent risks integrator confusion.
- **Suggested improvements:** INFM-1 through INFM-5 are non-blocking but all straightforward to address before publication.

---

## Out of Scope

- Math modules (`u128`, `u256`, `fixed_point`, `sd29x9`, `ud30x9`) — also changed on this branch but not part of the rate_limiter feature; separate review scope.
- Gas optimization — this review targeted security and correctness only.

---

## Dev Notes

The arithmetic safety story for `bucket_accrue` is particularly well-handled.
The two-branch split (`elapsed_steps <= steps_to_full` vs fill) avoids any large
intermediate products while correctly discarding overflow intervals. The inline
comments explaining the overflow proof are clear and accurate.

The Cooldown reconfigure re-arm logic (`now >= cooldown_end_ms` check after clamping
`available` to new capacity) is a non-obvious correctness property that is both
implemented correctly and tested well. Worth keeping.

## Open Questions

- Is `new_cooldown(cap, cd, 0)` intentionally equivalent to `new_cooldown(cap, cd, cap)`?
  If yes, consider renaming the parameter or adding an explicit alternative constructor.
- Should a future review cover the math module changes (u128/u256/fixed_point) on this branch?

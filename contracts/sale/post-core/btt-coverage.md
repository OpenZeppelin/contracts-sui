---
stage: review
project: prefunded-sale
mode: extension
extends: contracts/sale/sources
status: complete
timestamp: 2026-07-09
author: claude (sui-btt)
previous_stage: contracts/sale/post-core/basic-review.md
tags: [btt, coverage, post-core, sale, events]
---

# Prefunded Sale — BTT Coverage Report

## Summary

Walked the six-module `openzeppelin_sale` package (33 invariants, 65 `assert!`,
20 `event::emit`) against its test suite. Starting point: **96 tests** — an
exceptionally tight runtime-guard suite (every abort code with an exact-code
`#[expected_failure]`, exact-value conservation asserts, real `FixedRateCurve` +
real `VestingWallet<Linear>` composition, a `BadCurve` for the INV-23 residual).

**One systematic blind spot dominated: events.** All 20 emission points were
unobserved — not a single test called `event::events_by_type`, so every event
could be dropped, doubled, or given a wrong payload with all 96 tests still
green. The sibling `finance` package tests all of its events (via `test_new_*`
seams), so this was package-local drift from an established convention, not a
scoping choice. Secondary gaps: three defined error codes with no failure test
(`EQuoteSaleMismatch`, `ENotTerminal`, `ERaisedOverflow`) and two untested
boundary edges.

**Outcome (dev-approved: full event parity + all 3 abort gaps + boundaries):**
- Added **23 `#[test_only]` constructors** to source (14 event + 2 `CancelReason`
  in `prefunded_sale`; 4 event + 3 `VaultState` in `refund_vault`), mirroring
  `finance`.
- **8 new tests** + **event-payload assertions threaded through 15 existing
  tests**. Suite: **96 → 104**; `sui move build --lint --warnings-are-errors
  --build-env testnet` and `sui move test --build-env testnet` both green.

Confidence, event leaves (22 total: emission + payload, counting reason /
transition / source variants):
- **Before: 0 ✅ / 1 ◐ / 21 ❌**
- **After: 21 ✅ / 1 ◐ / 0 ❌** (the lone ◐ is `Purchased`, whose `receipt_id` is
  minted-and-transferred in-call so it isn't knowable in the emitting tx —
  emission count pinned; `paid`/`allocation` cross-checked via the delivered
  receipt's own asserted fields).

Abort-path leaves: **before 37 ✅ / 3 ❌ → after 40 ✅**. Boundary edges: **0 → 2
✅**. Verdict: **tight** — the only remaining uncovered leaves are trivial view
accessors, explicitly deferred.

## Source-Derived Leaf List (Step 2.0)

Audit material — re-run the greps on a future revision and diff against this.

**`event::emit` (20 points → 18 struct types):**
- `refund_vault.move`: `RefundVaultCreated` (149), `VaultDeposit` (180, gated on
  `amount != 0`), `VaultStateChanged` (201 refunding, 222 closed), `VaultRelease`
  (253 release_balance, 278 withdraw_all).
- `prefunded_sale.move`: `SaleCreated` (591), `InventoryDeposited` (627),
  `PerBuyerCapSet` (663), `VestingScheduleParamsSet` (697), `RefundVaultPaired`
  (742), `AllowlistEnabled` (781), `SaleActivated` (872), `Purchased` (999),
  `SaleFinalized` (1063), `SaleCancelled` (1190, `reason` ∈ {SoftCapMissed,
  AdminEmergency}), `ProceedsWithdrawn` (1408), `InventoryWithdrawn` (1443),
  `Refunded` (1503), `Claimed` (1958).

**`assert!` (65 points):** every abort code cross-referenced against the tests.
Codes with **no** failure test before this pass:
`prefunded_sale::EQuoteSaleMismatch` (61, line 943→945),
`prefunded_sale::ERaisedOverflow` (23, 965),
`phase::ENotTerminal` (4, via `withdraw_unsold_inventory` 1441). All three now
covered. (`EContributionOverflow` appears in the invariants doc but **not** in
source — see Design Deviations.)

## Branching Tree (gap-annotated; ✅ leaves elided for brevity)

```
purchase (Active)
├── quote for a different sale ......... aborts EQuoteSaleMismatch . ✅ NEW purchase_with_foreign_quote_aborts
├── raised + paid > u64::MAX ........... aborts ERaisedOverflow ..... ✅ NEW purchase_raised_overflow_aborts (BadCurve)
├── paid == entry.max_amount .......... succeeds (boundary) ........ ✅ NEW per_entry_cap_exact_boundary_ok
├── all guards pass ................... delivers Receipt + mutates . ✅ purchase_delivers_receipt…
└── all guards pass ................... emits Purchased{7 fields} .. ◐ NEW count-only (receipt_id not in-tx)

withdraw_unsold_inventory (terminal)
├── phase == Active (non-terminal) .... aborts ENotTerminal ........ ✅ NEW withdraw_unsold_before_terminal_aborts
├── Finalized / Cancelled ............. returns slack .............. ✅
└── success ........................... emits InventoryWithdrawn ... ✅ withdraw_unsold_returns_only_slack

claim_all (Finalized)
├── empty receipt vector .............. returns zero balance ....... ✅ NEW claim_all_empty_returns_zero
└── N receipts ........................ sums allocations .......... ✅ claim_all_sums_receipts

do_cancel  (via cancel_after_close / cancel_emergency)
├── raised > 0 ........................ VaultDeposit(raised) ....... ✅ cancel_after_close_succeeds…
├── raised == 0 ....................... no VaultDeposit (no-op) .... ✅ cancel_emergency_zero_raised_succeeds
├── ................................... VaultStateChanged→Refunding  ✅
└── ................................... SaleCancelled{reason} ...... ✅ both reasons pinned

refund_vault::deposit (Active)
├── amount == 0 ....................... no-op, no VaultDeposit ..... ✅ deposit_zero_is_noop (count == 0)
└── amount > 0 ........................ emits VaultDeposit ......... ✅ deposit_then_*

setup emitters (SaleCreated / InventoryDeposited / PerBuyerCapSet /
  VestingScheduleParamsSet / RefundVaultPaired / AllowlistEnabled / SaleActivated)
└── happy path ........................ emits {payload} ............ ✅ all pinned (3 new happy tests added)

Uncovered (deferred): is_open (T/F), has_reached_soft_cap, opens_at_ms,
  closes_at_ms, refund_vault::state — trivial views, tests artifact already
  accepts them as Out of Scope.
```

## Coverage Map (post-write; gaps + newly-closed rows)

| Function | Branch | Covered by | Confidence |
|---|---|---|---|
| purchase | quote for different sale / aborts EQuoteSaleMismatch | `purchase_with_foreign_quote_aborts` | ✅ (was ❌) |
| purchase | raised+paid overflow / aborts ERaisedOverflow | `purchase_raised_overflow_aborts` | ✅ (was ❌) |
| purchase | paid == entry max / succeeds | `per_entry_cap_exact_boundary_ok` | ✅ (was ❌) |
| purchase | success / emits Purchased | `purchase_delivers_receipt…` | ◐ count-only (was ❌) |
| withdraw_unsold_inventory | Active / aborts ENotTerminal | `withdraw_unsold_before_terminal_aborts` | ✅ (was ❌) |
| claim_all | empty vector / returns zero | `claim_all_empty_returns_zero` | ✅ (was ❌) |
| create_sale | emits SaleCreated | `create_sale_initializes…` | ✅ (was ❌) |
| deposit | emits InventoryDeposited (×2) | `deposit_accumulates_inventory` | ✅ (was ❌) |
| set_per_buyer_cap | happy / emits PerBuyerCapSet | `set_per_buyer_cap_emits_event` | ✅ (was ❌; no happy test existed) |
| set_vesting_schedule_params | emits VestingScheduleParamsSet | `set_vesting_schedule_params_fills_option` | ✅ (was ❌) |
| pair_refund_vault | emits RefundVaultPaired | `share_and_activate_emits_pairing…` | ✅ (was ❌) |
| enable_allowlist | happy / emits AllowlistEnabled | `enable_allowlist_emits_event` | ✅ (was ❌; no happy test existed) |
| share_and_activate | emits SaleActivated | `share_and_activate_emits_pairing…` | ✅ (was ❌) |
| finalize | emits SaleFinalized + vault→Closed | `finalize_after_close_succeeds` | ✅ (was ❌) |
| cancel_after_close | emits SaleCancelled{SoftCapMissed} + vault events | `cancel_after_close_succeeds…` | ✅ (was ❌) |
| cancel_emergency | emits SaleCancelled{AdminEmergency} | `cancel_emergency_succeeds` / `…_zero_raised_…` | ✅ (was ❌) |
| claim | emits Claimed{sale,buyer,receipt_id,amount} | `claim_returns_allocation…` | ✅ (was ❌) |
| refund | emits Refunded + VaultRelease | `refund_returns_paid…` | ✅ (was ❌) |
| withdraw_proceeds | emits ProceedsWithdrawn | `withdraw_proceeds_returns_raised` | ✅ (was ❌) |
| withdraw_unsold_inventory | emits InventoryWithdrawn | `withdraw_unsold_returns_only_slack` | ✅ (was ❌) |
| refund_vault::new | emits RefundVaultCreated | `new_starts_active_and_empty` | ✅ (was ❌) |
| refund_vault::flip_to_* | emits VaultStateChanged (both) | vault + lifecycle tests | ✅ (was ❌) |
| refund_vault::release_balance / withdraw_all | emits VaultRelease | vault + refund tests | ✅ (was ❌) |
| is_open / has_reached_soft_cap / opens_at_ms / closes_at_ms / vault state | read-only | — | ❌ Deferred (Out of Scope) |

## Design Deviations

- **DEV-1 (new — invariants.md):** INV-13 and INV-22 describe the per-buyer cap
  as `contributions[buyer] == Σ paid` accumulating upward, guarded by
  **`EContributionOverflow`**. The code
  ([prefunded_sale.move:975-984](../sources/prefunded_sale.move#L975-L984))
  stores **remaining allowance counting *down*** from the cap and has **no
  `EContributionOverflow`** — no such error constant exists (0 references
  anywhere). Enforcement is equivalent (the cap can't be exceeded) and no
  overflow is possible on a monoting-decreasing counter, so the missing guard is
  correct; the doc's model and named error are stale. Acceptable operationally;
  invariants.md should be corrected.
- **DEV-2 (invariants.md, already flagged):** INV-12 / Dev Notes name
  `EReceiptSaleMismatch` for the activation ticket check; source uses the
  dedicated `ETicketSaleMismatch` (code 62). Carried from basic-review.
- **DEV-3 (invariants.md, already flagged):** INV-32 says `claim_into_vesting`
  returns the wallet "directly"; source returns `(VestingWallet, DestroyCap)`.
  Carried from basic-review.

## Additions Written

### Source-side test seams (enable payload assertions cross-module)

**Type:** Modification to existing source (test-only additions)
**Files:** `sources/prefunded_sale.move` (14 `test_new_*` event constructors +
`test_cancel_reason_soft_cap_missed` / `_admin_emergency`);
`sources/refund_vault.move` (4 `test_new_*` event constructors +
`test_state_active` / `_refunding` / `_closed`).
**Pins:** enables whole-struct `assert_eq!` against `event::events_by_type` from
test modules. Mirrors `openzeppelin_finance::vesting_wallet`'s `test_new_*` seam.
**Severity at proposal time:** — (infrastructure)

### Failure-path additions (A1–A3)

#### purchase_with_foreign_quote_aborts
**Type:** New test · **File:** `tests/prefunded_sale_purchase_tests.move`
**Pins:** purchase / given a `Quote` minted for a different sale / it aborts
`EQuoteSaleMismatch`. **Verifies:** INV-2, INV-13. **Confidence:** ❌ → ✅.
**Severity:** High (security guard; the quote-side analogue of the tested
`ETicketSaleMismatch`).

#### withdraw_unsold_before_terminal_aborts
**Type:** New test · **File:** `tests/prefunded_sale_claim_refund_tests.move`
**Pins:** withdraw_unsold_inventory / given phase == Active / it aborts
`ENotTerminal`. **Verifies:** INV-18. **Confidence:** ❌ → ✅.
**Severity:** Medium-High (admin-path phase guard; sibling of the tested
`withdraw_proceeds` `ENotFinalized`).

#### purchase_raised_overflow_aborts
**Type:** New test · **File:** `tests/prefunded_sale_curve_trust_tests.move`
**Pins:** purchase / given `raised + paid > u64::MAX` / it aborts
`ERaisedOverflow`. **Verifies:** INV-13. **Confidence:** ❌ → ✅. **Severity:**
Medium (defensive; reachable via `BadCurve` with rate 0 so allocation stays clear
of the inventory bound, two buys of `u64::MAX` then `1`).

### Boundary additions (D1–D2)

#### per_entry_cap_exact_boundary_ok
**Type:** New test · **File:** `tests/prefunded_sale_purchase_tests.move`
**Pins:** purchase / `paid == entry.max_amount` / succeeds. **Verifies:** INV-13.
**Confidence:** ❌ → ✅. **Severity:** Medium (only the `>` case was tested).

#### claim_all_empty_returns_zero
**Type:** New test · **File:** `tests/prefunded_sale_claim_refund_tests.move`
**Pins:** claim_all / empty receipt vector / returns a zero balance. **Verifies:**
INV-24. **Confidence:** ❌ → ✅. **Severity:** Medium.

### Event-payload additions (full parity)

**Three new happy-path tests** (functions that previously had no happy/event
coverage, only failure tests or bundled-helper exercise):
`set_per_buyer_cap_emits_event`, `enable_allowlist_emits_event`,
`share_and_activate_emits_pairing_and_activation_events` (all in
`tests/prefunded_sale_setup_tests.move`). Each `❌ → ✅`.

**Payload assertions threaded through 15 existing tests** (Type: Modification;
each `❌ → ✅` except `Purchased` `❌ → ◐`), grouped by file:
- `refund_vault_tests.move`: `RefundVaultCreated`, `VaultDeposit` (incl. the
  zero-value skip: count `== 0` then `== 1`), `VaultStateChanged` (both
  transitions), `VaultRelease` (both sources).
- `prefunded_sale_setup_tests.move`: `SaleCreated`, `InventoryDeposited` (×2),
  `VestingScheduleParamsSet`.
- `prefunded_sale_purchase_tests.move`: `Purchased` (count-only ◐).
- `prefunded_sale_lifecycle_tests.move`: `SaleFinalized`, `SaleCancelled`
  (SoftCapMissed + AdminEmergency), `VaultStateChanged` (→Closed, →Refunding),
  `VaultDeposit` (proceeds routed; and count `== 0` on the zero-raised cancel).
- `prefunded_sale_claim_refund_tests.move`: `Claimed`, `Refunded`,
  `VaultRelease`, `ProceedsWithdrawn`, `InventoryWithdrawn`.

Representative sketch (the pattern the finance package uses, now applied here):

```move
let claimed = event::events_by_type<prefunded_sale::Claimed<SALE, USDC>>();
assert_eq!(claimed.length(), 1);
assert_eq!(
    claimed[0],
    prefunded_sale::test_new_claimed<SALE, USDC>(object::id(&sale), u::buyer(), receipt_id, 200),
);
```

## Verification

- `sui move test --build-env testnet` → **Total tests: 104; passed: 104;
  failed: 0** (was 96).
- `sui move build --lint --warnings-are-errors --build-env testnet` → clean.
- Every new `#[expected_failure]` triggered its named abort; every event
  assertion matched the exact payload.

## Rejections (Intentional Gaps)

None. The dev accepted the full recommended scope (events → full parity; all
three abort gaps; boundary edges). View accessors were deferred, not rejected —
see Out of Scope.

## Out of Scope

### Deferred (will revisit)
- **Trivial view accessors** — `is_open` (true + false branches),
  `has_reached_soft_cap`, `opens_at_ms`, `closes_at_ms`, `refund_vault::state`.
  Coverage is viable (one assertion each) but low value; the tests artifact
  already lists these as intentionally uncovered read-only views. **Trigger:**
  revisit if any becomes load-bearing for an integrator or an indexer.

### Not Applicable (closed)
- **Type-level invariants** (INV-1, INV-2, INV-4, INV-6, INV-7 no-ability /
  phantom / witness-gating) — compile-time; a violating test would fail to
  compile. Verified by the type checker.
- **True concurrent shared-object access (INV-33)** — the unit VM serializes
  transactions; genuine parallelism needs testnet.
- **`BadCurve`-side events** — the dishonest-curve harness emits `Purchased`
  under a test-only sale type; the honest-path `Purchased` leaf is the one that
  matters and is pinned (◐) in the purchase suite.

## Cascade Plan

| Artifact | Edit |
|---|---|
| `artifacts/invariants.md` | INV-13 / INV-22: replace the `contributions[buyer] == Σ paid` + `EContributionOverflow` description with the countdown-remaining model; delete the non-existent `EContributionOverflow` reference (DEV-1). |
| `artifacts/invariants.md` | INV-12 + Dev Notes: `EReceiptSaleMismatch` → `ETicketSaleMismatch`; mark Open Question #2 resolved (DEV-2). |
| `artifacts/invariants.md` | INV-32: return shape is `(VestingWallet, DestroyCap)` (DEV-3). |
| `artifacts/tests.md` | Test count 89 → **104**; add an "Events" row to the coverage matrix (every state-changing fn now asserts its event payload); note the `test_new_*` seam convention. |
| `post-core/basic-review.md` | LOW-2 recommendation ("run /sui-btt") satisfied; the event blind spot it did not surface is now closed. |

## Dev Notes

- **Event fields are module-private**, so payload assertions from a separate test
  module are impossible without a source seam. The chosen fix — `#[test_only]
  test_new_*` constructors + whole-struct `assert_eq!` — is exactly the
  `finance` package convention, so the two packages now match. Any future event
  (new field, new event type) should get a matching `test_new_*` and an
  assertion, or the payload silently drifts out of coverage again.
- **`Purchased` is the one ◐**: its `receipt_id` is generated and transferred to
  the buyer inside `purchase`, so it isn't takeable until the next tx, while
  `event::events_by_type` reads the emitting tx. Emission count is pinned and
  `paid`/`allocation` are cross-checked against the delivered receipt's asserted
  fields. To reach ✅ one would add per-field `#[test_only]` accessors and assert
  everything except `receipt_id` — deferred as low value.
- The zero-value `VaultDeposit` skip (basic-review INFO-1, commit `faf9439`) is
  now pinned at both levels: `deposit_zero_is_noop` (count `== 0`) and
  `cancel_emergency_zero_raised_succeeds` (do_cancel routes empty proceeds,
  emits no `VaultDeposit`).

## Open Questions

1. Apply the Cascade Plan edits to `invariants.md` now, or bundle when the
   artifact is next revised (`status: draft`)? (Carried from basic-review Q2.)
2. Upgrade `Purchased` to ✅ with per-field test-only accessors, or leave at ◐?
   (Recommended: leave — the payload is cross-checked and `receipt_id` is a
   fresh UID with no downstream dependency asserted elsewhere.)

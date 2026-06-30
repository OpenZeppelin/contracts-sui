---
stage: tests
project: prefunded-sale
mode: extension
extends: contracts/sale/sources
status: draft
timestamp: 2026-06-25
author: nenad
previous_stage: contracts/sale/artifacts/invariants.md
tags: [sale, presale, fixed-price, prefunded, refund-vault, allowlist, vesting, tests]
---

# Prefunded Sale — Test Suite

## Summary

An invariant-driven unit suite (89 tests) verifying all 33 invariants of the
`prefunded_sale` library and its side modules (`phase`, `receipt`,
`refund_vault`, `allowlist`, `fixed_rate_curve`). Tests are organized by concern
across nine files plus a shared `test_utils`, and every behavioral branch with a
typed abort code is pinned by an `#[expected_failure]` test naming that exact
code. The witness-gated curve trust boundary (INV-23) is exercised with a
test-only `BadCurve` — the only way to reach `EInsufficientInventory` and to
demonstrate the documented over-allocation residual, which an honest,
tightly-provisioned `FixedRateCurve` sale can never trip. All tests pass; lint is
clean.

## Test Files

| File | Scope |
|------|-------|
| `tests/test_utils.move` | Shared coin markers (`SALE`/`USDC`), constants, the canonical sale type, and setup helpers (`create_and_activate`, `buy`, `take_sale`/`take_vault`/`take_cap`). |
| `tests/phase_tests.move` | Lifecycle enum transitions + source-state guards (INV-20). |
| `tests/receipt_tests.move` | Receipt field carriage + consume round-trip (INV-1 data). |
| `tests/refund_vault_tests.move` | Vault state machine + cap-gating (INV-5, INV-19, INV-26). |
| `tests/allowlist_tests.move` | AllowEntry consume sale/buyer asserts (INV-4, INV-15, INV-31). |
| `tests/fixed_rate_curve_tests.move` | Rate guard, pricing math, overflow guards, carrier minting (INV-8, INV-14, INV-2/3). |
| `tests/prefunded_sale_setup_tests.move` | create/deposit/caps/vesting/pair/allowlist/activate (INV-3,8,10,11,12,15,20). |
| `tests/prefunded_sale_purchase_tests.move` | Purchase window/caps/allowlist coupling (INV-13,15,21,22,30,31). |
| `tests/prefunded_sale_lifecycle_tests.move` | finalize/cancel_after_close/cancel_emergency (INV-16,20,22,25,28,29). |
| `tests/prefunded_sale_claim_refund_tests.move` | claim/vesting/refund/withdrawals (INV-9,17,18,21,24,26,27,32). |
| `tests/prefunded_sale_curve_trust_tests.move` | Dishonest-curve trust boundary (INV-23, INV-21 inventory bound). |

## Test Plan

Failure tests carry the asserted abort code in parentheses.

### Construction & setup (INV-8, INV-10, INV-11, INV-15)

| Test | Invariant | Type |
|------|-----------|------|
| `create_sale_rejects_zero_hard_cap` | INV-8 | Failure (`EHardCapZero`) |
| `create_sale_rejects_soft_cap_above_hard` | INV-8 | Failure (`EInvalidCapsOrdering`) |
| `create_sale_rejects_inverted_time_range` | INV-8 | Failure (`EInvalidTimeRange`) |
| `create_sale_initializes_in_init_phase` | INV-5,8,20 | Happy |
| `params_rejects_zero_rate` | INV-8 | Failure (`ERateZero`) |
| `deposit_accumulates_inventory` | INV-10,21 | Happy |
| `deposit_after_activate_aborts` | INV-10 | Failure (`ENotInit`) |
| `set_per_buyer_cap_rejects_zero` | INV-10 | Failure (`EPerBuyerCapZero`) |
| `set_per_buyer_cap_twice_aborts` | INV-10 | Failure (`EPerBuyerCapAlreadySet`) |
| `set_vesting_schedule_params_fills_option` | INV-10,17 | Happy |
| `set_vesting_schedule_params_twice_aborts` | INV-10 | Failure (`EVestingScheduleAlreadySet`) |
| `enable_allowlist_twice_aborts` | INV-10,15 | Failure (`EAllowlistAlreadyEnabled`) |
| `pair_rejects_nonempty_vault` | INV-11 | Failure (`EVaultNotEmpty`) |
| `pair_rejects_mismatched_cap` | INV-5,11 | Failure (`EWrongVault`) |
| `pair_rejects_inactive_vault` | INV-11 | Failure (`EVaultNotActive`) |
| `pair_twice_aborts` | INV-10 | Failure (`EVaultAlreadyPaired`) |

### Activation (INV-3, INV-12, INV-20)

| Test | Invariant | Type |
|------|-----------|------|
| `activate_at_exact_required_inventory_ok` | INV-12 | Boundary |
| `activate_without_vault_aborts` | INV-12 | Failure (`EVaultRequiredForActivate`) |
| `activate_insufficient_inventory_aborts` | INV-12 | Failure (`EInsufficientInventoryAtActivate`) |
| `activate_after_close_aborts` | INV-12 | Failure (`EActivationAfterClose`) |
| `activate_with_foreign_ticket_aborts` | INV-3,12 | Failure (`ETicketSaleMismatch`) |

### Purchase (INV-13, INV-14, INV-15, INV-21, INV-22, INV-30, INV-31)

| Test | Invariant | Type |
|------|-----------|------|
| `purchase_delivers_receipt_and_updates_state` | INV-13,21,22,30 | Happy |
| `purchase_at_exact_hard_cap_ok` | INV-13,22 | Boundary |
| `purchase_before_open_aborts` | INV-13 | Failure (`ESaleWindowClosed`) |
| `purchase_after_close_aborts` | INV-13 | Failure (`ESaleWindowClosed`) |
| `purchase_exceeds_hard_cap_aborts` | INV-13,22 | Failure (`EHardCapExceeded`) |
| `per_buyer_cap_allows_up_to_cap` | INV-13 | Boundary |
| `per_buyer_cap_exceeded_aborts` | INV-13 | Failure (`EPerBuyerCapExceeded`) |
| `allowlist_purchase_with_entry_succeeds` | INV-15,31 | Happy |
| `allowlist_required_but_none_aborts` | INV-15 | Failure (`EAllowlistRequired`) |
| `allowlist_not_required_but_provided_aborts` | INV-15 | Failure (`EAllowlistNotRequired`) |
| `per_entry_cap_exceeded_aborts` | INV-13 | Failure (`EPerEntryCapExceeded`) |
| `quote_allocation_is_paid_times_rate` | INV-2,14 | Happy |
| `quote_rejects_zero_payment` | INV-14 | Failure (`EZeroPayment`) |
| `quote_allocation_overflow_aborts` | INV-14 | Failure (`EAllocationOverflow`) |
| `activation_ticket_overflow_aborts` | INV-14 | Failure (`ERequiredInventoryOverflow`) |

### Lifecycle close (INV-16, INV-20, INV-22, INV-25, INV-28, INV-29)

| Test | Invariant | Type |
|------|-----------|------|
| `finalize_after_close_succeeds` | INV-16,25,29 | Happy |
| `finalize_early_when_hard_cap_reached` | INV-16 | Boundary |
| `finalize_window_open_not_sold_out_aborts` | INV-16 | Failure (`ESaleWindowStillOpen`) |
| `finalize_soft_cap_not_met_aborts` | INV-16 | Failure (`ESoftCapNotMet`) |
| `finalize_twice_aborts` | INV-20 | Failure (`ENotActive`) |
| `cancel_after_close_succeeds_and_routes_proceeds` | INV-16,22,25,26 | Happy |
| `cancel_after_close_soft_cap_met_aborts` | INV-16 | Failure (`ESoftCapMet`) |
| `cancel_after_close_window_open_aborts` | INV-16 | Failure (`ESaleWindowStillOpen`) |
| `cancel_emergency_succeeds` | INV-16,25 | Happy |
| `cancel_emergency_wrong_cap_aborts` | INV-5 | Failure (`EWrongAdminCap`) |
| `cancel_emergency_after_close_aborts` | INV-16 | Failure (`EEmergencyCancelAfterClose`) |
| `cancel_emergency_hard_cap_reached_aborts` | INV-28 | Failure (`ESaleAlreadyComplete`) |
| `cancel_emergency_soft_cap_met_aborts` | INV-28 | Failure (`ESoftCapMet`) |

### Redemption & withdrawals (INV-9, INV-17, INV-18, INV-21, INV-24, INV-26, INV-27, INV-32)

| Test | Invariant | Type |
|------|-----------|------|
| `claim_returns_allocation_and_draws_inventory` | INV-9,21,24,27 | Happy |
| `claim_all_sums_receipts` | INV-9,24 | Happy |
| `claim_wrong_buyer_aborts` | INV-9 | Failure (`EBuyerOnly`) |
| `claim_foreign_receipt_aborts` | INV-9 | Failure (`EReceiptSaleMismatch`) |
| `claim_before_finalize_aborts` | INV-9 | Failure (`ENotFinalized`) |
| `claim_with_vesting_attached_aborts` | INV-17 | Failure (`EClaimRequiresVesting`) |
| `claim_into_vesting_returns_funded_wallet` | INV-17,32 | Happy |
| `claim_all_into_vesting_sums_into_one_wallet` | INV-17,32 | Happy |
| `claim_into_vesting_without_schedule_aborts` | INV-17 | Failure (`ENoVestingScheduleAttached`) |
| `refund_returns_paid_and_draws_vault` | INV-24,26,27 | Happy |
| `refund_wrong_buyer_aborts` | INV-9 | Failure (`EBuyerOnly`) |
| `refund_before_cancel_aborts` | INV-9 | Failure (`ENotCancelled`) |
| `withdraw_proceeds_returns_raised` | INV-18,24,29 | Happy |
| `withdraw_proceeds_wrong_cap_aborts` | INV-5,18 | Failure (`EWrongAdminCap`) |
| `withdraw_proceeds_before_finalize_aborts` | INV-18 | Failure (`ENotFinalized`) |
| `withdraw_unsold_returns_only_slack` | INV-18,21,24 | Happy |
| `withdraw_unsold_wrong_cap_aborts` | INV-5,18 | Failure (`EWrongAdminCap`) |

### Curve trust boundary (INV-23, INV-21)

| Test | Invariant | Type |
|------|-----------|------|
| `activation_trusts_undersized_required_inventory` | INV-23 | Trust-boundary (pins no backing check) |
| `overallocating_quote_beyond_inventory_aborts` | INV-21,23 | Failure (`EInsufficientInventory`) |
| `overallocating_quote_within_inventory_is_accepted` | INV-23 | Trust-boundary (pins over-allocation residual) |

### Side modules

| Test | Invariant |
|------|-----------|
| `phase_tests::*` (6) | INV-20 |
| `receipt_tests::new_receipt_exposes_fields` | INV-1 (data) |
| `refund_vault_tests::*` (9) | INV-5, INV-19, INV-26 |
| `allowlist_tests::*` (3) | INV-4, INV-15, INV-31 |
| `fixed_rate_curve_tests::*` (7) | INV-2, INV-3, INV-8, INV-14 |

## Coverage Matrix

| Invariant | Happy / Boundary | Failure | Notes |
|-----------|------------------|---------|-------|
| INV-1 (Receipt non-transferable, buyer-bound) | `receipt::new_receipt_exposes_fields` | `claim_wrong_buyer`, `refund_wrong_buyer` | Non-transferability is type-level (compile-time) — see Out of Scope. |
| INV-2 (Quote witness hot potato) | `quote_allocation_is_paid_times_rate` | — | No-ability/single-use is compile-time. |
| INV-3 (ActivationTicket witness hot potato) | `activation_ticket_requires_hard_cap_times_rate` | `activate_with_foreign_ticket_aborts` | |
| INV-4 (AllowEntry single-use) | `new_admin_and_consume_returns_max_amount` | `consume_wrong_sale`, `consume_wrong_buyer` | No-ability is compile-time. |
| INV-5 (Caps bound to one sale/vault) | `create_sale_initializes` (`cap_sale_id`) | `cancel_emergency_wrong_cap`, `withdraw_proceeds_wrong_cap`, `withdraw_unsold_wrong_cap`, `deposit_with_wrong_cap`, `pair_rejects_mismatched_cap` | |
| INV-6 (phantom types prevent cross-coin/curve) | — | — | Type system / compile-time — see Out of Scope. |
| INV-7 (Curve witness gates pricing authority) | (BadCurve tests demonstrate witness-holder mints) | — | Gating itself is compile-time (private witness ctor). |
| INV-8 (construction params well-formed) | `create_sale_initializes` | `create_sale_rejects_zero_hard_cap`, `..._soft_cap_above_hard`, `..._inverted_time_range`, `params_rejects_zero_rate` | |
| INV-9 (redemption buyer-only, sale-matched) | `claim_returns_allocation` | `claim_wrong_buyer`, `claim_foreign_receipt`, `claim_before_finalize`, `refund_wrong_buyer`, `refund_before_cancel` | |
| INV-10 (setup Init-only / one-shot) | `deposit_accumulates_inventory`, `set_vesting_schedule_params_fills_option` | `deposit_after_activate`, `set_per_buyer_cap_twice`, `set_per_buyer_cap_rejects_zero`, `set_vesting_schedule_params_twice`, `enable_allowlist_twice`, `pair_twice` | |
| INV-11 (vault pairing matching/active/empty) | (via `create_and_activate`) | `pair_rejects_nonempty_vault`, `pair_rejects_mismatched_cap`, `pair_rejects_inactive_vault` | |
| INV-12 (activation gate) | `activate_at_exact_required_inventory_ok` | `activate_without_vault`, `activate_insufficient_inventory`, `activate_after_close`, `activate_with_foreign_ticket` | |
| INV-13 (purchase window/caps/allowlist/inventory) | `purchase_delivers_receipt`, `purchase_at_exact_hard_cap`, `per_buyer_cap_allows_up_to_cap` | `purchase_before_open`, `purchase_after_close`, `purchase_exceeds_hard_cap`, `per_buyer_cap_exceeded`, `per_entry_cap_exceeded`, allowlist coupling | |
| INV-14 (quote zero/overflow guards) | `quote_allocation_is_paid_times_rate` | `quote_rejects_zero_payment`, `quote_allocation_overflow`, `activation_ticket_overflow` | |
| INV-15 (allowlist symmetric & one-shot) | `allowlist_purchase_with_entry_succeeds` | `allowlist_required_but_none`, `allowlist_not_required_but_provided`, `enable_allowlist_twice` | |
| INV-16 (close preconditions) | `finalize_after_close`, `finalize_early_when_hard_cap_reached`, `cancel_after_close_succeeds`, `cancel_emergency_succeeds` | finalize/cancel guard failures (7 tests) | |
| INV-17 (vesting routing mutually exclusive) | `claim_into_vesting_returns_funded_wallet`, `claim_all_into_vesting` | `claim_with_vesting_attached`, `claim_into_vesting_without_schedule` | |
| INV-18 (admin withdrawals cap+phase gated) | `withdraw_proceeds_returns_raised`, `withdraw_unsold_returns_only_slack` | `withdraw_proceeds_wrong_cap`, `withdraw_proceeds_before_finalize`, `withdraw_unsold_wrong_cap` | |
| INV-19 (vault mutations cap+state gated) | `deposit_then_close_then_withdraw_all`, `deposit_then_refunding_then_release_partial` | `deposit_after_refunding`, `release_in_active`, `withdraw_all_in_active`, `flip_to_closed_from_refunding`, `deposit_with_wrong_cap` | |
| INV-20 (phase monotonic, terminal sinks) | `phase::init_then_activate_then_finalize`, `..._cancel` | `phase::activate_from_active`, `..._finalize_from_init`, `..._cancel_twice`, `finalize_twice_aborts` | |
| INV-21 (inventory covers allocations) | `claim_returns_allocation`, `withdraw_unsold_returns_only_slack` | `overallocating_quote_beyond_inventory_aborts` | Failure path only reachable via dishonest curve. |
| INV-22 (raised tracks proceeds ≤ hard_cap) | `purchase_delivers_receipt`, `purchase_at_exact_hard_cap`, `cancel_after_close_succeeds` | `purchase_exceeds_hard_cap` | |
| INV-23 (curve trusted, no rate bound) | `activation_trusts_undersized_required_inventory`, `overallocating_quote_within_inventory_is_accepted` | `overallocating_quote_beyond_inventory_aborts` | Intentional design; tests pin the *absence* of a bound. |
| INV-24 (conservation) | `claim_returns_allocation`, `claim_all_sums_receipts`, `refund_returns_paid`, `withdraw_proceeds_returns_raised`, `withdraw_unsold_returns_only_slack` | — | Exact-value assertions. |
| INV-25 (vault mirrors terminal phase) | `finalize_after_close` (Closed), `cancel_after_close_succeeds` (Refunding), `cancel_emergency_succeeds` | — | |
| INV-26 (refund solvency) | `refund_returns_paid_and_draws_vault`, `cancel_after_close_succeeds` (`vault.value == raised`) | `release_over_locked_aborts` | |
| INV-27 (buyer redemption admin-independent) | `claim_*`, `refund_*` (all run in buyer tx, no cap) | — | Demonstrated structurally; no cap taken. |
| INV-28 (admin cannot rug goal-reaching sale) | — | `cancel_emergency_hard_cap_reached`, `cancel_emergency_soft_cap_met` | |
| INV-29 (proceeds: success XOR refund) | `withdraw_proceeds_returns_raised`, `cancel_after_close_succeeds` | `finalize_twice` (exclusivity via monotonicity) | |
| INV-30 (quote+purchase single PTB) | `purchase_delivers_receipt` (and every `buy`) | — | Composability. |
| INV-31 (compliance mint+purchase single PTB) | `allowlist_purchase_with_entry_succeeds` | — | Composability. |
| INV-32 (claim_into_vesting composes with wallet) | `claim_into_vesting_returns_funded_wallet`, `claim_all_into_vesting` | — | Real `VestingWallet<Linear, ...>` asserted (balance + beneficiary). |
| INV-33 (shared sale tolerates concurrent callers) | Multi-tx / multi-sender flows (admin/buyer/buyer2) | — | True concurrency needs testnet — see Out of Scope. |

## Test Notes

- **Real curve, no mocking of pricing.** Every honest-path test parameterizes the
  sale on `FixedRateCurve` and mints quotes/tickets through
  `fixed_rate_curve::quote` / `::activation_ticket`, so the witness-gated pricing
  path (INV-7) is exercised as integrators would use it. `fixed_rate_curve` has
  no `create_sale` sugar in the source (the module doc implies one); tests call
  `prefunded_sale::create_sale` directly with `fixed_rate_curve::params(rate)`.
- **`EInsufficientInventory` (INV-21) is unreachable with an honest fixed-rate
  curve.** Activation enforces `inventory >= hard_cap * rate` and the hard-cap
  check bounds `raised`, so allocation can never exceed unallocated inventory
  before the hard-cap aborts. The failure is reached only through a dishonest
  curve (`prefunded_sale_curve_trust_tests::BadCurve`), which is also how the
  intentional INV-23 over-allocation residual is demonstrated.
- **Vesting composition uses the real finance wallet.** `claim_into_vesting`
  tests instantiate `Witness = vesting_wallet_linear::Linear` and
  `VestingScheduleParams = vesting_wallet_linear::Params`, asserting the returned
  `VestingWallet<Linear, Params, SALE>` is funded with the exact allocation and
  has `beneficiary == buyer` (INV-32) — not a hand-rolled stub.
- **Standardized type instantiation.** All sales (vesting and non-vesting) share
  the concrete type `PrefundedSale<FixedRateCurve, Params, SALE, USDC,
  vesting_wallet_linear::Params>`; the difference is only whether the schedule
  Option is filled. `test_utils` spells the five-parameter type out once (Move
  2024 has no type aliases) so thematic files stay readable.
- **Coverage:** 89 tests pass; overall line coverage ≈ 89% (`fixed_rate_curve`,
  `receipt`, `allowlist` at 100%). The uncovered lines are read-only view
  functions (`is_open`, `has_reached_soft_cap`, `opens_at_ms`/`closes_at_ms`,
  `curve_params`, several `Quote`/`Phase` accessors) and defensive enum match
  arms — no invariant branch is uncovered.

## Out of Scope

- **Receipt/Quote/AllowEntry non-transferability and no-ability guarantees
  (INV-1, INV-2, INV-4)** — these are type-level properties enforced at compile
  time (`key`-only / no abilities + package-private transfer). A test that tries
  to transfer or store them would fail to compile, so they cannot be exercised as
  runtime `#[test]` cases; they are verified by the type checker.
- **Phantom-type cross-coin / cross-curve confusion (INV-6) and witness gating
  (INV-7)** — compile-time type-system guarantees. A `RefundVault<USDC>` paired
  with a SUI sale, or a foreign module minting a `Quote<FixedRateCurve>`, are
  compile errors, not runtime aborts.
- **True concurrent PTB execution against the shared sale (INV-33)** — the unit
  VM serializes transactions; genuine concurrent/contended access requires
  testnet deployment. The suite exercises multi-transaction, multi-sender
  sequences (the structural guarantee) but not real parallelism.
- **Curve correctness, vesting release-schedule math, and KYC verification** —
  delegated components (per the invariants doc's Out of Scope); tested in their
  own packages, not here.
- **`contributions` table growth / stale-receipt accumulation** — accepted by
  design (invariants Out of Scope); no liveness assertion attempted.

## Dev Notes

- **Drift caught vs the invariants doc (code is law).** INV-12 and the invariants
  Dev Notes state that `share_and_activate` reuses `EReceiptSaleMismatch`
  (code 60) for the ticket sale-id check. The current source
  (`prefunded_sale.move:672`) uses the dedicated **`ETicketSaleMismatch`**
  (code 62) — corrected in commit `547c315`, after the invariants doc was
  written. The failure test `activate_with_foreign_ticket_aborts` pins
  `ETicketSaleMismatch`. **Proposed upstream sync (Y/N):** update invariants
  INV-12 + Dev Notes to name `ETicketSaleMismatch`, and mark Open Question #2
  resolved. Not applied — awaiting confirmation.
- No source code was changed by this stage. The stale `max_rate` doc comments in
  the source (already flagged in invariants Dev Notes for the docs stage) were
  left untouched and deliberately *not* tested (no such bound exists — INV-23).

## Open Questions

1. Apply the INV-12 / Open-Question-#2 doc correction in `invariants.md`
   (`EReceiptSaleMismatch` → `ETicketSaleMismatch`)? (Y/N — see Dev Notes.)
2. Should the docs stage add an integration/E2E note that INV-33 (concurrent
   shared-object access) is only verifiable on testnet?

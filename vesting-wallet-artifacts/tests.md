---
stage: tests
project: vesting-wallet
mode: greenfield
extends: null
status: draft
timestamp: 2026-06-17
author: 0xNeshi
previous_stage: vesting-wallet-artifacts/invariants.md
tags: [vesting, finance, linear-schedule, tests]
---

# Vesting Wallet — Test Suite

## Summary

Two invariant-driven test modules cover the curve-agnostic primitive and the
built-in linear curve: `contracts/finance/tests/vesting_wallet_tests.move` (20
tests) drives the wallet-level accounting, conservation, event, and lifecycle
invariants through a throwaway `TestCurve` that lets the tests mint
`VestedAmount`s with arbitrary cumulative totals; `linear_schedule_tests.move`
(25 tests) drives the schedule-shape math (pre-start / pre-cliff / cliff jump /
linear mid / post-end clamp / u128 worst case), the construction guards, and
release/teardown through the real curve. 45 tests, all passing, **100% line
coverage** on both modules, lint clean under `--warnings-are-errors`. Type-level
invariants that can only fail at compile time (INV-1, and the negative directions
of INV-37/38/39) are covered positively and documented under Out of Scope rather
than as runtime tests. The implementation is correct against every runtime and
economic invariant — no code bugs were found.

## Test Plan

### `vesting_wallet_tests.move` — primitive (curve-agnostic)

| Test | Invariant(s) | Type | What it verifies |
|------|-------------|------|------------------|
| `new_initializes_fields_and_emits_created` | INV-2, 8, 12, 17 | Happy | zero balance/released, beneficiary set, exactly one `Created` with documented fields |
| `new_supports_owned_topology` | INV-3 | Type | `key + store` allows `public_transfer` into owned mode |
| `deposit_increases_balance_emits_and_is_permissionless` | INV-2, 12, 16, 28, 31 | Happy | balance↑, single `Deposited`, ledger conserved, unrelated sender funds |
| `receive_and_deposit_claims_addressed_coin` | INV-5, 12, 16, 28 | Happy | claims a coin sent to the wallet address, one `Deposited`, no separate `Received` |
| `mint_stamps_wallet_id_and_amount_reads_without_consuming` | INV-37, 38, 44 | Happy | `amount` reads by reference (drop, not hot-potato); stamp accepted by its wallet |
| `release_rejects_vested_from_other_wallet` | INV-44 | Failure | `EWalletMismatch` |
| `releasable_rejects_vested_from_other_wallet` | INV-44 | Failure | `EWalletMismatch` on the view |
| `release_pays_releasable_to_beneficiary` | INV-12, 16, 19, 28, 29 | Happy | beneficiary paid, `released == vested.amount`, `Released` fields, ledger conserved |
| `release_is_noop_when_nothing_releasable` | INV-11, 12 | Boundary | no state change, zero `Released` events, no abort |
| `release_again_at_same_total_is_noop` | INV-11, 18 | State | re-mint at same total releases nothing |
| `release_is_monotone_across_increasing_totals` | INV-15, 16, 19 | State | `released` non-decreasing, ledger conserved |
| `release_rejects_vested_below_released` | INV-19, 36 | Failure | `EVestedBelowReleased` (regressed curve) |
| `releasable_rejects_vested_below_released` | INV-19 | Failure | `EVestedBelowReleased` on the view |
| `release_aborts_when_vested_exceeds_total` | INV-36, 28 | Failure | framework `balance.split` abort when attested > balance + released (boundedness) |
| `destroy_empty_returns_params_and_emits` | INV-4, 10, 12, 28, 37 | Happy | returns `P`, one `Destroyed`, witness-gated, empty accepted |
| `destroy_empty_rejects_nonempty_balance` | INV-10 | Failure | `ENotEmpty` |
| `beneficiary_params_and_id_are_immutable` | INV-8, 14, 17 | State | unchanged across deposit/release |
| `released_coins_stay_with_beneficiary` | INV-30 | State | released coins never reduced by later wallet activity |
| `beneficiary_can_be_object_address` | INV-33 | Edge | an object's address receives the release |
| `owned_handoff_does_not_redirect_cashflow` | INV-29, 35 | Composability | wallet handed to Bob, Alice (the fixed beneficiary) still paid |

### `linear_schedule_tests.move` — built-in linear-with-cliff curve

| Test | Invariant(s) | Type | What it verifies |
|------|-------------|------|------------------|
| `new_rejects_zero_duration` | INV-6 | Failure | `EZeroDuration` |
| `new_rejects_cliff_exceeding_duration` | INV-7 | Failure | `EInvalidCliff` |
| `new_rejects_schedule_overflow` | INV-45 | Failure | `EScheduleOverflow` (start=MAX, dur=1) |
| `new_accepts_end_at_u64_max_boundary` | INV-45 | Boundary | start+dur == u64::MAX constructs, `end()` does not abort |
| `new_accepts_cliff_equal_to_duration` | INV-7 | Boundary | cliff == duration accepted (accept edge of `<=`); jumps to total at end |
| `new_sets_params_and_emits_created` | INV-12, 14 | Happy | accessors return configured params, one `Created` (full payload asserted via `test_params`) |
| `create_and_share_shares_wallet` | INV-3 | Type | `create_and_share` puts the wallet into shared topology |
| `vested_amount_pre_start_is_zero` | INV-13, 21 | Boundary | clock < start → 0, no underflow |
| `vested_amount_at_exact_start_is_zero` | INV-25 | Boundary | clock == start (elapsed 0, no cliff) → 0, lower edge of linear branch |
| `vested_amount_pre_cliff_is_zero` | INV-22 | Boundary | within the cliff → 0 (at start and just before cliff) |
| `vested_amount_at_cliff_jumps_to_proportional` | INV-23 | **Boundary (key)** | t=cliff-1 → 0, t=cliff → `total*cliff/dur` (250) |
| `vested_amount_is_linear_mid_schedule` | INV-25 | Happy | mid-points equal `total*(t-start)/dur` (500, 750) |
| `vested_amount_post_end_clamps_to_total` | INV-24 | Boundary | end, end+1, u64::MAX all → total |
| `vested_amount_is_nondecreasing_in_time` | INV-20, 36 | Property | monotone across 8 increasing samples |
| `vested_amount_uses_u128_intermediate_at_max` | INV-26 | Boundary | total=dur=u64::MAX, t=MAX-1 → MAX-1, no overflow/abort |
| `deposit_vests_as_if_from_start` | INV-27 | Edge | a late deposit immediately vests at the current proportion |
| `release_pays_linear_portion_and_is_permissionless` | INV-11, 12, 16, 28, 29, 31 | Happy | mid-schedule release pays beneficiary, ledger conserved, unrelated sender |
| `release_then_release_at_same_clock_is_noop` | INV-11, 18, 34 | State | idempotent at a fixed clock (stand-in for concurrent-race safety) |
| `releasable_view_matches_release` | INV-18 | State | `releasable` == amount paid; 0 right after release |
| `full_release_after_end_then_releasable_zero` | INV-18, 24 | Happy | drains to total, then nothing releasable |
| `destroy_after_end_on_empty_wallet` | INV-4, 9, 10, 12 | Happy | ended + empty wallet tears down, emits `Destroyed` |
| `destroy_rejects_before_end` | INV-9 | Failure | `ENotEnded` (empty wallet, before end) |
| `destroy_rejects_nonempty_balance` | INV-10 | Failure | `ENotEmpty` (balance gate fires before the ended gate) |
| `create_deposit_release_in_one_flow` | INV-32 | Composability | new + deposit + release compose in one transaction |
| `receive_and_deposit_then_release_in_one_flow` | INV-32, 5 | Composability | claim addressed coin + release in one transaction (emission/payroll path) |

## Coverage Matrix

Legend: ✅ runtime test · 🔒 compile-time enforced (positive coverage only;
negative is unrepresentable in-package — see Out of Scope).

| Invariant | Happy / Positive | Boundary | Failure | Additional |
|-----------|------------------|----------|---------|------------|
| INV-1 (per-triple isolation) | 🔒 every test uses one triple | — | 🔒 compile | — |
| INV-2 (balance encapsulated) | `new_initializes`, `deposit_*` | — | 🔒 no `&mut Balance` exposed | — |
| INV-3 (shared + owned) | `create_and_share_shares_wallet` | — | — | `new_supports_owned_topology` |
| INV-4 (no drop / explicit destroy) | `destroy_empty_returns_params`, `destroy_after_end` | — | 🔒 compile | — |
| INV-5 (receive only addressed) | `receive_and_deposit_claims_addressed_coin` | — | framework (OOS) | `receive_and_deposit_then_release_in_one_flow` |
| INV-6 (zero duration) | — | — | `new_rejects_zero_duration` | — |
| INV-7 (cliff > duration) | — | `new_accepts_cliff_equal_to_duration` (accept edge) | `new_rejects_cliff_exceeding_duration` | — |
| INV-8 (beneficiary fixed) | `new_initializes` | — | — | `beneficiary_params_and_id_are_immutable` |
| INV-9 (destroy requires ended) | `destroy_after_end_on_empty_wallet` | — | `destroy_rejects_before_end` | — |
| INV-10 (destroy requires empty) | `destroy_empty_returns_params` | — | `destroy_empty_rejects_nonempty_balance`, `destroy_rejects_nonempty_balance` | — |
| INV-11 (release no-op at zero) | — | `release_is_noop_when_nothing_releasable` | — | `release_again_at_same_total`, `release_then_release_at_same_clock` |
| INV-12 (event contract) | `new_*`, `deposit_*`, `release_pays_*`, `destroy_*` | `release_is_noop` (0 events) | — | `release_then_release` (0 on 2nd) |
| INV-13 (pre-start underflow guard) | `vested_amount_pre_start_is_zero` | ✅ | — | — |
| INV-14 (params immutable) | `new_sets_params_and_emits_created` | — | — | `beneficiary_params_and_id_are_immutable` |
| INV-15 (released monotone) | `release_is_monotone_across_increasing_totals` | — | — | — |
| INV-16 (ledger conservation) | `deposit_*`, `release_pays_*` | — | — | `release_is_monotone` |
| INV-17 (id stable) | `new_initializes` | — | — | `beneficiary_params_and_id_are_immutable` |
| INV-18 (post-release releasable zero) | `releasable_view_matches_release` | — | — | `release_again_at_same_total`, `full_release_after_end` |
| INV-19 (released ≤ vested.amount; `≥` guard) | `release_pays_releasable_to_beneficiary` | — | `release_rejects_vested_below_released`, `releasable_rejects_vested_below_released` | — |
| INV-20 (non-decreasing in time) | `vested_amount_is_nondecreasing_in_time` | — | — | — |
| INV-21 (pre-start zero) | — | `vested_amount_pre_start_is_zero` | — | — |
| INV-22 (pre-cliff zero) | — | `vested_amount_pre_cliff_is_zero` | — | — |
| INV-23 (cliff jump) | — | `vested_amount_at_cliff_jumps_to_proportional` | — | — |
| INV-24 (post-end clamp) | — | `vested_amount_post_end_clamps_to_total` | — | `full_release_after_end_then_releasable_zero` |
| INV-25 (linear mid) | `vested_amount_is_linear_mid_schedule` | `vested_amount_at_exact_start_is_zero` (elapsed 0 edge) | — | — |
| INV-26 (u128 intermediate) | — | `vested_amount_uses_u128_intermediate_at_max` | — | — |
| INV-27 (vests as if from start) | — | `deposit_vests_as_if_from_start` | — | — |
| INV-28 (conservation) | `deposit_*`, `release_pays_*` | — | 🔒 `Balance` no drop; `release_aborts_when_vested_exceeds_total` | `release_is_monotone` |
| INV-29 (pays fixed beneficiary) | `release_pays_releasable_to_beneficiary` | — | — | `owned_handoff`, `release_pays_linear_portion` |
| INV-30 (released coins out of reach) | `released_coins_stay_with_beneficiary` | — | — | — |
| INV-31 (permissionless) | `deposit_*_is_permissionless`, `release_pays_linear_*_is_permissionless` | — | — | — |
| INV-32 (single-PTB compositions) | `create_deposit_release_in_one_flow` | — | — | `receive_and_deposit_then_release_in_one_flow` |
| INV-33 (beneficiary any address) | `beneficiary_can_be_object_address` | — | — | — |
| INV-34 (shared concurrent release) | `release_then_release_at_same_clock_is_noop` (idempotency stand-in) | — | — | — |
| INV-35 (owned handoff no redirect) | `owned_handoff_does_not_redirect_cashflow` | — | — | — |
| INV-36 (curve monotone + bounded) | `vested_amount_is_nondecreasing_in_time` (built-in satisfies) | `vested_amount_post_end_clamps` (bounded) | `release_rejects_vested_below_released` (non-monotone aborts), `release_aborts_when_vested_exceeds_total` (unbounded aborts) | — |
| INV-37 (only declarer builds/mints) | `mint_stamps_*`; every `linear_schedule` test | — | 🔒 compile | `destroy_empty_*` (witness-gated) |
| INV-38 (`VestedAmount` drop-only) | `mint_stamps_*_reads_without_consuming` | — | 🔒 compile (no store/key/copy) | — |
| INV-39 (`S` pins curve) | 🔒 `Linear` used throughout | — | 🔒 compile | — |
| INV-44 (wallet binding) | `mint_stamps_*` | — | `release_rejects_vested_from_other_wallet`, `releasable_rejects_vested_from_other_wallet` | — |
| INV-45 (end-time overflow) | — | `new_accepts_end_at_u64_max_boundary` | `new_rejects_schedule_overflow` | — |

Every live invariant has at least one ✅ test or is 🔒 compile-enforced with
positive coverage. No gaps.

## Test Notes

- **Throwaway `TestCurve` for primitive tests.** The primitive is curve-agnostic,
  so the wallet-level invariants (INV-11, 15, 16, 18, 19, 44, …) need a way to
  feed `release` an arbitrary cumulative total. `vesting_wallet_tests` declares a
  `#[test_only]`-module `TestCurve`/`TestParams` and mints `VestedAmount`s
  directly via `mint_vested_amount`, decoupling the accounting tests from the
  linear math. The schedule-shape invariants are tested separately through the
  real `linear_schedule` curve. This mirrors how a downstream custom curve would
  use the primitive.
- **Event assertions.** Four `#[test_only]` event constructors were added to
  `vesting_wallet.move` (`test_new_created/deposited/released/destroyed`,
  matching the `access_control::test_new_role_granted` pattern) so the suite can
  assert event *field values*, not just cardinality. `Deposited`/`Released`/
  `Destroyed` are asserted by full value equality in both suites; the linear
  `Created` event (whose `schedule_params: Params` field is module-private) is
  asserted by cardinality plus the public accessors. `event::events_by_type` is
  per-transaction, so no-op assertions (zero `Released`) are made in a fresh
  `next_tx`.
- **Verified the code is ahead of the invariants doc.** Several INV code-notes
  describe an earlier code state that the current implementation has already
  fixed; the tests pin the *current* behaviour. See Upstream Sync below.
- **INV-34 (concurrent release).** A deterministic two-transaction race is not
  authorable in `test_scenario`; per the invariants doc, the same-clock
  back-to-back release idempotency test exercises the underlying property (each
  `release` recomputes `releasable` fresh against the live `released`).

## Out of Scope

- **Type-level negative tests (INV-1, INV-37 mint/build gate, INV-38 no
  store/key/copy, INV-39 curve pinning).** A snippet that violates these does not
  compile, so it cannot live in the package's test suite. Each is covered
  positively (the allowed direction executes) and the negative direction is
  guaranteed by the Move type system. Verifying the compile failures would
  require a separate "expected-compile-failure" harness the repo does not use.
- **INV-5 negative (receipt addressed elsewhere).** Framework-enforced by
  `transfer::public_receive`; the positive path is tested, the framework abort is
  not re-tested here.
- **INV-34 two-transaction concurrent race.** Requires real consensus ordering;
  not deterministically reproducible in `test_scenario` (covered by the
  idempotency stand-in — see Test Notes).
- **`u64` aggregate-deposit overflow (`balance::join`).** Out of scope in the
  invariants doc (framework abort, no typed error); not tested. The *schedule*
  end-time overflow (INV-45) is tested.
- **Custom-curve schedule shapes (downstream).** INV-20..27 are tested only for
  the built-in `Linear` curve; downstream curves owe their own shape tests
  (INV-36 is the only contract the wallet imposes).

## Dev Notes

- All 45 tests pass; `sui move test --coverage` reports **100.00%** module
  coverage for both `vesting_wallet` and `linear_schedule`;
  `sui move build --lint --warnings-are-errors` is clean.
- The source changes are additive and test-only: four `#[test_only]` event
  constructors under a `// === Test-Only Helpers ===` section in
  `vesting_wallet.move`, plus a `#[test_only] test_params` constructor in the same
  section of `linear_schedule.move` (so tests can assert the linear `Created`
  payload, whose `Params` fields are module-private). No production code was
  modified.
- No code bugs surfaced. Every assertion that could expose a math or accounting
  error (cliff jump = 250, mid = 500/750, u128 worst case = MAX-1, ledger
  conservation after each step) holds exactly.

## Upstream Sync — applied to `invariants.md`

Resolved (BTT run, 2026-06-17). The three doc-consistency items surfaced while
pinning current behaviour have been applied to `invariants.md`:

1. **INV-12 code note** — removed, along with the "inconsistent type-argument tag"
   violation-scenario clause. Current code emits `Deposited<S, C>` /
   `Released<S, C>` / `Destroyed<S, C>` — all four events use `S`.
2. **INV-19 code note + statement** — updated to name `EVestedBelowReleased` on
   both `release` and `releasable`; the asymmetry code note and the coverage
   matrix's "(bare subtraction)" tag are removed.
3. **Open Questions 1–3** — removed from `invariants.md`.

## Open Questions

None blocking.

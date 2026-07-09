---
stage: review
project: prefunded-sale
mode: extension
extends: contracts/sale/sources
status: draft
timestamp: 2026-07-09
author: claude (basic-review)
previous_stage: contracts/sale/artifacts/docs.md
tags: [sale, presale, fixed-price, prefunded, refund-vault, allowlist, vesting, review]
---

# Prefunded Sale — Basic Review Report

## Summary

Reviewed the `openzeppelin_sale` package on `token-presale`: six modules
(`prefunded_sale`, `phase`, `receipt`, `refund_vault`, `allowlist`,
`fixed_rate_curve`, ~3.2k source lines) against the invariants document, the
seven security categories, and code quality. Verified against ground truth:
`sui move build --build-env testnet` and `--lint --warnings-are-errors` are clean,
and **89/89 tests pass**.

**Overall: ready to publish. No Critical, High, or Medium findings.** The core
money-flow invariants (inventory solvency, refund solvency, conservation, phase
monotonicity, no-rug) hold under the code as written, and the design leans on the
type system in several places that a first read makes look like footguns but which
are in fact air-tight (see below). Remaining items are 2 Low-severity **test gaps**,
3 Informational doc/event nits, and artifact drift in `invariants.md` (the source
moved ahead of it — mostly already flagged by the tests/docs stages). **All
code/test items were resolved in this branch after the review — see the Resolution
Log below; only the `invariants.md` drift is outstanding.**

Two structural risks I specifically chased and **cleared**:

1. *Deposited inventory stranded if setup is abandoned mid-way.* Cannot happen.
   `PrefundedSale` is `key`-only with no `store`; its **only** by-value consumer is
   `share_and_activate`. The caller can neither `public_transfer` it nor share it
   themselves, so a PTB that calls `create_sale` must reach `share_and_activate`
   (or revert and return the inventory). Setup is atomic by construction.
2. *Buyer refunds break if the vault is never shared.* Cannot happen. `RefundVault`
   is likewise `key`-only/no-`store` with `refund_vault::share` its only by-value
   consumer, so the vault is forced to become shared (or the PTB reverts). The
   permissionless `finalize` / `cancel_after_close` / `refund` paths always have a
   reachable vault, so INV-27 holds.

## Resolution Log (2026-07-09)

All findings were addressed in this branch after the review. Build (`--doc`), lint
(`--warnings-are-errors`), and the test suite (now **96/96**, up from 89) are green.

| Finding | Resolution | Commit |
|---------|------------|--------|
| INFO-1 | `refund_vault::deposit` now joins first (consuming the balance) and gates the `VaultDeposit` event on `amount != 0`, matching `vesting_wallet::deposit`. Tests: `deposit_zero_is_noop`, `cancel_emergency_zero_raised_succeeds`. | `faf9439` |
| LOW-1 | Added `withdraw_unsold_in_cancelled_recovers_freed_inventory` — covers the Cancelled-phase withdrawal and the freed-inventory-after-refund interaction. | `ff727f9` |
| LOW-2 | Added `EWrongVault` failure tests on `finalize` / `cancel_after_close` / `cancel_emergency` / `refund`, each driven past the preceding guards. | `8dfae6a` |
| INFO-2 | Module header simplified to a plain description (dropped the 2-of-5-param `PrefundedSale` sig and the invented `MintingSale<..>` forward-reference); `refund_vault` comment reworded to name `P` as the payment coin. | `4aa2eab` |
| INFO-3 | Removed the single-use `unpack` helper (whose doc mislabeled the payment balance as `paid`); `purchase` destructures the `Quote` directly. | `6ad40d4` |

Still outstanding: the `invariants.md` artifact-drift sync (see `## Artifact Drift`),
which is owned by the invariants stage.

## Invariant Verification

All 33 invariants are enforced by the current source. `Enforced?` = ✅ where the
source enforces exactly what the statement says; ⚠️ where enforced but the
invariants-doc text is stale about *how* (a drift note, not a missing check — see
`## Artifact Drift`).

| Invariant | Enforced? | Location | Notes |
|-----------|-----------|----------|-------|
| INV-1 Receipt non-transferable, buyer-bound | ✅ | `receipt.move` (`key`-only; `public(package)` `deliver`/`consume`) + `claim_internal`/`refund` sender asserts | Type-level + runtime |
| INV-2 Quote single-use witness hot potato | ✅ | `Quote` (no abilities), `mint_quote` (`_w: Curve`), private `unpack` | |
| INV-3 ActivationTicket witness hot potato | ✅ | `ActivationTicket` (no abilities), `mint_activation_ticket`, consumed in `share_and_activate` | |
| INV-4 AllowEntry single-use no-ability ticket | ✅ | `allowlist.move` `AllowEntry` (no abilities), `consume` asserts sale+buyer | |
| INV-5 Caps bound to one sale/vault | ✅ | `SaleAdminCap.sale_id`, `AllowlistAdmin.sale_id`, `RefundVaultCap.vault_id` id-match asserts | |
| INV-6 Phantom types prevent cross-coin/curve | ✅ | Generic signatures across all modules | Compile-time |
| INV-7 Curve witness gates pricing/activation | ✅ | `mint_quote`/`mint_activation_ticket` require `Curve` by value; private ctor | Gates *who*, not the result (INV-23) |
| INV-8 Construction params well-formed | ✅ | `create_sale:567-569`; `fixed_rate_curve::params:85` | |
| INV-9 Redemption buyer-only + sale-matched | ✅ | `claim_internal:1960-1961`, `refund:1491-1492` | |
| INV-10 Setup Init-only / one-shot | ✅ | `assert_init` + `is_none`/`!requires_allowlist` guards in each setter | |
| INV-11 Vault pairing matching/active/empty | ✅ | `pair_refund_vault:735-739` | |
| INV-12 Activation gate | ✅ | `share_and_activate:862-870` | Ticket sale-id uses `ETicketSaleMismatch` (62), **not** `EReceiptSaleMismatch` (60) as INV doc says → drift |
| INV-13 Purchase window/caps/allowlist/inventory | ✅ | `purchase:942-989` | u128-widened arithmetic |
| INV-14 Quote rejects zero / overflow | ✅ | `mint_quote:1907-1909`; `activation_ticket:106` | |
| INV-15 Allowlist symmetric & one-shot | ✅ | `enable_allowlist:779`, `purchase:953-961` | |
| INV-16 Close preconditions | ✅ | `finalize:1049-1057`, `cancel_after_close:1108-1111`, `cancel_emergency:1157-1162` | |
| INV-17 Vesting routing mutually exclusive | ✅ | `claim:1235`, `claim_into_vesting:1322`, forced `ctx.sender()` beneficiary | |
| INV-18 Admin withdrawals cap+phase gated | ✅ | `withdraw_proceeds:1407-1408`, `withdraw_unsold_inventory:1442-1443` | |
| INV-19 Vault mutations cap+state gated | ✅ | `refund_vault.move` deposit/flip/release/withdraw_all | |
| INV-20 Phase monotonic, terminal sinks | ✅ | `phase.move` transition asserts | |
| INV-21 Inventory covers allocations | ✅ | `purchase:988-992`, `claim_internal:1966-1967`, `withdraw_unsold_inventory:1444` | Holds; honest fixed-rate curve makes `EInsufficientInventory` unreachable |
| INV-22 raised tracks proceeds ≤ hard_cap | ✅ | `purchase:968-993`, `do_cancel:1183-1187` | |
| INV-23 Curve trusted (no independent rate bound) | ✅ (intentional) | Witness gate only; result unchecked | Dev-confirmed design; **not** a finding |
| INV-24 Conservation | ✅ | `claim_internal`, `refund`, `withdraw_*` exact splits | |
| INV-25 Vault mirrors terminal phase; cap never escapes | ✅ | `finalize:1062` (→Closed), `do_cancel:1188` (→Refunding); cap wrapped in `Option`, never read out | |
| INV-26 Refund solvency | ✅ | `do_cancel` moves all proceeds to vault; `release_balance` `locked>=amount` | |
| INV-27 Buyer redemption admin-independent | ✅ | `purchase`/`claim*`/`refund`/`finalize`/`cancel_after_close` permissionless | Depends on vault being shared — type-forced (see Summary) |
| INV-28 Admin cannot rug goal-reaching sale | ✅ | `cancel_emergency:1161-1162` | |
| INV-29 Proceeds success XOR refund | ✅ | Phase gating (Finalized vs Cancelled) + INV-20 | |
| INV-30 quote+purchase single PTB | ✅ | `Quote` no abilities | |
| INV-31 compliance mint+purchase single PTB | ✅ | `AllowEntry` no abilities | |
| INV-32 claim_into_vesting composes with wallet | ⚠️ | `claim_into_vesting:1321-1332` | Correct, but now returns `(VestingWallet, DestroyCap)` — INV doc still says "wallet directly" → drift |
| INV-33 Shared sale tolerates concurrent callers | ✅ | Shared object; no exclusive-access assumption | |

## Findings

### Critical
None.

### High
None.

### Medium
None.

### Low

#### LOW-1: `withdraw_unsold_inventory` in the `Cancelled` phase is untested

**Location:** `prefunded_sale.move` `withdraw_unsold_inventory()` (guard
`assert_terminal`, line 1443) / `tests/prefunded_sale_claim_refund_tests.move:436`

**Issue:** `withdraw_unsold_inventory` is allowed in *either* terminal phase
(`Finalized` or `Cancelled`), and in a cancelled sale it is the mechanism by which
the admin recovers inventory freed as buyers refund (each `refund` decrements
`total_allocated`, enlarging the withdrawable slack). Only the `Finalized` branch is
tested (`withdraw_unsold_returns_only_slack`). The `Cancelled` branch and the
"admin recovers freed inventory after a refund" interaction have no test.

**Impact:** A regression that broke inventory recovery in the cancelled path (e.g. a
future change to `assert_terminal` or to `total_allocated` bookkeeping in `refund`)
would not be caught. No current bug — the code path is correct.

**Recommendation:** Add a test: cancel a sale with an outstanding receipt, call
`withdraw_unsold_inventory` (expect only the truly-unsold slack), have the buyer
`refund`, then call `withdraw_unsold_inventory` again and assert the freed
allocation is now recoverable.

**Status:** Fixed (`ff727f9` — `withdraw_unsold_in_cancelled_recovers_freed_inventory`)

#### LOW-2: `EWrongVault` untested on the close/refund paths

**Location:** `finalize:1057`, `do_cancel:1181` (covers `cancel_after_close` /
`cancel_emergency`), `refund:1494`

**Issue:** Every close/refund path re-asserts `object::id(vault) == paired_id`
(`EWrongVault`) so a caller cannot substitute a different vault at close or refund
time. This assertion is only exercised at *pairing* time
(`pair_rejects_mismatched_cap`, setup_tests:268). The close-time and refund-time
`EWrongVault` guards have no failure test.

**Impact:** These are security-relevant asserts (they prevent draining proceeds into,
or refunding out of, an attacker-supplied vault). A regression removing one would go
unnoticed. No current bug — the asserts are present and correct.

**Recommendation:** Add `#[expected_failure(abort_code = EWrongVault)]` tests that
pass a valid-but-unpaired vault to `finalize`, `cancel_after_close`, and `refund`.
For exhaustive branch coverage, run `/sui-btt`.

**Status:** Fixed (`8dfae6a` — wrong-vault failure tests on all four paths)

### Informational

#### INFO-1: `refund_vault::deposit` emits an event for zero-value deposits

**Location:** `refund_vault.move` `deposit()` lines 174-184

**Issue:** `deposit` emits `VaultDeposit` unconditionally. `do_cancel` always calls
`vault.deposit(cap, proceeds)`, and when `raised == 0` (e.g. `cancel_emergency`
pre-open or with zero purchases) it deposits an empty balance, emitting a
`VaultDeposit { amount: 0, locked_after: 0 }`. The sibling `vesting_wallet::deposit`
returns early on a zero balance and emits nothing. Cosmetic event noise only.

**Recommendation:** Optional — early-return on `funds.value() == 0` in
`refund_vault::deposit` to match `vesting_wallet::deposit`, or leave as-is (the
generic primitive arguably *should* record every deposit call).

#### INFO-2: Module-doc header uses the stale 2-parameter type signatures

**Location:** `prefunded_sale.move` lines 1, 5

**Issue:** The very first module-doc line reads
`PrefundedSale<SaleCoin, PaymentCoin>` and line 5 `MintingSale<SaleCoin, PaymentCoin>`,
but the real type is the 5-parameter
`PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>`.
The multi-parameter shape is itself documented (in the README) as the "main
ergonomic hurdle," so the simplified header is the first thing an auditor sees and it
under-represents that complexity. The docs stage corrected the *body* comments but
not this header line.

**Recommendation:** Update the header to the full signature (or add "(abbreviated)").

#### INFO-3: `unpack` doc comment mislabels the returned payment balance

**Location:** `prefunded_sale.move` lines 1913-1918

**Issue:** The doc says `unpack` "Returns `(sale_id, paid, allocation)`", but the
middle element is the `Balance<PaymentCoin>` payment, not a `u64` "paid" amount
(the return type is `(ID, Balance<PaymentCoin>, u64)`). Minor; this is a
package-private helper.

**Recommendation:** Reword to `(sale_id, payment, allocation)`.

## Security Checklist Results

| Category | Result | Notes |
|----------|--------|-------|
| 3.1 Access control | ✅ Pass | Admin paths cap+id-gated; setup gated by Init ownership; buyer paths assert `sender == receipt.buyer`; curve paths witness-gated; allowlist via `AllowlistAdmin`. `public`/`public(package)` split is correct — receipt mint/deliver/consume and allowlist `new_admin`/`consume` are package-internal. |
| 3.2 Object safety | ✅ Pass | No leaks: `PrefundedSale` and `RefundVault` are `key`-only/no-`store` and must be shared by their only by-value consumers or the PTB reverts. Receipts delivered to buyer; caps returned. `contributions` `Table` lives with the permanent shared sale (never orphaned; never pruned — accepted, O(1)). Vault-id and receipt-sale-id checked wherever objects are passed. |
| 3.3 Arithmetic | ✅ Pass | `allocation` and `raised+paid` widened to u128 with typed overflow guards; `activation_ticket` overflow-checks `hard_cap*rate`; no division anywhere; `total_allocated` decrements are matched 1:1 with prior increments (cannot underflow); `inventory.split`/`release_balance` guarded by INV-21/INV-26. |
| 3.4 Type safety | ✅ Pass | Phantom generics prevent cross-coin/cross-curve pairing; witness pattern (`Curve`, vesting `Witness`) correct; `Quote`/`ActivationTicket`/`AllowEntry` are ability-less hot potatoes — unstorable, unreplayable, single-PTB. |
| 3.5 Reentrancy & composability | ✅ Pass | No callbacks into the sale; the only external calls (`vesting_wallet::new`/`deposit`) don't re-enter. Shared object makes no sole-caller assumption. Vault pairing has no TOCTOU (cap-gated; empty+active checked at pair time; cap consumed so no concurrent mutation). |
| 3.6 Economic security | ✅ Pass | Conservation, refund solvency, and success-XOR-refund proceeds routing hold. No mint/burn — only routing of deposited balances. `cancel_emergency` blocked once soft/hard cap met (no rug). Curve is a trusted, witness-gated component by design (INV-23, dev-confirmed) — the only residual is an honest-curve-provisioning assumption, bounded by inventory. |
| 3.7 Upgrade safety | ⚠️ N/A this pass | Package is unpublished (`Move.toml` `0x0`, local finance dep, absent from the `contracts/README.md` catalog). No on-chain compatibility surface yet. Enum-based `Phase`/`VaultState` and phantom-generic types are upgrade-friendly, but a full upgrade-compat review belongs at publish time. |

## Test Coverage Assessment

Strong. 96 tests across 10 files (89 at review time + 7 added closing LOW-1/LOW-2 and
INFO-1), an invariant→test matrix mapping every INV, real (non-mocked)
`FixedRateCurve` pricing on happy paths, a dishonest `BadCurve` to reach the INV-23
residual and the `EInsufficientInventory` bound, and real `VestingWallet<Linear, ...>`
composition. Build/lint/tests all green (verified this pass).

Gaps found (both Low, both regression-guards rather than live bugs) — **both now
closed** (see Resolution Log):
- `withdraw_unsold_inventory` in the `Cancelled` phase (LOW-1). ✅ Fixed.
- `EWrongVault` on `finalize` / `cancel_after_close` / `cancel_emergency` / `refund`
  (LOW-2). ✅ Fixed.

For a systematic branch-by-branch pass, `/sui-btt` is the right follow-up.

## Artifact Drift

The source moved ahead of `invariants.md` (which predates the tests/docs stages and
the release-v1.4 vesting merge). The tests and docs artifacts already flagged most of
this; recorded here for completeness. Doc-sync only, not findings.

- **Artifact:** `artifacts/invariants.md` (INV-12, Dev Notes bullet 2, Open Question #2)
  → **Stale:** `share_and_activate` reuses `EReceiptSaleMismatch` (code 60) for the
  ticket sale-id check → **Current:** source uses the dedicated `ETicketSaleMismatch`
  (code 62) at `prefunded_sale.move:862` (fixed in `547c315`) → **Suggested update:**
  rename in INV-12 + Dev Notes; mark Open Question #2 resolved.
- **Artifact:** `artifacts/invariants.md` (INV-32, Composability; Dev Notes bullet 2b)
  → **Stale:** `claim_into_vesting` "returns a `VestingWallet` ... directly"
  → **Current:** returns `(VestingWallet, vesting_wallet::DestroyCap)` after the
  release-v1.4 merge (`prefunded_sale.move:1321`) → **Suggested update:** add the
  `DestroyCap` to INV-32.
- **Artifact:** `artifacts/invariants.md` (Dev Notes bullet 1; Open Question #1)
  → **Stale:** the stale `max_rate` doc comments "should be corrected at the
  code-comment / docs stage" → **Current:** already corrected — see `docs.md`
  Revision-2 and the "Source doc-comment corrections" section → **Suggested update:**
  mark resolved.
- **Artifact:** `artifacts/invariants.md` frontmatter (`status: draft`,
  `timestamp: 2026-06-25`) → **Stale:** predates the vesting-wallet merge that changed
  the vesting return shape → **Current:** `docs.md` is Revision 2 (2026-07-09)
  → **Suggested update:** refresh once the INV-12/INV-32 edits land.

## Extension Mode: Compatibility Check

This is substantively a **new package**; the only pre-existing code in play is
`openzeppelin_finance::vesting_wallet`, which the sale consumes.

- The `release-v1.4` merge changed `vesting_wallet::new` to return
  `(VestingWallet, DestroyCap)` and `release` to pay into the beneficiary's address
  balance. The sale calls only `new` + `deposit` and **never** `release`, so the
  release-mechanism change does not reach it. `claim_into_vesting` /
  `claim_all_into_vesting` correctly destructure the new tuple and thread the
  `DestroyCap` out to the buyer. Integration verified: 89/89 tests pass, including the
  real-`VestingWallet` composition tests.
- No existing sale-package API is broken (the package is new; nothing depends on it
  yet).
- The vesting-wallet changes themselves are **out of scope** here — they belong to the
  `finance` package's own review.

## Recommendation

- **Overall verdict:** **Ready for publishing.** No blocking issues.
- **Blocking issues:** None.
- **Suggested improvements (non-blocking):**
  - ~~Close the two test gaps (LOW-1, LOW-2)~~ — done (`ff727f9`, `8dfae6a`); run
    `/sui-btt` for a full branch sweep beyond these.
  - ~~Apply the three informational doc/event nits (INFO-1..3)~~ — done (`faf9439`,
    `4aa2eab`, `6ad40d4`).
  - Sync `artifacts/invariants.md` to the current source (Artifact Drift section). **Still open.**
  - At publish time: run an upgrade-compatibility pass, add `sale` to the
    `contracts/README.md` catalog, and stand up the hosted docs (per `docs.md` Open
    Questions).

## Out of Scope

- **`openzeppelin_finance::vesting_wallet` / `vesting_wallet_linear` changes** (203-line
  diff on this branch) and their tests/examples — the sale only consumes the unchanged
  `new`/`deposit` surface (integration verified); the changes belong to the finance
  package's own review.
- **Curve pricing correctness, vesting release-schedule math, KYC verification** —
  delegated, trusted components (INV-23 and the invariants doc's Out of Scope).
- **True concurrent PTB execution (INV-33)** — requires testnet; the unit VM serializes.
- **Upgrade compatibility** — package is unpublished; deferred to publish time.
- **Gas / storage optimization** — this pass targeted correctness and security.
- **Exhaustive branch-coverage audit** — that is `/sui-btt`'s job; this pass spot-checked.

## Dev Notes

- The `key`-only/no-`store` discipline on `PrefundedSale` and `RefundVault` is doing
  real safety work: it makes atomic setup+activation and vault-sharing *unavoidable*
  rather than merely recommended. Worth preserving deliberately across any future
  refactor (e.g. resist adding `store` to either for "convenience").
- INV-23 (curve is trusted, no independent rate bound) is the load-bearing assumption.
  It is dev-confirmed intentional and well-documented (README headline + `[!IMPORTANT]`
  callout + module comments), and the sale's independent protections (inventory
  bounding + overflow guards) are correctly in place. Treated as accepted, not a
  finding — but it is the single thing an integrator/auditor must internalize.
- Verified this pass (not just trusting the artifacts): `sui move build --build-env
  testnet` succeeds, `--lint --warnings-are-errors` is clean, and `sui move test`
  reports 89/89. (Plain `--path` without `--build-env` fails dependency resolution
  because the merged vesting-wallet pulls in framework accumulator features — worth a
  one-line note in the package README/CONTRIBUTING if not already implied.)

## Open Questions

1. Take the two Low test gaps here, or defer to a dedicated `/sui-btt` pass?
2. Confirm you want the `invariants.md` drift synced now vs. left until the artifact is
   next revised (it is `status: draft`).
3. Should the sale README/CONTRIBUTING note the `--build-env testnet|mainnet`
   requirement introduced by the vesting-wallet accumulator dependency?

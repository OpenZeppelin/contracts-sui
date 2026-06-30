---
stage: docs
project: prefunded-sale
mode: extension
extends: contracts/sale/sources
status: draft
timestamp: 2026-06-26
author: nenad
previous_stage: contracts/sale/artifacts/tests.md
tags: [sale, presale, fixed-price, prefunded, refund-vault, allowlist, vesting, docs]
---

# Prefunded Sale - Documentation

## Summary

Two deliverables: (1) a comprehensive root `README.md` for `openzeppelin_sale` in the
`finance` package's house style, and (2) a full pass over the **source doc-comments**
across all six modules to bring them into line with `STYLEGUIDE.md`. Since
`sui move build --doc` generates the hosted API reference from those comments, the
doc-comments are the API reference.

Every public function now carries a description plus `#### Parameters` / `#### Returns`
/ `#### Aborts` sections (Aborts lists every cause, including native overflow and
errors propagated from internal calls), and every error constant carries a `///`
doc-comment. The earlier stale content (the non-existent `max_rate` bound, the
`VestedAllocation` hot-potato, the bogus `fixed_rate_curve` purchase snippet, stray
`vested_claim` references, and "returns `Coin`" where the function returns `Balance`)
was corrected in the same pass, and all em dashes / arrows were normalized to `-` /
`->` per the guide.

`sui move build --doc` succeeds; all 89 tests still pass. Every README example was
verified against the actual API (source signatures + the passing test suite).

Per repo convention, **no hand-written `api-reference.md` / `integration-guide.md` and
no `docs/` directory were created** - the API reference is generated from these source
comments, and integration patterns live in the README. Dev-confirmed at the
stage-start drift check.

## Documents

| Document | Status | Purpose | Audience |
|----------|--------|---------|----------|
| `contracts/sale/README.md` | **Written** (replaces 1-line stub) | Landing page: overview, install, modules, key concepts, lifecycle, usage, PTB/TS integration, common mistakes, security notes | All developers + protocol teams |
| API reference (source doc-comments) | **Brought to convention** | All six modules: `#### Parameters`/`#### Returns`/`#### Aborts` on every public function, `///` on every error. `sui move build --doc` is the generator | Move developers |
| Integration guide | Folded into README | "Usage", "PTB / TypeScript integration", "Common mistakes", "Security Notes" sections | Protocol teams |
| `examples/` | Deferred | Standalone integration example modules + tests | All developers |
| CHANGELOG.md | N/A | Package is unreleased - no prior version to diff against | - |

## Source doc-comment corrections (extension mode: what changed)

Comment-only edits except where noted. No logic changed; abort codes unchanged.

**`sources/prefunded_sale.move`**
- Module doc "Hard cap" bullet: `inventory >= hard_cap * max_rate` -> `inventory >= required_inventory` (curve-supplied via `ActivationTicket`).
- `create_sale` doc: removed the non-existent `max_rate` parameter description and the bogus `max_rate > 0` assert; reframed as curve-supplied + trusted.
- `share_and_activate` doc: `hard_cap * max_rate` -> `required_inventory` (carried by the curve's ticket).
- `purchase` doc: removed the stale `paid * max_rate` defensive-bound claim and the `Quote<Curve>`/`quote.paid == payment.value()` framing (there is no separate payment param; payment rides inside the `Quote`). Replaced with the actual trust model (INV-23) + the real overflow guards.
- `Quote` section comment: removed the stale `quote.paid == coin::value(payment)` and `quote.allocation <= quote.paid * sale.max_rate` paragraph; replaced with the witness-gate / no-rate-bound explanation.
- `claim_into_vesting` doc: `VestedAllocation` hot-potato -> returns a funded `VestingWallet<Witness, VestingScheduleParams, SaleCoin>` directly (INV-32); documented the `Witness` type-arg requirement.
- `vesting_schedule_params` field doc + `set_vesting_schedule_params` doc: `claim_into_vesting -> vested_claim::into_*` -> `claim_into_vesting` returns a funded `VestingWallet`.
- **Error string** `EClaimRequiresVesting` (code 81): dropped the `+ vested_claim` (non-existent module). *String change, not a comment.*
- **Error string** `EInsufficientInventoryAtActivate` (code 25): `hard_cap * max_rate` -> "the curve's required backing". *String change, not a comment.*

**`sources/fixed_rate_curve.move`**
- Module doc: removed `max_rate` framing and the non-existent `create_sale` sugar; corrected the integrator API list to `params / activation_ticket / quote / rate`.
- `### Purchase` snippet: `quote(&sale, paid)` + `purchase(&mut sale, payment, quote, ...)` -> `quote(&sale, payment.into_balance())` + `purchase(&mut sale, quote, allow, &clock, ctx)` (payment is carried by the `Quote`).
- `quote` fn doc: "buyer paying `paid` units" -> "buyer's `balance`".

**`sources/receipt.move`**
- Package-internal helpers comment: removed the stale `vested_claim` consumer reference.

## STYLEGUIDE doc-comment conformance (all six modules)

Applied the `STYLEGUIDE.md` Documentation rules so the generated API reference is
complete:

- **Every error constant** got a `///` doc-comment describing the condition that
  raises it (`phase` 6, `refund_vault` 5, `allowlist` 2, `fixed_rate_curve` 2,
  `prefunded_sale` 33).
- **Every public function** got `#### Parameters` / `#### Returns` and, where it can
  abort, `#### Aborts`. The Aborts sections list every cause, including:
  - native aborts (e.g. `deposit`'s inventory-join overflow);
  - **propagated** aborts from internal calls (e.g. `fixed_rate_curve::quote` lists
    `prefunded_sale::EZeroPayment` / `EAllocationOverflow`; sale redemption paths name
    the `phase` errors they trigger through helpers);
  - logically-unreachable propagated guards (e.g. the vault-state asserts behind
    `finalize`/`refund`, satisfied by the sale's own invariants) were **omitted** per
    the guide's "avoid documenting impossible paths".
- **Stale return types fixed**: `claim` / `claim_all` / `refund` / `withdraw_*`
  document returning `Balance<...>` (the prior text said `Coin`).
- **Dashes/arrows normalized**: em dashes to `-`, `->` for transitions, matching
  `finance`.

Package builds with `--doc`; 89/89 tests pass (the two error-string edits changed no
abort codes).

## Out of Scope

- **Hand-written API reference (`api-reference.md`)** - the repo generates and hosts the
  API reference from source doc comments; a parallel hand-written file would duplicate
  and drift. This pass instead corrected the source comments that feed it.
- **Separate `integration-guide.md` / `docs/` directory** - house convention keeps
  integration patterns inside the package README (as `finance`/`access`/`utils` do).
  Folded in rather than split out.
- **`examples/` integration modules** - `contracts/sale/examples/` exists but is empty;
  the house pattern populates it via `/sui-library-integration-example` (separate,
  compiling example modules + tests), not the docs stage. Deferred; README points there.
- **CHANGELOG / migration guide** - the package is unreleased (absent from the
  `contracts/README.md` catalog; `Move.toml` is `0x0` with a local finance dep), so
  there is no prior published version to changelog against.
- **Full TypeScript SDK / client library** - only illustrative PTB snippets are
  provided (buyer purchase + a note on the allowlist + balance->coin follow-ups).
- **Invariants/tests artifact sync** - those are separate artifacts owned by their
  stages; not rewritten here (the `EReceiptSaleMismatch -> ETicketSaleMismatch`
  carry-over from tests.md is surfaced in Open Questions, not silently applied).
- **The future minting sale flavor** - not in this branch.

## Dev Notes

- **Stage-start drift-check decisions (dev-confirmed):** (1) **Rich root README** in
  house style, not the literal `sui-docs` `docs/` template. (2) **Fix the stale source
  comments** as part of this pass so the generated API reference is accurate.
- **Scope expanded after dev feedback.** The first pass did the README + stale-comment
  fixes only. On review the dev required the full `STYLEGUIDE.md` doc-comment treatment
  - `#### Parameters` / `#### Returns` / `#### Aborts` on every public function and a
  `///` on every error - now complete across all six modules (see "STYLEGUIDE
  doc-comment conformance").
- **Further doc refinements (dev feedback).** (1) Every `#[error]` message string was
  rewritten as plain, user-facing English with no field/function/type identifiers
  (abort codes unchanged; tests assert on codes, all 89 pass). (2) `///` docs added to
  every type and event (and `CancelReason`). (3) `#### Aborts` extended to list
  propagated/nested abort codes (paired-vault, phase, and finance vesting-wallet
  errors), with invariant-guarded ones explicitly marked unreachable. (4) Field-level
  `///` docs on every non-event public type in `vesting_wallet` style - including
  moving `Receipt`'s field list out of its top doc-comment into per-field docs.
- **Scope note on the two error-string edits.** The drift-check preview listed
  *comment* edits. Two of the 14 edits also touched error-message *strings*
  (`EClaimRequiresVesting`, `EInsufficientInventoryAtActivate`) because they named
  non-existent concepts (`vested_claim`, `max_rate`) - the same staleness the pass is
  removing. Abort codes are unchanged and all 89 tests (which assert on codes, not
  strings) pass. Flagged here for visibility; trivial to revert if you'd rather keep
  the strings.
- **Trust model is the README's headline** (Key Concepts -> "The sale is pricing-agnostic;
  the curve is trusted", plus an `[!IMPORTANT]` callout). This is the docs realization
  of INV-23 - the single most important thing an integrator/auditor must internalize.
- **Hot-potato warnings are prominent** (`Quote`, `AllowEntry`, `ActivationTicket`), per
  the Sui doc convention that these are the #1 source of confusion.
- **The 5-type-parameter `PrefundedSale`** is explained with a table, and the awkward
  always-instantiate-`VestingScheduleParams` slot (use `vesting_wallet_linear::Params`
  even for non-vesting sales) is called out - this is the main ergonomic hurdle.
- **Forward-looking links.** The README's hosted-docs links
  (`docs.openzeppelin.com/.../sale`, `/api/sale`) and the MVR handle
  (`@openzeppelin-move/sale`) follow the sibling-package pattern but **do not resolve
  yet** - the package is unpublished and not in the catalog. An `[!NOTE]` in Install
  says so. See Open Questions.
- Verified all examples against `tests/test_utils.move` and
  `tests/prefunded_sale_claim_refund_tests.move` - call forms, method-vs-function
  syntax, the 6-type-arg `claim_into_vesting`, and the `Balance`-returning redemption
  functions all match the real API.

## Open Questions

1. **Release plumbing.** Confirm the intended MVR handle (`@openzeppelin-move/sale`)
   and, when published, add `sale` to the `contracts/README.md` catalog and stand up
   the hosted `/sale` + `/api/sale` docs pages. The README Install note + Learn More
   links assume these.
2. **Keep the two error-string edits, or revert to comment-only?** Recommend keep
   (they named non-existent concepts; no behavioral change).
3. **`examples/` population.** Schedule a `/sui-library-integration-example` pass to
   fill `contracts/sale/examples/` (README's "Examples" section points there).
4. **Carry-over from tests.md (not a docs deliverable):** apply the
   `EReceiptSaleMismatch -> ETicketSaleMismatch` correction in `invariants.md` INV-12 +
   Dev Notes? Source already uses `ETicketSaleMismatch` (code 62); the README/source are
   correct - only the invariants artifact lags.

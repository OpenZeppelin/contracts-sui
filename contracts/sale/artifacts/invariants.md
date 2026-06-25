---
stage: invariants
project: prefunded-sale
mode: extension
extends: contracts/sale/sources
status: draft
timestamp: 2026-06-25
author: nenad
previous_stage: null
tags: [sale, presale, fixed-price, prefunded, refund-vault, allowlist, vesting]
---

# Prefunded Sale — Invariants

## Summary

Invariants extracted directly from the source on `token-presale` (code is law;
the README and several doc comments are stale and were ignored). The library is
a fixed-price, pre-funded token sale (`prefunded_sale`) plus four orthogonal
side modules: a lifecycle enum (`phase`), a non-transferable claim ticket
(`receipt`), a generic refundable escrow (`refund_vault`), a compliance slot
(`allowlist`), and one pricing curve (`fixed_rate_curve`). The organizing
principle is **capability- and witness-gated authority with type-enforced
single-use carriers**: setup authority is implicit ownership during `Init`;
post-activation authority splits into permissionless buyer paths, cap-gated
admin paths, and witness-gated curve paths. The most critical properties are
(a) inventory solvency `inventory >= total_allocated`, (b) refund solvency
`vault.locked == raised` after cancel, (c) the curve-trust boundary, and
(d) phase monotonicity.

> **Trust-model headline (read first).** The pricing curve module is a
> **trusted component**, not a checked one. `purchase` accepts the curve's
> `allocation` verbatim, bounded only by unallocated inventory; `share_and_activate`
> accepts the curve's `required_inventory` verbatim. The widely-documented
> `allocation <= paid * max_rate` defensive bound **is not implemented** — there
> is no `max_rate` field. This is **intentional** — the curve is a trusted,
> witness-gated component (dev-confirmed). See INV-23.

## Type-Level Invariants

### INV-1: Receipt is non-transferable and buyer-bound

**Category:** Type-level
**Statement:** `Receipt<S>` has `key` only (no `store`). It can be moved to an
address solely through `receipt::deliver` (package-internal, called once at
purchase). No consumer module can `transfer`/`public_transfer` it, store it in a
field, or wrap it.
**Applies to:** `Receipt<S>`, `purchase`, `claim`, `claim_into_vesting`, `refund`.
**Enforcement:** Type system (`key`-only ability) + `public(package)` visibility
on `new_receipt`/`deliver`/`consume`. Redemption paths additionally assert
`ctx.sender() == receipt.buyer` (INV-9), so even shared custody cannot delegate.
**Violation scenario:** If `store` were added, a buyer could sell/forward a
receipt, bypassing KYC carried from purchase to distribution.
**Severity:** High

### INV-2: Quote is a single-use, sale-bound, witness-minted hot potato

**Category:** Type-level
**Statement:** `Quote<PaymentCoin>` has no abilities. It can only be produced by
`mint_quote`, which requires a `Curve` witness value (`_w: Curve`), and it pins
`sale_id`. It cannot be copied, stored, replayed across transactions,
transferred, or silently dropped; the sole legal consumer is `purchase` (via the
package-private `unpack`).
**Applies to:** `Quote<PaymentCoin>`, `mint_quote`, `purchase`.
**Enforcement:** Type system (no abilities) + private `Curve` constructor +
`unpack` is module-private.
**Violation scenario:** Without witness-gating, any caller could fabricate an
arbitrary `allocation` for a payment and drain inventory at a self-chosen rate.
**Severity:** Critical

### INV-3: ActivationTicket is a single-use, witness-minted hot potato

**Category:** Type-level
**Statement:** `ActivationTicket<Curve>` has no abilities, pins `sale_id`, and is
minted only via `mint_activation_ticket` (requires `_w: Curve`). It is consumed
(destructured) exactly once inside `share_and_activate`.
**Applies to:** `mint_activation_ticket`, `share_and_activate`, `fixed_rate_curve::activation_ticket`.
**Enforcement:** Type system + witness gate.
**Violation scenario:** A forgeable ticket would let a caller set
`required_inventory = 0`, activating an unbacked sale.
**Severity:** Critical (gated to the curve, see INV-23 for the residual trust)

### INV-4: AllowEntry is a single-use, no-ability compliance ticket

**Category:** Type-level
**Statement:** `AllowEntry<S>` has no abilities. Minted by the compliance module
via `new_entry` (gated by `&AllowlistAdmin<S>`), consumed once by `purchase` via
package-internal `consume`, which asserts `sale_id` and `buyer`. Cannot be stored,
copied, replayed, or transferred.
**Applies to:** `AllowEntry<S>`, `new_entry`, `consume`, `purchase`.
**Enforcement:** Type system + `public(package)` `consume`.
**Violation scenario:** A storable/replayable entry would let one KYC approval be
reused across many purchases or buyers.
**Severity:** High

### INV-5: Capabilities are owned objects bound to exactly one sale/vault

**Category:** Type-level
**Statement:**
- `SaleAdminCap<SaleCoin, PaymentCoin>` (`key + store`) carries `sale_id`; every
  admin path asserts `cap.sale_id == object::id(sale)` (`EWrongAdminCap`).
- `AllowlistAdmin<S>` (`key + store`) carries `sale_id`; exactly one is issued per
  sale (INV-15).
- `RefundVaultCap<P>` (`key + store`) carries `vault_id`; every vault mutation
  asserts `cap.vault_id == object::id(vault)` (`EWrongVaultCap`).
**Applies to:** all admin/cap-gated functions.
**Enforcement:** Type system (unique owned objects) + runtime id-match asserts.
**Violation scenario:** A cap usable across sales would let one issuer's admin
drain another's proceeds.
**Severity:** Critical

### INV-6: Phantom type parameters prevent cross-coin / cross-curve confusion

**Category:** Type-level
**Statement:** `PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>`
and `RefundVault<P>`/`RefundVaultCap<P>` are phantom-typed. A `RefundVault<USDC>`
cannot be paired with a SUI-payment sale; a `Quote`/`ActivationTicket` for one
`Curve` cannot drive a sale of a different `Curve` (the witness type differs).
**Applies to:** `pair_refund_vault`, `mint_quote`, `mint_activation_ticket`, all flows.
**Enforcement:** Type system at compile time.
**Severity:** High

### INV-7: Curve witness gates all pricing and activation authority

**Category:** Type-level
**Statement:** Only the module that declares `Curve` (whose constructor is
module-private) can produce a `Curve` value, and therefore only it can mint a
`Quote` or `ActivationTicket` for a `PrefundedSale<Curve, ...>`. A sale
parameterized by `FixedRateCurve` can be priced by no other logic.
**Applies to:** `mint_quote`, `mint_activation_ticket`, `fixed_rate_curve`.
**Enforcement:** Type system (private witness constructor) + by-value witness param.
**Severity:** Critical
**Note:** This *gates* who computes pricing; it does **not** check the result.
See INV-23.

## Runtime Invariants

### INV-8: Construction parameters are well-formed

**Category:** Runtime
**Statement:** `create_sale` asserts `hard_cap > 0` (`EHardCapZero`),
`soft_cap <= hard_cap` (`EInvalidCapsOrdering`), and
`opens_at_ms < closes_at_ms` (`EInvalidTimeRange`). `fixed_rate_curve::params`
asserts `rate > 0` (`ERateZero`).
**Applies to:** `create_sale`, `fixed_rate_curve::params`.
**Enforcement:** Runtime asserts.
**Severity:** High

### INV-9: Receipt redemption is buyer-only and sale-matched

**Category:** Runtime
**Statement:** `claim`, `claim_into_vesting`, `claim_all*`, and `refund` each
assert `receipt.sale_id() == object::id(sale)` (`EReceiptSaleMismatch`) and
`receipt.buyer() == ctx.sender()` (`EBuyerOnly`).
**Applies to:** `claim`, `claim_all`, `claim_into_vesting`, `claim_all_into_vesting`, `refund`.
**Enforcement:** Runtime asserts in `claim_internal` / `refund`.
**Severity:** Critical

### INV-10: Setup mutators are Init-only and one-shot where applicable

**Category:** Runtime
**Statement:** `deposit`, `set_per_buyer_cap`, `set_vesting_schedule_params`,
`pair_refund_vault`, `enable_allowlist`, and `share_and_activate` all assert
`phase == Init` (`ENotInit`). One-shot guards:
`set_per_buyer_cap` → `EPerBuyerCapAlreadySet` + `per_buyer_cap > 0` (`EPerBuyerCapZero`);
`set_vesting_schedule_params` → `EVestingScheduleAlreadySet`;
`pair_refund_vault` → `EVaultAlreadyPaired`;
`enable_allowlist` → `EAllowlistAlreadyEnabled`.
**Applies to:** all setup functions.
**Enforcement:** Runtime asserts.
**Severity:** High

### INV-11: Vault pairing requires a matching, Active, empty vault

**Category:** Runtime
**Statement:** `pair_refund_vault` asserts `cap.vault_id == object::id(vault)`
(`EWrongVault`), `vault.is_active()` (`EVaultNotActive`), and `vault.value() == 0`
(`EVaultNotEmpty`). The empty requirement prevents stranded pre-existing funds:
the cap is consumed into the sale and `withdraw_all` requires `Closed`
(reachable only via `finalize`).
**Applies to:** `pair_refund_vault`.
**Enforcement:** Runtime asserts.
**Severity:** High

### INV-12: Activation requires a paired vault, live window, and sufficient inventory

**Category:** Runtime
**Statement:** `share_and_activate` asserts the ticket's `sale_id` matches
(`EReceiptSaleMismatch`), `phase == Init`, `refund_vault_cap.is_some()`
(`EVaultRequiredForActivate`), `now < closes_at_ms` (`EActivationAfterClose`),
and `inventory.value() >= ticket.required_inventory`
(`EInsufficientInventoryAtActivate`). Activation before `opens_at_ms` is allowed.
**Applies to:** `share_and_activate`.
**Enforcement:** Runtime asserts.
**Severity:** High
**Note:** `required_inventory` is curve-supplied (INV-23).

### INV-13: Purchase enforces window, caps, allowlist coupling, and inventory backing

**Category:** Runtime
**Statement:** `purchase` asserts, in order: `phase == Active`;
`quote.sale_id == object::id(sale)` (`EQuoteSaleMismatch`);
`opens_at_ms <= now <= closes_at_ms` (`ESaleWindowClosed`);
allowlist presence matches `requires_allowlist`
(`EAllowlistRequired` / `EAllowlistNotRequired`) with entry `sale_id`+`buyer`
matched on consume; `raised + paid` no overflow (`ERaisedOverflow`) and
`<= hard_cap` (`EHardCapExceeded`); per-entry cap `paid <= entry_max` when
`entry_max != 0` (`EPerEntryCapExceeded`); per-buyer cumulative cap with overflow
guard (`EContributionOverflow`, `EPerBuyerCapExceeded`); and
`allocation <= inventory.value() - total_allocated` (`EInsufficientInventory`).
**Applies to:** `purchase`.
**Enforcement:** Runtime asserts (user-controlled arithmetic u128-widened).
**Severity:** Critical

### INV-14: Quote minting rejects zero payment and overflowing allocation

**Category:** Runtime
**Statement:** `mint_quote` asserts `payment.value() > 0` (`EZeroPayment`) and
`paid * rate <= u64::MAX` (`EAllocationOverflow`, computed in u128).
**Applies to:** `mint_quote`, `fixed_rate_curve::quote`.
**Enforcement:** Runtime asserts.
**Severity:** High

### INV-15: Allowlist coupling is symmetric and one-shot

**Category:** Runtime
**Statement:** `enable_allowlist` sets `requires_allowlist = true` and issues
exactly one `AllowlistAdmin<S>` (aborts on second call, `EAllowlistAlreadyEnabled`).
`purchase` requires `allow.is_some() iff requires_allowlist`.
**Applies to:** `enable_allowlist`, `purchase`.
**Enforcement:** Runtime asserts.
**Severity:** High

### INV-16: Close transitions enforce their economic preconditions

**Category:** Runtime
**Statement:**
- `finalize`: `phase == Active`, `(now > closes_at_ms || raised >= hard_cap)`
  (`ESaleWindowStillOpen`), `raised >= soft_cap` (`ESoftCapNotMet`), vault matches.
- `cancel_after_close`: `phase == Active`, `now > closes_at_ms`, `soft_cap > 0 &&
  raised < soft_cap` (`ESoftCapMet`).
- `cancel_emergency`: `cap` matches, `phase == Active`, `now <= closes_at_ms`
  (`EEmergencyCancelAfterClose`), `raised < hard_cap` (`ESaleAlreadyComplete`),
  `soft_cap == 0 || raised < soft_cap` (`ESoftCapMet`).
**Applies to:** `finalize`, `cancel_after_close`, `cancel_emergency`.
**Enforcement:** Runtime asserts.
**Severity:** Critical

### INV-17: Vesting routing is mutually exclusive and schedule-presence-gated

**Category:** Runtime
**Statement:** When `vesting_schedule_params.is_some()`, `claim`/`claim_all` abort
(`EClaimRequiresVesting`) and redemption must go through `claim_into_vesting` /
`claim_all_into_vesting`. When `is_none()`, the vesting paths abort
(`ENoVestingScheduleAttached`). The schedule is issuer-defined at Init; the buyer
(caller) cannot supply or override it — the wallet beneficiary is forced to
`ctx.sender()` (the asserted buyer).
**Applies to:** `claim`, `claim_all`, `claim_into_vesting`, `claim_all_into_vesting`.
**Enforcement:** Runtime asserts + `vesting_wallet::new(..., ctx.sender(), ..)`.
**Severity:** High

### INV-18: Admin withdrawals are cap-gated and phase-gated

**Category:** Runtime
**Statement:** `withdraw_proceeds` asserts `cap` matches and `phase == Finalized`;
`withdraw_unsold_inventory` asserts `cap` matches and `phase` is terminal
(Finalized or Cancelled) and only splits `inventory.value() - total_allocated`.
**Applies to:** `withdraw_proceeds`, `withdraw_unsold_inventory`.
**Enforcement:** Runtime asserts.
**Severity:** Critical

### INV-19: Vault mutations are cap-gated and state-gated

**Category:** Runtime
**Statement:** `deposit` and both `flip_to_*` require `Active`; `release_balance`
requires `Refunding` and `locked >= amount` (`EInsufficientLocked`);
`withdraw_all` requires `Closed`. All require a matching cap.
**Applies to:** `refund_vault` module.
**Enforcement:** Runtime asserts.
**Severity:** Critical

## State Transition Invariants

### INV-20: Phase is monotonic with terminal sinks

**Category:** State transition
**Statement:** Phase transitions are only `Init → Active` (`activate`),
`Active → Finalized` (`finalize`), `Active → Cancelled` (`cancel`). Each asserts
its source state. `Finalized` and `Cancelled` are terminal — no function moves
out of them. `cancel` additionally asserts `!is_cancelled` (`EAlreadyCancelled`).
**Applies to:** `phase` module; every lifecycle transition.
**Enforcement:** Runtime asserts in `phase`.
**Severity:** Critical

### INV-21: Inventory always covers outstanding allocations

**Category:** State transition
**Statement:** `inventory.value() >= total_allocated` holds at every point.
`purchase` increases `total_allocated` only after asserting
`allocation <= inventory - total_allocated`; `claim*`/`refund` decrease
`total_allocated` by exactly the consumed receipt's `allocation` and (claim only)
split that much out of inventory; `withdraw_unsold_inventory` removes only the
`inventory - total_allocated` slack. `total_allocated == Σ allocation` over
outstanding receipts.
**Applies to:** `purchase`, `claim_internal`, `refund`, `withdraw_unsold_inventory`.
**Enforcement:** Runtime asserts + disciplined arithmetic.
**Severity:** Critical

### INV-22: raised tracks proceeds and never exceeds hard_cap

**Category:** State transition
**Statement:** `raised` only increases, by exactly `paid`, inside `purchase`, and
always stays `<= hard_cap`. While `Active`/`Finalized` (pre-withdraw),
`proceeds.value() == raised`. On cancel, `do_cancel` moves the entire `proceeds`
balance into the vault, so post-cancel `vault.locked == raised` and
`proceeds == 0`. `contributions[buyer] == Σ paid` for that buyer (when per-buyer
cap configured).
**Applies to:** `purchase`, `do_cancel`, `withdraw_proceeds`, `refund`.
**Enforcement:** Disciplined arithmetic + balance moves.
**Severity:** Critical

### INV-25: Vault state mirrors the sale's terminal phase; cap never escapes

**Category:** State transition
**Statement:** After activation, `refund_vault_cap.is_some()` and the cap is never
returned out of the sale. `finalize` flips the vault `Active → Closed`;
`do_cancel` flips it `Active → Refunding`. Vault transitions are one-way (INV-19).
A cancelled sale's vault can never reach `Closed`, so `withdraw_all` is
unreachable for it — refunds are the only outflow.
**Applies to:** `share_and_activate`, `finalize`, `do_cancel`.
**Enforcement:** Type (cap wrapped in `Option`, never read out) + runtime state asserts.
**Severity:** Critical

## Economic / Protocol Invariants

### INV-23: The pricing curve is a trusted component (no independent rate bound)

**Category:** Economic
**Status:** Intentional design decision (dev-confirmed 2026-06-25).
**Statement:** The sale accepts the curve's `allocation` (from the quote) and
`required_inventory` (from the activation ticket) **without re-deriving or
bounding them against any sale-held rate**. There is no `max_rate` field and no
`allocation <= paid * max_rate` check (the doc comments describing one are stale
— see Dev Notes). The only independent protections are: INV-21
(`allocation <= unallocated inventory`) and the u128 overflow guards (INV-14).
Correct per-payment pricing and correct inventory sizing are therefore — **by
design** — assumptions delegated to the witness-gated curve module (INV-7), not
enforced invariants. The witness gate (only the declaring curve module can mint a
quote/ticket for its sale type) is the security boundary that makes this safe:
the curve is first-party trusted code, audited alongside the sale.
**Applies to:** `purchase`, `share_and_activate`, `mint_quote`, `mint_activation_ticket`.
**Enforcement:** Witness gate only (INV-7); result unchecked by the sale.
**Violation scenario:** A buggy/dishonest curve over-allocates per payment up to
the inventory ceiling, exhausting inventory faster than `raised` approaches
`hard_cap` (sold-out before hard-cap). No value is created beyond inventory, and
no payment is taken without an atomic allocation, but the "sold-out ⇔
hard-cap-reached" guarantee holds only if the curve sizes `required_inventory`
honestly.
**Severity:** Critical (central trust boundary — intentional per design)

### INV-24: Conservation — no value in or out beyond receipts and routed balances

**Category:** Economic
**Statement:**
- Each `claim` returns exactly `receipt.allocation` of `SaleCoin` out of inventory.
- Each `refund` returns exactly `receipt.paid` of `PaymentCoin` out of the vault.
- `withdraw_proceeds` returns exactly `raised` (the accumulated proceeds) on success.
- `withdraw_unsold_inventory` returns only unallocated inventory.
The sale never mints or burns either coin; it only routes deposited balances.
**Applies to:** `claim_internal`, `refund`, `withdraw_proceeds`, `withdraw_unsold_inventory`.
**Enforcement:** Balance arithmetic + INV-21/INV-22.
**Severity:** Critical

### INV-26: Refund solvency — the vault always covers outstanding refunds

**Category:** Economic
**Statement:** On cancel, `vault.locked == raised == Σ paid` over all receipts
ever issued. Each `refund` releases exactly `paid` and removes that receipt, so at
all times `vault.locked >= Σ paid` over *unrefunded* receipts. Every buyer can
always recover exactly their payment regardless of order or admin liveness.
**Applies to:** `do_cancel`, `refund`.
**Enforcement:** INV-22 + `release_balance` `locked >= amount` assert.
**Severity:** Critical

### INV-27: Buyer redemption does not depend on admin liveness

**Category:** Economic
**Statement:** `purchase`, `claim*`, `refund`, `finalize`, and
`cancel_after_close` are permissionless. Losing the `SaleAdminCap` cannot strand
buyer funds — buyers still claim (after permissionless `finalize`) or refund
(after permissionless `cancel_after_close`). Admin loss only forfeits
`cancel_emergency`, `withdraw_proceeds`, and `withdraw_unsold_inventory`.
**Applies to:** all permissionless paths.
**Enforcement:** Function visibility + INV-16.
**Severity:** High

### INV-28: Admin cannot rug a goal-reaching sale

**Category:** Economic
**Statement:** `cancel_emergency` is blocked once `raised >= hard_cap`
(`ESaleAlreadyComplete`) and, when a soft cap exists, once `raised >= soft_cap`
(`ESoftCapMet`). A sale that has met its goal can only `finalize`; admin cannot
force refunds to claw value back from a successful raise. Emergency cancel is also
window-bounded (`now <= closes_at_ms`).
**Applies to:** `cancel_emergency`.
**Enforcement:** Runtime asserts.
**Severity:** Critical

### INV-29: Proceeds are released to admin only on success, to refunds only on failure

**Category:** Economic
**Statement:** `proceeds` leave the sale through exactly one of two mutually
exclusive terminal paths: `withdraw_proceeds` (Finalized only) or `do_cancel` →
vault → `refund` (Cancelled only). Phase monotonicity (INV-20) makes these
exclusive — a sale is never both Finalized and Cancelled.
**Applies to:** `withdraw_proceeds`, `do_cancel`, `refund`.
**Enforcement:** Phase gating + INV-20.
**Severity:** Critical

## Composability Invariants

### INV-30: quote + purchase compose in a single PTB

**Category:** Composability
**Statement:** Because `Quote` is a no-ability hot potato bound to `sale_id`, the
buyer must mint it (via the curve's `quote`) and consume it (via `purchase`) in
the same transaction. No intermediate publishing or storage is possible.
**Applies to:** `mint_quote`/`fixed_rate_curve::quote`, `purchase`.
**Severity:** Medium

### INV-31: compliance mint + purchase compose in a single PTB

**Category:** Composability
**Statement:** `AllowEntry<S>` (no abilities) forces the compliance module's
`new_entry` and the sale's `purchase` into one PTB; entries cannot be pre-minted
and warehoused.
**Applies to:** `new_entry`, `purchase`.
**Severity:** Medium

### INV-32: claim_into_vesting composes with the finance vesting wallet

**Category:** Composability
**Statement:** `claim_into_vesting` returns a `VestingWallet<Witness,
VestingScheduleParams, SaleCoin>` directly (not a `VestedAllocation` hot potato —
the doc comment is stale), with `beneficiary == ctx.sender()` and the sale's
fixed schedule params, funded with exactly the claimed allocation.
**Applies to:** `claim_into_vesting`, `claim_all_into_vesting`.
**Severity:** Medium

### INV-33: The sale is a shared object that tolerates concurrent, non-exclusive callers

**Category:** Composability
**Statement:** After `share_and_activate` the sale is shared; it makes no
assumption of being the sole caller in a transaction. The refund vault is a
standalone primitive usable outside the sale, but once paired its cap is owned by
the sale and only sale-gated paths drive it.
**Applies to:** whole module.
**Severity:** Medium

## Existing Invariants (Extension Mode)

This is an extraction from already-written code, so every invariant above is
"preserved" in the sense that it is currently enforced by the source as written.
No prior invariants artifact existed (the previous `artifacts/invariants.md` was
emptied in commit `cb75fb0`). There are no *modified* or *new* invariants relative
to a baseline — this document establishes the baseline.

## Invariant Coverage Matrix

| Function | Invariants | Enforcement |
|---|---|---|
| `create_sale` | INV-8 | Runtime |
| `deposit` | INV-10, INV-21 | Runtime |
| `set_per_buyer_cap` | INV-10 | Runtime |
| `set_vesting_schedule_params` | INV-10, INV-17 | Runtime |
| `pair_refund_vault` | INV-5, INV-6, INV-10, INV-11 | Type + Runtime |
| `enable_allowlist` | INV-5, INV-10, INV-15 | Type + Runtime |
| `mint_activation_ticket` | INV-3, INV-7 | Type |
| `share_and_activate` | INV-3, INV-12, INV-20, INV-23, INV-25 | Type + Runtime |
| `mint_quote` | INV-2, INV-7, INV-14, INV-23 | Type + Runtime |
| `purchase` | INV-1, INV-2, INV-4, INV-13, INV-15, INV-21, INV-22, INV-23, INV-30, INV-31 | Type + Runtime |
| `finalize` | INV-5, INV-16, INV-20, INV-25, INV-29 | Runtime |
| `cancel_after_close` | INV-16, INV-20, INV-22, INV-25, INV-26 | Runtime |
| `cancel_emergency` | INV-5, INV-16, INV-20, INV-25, INV-26, INV-28 | Runtime |
| `claim` / `claim_all` | INV-1, INV-9, INV-17, INV-20, INV-21, INV-24 | Type + Runtime |
| `claim_into_vesting` / `claim_all_into_vesting` | INV-1, INV-9, INV-17, INV-24, INV-32 | Type + Runtime |
| `withdraw_proceeds` | INV-5, INV-18, INV-24, INV-29 | Runtime |
| `withdraw_unsold_inventory` | INV-5, INV-18, INV-21, INV-24 | Runtime |
| `refund` | INV-1, INV-9, INV-21, INV-22, INV-24, INV-26 | Type + Runtime |
| `refund_vault::*` | INV-5, INV-19, INV-25, INV-26 | Type + Runtime |
| `allowlist::new_entry` / `consume` | INV-4, INV-15, INV-31 | Type + Runtime |
| views (`phase`, `raised`, …) | — (read-only) | — |

## Out of Scope

- **Curve correctness verification** — delegated to each curve module's own
  invariants (witness-gated trust boundary; see INV-23). The sale enforces only
  inventory bounding and overflow safety.
- **Vesting release schedule math** — delegated to `openzeppelin_finance::vesting_wallet`;
  the sale only forces beneficiary and supplies fixed params (INV-17/INV-32).
- **Compliance/KYC logic** — `allowlist` is a typed slot only; the verification
  scheme is the integrator's (INV-4).
- **Cap-recovery / RBAC for `SaleAdminCap` and `AllowlistAdmin`** — losing a cap is
  an integrator concern; no library override by design (INV-27 documents the
  blast radius).
- **Stale-receipt sweeping / grace periods** — intentionally absent; unclaimed
  receipts pin inventory (Finalized) or vault funds (Cancelled) indefinitely,
  buyer-protective by design.
- **`MintingSale` (v2) flavor** — not in this branch; out of scope here.

## Dev Notes

- **Code-vs-doc drift (code is law, per dev instruction).** Two confirmed stale
  docs that affect the invariants:
  1. The `max_rate` defensive bound (`create_sale` doc "asserts `max_rate > 0`";
     `purchase` doc "accepted only up to `paid * max_rate`"; the `Quote` section
     "asserts `quote.allocation <= quote.paid * sale.max_rate`") **does not exist**
     in code. There is no `max_rate` field, parameter, or assert. → INV-23.
     **Dev confirmed the absence is intentional (curve is trusted), so the
     purchase-time-bound claims are wrong and should be deleted** at the
     code-comment / docs stage. Flatly false: `create_sale` "asserts `max_rate > 0`"
     (lines 414–422; `create_sale` has no such param) and the `paid * max_rate`
     purchase bound (lines 700–711, 1357–1359). Conceptually OK but should name the
     curve as the source: the *activation backing* references
     `inventory >= hard_cap * max_rate` (lines 62, 181, 653) — real, but
     `required_inventory` is curve-supplied, not derived from a sale field.
  2. `claim_into_vesting` returns `VestingWallet` directly; the `VestedAllocation`
     hot-potato described at lines 986–996 no longer exists. → INV-32.
- The `EReceiptSaleMismatch` (code 60) error is reused for the `ActivationTicket`
  sale-id check in `share_and_activate` (line 674) even though a dedicated
  `ETicketSaleMismatch` (code 62) exists. Cosmetic; flagged for the code/review stage.

## Open Questions

1. ~~Is the curve-trust boundary (INV-23) intentional?~~ **Resolved
   (2026-06-25): intentional.** The curve is a trusted, witness-gated component;
   the sale enforces only inventory bounding (INV-21) and overflow safety
   (INV-14). The stale `max_rate` docs should be corrected at the code-comment /
   docs stage (see Dev Notes) — no step-back to Design needed.
2. Should `share_and_activate` reuse the dedicated `ETicketSaleMismatch` instead of
   `EReceiptSaleMismatch`? (Pure error-code hygiene; defer to code/review stage.)
3. **Per-buyer cap state growth:** for a sale that called `set_per_buyer_cap`, the
   `contributions: Table<address, u64>` grows one entry per distinct buyer with no
   eviction. Is unbounded growth an accepted state-size cost? (Uncapped sales leave
   the table `None` and are unaffected.) — *awaiting dev call.*

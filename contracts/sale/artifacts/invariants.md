---
stage: invariants
project: openzeppelin-sale
mode: extension
extends: contracts/sale/sources
status: draft
revision: 1
timestamp: 2026-06-25
author: nenad
previous_stage: contracts/sale/proposal.md
tags: [sale, presale, fixed-price, prefunded, vesting, refund-vault, allowlist, hot-potato]
---

# openzeppelin_sale — Invariants

## Summary

Invariants for the `openzeppelin_sale` library, extracted from the implemented
sources (the authority) and cross-checked against `proposal.md`. They are organized
into the five standard categories: type-level (ability/witness-enforced), runtime
(`assert!`-enforced), state-transition (relationships that hold across calls),
economic/protocol (business guarantees), and composability (PTB / shared-object
behavior). The load-bearing properties are **inventory backing**
(`inventory >= total_allocated` in every phase), **value conservation** (every claim
pays exactly its allocation, every refund pays exactly its payment, refunds are always
solvent), **non-bypassable vesting**, **bounded admin power** (no rug of a successful
sale), and the **hot-potato carriers** (`Quote`, `AllowEntry`, `VestedAllocation`,
`ActivationTicket`) that force single-PTB composition and gate who can price, gate,
and redeem.

> **Note on drift from `proposal.md`.** The code has evolved past the proposal's §5
> inline summary. The sale is now generic over a pricing `Curve` / `CurveParams`, the
> payment flows in via a witness-gated `Quote<PaymentCoin>` hot-potato, activation is
> gated by an `ActivationTicket<Curve>` carrying a curve-computed `required_inventory`,
> and the vesting schedule is a generic `VestingScheduleParams`. Several docstrings
> still reference a stored `max_rate` and a `purchase`-time `allocation <= paid * max_rate`
> check that **no longer exist in the code** — see INV-41 (the one real enforcement gap).

## Type-Level Invariants

### INV-1: Receipt non-transferability and buyer-binding (type level)

**Category:** Type-level

**Statement:** `Receipt<S>` has `key` only (no `store`, `copy`, `drop`). It cannot be
`public_transfer`'d, cannot be a field of another struct, cannot be copied or silently
dropped. The only transfer path is `receipt::deliver` (`public(package)`), called by a
sale flavor at purchase to send the receipt to the buyer. Construction (`new_receipt`)
and destruction (`consume`) are `public(package)`.

**Applies to:** `Receipt<S>`; `purchase`, `claim`, `claim_all`, `claim_into_vesting`, `refund`.

**Enforcement mechanism:**
- Type system: `key`-only ability set; `public(package)` constructor/consumer/deliver.
- Runtime check: redemption paths *additionally* assert `ctx.sender() == receipt.buyer` (see INV-22) — the type guarantees the receipt can't leave the buyer, the assert guarantees a third party can't redeem even under shared custody.
- Test: attempt `public_transfer` of a receipt (must not compile); attempt redemption from a non-buyer sender (must abort `EBuyerOnly`).

**Violation scenario:** If `Receipt<S>` had `store`, a buyer could sell their unredeemed
allocation/refund to an unverified third party, defeating KYC-at-purchase carry-through.

**Severity:** Critical

### INV-2: Quote is a witness-gated, single-use, sale-bound hot-potato

**Category:** Type-level

**Statement:** `Quote<PaymentCoin>` has **no abilities**. It can only be minted by
`prefunded_sale::mint_quote`, which takes the curve witness `_w: Curve` by value; since
a curve's witness constructor is module-private, only the module that declares `Curve`
can mint a `Quote` for a `PrefundedSale<Curve, ...>`. The quote *carries the payment
balance itself* (`payment: Balance<PaymentCoin>`) and an `allocation`, and pins
`sale_id`. The only consumer is `purchase` (via the module-private `unpack`).

**Applies to:** `Quote<PaymentCoin>`; `mint_quote`, `purchase`, every `Curve` module
(e.g. `fixed_rate_curve::quote`).

**Enforcement mechanism:**
- Type system: no abilities ⇒ no store/copy/replay/transfer/drop; witness-by-value gate on minting; module-private `unpack`.
- Runtime check: `purchase` asserts `quote.sale_id == object::id(sale)` (`EQuoteSaleMismatch`); because the payment lives inside the quote, `paid == payment.value()` holds structurally (no separate field to drift).
- Test: a quote minted for sale A spent on sale B aborts; a quote cannot be stored across PTBs (won't compile).

**Violation scenario:** If `Quote` had `store`/`copy`, a buyer could replay one priced
quote across many purchases, or mint a quote without curve cooperation, breaking pricing.

**Severity:** Critical

### INV-3: AllowEntry is a single-use, sale- and buyer-bound hot-potato

**Category:** Type-level

**Statement:** `AllowEntry<S>` has **no abilities**. It is minted only by the holder of an
`AllowlistAdmin<S>` via `allowlist::new_entry`, and consumed only by `purchase` via the
`public(package)` `consume`, which asserts the entry's `sale_id` and `buyer`.

**Applies to:** `AllowEntry<S>`, `AllowlistAdmin<S>`; `enable_allowlist`, `new_entry`,
`purchase`.

**Enforcement mechanism:**
- Type system: no abilities ⇒ must be minted and consumed in the same PTB; `consume` is `public(package)`.
- Runtime check: `consume` asserts `sale_id == expected_sale_id` (`EWrongSaleId`) and `buyer == expected_buyer` (`EWrongBuyer`); `purchase` asserts presence iff `requires_allowlist` (INV-16).
- Test: entry minted for buyer X used by sender Y aborts; entry for sale A used on sale B aborts.

**Violation scenario:** If `AllowEntry` had `store`, a compliance ticket could be stockpiled
or resold, decoupling KYC verification from the actual purchaser.

**Severity:** Critical

### INV-4: VestedAllocation is a library-only hot-potato

**Category:** Type-level

**Statement:** `VestedAllocation<S, P>` has **no abilities** and **module-private fields**.
It can only be constructed by `vested_allocation::new` (`public(package)`) — reached solely
from `prefunded_sale::claim_into_vesting` — and unpacked by `unpack_vested_allocation`
(`public(package)`) — reached solely from `vested_claim::into_*`. The buyer who holds it
mid-PTB cannot stash it, drop it, transfer it, or extract the inner `Balance<S>`.

**Applies to:** `VestedAllocation<S, P>`; `claim_into_vesting`, `vested_claim::into_shared_wallet`,
`vested_claim::into_owned_wallet`.

**Enforcement mechanism:**
- Type system: no abilities + private fields + `public(package)` ctor/unpacker.
- Test: attempting to extract the coin or drop the allocation outside `vested_claim` must not compile.

**Violation scenario:** If a buyer could unpack `VestedAllocation`, they would obtain an
immediate `Coin<S>` on a vested sale, fully bypassing the schedule (see INV-40).

**Severity:** Critical

### INV-5: Curve witness binds a sale to exactly one pricing module

**Category:** Type-level

**Statement:** A `PrefundedSale<Curve, CurveParams, ...>` can be priced only by the module
that declares `Curve` (the field-less, `drop`-only witness whose constructor is module-private).
`mint_quote` and `mint_activation_ticket` both require the witness by value. No external
module can produce quotes or activation tickets for a sale parameterized by a curve it
does not own.

**Applies to:** every `Curve` type; `mint_quote`, `mint_activation_ticket`, `purchase`,
`share_and_activate`.

**Enforcement mechanism:**
- Type system: witness-by-value + module-private witness constructor.
- Test: a foreign module cannot construct `FixedRateCurve {}` (won't compile), so cannot mint a quote.

**Violation scenario:** If any module could mint a quote, arbitrary pricing (and arbitrary
allocation up to inventory) could be forced on the sale.

**Severity:** High

### INV-6: Typed capabilities prevent coin/sale/vault confusion

**Category:** Type-level

**Statement:** `SaleAdminCap<SaleCoin, PaymentCoin>`, `AllowlistAdmin<S>`, and
`RefundVaultCap<P>` are phantom-typed; a cap for one coin/sale/vault is type-incompatible
with another. `RefundVaultCap<P>` has `store` but is *wrapped into the sale* at
`pair_refund_vault` and never returned, so after pairing only the sale's gated functions
drive the vault.

**Applies to:** all three capability types; admin and vault operations.

**Enforcement mechanism:**
- Type system: phantom type parameters; cap consumed-into-sale at pairing.
- Runtime check: each op also asserts the cap's recorded id matches the target (INV-26).
- Test: pairing a `RefundVaultCap<USDC>` against a SUI-payment sale must not compile.

**Violation scenario:** Without typing, an admin cap from sale A could drive sale B, or a
USDC vault could back a SUI sale, stranding/mismatching funds.

**Severity:** High

### INV-7: ActivationTicket is a witness-gated activation hot-potato

**Category:** Type-level

**Statement:** `ActivationTicket<Curve>` has **no abilities**. It is minted by
`mint_activation_ticket` (witness-gated) — in practice from the curve module's
`activation_ticket`, which computes `required_inventory` from the curve params — and
consumed by `share_and_activate`, which pins `sale_id` and enforces the inventory cover.

**Applies to:** `ActivationTicket<Curve>`; `mint_activation_ticket`, `share_and_activate`,
`fixed_rate_curve::activation_ticket`.

**Enforcement mechanism:**
- Type system: no abilities; witness-gated mint.
- Runtime check: `share_and_activate` asserts `sale_id == ticket.sale_id` and `inventory >= required_inventory`.
- Test: activating with a ticket from a different sale aborts; activating with `inventory < required_inventory` aborts.

**Violation scenario:** Without the ticket, a sale could be activated with inventory that
does not cover `hard_cap`-worth of allocation, breaking the "sold-out coincides with
hard-cap" guarantee for honest curves.

**Severity:** High

### INV-8: Sale-coin / payment-coin separation by type

**Category:** Type-level

**Statement:** `inventory: Balance<SaleCoin>` and `proceeds: Balance<PaymentCoin>` are
distinct types on the sale; the type system makes it impossible to pay out inventory as a
refund or refund payment as inventory.

**Applies to:** `PrefundedSale`; `purchase`, `claim`, `refund`, withdrawals.

**Enforcement mechanism:** Type system (generic `Balance<T>`).

**Violation scenario:** Mixing the two balances would let a refund drain sale tokens or a
claim drain payment proceeds.

**Severity:** High

## Runtime Invariants

### INV-9: All setup mutations are Init-phase gated

**Category:** Runtime

**Statement:** `deposit`, `set_per_buyer_cap`, `set_vesting_schedule_params`,
`pair_refund_vault`, `enable_allowlist`, and `share_and_activate` all assert
`phase == Init`. After activation, no setup can run.

**Applies to:** the six functions above.

**Enforcement:** `sale.phase.assert_init()` (`ENotInit`) at the top of each.

**Violation scenario:** Post-activation reconfiguration (e.g. lowering inventory backing,
changing vesting after purchases) would corrupt outstanding receipts' guarantees.

**Severity:** Critical

### INV-10: One-shot setup operations

**Category:** Runtime

**Statement:** Per-buyer cap, vesting schedule, vault pairing, and allowlist are each
settable at most once.

**Applies to:** `set_per_buyer_cap` (`EPerBuyerCapAlreadySet`), `set_vesting_schedule_params`
(`EVestingScheduleAlreadySet`), `pair_refund_vault` (`EVaultAlreadyPaired`),
`enable_allowlist` (`EAllowlistAlreadyEnabled`).

**Enforcement:** `assert!(option.is_none(), ...)` / `assert!(!requires_allowlist, ...)`.

**Violation scenario:** A second `enable_allowlist` would issue a duplicate
`AllowlistAdmin`, letting two compliance modules independently mint entries and defeating
the gate; a second vault pairing would orphan the first vault's cap.

**Severity:** High

### INV-11: Well-formed caps and time window at creation

**Category:** Runtime

**Statement:** `hard_cap > 0`, `soft_cap <= hard_cap`, `opens_at_ms < closes_at_ms` at
`create_sale`. `per_buyer_cap > 0` if configured.

**Applies to:** `create_sale` (`EHardCapZero`, `EInvalidCapsOrdering`, `EInvalidTimeRange`),
`set_per_buyer_cap` (`EPerBuyerCapZero`).

**Enforcement:** asserts in the respective functions.

**Violation scenario:** `hard_cap == 0` makes every purchase abort; `soft_cap > hard_cap`
makes a successful close impossible; `per_buyer_cap == 0` blocks every buyer.

**Severity:** High

### INV-12: Activation preconditions

**Category:** Runtime

**Statement:** `share_and_activate` requires: a paired refund vault
(`refund_vault_cap.is_some()`), `now < closes_at_ms`, and
`inventory >= required_inventory` (the curve-computed cover).

**Applies to:** `share_and_activate` (`EVaultRequiredForActivate`, `EActivationAfterClose`,
`EInsufficientInventoryAtActivate`).

**Enforcement:** asserts in `share_and_activate`.

**Violation scenario:** Activating a vault-less sale leaves `cancel_emergency`/refunds with
no destination; activating after `closes_at_ms` shares a sale with no purchase window;
activating under-funded breaks inventory backing for honest curves.

**Severity:** Critical

### INV-13: Purchase phase and time-window gating

**Category:** Runtime

**Statement:** `purchase` requires `phase == Active` and `opens_at_ms <= now <= closes_at_ms`.

**Applies to:** `purchase` (`ENotActive`, `ESaleWindowClosed`).

**Enforcement:** `assert_active()` + window assert.

**Severity:** High

### INV-14: Hard-cap enforcement on purchase (overflow-safe)

**Category:** Runtime

**Statement:** `raised + paid <= hard_cap`, with `raised + paid` overflow-checked against
`u64::MAX` before the comparison.

**Applies to:** `purchase` (`ERaisedOverflow`, `EHardCapExceeded`).

**Enforcement:** `assert!(u64_max - paid >= raised)` then `assert!(new_raised <= hard_cap)`.

**Violation scenario:** Over-raising past `hard_cap`, or an overflow wrapping `raised`.

**Severity:** Critical

### INV-15: Per-buyer (cumulative) and per-entry (single-purchase) caps

**Category:** Runtime

**Statement:** If a per-buyer cap is set, the running sum `contributions[buyer] + paid`
must not exceed it (overflow-checked). If an `AllowEntry` carries `max_amount > 0`, the
single purchase's `paid` must not exceed it.

**Applies to:** `purchase` (`EContributionOverflow`, `EPerBuyerCapExceeded`,
`EPerEntryCapExceeded`).

**Enforcement:** asserts + `contributions` table update.

**Violation scenario:** A whale exceeding the anti-whale cap; an entry-scoped limit
silently ignored.

**Severity:** High

### INV-16: Allowlist presence coupling

**Category:** Runtime

**Statement:** `allow` must be `Some` iff `requires_allowlist == true`; the entry is then
consumed and asserted against this sale and this buyer. If allowlist is off, an entry must
not be supplied.

**Applies to:** `purchase` (`EAllowlistRequired`, `EAllowlistNotRequired`, + INV-3 asserts).

**Enforcement:** branch on `requires_allowlist` with both `is_some`/`is_none` asserts.

**Severity:** High

### INV-17: Inventory backing on purchase

**Category:** Runtime

**Statement:** A purchase's `allocation` must not exceed currently unallocated inventory:
`allocation <= inventory.value() - total_allocated`. (Note: enforced with the misnamed
`EInsufficientInventoryAtActivate` code — see Dev Notes.)

**Applies to:** `purchase`.

**Enforcement:** `assert!(allocation <= unallocated, ...)` then `total_allocated += allocation`.

**Violation scenario:** Promising allocation the inventory cannot back — would make a later
claim fail or let allocations exceed inventory. This assert is what *maintains* INV-28.

**Severity:** Critical

### INV-18: Quote minting validity

**Category:** Runtime

**Statement:** `mint_quote` asserts `payment.value() > 0` and that
`payment.value() * rate` does not overflow `u64` (`u128`-widened).

**Applies to:** `mint_quote` (`EZeroPayment`, `EAllocationOverflow`); curve `quote` sugar.

**Enforcement:** asserts in `mint_quote`.

**Severity:** High

### INV-19: Finalize preconditions

**Category:** Runtime

**Statement:** `finalize` requires `phase == Active`, (`now > closes_at_ms` OR
`raised >= hard_cap`), `raised >= soft_cap`, and the supplied vault is the paired vault.

**Applies to:** `finalize` (`ENotActive`, `ESaleWindowStillOpen`, `ESoftCapNotMet`,
`EWrongVault`).

**Enforcement:** asserts in `finalize`; also flips the vault to `Closed`.

**Violation scenario:** Finalizing a still-open under-cap sale, or one below soft cap,
would lock buyers out of refunds.

**Severity:** Critical

### INV-20: cancel_after_close preconditions (permissionless soft-cap miss)

**Category:** Runtime

**Statement:** Requires `phase == Active`, `now > closes_at_ms`, `soft_cap > 0`, and
`raised < soft_cap`, with the paired vault. Drains proceeds to vault, flips vault to
`Refunding`.

**Applies to:** `cancel_after_close` (`ENotActive`, `ESaleWindowStillOpen`, `ESoftCapMet`,
`EWrongVault`).

**Enforcement:** asserts + `do_cancel`.

**Severity:** High

### INV-21: cancel_emergency preconditions (bounded admin power)

**Category:** Runtime

**Statement:** Requires a matching `SaleAdminCap`, `phase == Active`, in-window
(`now <= closes_at_ms`), `raised < hard_cap`, and (`soft_cap == 0` OR `raised < soft_cap`).
A sale that has reached its hard cap or met its soft cap **cannot** be emergency-cancelled.

**Applies to:** `cancel_emergency` (`EWrongAdminCap`, `ENotActive`,
`EEmergencyCancelAfterClose`, `ESaleAlreadyComplete`, `ESoftCapMet`).

**Enforcement:** asserts + `do_cancel`. (Economic consequence in INV-38.)

**Severity:** Critical

### INV-22: Redemption is sale-bound and buyer-bound

**Category:** Runtime

**Statement:** `claim`, `claim_into_vesting`, and `refund` each assert
`receipt.sale_id == object::id(sale)` and `receipt.buyer == ctx.sender()`.

**Applies to:** `claim`, `claim_all`, `claim_into_vesting`, `refund`
(`EReceiptSaleMismatch`, `EBuyerOnly`).

**Enforcement:** asserts before consuming the receipt.

**Violation scenario:** Redeeming a receipt against the wrong sale, or a third party
redeeming someone's receipt.

**Severity:** Critical

### INV-23: Claim phase and vesting routing

**Category:** Runtime

**Statement:** `claim`/`claim_all` require `phase == Finalized` and
`vesting_schedule_params.is_none()`. `claim_into_vesting` requires `phase == Finalized` and
`vesting_schedule_params.is_some()`. The two redemption routes are mutually exclusive by
vesting configuration.

**Applies to:** `claim`, `claim_all`, `claim_into_vesting` (`ENotFinalized`,
`EClaimRequiresVesting`, `ENoVestingScheduleAttached`).

**Enforcement:** phase + option asserts. (This is the runtime half of INV-40.)

**Severity:** Critical

### INV-24: Refund phase gating

**Category:** Runtime

**Statement:** `refund` requires `phase == Cancelled` and the paired vault.

**Applies to:** `refund` (`ENotCancelled`, `EWrongVault`).

**Enforcement:** asserts.

**Severity:** High

### INV-25: Admin withdrawals are phase- and cap-gated and never touch backed funds

**Category:** Runtime

**Statement:** `withdraw_proceeds` requires `phase == Finalized` + matching cap.
`withdraw_unsold_inventory` requires a terminal phase (`Finalized` or `Cancelled`) +
matching cap, and releases strictly `inventory - total_allocated` (the unallocated
remainder), never funds backing outstanding receipts.

**Applies to:** `withdraw_proceeds`, `withdraw_unsold_inventory` (`EWrongAdminCap`,
`ENotFinalized`, `ENotTerminal`).

**Enforcement:** asserts + `split(inventory - total_allocated)`.

**Violation scenario:** Admin draining inventory that backs unclaimed receipts, or
proceeds before finalize.

**Severity:** Critical

### INV-26: Capability authenticity at the call site

**Category:** Runtime

**Statement:** Every admin op asserts `cap.sale_id == object::id(sale)`; every vault op
asserts `cap.vault_id == object::id(vault)`; sale↔vault ops assert
`object::id(vault) == refund_vault_id`.

**Applies to:** `cancel_emergency`, `withdraw_proceeds`, `withdraw_unsold_inventory`
(`EWrongAdminCap`); all `refund_vault` cap-gated fns (`EWrongVaultCap`); `finalize`,
`cancel_*`, `refund` (`EWrongVault`).

**Enforcement:** id-equality asserts.

**Severity:** Critical

### INV-27: Refund-vault state machine gating

**Category:** Runtime

**Statement:** `deposit` requires `Active`; `flip_to_refunding`/`flip_to_closed` require
`Active` (so transitions originate only from `Active`); `release_balance` requires
`Refunding` and `locked >= amount`; `withdraw_all` requires `Closed`.

**Applies to:** `refund_vault::{deposit, flip_to_refunding, flip_to_closed, release_balance,
withdraw_all}` (`ENotActiveState`, `ENotRefundingState`, `ENotClosedState`,
`EInsufficientLocked`).

**Enforcement:** state asserts.

**Severity:** High

## State Transition Invariants

### INV-28: Inventory backing (master accounting invariant)

**Category:** State transition

**Statement:** `inventory.value() >= total_allocated` holds after every transaction, in
every phase. Established at activation (INV-12), preserved by `purchase` (checks
`allocation <= inventory - total_allocated`, then adds to both sides bound), and preserved
by `claim`/`claim_into_vesting`/`refund` (each does `total_allocated -= allocation`, and
claim paths also `inventory.split(allocation)`, keeping the gap non-negative).

**Applies to:** every state-mutating function.

**Enforcement:** the combination of INV-12, INV-17, and the symmetric decrements on
redemption. No single assert; an emergent invariant.

**Violation scenario:** If it ever broke, an outstanding receipt could fail to claim its
promised tokens — direct loss to a buyer.

**Severity:** Critical

### INV-29: total_allocated equals the sum of outstanding receipts' allocations

**Category:** State transition

**Statement:** `total_allocated == Σ allocation(r)` over all live `Receipt<S>` for this
sale. `purchase` increments it by exactly the new receipt's allocation;
`claim`/`claim_into_vesting`/`refund` decrement it by exactly the consumed receipt's
allocation.

**Applies to:** `purchase`, `claim`, `claim_all`, `claim_into_vesting`, `refund`.

**Enforcement:** paired `+= allocation` / `-= allocation` with receipt mint/consume.

**Severity:** Critical

### INV-30: `raised` is monotonic, equals total payments, and is hard-capped

**Category:** State transition

**Statement:** `raised` only ever increases (only `purchase` writes it), equals the sum of
all accepted payments, and satisfies `raised <= hard_cap` at all times.

**Applies to:** `purchase`; read by `finalize`, `cancel_*`.

**Enforcement:** INV-14 assert; no decrement path.

**Severity:** High

### INV-31: Sale phase is monotonic with terminal end-states

**Category:** State transition

**Statement:** Phase transitions are `Init → Active → {Finalized | Cancelled}` only.
`Finalized` and `Cancelled` are terminal (no transition out). `activate` asserts `Init`,
`finalize` asserts `Active`, `cancel` asserts not-already-`Cancelled` (and `do_cancel` is
only reachable from `Active`).

**Applies to:** `phase` module; `share_and_activate`, `finalize`, `cancel_*`.

**Enforcement:** `public(package)` transition fns each assert the source phase.

**Violation scenario:** Re-finalizing, re-cancelling, or reviving a terminal sale would
double-spend inventory or proceeds.

**Severity:** Critical

### INV-32: Refund-vault state is monotonic one-way

**Category:** State transition

**Statement:** Vault transitions are `Active → Refunding` or `Active → Closed` only; both
target states are terminal. A vault never returns to `Active`, and `Refunding`/`Closed` are
mutually exclusive outcomes.

**Applies to:** `refund_vault`; driven by sale `finalize`/`cancel_*`.

**Enforcement:** flips assert `Active` as the source.

**Severity:** High

### INV-33: Sale ↔ vault lifecycle synchronization

**Category:** State transition

**Statement:** A successful close drives the vault to `Closed` in the same call
(`finalize` → `flip_to_closed`); a cancellation drains all sale proceeds into the vault and
drives it to `Refunding` (`do_cancel` → `deposit` + `flip_to_refunding`). The vault's
terminal state always matches the sale's terminal phase.

**Applies to:** `finalize`, `cancel_after_close`, `cancel_emergency`.

**Enforcement:** the cap (wrapped in the sale) is used to flip the paired vault inside the
same function.

**Violation scenario:** A `Cancelled` sale with an `Active` (or unfunded) vault would leave
buyers unable to refund; a `Finalized` sale with a `Refunding` vault would be incoherent.

**Severity:** Critical

### INV-34: Proceeds conservation

**Category:** State transition

**Statement:** During `Active`, `proceeds == Σ paid` (every payment joins proceeds, nothing
leaves — `withdraw_proceeds` requires `Finalized`). On cancel, the *entire* proceeds balance
is moved into the vault (`split(value)` then `deposit`), leaving `proceeds == 0`. On
finalize, proceeds stay in the sale until the admin withdraws them.

**Applies to:** `purchase`, `do_cancel`, `withdraw_proceeds`.

**Enforcement:** balance joins/splits; phase gating on withdrawal.

**Severity:** High

### INV-35: Refund solvency

**Category:** State transition

**Statement:** At cancel time, `vault.locked == Σ paid` over all purchases (because
proceeds accumulated every payment and nothing was withdrawn before cancel — withdrawal
requires `Finalized`, which is mutually exclusive with `Cancelled`). Each `refund` releases
exactly `receipt.paid`. Therefore `Σ paid(outstanding receipts) <= vault.locked` at all
times, so every outstanding buyer can always be refunded in full.

**Applies to:** `do_cancel`, `refund`, `release_balance`.

**Enforcement:** emergent from INV-34 + INV-30 + `release_balance`'s `locked >= amount`
check; no path reduces `locked` except a refund of exactly `paid`.

**Violation scenario:** If proceeds could leak before cancel, the vault would be
under-funded and some buyer's refund would abort — last-out loses.

**Severity:** Critical

## Economic / Protocol Invariants

### INV-36: Value conservation — no tokens or payments created from nothing

**Category:** Economic

**Statement:** Every `claim`/`claim_into_vesting` pays out exactly `receipt.allocation`
sale tokens drawn from pre-funded `inventory`; the library never mints `SaleCoin` (it holds
no `TreasuryCap`). Every `refund` pays out exactly `receipt.paid` payment coins drawn from
vault `locked`. Total tokens distributed `<= inventory deposited`; total refunds
`<= raised`.

**Applies to:** `claim`, `claim_into_vesting`, `refund`.

**Enforcement:** INV-28, INV-35, and the absence of any mint path (pre-funded design).

**Severity:** Critical

### INV-37: Mutually-exclusive close outcomes / soft-cap guarantee

**Category:** Economic

**Statement:** A sale closes either as success (`finalize`, requires `raised >= soft_cap`)
or as soft-cap miss (`cancel_after_close`, requires `raised < soft_cap` with `soft_cap > 0`)
— never both, because both consume the single `Active → terminal` transition and their
guards are complementary. If the soft cap is missed, buyers are guaranteed the refund path;
if met, buyers are guaranteed the claim path. With `soft_cap == 0`, `cancel_after_close` is
unreachable (its `soft_cap > 0` guard) and the only non-emergency close is `finalize`.

**Applies to:** `finalize`, `cancel_after_close`, INV-31.

**Enforcement:** complementary guards + monotonic phase.

**Severity:** High

### INV-38: Bounded emergency cancel — no rug of a successful sale

**Category:** Economic

**Statement:** `cancel_emergency` is admin-only, in-window only, and forbidden once
`raised >= hard_cap` or (`soft_cap > 0` and `raised >= soft_cap`). The admin therefore
cannot cancel a sale that has reached its goal to force refunds / claw back a successful
raise. After the window closes, the admin has no cancel power at all (only the permissionless
paths remain).

**Applies to:** `cancel_emergency` (INV-21).

**Enforcement:** the `raised < hard_cap` and `soft_cap == 0 || raised < soft_cap` asserts.

**Violation scenario:** A malicious or compromised admin cancelling a met-goal sale to deny
buyers their allocation.

**Severity:** Critical

### INV-39: Permissionless close and redemption — no admin-liveness dependency

**Category:** Economic

**Statement:** `finalize`, `cancel_after_close`, `claim`, `claim_all`,
`claim_into_vesting`, and `refund` require no capability. Once the window/cap conditions
hold, any caller can close the sale, and buyers can always self-serve their claim or refund
regardless of whether the admin (or allowlist admin) is alive. Losing `SaleAdminCap` costs
only proceeds/unsold-inventory withdrawal and emergency-cancel — never buyer funds.

**Applies to:** the six permissionless functions.

**Enforcement:** no cap parameter on those functions.

**Severity:** High

### INV-40: Vesting cannot be bypassed

**Category:** Economic

**Statement:** When `vesting_schedule_params.is_some()`, the only path that produces a
`Coin/Balance<S>` for a buyer is `claim_into_vesting → vested_claim::into_*`, which always
funds a `VestingWallet<S>` honoring the recorded schedule and paying the recorded
beneficiary. The immediate `claim` aborts (`EClaimRequiresVesting`), and the intermediate
`VestedAllocation` cannot be unpacked outside the library (INV-4).

**Applies to:** `claim`, `claim_into_vesting`, `vested_claim::into_shared_wallet`,
`vested_claim::into_owned_wallet`.

**Enforcement:** INV-23 (runtime) + INV-4 (type level).

**Violation scenario:** A buyer obtaining the full allocation immediately on a sale the
issuer configured to vest.

**Severity:** Critical

### INV-41: Allocation-vs-rate bound — ENFORCEMENT GAP (relies on curve correctness)

**Category:** Economic

**Statement (intended):** A purchase's `allocation` should be bounded by the sale's
committed pricing — historically `allocation <= paid * max_rate` — so a buggy or dishonest
`Curve` cannot over-allocate inventory relative to what the rate implies.

**Reality in code:** There is **no `max_rate` field** and **no `allocation <= paid * max_rate`
check** in `purchase`. The only per-purchase bound is `allocation <= unallocated inventory`
(INV-17). Several docstrings (`purchase`, the `Quote` section, `create_sale`,
`share_and_activate`) still claim this defense-in-depth bound exists. It does not.

**Applies to:** `purchase`, `mint_quote`, every `Curve` module.

**Enforcement mechanism:**
- Type system: only the curve module can mint a quote (INV-5) — so "dishonest curve" reduces to "buggy/malicious curve module," which is inside the audit boundary for first-party curves.
- Runtime check: **missing.** A faulty curve can set any `allocation` up to remaining inventory; the sale will accept it.
- Test: a stub curve minting `allocation > paid * rate` is accepted by `purchase` today (would *not* abort) — demonstrates the gap.

**Violation scenario:** A buggy curve front-loads allocation (early buyers get more than the
rate implies), draining inventory so later in-cap buyers' purchases abort on inventory.
Bounded by total inventory (cannot exceed it — INV-28 still holds), so this is
misallocation among buyers, **not** creation of value beyond inventory.

**Severity:** High — *no fund-loss beyond inventory, but a promised safety property is
absent and the docs are misleading.* Recommend either (a) restore a `max_rate` on the sale
and assert `allocation <= paid * max_rate` in `purchase`, or (b) remove the `max_rate`
claims from the docstrings and state explicitly that inventory backing is the sole bound
and curve correctness is trusted. **Dev decision required.**

### INV-42: Stale receipts pin funds but never lose backing (buyer-protective)

**Category:** Economic

**Statement:** There is no grace-period sweep. An unclaimed receipt in `Finalized` keeps its
`allocation` pinned in `inventory` (admin can only withdraw the unallocated remainder —
INV-25). An unrefunded receipt in `Cancelled` keeps its `paid` in vault `locked` and its
`allocation` counted in `total_allocated`; the vault stays `Refunding` indefinitely. Buyer
funds are never swept or lost; they remain claimable/refundable forever.

**Applies to:** `withdraw_unsold_inventory`, `refund`, vault lifecycle.

**Enforcement:** INV-25 + INV-32 (vault never reaches `Closed` from `Refunding`).

**Severity:** Medium (a known, documented tradeoff; not a defect).

## Composability Invariants

### INV-43: Single-PTB atomic flows via hot potatoes

**Category:** Composability

**Statement:** The no-ability carriers force composition within one PTB:
`curve::quote → purchase` (Quote), `compliance::mint_entry → purchase` (AllowEntry),
`curve::activation_ticket → share_and_activate` (ActivationTicket), and
`claim_into_vesting → vested_claim::into_*` (VestedAllocation). None can be persisted,
split across transactions, or silently dropped.

**Applies to:** `Quote`, `AllowEntry`, `ActivationTicket`, `VestedAllocation`.

**Enforcement:** ability-less carriers (INV-2, INV-3, INV-7, INV-4).

**Severity:** High

### INV-44: No sole-caller assumption on the shared sale

**Category:** Composability

**Statement:** Once shared, the sale supports concurrent independent buyers; per-buyer state
lives in a keyed `Table<address, u64>` rather than any singleton/owned slot, and each
purchase is self-contained. The library never assumes it is the only caller in a PTB.

**Applies to:** `purchase`, the shared `PrefundedSale`, `RefundVault`.

**Enforcement:** shared-object model + per-address table.

**Severity:** Medium

### INV-45: Pricing-module isolation

**Category:** Composability

**Statement:** The sale is pricing-agnostic: it stores opaque `curve_params` and accepts a
priced `Quote` only from its own `Curve` module (INV-5). Swapping pricing means choosing a
different `Curve` type parameter; no sale-core change is required, and one curve cannot price
another curve's sale.

**Applies to:** `PrefundedSale`, `mint_quote`, curve modules.

**Enforcement:** generic `Curve` parameter + witness gating.

**Severity:** Medium

## Existing Invariants (Extension Mode)

This artifact extracts invariants from already-implemented sources, so all invariants above
describe **existing** behavior that must be preserved. There is no pre-existing invariants
document to diff against.

- **Preserved:** all of INV-1…INV-45 reflect the current implementation and must hold.
- **Modified:** none (first invariants artifact for this package).
- **New:** none beyond what the code already embodies. The one item not matching the
  implementation is INV-41 (the documented-but-absent `max_rate` bound), surfaced as a gap
  rather than a silent assumption.

## Invariant Coverage Matrix

| Function | Invariants | Enforcement |
|---|---|---|
| `create_sale` | INV-6, INV-8, INV-11 | Type + Runtime |
| `deposit` | INV-9, INV-28 | Runtime |
| `set_per_buyer_cap` | INV-9, INV-10, INV-11 | Runtime |
| `set_vesting_schedule_params` | INV-9, INV-10 | Runtime |
| `pair_refund_vault` | INV-6, INV-9, INV-10, INV-26, INV-27 | Type + Runtime |
| `enable_allowlist` | INV-3, INV-9, INV-10 | Type + Runtime |
| `mint_activation_ticket` | INV-5, INV-7 | Type |
| `share_and_activate` | INV-7, INV-9, INV-12, INV-28, INV-31 | Type + Runtime |
| `mint_quote` | INV-2, INV-5, INV-18 | Type + Runtime |
| `purchase` | INV-1, INV-2, INV-3, INV-13, INV-14, INV-15, INV-16, INV-17, INV-28, INV-29, INV-30, INV-41, INV-43, INV-44 | Type + Runtime |
| `finalize` | INV-19, INV-26, INV-31, INV-32, INV-33, INV-37, INV-39 | Runtime |
| `cancel_after_close` | INV-20, INV-26, INV-31, INV-32, INV-33, INV-34, INV-35, INV-37, INV-39 | Runtime |
| `cancel_emergency` | INV-21, INV-26, INV-31, INV-32, INV-33, INV-34, INV-35, INV-38 | Runtime |
| `claim` / `claim_all` | INV-1, INV-22, INV-23, INV-25(read), INV-28, INV-29, INV-36, INV-39, INV-40 | Type + Runtime |
| `claim_into_vesting` | INV-1, INV-4, INV-22, INV-23, INV-28, INV-29, INV-36, INV-40, INV-43 | Type + Runtime |
| `withdraw_proceeds` | INV-25, INV-26, INV-34 | Runtime |
| `withdraw_unsold_inventory` | INV-25, INV-26, INV-28, INV-42 | Runtime |
| `refund` | INV-1, INV-22, INV-24, INV-26, INV-28, INV-29, INV-35, INV-36, INV-39, INV-42 | Type + Runtime |
| `vested_claim::into_shared_wallet` | INV-4, INV-40, INV-43 | Type |
| `vested_claim::into_owned_wallet` | INV-4, INV-40, INV-43 | Type |
| `fixed_rate_curve::params` | INV-11 (rate>0) | Runtime |
| `fixed_rate_curve::activation_ticket` | INV-5, INV-7, INV-12 | Type + Runtime |
| `fixed_rate_curve::quote` | INV-2, INV-5, INV-18 | Type + Runtime |
| `allowlist::new_entry` | INV-3 | Type |
| `allowlist::consume` (pkg) | INV-3 | Type + Runtime |
| `refund_vault::new` | INV-6, INV-32 | Type |
| `refund_vault::deposit` | INV-26, INV-27 | Runtime |
| `refund_vault::flip_to_refunding` | INV-26, INV-27, INV-32 | Runtime |
| `refund_vault::flip_to_closed` | INV-26, INV-27, INV-32 | Runtime |
| `refund_vault::release_balance` | INV-26, INV-27, INV-35 | Runtime |
| `refund_vault::withdraw_all` | INV-26, INV-27 | Runtime |
| `receipt::{new_receipt,deliver,consume}` (pkg) | INV-1 | Type |
| `vested_allocation::{new,unpack}` (pkg) | INV-4 | Type |
| `phase::{activate,finalize,cancel}` (pkg) | INV-31 | Runtime |

## Out of Scope

- **Vesting-wallet internal correctness.** `VestingWallet<S>` release math, cliff/linear
  schedule monotonicity, and overflow guards are owned by `openzeppelin_finance::vesting_wallet`
  and its own invariants. This document only guarantees the sale routes a vested claim into a
  wallet with the issuer's recorded schedule and beneficiary.
- **`VestingScheduleParams` semantic validation.** The sale stores the params opaquely and
  does not validate them (e.g. cliff ≤ duration); that is the vesting wallet's `new`
  responsibility at consumption.
- **`Witness` choice in `vested_claim::into_*`.** The wallet witness type is caller-chosen and
  not pinned to the sale/curve; binding it is integrator territory (see Open Questions).
- **Curve pricing-math correctness.** Delegated to each `Curve` module. The sale trusts the
  quote's `allocation` up to inventory (see INV-41 for the missing defensive bound).
- **Compliance/KYC logic.** The library ships only the `AllowlistAdmin`/`AllowEntry` slot;
  verification logic lives in integrator modules.
- **Clock granularity / consensus timing.** Sub-second auction clearing is not a goal; time
  windows are reliable at sale-duration granularity only.
- **Lost-capability recovery.** Losing `SaleAdminCap` or `AllowlistAdmin` is a documented
  operational footgun (hold in a recoverable wrapper), not a library invariant.
- **Multi-payment / multi-curve single sale, minting sale (`MintingSale`), grace-period
  sweep.** Out of v1 scope per proposal §6.

## Dev Notes

- **Source of truth is the code, not `proposal.md` §5.** The proposal's inline invariants
  summary predates the curve-generic / `Quote` / `ActivationTicket` refactor. INV-41 is the
  one place the *code* contradicts its own *docstrings*.
- **Misnamed error codes (code-quality, not invariant violations):**
  - `purchase`'s inventory-backing assert uses `EInsufficientInventoryAtActivate` (intended
    for activation, reused at purchase time) — see [prefunded_sale.move:772](contracts/sale/sources/prefunded_sale.move#L772).
  - `share_and_activate`'s ticket-sale-id assert uses `EReceiptSaleMismatch` instead of a
    ticket-specific code — see [prefunded_sale.move:667](contracts/sale/sources/prefunded_sale.move#L667).
  These don't break any invariant but will confuse integrators reading aborts; suggest
  dedicated codes during the next code-draft pass.
- **`TODO` in `share_and_activate`** ([prefunded_sale.move:669](contracts/sale/sources/prefunded_sale.move#L669)):
  "move phase-related error codes to this module and remove assert_init" — tracked, not an
  invariant concern.
- **Refund-vault `Closed` path is inert in the paired flow.** Pairing requires an empty vault
  and `finalize` only flips it to `Closed` without depositing (proceeds stay in the sale), so
  `withdraw_all` would return 0 and the wrapped cap is never exposed to call it. No stranded
  funds — consistent with INV-33/INV-42.

## Open Questions

1. **INV-41 — restore the bound or fix the docs?** Add `max_rate` back to the sale and assert
   `allocation <= paid * max_rate` in `purchase` (defense-in-depth against a buggy curve), or
   delete the stale `max_rate` claims and document inventory backing as the sole bound with
   curve correctness trusted? *(Blocks closing the docstring/code contradiction.)*
2. **Should `vested_claim::into_*` pin the `Witness` to the sale's curve/schedule?** Today an
   integrator picks the wallet witness freely. Is there a domain reason to bind it, or is
   that intentionally integrator territory?
3. **Any economic invariant the LLM missed?** Specifically around the curve abstraction —
   e.g. should ratcheting/decreasing-rate curves carry an extra monotonicity invariant the
   sale should defend, or is that wholly the curve's responsibility?
4. **Per-entry vs per-buyer cap interaction** — is the current "per-entry caps a single
   purchase, per-buyer caps cumulative, both can coexist" the intended product behavior, or
   should one dominate?

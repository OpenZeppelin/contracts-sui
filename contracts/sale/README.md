# `openzeppelin_sale`

Fixed-price, pre-funded token sales (presale / IDO) for Sui.

The `openzeppelin_sale` package runs a token sale against a **fixed, pre-deposited
inventory**. The issuer funds the sale with a `Balance<SaleCoin>` up front; buyers pay
a `PaymentCoin` during a time window and each receives a non-transferable `Receipt`.
After the window the sale resolves one of two ways: **finalize** (success - buyers
claim their tokens, the issuer withdraws proceeds) or **cancel** (failure - buyers
recover their payment from an escrow vault). Use it for capped public rounds,
per-address-capped public rounds, and compliance-gated strategic rounds.

Pricing is not baked in. The sale is generic over a **witness-gated curve module**
that computes each buyer's allocation; a built-in **fixed-rate curve**
(`allocation = paid * rate`) covers the common case, and the seam is open for custom
curves. The sale never holds a `TreasuryCap` - it only ever routes the inventory and
payments deposited into it.

> [!NOTE]
> This is the **prefunded** flavor (`prefunded_sale`), which draws from a fixed
> inventory and never mints. A future minting flavor (which would hold a
> `TreasuryCap<SaleCoin>`) is a separate type with the same `Receipt` and `Phase`, and
> is out of scope for this package.

## Install

```toml
[dependencies]
openzeppelin_sale = { git = "https://github.com/OpenZeppelin/contracts-sui.git", subdir = "contracts/sale", rev = "v1.5.0" }
```

> [!NOTE]
> `openzeppelin_sale` is **not yet published** to the Move Registry. The handle above
> is the intended install form once released; until then, vendor the package from
> source. It depends on [`openzeppelin_finance`](../finance) for the vesting path.

## Modules

Most integrators interact with `prefunded_sale` + `fixed_rate_curve`. The other four
are supporting types you will see in signatures.

| Module | What it is |
| --- | --- |
| [`prefunded_sale`](https://docs.openzeppelin.com/contracts-sui/1.x/api/sale#prefunded_sale) | The sale itself. Create + configure (Init), `share_and_activate`, `purchase`, close (`finalize` / `cancel_*`), and redeem (`claim*` / `refund` / `withdraw_*`). **Start here.** |
| [`fixed_rate_curve`](https://docs.openzeppelin.com/contracts-sui/1.x/api/sale#fixed_rate_curve) | The built-in pricing curve: `allocation = paid * rate`, fixed for the whole sale. Mints the `Quote` and `ActivationTicket` a `FixedRateCurve` sale needs. **Most sales use this.** |
| [`refund_vault`](https://docs.openzeppelin.com/contracts-sui/1.x/api/sale#refund_vault) | A generic, cap-gated refundable escrow over `Balance<P>`. Every sale is paired with one; on cancel it holds the proceeds, and each buyer recovers their payment through the sale's `Receipt`-authorized `refund` (the vault itself keeps no per-depositor ledger). Usable standalone. |
| [`allowlist`](https://docs.openzeppelin.com/contracts-sui/1.x/api/sale#allowlist) | A typed compliance slot (`AllowlistAdmin` + single-use `AllowEntry`). The library ships **no** KYC logic - you wire your own scheme against these types. |
| [`receipt`](https://docs.openzeppelin.com/contracts-sui/1.x/api/sale#receipt) | The non-transferable, buyer-bound claim ticket minted by `purchase` and consumed by `claim` / `refund`. |

## Key Concepts

### The sale is pricing-agnostic; the curve is trusted

`PrefundedSale` is generic over a **curve witness**:

```move
PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingWitness, VestingScheduleParams>
```

| Type param | Meaning | Fixed-rate example |
| --- | --- | --- |
| `Curve` | The pricing witness (a `drop`-only struct the curve module declares). | `fixed_rate_curve::FixedRateCurve` |
| `CurveParams` | The curve's stored config, opaque to the sale. | `fixed_rate_curve::Params` |
| `SaleCoin` | The token being sold. | your project coin |
| `PaymentCoin` | The coin collected as proceeds. | `USDC`, `SUI`, … |
| `VestingWitness` | The vesting schedule's witness (the `drop`-only type that owns `VestingScheduleParams`). Fixes which schedule `claim_into_vesting` builds. Instantiated even for a non-vesting sale. | `vesting_wallet_linear::Linear` |
| `VestingScheduleParams` | The vesting params type. Filled only if you attach a schedule, but the slot must always be instantiated. | `vesting_wallet_linear::Params` |

The sale never prices a purchase itself. It accepts a `Quote` - carrying a
curve-computed `allocation` - and applies it **verbatim**, bounded only by unallocated
inventory and `u64` overflow guards. There is **no `max_rate` field and no
independent per-payment rate check**: correct pricing is delegated to the curve.

What keeps this safe is the **witness gate**. A `Quote` for a `PrefundedSale<C, …>`
can only be minted by passing a value of type `C`, and `C`'s constructor is private to
the module that declares it. So a sale parameterized on `FixedRateCurve` can be priced
by no other code - the curve is first-party, trusted, and audited alongside the sale.

> [!IMPORTANT]
> **The curve is a trusted component.** A buggy or dishonest curve can over-allocate
> per payment up to the inventory ceiling (it can never create tokens beyond inventory,
> and no payment is ever taken without an atomic allocation, but it can make the sale
> sell out before the hard cap). Treat any custom curve as security-critical and audit
> it with the sale. The provided `fixed_rate_curve` is honest by construction.

### Hot potatoes: `Quote` and `AllowEntry`

Two carrier types have **no abilities** - they cannot be stored, copied, transferred,
or dropped, so they must be minted and consumed **in the same transaction (PTB)**:

- **`Quote<PaymentCoin>`** - carries the buyer's payment `Balance` *and* the
  curve-computed allocation. The curve module's `quote(...)` mints it; the sale's
  `purchase(...)` is its only legal consumer. Pricing and funds stay welded together
  and cannot be replayed across transactions.
- **`AllowEntry<SaleCoin>`** - a single-use compliance ticket (allowlist sales only).
  Your compliance module mints one per approved buyer; `purchase` consumes it,
  asserting it was issued for *this* sale and *this* buyer. No warehousing, no replay.

`ActivationTicket<Curve>` is a third witness-minted hot potato, consumed once by
`share_and_activate` to carry the curve's inventory-backing requirement.

### Lifecycle

```text
  create_sale ─┐
  deposit       │
  set_per_buyer_cap          │  Init phase - sale is an OWNED value;
  set_vesting_schedule_params├   holding it by &mut is the authority.
  enable_allowlist           │   All setup happens here.
  pair_refund_vault          │
                             │
  share_and_activate ────────┴──▶  Active phase - sale AND vault are SHARED.
                                       │
                                   purchase ×N   (within [opens_at_ms, closes_at_ms])
                                       │
                                       ├──▶ finalize             (permissionless; success)
                                       │      claim / claim_all, withdraw_proceeds,
                                       │      withdraw_unsold_inventory
                                       │
                                       ├──▶ cancel_after_close   (permissionless; soft-cap miss)
                                       │      refund / refund_all, withdraw_unsold_inventory
                                       │
                                       └──▶ cancel_emergency     (admin-only; in-window emergency)
                                              refund / refund_all, withdraw_unsold_inventory
```

`Finalized` and `Cancelled` are terminal. During `Init` the sale is an owned value and
**all setup must complete before `share_and_activate`** - setup functions abort once
the sale is `Active`.

### Receipts are non-transferable and buyer-bound

Each `purchase` delivers one `Receipt<SaleCoin>` to the buyer. It has `key` only (no
`store`), so it cannot be transferred, wrapped, or stored elsewhere - and `claim` /
`refund` additionally assert `ctx.sender() == receipt.buyer`. Two consequences:

- **No wallet rotation** between purchase and redemption. The buying address is the
  redeeming address.
- **KYC enforced at purchase carries through to distribution** - a verified buyer
  cannot forward a claim to an unverified address.

A buyer with several purchases holds several receipts; `claim_all` batches redemption
on a finalized sale and `refund_all` batches recovery on a cancelled one.

### Every sale needs a refund vault

A `RefundVault<PaymentCoin>` is **required before activation**, even when
`soft_cap == 0` - `cancel_emergency` always needs a refund destination. When paired,
the vault must be **`Active` and empty** (pre-existing funds would be stranded). The
sale consumes the vault's controller cap and from then on drives the vault's state:
`finalize` flips it to `Closed`, cancel flips it to `Refunding`. Buyers refund
directly from the vault; this never depends on admin liveness.

An external router deciding between `claim` and `refund` reads the sale's phase
directly - `is_finalized()` for the claim path, `is_cancelled()` for the refund path
(the full set is `is_init` / `is_active` / `is_finalized` / `is_cancelled`). Do **not**
infer the phase from the vault's `is_refunding` / `is_closed` state: that flip is an
internal consequence of the sale's transition, not a supported signal, and a caller
could supply an unrelated vault of the right coin type. Verify a vault is the sale's
own with `refund_vault_id()` before trusting it.

### Optional vesting

Attach an issuer-defined schedule with `set_vesting_schedule_params` during `Init`.
When set, the plain `claim` path aborts and the only redemption route is
`claim_into_vesting`, which returns a funded
[`VestingWallet`](../finance) (from `openzeppelin_finance`) - with `beneficiary` forced
to the buyer and the sale's fixed schedule params - plus the wallet's `DestroyCap`
(teardown authority). The buyer cannot influence or bypass the schedule. Releases pay
into the beneficiary's address balance, so the buyer receives funds without holding
the wallet.

## Choosing a sale shape

Four orthogonal, independent configuration axes:

- **Hard cap (required, `> 0`).** Bounds the maximum raise. Inventory backing for the
  full hard cap is enforced at activation, so with an honest curve a `purchase` never
  runs out of inventory before the hard cap is reached (a buggy or dishonest curve can
  over-allocate and sell out early - see the curve-trust note above). Depositing more
  than the backing is allowed, and the surplus stays withdrawable, so
  *hard-cap-reached* does not imply the inventory is exhausted.
- **Soft cap (optional, `0 = none`).** Minimum raise required to `finalize`. If the
  window closes below it, anyone can `cancel_after_close` and every buyer can refund.
- **Per-buyer cap (optional).** Cumulative cap on a single buyer's total payment.
  Configure with `set_per_buyer_cap`.
- **Allowlist (optional).** Compliance-gated mode: every `purchase` must consume an
  `AllowEntry`. Configure with `enable_allowlist`.

The three shapes a fixed-price sale typically takes:

| Shape | KYC | Soft cap | Per-buyer cap | Typical use |
| --- | --- | --- | --- | --- |
| Public round | no | no | no | Open public sale, FCFS |
| Capped public round | no | optional | yes | Public sale with a per-address spend cap |
| Strategic round | yes | yes | yes | Compliance-gated raise |

The per-buyer cap is keyed by sender address, so it bounds spend **per address**, not
per actor. Without KYC (the strategic round), one actor buying from many addresses
defeats it - a per-address cap is not, on its own, whale resistance.

This primitive is **not** a bonding curve, LBP, auction (Dutch / English / sealed-bid),
or fair launch - those have different mechanics and belong in separate standards.

## Usage

The examples below use `SALE` as the sale token, `USDC` as the payment coin, and
`vesting_wallet_linear::{Linear, Params}` for the (unused, non-vesting) vesting slot.

### Issuer: create, fund, and activate

Everything below runs in `Init` and is typically threaded through one PTB. Authority is
implicit - the sale is an owned value, so only its holder can pass it by `&mut`.

```move
use openzeppelin_sale::prefunded_sale;
use openzeppelin_sale::fixed_rate_curve::{Self, FixedRateCurve, Params as FrcParams};
use openzeppelin_sale::refund_vault;
use openzeppelin_finance::vesting_wallet_linear::{Linear, Params as VParams};
use sui::clock::Clock;
use sui::coin::Coin;

/// Create a capped public round and hand the shared sale + vault to the world.
public fun launch(
    inventory: Coin<SALE>,    // pre-acquired sale tokens
    rate: u64,                // SALE smallest-units per 1 USDC smallest-unit
    hard_cap: u64,
    soft_cap: u64,            // 0 = none
    per_buyer_cap: u64,
    opens_at_ms: u64,
    closes_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // 1. Create the sale (Init). Returns the owned sale + its admin cap.
    let (mut sale, admin_cap) = prefunded_sale::create_sale<
        FixedRateCurve, FrcParams, SALE, USDC, Linear, VParams,
    >(
        fixed_rate_curve::params(rate),
        hard_cap,
        soft_cap,
        opens_at_ms,
        closes_at_ms,
        ctx,
    );

    // 2. Fund inventory (deposit takes a Balance).
    sale.deposit(inventory.into_balance());

    // 3. Optional knobs - all Init-only and one-shot.
    sale.set_per_buyer_cap(per_buyer_cap, ctx);
    // let allow_admin = sale.enable_allowlist(ctx);  // for a strategic round
    // sale.set_vesting_schedule_params(vesting_wallet_linear::params(...));

    // 4. Pair a fresh, empty, Active vault, then activate. share_and_activate takes
    //    the vault by value and shares it together with the sale, so the
    //    permissionless refund paths can never be bricked by a forgotten share step.
    let (vault, vault_cap) = refund_vault::new<USDC>(ctx);
    sale.pair_refund_vault(&vault, vault_cap);
    let ticket = fixed_rate_curve::activation_ticket(&sale);
    sale.share_and_activate(vault, ticket, clock);   // consumes + shares sale AND vault

    // 5. Park the admin cap somewhere recoverable (RBAC / multisig / governance).
    transfer::public_transfer(admin_cap, ctx.sender());
}
```

### Buyer: purchase

`quote` takes the payment as a `Balance` and welds it into the returned `Quote`;
`purchase` consumes the quote and delivers the `Receipt` to the sender. For a
non-allowlist sale, pass `option::none()` for the entry.

```move
public fun buy(
    sale: &mut PrefundedSale<FixedRateCurve, FrcParams, SALE, USDC, Linear, VParams>,
    payment: Coin<USDC>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let quote = fixed_rate_curve::quote(sale, payment.into_balance());
    sale.purchase(quote, option::none(), clock, ctx);
    // The Receipt<SALE> is now owned by ctx.sender().
}
```

### Close and redeem (success)

```move
// Permissionless: callable once the window closes with soft cap met,
// or as soon as the hard cap is reached (closes early).
sale.finalize(&mut vault, clock);

// Buyer redeems their receipt for Coin<SALE>.
let tokens: Balance<SALE> = sale.claim(receipt, ctx);
transfer::public_transfer(coin::from_balance(tokens, ctx), ctx.sender());

// Admin (cap-gated) withdrawals.
let proceeds: Balance<USDC> = sale.withdraw_proceeds(&admin_cap);
let unsold:   Balance<SALE> = sale.withdraw_unsold_inventory(&admin_cap); // only the slack
```

### Close and redeem (failure)

```move
// Permissionless once the window closes below soft cap:
sale.cancel_after_close(&mut vault, clock);
// ...or admin-only, in-window emergency (cannot cancel a goal-reaching sale):
// sale.cancel_emergency(&admin_cap, &mut vault, clock);

// Every buyer recovers exactly what they paid, in any order, without admin help.
let money_back: Balance<USDC> = sale.refund(&mut vault, receipt, ctx);
transfer::public_transfer(coin::from_balance(money_back, ctx), ctx.sender());
```

### Redeem into vesting

For a sale created with `set_vesting_schedule_params`, redemption must go through
`claim_into_vesting`. The vesting schedule - both its `VestingWitness` (here
`vesting_wallet_linear::Linear`) and its `VestingScheduleParams` - is fixed at
`create_sale`, so `claim_into_vesting` infers **every** type argument from the `sale`
it takes by `&mut`. The turbofish below is written out only to name the wallet's type;
you can drop it entirely and let inference fill it in:

```move
use openzeppelin_finance::vesting_wallet::{VestingWallet, DestroyCap};
use openzeppelin_finance::vesting_wallet_linear::{Linear, Params as VParams};

// Returns the funded wallet plus its DestroyCap (teardown authority).
let (wallet, cap): (VestingWallet<Linear, VParams, SALE>, DestroyCap) =
    prefunded_sale::claim_into_vesting(&mut sale, receipt, ctx);

transfer::public_share_object(wallet);        // shared: anyone can poke `release`; funds land in the buyer's address balance
transfer::public_transfer(cap, ctx.sender()); // hold the cap to reclaim the drained wallet's storage later
```

## PTB / TypeScript integration

A buyer's purchase from the TypeScript SDK. The payment coin is converted to a
`Balance`, fed to the curve's `quote`, and the resulting `Quote` is consumed by
`purchase` - all in one PTB. The `Receipt` is transferred to the sender automatically.

```typescript
import { Transaction } from '@mysten/sui/transactions';

const PKG = '0x…';                 // openzeppelin_sale package id
const SALE = `${PROJECT_PKG}::coin::SALE`;
const USDC = '0x…::usdc::USDC';
const VWITNESS = `${FINANCE_PKG}::vesting_wallet_linear::Linear`;
const VPARAMS = `${FINANCE_PKG}::vesting_wallet_linear::Params`;
const CURVE = `${PKG}::fixed_rate_curve::FixedRateCurve`;
const FRC_PARAMS = `${PKG}::fixed_rate_curve::Params`;

const tx = new Transaction();

// 1. Coin<USDC> -> Balance<USDC>
const payBalance = tx.moveCall({
  target: '0x2::coin::into_balance',
  typeArguments: [USDC],
  arguments: [tx.object(usdcCoinId)],
});

// 2. Mint the Quote from the curve module. (quote: <SaleCoin, PaymentCoin, VestingWitness, VestingScheduleParams>)
const quote = tx.moveCall({
  target: `${PKG}::fixed_rate_curve::quote`,
  typeArguments: [SALE, USDC, VWITNESS, VPARAMS],
  arguments: [tx.object(SALE_ID), payBalance],
});

// 3. allow = option::none<AllowEntry<SALE>>() for a non-allowlist sale.
const noEntry = tx.moveCall({
  target: '0x1::option::none',
  typeArguments: [`${PKG}::allowlist::AllowEntry<${SALE}>`],
  arguments: [],
});

// 4. Purchase. (purchase: <Curve, CurveParams, SaleCoin, PaymentCoin, VestingWitness, VestingScheduleParams>)
tx.moveCall({
  target: `${PKG}::prefunded_sale::purchase`,
  typeArguments: [CURVE, FRC_PARAMS, SALE, USDC, VWITNESS, VPARAMS],
  arguments: [tx.object(SALE_ID), quote, noEntry, tx.object('0x6')], // 0x6 = Clock
});
```

For an **allowlist** sale, replace step 3 with a call into your compliance module's
mint function (which returns an `AllowEntry`) and thread that into `purchase` - minted
and consumed in the same PTB.

`claim`, `refund`, `withdraw_proceeds`, and `withdraw_unsold_inventory` all return a
`Balance`, so a follow-up `0x2::coin::from_balance` + transfer is needed to land coins
in a wallet.

## Common mistakes

| Mistake | What happens | Fix |
| --- | --- | --- |
| Configuring (deposit / caps / allowlist / vesting) after `share_and_activate` | Aborts (`ENotInit`) | Do all setup in `Init`, before activating. |
| Pairing a vault that already holds funds, or is not `Active` (already `Refunding` / `Closed`) | Aborts (`EVaultNotEmpty` / `EVaultNotActive`) | Pair a fresh, empty `Active` vault; `share_and_activate` then consumes and shares it for you (don't `share` it yourself first). |
| Activating with under-provisioned inventory | Aborts (`EInsufficientInventoryAtActivate`) | Deposit `≥ hard_cap * rate` before activating (the curve's `activation_ticket` computes the requirement). |
| Plain `claim` on a vesting sale (or `claim_into_vesting` on a non-vesting sale) | Aborts (`EClaimRequiresVesting` / `ENoVestingScheduleAttached`) | Match the redemption path to whether a schedule is attached. |
| Buying then redeeming from a different wallet | Aborts (`EBuyerOnly`) | Redeem from the purchasing address - receipts are buyer-bound. |
| Losing the `AllowlistAdmin` of an allowlist sale | No entries can be minted -> every `purchase` aborts | Hold caps in a recoverable RBAC / multisig wrapper. |

## Security Notes

- **The curve is trusted.** The sale applies the curve's allocation verbatim, bounded
  only by inventory and overflow. The witness gate makes a `FixedRateCurve` sale
  un-priceable by anything but the fixed-rate module; a *custom* curve is
  security-critical and must be audited with the sale.
- **Buyer redemption never depends on admin liveness.** `purchase`, `claim`, `refund`,
  `finalize`, and `cancel_after_close` are permissionless. Losing the `SaleAdminCap`
  forfeits only `cancel_emergency`, `withdraw_proceeds`, and `withdraw_unsold_inventory`
  - buyer funds are never stranded.
- **Admin cannot rug a goal-reaching sale.** `cancel_emergency` is blocked once the
  hard cap (or a configured soft cap) is reached, and is window-bounded - a successful
  raise can only `finalize`.
- **Refund solvency is guaranteed.** On cancel the entire proceeds balance moves into
  the vault, so `vault.locked == raised`; every buyer can recover exactly their
  payment, in any order.
- **Receipts are non-transferable and buyer-bound** - no wallet rotation, and KYC at
  purchase carries through to distribution.
- **Stale receipts pin funds.** There is no grace-period sweep. An unclaimed receipt
  keeps its allocation pinned in inventory (Finalized) or its payment locked in the
  vault (Cancelled) indefinitely. This is buyer-protective by design.
- **Lost caps are unrecoverable by the library** (no centralization override). A lost
  `AllowlistAdmin` bricks purchases on an allowlist sale. Hold every cap in an
  access-controlled wrapper.

## Examples

> [!Warning]
> Integration examples are illustrations of how the primitive can be wired up, **not**
> production-ready code.

The full unit suite under [`tests/`](tests) doubles as an executable specification -
`test_utils.move` shows the canonical `Init -> Active` setup, and the thematic files
exercise every purchase, close, redemption, and failure path. Standalone integration
examples will live in [`examples/`](examples).

## Learn More

- [Sale package overview](https://docs.openzeppelin.com/contracts-sui/1.x/sale)
- [Sale API reference](https://docs.openzeppelin.com/contracts-sui/1.x/api/sale)
- [`openzeppelin_finance`](../finance) - the vesting wallet behind `claim_into_vesting`
- [`llms.txt`](https://raw.githubusercontent.com/OpenZeppelin/contracts-sui/main/llms.txt): discovery entry point for AI integrators
- [OpenZeppelin Contracts for Sui](https://docs.openzeppelin.com/contracts-sui)

#### 1. Problem (short)

- What is being solved/improved?
    
    Token issuers on Sui need a way to run pre-sales (strategic / private / public rounds) without rebuilding the security primitives from scratch. Today the open-source Move ecosystem has no audited fixed-price sale library: issuers either pay a launchpad product (lose UX and economic control, hand over a recurring fee), or commission a one-off contract ($50–150k audit, weeks of engineering, code unreusable for anyone else). Every launch reinvents the wheel and re-pays for the audit.
    
- Who is the target user (regular user / protocol / developer)?
    
    The primary user is the **smart-contract developer at a token-issuing project** wiring a sale at launch, with the issuer's compliance and treasury teams in the loop. Secondary users are **launchpad operators** who want to adopt the standard as their engine and differentiate on UX/KYC, and **wallets / indexers / aggregators** consuming a canonical event schema. The end-buyer is *not* the target user — they interact through the issuer's UI.
    

#### 2. Existing solutions

*Source: research artifact — Existing Sui Implementations + Gap Analysis*

- What already exists in Sui?
    - `movefuns/sui-ido` — hackathon-grade open-source IDO, right shape but buggy and incomplete.
    - `karangoraniya/sui-ido` — broken owned-object design; only one buyer can participate at a time.
    - `roswelly/sui-presale-smart-contract` — satellite primitives (KYC, tier, referral) with no integrated sale.
    - `kunalabs-io` vesting/distribution library — high quality, plugs *into* a sale but isn't one.
    - Sui official docs — linear/cliff/milestone/hybrid vesting wallet examples (we vendor and modify `0xNeshi/vesting-wallet` for this design).
    - **Closed-source launchpads:** SuiPad, BeLaunch, SeaPad, Republic — full-stack products with proprietary Move code; can't be audited or composed with.
- What does it do well / poorly?
    - Launchpads are operationally complete but lock issuers into their UX, KYC vendor, and fees. Closed source — community can't audit.
    - Open-source Move examples are either incomplete (no soft-cap refund, no per-buyer cap, no vesting), unaudited, or broken in obvious ways (single-buyer designs). None is reusable as a library.
- Which constraints come from Sui's model (ownership, shared objects, upgrades, etc.)?
    - **Shared-object contention.** A sale object is shared so anyone can purchase, finalize, or refund. Per-block consensus on the shared sale bounds raw TPS; in practice fine for sale durations measured in hours/days, but worth noting for any "1ms launch" auction shape (we don't ship that).
    - **Object capabilities, not address authority.** `SaleAdminCap<S, P>`, `AllowlistAdmin<S>`, `RefundVaultCap<P>` are typed object-capabilities rather than addresses-with-roles. Loses-the-key implications are different from EVM (no `Ownable` recovery without a separate wrapper).
    - **Receipt non-transferability via abilities.** `Receipt<S>` carries `key` only — Sui's transfer system refuses to move it, the type system refuses to wrap it. This is a property of the type, not a runtime check.
    - **PTBs allow atomic composition.** `mint_entry → purchase → … → claim_into_vesting → vested_claim::into_shared_wallet` can be one transaction. The hot-potato pattern (no-drop carriers) enforces "you must consume me in this PTB" without needing a state machine.
    - **No mid-tx upgrade.** Module upgrade story for shared sales is non-trivial; the library's lifecycle enum and event schema are committed at publish time.
    - **Clock granularity.** `sui::clock::Clock` advances per consensus commit (sub-second on Sui). Time windows are reliable for sale duration but not for sub-second auction clearing.

#### 3. Integration surface

*Source: design artifact — Integration Patterns + Object Ownership Model*

- **What does the integrator add on their end?**
    - The sale token type `S` and its `TreasuryCap<S>` (held by issuer; standard never holds it).
    - The payment coin type `P` (e.g., `SUI`, `USDC`).
    - An optional compliance module shape (the example ships `simple_kyc` as a reference; integrator can swap for sealed-credential, attestation-list, vendor-API, etc.).
    - A factory layer (the example ships `sale_factory`) that wires their token, KYC, and chosen sale shape into the library primitives.
- **What comes from the library?**
    - `PrefundedSale<S, P>` — the sale object, with phase, caps, vesting schedule, allowlist hook.
    - `Receipt<S>` — buyer claim ticket; non-transferable (`key` only).
    - `RefundVault<P>` — typed refundable escrow, lifecycle slaved to the sale.
    - `AllowEntry<S>` — hot-potato compliance ticket; minted by the integrator's compliance module, consumed by `purchase` in the same PTB.
    - `VestingSchedule` — issuer-defined vesting policy attached to the sale at `Init`.
    - `VestedAllocation<S>` — no-ability hot-potato wrapping a claim on a vested sale; only the library can construct or unpack.
    - `VestingWallet<S>` — vendored linear-with-cliff wallet (modified: `migrate_beneficiary` removed; overflow-guarded).
    - `vested_claim::into_*` — library router that converts `VestedAllocation` into a funded wallet.
- **What objects/capabilities are required, and which entities hold them?**

| **Capability** | **Type** | **Issued by** | **Held by** | **Controls** |
| --- | --- | --- | --- | --- |
| `SaleAdminCap<S, P>` | `key, store` | `create_sale` | Issuer treasury (multisig recommended) | `cancel_emergency`, `withdraw_proceeds`, `withdraw_unsold_inventory` |
| `AllowlistAdmin<S>` | `key, store` | `enable_allowlist` (one-shot) | Integrator's compliance module | Minting `AllowEntry<S>` tickets |
| `RefundVaultCap<P>` | `store` only | `refund_vault::new` | Wrapped inside the sale; never exposed | Vault state transitions; library-internal |

Buyers hold no capability — they hold a `Receipt<S>` per purchase. Permissionless close paths (`finalize`, `cancel_after_close`) need no capability.

- **How does the system get configured?**
    
    Init-phase setup (sale is owned, not yet shared):
    
    1. `create_sale<S, P>(rate, hard_cap, soft_cap, opens_at_ms, closes_at_ms, ctx) → (sale, cap)`
    2. `deposit(&mut sale, coin)` — fund the sale's `Balance<S>`.
    3. `set_per_buyer_cap(&mut sale, cap, ctx)` *(optional)*
    4. `set_vesting_schedule(&mut sale, start_ms, cliff_ms, duration_ms)` *(optional; enables `claim_into_vesting`, disables plain `claim`)*
    5. `pair_refund_vault(&mut sale, &vault, vault_cap)` — required.
    6. `enable_allowlist(&mut sale, ctx) → AllowlistAdmin<S>` *(optional)*
    7. `share_and_activate(sale, &clock)` — shares the sale; phase flips to Active.
    
    The integrator's `sale_factory` composes these into 4 plain-English helpers (`deploy_public_round` / `deploy_capped_public_round` / `deploy_strategic_round` / `deploy_strategic_round_vested`).
    
- **Ownership boundaries**
    
    Two tiers, enforced by convention in v1 (single-package), by type system in v2 (separate package):
    
    - **Tier 1** (`sources/library/`) — audit boundary. `sale`, `prefunded_sale`, `refund_vault`, `allowlist`, `vesting_wallet`, `vested_claim`.
    - **Tier 2** (`sources/integration/`) — example wiring, not audited. `my_token`, `simple_kyc`, `sale_factory`.
    
    Convention rule: integration code never calls a library `public(package)` helper. Grep-checkable.
    
- Link to design artifact
    
    openzeppelin/contracts-sui — sales_example/README.md
    
- Consumer-side integration sketch (high level — types and flow, not full code)
    
    ```
    // One-time at deployment (issuer's factory tx):
    let (sale_id, vault_id) = sale_factory::deploy_strategic_round_vested(
        &mut treasury_cap, &mut kyc_module, &kyc_cap, treasury_addr,
        rate, inventory, hard_cap, soft_cap, per_buyer_cap,
        vest_start, vest_cliff, vest_duration,
        opens_at, closes_at, &clock, ctx,
    );
    
    // Per-buyer at sale time (buyer's PTB):
    let entry   = simple_kyc::mint_entry(&kyc, sale_id, ctx);
    let payment = /* user's Coin<P> */;
    prefunded_sale::purchase<S, P>(&mut sale, payment, option::some(entry), &clock, ctx);
    // Receipt<S> auto-delivered to buyer; entry consumed.
    
    // Permissionless close (anyone, after window):
    prefunded_sale::finalize(&mut sale, &mut vault, &clock);
    
    // Buyer redemption (buyer's PTB):
    let allocation = prefunded_sale::claim_into_vesting<S, P>(&mut sale, receipt, ctx);
    vested_claim::into_shared_wallet<S>(allocation, ctx);
    // Wallet is shared; anyone pokes `release` over the schedule.
    ```
    

#### 4. Minimal end-to-end examples (required)

Actual compiling code in a separate repo/module. **Add comments explaining flow**, not implementation. Anyone should understand the system by reading the example, not the spec.

- Link to example repo/module(s)
    
    https://github.com/ericnordelo/sales_example/blob/main/sources/library/prefunded_sale.move
    
- Happy path example
    - `tests/happy_path_tests::public_sale_happy_path` — open public round → finalize → claim.
    - `tests/kyc_gated_tests::kyc_gated_purchase_and_claim` — KYC verify → mint entry + purchase in one PTB → finalize → claim.
    - `tests/vested_claim_tests::strategic_round_vested_claim_releases_over_time` — strategic round with 6-month cliff + 12-month linear vesting; releases observed pre-cliff, mid-vest (75%), post-end.
- Failing case example
    - `kyc_gated_tests::unverified_buyer_cannot_mint_entry` — KYC gate rejects.
    - `kyc_gated_tests::attacker_cannot_claim_buyers_receipt` — receipt buyer-binding rejects.
    - `vested_claim_tests::plain_claim_aborts_on_vested_sale` — vested-bypass via `claim` rejects (the P1 fix from review round 6).
    - `capped_public_round_tests::capped_public_round_second_buy_over_cap_aborts` — per-buyer cap rejects.
    - The 3 `capped_public_round_tests::cancel_emergency_aborts_after_*` tests — admin can't rug a successful or closed sale (hard-cap reached, soft-cap met, after-window).
    - `refund_path_tests::strategic_round_soft_cap_miss_refund` — soft-cap miss flips vault to Refunding; buyer refunds; treasury reclaims unsold inventory.
    
    Test suite: **13/13 passing** at `sui move test`.
    

#### 5. Invariants summary

*Source: invariants artifact*

Link to the full invariants artifact — don't duplicate it here.

- Link to invariants artifact
    
    A standalone invariants artifact does not yet exist. Inline summary below; a separate doc is tracked under "Open questions / follow-ups".
    
- Critical invariants (type-level, runtime, economic) — 3–5 max
    1. **Inventory backing.** `inventory.value() >= total_allocated` holds in every phase, every transaction. `withdraw_unsold_inventory` only ever releases `inventory - total_allocated`, so outstanding receipts remain backed.
    2. **Receipt buyer-binding.** `Receipt<S>` has `key` only — neither transfer nor wrapping is type-permitted. `claim`, `claim_into_vesting`, and `refund` additionally assert `ctx.sender() == receipt.buyer`. KYC at purchase carries through redemption.
    3. **No coin leakage on vested sales.** When `vesting_schedule.is_some()`, `prefunded_sale::claim` aborts with `EClaimRequiresVesting`. The only path producing a `Coin<S>` is `claim_into_vesting → vested_claim::into_*`, both library-side. The intermediate `VestedAllocation<S>` carrier has no `drop / key / store`, private fields, and `public(package)` ctor/unpacker — buyers cannot stash, discard, or peel it.
    4. **Permissionless close.** Once `closes_at_ms` has passed, anyone can call `finalize` (if `raised >= soft_cap`) or `cancel_after_close` (if `raised < soft_cap`). Buyer claims/refunds do not depend on admin liveness. `finalize` is also reachable early when `raised >= hard_cap`.
    5. **Bounded emergency cancel.** `cancel_emergency` is admin-only, in-window only, and asserts `raised < hard_cap` and (`soft_cap == 0` or `raised < soft_cap`). Cannot rug a sale that has reached its goal.

#### 6. Why this is better (the delta)

*Source: design artifact — Design Decisions Log*

*Background:* see Design choices — fixed price, round types, compliance for why fixed-price-first, strategic-vs-public, and KYC.

- Improvements over existing solutions
    - **Library, not product.** Issuers compose, not subscribe. Audit is shared infrastructure; UX, KYC vendor, and economics stay with the issuer.
    - **Type-rigorous safety properties.** Receipt non-transferability, vested-allocation hot-potato, typed vault caps, allowlist hot-potato — properties enforced by the type system rather than runtime checks.
    - **Four sale shapes from one primitive.** Public, capped public, strategic, strategic-vested — same lifecycle, four factory wirings.
    - **Vesting policy library-enforced.** Schedule is issuer-defined and pinned on the sale; the library refuses to let the buyer skip it.
    - **Composes with Sui's existing infrastructure.** Vendored linear-with-cliff wallet from `0xNeshi/vesting-wallet`; pluggable compliance module shape; standard `Coin<P>` for payment.
    - **Permissionless close paths.** Finalize and cancel-on-soft-miss don't need admin to be alive.
- Tradeoffs introduced
    - **Pre-funded only in v1.** No `MintingSale<S, P>` flavor yet; issuer must mint and deposit inventory up front.
    - **One payment coin per sale.** Multi-payment is a deployment pattern (multiple sale objects), not a single-sale feature.
    - **Rate is a single u64.** Sale tokens per payment smallest unit, integer ratio only.
    - **Linear-with-cliff vesting only.** Milestone / hybrid / clawback wallet shapes would be sibling library modules; v1 ships one.
    - **Wallet rotation between purchase and claim is not supported.** Receipt is bound to the purchasing address.
    - **Stale receipts pin inventory.** No grace-period sweep in v1 — buyer-protective by design, production decision required.
- What it does NOT solve
    - Bonding curves, dynamic-bonding-curve fair launches, LBPs — different price-discovery primitive (see research subpage).
    - Dutch, English, sealed-bid, or uniform-price auctions.
    - Anti-sniper protection beyond per-buyer cap (a botnet defeats it; tier-windowed allowlist is the planned mitigation).
    - Automatic LP seeding at finalize.
    - Fee model (none in v1; integrator can wrap with a fee module).
    - Token-standard concerns (assumes `Coin<S>` exists with `TreasuryCap<S>` held by issuer).

<aside>

If this is unclear → design is not ready.

</aside>

#### 7. Review readiness

- [x]  Problem is written down
- [ ]  Research artifact exists and has a go/no-go recommendation — *Research page exists; explicit go/no-go to be added (recommend "go: fixed-price first")*
- [x]  Design artifact exists with ownership model decision — README + `sources/` tree
- [ ]  Invariants artifact exists — *inline in §5; standalone doc tracked under open questions*
- [x]  Integration surface is clear (consumer sketch compiles conceptually)
- [x]  Examples compile
- [x]  Examples include happy + failing cases
- [x]  Delta is explicit (why this is better, what it doesn't solve)
- [x]  Open questions listed

#### Open questions / follow-ups

- **Stale-receipt sweep.** v1 is buyer-protective (unclaimed receipts pin inventory/refund funds forever). Production deployers will need one of: accept-the-default, grace-period sweep adapter, or a pre-claim sale flavor. Library exposes no sweep today.
- **`MintingSale<S, P>` for v2.** Mint-on-purchase from a `TreasuryCap<S>` held by the sale. Different audit boundary, same `Receipt<S>` / `Phase`.
- **Tier-windowed allowlist example.** Anti-sniper mitigation; the `AllowEntry` hot-potato hook is already in place, no example wired yet.
- **Standalone invariants artifact.** Move the inline invariants summary into a dedicated doc with formal pre/post conditions per public function.
- **`claim_all_into_vesting` batch helper.** A buyer with multiple receipts on a vested sale today must call `claim_into_vesting + into_*_wallet` per receipt, producing one wallet per receipt. Should we support a batch path that produces one wallet?
- **Fee model.** No fee primitive in v1. Should we ship a thin `fee_module` example, or leave it as integrator territory?
- **Milestone / hybrid / clawback wallet variants.** Each would be a sibling `vested_claim` module with its own audit story.
- **Multi-payment sale.** Currently a deployment pattern (one sale per payment coin). Worth investigating a single-sale multi-asset proceeds shape for v2.

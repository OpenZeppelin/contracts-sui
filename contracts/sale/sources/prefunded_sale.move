/// `PrefundedSale<SaleCoin, PaymentCoin>` — fixed-price token sale, v1 flavor.
///
/// The issuer pre-mints (or pre-acquires) the sale tokens and deposits
/// them as `Balance<SaleCoin>` inventory before activation. The sale draws
/// from that fixed inventory at `claim` time and never holds a
/// `TreasuryCap<SaleCoin>`. v2's `MintingSale<SaleCoin, PaymentCoin>` will be a sibling type
/// that holds a `TreasuryCap<SaleCoin>` instead — same `Receipt<SaleCoin>`, same
/// `Phase`, separate audit boundary.
///
/// ### Lifecycle
///
/// ```text
///   create_sale ──┐
///   deposit_inventory ──┐
///   set_per_buyer_cap   │  (Init phase — sale is owned by caller;
///   pair_refund_vault   ├   holding it by &mut is the authority)
///   enable_allowlist    │
///                       │
///   share_and_activate ─┴──>  (Active phase — sale is shared)
///                                  │
///                              purchase ×N
///                                  │
///                                  ├──> finalize          (permissionless;
///                                  │      claim, withdraw_proceeds,        successful close)
///                                  │      withdraw_unsold_inventory
///                                  │
///                                  ├──> cancel_after_close (permissionless;
///                                  │      refund,                            soft-cap miss)
///                                  │      withdraw_unsold_inventory
///                                  │
///                                  └──> cancel_emergency   (admin-only;
///                                          refund,                            in-window emergency)
///                                          withdraw_unsold_inventory
/// ```
///
/// `Finalized` and `Cancelled` are terminal.
///
/// ### Authority model
///
/// During Init, the caller holds the sale value; that is the only
/// authority needed for setup functions. After `share_and_activate`,
/// the sale is shared and operations split into three categories:
///
/// - **Permissionless:** `purchase`, `claim`, `claim_all`, `refund`,
///   `finalize`, `cancel_after_close`. Buyers and any caller with
///   visibility to the sale can drive these flows once their
///   conditions hold. **Buyer claims and refunds do not depend on
///   admin liveness.**
/// - **Admin-only (via `SaleAdminCap<SaleCoin, PaymentCoin>`):** `cancel_emergency`
///   (in-window), `withdraw_proceeds`, `withdraw_unsold_inventory`.
/// - **None (type-level):** `Receipt<SaleCoin>` cannot be transferred or
///   wrapped; the sale module itself can never mint or destroy
///   receipts outside the `purchase`/`claim`/`refund` paths.
///
/// ### Choosing a sale shape
///
/// The sale supports four orthogonal configuration axes. Each is
/// independent; combine as needed.
///
/// - **Hard cap (required).** `hard_cap > 0` is enforced at
///   `create_sale`. Bounds the maximum raise. `inventory >=
///   hard_cap * rate` is enforced at activation, so sold-out and
///   hard-cap-reached coincide.
/// - **Soft cap (optional, `0 = none`).** Minimum raise required for
///   `finalize`. If the window closes with `raised < soft_cap`,
///   `cancel_after_close` is callable by anyone; refunds become
///   available to all buyers.
/// - **Per-buyer cap (optional).** Cumulative cap on a single buyer's
///   payment to this sale. Enforced inside `purchase` against the
///   running `contributions[buyer]` total. Configure with
///   `set_per_buyer_cap`.
/// - **Allowlist (optional).** Switches the sale into compliance-gated
///   mode: every `purchase` must consume an `AllowEntry<SaleCoin>` minted by
///   the consumer's compliance module. Configure with
///   `enable_allowlist`.
///
/// The three common shapes a fixed-price sale takes:
///
/// | Shape | KYC | Soft cap | Per-buyer cap | Typical use |
/// |---|---|---|---|---|
/// | Public round | no | no | no | Open public sale, FCFS |
/// | Capped public round | no | optional | yes | Anti-whale public sale |
/// | Strategic round | yes | yes | yes | Compliance-gated raise |
///
/// **What this primitive is not:** not a bonding curve, not an LBP,
/// not a Dutch / English / sealed-bid auction, not a fair launch.
/// Those have different mechanics (price discovery, auction clearing)
/// and belong in separate standards.
///
/// ### Integrator footguns
///
/// 1. **All setup must happen before `share_and_activate`.** Setup
///    functions assert `phase == Init`; after activation they abort.
///
/// 2. **`SaleAdminCap<SaleCoin, PaymentCoin>` controls only the admin-only paths.**
///    Wrap it in an RBAC / multisig / governance object. Losing the
///    cap leaves the sale fully usable for buyers — they can still
///    `purchase`, `claim`, `refund`, and trigger `finalize` /
///    `cancel_after_close` permissionlessly — but admin loses
///    emergency-cancel power and the ability to withdraw proceeds
///    and unsold inventory.
///
/// 3. **`AllowlistAdmin<SaleCoin>` controls compliance.** Issued by
///    `enable_allowlist`. Loses-the-key implications: no entries can
///    be minted, every `purchase` aborts. Hold in a recoverable
///    container.
///
/// 4. **Every sale requires a paired `RefundVault<PaymentCoin>`.** Even sales
///    with `soft_cap == 0` need a vault — `cancel_emergency` always
///    has a refund destination. Pair the vault before activation.
///
/// 5. **Receipts are non-transferable and buyer-bound.** A buyer with
///    multiple purchases holds multiple receipts; `claim_all` batches
///    them. Wallet rotation between purchase and redemption is not
///    supported. `claim` and `refund` assert
///    `ctx.sender() == receipt.buyer`.
///
/// 6. **Stale receipts pin both inventory and refund funds.** No
///    grace-period sweep. Buyer-protective by design.
///    - In `Finalized`: an unclaimed receipt keeps its `allocation`
///      pinned in `inventory`. Admin's
///      `withdraw_unsold_inventory` only ever releases the
///      unallocated portion (`inventory - total_allocated`).
///    - In `Cancelled`: an unrefunded receipt keeps both its `paid`
///      amount in the vault's locked balance and its `allocation`
///      counted against `total_allocated`. The vault stays in
///      `Refunding` indefinitely; `withdraw_all` requires `Closed`,
///      which `Cancelled` cannot reach. Buyer's tokens and payment
///      both stay locked until they call `refund`.
module openzeppelin_sale::prefunded_sale;

use openzeppelin_sale::allowlist::{Self, AllowEntry, AllowlistAdmin};
use openzeppelin_sale::refund_vault::{Self, RefundVault, RefundVaultCap};
use openzeppelin_sale::sale::{Self, Phase, Receipt, VestedAllocation};
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::table::{Self, Table};

use fun openzeppelin_sale::sale::consume_receipt as Receipt.consume;

// === Errors ===

// Auth
#[error(code = 10)]
const EWrongAdminCap: vector<u8> = "Admin cap does not match this sale";
#[error(code = 11)]
const EBuyerOnly: vector<u8> =
    "Receipt is bound to its buyer; transaction sender must equal receipt.buyer";
#[error(code = 12)]
const EEmergencyCancelAfterClose: vector<u8> =
    "cancel_emergency can only be called during the active window; use cancel_after_close instead";

// Time
#[error(code = 20)]
const EInvalidTimeRange: vector<u8> = "opens_at_ms must be strictly less than closes_at_ms";
#[error(code = 21)]
const ESaleWindowClosed: vector<u8> = "Purchase outside [opens_at_ms, closes_at_ms]";
#[error(code = 22)]
const ESaleWindowStillOpen: vector<u8> =
    "Cannot close: window still open and hard cap not yet reached";
#[error(code = 23)]
const EActivationAfterClose: vector<u8> = "Cannot activate: closes_at_ms is already in the past";

// Pricing & accounting
#[error(code = 30)]
const ERateZero: vector<u8> = "rate must be greater than zero";
#[error(code = 31)]
const EHardCapZero: vector<u8> = "hard_cap must be greater than zero";
#[error(code = 32)]
const EInvalidCapsOrdering: vector<u8> = "soft_cap must be <= hard_cap";
#[error(code = 33)]
const EZeroPayment: vector<u8> = "Payment must be greater than zero";
#[error(code = 34)]
const EAllocationOverflow: vector<u8> = "payment * rate overflows u64";
#[error(code = 35)]
const ERaisedOverflow: vector<u8> = "raised + payment overflows u64";
#[error(code = 36)]
const EContributionOverflow: vector<u8> = "buyer contribution + payment overflows u64";
#[error(code = 37)]
const EHardCapExceeded: vector<u8> = "Purchase would exceed hard_cap";
#[error(code = 38)]
const EInventoryOverflowAtActivate: vector<u8> =
    "hard_cap * rate overflows u64; cannot guarantee inventory backing";
#[error(code = 39)]
const EInsufficientInventoryAtActivate: vector<u8> =
    "Inventory at activation does not cover hard_cap * rate";

// Caps
#[error(code = 40)]
const EPerBuyerCapExceeded: vector<u8> = "Purchase exceeds per-buyer cap";
#[error(code = 41)]
const EPerEntryCapExceeded: vector<u8> = "Purchase exceeds AllowEntry max_amount";
#[error(code = 42)]
const ESoftCapNotMet: vector<u8> = "Cannot finalize: raised < soft_cap";
#[error(code = 43)]
const ESoftCapMet: vector<u8> = "Cannot cancel: soft_cap already met or no soft_cap configured";
#[error(code = 44)]
const ESaleAlreadyComplete: vector<u8> =
    "Cannot cancel: hard_cap already reached, sale must finalize";

// Allowlist coupling
#[error(code = 50)]
const EAllowlistRequired: vector<u8> = "Sale requires AllowEntry but none provided";
#[error(code = 51)]
const EAllowlistNotRequired: vector<u8> = "Sale does not require AllowEntry but one was provided";
#[error(code = 52)]
const EAllowlistAlreadyEnabled: vector<u8> = "Allowlist already enabled for this sale";

// Vault coupling
#[error(code = 60)]
const EVaultAlreadyPaired: vector<u8> = "Refund vault already paired";
#[error(code = 61)]
const EVaultRequiredForActivate: vector<u8> = "Activation requires a paired refund vault";
#[error(code = 62)]
const EWrongVault: vector<u8> = "Provided vault does not match the one paired with this sale";
#[error(code = 63)]
const EVaultNotActive: vector<u8> = "Refund vault must be in Active state when paired";
#[error(code = 64)]
const EVaultNotEmpty: vector<u8> =
    "Refund vault must be empty (value == 0) when paired; pre-existing funds would be stranded after finalize/cancel";

// Receipts
#[error(code = 70)]
const EReceiptSaleMismatch: vector<u8> = "Receipt does not belong to this sale";

// Per-buyer cap configuration
#[error(code = 80)]
const EPerBuyerCapAlreadySet: vector<u8> = "Per-buyer cap already configured";
#[error(code = 81)]
const EPerBuyerCapZero: vector<u8> =
    "Per-buyer cap must be greater than zero (a zero cap blocks every buyer)";

// Vesting schedule configuration
#[error(code = 90)]
const EVestingScheduleAlreadySet: vector<u8> = "Vesting schedule already configured";
#[error(code = 91)]
const EClaimRequiresVesting: vector<u8> =
    "Sale has a vesting schedule; redeem via claim_into_vesting + vested_claim, not plain claim";
#[error(code = 92)]
const ENoVestingScheduleAttached: vector<u8> =
    "Sale has no vesting schedule; use claim instead of claim_into_vesting";

// === Types ===

public struct PrefundedSale<phantom SaleCoin, phantom PaymentCoin, ScheduleParams: copy> has key {
    id: UID,
    // Inventory & accounting
    /// Pre-funded sale tokens. Deposited during Init, drawn down on claim.
    inventory: Balance<SaleCoin>,
    /// Allocations promised to outstanding receipts.
    /// Invariant: `inventory.value() >= total_allocated`. The
    /// `inventory.value() - total_allocated` remainder is the
    /// "unallocated" portion `withdraw_unsold_inventory` returns.
    total_allocated: u64,
    /// Accumulated payments. Drained to admin on `withdraw_proceeds`
    /// (Finalized) or to the vault on cancel (Cancelled).
    proceeds: Balance<PaymentCoin>,
    // Pricing
    /// Sale tokens (smallest units) per 1 payment-coin smallest unit.
    rate: u64,
    // Caps
    hard_cap: u64, // > 0; enforced at create_sale
    soft_cap: u64, // 0 = no soft cap; otherwise <= hard_cap
    raised: u64,
    // Time
    opens_at_ms: u64,
    closes_at_ms: u64,
    // Lifecycle
    phase: Phase,
    // Hooks
    requires_allowlist: bool,
    /// Paired vault ID. Always Some after activation.
    refund_vault_id: Option<ID>,
    /// Wrapped vault controller. Sale's lifecycle drives vault state;
    /// the cap never returns out of the sale.
    refund_vault_cap: Option<RefundVaultCap<PaymentCoin>>,
    // Optional per-buyer cap (lazy table)
    per_buyer_cap: Option<u64>,
    contributions: Option<Table<address, u64>>,
    /// Optional issuer-defined vesting policy. When `Some`, the plain
    /// `claim` path aborts (`EClaimRequiresVesting`) and the only
    /// redemption route is `claim_into_vesting` → a library consumer
    /// (`vested_claim::into_*`). The buyer cannot influence the
    /// schedule — it is fixed at sale construction.
    vesting_schedule_params: Option<ScheduleParams>,
}

public struct SaleAdminCap<phantom SaleCoin, phantom PaymentCoin> has key, store {
    id: UID,
    sale_id: ID,
}

// === Events ===

public struct SaleCreated<phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    rate: u64,
    hard_cap: u64,
    soft_cap: u64,
    opens_at_ms: u64,
    closes_at_ms: u64,
}

public struct InventoryDeposited<phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    amount: u64,
    inventory_after: u64,
}

public struct PerBuyerCapSet<phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    cap: u64,
}

public struct VestingScheduleParamsSet<
    phantom SaleCoin,
    phantom PaymentCoin,
    ScheduleParams: copy + drop,
> has copy, drop {
    sale_id: ID,
    params: ScheduleParams,
}

public struct RefundVaultPaired<phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    vault_id: ID,
}

public struct AllowlistEnabled<phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    allowlist_admin_id: ID,
}

public struct SaleActivated<phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    activated_at_ms: u64,
}

public struct Purchased<phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    buyer: address,
    receipt_id: ID,
    paid: u64,
    allocation: u64,
    raised_after: u64,
    purchased_at_ms: u64,
}

public struct SaleFinalized<phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    raised: u64,
    closed_at_ms: u64,
}

public enum CancelReason has copy, drop, store {
    SoftCapMissed,
    AdminEmergency,
}

public struct SaleCancelled<phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    raised: u64,
    reason: CancelReason,
    closed_at_ms: u64,
}

public struct Claimed<phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    buyer: address,
    receipt_id: ID,
    amount: u64,
}

public struct Refunded<phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    buyer: address,
    receipt_id: ID,
    amount: u64,
}

public struct ProceedsWithdrawn<phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    amount: u64,
}

public struct InventoryWithdrawn<phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    amount: u64,
}

// === Internal helpers ===

fun assert_admin<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
    cap: &SaleAdminCap<SaleCoin, PaymentCoin>,
) {
    assert!(cap.sale_id == object::id(sale), EWrongAdminCap);
}

fun assert_sender_is_buyer<SaleCoin>(receipt: &Receipt<SaleCoin>, ctx: &TxContext) {
    assert!(receipt.buyer() == ctx.sender(), EBuyerOnly);
}

// === Setup (Phase: Init) ===

/// Create a sale in `Init` phase. Returns the sale as an owned value
/// plus its admin cap. The caller threads the sale through setup
/// calls in the same PTB and then calls `share_and_activate` to
/// transition to `Active`.
///
/// Asserts:
/// - `rate > 0`
/// - `hard_cap > 0` (every sale must have a bounded raise)
/// - `soft_cap <= hard_cap`
/// - `opens_at_ms < closes_at_ms`
public fun create_sale<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    rate: u64,
    hard_cap: u64,
    soft_cap: u64,
    opens_at_ms: u64,
    closes_at_ms: u64,
    ctx: &mut TxContext,
): (PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>, SaleAdminCap<SaleCoin, PaymentCoin>) {
    assert!(rate > 0, ERateZero);
    assert!(hard_cap > 0, EHardCapZero);
    assert!(soft_cap <= hard_cap, EInvalidCapsOrdering);
    assert!(opens_at_ms < closes_at_ms, EInvalidTimeRange);

    let sale = PrefundedSale {
        id: object::new(ctx),
        inventory: balance::zero<SaleCoin>(),
        total_allocated: 0,
        proceeds: balance::zero<PaymentCoin>(),
        rate,
        hard_cap,
        soft_cap,
        raised: 0,
        opens_at_ms,
        closes_at_ms,
        phase: sale::phase_init(),
        requires_allowlist: false,
        refund_vault_id: option::none(),
        refund_vault_cap: option::none(),
        per_buyer_cap: option::none(),
        contributions: option::none(),
        vesting_schedule_params: option::none(),
    };
    let sale_id = object::id(&sale);
    let cap = SaleAdminCap<SaleCoin, PaymentCoin> { id: object::new(ctx), sale_id };

    event::emit(SaleCreated<SaleCoin, PaymentCoin> {
        sale_id,
        rate,
        hard_cap,
        soft_cap,
        opens_at_ms,
        closes_at_ms,
    });

    (sale, cap)
}

/// Deposit sale tokens into inventory. May be called multiple times
/// during Init. Authority is implicit: the sale is owned, so only the
/// caller that created it can pass it as `&mut`.
public fun deposit_inventory<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
    inventory: Coin<SaleCoin>,
) {
    sale.phase.assert_init();
    let amount = inventory.value();
    sale.inventory.join(inventory.into_balance());
    event::emit(InventoryDeposited<SaleCoin, PaymentCoin> {
        sale_id: object::id(sale),
        amount,
        inventory_after: sale.inventory.value(),
    });
}

/// Configure a cumulative per-buyer cap.
///
/// Per-buyer means the sum of every `purchase` payment a single
/// buyer makes to this sale must not exceed `per_buyer_cap`.
/// Enforced inside `purchase` against the running
/// `contributions[buyer]` total.
///
/// Asserts:
/// - `per_buyer_cap > 0` (a zero cap would block every purchase).
/// - Not already configured (`set_per_buyer_cap` is one-shot).
public fun set_per_buyer_cap<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
    per_buyer_cap: u64,
    ctx: &mut TxContext,
) {
    sale.phase.assert_init();
    assert!(sale.per_buyer_cap.is_none(), EPerBuyerCapAlreadySet);
    assert!(per_buyer_cap > 0, EPerBuyerCapZero);
    sale.per_buyer_cap.fill(per_buyer_cap);
    sale.contributions.fill(table::new<address, u64>(ctx));
    event::emit(PerBuyerCapSet<SaleCoin, PaymentCoin> {
        sale_id: object::id(sale),
        cap: per_buyer_cap,
    });
}

/// Configure the sale's vesting policy. One-shot, Init-phase only.
/// `start_ms`, `cliff_duration_ms`, and `duration_ms` are validated
/// by `sale::new_vesting_schedule` (duration > 0, cliff <= duration,
/// no `start_ms + duration_ms` overflow).
///
/// Once a schedule is attached, the plain `claim` path aborts and
/// buyers must redeem through `claim_into_vesting` → a
/// `vested_claim::into_*` consumer. The library enforces this so a
/// buyer cannot trivially bypass the schedule. The schedule is
/// **issuer-defined**: the buyer is the caller of the redemption
/// path and cannot supply or override these values.
public fun set_vesting_schedule_params<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
    params: ScheduleParams,
) {
    sale.phase.assert_init();
    assert!(sale.vesting_schedule_params.is_none(), EVestingScheduleAlreadySet);
    sale.vesting_schedule_params.fill(params);
    event::emit(VestingScheduleParamsSet<SaleCoin, PaymentCoin, ScheduleParams> {
        sale_id: object::id(sale),
        params,
    });
}

/// Pair a refund vault with the sale. Required before activation.
///
/// The vault is taken by reference (for state inspection) and the
/// cap by value (consumed into the sale).
///
/// Asserts:
/// - `cap.vault_id == object::id(vault)`.
/// - Vault is in `Active` state.
/// - **Vault is empty** (`value(vault) == 0`). Pre-existing funds
///   would be stranded: the cap is wrapped into the sale, the sale
///   never exposes a way to withdraw arbitrary vault funds, and
///   `withdraw_all` requires `Closed` (reachable only via the sale's
///   `finalize`, which does not return the cap).
/// - No prior vault has been paired.
public fun pair_refund_vault<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
    vault: &RefundVault<PaymentCoin>,
    vault_cap: RefundVaultCap<PaymentCoin>,
) {
    sale.phase.assert_init();
    assert!(sale.refund_vault_cap.is_none(), EVaultAlreadyPaired);
    assert!(vault_cap.cap_vault_id() == object::id(vault), EWrongVault);
    assert!(vault.is_active(), EVaultNotActive);
    assert!(vault.value() == 0, EVaultNotEmpty);

    let vault_id = object::id(vault);
    sale.refund_vault_id.fill(vault_id);
    sale.refund_vault_cap.fill(vault_cap);
    event::emit(RefundVaultPaired<SaleCoin, PaymentCoin> {
        sale_id: object::id(sale),
        vault_id,
    });
}

/// Switch the sale into compliance-gated mode and issue the
/// `AllowlistAdmin<SaleCoin>`. The caller wraps the admin inside the
/// compliance module of their choice.
///
/// One-shot: aborts if called twice on the same sale. Duplicate
/// admins would let two compliance modules mint entries
/// independently for the same sale, defeating the gating.
public fun enable_allowlist<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
    ctx: &mut TxContext,
): AllowlistAdmin<SaleCoin> {
    sale.phase.assert_init();
    assert!(!sale.requires_allowlist, EAllowlistAlreadyEnabled);
    sale.requires_allowlist = true;
    let sale_id = object::id(sale);
    let admin = allowlist::new_admin<SaleCoin>(sale_id, ctx);
    event::emit(AllowlistEnabled<SaleCoin, PaymentCoin> {
        sale_id,
        allowlist_admin_id: object::id(&admin),
    });
    admin
}

/// Transition `Init → Active` and share the sale.
///
/// Asserts:
/// - A refund vault has been paired (every sale requires one).
/// - `inventory >= hard_cap * rate` (u128-checked for overflow).
///   Sold-out and hard-cap-reached therefore coincide; `purchase`
///   never aborts with "out of inventory" before "exceeds cap".
/// - `now < closes_at_ms`. Activating after the window has elapsed
///   would share a stale sale that immediately becomes finalizable
///   or cancellable with no purchase opportunity. Activation before
///   `opens_at_ms` is allowed.
public fun share_and_activate<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    mut sale: PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
    clock: &Clock,
) {
    sale.phase.assert_init();
    assert!(sale.refund_vault_cap.is_some(), EVaultRequiredForActivate);

    let required = (sale.hard_cap as u128) * (sale.rate as u128);
    assert!(required <= std::u64::max_value!() as u128, EInventoryOverflowAtActivate);
    let required = required as u64;
    assert!(sale.inventory.value() >= required, EInsufficientInventoryAtActivate);

    let activated_at_ms = clock::timestamp_ms(clock);
    assert!(activated_at_ms < sale.closes_at_ms, EActivationAfterClose);

    sale.phase.activate();
    let sale_id = object::id(&sale);
    transfer::share_object(sale);
    event::emit(SaleActivated<SaleCoin, PaymentCoin> { sale_id, activated_at_ms });
}

// === Active phase ===

/// Buy sale tokens. Delivers a fresh `Receipt<SaleCoin>` to `ctx.sender()`
/// (the buyer). Payment is added to `sale.proceeds`.
///
/// `allow` must be `Some` iff `requires_allowlist == true`. The
/// entry is consumed; its `sale_id` and `buyer` are asserted.
///
/// All arithmetic on user-controlled inputs (`raised + paid`,
/// `contribution + paid`, `paid * rate`) is widened to `u128` and
/// bounds-checked before downcasting, so oversized payments abort
/// with a typed error rather than the default arithmetic overflow.
public fun purchase<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
    payment: Coin<PaymentCoin>,
    allow: Option<AllowEntry<SaleCoin>>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Phase + time
    sale.phase.assert_active();
    let now = clock::timestamp_ms(clock);
    assert!(now >= sale.opens_at_ms && now <= sale.closes_at_ms, ESaleWindowClosed);

    // Allowlist gate
    let buyer = ctx.sender();
    let entry_max = if (sale.requires_allowlist) {
        assert!(allow.is_some(), EAllowlistRequired);
        let entry = allow.destroy_some();
        entry.consume(object::id(sale), buyer)
    } else {
        assert!(allow.is_none(), EAllowlistNotRequired);
        allow.destroy_none();
        0
    };

    // Hard cap (u128-widened)
    let paid = payment.value();
    assert!(paid > 0, EZeroPayment);
    let u64_max = std::u64::max_value!();
    assert!(u64_max - paid >= sale.raised, ERaisedOverflow);
    let new_raised = sale.raised + paid;
    assert!(new_raised <= sale.hard_cap, EHardCapExceeded);

    // Per-entry cap
    assert!(entry_max == 0 || paid <= entry_max, EPerEntryCapExceeded);

    // Per-buyer cap (u128-widened)
    if (sale.per_buyer_cap.is_some()) {
        let per_cap = *sale.per_buyer_cap.borrow();
        let contribs = sale.contributions.borrow_mut();
        let current = if (contribs.contains(buyer)) {
            *contribs.borrow(buyer)
        } else { 0 };
        assert!(u64_max - paid >= current, EContributionOverflow);
        let new_total = current + paid;
        assert!(new_total <= per_cap, EPerBuyerCapExceeded);
        if (contribs.contains(buyer)) {
            let slot = contribs.borrow_mut(buyer);
            *slot = new_total;
        } else {
            contribs.add(buyer, new_total);
        };
    };

    // Allocation + inventory backing (u128-checked)
    let allocation = (paid as u128) * (sale.rate as u128);
    assert!(allocation <= u64_max as u128, EAllocationOverflow);
    let allocation = allocation as u64;
    let unallocated = sale.inventory.value() - sale.total_allocated;
    assert!(allocation <= unallocated, EInsufficientInventoryAtActivate);

    // State mutations
    sale.total_allocated = sale.total_allocated + allocation;
    sale.raised = new_raised;
    sale.proceeds.join(payment.into_balance());

    // Mint and deliver receipt
    let sale_id = object::id(sale);
    let receipt = sale::new_receipt<SaleCoin>(sale_id, buyer, paid, allocation, now, ctx);
    let receipt_id = object::id(&receipt);
    sale::deliver_receipt(receipt, buyer);

    event::emit(Purchased<SaleCoin, PaymentCoin> {
        sale_id,
        buyer,
        receipt_id,
        paid,
        allocation,
        raised_after: sale.raised,
        purchased_at_ms: now,
    });
}

// === Closing ===

/// Close the sale as a success. **Permissionless.** Also transitions
/// the paired vault to `Closed` in the same call.
///
/// Allowed when phase is `Active` and either:
/// - `now > closes_at_ms` and `raised >= soft_cap`, or
/// - `raised >= hard_cap` (sold-out — closes early).
public fun finalize<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
    vault: &mut RefundVault<PaymentCoin>,
    clock: &Clock,
) {
    sale.phase.assert_active();
    let now = clock::timestamp_ms(clock);
    let window_closed = now > sale.closes_at_ms;
    let hard_cap_reached = sale.raised >= sale.hard_cap;
    assert!(window_closed || hard_cap_reached, ESaleWindowStillOpen);
    assert!(sale.raised >= sale.soft_cap, ESoftCapNotMet);

    let paired_id = *sale.refund_vault_id.borrow();
    assert!(object::id(vault) == paired_id, EWrongVault);

    // Synchronize vault state with the sale's terminal phase.
    {
        let cap_ref = sale.refund_vault_cap.borrow();
        vault.flip_to_closed(cap_ref);
    };

    sale.phase.finalize();
    event::emit(SaleFinalized<SaleCoin, PaymentCoin> {
        sale_id: object::id(sale),
        raised: sale.raised,
        closed_at_ms: now,
    });
}

/// Close the sale as a soft-cap miss. **Permissionless.**
///
/// Allowed when phase is `Active`, `now > closes_at_ms`,
/// `soft_cap > 0`, and `raised < soft_cap`. Drains `sale.proceeds`
/// into the paired vault and flips vault to `Refunding`. Buyers then
/// call `refund` individually.
public fun cancel_after_close<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
    vault: &mut RefundVault<PaymentCoin>,
    clock: &Clock,
) {
    sale.phase.assert_active();
    let now = clock::timestamp_ms(clock);
    assert!(now > sale.closes_at_ms, ESaleWindowStillOpen);
    assert!(sale.soft_cap > 0 && sale.raised < sale.soft_cap, ESoftCapMet);

    sale.do_cancel(vault, CancelReason::SoftCapMissed, now);
}

/// Emergency cancellation. **Admin-only.**
///
/// Allowed when phase is `Active` and the window has not yet closed
/// (`now <= closes_at_ms`). Pre-open cancel (`now < opens_at_ms`) is
/// permitted — useful when a bug or compliance issue is discovered
/// before any purchase has happened.
///
/// Guards (designed to prevent rugging a successful sale):
/// - `raised < hard_cap`. A sold-out sale must `finalize`.
/// - `soft_cap == 0` OR `raised < soft_cap`. A sale that has reached
///   its goal must `finalize`; admin cannot cancel it to force
///   refunds.
///
/// Drains `sale.proceeds` into the vault and flips vault to
/// `Refunding`.
public fun cancel_emergency<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
    cap: &SaleAdminCap<SaleCoin, PaymentCoin>,
    vault: &mut RefundVault<PaymentCoin>,
    clock: &Clock,
) {
    assert_admin(sale, cap);
    sale.phase.assert_active();
    let now = clock::timestamp_ms(clock);
    assert!(now <= sale.closes_at_ms, EEmergencyCancelAfterClose);
    assert!(sale.raised < sale.hard_cap, ESaleAlreadyComplete);
    assert!(sale.soft_cap == 0 || sale.raised < sale.soft_cap, ESoftCapMet);

    sale.do_cancel(vault, CancelReason::AdminEmergency, now);
}

/// Shared body of `cancel_after_close` and `cancel_emergency`.
fun do_cancel<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
    vault: &mut RefundVault<PaymentCoin>,
    reason: CancelReason,
    now: u64,
) {
    let paired_id = *sale.refund_vault_id.borrow();
    assert!(object::id(vault) == paired_id, EWrongVault);

    let amount = sale.proceeds.value();
    let proceeds_balance = sale.proceeds.split(amount);
    {
        let cap_ref = sale.refund_vault_cap.borrow();
        vault.deposit(cap_ref, proceeds_balance);
        vault.flip_to_refunding(cap_ref);
    };

    sale.phase.cancel();

    event::emit(SaleCancelled<SaleCoin, PaymentCoin> {
        sale_id: object::id(sale),
        raised: sale.raised,
        reason,
        closed_at_ms: now,
    });
}

// === Success path (Finalized) ===

/// Redeem a receipt for `Coin<SaleCoin>`. Asserts
/// `ctx.sender() == receipt.buyer`. Destroys the receipt.
///
/// Aborts with `EClaimRequiresVesting` if the sale has a vesting
/// schedule attached — vested sales must redeem via
/// `claim_into_vesting`. This is the library's enforcement that the
/// schedule cannot be bypassed by calling the immediate-distribution
/// path.
public fun claim<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
    receipt: Receipt<SaleCoin>,
    ctx: &mut TxContext,
): Coin<SaleCoin> {
    sale.phase.assert_finalized();
    assert!(sale.vesting_schedule_params.is_none(), EClaimRequiresVesting);
    assert!(receipt.sale_id() == object::id(sale), EReceiptSaleMismatch);
    assert_sender_is_buyer(&receipt, ctx);

    let receipt_id = object::id(&receipt);
    let (_sale_id, buyer, _paid, allocation, _ts) = receipt.consume();

    sale.total_allocated = sale.total_allocated - allocation;
    let payout = sale.inventory.split(allocation);

    event::emit(Claimed<SaleCoin, PaymentCoin> {
        sale_id: object::id(sale),
        buyer,
        receipt_id,
        amount: allocation,
    });

    coin::from_balance(payout, ctx)
}

/// Batch helper: claim several receipts in one call. Asserts
/// `ctx.sender() == receipt.buyer` on each. Aborts the whole call
/// if any receipt is invalid. Inherits the no-vesting guard from
/// `claim`.
public fun claim_all<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
    mut receipts: vector<Receipt<SaleCoin>>,
    ctx: &mut TxContext,
): Coin<SaleCoin> {
    let mut total = coin::zero<SaleCoin>(ctx);
    while (!receipts.is_empty()) {
        let r = receipts.pop_back();
        total.join(sale.claim(r, ctx));
    };
    receipts.destroy_empty();
    total
}

/// Redeem a receipt into a `VestedAllocation<SaleCoin, ScheduleParams>` hot-potato. The only
/// redemption path for a vesting-attached sale; aborts with
/// `ENoVestingScheduleAttached` if no schedule is set (use `claim`
/// instead).
///
/// The returned `VestedAllocation<SaleCoin, ScheduleParams>` has no `drop`, `key`, or `store`
/// ability and its fields are private to `sale.move`, so the caller
/// cannot stash it, discard it, or extract the raw `Coin<SaleCoin>`. The
/// only consumer paths live in `vested_claim`, which route the coin
/// into a `VestingWallet<SaleCoin>` matching the sale's schedule.
///
/// Asserts `ctx.sender() == receipt.buyer` (same buyer-binding rule
/// as `claim`). Destroys the receipt.
public fun claim_into_vesting<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
    receipt: Receipt<SaleCoin>,
    ctx: &mut TxContext,
): VestedAllocation<SaleCoin, ScheduleParams> {
    sale.phase.assert_finalized();
    assert!(sale.vesting_schedule_params.is_some(), ENoVestingScheduleAttached);
    assert!(receipt.sale_id() == object::id(sale), EReceiptSaleMismatch);
    assert_sender_is_buyer(&receipt, ctx);

    let receipt_id = object::id(&receipt);
    let (_sale_id, buyer, _paid, allocation, _ts) = receipt.consume_receipt();

    sale.total_allocated = sale.total_allocated - allocation;
    let payout = sale.inventory.split(allocation);
    let coin = coin::from_balance(payout, ctx);

    let schedule = *sale.vesting_schedule_params.borrow();
    let sale_id = object::id(sale);

    event::emit(Claimed<SaleCoin, PaymentCoin> {
        sale_id,
        buyer,
        receipt_id,
        amount: allocation,
    });

    sale::new_vested_allocation(coin, schedule, buyer, sale_id)
}

/// Withdraw collected proceeds. Phase must be `Finalized`.
public fun withdraw_proceeds<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
    cap: &SaleAdminCap<SaleCoin, PaymentCoin>,
    ctx: &mut TxContext,
): Coin<PaymentCoin> {
    assert_admin(sale, cap);
    sale.phase.assert_finalized();
    let amount = sale.proceeds.value();
    let part = sale.proceeds.split(amount);
    event::emit(ProceedsWithdrawn<SaleCoin, PaymentCoin> {
        sale_id: object::id(sale),
        amount,
    });
    coin::from_balance(part, ctx)
}

/// Withdraw unallocated inventory. Valid in `Finalized` or
/// `Cancelled`. Strictly the unreserved portion
/// (`inventory - total_allocated`); outstanding receipts remain
/// backed.
public fun withdraw_unsold_inventory<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
    cap: &SaleAdminCap<SaleCoin, PaymentCoin>,
    ctx: &mut TxContext,
): Coin<SaleCoin> {
    assert_admin(sale, cap);
    sale.phase.assert_finalized();
    let unallocated = sale.inventory.value() - sale.total_allocated;
    let part = sale.inventory.split(unallocated);
    event::emit(InventoryWithdrawn<SaleCoin, PaymentCoin> {
        sale_id: object::id(sale),
        amount: unallocated,
    });
    coin::from_balance(part, ctx)
}

// === Failure path (Cancelled) ===

/// Refund a buyer's payment. Asserts
/// `ctx.sender() == receipt.buyer`. Destroys the receipt and pays
/// `receipt.paid` worth of `Coin<PaymentCoin>` out of the paired vault.
public fun refund<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
    vault: &mut RefundVault<PaymentCoin>,
    receipt: Receipt<SaleCoin>,
    ctx: &mut TxContext,
): Coin<PaymentCoin> {
    sale.phase.assert_cancelled();
    assert!(receipt.sale_id() == object::id(sale), EReceiptSaleMismatch);
    assert_sender_is_buyer(&receipt, ctx);
    let paired_vault_id = *sale.refund_vault_id.borrow();
    assert!(object::id(vault) == paired_vault_id, EWrongVault);

    let receipt_id = object::id(&receipt);
    let (_sale_id, buyer, paid, allocation, _ts) = receipt.consume();

    sale.total_allocated = sale.total_allocated - allocation;

    let payment = {
        let cap_ref = sale.refund_vault_cap.borrow();
        vault.release_balance(cap_ref, paid)
    };

    event::emit(Refunded<SaleCoin, PaymentCoin> {
        sale_id: object::id(sale),
        buyer,
        receipt_id,
        amount: paid,
    });

    coin::from_balance(payment, ctx)
}

// === Views ===

public fun phase<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
): Phase {
    sale.phase
}

public fun raised<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
): u64 {
    sale.raised
}

public fun rate<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
): u64 { sale.rate }

public fun hard_cap<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
): u64 {
    sale.hard_cap
}

public fun soft_cap<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
): u64 {
    sale.soft_cap
}

public fun opens_at_ms<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
): u64 {
    sale.opens_at_ms
}

public fun closes_at_ms<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
): u64 {
    sale.closes_at_ms
}

public fun requires_allowlist<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
): bool { sale.requires_allowlist }

/// Read the sale's vesting schedule. Returns `Some(schedule)` if the
/// issuer called `set_vesting_schedule_params` during Init, otherwise `None`.
/// Vesting adapters read this to determine the redemption shape.
public fun vesting_schedule_params<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
): Option<ScheduleParams> {
    sale.vesting_schedule_params
}

public fun inventory_total<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
): u64 {
    sale.inventory.value()
}

public fun total_allocated<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
): u64 {
    sale.total_allocated
}

public fun inventory_remaining<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
): u64 {
    sale.inventory.value() - sale.total_allocated
}

public fun proceeds_amount<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
): u64 {
    sale.proceeds.value()
}

public fun is_open<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
    clock: &Clock,
): bool {
    if (!sale.phase.is_active()) { return false };
    let now = clock::timestamp_ms(clock);
    now >= sale.opens_at_ms && now <= sale.closes_at_ms
}

public fun has_reached_soft_cap<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
): bool {
    sale.raised >= sale.soft_cap
}

public fun has_reached_hard_cap<SaleCoin, PaymentCoin, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<SaleCoin, PaymentCoin, ScheduleParams>,
): bool {
    sale.raised >= sale.hard_cap
}

public fun cap_sale_id<SaleCoin, PaymentCoin>(c: &SaleAdminCap<SaleCoin, PaymentCoin>): ID {
    c.sale_id
}

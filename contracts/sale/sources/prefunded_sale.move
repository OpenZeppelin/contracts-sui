/// `PrefundedSale<S, P>` — fixed-price token sale, v1 flavor.
///
/// The issuer pre-mints (or pre-acquires) the sale tokens and deposits
/// them as `Balance<S>` inventory before activation. The sale draws
/// from that fixed inventory at `claim` time and never holds a
/// `TreasuryCap<S>`. v2's `MintingSale<S, P>` will be a sibling type
/// that holds a `TreasuryCap<S>` instead — same `Receipt<S>`, same
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
/// - **Admin-only (via `SaleAdminCap<S, P>`):** `cancel_emergency`
///   (in-window), `withdraw_proceeds`, `withdraw_unsold_inventory`.
/// - **None (type-level):** `Receipt<S>` cannot be transferred or
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
///   mode: every `purchase` must consume an `AllowEntry<S>` minted by
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
/// 2. **`SaleAdminCap<S, P>` controls only the admin-only paths.**
///    Wrap it in an RBAC / multisig / governance object. Losing the
///    cap leaves the sale fully usable for buyers — they can still
///    `purchase`, `claim`, `refund`, and trigger `finalize` /
///    `cancel_after_close` permissionlessly — but admin loses
///    emergency-cancel power and the ability to withdraw proceeds
///    and unsold inventory.
///
/// 3. **`AllowlistAdmin<S>` controls compliance.** Issued by
///    `enable_allowlist`. Loses-the-key implications: no entries can
///    be minted, every `purchase` aborts. Hold in a recoverable
///    container.
///
/// 4. **Every sale requires a paired `RefundVault<P>`.** Even sales
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

// === Errors ===

// Phase guards
#[error(code = 0)]
const ENotInit: vector<u8> = "Sale must be in Init phase";
#[error(code = 1)]
const ENotActive: vector<u8> = "Sale must be in Active phase";
#[error(code = 2)]
const ENotFinalized: vector<u8> = "Sale must be in Finalized phase";
#[error(code = 3)]
const ENotCancelled: vector<u8> = "Sale must be in Cancelled phase";
#[error(code = 4)]
const ENotTerminal: vector<u8> = "Sale must be in a terminal phase (Finalized or Cancelled)";

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

public struct PrefundedSale<phantom S, phantom P, ScheduleParams: copy> has key {
    id: UID,
    // Inventory & accounting
    /// Pre-funded sale tokens. Deposited during Init, drawn down on claim.
    inventory: Balance<S>,
    /// Allocations promised to outstanding receipts.
    /// Invariant: `inventory.value() >= total_allocated`. The
    /// `inventory.value() - total_allocated` remainder is the
    /// "unallocated" portion `withdraw_unsold_inventory` returns.
    total_allocated: u64,
    /// Accumulated payments. Drained to admin on `withdraw_proceeds`
    /// (Finalized) or to the vault on cancel (Cancelled).
    proceeds: Balance<P>,
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
    refund_vault_cap: Option<RefundVaultCap<P>>,
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

public struct SaleAdminCap<phantom S, phantom P> has key, store {
    id: UID,
    sale_id: ID,
}

// === Events ===

public struct SaleCreated<phantom S, phantom P> has copy, drop {
    sale_id: ID,
    rate: u64,
    hard_cap: u64,
    soft_cap: u64,
    opens_at_ms: u64,
    closes_at_ms: u64,
}

public struct InventoryDeposited<phantom S, phantom P> has copy, drop {
    sale_id: ID,
    amount: u64,
    inventory_after: u64,
}

public struct PerBuyerCapSet<phantom S, phantom P> has copy, drop {
    sale_id: ID,
    cap: u64,
}

public struct VestingScheduleParamsSet<phantom S, phantom P, ScheduleParams: copy> has copy, drop {
    sale_id: ID,
    params: ScheduleParams,
}

public struct RefundVaultPaired<phantom S, phantom P> has copy, drop {
    sale_id: ID,
    vault_id: ID,
}

public struct AllowlistEnabled<phantom S, phantom P> has copy, drop {
    sale_id: ID,
    allowlist_admin_id: ID,
}

public struct SaleActivated<phantom S, phantom P> has copy, drop {
    sale_id: ID,
    activated_at_ms: u64,
}

public struct Purchased<phantom S, phantom P> has copy, drop {
    sale_id: ID,
    buyer: address,
    receipt_id: ID,
    paid: u64,
    allocation: u64,
    raised_after: u64,
    purchased_at_ms: u64,
}

public struct SaleFinalized<phantom S, phantom P> has copy, drop {
    sale_id: ID,
    raised: u64,
    closed_at_ms: u64,
}

public enum CancelReason has copy, drop, store {
    SoftCapMissed,
    AdminEmergency,
}

public struct SaleCancelled<phantom S, phantom P> has copy, drop {
    sale_id: ID,
    raised: u64,
    reason: CancelReason,
    closed_at_ms: u64,
}

public struct Claimed<phantom S, phantom P> has copy, drop {
    sale_id: ID,
    buyer: address,
    receipt_id: ID,
    amount: u64,
}

public struct Refunded<phantom S, phantom P> has copy, drop {
    sale_id: ID,
    buyer: address,
    receipt_id: ID,
    amount: u64,
}

public struct ProceedsWithdrawn<phantom S, phantom P> has copy, drop {
    sale_id: ID,
    amount: u64,
}

public struct InventoryWithdrawn<phantom S, phantom P> has copy, drop {
    sale_id: ID,
    amount: u64,
}

// === Internal helpers ===

const U64_MAX: u128 = 18446744073709551615;

fun assert_admin<S, P, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<S, P, ScheduleParams>,
    cap: &SaleAdminCap<S, P>,
) {
    assert!(cap.sale_id == object::id(sale), EWrongAdminCap);
}

fun assert_sender_is_buyer<S>(receipt: &Receipt<S>, ctx: &TxContext) {
    assert!(sale::receipt_buyer(receipt) == ctx.sender(), EBuyerOnly);
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
public fun create_sale<S, P, ScheduleParams: copy + drop + store>(
    rate: u64,
    hard_cap: u64,
    soft_cap: u64,
    opens_at_ms: u64,
    closes_at_ms: u64,
    ctx: &mut TxContext,
): (PrefundedSale<S, P, ScheduleParams>, SaleAdminCap<S, P>) {
    assert!(rate > 0, ERateZero);
    assert!(hard_cap > 0, EHardCapZero);
    assert!(soft_cap <= hard_cap, EInvalidCapsOrdering);
    assert!(opens_at_ms < closes_at_ms, EInvalidTimeRange);

    let sale = PrefundedSale {
        id: object::new(ctx),
        inventory: balance::zero<S>(),
        total_allocated: 0,
        proceeds: balance::zero<P>(),
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
    let cap = SaleAdminCap<S, P> { id: object::new(ctx), sale_id };

    event::emit(SaleCreated<S, P> {
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
public fun deposit_inventory<S, P, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<S, P, ScheduleParams>,
    inventory: Coin<S>,
) {
    assert!(sale::is_init(&sale.phase), ENotInit);
    let amount = coin::value(&inventory);
    balance::join(&mut sale.inventory, coin::into_balance(inventory));
    event::emit(InventoryDeposited<S, P> {
        sale_id: object::id(sale),
        amount,
        inventory_after: balance::value(&sale.inventory),
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
public fun set_per_buyer_cap<S, P, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<S, P, ScheduleParams>,
    per_buyer_cap: u64,
    ctx: &mut TxContext,
) {
    assert!(sale::is_init(&sale.phase), ENotInit);
    assert!(option::is_none(&sale.per_buyer_cap), EPerBuyerCapAlreadySet);
    assert!(per_buyer_cap > 0, EPerBuyerCapZero);
    option::fill(&mut sale.per_buyer_cap, per_buyer_cap);
    option::fill(&mut sale.contributions, table::new<address, u64>(ctx));
    event::emit(PerBuyerCapSet<S, P> {
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
public fun set_vesting_schedule_params<S, P, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<S, P, ScheduleParams>,
    params: ScheduleParams,
) {
    assert!(sale::is_init(&sale.phase), ENotInit);
    assert!(option::is_none(&sale.vesting_schedule_params), EVestingScheduleAlreadySet);
    option::fill(&mut sale.vesting_schedule_params, params);
    event::emit(VestingScheduleParamsSet<S, P, ScheduleParams> {
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
public fun pair_refund_vault<S, P, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<S, P, ScheduleParams>,
    vault: &RefundVault<P>,
    vault_cap: RefundVaultCap<P>,
) {
    assert!(sale::is_init(&sale.phase), ENotInit);
    assert!(option::is_none(&sale.refund_vault_cap), EVaultAlreadyPaired);
    assert!(refund_vault::cap_vault_id(&vault_cap) == object::id(vault), EWrongVault);
    assert!(refund_vault::is_active(vault), EVaultNotActive);
    assert!(refund_vault::value(vault) == 0, EVaultNotEmpty);

    let vault_id = object::id(vault);
    option::fill(&mut sale.refund_vault_id, vault_id);
    option::fill(&mut sale.refund_vault_cap, vault_cap);
    event::emit(RefundVaultPaired<S, P> {
        sale_id: object::id(sale),
        vault_id,
    });
}

/// Switch the sale into compliance-gated mode and issue the
/// `AllowlistAdmin<S>`. The caller wraps the admin inside the
/// compliance module of their choice.
///
/// One-shot: aborts if called twice on the same sale. Duplicate
/// admins would let two compliance modules mint entries
/// independently for the same sale, defeating the gating.
public fun enable_allowlist<S, P, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<S, P, ScheduleParams>,
    ctx: &mut TxContext,
): AllowlistAdmin<S> {
    assert!(sale::is_init(&sale.phase), ENotInit);
    assert!(!sale.requires_allowlist, EAllowlistAlreadyEnabled);
    sale.requires_allowlist = true;
    let sale_id = object::id(sale);
    let admin = allowlist::new_admin<S>(sale_id, ctx);
    event::emit(AllowlistEnabled<S, P> {
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
public fun share_and_activate<S, P, ScheduleParams: copy + drop + store>(
    mut sale: PrefundedSale<S, P, ScheduleParams>,
    clock: &Clock,
) {
    assert!(sale::is_init(&sale.phase), ENotInit);
    assert!(option::is_some(&sale.refund_vault_cap), EVaultRequiredForActivate);

    let required_128 = (sale.hard_cap as u128) * (sale.rate as u128);
    assert!(required_128 <= U64_MAX, EInventoryOverflowAtActivate);
    let required = required_128 as u64;
    assert!(balance::value(&sale.inventory) >= required, EInsufficientInventoryAtActivate);

    let activated_at_ms = clock::timestamp_ms(clock);
    assert!(activated_at_ms < sale.closes_at_ms, EActivationAfterClose);

    sale.phase = sale::phase_active();
    let sale_id = object::id(&sale);
    transfer::share_object(sale);
    event::emit(SaleActivated<S, P> { sale_id, activated_at_ms });
}

// === Active phase ===

/// Buy sale tokens. Delivers a fresh `Receipt<S>` to `ctx.sender()`
/// (the buyer). Payment is added to `sale.proceeds`.
///
/// `allow` must be `Some` iff `requires_allowlist == true`. The
/// entry is consumed; its `sale_id` and `buyer` are asserted.
///
/// All arithmetic on user-controlled inputs (`raised + paid`,
/// `contribution + paid`, `paid * rate`) is widened to `u128` and
/// bounds-checked before downcasting, so oversized payments abort
/// with a typed error rather than the default arithmetic overflow.
public fun purchase<S, P, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<S, P, ScheduleParams>,
    payment: Coin<P>,
    allow: Option<AllowEntry<S>>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Phase + time
    assert!(sale::is_active(&sale.phase), ENotActive);
    let now = clock::timestamp_ms(clock);
    assert!(now >= sale.opens_at_ms && now <= sale.closes_at_ms, ESaleWindowClosed);

    // Allowlist gate
    let buyer = ctx.sender();
    let entry_max = if (sale.requires_allowlist) {
        assert!(option::is_some(&allow), EAllowlistRequired);
        let entry = option::destroy_some(allow);
        allowlist::consume<S>(entry, object::id(sale), buyer)
    } else {
        assert!(option::is_none(&allow), EAllowlistNotRequired);
        option::destroy_none(allow);
        0
    };

    // Hard cap (u128-widened)
    let paid = coin::value(&payment);
    assert!(paid > 0, EZeroPayment);
    let new_raised_128 = (sale.raised as u128) + (paid as u128);
    assert!(new_raised_128 <= U64_MAX, ERaisedOverflow);
    assert!(new_raised_128 <= (sale.hard_cap as u128), EHardCapExceeded);

    // Per-entry cap
    if (entry_max > 0) {
        assert!(paid <= entry_max, EPerEntryCapExceeded);
    };

    // Per-buyer cap (u128-widened)
    if (option::is_some(&sale.per_buyer_cap)) {
        let per_cap = *option::borrow(&sale.per_buyer_cap);
        let contribs = option::borrow_mut(&mut sale.contributions);
        let current = if (table::contains(contribs, buyer)) {
            *table::borrow(contribs, buyer)
        } else { 0 };
        let new_total_128 = (current as u128) + (paid as u128);
        assert!(new_total_128 <= U64_MAX, EContributionOverflow);
        assert!(new_total_128 <= (per_cap as u128), EPerBuyerCapExceeded);
        let new_total = new_total_128 as u64;
        if (table::contains(contribs, buyer)) {
            let slot = table::borrow_mut(contribs, buyer);
            *slot = new_total;
        } else {
            table::add(contribs, buyer, new_total);
        };
    };

    // Allocation + inventory backing (u128-checked)
    let allocation_128 = (paid as u128) * (sale.rate as u128);
    assert!(allocation_128 <= U64_MAX, EAllocationOverflow);
    let allocation = allocation_128 as u64;
    let unallocated = balance::value(&sale.inventory) - sale.total_allocated;
    assert!(allocation <= unallocated, EInsufficientInventoryAtActivate);

    // State mutations
    sale.total_allocated = sale.total_allocated + allocation;
    sale.raised = new_raised_128 as u64;
    balance::join(&mut sale.proceeds, coin::into_balance(payment));

    // Mint and deliver receipt
    let sale_id = object::id(sale);
    let receipt = sale::new_receipt<S>(sale_id, buyer, paid, allocation, now, ctx);
    let receipt_id = object::id(&receipt);
    sale::deliver_receipt(receipt, buyer);

    event::emit(Purchased<S, P> {
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
public fun finalize<S, P, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<S, P, ScheduleParams>,
    vault: &mut RefundVault<P>,
    clock: &Clock,
) {
    assert!(sale::is_active(&sale.phase), ENotActive);
    let now = clock::timestamp_ms(clock);
    let window_closed = now > sale.closes_at_ms;
    let hard_cap_reached = sale.raised >= sale.hard_cap;
    assert!(window_closed || hard_cap_reached, ESaleWindowStillOpen);
    assert!(sale.raised >= sale.soft_cap, ESoftCapNotMet);

    let paired_id = *option::borrow(&sale.refund_vault_id);
    assert!(object::id(vault) == paired_id, EWrongVault);

    // Synchronize vault state with the sale's terminal phase.
    {
        let cap_ref = option::borrow(&sale.refund_vault_cap);
        refund_vault::flip_to_closed(vault, cap_ref);
    };

    sale.phase = sale::phase_finalized();
    event::emit(SaleFinalized<S, P> {
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
public fun cancel_after_close<S, P, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<S, P, ScheduleParams>,
    vault: &mut RefundVault<P>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(sale::is_active(&sale.phase), ENotActive);
    let now = clock::timestamp_ms(clock);
    assert!(now > sale.closes_at_ms, ESaleWindowStillOpen);
    assert!(sale.soft_cap > 0 && sale.raised < sale.soft_cap, ESoftCapMet);

    do_cancel(sale, vault, CancelReason::SoftCapMissed, now);
    let _ = ctx;
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
public fun cancel_emergency<S, P, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<S, P, ScheduleParams>,
    cap: &SaleAdminCap<S, P>,
    vault: &mut RefundVault<P>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_admin(sale, cap);
    assert!(sale::is_active(&sale.phase), ENotActive);
    let now = clock::timestamp_ms(clock);
    assert!(now <= sale.closes_at_ms, EEmergencyCancelAfterClose);
    assert!(sale.raised < sale.hard_cap, ESaleAlreadyComplete);
    assert!(sale.soft_cap == 0 || sale.raised < sale.soft_cap, ESoftCapMet);

    do_cancel(sale, vault, CancelReason::AdminEmergency, now);
    let _ = ctx;
}

/// Shared body of `cancel_after_close` and `cancel_emergency`.
fun do_cancel<S, P, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<S, P, ScheduleParams>,
    vault: &mut RefundVault<P>,
    reason: CancelReason,
    now: u64,
) {
    let paired_id = *option::borrow(&sale.refund_vault_id);
    assert!(object::id(vault) == paired_id, EWrongVault);

    let amount = balance::value(&sale.proceeds);
    let proceeds_balance = balance::split(&mut sale.proceeds, amount);
    {
        let cap_ref = option::borrow(&sale.refund_vault_cap);
        refund_vault::deposit(vault, cap_ref, proceeds_balance);
        refund_vault::flip_to_refunding(vault, cap_ref);
    };

    sale.phase = sale::phase_cancelled();

    event::emit(SaleCancelled<S, P> {
        sale_id: object::id(sale),
        raised: sale.raised,
        reason,
        closed_at_ms: now,
    });
}

// === Success path (Finalized) ===

/// Redeem a receipt for `Coin<S>`. Asserts
/// `ctx.sender() == receipt.buyer`. Destroys the receipt.
///
/// Aborts with `EClaimRequiresVesting` if the sale has a vesting
/// schedule attached — vested sales must redeem via
/// `claim_into_vesting`. This is the library's enforcement that the
/// schedule cannot be bypassed by calling the immediate-distribution
/// path.
public fun claim<S, P, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<S, P, ScheduleParams>,
    receipt: Receipt<S>,
    ctx: &mut TxContext,
): Coin<S> {
    assert!(sale::is_finalized(&sale.phase), ENotFinalized);
    assert!(option::is_none(&sale.vesting_schedule_params), EClaimRequiresVesting);
    assert!(sale::receipt_sale_id(&receipt) == object::id(sale), EReceiptSaleMismatch);
    assert_sender_is_buyer(&receipt, ctx);

    let receipt_id = object::id(&receipt);
    let (_sale_id, buyer, _paid, allocation, _ts) = sale::consume_receipt(receipt);

    sale.total_allocated = sale.total_allocated - allocation;
    let payout = balance::split(&mut sale.inventory, allocation);

    event::emit(Claimed<S, P> {
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
public fun claim_all<S, P, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<S, P, ScheduleParams>,
    mut receipts: vector<Receipt<S>>,
    ctx: &mut TxContext,
): Coin<S> {
    let mut total = coin::zero<S>(ctx);
    while (!vector::is_empty(&receipts)) {
        let r = vector::pop_back(&mut receipts);
        coin::join(&mut total, claim(sale, r, ctx));
    };
    vector::destroy_empty(receipts);
    total
}

/// Redeem a receipt into a `VestedAllocation<S, ScheduleParams>` hot-potato. The only
/// redemption path for a vesting-attached sale; aborts with
/// `ENoVestingScheduleAttached` if no schedule is set (use `claim`
/// instead).
///
/// The returned `VestedAllocation<S, ScheduleParams>` has no `drop`, `key`, or `store`
/// ability and its fields are private to `sale.move`, so the caller
/// cannot stash it, discard it, or extract the raw `Coin<S>`. The
/// only consumer paths live in `vested_claim`, which route the coin
/// into a `VestingWallet<S>` matching the sale's schedule.
///
/// Asserts `ctx.sender() == receipt.buyer` (same buyer-binding rule
/// as `claim`). Destroys the receipt.
public fun claim_into_vesting<S, P, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<S, P, ScheduleParams>,
    receipt: Receipt<S>,
    ctx: &mut TxContext,
): VestedAllocation<S, ScheduleParams> {
    assert!(sale::is_finalized(&sale.phase), ENotFinalized);
    assert!(option::is_some(&sale.vesting_schedule_params), ENoVestingScheduleAttached);
    assert!(sale::receipt_sale_id(&receipt) == object::id(sale), EReceiptSaleMismatch);
    assert_sender_is_buyer(&receipt, ctx);

    let receipt_id = object::id(&receipt);
    let (_sale_id, buyer, _paid, allocation, _ts) = sale::consume_receipt(receipt);

    sale.total_allocated = sale.total_allocated - allocation;
    let payout = balance::split(&mut sale.inventory, allocation);
    let coin = coin::from_balance(payout, ctx);

    let schedule = *option::borrow(&sale.vesting_schedule_params);
    let sale_id = object::id(sale);

    event::emit(Claimed<S, P> {
        sale_id,
        buyer,
        receipt_id,
        amount: allocation,
    });

    sale::new_vested_allocation(coin, schedule, buyer, sale_id)
}

/// Withdraw collected proceeds. Phase must be `Finalized`.
public fun withdraw_proceeds<S, P, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<S, P, ScheduleParams>,
    cap: &SaleAdminCap<S, P>,
    ctx: &mut TxContext,
): Coin<P> {
    assert_admin(sale, cap);
    assert!(sale::is_finalized(&sale.phase), ENotFinalized);
    let amount = balance::value(&sale.proceeds);
    let part = balance::split(&mut sale.proceeds, amount);
    event::emit(ProceedsWithdrawn<S, P> {
        sale_id: object::id(sale),
        amount,
    });
    coin::from_balance(part, ctx)
}

/// Withdraw unallocated inventory. Valid in `Finalized` or
/// `Cancelled`. Strictly the unreserved portion
/// (`inventory - total_allocated`); outstanding receipts remain
/// backed.
public fun withdraw_unsold_inventory<S, P, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<S, P, ScheduleParams>,
    cap: &SaleAdminCap<S, P>,
    ctx: &mut TxContext,
): Coin<S> {
    assert_admin(sale, cap);
    assert!(sale::is_finalized(&sale.phase) || sale::is_cancelled(&sale.phase), ENotTerminal);
    let unallocated = balance::value(&sale.inventory) - sale.total_allocated;
    let part = balance::split(&mut sale.inventory, unallocated);
    event::emit(InventoryWithdrawn<S, P> {
        sale_id: object::id(sale),
        amount: unallocated,
    });
    coin::from_balance(part, ctx)
}

// === Failure path (Cancelled) ===

/// Refund a buyer's payment. Asserts
/// `ctx.sender() == receipt.buyer`. Destroys the receipt and pays
/// `receipt.paid` worth of `Coin<P>` out of the paired vault.
public fun refund<S, P, ScheduleParams: copy + drop + store>(
    sale: &mut PrefundedSale<S, P, ScheduleParams>,
    vault: &mut RefundVault<P>,
    receipt: Receipt<S>,
    ctx: &mut TxContext,
): Coin<P> {
    assert!(sale::is_cancelled(&sale.phase), ENotCancelled);
    assert!(sale::receipt_sale_id(&receipt) == object::id(sale), EReceiptSaleMismatch);
    assert_sender_is_buyer(&receipt, ctx);
    let paired_vault_id = *option::borrow(&sale.refund_vault_id);
    assert!(object::id(vault) == paired_vault_id, EWrongVault);

    let receipt_id = object::id(&receipt);
    let (_sale_id, buyer, paid, allocation, _ts) = sale::consume_receipt(receipt);

    sale.total_allocated = sale.total_allocated - allocation;

    let payment = {
        let cap_ref = option::borrow(&sale.refund_vault_cap);
        refund_vault::release_balance(vault, cap_ref, paid)
    };

    event::emit(Refunded<S, P> {
        sale_id: object::id(sale),
        buyer,
        receipt_id,
        amount: paid,
    });

    coin::from_balance(payment, ctx)
}

// === Views ===

public fun phase<S, P, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<S, P, ScheduleParams>,
): Phase {
    sale.phase
}

public fun raised<S, P, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<S, P, ScheduleParams>,
): u64 {
    sale.raised
}

public fun rate<S, P, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<S, P, ScheduleParams>,
): u64 { sale.rate }

public fun hard_cap<S, P, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<S, P, ScheduleParams>,
): u64 {
    sale.hard_cap
}

public fun soft_cap<S, P, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<S, P, ScheduleParams>,
): u64 {
    sale.soft_cap
}

public fun opens_at_ms<S, P, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<S, P, ScheduleParams>,
): u64 {
    sale.opens_at_ms
}

public fun closes_at_ms<S, P, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<S, P, ScheduleParams>,
): u64 {
    sale.closes_at_ms
}

public fun requires_allowlist<S, P, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<S, P, ScheduleParams>,
): bool { sale.requires_allowlist }

/// Read the sale's vesting schedule. Returns `Some(schedule)` if the
/// issuer called `set_vesting_schedule_params` during Init, otherwise `None`.
/// Vesting adapters read this to determine the redemption shape.
public fun vesting_schedule_params<S, P, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<S, P, ScheduleParams>,
): Option<ScheduleParams> {
    sale.vesting_schedule_params
}

public fun inventory_total<S, P, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<S, P, ScheduleParams>,
): u64 {
    balance::value(&sale.inventory)
}

public fun total_allocated<S, P, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<S, P, ScheduleParams>,
): u64 {
    sale.total_allocated
}

public fun inventory_remaining<S, P, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<S, P, ScheduleParams>,
): u64 {
    balance::value(&sale.inventory) - sale.total_allocated
}

public fun proceeds_amount<S, P, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<S, P, ScheduleParams>,
): u64 {
    balance::value(&sale.proceeds)
}

public fun is_open<S, P, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<S, P, ScheduleParams>,
    clock: &Clock,
): bool {
    if (!sale::is_active(&sale.phase)) { return false };
    let now = clock::timestamp_ms(clock);
    now >= sale.opens_at_ms && now <= sale.closes_at_ms
}

public fun has_reached_soft_cap<S, P, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<S, P, ScheduleParams>,
): bool {
    sale.raised >= sale.soft_cap
}

public fun has_reached_hard_cap<S, P, ScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<S, P, ScheduleParams>,
): bool {
    sale.raised >= sale.hard_cap
}

public fun cap_sale_id<S, P>(c: &SaleAdminCap<S, P>): ID { c.sale_id }

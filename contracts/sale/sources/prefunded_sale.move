/// `PrefundedSale<SaleCoin, PaymentCoin>` - fixed-price token sale, v1 flavor.
///
/// The issuer pre-mints (or pre-acquires) the sale tokens and deposits
/// them as `Balance<SaleCoin>` inventory before activation. The sale draws
/// from that fixed inventory at `claim` time and never holds a
/// `TreasuryCap<SaleCoin>`. v2's `MintingSale<SaleCoin, PaymentCoin>` will be a sibling type
/// that holds a `TreasuryCap<SaleCoin>` instead - same `Receipt<SaleCoin>`, same
/// `Phase`, separate audit boundary.
///
/// ### Lifecycle
///
/// ```text
///   create_sale ──┐
///   deposit ──┐
///   set_per_buyer_cap   │  (Init phase - sale is owned by caller;
///   pair_refund_vault   ├   holding it by &mut is the authority)
///   enable_allowlist    │
///                       │
///   share_and_activate ─┴──>  (Active phase - sale is shared)
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
///   hard_cap * max_rate` is enforced at activation, so sold-out and
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
///    cap leaves the sale fully usable for buyers - they can still
///    `purchase`, `claim`, `refund`, and trigger `finalize` /
///    `cancel_after_close` permissionlessly - but admin loses
///    emergency-cancel power and the ability to withdraw proceeds
///    and unsold inventory.
///
/// 3. **`AllowlistAdmin<SaleCoin>` controls compliance.** Issued by
///    `enable_allowlist`. Loses-the-key implications: no entries can
///    be minted, every `purchase` aborts. Hold in a recoverable
///    container.
///
/// 4. **Every sale requires a paired `RefundVault<PaymentCoin>`.** Even sales
///    with `soft_cap == 0` need a vault - `cancel_emergency` always
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

use openzeppelin_finance::vesting_wallet::{Self, VestingWallet};
use openzeppelin_sale::allowlist::{Self, AllowEntry, AllowlistAdmin};
use openzeppelin_sale::phase::{Self, Phase};
use openzeppelin_sale::receipt::{Self, Receipt};
use openzeppelin_sale::refund_vault::{Self, RefundVault, RefundVaultCap};
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin;
use sui::event;
use sui::table::{Self, Table};

// === Errors ===

// Auth
#[error(code = 0)]
const EWrongAdminCap: vector<u8> = "Admin cap does not match this sale";
#[error(code = 1)]
const EBuyerOnly: vector<u8> =
    "Receipt is bound to its buyer; transaction sender must equal receipt.buyer";
#[error(code = 2)]
const EEmergencyCancelAfterClose: vector<u8> =
    "cancel_emergency can only be called during the active window; use cancel_after_close instead";

// Time
#[error(code = 10)]
const EInvalidTimeRange: vector<u8> = "opens_at_ms must be strictly less than closes_at_ms";
#[error(code = 11)]
const ESaleWindowClosed: vector<u8> = "Purchase outside [opens_at_ms, closes_at_ms]";
#[error(code = 12)]
const ESaleWindowStillOpen: vector<u8> =
    "Cannot close: window still open and hard cap not yet reached";
#[error(code = 13)]
const EActivationAfterClose: vector<u8> = "Cannot activate: closes_at_ms is already in the past";

// Pricing & accounting
#[error(code = 20)]
const EHardCapZero: vector<u8> = "hard_cap must be greater than zero";
#[error(code = 21)]
const EInvalidCapsOrdering: vector<u8> = "soft_cap must be <= hard_cap";
#[error(code = 22)]
const EZeroPayment: vector<u8> = "Payment must be greater than zero";
#[error(code = 23)]
const ERaisedOverflow: vector<u8> = "raised + payment overflows u64";
#[error(code = 24)]
const EContributionOverflow: vector<u8> = "buyer contribution + payment overflows u64";
#[error(code = 25)]
const EHardCapExceeded: vector<u8> = "Purchase would exceed hard_cap";
#[error(code = 26)]
const EInsufficientInventoryAtActivate: vector<u8> =
    "Inventory at activation does not cover hard_cap * max_rate";
#[error(code = 27)]
const EAllocationOverflow: vector<u8> = "Allocation would overflow u64";
#[error(code = 28)]
const EInsufficientInventory: vector<u8> = "Purchase allocation exceeds unallocated inventory";

// Caps
#[error(code = 30)]
const EPerBuyerCapExceeded: vector<u8> = "Purchase exceeds per-buyer cap";
#[error(code = 31)]
const EPerEntryCapExceeded: vector<u8> = "Purchase exceeds AllowEntry max_amount";
#[error(code = 32)]
const ESoftCapNotMet: vector<u8> = "Cannot finalize: raised < soft_cap";
#[error(code = 33)]
const ESoftCapMet: vector<u8> = "Cannot cancel: soft_cap already met or no soft_cap configured";
#[error(code = 34)]
const ESaleAlreadyComplete: vector<u8> =
    "Cannot cancel: hard_cap already reached, sale must finalize";

// Allowlist coupling
#[error(code = 40)]
const EAllowlistRequired: vector<u8> = "Sale requires AllowEntry but none provided";
#[error(code = 41)]
const EAllowlistNotRequired: vector<u8> = "Sale does not require AllowEntry but one was provided";
#[error(code = 42)]
const EAllowlistAlreadyEnabled: vector<u8> = "Allowlist already enabled for this sale";

// Vault coupling
#[error(code = 50)]
const EVaultAlreadyPaired: vector<u8> = "Refund vault already paired";
#[error(code = 51)]
const EVaultRequiredForActivate: vector<u8> = "Activation requires a paired refund vault";
#[error(code = 52)]
const EWrongVault: vector<u8> = "Provided vault does not match the one paired with this sale";
#[error(code = 53)]
const EVaultNotActive: vector<u8> = "Refund vault must be in Active state when paired";
#[error(code = 54)]
const EVaultNotEmpty: vector<u8> =
    "Refund vault must be empty (value == 0) when paired; pre-existing funds would be stranded after finalize/cancel";

// Receipts
#[error(code = 60)]
const EReceiptSaleMismatch: vector<u8> = "Receipt does not belong to this sale";

// Quote / curve coupling
#[error(code = 61)]
const EQuoteSaleMismatch: vector<u8> = "Quote does not belong to this sale";

// Activation ticket
#[error(code = 62)]
const ETicketSaleMismatch: vector<u8> = "Activation ticket does not belong to this sale";

// Per-buyer cap configuration
#[error(code = 70)]
const EPerBuyerCapAlreadySet: vector<u8> = "Per-buyer cap already configured";
#[error(code = 71)]
const EPerBuyerCapZero: vector<u8> =
    "Per-buyer cap must be greater than zero (a zero cap blocks every buyer)";

// Vesting schedule configuration
#[error(code = 80)]
const EVestingScheduleAlreadySet: vector<u8> = "Vesting schedule already configured";
#[error(code = 81)]
const EClaimRequiresVesting: vector<u8> =
    "Sale has a vesting schedule; redeem via claim_into_vesting + vested_claim, not plain claim";
#[error(code = 82)]
const ENoVestingScheduleAttached: vector<u8> =
    "Sale has no vesting schedule; use claim instead of claim_into_vesting";

// === Types ===

public struct PrefundedSale<
    phantom Curve: drop,
    CurveParams: copy + drop + store,
    phantom SaleCoin,
    phantom PaymentCoin,
    VestingScheduleParams: copy,
> has key {
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
    /// Curve configuration, opaque to the sale and fixed at construction.
    /// Only the declaring `Curve` module interprets it (read via
    /// `curve_params`). Mirrors how `VestingWallet` stores `schedule_params`.
    curve_params: CurveParams,
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
    /// schedule - it is fixed at sale construction.
    vesting_schedule_params: Option<VestingScheduleParams>,
}

public struct SaleAdminCap<phantom SaleCoin, phantom PaymentCoin> has key, store {
    id: UID,
    sale_id: ID,
}

// === Events ===

public struct SaleCreated<CurveParams, phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    hard_cap: u64,
    soft_cap: u64,
    opens_at_ms: u64,
    closes_at_ms: u64,
    curve_params: CurveParams,
}

public struct InventoryDeposited<phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    amount: u64,
    new_inventory: u64,
}

public struct PerBuyerCapSet<phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    cap: u64,
}

public struct VestingVestingScheduleParamsSet<
    phantom SaleCoin,
    phantom PaymentCoin,
    VestingScheduleParams: copy + drop,
> has copy, drop {
    sale_id: ID,
    params: VestingScheduleParams,
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

// === Setup (Phase: Init) ===

/// Create a sale in `Init` phase. Returns the sale as an owned value
/// plus its admin cap. The caller threads the sale through setup
/// calls in the same PTB and then calls `share_and_activate` to
/// transition to `Active`.
///
/// The sale is pricing-agnostic. `curve_params` is the opaque
/// configuration the `Curve` module interprets, and `max_rate` is the
/// upper bound on allocation per payment unit that the curve commits to
/// (a fixed-rate curve sets `max_rate = rate`; a ratcheting-down curve
/// sets `max_rate = initial_rate`). Integrators normally call the curve
/// module's own `create_sale` sugar, which derives `max_rate` from the
/// params so the two cannot drift apart.
///
/// Asserts:
/// - `max_rate > 0`
/// - `hard_cap > 0` (every sale must have a bounded raise)
/// - `soft_cap <= hard_cap`
/// - `opens_at_ms < closes_at_ms`
public fun create_sale<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    curve_params: CurveParams,
    hard_cap: u64,
    soft_cap: u64,
    opens_at_ms: u64,
    closes_at_ms: u64,
    ctx: &mut TxContext,
): (
    PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
    SaleAdminCap<SaleCoin, PaymentCoin>,
) {
    assert!(hard_cap > 0, EHardCapZero);
    assert!(soft_cap <= hard_cap, EInvalidCapsOrdering);
    assert!(opens_at_ms < closes_at_ms, EInvalidTimeRange);

    let sale = PrefundedSale {
        id: object::new(ctx),
        inventory: balance::zero<SaleCoin>(),
        total_allocated: 0,
        proceeds: balance::zero<PaymentCoin>(),
        curve_params,
        hard_cap,
        soft_cap,
        raised: 0,
        opens_at_ms,
        closes_at_ms,
        phase: phase::phase_init(),
        requires_allowlist: false,
        refund_vault_id: option::none(),
        refund_vault_cap: option::none(),
        per_buyer_cap: option::none(),
        contributions: option::none(),
        vesting_schedule_params: option::none(),
    };
    let sale_id = object::id(&sale);
    let cap = SaleAdminCap<SaleCoin, PaymentCoin> { id: object::new(ctx), sale_id };

    event::emit(SaleCreated<CurveParams, SaleCoin, PaymentCoin> {
        sale_id,
        hard_cap,
        soft_cap,
        opens_at_ms,
        closes_at_ms,
        curve_params,
    });

    (sale, cap)
}

/// Deposit sale tokens into inventory. May be called multiple times
/// during Init. Authority is implicit: the sale is owned, so only the
/// caller that created it can pass it as `&mut`.
public fun deposit<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &mut PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
    inventory: Balance<SaleCoin>,
) {
    sale.phase.assert_init();
    let amount = inventory.value();
    sale.inventory.join(inventory);
    event::emit(InventoryDeposited<SaleCoin, PaymentCoin> {
        sale_id: object::id(sale),
        amount,
        new_inventory: sale.inventory.value(),
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
public fun set_per_buyer_cap<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &mut PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
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
///
/// Once a schedule is attached, the plain `claim` path aborts and
/// buyers must redeem through `claim_into_vesting` → a
/// `vested_claim::into_*` consumer. The library enforces this so a
/// buyer cannot trivially bypass the schedule. The schedule is
/// **issuer-defined**: the buyer is the caller of the redemption
/// path and cannot supply or override these values.
public fun set_vesting_schedule_params<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &mut PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
    params: VestingScheduleParams,
) {
    sale.phase.assert_init();
    assert!(sale.vesting_schedule_params.is_none(), EVestingScheduleAlreadySet);
    sale.vesting_schedule_params.fill(params);
    event::emit(VestingVestingScheduleParamsSet<SaleCoin, PaymentCoin, VestingScheduleParams> {
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
public fun pair_refund_vault<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &mut PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
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
public fun enable_allowlist<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &mut PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
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

public struct ActivationTicket<phantom Curve: drop> {
    sale_id: ID,
    required_inventory: u64,
}

public fun mint_activation_ticket<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
    _w: Curve,
    required_inventory: u64,
): ActivationTicket<Curve> { ActivationTicket { sale_id: object::id(sale), required_inventory } }

/// Transition `Init → Active` and share the sale.
///
/// Asserts:
/// - A refund vault has been paired (every sale requires one).
/// - `inventory >= hard_cap * max_rate` (u128-checked for overflow).
///   Sold-out and hard-cap-reached therefore coincide; `purchase`
///   never aborts with "out of inventory" before "exceeds cap".
/// - `now < closes_at_ms`. Activating after the window has elapsed
///   would share a stale sale that immediately becomes finalizable
///   or cancellable with no purchase opportunity. Activation before
///   `opens_at_ms` is allowed.
public fun share_and_activate<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    mut sale: PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
    ticket: ActivationTicket<Curve>,
    clock: &Clock,
) {
    let sale_id = object::id(&sale);
    let ActivationTicket { sale_id: ticket_sale_id, required_inventory } = ticket;

    assert!(sale_id == ticket_sale_id, EReceiptSaleMismatch);

    // TODO: move phase-related error codes to this module and remove assert_init
    sale.phase.assert_init();
    assert!(sale.refund_vault_cap.is_some(), EVaultRequiredForActivate);

    let activated_at_ms = clock::timestamp_ms(clock);
    assert!(activated_at_ms < sale.closes_at_ms, EActivationAfterClose);

    assert!(sale.inventory.value() >= required_inventory, EInsufficientInventoryAtActivate);

    sale.phase.activate();
    transfer::share_object(sale);
    event::emit(SaleActivated<SaleCoin, PaymentCoin> {
        sale_id,
        activated_at_ms,
    });
}

// === Active phase ===

/// Buy sale tokens. Delivers a fresh `Receipt<SaleCoin>` to `ctx.sender()`
/// (the buyer). Payment is added to `sale.proceeds`.
///
/// Pricing is supplied by `quote`, a witness-gated `Quote<Curve>` that
/// only the sale's `Curve` module can mint (see `sale::mint_quote`).
/// The quote is bound to this sale (`quote.sale_id`) and to the payment
/// (`quote.paid == payment.value()`); its `allocation` is accepted only
/// up to `paid * max_rate`, the sale's committed defensive bound, so a
/// buggy or dishonest curve can never over-allocate inventory.
///
/// `allow` must be `Some` iff `requires_allowlist == true`. The
/// entry is consumed; its `sale_id` and `buyer` are asserted.
///
/// All arithmetic on user-controlled inputs (`raised + paid`,
/// `contribution + paid`, `paid * max_rate`) is widened to `u128` and
/// bounds-checked before downcasting, so oversized payments abort
/// with a typed error rather than the default arithmetic overflow.
public fun purchase<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &mut PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
    quote: Quote<PaymentCoin>,
    allow: Option<AllowEntry<SaleCoin>>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Phase + time
    sale.phase.assert_active();

    // Unpack the quote and bind it to this sale.
    let (quote_sale_id, payment, allocation) = quote.unpack();
    assert!(quote_sale_id == object::id(sale), EQuoteSaleMismatch);

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

    // already ensured that the value is > 0, see `mint_quote`
    let paid = payment.value();
    let u64_max = std::u64::max_value!();

    // Hard cap
    assert!(u64_max - paid >= sale.raised, ERaisedOverflow);
    let new_raised = sale.raised + paid;
    assert!(new_raised <= sale.hard_cap, EHardCapExceeded);

    // Per-entry cap
    assert!(entry_max == 0 || paid <= entry_max, EPerEntryCapExceeded);

    // Per-buyer cap
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

    // Inventory backing.
    let unallocated = sale.inventory.value() - sale.total_allocated;
    assert!(allocation <= unallocated, EInsufficientInventory);

    // State mutations
    sale.total_allocated = sale.total_allocated + allocation;
    sale.raised = new_raised;
    sale.proceeds.join(payment);

    // Mint and deliver receipt
    let sale_id = object::id(sale);
    let receipt = receipt::new_receipt<SaleCoin>(sale_id, buyer, paid, allocation, now, ctx);
    let receipt_id = object::id(&receipt);
    receipt.deliver(buyer);

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
/// - `raised >= hard_cap` (sold-out - closes early).
public fun finalize<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &mut PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
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
public fun cancel_after_close<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &mut PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
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
/// permitted - useful when a bug or compliance issue is discovered
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
public fun cancel_emergency<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &mut PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
    cap: &SaleAdminCap<SaleCoin, PaymentCoin>,
    vault: &mut RefundVault<PaymentCoin>,
    clock: &Clock,
) {
    assert!(cap.sale_id == object::id(sale), EWrongAdminCap);
    sale.phase.assert_active();
    let now = clock::timestamp_ms(clock);
    assert!(now <= sale.closes_at_ms, EEmergencyCancelAfterClose);
    assert!(sale.raised < sale.hard_cap, ESaleAlreadyComplete);
    assert!(sale.soft_cap == 0 || sale.raised < sale.soft_cap, ESoftCapMet);

    sale.do_cancel(vault, CancelReason::AdminEmergency, now);
}

/// Shared body of `cancel_after_close` and `cancel_emergency`.
fun do_cancel<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &mut PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
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
/// schedule attached - vested sales must redeem via
/// `claim_into_vesting`. This is the library's enforcement that the
/// schedule cannot be bypassed by calling the immediate-distribution
/// path.
public fun claim<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &mut PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
    receipt: Receipt<SaleCoin>,
    ctx: &mut TxContext,
): Balance<SaleCoin> {
    assert!(sale.vesting_schedule_params.is_none(), EClaimRequiresVesting);
    sale.claim_internal(receipt, ctx)
}

/// Batch helper: claim several receipts in one call. Asserts
/// `ctx.sender() == receipt.buyer` on each. Aborts the whole call
/// if any receipt is invalid. Inherits the no-vesting guard from
/// `claim`.
public fun claim_all<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &mut PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
    receipts: vector<Receipt<SaleCoin>>,
    ctx: &mut TxContext,
): Balance<SaleCoin> {
    assert!(sale.vesting_schedule_params.is_none(), EClaimRequiresVesting);
    sale.claim_all_internal(receipts, ctx)
}

/// Redeem a receipt into a `VestedAllocation<SaleCoin, VestingScheduleParams>` hot-potato. The only
/// redemption path for a vesting-attached sale; aborts with
/// `ENoVestingScheduleAttached` if no schedule is set (use `claim`
/// instead).
///
/// The returned `VestedAllocation<SaleCoin, VestingScheduleParams>` has no `drop`, `key`, or `store`
/// ability and its fields are private to `sale.move`, so the caller
/// cannot stash it, discard it, or extract the raw `Coin<SaleCoin>`. The
/// only consumer paths live in `vested_claim`, which route the coin
/// into a `VestingWallet<SaleCoin>` matching the sale's schedule.
///
/// Asserts `ctx.sender() == receipt.buyer` (same buyer-binding rule
/// as `claim`). Destroys the receipt.
public fun claim_into_vesting<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
    Witness: drop,
>(
    sale: &mut PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
    receipt: Receipt<SaleCoin>,
    ctx: &mut TxContext,
): VestingWallet<Witness, VestingScheduleParams, SaleCoin> {
    assert!(sale.vesting_schedule_params.is_some(), ENoVestingScheduleAttached);
    let payout = sale.claim_internal(receipt, ctx);

    let mut wallet = vesting_wallet::new<Witness, VestingScheduleParams, SaleCoin>(
        *sale.vesting_schedule_params.borrow(),
        ctx.sender(), // only buyer can claim
        ctx,
    );
    wallet.deposit(coin::from_balance(payout, ctx));

    wallet
}

public fun claim_all_into_vesting<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
    Witness: drop,
>(
    sale: &mut PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
    receipts: vector<Receipt<SaleCoin>>,
    ctx: &mut TxContext,
): VestingWallet<Witness, VestingScheduleParams, SaleCoin> {
    assert!(sale.vesting_schedule_params.is_some(), ENoVestingScheduleAttached);
    let payout = sale.claim_all_internal(receipts, ctx);

    let mut wallet = vesting_wallet::new<Witness, VestingScheduleParams, SaleCoin>(
        *sale.vesting_schedule_params.borrow(),
        ctx.sender(), // only buyer can claim
        ctx,
    );
    wallet.deposit(coin::from_balance(payout, ctx));

    wallet
}

/// Withdraw collected proceeds. Phase must be `Finalized`.
public fun withdraw_proceeds<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &mut PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
    cap: &SaleAdminCap<SaleCoin, PaymentCoin>,
): Balance<PaymentCoin> {
    assert!(cap.sale_id == object::id(sale), EWrongAdminCap);
    sale.phase.assert_finalized();
    let amount = sale.proceeds.value();
    let part = sale.proceeds.split(amount);
    event::emit(ProceedsWithdrawn<SaleCoin, PaymentCoin> {
        sale_id: object::id(sale),
        amount,
    });
    part
}

/// Withdraw unallocated inventory. Valid in `Finalized` or
/// `Cancelled`. Strictly the unreserved portion
/// (`inventory - total_allocated`); outstanding receipts remain
/// backed.
public fun withdraw_unsold_inventory<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &mut PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
    cap: &SaleAdminCap<SaleCoin, PaymentCoin>,
): Balance<SaleCoin> {
    assert!(cap.sale_id == object::id(sale), EWrongAdminCap);
    sale.phase.assert_terminal();
    let unallocated = sale.inventory.value() - sale.total_allocated;
    let part = sale.inventory.split(unallocated);
    event::emit(InventoryWithdrawn<SaleCoin, PaymentCoin> {
        sale_id: object::id(sale),
        amount: unallocated,
    });
    part
}

// === Failure path (Cancelled) ===

/// Refund a buyer's payment. Asserts
/// `ctx.sender() == receipt.buyer`. Destroys the receipt and pays
/// `receipt.paid` worth of `Coin<PaymentCoin>` out of the paired vault.
public fun refund<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &mut PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
    vault: &mut RefundVault<PaymentCoin>,
    receipt: Receipt<SaleCoin>,
    ctx: &mut TxContext,
): Balance<PaymentCoin> {
    sale.phase.assert_cancelled();
    assert!(receipt.sale_id() == object::id(sale), EReceiptSaleMismatch);
    assert!(receipt.buyer() == ctx.sender(), EBuyerOnly);
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

    payment
}

// === Views ===

public fun phase<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
): Phase {
    sale.phase
}

public fun raised<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
): u64 {
    sale.raised
}

/// Read the sale's curve configuration. Opaque to the sale; the
/// declaring `Curve` module interprets it to price purchases. Mirrors
/// `VestingWallet::schedule_params`.
public fun curve_params<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
): CurveParams { sale.curve_params }

public fun hard_cap<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
): u64 {
    sale.hard_cap
}

public fun soft_cap<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
): u64 {
    sale.soft_cap
}

public fun opens_at_ms<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
): u64 {
    sale.opens_at_ms
}

public fun closes_at_ms<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
): u64 {
    sale.closes_at_ms
}

public fun requires_allowlist<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
): bool { sale.requires_allowlist }

/// Read the sale's vesting schedule. Returns `Some(schedule)` if the
/// issuer called `set_vesting_schedule_params` during Init, otherwise `None`.
/// Vesting adapters read this to determine the redemption shape.
public fun vesting_schedule_params<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
): Option<VestingScheduleParams> {
    sale.vesting_schedule_params
}

public fun inventory_total<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
): u64 {
    sale.inventory.value()
}

public fun total_allocated<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
): u64 {
    sale.total_allocated
}

public fun inventory_remaining<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
): u64 {
    sale.inventory.value() - sale.total_allocated
}

public fun proceeds_amount<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
): u64 {
    sale.proceeds.value()
}

public fun is_open<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
    clock: &Clock,
): bool {
    if (!sale.phase.is_active()) { return false };
    let now = clock::timestamp_ms(clock);
    now >= sale.opens_at_ms && now <= sale.closes_at_ms
}

public fun has_reached_soft_cap<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
): bool {
    sale.raised >= sale.soft_cap
}

public fun has_reached_hard_cap<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
): bool {
    sale.raised >= sale.hard_cap
}

public fun cap_sale_id<SaleCoin, PaymentCoin>(c: &SaleAdminCap<SaleCoin, PaymentCoin>): ID {
    c.sale_id
}

// === Quote<C> - witness-gated pricing carrier ===
//
// A `Quote<C>` is the only way to drive `purchase` on a
// `PrefundedSale<C, _, _, _, _>`. The hot-potato has no abilities, so:
//
// - It can only be produced by `mint_quote`, which requires a value
//   of type `C: drop`. Since `C`'s constructor is private to the curve
//   module that declares it, only that module can mint quotes for `C`.
// - It cannot be stored, copied, or replayed across transactions.
// - It cannot be transferred to another address.
// - It cannot be discarded silently. The sale's `purchase` is the
//   single legal consumer (`unpack`).
//
// The carrier pins `sale_id` so a quote minted for sale A cannot be
// spent on sale B. The sale's `purchase` additionally asserts
// `quote.paid == coin::value(payment)` to bind the quote to its
// payment, and asserts `quote.allocation <= quote.paid * sale.max_rate`
// as a defense-in-depth bound against a buggy or dishonest curve.

/// Hot-potato carrying a curve-priced quote for a single purchase.
public struct Quote<phantom PaymentCoin> {
    sale_id: ID,
    payment: Balance<PaymentCoin>,
    allocation: u64,
}

/// Witness-gated quote constructor. The curve module declaring `C`
/// calls this from its `quote(..)` function after running whatever
/// pricing math it owns. The witness value is taken by value (`_w: C`)
/// so a caller cannot mint a quote without the declaring curve module's
/// cooperation.
public fun mint_quote<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
    _w: Curve,
    payment: Balance<PaymentCoin>,
    rate: u64,
): Quote<PaymentCoin> {
    assert!(payment.value() > 0, EZeroPayment);
    let allocation = (payment.value() as u128) * (rate as u128);
    assert!(allocation <= (std::u64::max_value!() as u128), EAllocationOverflow);
    Quote { sale_id: object::id(sale), payment, allocation: allocation as u64 }
}

/// Destructively read a quote. Library-internal: only sibling library
/// modules (the sale flavor's `purchase`) unpack quotes. Returns
/// `(sale_id, paid, allocation)`.
fun unpack<PaymentCoin>(q: Quote<PaymentCoin>): (ID, Balance<PaymentCoin>, u64) {
    let Quote { sale_id, payment, allocation } = q;
    (sale_id, payment, allocation)
}

public fun sale_id<PaymentCoin>(q: &Quote<PaymentCoin>): ID { q.sale_id }

public fun payment<PaymentCoin>(q: &Quote<PaymentCoin>): &Balance<PaymentCoin> { &q.payment }

public fun allocation<PaymentCoin>(q: &Quote<PaymentCoin>): u64 { q.allocation }

fun claim_internal<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &mut PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
    receipt: Receipt<SaleCoin>,
    ctx: &TxContext,
): Balance<SaleCoin> {
    sale.phase.assert_finalized();
    assert!(receipt.sale_id() == object::id(sale), EReceiptSaleMismatch);
    assert!(receipt.buyer() == ctx.sender(), EBuyerOnly);

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

    payout
}

fun claim_all_internal<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &mut PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
    mut receipts: vector<Receipt<SaleCoin>>,
    ctx: &TxContext,
): Balance<SaleCoin> {
    let mut total = balance::zero<SaleCoin>();
    while (!receipts.is_empty()) {
        let r = receipts.pop_back();
        total.join(sale.claim_internal(r, ctx));
    };
    receipts.destroy_empty();
    total
}

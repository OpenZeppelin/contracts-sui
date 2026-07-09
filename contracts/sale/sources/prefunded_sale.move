/// Fixed-price token sale.
///
/// The issuer pre-mints (or pre-acquires) the sale tokens and deposits
/// them as `Balance<SaleCoin>` inventory before activation. The sale draws
/// from that fixed inventory at `claim` time and never holds a
/// `TreasuryCap<SaleCoin>`.
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
///   `create_sale`. Bounds the maximum raise. At activation the sale
///   asserts `inventory >= required_inventory`, the backing amount the
///   curve commits to via its `ActivationTicket` (a fixed-rate curve
///   sets it to `hard_cap * rate`), so sold-out and hard-cap-reached
///   coincide. The cap is enforced **all-or-nothing**: a `purchase`
///   whose payment would push `raised` past `hard_cap` aborts in full
///   with `EHardCapExceeded` - there is no partial fill up to the
///   remaining capacity. See `purchase` for how buyers size a payment
///   near sell-out.
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
use openzeppelin_sale::receipt::{Self, Receipt};
use openzeppelin_sale::refund_vault::{RefundVault, RefundVaultCap};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::event;
use sui::table::{Self, Table};

// === Errors ===

// Auth

/// The supplied `SaleAdminCap` was issued for a different sale.
#[error(code = 0)]
const EWrongAdminCap: vector<u8> = "This admin capability does not control this sale";

/// A redemption path (`claim`, `refund`, ...) was called by an address other than
/// the receipt's `buyer`.
#[error(code = 1)]
const EBuyerOnly: vector<u8> = "Only the buyer who made this purchase can perform this action";

/// `cancel_emergency` was called after the sale window closed; use
/// `cancel_after_close` instead.
#[error(code = 2)]
const EEmergencyCancelAfterClose: vector<u8> =
    "Emergency cancellation is only allowed while the sale is still open";

// Time

/// `create_sale` was given `opens_at_ms >= closes_at_ms`.
#[error(code = 10)]
const EInvalidTimeRange: vector<u8> = "The sale must open before it closes";

/// A `purchase` was attempted outside the sale window `[opens_at_ms, closes_at_ms]`.
#[error(code = 11)]
const ESaleWindowClosed: vector<u8> = "The sale is not open for purchases at this time";

/// A close (`finalize` / `cancel_after_close`) was attempted while the window is
/// still open and the hard cap has not been reached.
#[error(code = 12)]
const ESaleWindowStillOpen: vector<u8> =
    "The sale cannot be closed yet: it is still open and has not sold out";

/// `share_and_activate` was called after `closes_at_ms` had already passed.
#[error(code = 13)]
const EActivationAfterClose: vector<u8> =
    "The sale cannot be activated after its closing time has passed";

// Pricing & accounting

/// `create_sale` was given `hard_cap == 0`; every sale must have a bounded raise.
#[error(code = 20)]
const EHardCapZero: vector<u8> = "The maximum raise must be greater than zero";

/// `create_sale` was given `soft_cap > hard_cap`.
#[error(code = 21)]
const EInvalidCapsOrdering: vector<u8> = "The minimum raise cannot exceed the maximum raise";

/// A quote was requested for a zero-value payment.
#[error(code = 22)]
const EZeroPayment: vector<u8> = "The payment must be greater than zero";

/// A purchase would push `raised + paid` past `u64::MAX`.
#[error(code = 23)]
const ERaisedOverflow: vector<u8> = "The total amount raised would be too large to represent";

/// A purchase would push `raised` past `hard_cap`.
#[error(code = 24)]
const EHardCapExceeded: vector<u8> = "This purchase would exceed the maximum raise";

/// At activation, `inventory` did not cover the backing the curve's
/// `ActivationTicket` requires.
#[error(code = 25)]
const EInsufficientInventoryAtActivate: vector<u8> =
    "Not enough tokens have been deposited to back the sale";

/// A quote's `allocation` (`paid * rate`) would exceed `u64::MAX`.
#[error(code = 26)]
const EAllocationOverflow: vector<u8> = "The token allocation would be too large to represent";

/// A purchase's `allocation` exceeded the sale's unallocated inventory
/// (`inventory - total_allocated`). Only reachable via a dishonest curve.
#[error(code = 27)]
const EInsufficientInventory: vector<u8> = "Not enough tokens remain available for this purchase";

// Caps

/// A purchase would push the buyer's cumulative payment past the configured
/// per-buyer cap.
#[error(code = 30)]
const EPerBuyerCapExceeded: vector<u8> = "This purchase would exceed the per-buyer limit";

/// A purchase's payment exceeded the consumed `AllowEntry`'s `max_amount`.
#[error(code = 31)]
const EPerEntryCapExceeded: vector<u8> =
    "This purchase would exceed the amount permitted by the allowlist entry";

/// `finalize` was called with `raised < soft_cap`.
#[error(code = 32)]
const ESoftCapNotMet: vector<u8> = "The sale cannot be finalized: the minimum raise was not met";

/// A cancel was attempted on a sale that has met its goal: `cancel_after_close` with
/// the soft cap reached or no soft cap configured, or `cancel_emergency` with the
/// soft cap reached.
#[error(code = 33)]
const ESoftCapMet: vector<u8> =
    "The sale cannot be cancelled: it has met its minimum raise, or none was set";

/// `cancel_emergency` was called on a sold-out sale (`raised >= hard_cap`); it must
/// `finalize`.
#[error(code = 34)]
const ESaleAlreadyComplete: vector<u8> =
    "The sale cannot be cancelled: it has sold out and must be finalized";

// Allowlist coupling

/// The sale requires an `AllowEntry` but `purchase` was called without one.
#[error(code = 40)]
const EAllowlistRequired: vector<u8> =
    "This sale requires an allowlist entry, but none was provided";

/// The sale does not require an `AllowEntry` but `purchase` was given one.
#[error(code = 41)]
const EAllowlistNotRequired: vector<u8> =
    "This sale does not use an allowlist, but an entry was provided";

/// `enable_allowlist` was called a second time on the same sale.
#[error(code = 42)]
const EAllowlistAlreadyEnabled: vector<u8> = "The allowlist has already been enabled for this sale";

// Vault coupling

/// `pair_refund_vault` was called after a vault had already been paired.
#[error(code = 50)]
const EVaultAlreadyPaired: vector<u8> = "A refund vault has already been paired with this sale";

/// `share_and_activate` was called before a refund vault was paired.
#[error(code = 51)]
const EVaultRequiredForActivate: vector<u8> =
    "The sale cannot be activated without a paired refund vault";

/// The vault passed to a sale operation is not the one paired with this sale; at
/// pairing time, the cap does not control the supplied vault.
#[error(code = 52)]
const EWrongVault: vector<u8> = "The provided refund vault is not the one paired with this sale";

/// The vault offered to `pair_refund_vault` was not in the `Active` state.
#[error(code = 53)]
const EVaultNotActive: vector<u8> = "The refund vault must be active when paired";

/// The vault offered to `pair_refund_vault` held a non-zero balance; pre-existing
/// funds would be stranded after finalize/cancel.
#[error(code = 54)]
const EVaultNotEmpty: vector<u8> =
    "The refund vault must be empty when paired, otherwise existing funds would be stranded";

// Receipts

/// A receipt passed to `claim` / `refund` was issued by a different sale.
#[error(code = 60)]
const EReceiptSaleMismatch: vector<u8> = "This receipt was issued by a different sale";

// Quote / curve coupling

/// A quote passed to `purchase` was minted for a different sale.
#[error(code = 61)]
const EQuoteSaleMismatch: vector<u8> = "This quote was issued for a different sale";

// Activation ticket

/// An activation ticket passed to `share_and_activate` was minted for a different
/// sale.
#[error(code = 62)]
const ETicketSaleMismatch: vector<u8> = "This activation ticket was issued for a different sale";

// Per-buyer cap configuration

/// `set_per_buyer_cap` was called a second time on the same sale.
#[error(code = 70)]
const EPerBuyerCapAlreadySet: vector<u8> = "The per-buyer limit has already been set";

/// `set_per_buyer_cap` was given `0`; a zero cap would block every buyer.
#[error(code = 71)]
const EPerBuyerCapZero: vector<u8> = "The per-buyer limit must be greater than zero";

// Vesting schedule configuration

/// `set_vesting_schedule_params` was called a second time on the same sale.
#[error(code = 80)]
const EVestingScheduleAlreadySet: vector<u8> = "The vesting schedule has already been set";

/// Plain `claim` was called on a sale that has a vesting schedule; redeem via
/// `claim_into_vesting`.
#[error(code = 81)]
const EClaimRequiresVesting: vector<u8> =
    "This sale uses vesting; tokens must be claimed into a vesting wallet";

/// `claim_into_vesting` was called on a sale with no vesting schedule; use `claim`.
#[error(code = 82)]
const ENoVestingScheduleAttached: vector<u8> =
    "This sale does not use vesting; claim the tokens directly";

// Phase

/// A phase-gated operation required the `Init` phase but the sale was past it.
#[error(code = 90)]
const ENotInit: vector<u8> = "The sale must be in the setup phase";

/// A phase-gated operation required the `Active` phase: the sale was not yet
/// activated, or has already closed.
#[error(code = 91)]
const ENotActive: vector<u8> = "The sale must be open";

/// A phase-gated operation required the `Finalized` phase, e.g. a claim before the
/// sale was finalized.
#[error(code = 92)]
const ENotFinalized: vector<u8> = "The sale must have closed successfully first";

/// A phase-gated operation required the `Cancelled` phase, e.g. a refund before the
/// sale was cancelled.
#[error(code = 93)]
const ENotCancelled: vector<u8> = "The sale must have been cancelled";

/// A phase-gated operation required a terminal phase (`Finalized` or `Cancelled`).
#[error(code = 94)]
const ENotTerminal: vector<u8> = "The sale must have ended";

// === Structs ===

/// A fixed-price, pre-funded token sale. Generic over a pricing `Curve` (and its
/// `CurveParams`), the `SaleCoin` being sold, the `PaymentCoin` collected, and the
/// `VestingScheduleParams` of an optional vesting policy. Created as an owned value
/// during setup, then shared on activation. See the module doc for the full
/// lifecycle and authority model.
public struct PrefundedSale<
    phantom Curve: drop,
    CurveParams: copy + drop + store,
    phantom SaleCoin,
    phantom PaymentCoin,
    VestingScheduleParams: copy + drop + store, // abilities required by `VestingWallet`
> has key {
    id: UID,
    /// Pre-funded sale tokens, drawn down as buyers claim.
    inventory: Balance<SaleCoin>,
    /// Sale tokens promised to outstanding receipts; always `<= inventory`. The
    /// remainder is the unallocated portion `withdraw_unsold_inventory` returns.
    total_allocated: u64,
    /// Payments collected so far. Paid out to the admin on success, or moved to the
    /// vault on cancel.
    proceeds: Balance<PaymentCoin>,
    /// Opaque curve configuration, fixed at construction; only the declaring `Curve`
    /// module interprets it.
    curve_params: CurveParams,
    /// Maximum raise. Always greater than zero.
    hard_cap: u64,
    /// Minimum raise required to finalize; `0` means no soft cap.
    soft_cap: u64,
    /// Total payment raised so far.
    raised: u64,
    /// Start of the purchase window (ms).
    opens_at_ms: u64,
    /// End of the purchase window (ms).
    closes_at_ms: u64,
    /// Current lifecycle phase.
    phase: Phase,
    /// Whether each purchase must consume an allowlist entry.
    requires_allowlist: bool,
    /// Id of the paired refund vault. `Some` once activated.
    refund_vault_id: Option<ID>,
    /// Controller cap for the paired vault, wrapped so it never leaves the sale.
    refund_vault_cap: Option<RefundVaultCap<PaymentCoin>>,
    /// Configured cumulative per-buyer payment cap; `None` if unset.
    per_buyer_cap: Option<u64>,
    /// Remaining per-buyer allowance, counting down from the cap. `Some` only when a
    /// per-buyer cap is set.
    contributions: Option<Table<address, u64>>,
    /// Optional issuer-defined vesting policy. When `Some`, redemption is via
    /// `claim_into_vesting` (which returns a funded `VestingWallet` and its
    /// `DestroyCap`) rather than `claim`. Fixed at construction; the buyer cannot
    /// influence it.
    vesting_schedule_params: Option<VestingScheduleParams>,
}

/// Lifecycle phases shared by every sale flavor.
///
/// Transitions:
///   - `Init      -> Active`                  via the flavor's `share_and_activate`
///   - `Active    -> Finalized`               via the flavor's `finalize`
///   - `Active    -> Cancelled`               via the flavor's `cancel_*`
///
/// `Finalized` and `Cancelled` are terminal.
public enum Phase has copy, drop, store {
    /// Sale exists but is not yet shared. Setup functions (deposit
    /// inventory, configure caps, pair vault, enable allowlist) run
    /// in this phase. Authority is implicit: holding the sale value
    /// by `&mut`.
    Init,
    /// Sale is shared. Purchases are accepted within
    /// `[opens_at_ms, closes_at_ms]`.
    Active,
    /// Successful close. Buyers can `claim`. Admin can withdraw
    /// proceeds and any unallocated inventory.
    Finalized,
    /// Failed close. Buyers can `refund` from the paired vault.
    /// Admin can withdraw unallocated inventory.
    Cancelled,
}

/// Admin capability for a single sale. Gates emergency cancellation and the proceeds
/// and unsold-inventory withdrawals; losing it never strands buyer funds. Bound to
/// its sale by id.
public struct SaleAdminCap<phantom SaleCoin, phantom PaymentCoin> has key, store {
    id: UID,
    /// Id of the sale this cap controls.
    sale_id: ID,
}

/// Witness-gated, single-use carrier for `share_and_activate`. Has no abilities, so
/// it must be minted and consumed in the same PTB. It pins `sale_id` and the curve's
/// committed `required_inventory`.
public struct ActivationTicket<phantom Curve: drop> {
    /// Id of the sale this ticket authorizes activation for.
    sale_id: ID,
    /// Inventory backing the curve commits to; checked at activation.
    required_inventory: u64,
}

// A `Quote<C>` is the only way to drive `purchase` on a
// `PrefundedSale<C, _, _, _, _>`. The hot-potato has no abilities, so:
//
// - It can only be produced by `mint_quote`, which requires a value
//   of type `C: drop`. Since `C`'s constructor is private to the curve
//   module that declares it, only that module can mint quotes for `C`.
// - It cannot be stored, copied, or replayed across transactions.
// - It cannot be transferred to another address.
// - It cannot be discarded silently. The sale's `purchase` is the
//   single legal consumer.
//
// The carrier pins `sale_id` so a quote minted for sale A cannot be
// spent on sale B, and it carries the payment balance itself, so the
// `allocation` and the funds it was priced for stay bound together
// through to `purchase`.
//
// The sale does NOT independently bound `allocation` against any
// sale-held rate - there is no `max_rate` field, and `purchase` accepts
// the curve's `allocation` verbatim. The curve is a trusted, first-party
// component: the witness gate (only the module declaring `C` can mint a
// `Quote` for a `PrefundedSale<C, ..>`) is the security boundary. The
// sale's only independent protections are inventory backing
// (`allocation <= inventory - total_allocated`) and u128 overflow guards.

/// Hot-potato carrying a curve-priced quote for a single purchase.
public struct Quote<phantom PaymentCoin> {
    /// Id of the sale this quote may be spent on.
    sale_id: ID,
    /// The buyer's payment, carried through to `purchase`.
    payment: Balance<PaymentCoin>,
    /// Curve-computed sale-token allocation for this payment.
    allocation: u64,
}

/// The reason a sale was cancelled, carried by `SaleCancelled`.
public enum CancelReason has copy, drop, store {
    /// The window closed below the minimum raise (`cancel_after_close`).
    SoftCapMissed,
    /// An admin cancelled while the sale was still open (`cancel_emergency`).
    AdminEmergency,
}

// === Events ===

/// Emitted by `create_sale` when a sale is created.
public struct SaleCreated<CurveParams, phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    hard_cap: u64,
    soft_cap: u64,
    opens_at_ms: u64,
    closes_at_ms: u64,
    curve_params: CurveParams,
}

/// Emitted by `deposit` when sale tokens are added to inventory.
public struct InventoryDeposited<phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    amount: u64,
    new_inventory: u64,
}

/// Emitted by `set_per_buyer_cap` when a per-buyer limit is configured.
public struct PerBuyerCapSet<phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    cap: u64,
}

/// Emitted by `set_vesting_schedule_params` when a vesting policy is attached.
public struct VestingScheduleParamsSet<
    phantom SaleCoin,
    phantom PaymentCoin,
    VestingScheduleParams: copy + drop,
> has copy, drop {
    sale_id: ID,
    params: VestingScheduleParams,
}

/// Emitted by `pair_refund_vault` when a vault is paired with the sale.
public struct RefundVaultPaired<phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    vault_id: ID,
}

/// Emitted by `enable_allowlist` when the sale switches into allowlist mode.
public struct AllowlistEnabled<phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    allowlist_admin_id: ID,
}

/// Emitted by `share_and_activate` when the sale goes live.
public struct SaleActivated<phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    activated_at_ms: u64,
}

/// Emitted by `purchase` for each successful buy.
public struct Purchased<phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    buyer: address,
    receipt_id: ID,
    paid: u64,
    allocation: u64,
    raised_after: u64,
    purchased_at_ms: u64,
}

/// Emitted by `finalize` when the sale closes successfully.
public struct SaleFinalized<phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    raised: u64,
    closed_at_ms: u64,
}

/// Emitted by `cancel_after_close` and `cancel_emergency` when the sale is cancelled.
public struct SaleCancelled<phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    raised: u64,
    reason: CancelReason,
    closed_at_ms: u64,
}

/// Emitted for each receipt redeemed through `claim` / `claim_all` (and the vesting
/// variants).
public struct Claimed<phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    buyer: address,
    receipt_id: ID,
    amount: u64,
}

/// Emitted by `refund` when a buyer recovers their payment.
public struct Refunded<phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    buyer: address,
    receipt_id: ID,
    amount: u64,
}

/// Emitted by `withdraw_proceeds` when the admin withdraws collected proceeds.
public struct ProceedsWithdrawn<phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    amount: u64,
}

/// Emitted by `withdraw_unsold_inventory` when the admin withdraws unallocated
/// inventory.
public struct InventoryWithdrawn<phantom SaleCoin, phantom PaymentCoin> has copy, drop {
    sale_id: ID,
    amount: u64,
}

// === Public Functions ===

// === Setup (Phase: Init) ===

/// Create a sale in `Init` phase. Returns the sale as an owned value plus its admin
/// cap. The caller threads the sale through setup calls in the same PTB and then
/// calls `share_and_activate` to transition to `Active`.
///
/// The sale is pricing-agnostic. `curve_params` is the opaque configuration the
/// `Curve` module interprets to price purchases; the sale stores it and never reads
/// it. Both the per-purchase `allocation` (via the `Quote`) and the activation
/// backing (`required_inventory`, via the `ActivationTicket`) are supplied by the
/// witness-gated curve module - the sale trusts them and does not re-derive them
/// (see the `Quote` section). Integrators build `curve_params` through the curve
/// module's own `params` constructor.
///
/// #### Parameters
/// - `curve_params`: The curve's stored configuration, opaque to the sale.
/// - `hard_cap`: Maximum raise, in `PaymentCoin` units.
/// - `soft_cap`: Minimum raise required to `finalize`; `0` means no soft cap.
/// - `opens_at_ms`: Start of the purchase window (ms).
/// - `closes_at_ms`: End of the purchase window (ms).
/// - `ctx`: Transaction context, used to allocate the sale and cap `UID`s.
///
/// #### Returns
/// - The owned `PrefundedSale` (in `Init` phase) and its `SaleAdminCap`.
///
/// #### Aborts
/// - `EHardCapZero` if `hard_cap == 0`.
/// - `EInvalidCapsOrdering` if `soft_cap > hard_cap`.
/// - `EInvalidTimeRange` if `opens_at_ms >= closes_at_ms`.
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
        phase: Phase::Init,
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

/// Deposit sale tokens into inventory. May be called multiple times during Init.
/// Authority is implicit: the sale is owned, so only the caller that created it can
/// pass it as `&mut`.
///
/// #### Parameters
/// - `sale`: The sale to fund, in `Init` phase.
/// - `inventory`: Sale tokens to add to the inventory balance.
///
/// #### Aborts
/// - `ENotInit` if the sale is not in `Init` phase.
/// - Arithmetic overflow if the deposit would push total inventory past `u64::MAX`.
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
    assert!(sale.phase.is_init(), ENotInit);
    let amount = inventory.value();
    sale.inventory.join(inventory);
    event::emit(InventoryDeposited<SaleCoin, PaymentCoin> {
        sale_id: object::id(sale),
        amount,
        new_inventory: sale.inventory.value(),
    });
}

/// Configure a cumulative per-buyer cap. The sum of every `purchase` payment a
/// single buyer makes to this sale must not exceed `per_buyer_cap`, enforced inside
/// `purchase` against the running `contributions[buyer]` total. One-shot.
///
/// #### Parameters
/// - `sale`: The sale to configure, in `Init` phase.
/// - `per_buyer_cap`: Cumulative payment cap per buyer.
/// - `ctx`: Transaction context, used to allocate the `contributions` table.
///
/// #### Aborts
/// - `ENotInit` if the sale is not in `Init` phase.
/// - `EPerBuyerCapAlreadySet` if a per-buyer cap is already configured.
/// - `EPerBuyerCapZero` if `per_buyer_cap == 0` (a zero cap would block every buyer).
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
    assert!(sale.phase.is_init(), ENotInit);
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
/// Once a schedule is attached, the plain `claim` path aborts and buyers must redeem
/// through `claim_into_vesting`, which returns a funded `VestingWallet` and its
/// `DestroyCap`. The library enforces this so a buyer cannot trivially bypass the
/// schedule. The schedule is **issuer-defined**: the buyer is the caller of the
/// redemption path and cannot supply or override these values.
///
/// #### Parameters
/// - `sale`: The sale to configure, in `Init` phase.
/// - `params`: The issuer-defined vesting schedule parameters, stored on the sale.
///
/// #### Aborts
/// - `ENotInit` if the sale is not in `Init` phase.
/// - `EVestingScheduleAlreadySet` if a schedule is already configured.
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
    assert!(sale.phase.is_init(), ENotInit);
    assert!(sale.vesting_schedule_params.is_none(), EVestingScheduleAlreadySet);
    sale.vesting_schedule_params.fill(params);
    event::emit(VestingScheduleParamsSet<SaleCoin, PaymentCoin, VestingScheduleParams> {
        sale_id: object::id(sale),
        params,
    });
}

/// Pair a refund vault with the sale. Required before activation. The vault is taken
/// by reference (for state inspection) and the cap by value (consumed into the sale,
/// never returned).
///
/// The vault must be empty: pre-existing funds would be stranded, since the sale
/// never exposes a way to withdraw arbitrary vault funds and `withdraw_all` requires
/// the `Closed` state (reachable only via the sale's `finalize`).
///
/// #### Parameters
/// - `sale`: The sale to pair the vault with, in `Init` phase.
/// - `vault`: The refund vault, inspected by reference. Must be `Active` and empty.
/// - `vault_cap`: The vault's controller cap, consumed into the sale.
///
/// #### Aborts
/// - `ENotInit` if the sale is not in `Init` phase.
/// - `EVaultAlreadyPaired` if a vault has already been paired.
/// - `EWrongVault` if `vault_cap` does not control `vault`.
/// - `EVaultNotActive` if `vault` is not in the `Active` state.
/// - `EVaultNotEmpty` if `vault` holds a non-zero balance.
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
    assert!(sale.phase.is_init(), ENotInit);
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

/// Switch the sale into compliance-gated mode and issue the single
/// `AllowlistAdmin<SaleCoin>`. The caller wraps the admin inside the compliance
/// module of their choice. After this, every `purchase` must consume an `AllowEntry`.
///
/// One-shot: a second admin would let two compliance modules mint entries
/// independently for the same sale, defeating the gating.
///
/// #### Parameters
/// - `sale`: The sale to switch into allowlist mode, in `Init` phase.
/// - `ctx`: Transaction context, used to allocate the admin's `UID`.
///
/// #### Returns
/// - The `AllowlistAdmin<SaleCoin>` for this sale, to be wrapped in a compliance
///   module.
///
/// #### Aborts
/// - `ENotInit` if the sale is not in `Init` phase.
/// - `EAllowlistAlreadyEnabled` if the allowlist is already enabled.
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
    assert!(sale.phase.is_init(), ENotInit);
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

/// Mint an `ActivationTicket<Curve>` for `sale`. Witness-gated: requires a value of
/// type `Curve`, whose constructor is private to the declaring curve module, so only
/// that module can mint a ticket for a `PrefundedSale<Curve, ..>`. Curve modules wrap
/// this (e.g. `fixed_rate_curve::activation_ticket`).
///
/// #### Parameters
/// - `sale`: The sale the ticket authorizes activation for.
/// - `_w`: The curve witness `Curve`; proves the caller is the declaring curve module.
/// - `required_inventory`: The inventory backing the curve commits to;
///   `share_and_activate` asserts `inventory >= required_inventory`.
///
/// #### Returns
/// - An `ActivationTicket<Curve>` pinned to this sale.
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

/// Transition `Init -> Active` and share the sale. Consumes both the sale and the
/// activation ticket.
///
/// The `required_inventory` carried by the ticket is the backing the curve commits
/// to (a fixed-rate curve sets it to `hard_cap * rate`, overflow-checked when the
/// ticket is minted). Provisioned honestly, sold-out and hard-cap-reached coincide,
/// so `purchase` never aborts with "out of inventory" before "exceeds cap".
/// Activation before `opens_at_ms` is allowed; activation after `closes_at_ms` is
/// not, since it would share a stale sale that is immediately finalizable or
/// cancellable with no purchase opportunity.
///
/// #### Parameters
/// - `sale`: The sale to activate, in `Init` phase. Consumed and shared.
/// - `ticket`: The curve's `ActivationTicket`, carrying `required_inventory`.
///   Consumed.
/// - `clock`: Sui `Clock`, read for the current timestamp.
///
/// #### Aborts
/// - `ETicketSaleMismatch` if `ticket` was minted for a different sale.
/// - `ENotInit` if the sale is not in `Init` phase.
/// - `EVaultRequiredForActivate` if no refund vault has been paired.
/// - `EActivationAfterClose` if `now >= closes_at_ms`.
/// - `EInsufficientInventoryAtActivate` if `inventory < required_inventory`.
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

    assert!(sale_id == ticket_sale_id, ETicketSaleMismatch);

    // The only way to hold a `PrefundedSale` by value is straight out of `create_sale`,
    // so this is a purely defensive check.
    assert!(sale.phase.is_init(), ENotInit);
    assert!(sale.refund_vault_cap.is_some(), EVaultRequiredForActivate);

    let activated_at_ms = clock.timestamp_ms();
    assert!(activated_at_ms < sale.closes_at_ms, EActivationAfterClose);

    assert!(sale.inventory.value() >= required_inventory, EInsufficientInventoryAtActivate);

    sale.phase = Phase::Active;
    transfer::share_object(sale);
    event::emit(SaleActivated<SaleCoin, PaymentCoin> {
        sale_id,
        activated_at_ms,
    });
}

// === Active phase ===

/// Buy sale tokens. Delivers a fresh `Receipt<SaleCoin>` to `ctx.sender()` (the
/// buyer) and adds the payment to `sale.proceeds`. The receipt is transferred, not
/// returned.
///
/// Pricing is supplied by `quote`, a witness-gated `Quote<PaymentCoin>` that only
/// the sale's `Curve` module can mint (see `mint_quote`). The quote carries the
/// buyer's payment balance together with the curve-computed `allocation`, and is
/// bound to this sale by `quote.sale_id`.
///
/// **The curve is trusted.** `purchase` accepts the quote's `allocation` verbatim;
/// the sale does not re-derive or bound it against any sale-held rate (there is no
/// `max_rate` field). The only checks on it are inventory backing
/// (`allocation <= inventory - total_allocated`) and overflow. Correct pricing is
/// delegated to the witness-gated curve module - the witness gate (only the
/// declaring curve can mint a `Quote` for its sale type) is what makes this safe.
/// See the `Quote` section below.
///
/// **Hard cap is all-or-nothing.** The sale never partially fills a purchase up to the
/// remaining capacity and refunds the rest. This is deliberate: the `Quote` carries a
/// single curve-computed `allocation` priced for the exact `paid` amount, and honoring
/// a partial payment would require re-pricing the accepted portion, which only the curve
/// can do. Near sell-out, buyers must size their payment to the remaining capacity -
/// `hard_cap() - raised()` - off-chain before minting the quote. A payment for the exact
/// remaining capacity closes the sale (`raised == hard_cap`); anything larger reverts.
///
/// All arithmetic on user-controlled inputs (`raised + paid`, `contribution + paid`)
/// is widened to `u128` and bounds-checked before downcasting, so oversized payments
/// abort with a typed error rather than a native arithmetic overflow.
///
/// #### Parameters
/// - `sale`: The shared sale, in `Active` phase.
/// - `quote`: A `Quote<PaymentCoin>` minted by the sale's curve module, carrying the
///   payment and the curve-computed allocation. Consumed.
/// - `allow`: `Some(entry)` iff the sale `requires_allowlist`; the entry is consumed
///   and its `sale_id` and `buyer` are asserted. `None` otherwise.
/// - `clock`: Sui `Clock`, read for the current timestamp.
/// - `ctx`: Transaction context; `ctx.sender()` is the buyer the receipt is
///   delivered to.
///
/// #### Aborts
/// - `ENotActive` if the sale is not in `Active` phase.
/// - `EQuoteSaleMismatch` if `quote` was minted for a different sale.
/// - `ESaleWindowClosed` if `now` is outside `[opens_at_ms, closes_at_ms]`.
/// - `EAllowlistRequired` if the sale requires an entry but `allow` is `None`.
/// - `EAllowlistNotRequired` if the sale does not require an entry but `allow` is
///   `Some`.
/// - `allowlist::EWrongSaleId` / `allowlist::EWrongBuyer` if the provided entry was
///   issued for a different sale or buyer.
/// - `ERaisedOverflow` if `raised + paid` would exceed `u64::MAX`.
/// - `EHardCapExceeded` if `raised + paid` would exceed `hard_cap`.
/// - `EPerEntryCapExceeded` if `paid` exceeds the entry's `max_amount`.
/// - `EPerBuyerCapExceeded` if `paid` exceeds the buyer's remaining per-buyer cap.
/// - `EInsufficientInventory` if `allocation` exceeds unallocated inventory (only
///   reachable via a dishonest curve).
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
    assert!(sale.phase.is_active(), ENotActive);

    let sale_id = object::id(sale);
    let Quote { sale_id: quote_sale_id, payment, allocation } = quote;

    assert!(quote_sale_id == sale_id, EQuoteSaleMismatch);

    let now = clock.timestamp_ms();
    assert!(now >= sale.opens_at_ms && now <= sale.closes_at_ms, ESaleWindowClosed);

    let buyer = ctx.sender();
    let entry_max = if (sale.requires_allowlist) {
        assert!(allow.is_some(), EAllowlistRequired);
        let entry = allow.destroy_some();
        entry.consume(sale_id, buyer)
    } else {
        assert!(allow.is_none(), EAllowlistNotRequired);
        allow.destroy_none();
        0
    };

    // `mint_quote` already guaranteed the payment is non-zero.
    let paid = payment.value();
    let u64_max = std::u64::max_value!();

    assert!(u64_max - paid >= sale.raised, ERaisedOverflow);
    let new_raised = sale.raised + paid;
    assert!(new_raised <= sale.hard_cap, EHardCapExceeded);

    assert!(entry_max == 0 || paid <= entry_max, EPerEntryCapExceeded);

    // `contributions[buyer]` holds the buyer's *remaining* allowance: seeded at the
    // cap on first purchase, then counted down.
    if (sale.per_buyer_cap.is_some()) {
        let contributions = sale.contributions.borrow_mut();
        if (!contributions.contains(buyer)) {
            let per_cap = *sale.per_buyer_cap.borrow();
            contributions.add(buyer, per_cap);
        };
        let cap = contributions.borrow_mut(buyer);
        assert!(paid <= *cap, EPerBuyerCapExceeded);
        *cap = *cap - paid;
    };

    let unallocated = sale.inventory.value() - sale.total_allocated;
    assert!(allocation <= unallocated, EInsufficientInventory);

    sale.total_allocated = sale.total_allocated + allocation;
    sale.raised = new_raised;
    sale.proceeds.join(payment);

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

/// Close the sale as a success. **Permissionless.** Also transitions the paired
/// vault to `Closed` in the same call, so the admin can later withdraw proceeds.
///
/// Allowed when the phase is `Active` and either the window has closed with the soft
/// cap met (`now > closes_at_ms && raised >= soft_cap`), or the hard cap has been
/// reached (`raised >= hard_cap`, which closes the sale early).
///
/// #### Parameters
/// - `sale`: The shared sale, in `Active` phase.
/// - `vault`: The paired refund vault, flipped to `Closed`.
/// - `clock`: Sui `Clock`, read for the current timestamp.
///
/// #### Aborts
/// - `ENotActive` if the sale is not in `Active` phase.
/// - `ESaleWindowStillOpen` if the window is still open and the hard cap is not
///   reached.
/// - `ESoftCapNotMet` if `raised < soft_cap`.
/// - `EWrongVault` if `vault` is not the one paired with this sale.
///
/// Propagated from the paired vault via `flip_to_closed` (guarded by the sale's
/// invariants - the paired vault always matches and is active while the sale is
/// open - so unreachable in normal operation):
/// - `refund_vault::EWrongVaultCap`, `refund_vault::ENotActiveState`.
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
    assert!(sale.phase.is_active(), ENotActive);
    let now = clock.timestamp_ms();
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

    sale.phase = Phase::Finalized;
    event::emit(SaleFinalized<SaleCoin, PaymentCoin> {
        sale_id: object::id(sale),
        raised: sale.raised,
        closed_at_ms: now,
    });
}

/// Close the sale as a soft-cap miss. **Permissionless.** Drains `sale.proceeds`
/// into the paired vault and flips the vault to `Refunding`; buyers then call
/// `refund` individually.
///
/// Allowed when the phase is `Active`, the window has closed (`now > closes_at_ms`),
/// a soft cap is configured (`soft_cap > 0`), and it was missed (`raised < soft_cap`).
///
/// #### Parameters
/// - `sale`: The shared sale, in `Active` phase.
/// - `vault`: The paired refund vault, flipped to `Refunding` and funded with the
///   proceeds.
/// - `clock`: Sui `Clock`, read for the current timestamp.
///
/// #### Aborts
/// - `ENotActive` if the sale is not in `Active` phase.
/// - `ESaleWindowStillOpen` if the window has not yet closed.
/// - `ESoftCapMet` if no soft cap is configured or `raised >= soft_cap`.
/// - `EWrongVault` if `vault` is not the one paired with this sale.
///
/// Propagated through the internal cancel path (guarded by the sale's invariants, so
/// unreachable in normal operation):
/// - `refund_vault::EWrongVaultCap` and `refund_vault::ENotActiveState` (depositing
///   proceeds into the vault and flipping it to refunding);
/// - `phase::EAlreadyCancelled` (the phase transition).
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
    assert!(sale.phase.is_active(), ENotActive);
    let now = clock.timestamp_ms();
    assert!(now > sale.closes_at_ms, ESaleWindowStillOpen);
    assert!(sale.soft_cap > 0 && sale.raised < sale.soft_cap, ESoftCapMet);

    sale.do_cancel(vault, CancelReason::SoftCapMissed, now);
}

/// Emergency cancellation. **Admin-only** (gated by `SaleAdminCap`). Drains
/// `sale.proceeds` into the vault and flips the vault to `Refunding`.
///
/// Allowed when the phase is `Active` and the window has not yet closed
/// (`now <= closes_at_ms`); pre-open cancel (`now < opens_at_ms`) is permitted, which
/// is useful when a bug or compliance issue is found before any purchase. The guards
/// prevent rugging a successful sale: a sold-out sale (`raised >= hard_cap`) or one
/// that has met its soft cap must `finalize` instead.
///
/// #### Parameters
/// - `sale`: The shared sale, in `Active` phase.
/// - `cap`: The sale's admin cap.
/// - `vault`: The paired refund vault, flipped to `Refunding` and funded with the
///   proceeds.
/// - `clock`: Sui `Clock`, read for the current timestamp.
///
/// #### Aborts
/// - `EWrongAdminCap` if `cap` was issued for a different sale.
/// - `ENotActive` if the sale is not in `Active` phase.
/// - `EEmergencyCancelAfterClose` if `now > closes_at_ms`.
/// - `ESaleAlreadyComplete` if `raised >= hard_cap`.
/// - `ESoftCapMet` if a soft cap is configured and `raised >= soft_cap`.
/// - `EWrongVault` if `vault` is not the one paired with this sale.
///
/// Propagated through the internal cancel path (guarded by the sale's invariants, so
/// unreachable in normal operation):
/// - `refund_vault::EWrongVaultCap` and `refund_vault::ENotActiveState` (depositing
///   proceeds into the vault and flipping it to refunding);
/// - `phase::EAlreadyCancelled` (the phase transition).
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
    assert!(sale.phase.is_active(), ENotActive);
    let now = clock.timestamp_ms();
    assert!(now <= sale.closes_at_ms, EEmergencyCancelAfterClose);
    assert!(sale.raised < sale.hard_cap, ESaleAlreadyComplete);
    assert!(sale.soft_cap == 0 || sale.raised < sale.soft_cap, ESoftCapMet);

    sale.do_cancel(vault, CancelReason::AdminEmergency, now);
}

// === Success path (Finalized) ===

/// Redeem a receipt for its sale-token allocation, returned as `Balance<SaleCoin>`.
/// Destroys the receipt. The buyer wraps the balance into a `Coin` and transfers it.
///
/// A sale with a vesting schedule must redeem via `claim_into_vesting` instead; this
/// is the library's enforcement that the schedule cannot be bypassed by the
/// immediate-distribution path.
///
/// #### Parameters
/// - `sale`: The shared sale, in `Finalized` phase.
/// - `receipt`: The buyer's receipt. Consumed.
/// - `ctx`: Transaction context; `ctx.sender()` must equal `receipt.buyer`.
///
/// #### Returns
/// - A `Balance<SaleCoin>` of exactly the receipt's `allocation`, split from
///   inventory.
///
/// #### Aborts
/// - `EClaimRequiresVesting` if the sale has a vesting schedule attached.
/// - `ENotFinalized` if the sale is not in `Finalized` phase.
/// - `EReceiptSaleMismatch` if `receipt` was issued by a different sale.
/// - `EBuyerOnly` if `ctx.sender()` is not the receipt's buyer.
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

/// Batch helper: claim several receipts in one call, summing their allocations into
/// one `Balance<SaleCoin>`. Inherits the no-vesting guard from `claim`. Aborts the
/// whole call (releasing nothing) if any receipt is invalid.
///
/// #### Parameters
/// - `sale`: The shared sale, in `Finalized` phase.
/// - `receipts`: The buyer's receipts. All consumed.
/// - `ctx`: Transaction context; `ctx.sender()` must equal each receipt's buyer.
///
/// #### Returns
/// - A `Balance<SaleCoin>` summing every receipt's `allocation`.
///
/// #### Aborts
/// - `EClaimRequiresVesting` if the sale has a vesting schedule attached.
/// - `ENotFinalized` if the sale is not in `Finalized` phase.
/// - `EReceiptSaleMismatch` if any receipt was issued by a different sale.
/// - `EBuyerOnly` if `ctx.sender()` is not the buyer of any receipt.
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

/// Redeem a receipt directly into a funded
/// `VestingWallet<Witness, VestingScheduleParams, SaleCoin>` from
/// `openzeppelin_finance`. The only redemption path for a vesting-attached sale.
///
/// The wallet is constructed with the sale's issuer-defined schedule params and
/// `beneficiary == ctx.sender()` (the asserted buyer), then funded with exactly the
/// claimed `allocation`. The buyer cannot influence the schedule - it is fixed at
/// sale construction. The caller chooses the vesting curve by supplying its `Witness`
/// type (e.g. `vesting_wallet_linear::Linear`); the witness must be the curve module
/// that interprets the sale's `VestingScheduleParams`, or the returned wallet cannot
/// be released.
///
/// Alongside the wallet, `vesting_wallet::new` mints a `DestroyCap` bound to it - the
/// teardown authority, deliberately decoupled from `beneficiary`. This call returns
/// that cap to the buyer to route as they see fit; it is required later to tear the
/// drained wallet down. The wallet's `release` pays into the beneficiary's address
/// balance (no `Coin` object is minted), so the buyer never needs to hold the wallet
/// to receive funds.
///
/// #### Parameters
/// - `sale`: The shared sale, in `Finalized` phase, with a vesting schedule attached.
/// - `receipt`: The buyer's receipt. Consumed.
/// - `ctx`: Transaction context; `ctx.sender()` must equal `receipt.buyer` and
///   becomes the wallet's beneficiary.
///
/// #### Returns
/// - A `VestingWallet<Witness, VestingScheduleParams, SaleCoin>` funded with the
///   receipt's `allocation`.
/// - The wallet's `vesting_wallet::DestroyCap` - the authority to tear the wallet
///   down once it is drained.
///
/// #### Aborts
/// - `ENoVestingScheduleAttached` if the sale has no vesting schedule (use `claim`).
/// - `ENotFinalized` if the sale is not in `Finalized` phase.
/// - `EReceiptSaleMismatch` if `receipt` was issued by a different sale.
/// - `EBuyerOnly` if `ctx.sender()` is not the receipt's buyer.
/// - `vesting_wallet::EBalanceOverflow`, propagated when funding the wallet (guarded:
///   a single receipt's allocation always fits in `u64`, so unreachable in normal
///   operation).
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
): (VestingWallet<Witness, VestingScheduleParams, SaleCoin>, vesting_wallet::DestroyCap) {
    assert!(sale.vesting_schedule_params.is_some(), ENoVestingScheduleAttached);
    let payout = sale.claim_internal(receipt, ctx);

    let (mut wallet, destroy_cap) = vesting_wallet::new<Witness, VestingScheduleParams, SaleCoin>(
        *sale.vesting_schedule_params.borrow(),
        ctx.sender(), // only buyer can claim
        ctx,
    );
    wallet.deposit(payout);

    (wallet, destroy_cap)
}

/// Batch variant of `claim_into_vesting`: redeem several receipts into one funded
/// `VestingWallet<Witness, VestingScheduleParams, SaleCoin>`, summing their
/// allocations. Aborts the whole call if any receipt is invalid.
///
/// #### Parameters
/// - `sale`: The shared sale, in `Finalized` phase, with a vesting schedule attached.
/// - `receipts`: The buyer's receipts. All consumed.
/// - `ctx`: Transaction context; `ctx.sender()` must equal each receipt's buyer and
///   becomes the wallet's beneficiary.
///
/// #### Returns
/// - A single `VestingWallet<Witness, VestingScheduleParams, SaleCoin>` funded with
///   the summed allocations.
/// - The wallet's `vesting_wallet::DestroyCap` - the authority to tear the wallet
///   down once it is drained.
///
/// #### Aborts
/// - `ENoVestingScheduleAttached` if the sale has no vesting schedule (use
///   `claim_all`).
/// - `ENotFinalized` if the sale is not in `Finalized` phase.
/// - `EReceiptSaleMismatch` if any receipt was issued by a different sale.
/// - `EBuyerOnly` if `ctx.sender()` is not the buyer of any receipt.
/// - `vesting_wallet::EBalanceOverflow`, propagated when funding the wallet (guarded:
///   the summed allocation never exceeds total inventory and fits in `u64`, so
///   unreachable in normal operation).
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
): (VestingWallet<Witness, VestingScheduleParams, SaleCoin>, vesting_wallet::DestroyCap) {
    assert!(sale.vesting_schedule_params.is_some(), ENoVestingScheduleAttached);
    let payout = sale.claim_all_internal(receipts, ctx);

    let (mut wallet, destroy_cap) = vesting_wallet::new<Witness, VestingScheduleParams, SaleCoin>(
        *sale.vesting_schedule_params.borrow(),
        ctx.sender(), // only buyer can claim
        ctx,
    );
    wallet.deposit(payout);

    (wallet, destroy_cap)
}

/// Withdraw the collected proceeds. **Admin-only.** Phase must be `Finalized`.
///
/// Idempotent: a second call (or one against zero proceeds) returns an empty balance
/// and emits no `ProceedsWithdrawn` event.
///
/// #### Parameters
/// - `sale`: The shared sale, in `Finalized` phase.
/// - `cap`: The sale's admin cap.
///
/// #### Returns
/// - A `Balance<PaymentCoin>` holding all collected proceeds (`raised`).
///
/// #### Aborts
/// - `EWrongAdminCap` if `cap` was issued for a different sale.
/// - `ENotFinalized` if the sale is not in `Finalized` phase.
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
    assert!(sale.phase.is_finalized(), ENotFinalized);
    let amount = sale.proceeds.value();
    let part = sale.proceeds.split(amount);
    if (amount > 0) {
        event::emit(ProceedsWithdrawn<SaleCoin, PaymentCoin> {
            sale_id: object::id(sale),
            amount,
        });
    };
    part
}

/// Withdraw unallocated inventory. **Admin-only.** Valid in `Finalized` or
/// `Cancelled`. Returns strictly the unreserved portion
/// (`inventory - total_allocated`); inventory backing outstanding receipts stays put.
///
/// Idempotent: a second call (or one with nothing unallocated) returns an empty
/// balance and emits no `InventoryWithdrawn` event.
///
/// #### Parameters
/// - `sale`: The shared sale, in a terminal (`Finalized` or `Cancelled`) phase.
/// - `cap`: The sale's admin cap.
///
/// #### Returns
/// - A `Balance<SaleCoin>` holding the unallocated inventory slack.
///
/// #### Aborts
/// - `EWrongAdminCap` if `cap` was issued for a different sale.
/// - `ENotTerminal` if the sale is neither in the `Finalized` nor `Cancelled` phase.
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
    assert!(sale.phase.is_finalized() || sale.phase.is_cancelled(), ENotTerminal);
    let unallocated = sale.inventory.value() - sale.total_allocated;
    let part = sale.inventory.split(unallocated);
    if (unallocated > 0) {
        event::emit(InventoryWithdrawn<SaleCoin, PaymentCoin> {
            sale_id: object::id(sale),
            amount: unallocated,
        });
    };
    part
}

// === Failure path (Cancelled) ===

/// Refund a buyer's payment from the paired vault. **Permissionless** but
/// buyer-bound. Destroys the receipt and returns `receipt.paid` as
/// `Balance<PaymentCoin>`, drawn from the vault.
///
/// #### Parameters
/// - `sale`: The shared sale, in `Cancelled` phase.
/// - `vault`: The paired refund vault, in `Refunding` state.
/// - `receipt`: The buyer's receipt. Consumed.
/// - `ctx`: Transaction context; `ctx.sender()` must equal `receipt.buyer`.
///
/// #### Returns
/// - A `Balance<PaymentCoin>` of exactly the receipt's `paid` amount.
///
/// #### Aborts
/// - `ENotCancelled` if the sale is not in `Cancelled` phase.
/// - `EReceiptSaleMismatch` if `receipt` was issued by a different sale.
/// - `EBuyerOnly` if `ctx.sender()` is not the receipt's buyer.
/// - `EWrongVault` if `vault` is not the one paired with this sale.
///
/// Propagated from the paired vault via `release_balance` (guarded by the sale's
/// refund-solvency invariant, so unreachable in normal operation):
/// - `refund_vault::EWrongVaultCap`, `refund_vault::ENotRefundingState`,
///   `refund_vault::EInsufficientLocked`.
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
    assert!(sale.phase.is_cancelled(), ENotCancelled);
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

// === Quote ===

/// Witness-gated quote constructor. The curve module declaring `Curve` calls this
/// from its `quote(..)` function after running whatever pricing math it owns. The
/// witness is taken by value (`_w: Curve`), so a caller cannot mint a quote without
/// the declaring curve module's cooperation.
///
/// #### Parameters
/// - `sale`: The sale the quote is bound to (by id).
/// - `_w`: The curve witness `Curve`; proves the caller is the declaring curve
///   module.
/// - `payment`: The buyer's payment, moved into the returned `Quote`.
/// - `rate`: Sale tokens allocated per payment unit, supplied by the curve; the
///   allocation is `payment.value() * rate`.
///
/// #### Returns
/// - A single-use `Quote<PaymentCoin>` pinned to this sale, carrying `payment` and
///   the computed allocation.
///
/// #### Aborts
/// - `EZeroPayment` if `payment` has zero value.
/// - `EAllocationOverflow` if `payment.value() * rate` would exceed `u64::MAX`.
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

// === View helpers ===

/// The sale's current lifecycle phase.
///
/// #### Parameters
/// - `sale`: The sale to query.
///
/// #### Returns
/// - The current `Phase` (`Init`, `Active`, `Finalized`, or `Cancelled`).
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

/// The total payment raised so far, in `PaymentCoin` units.
///
/// #### Parameters
/// - `sale`: The sale to query.
///
/// #### Returns
/// - The amount raised.
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

/// Read the sale's curve configuration. Opaque to the sale; the declaring `Curve`
/// module interprets it to price purchases. Mirrors `VestingWallet`'s
/// `schedule_params`.
///
/// #### Parameters
/// - `sale`: The sale to query.
///
/// #### Returns
/// - The stored `CurveParams`.
public fun curve_params<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
): CurveParams { sale.curve_params }

/// The configured hard cap (maximum raise), in `PaymentCoin` units.
///
/// #### Parameters
/// - `sale`: The sale to query.
///
/// #### Returns
/// - The hard cap.
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

/// The configured soft cap (minimum raise to finalize); `0` means no soft cap.
///
/// #### Parameters
/// - `sale`: The sale to query.
///
/// #### Returns
/// - The soft cap, or `0` if none.
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

/// The start of the purchase window (ms).
///
/// #### Parameters
/// - `sale`: The sale to query.
///
/// #### Returns
/// - The `opens_at_ms` timestamp.
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

/// The end of the purchase window (ms).
///
/// #### Parameters
/// - `sale`: The sale to query.
///
/// #### Returns
/// - The `closes_at_ms` timestamp.
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

/// Whether purchases require an `AllowEntry` (allowlist mode).
///
/// #### Parameters
/// - `sale`: The sale to query.
///
/// #### Returns
/// - `true` if the allowlist is enabled.
public fun requires_allowlist<
    Curve: drop,
    CurveParams: copy + drop + store,
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<Curve, CurveParams, SaleCoin, PaymentCoin, VestingScheduleParams>,
): bool { sale.requires_allowlist }

/// Read the sale's vesting schedule. Vesting adapters read this to determine the
/// redemption shape.
///
/// #### Parameters
/// - `sale`: The sale to query.
///
/// #### Returns
/// - `Some(params)` if the issuer called `set_vesting_schedule_params` during Init,
///   otherwise `None`.
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

/// Total inventory currently held by the sale (allocated plus unallocated).
///
/// #### Parameters
/// - `sale`: The sale to query.
///
/// #### Returns
/// - The total inventory balance.
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

/// Sale tokens promised to outstanding (unredeemed) receipts.
///
/// #### Parameters
/// - `sale`: The sale to query.
///
/// #### Returns
/// - The total currently allocated.
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

/// Unallocated inventory: `inventory_total - total_allocated`.
///
/// #### Parameters
/// - `sale`: The sale to query.
///
/// #### Returns
/// - The unallocated inventory available to `withdraw_unsold_inventory`.
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

/// Payment currently held by the sale as proceeds (before withdrawal or cancel).
///
/// #### Parameters
/// - `sale`: The sale to query.
///
/// #### Returns
/// - The proceeds balance amount.
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

/// Whether the sale is currently accepting purchases: `Active` and within the
/// purchase window at the clock's current time.
///
/// #### Parameters
/// - `sale`: The sale to query.
/// - `clock`: Sui `Clock`, read for the current timestamp.
///
/// #### Returns
/// - `true` if a `purchase` would pass its phase and window checks right now.
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
    if (sale.phase != Phase::Active) { return false };
    let now = clock.timestamp_ms();
    now >= sale.opens_at_ms && now <= sale.closes_at_ms
}

/// Whether `raised >= soft_cap`. Always `true` when no soft cap is configured
/// (`soft_cap == 0`).
///
/// #### Parameters
/// - `sale`: The sale to query.
///
/// #### Returns
/// - `true` if the soft cap has been met.
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

/// Whether `raised >= hard_cap` (the sale is sold out and can `finalize` early).
///
/// #### Parameters
/// - `sale`: The sale to query.
///
/// #### Returns
/// - `true` if the hard cap has been reached.
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

/// The id of the sale this admin cap controls.
///
/// #### Parameters
/// - `c`: The admin cap to read.
///
/// #### Returns
/// - The controlled sale's id.
public fun cap_sale_id<SaleCoin, PaymentCoin>(c: &SaleAdminCap<SaleCoin, PaymentCoin>): ID {
    c.sale_id
}

/// The id of the sale this quote was minted for.
///
/// #### Parameters
/// - `q`: The quote to read.
///
/// #### Returns
/// - The bound sale's id.
public fun sale_id<PaymentCoin>(q: &Quote<PaymentCoin>): ID { q.sale_id }

/// The payment balance carried by this quote.
///
/// #### Parameters
/// - `q`: The quote to read.
///
/// #### Returns
/// - A reference to the carried payment balance.
public fun payment<PaymentCoin>(q: &Quote<PaymentCoin>): &Balance<PaymentCoin> { &q.payment }

/// The curve-computed allocation this quote will deliver on purchase.
///
/// #### Parameters
/// - `q`: The quote to read.
///
/// #### Returns
/// - The allocation in `SaleCoin`'s smallest units.
public fun allocation<PaymentCoin>(q: &Quote<PaymentCoin>): u64 { q.allocation }

// === Package Functions ===

/// True if the phase is `Init`.
public(package) fun is_init(p: &Phase): bool {
    match (p) {
        Phase::Init => true,
        _ => false,
    }
}

/// True if the phase is `Active`.
public(package) fun is_active(p: &Phase): bool {
    match (p) {
        Phase::Active => true,
        _ => false,
    }
}

/// True if the phase is `Finalized`.
public(package) fun is_finalized(p: &Phase): bool {
    match (p) {
        Phase::Finalized => true,
        _ => false,
    }
}

/// True if the phase is `Cancelled`.
public(package) fun is_cancelled(p: &Phase): bool {
    match (p) {
        Phase::Cancelled => true,
        _ => false,
    }
}

// === Private Functions ===

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

    sale.phase = Phase::Cancelled;

    event::emit(SaleCancelled<SaleCoin, PaymentCoin> {
        sale_id: object::id(sale),
        raised: sale.raised,
        reason,
        closed_at_ms: now,
    });
}

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
    assert!(sale.phase.is_finalized(), ENotFinalized);
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
    assert!(sale.phase.is_finalized(), ENotFinalized);
    let mut total = balance::zero<SaleCoin>();
    while (!receipts.is_empty()) {
        let r = receipts.pop_back();
        total.join(sale.claim_internal(r, ctx));
    };
    receipts.destroy_empty();
    total
}

// === Test-Only Helpers ===
//
// Event struct fields are module-private, so tests in other modules cannot build
// an expected event to compare against `event::events_by_type`. These mirror the
// `test_new_*` seam used by `openzeppelin_finance::vesting_wallet`.

/// Build a `SaleCreated` event value for asserting against `event::events_by_type`.
#[test_only]
public fun test_new_sale_created<CurveParams: copy + drop, SaleCoin, PaymentCoin>(
    sale_id: ID,
    hard_cap: u64,
    soft_cap: u64,
    opens_at_ms: u64,
    closes_at_ms: u64,
    curve_params: CurveParams,
): SaleCreated<CurveParams, SaleCoin, PaymentCoin> {
    SaleCreated { sale_id, hard_cap, soft_cap, opens_at_ms, closes_at_ms, curve_params }
}

/// Build an `InventoryDeposited` event value for asserting against `event::events_by_type`.
#[test_only]
public fun test_new_inventory_deposited<SaleCoin, PaymentCoin>(
    sale_id: ID,
    amount: u64,
    new_inventory: u64,
): InventoryDeposited<SaleCoin, PaymentCoin> {
    InventoryDeposited { sale_id, amount, new_inventory }
}

/// Build a `PerBuyerCapSet` event value for asserting against `event::events_by_type`.
#[test_only]
public fun test_new_per_buyer_cap_set<SaleCoin, PaymentCoin>(
    sale_id: ID,
    cap: u64,
): PerBuyerCapSet<SaleCoin, PaymentCoin> {
    PerBuyerCapSet { sale_id, cap }
}

/// Build a `VestingScheduleParamsSet` event value for asserting against
/// `event::events_by_type`.
#[test_only]
public fun test_new_vesting_schedule_params_set<
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop,
>(
    sale_id: ID,
    params: VestingScheduleParams,
): VestingScheduleParamsSet<SaleCoin, PaymentCoin, VestingScheduleParams> {
    VestingScheduleParamsSet { sale_id, params }
}

/// Build a `RefundVaultPaired` event value for asserting against `event::events_by_type`.
#[test_only]
public fun test_new_refund_vault_paired<SaleCoin, PaymentCoin>(
    sale_id: ID,
    vault_id: ID,
): RefundVaultPaired<SaleCoin, PaymentCoin> {
    RefundVaultPaired { sale_id, vault_id }
}

/// Build an `AllowlistEnabled` event value for asserting against `event::events_by_type`.
#[test_only]
public fun test_new_allowlist_enabled<SaleCoin, PaymentCoin>(
    sale_id: ID,
    allowlist_admin_id: ID,
): AllowlistEnabled<SaleCoin, PaymentCoin> {
    AllowlistEnabled { sale_id, allowlist_admin_id }
}

/// Build a `SaleActivated` event value for asserting against `event::events_by_type`.
#[test_only]
public fun test_new_sale_activated<SaleCoin, PaymentCoin>(
    sale_id: ID,
    activated_at_ms: u64,
): SaleActivated<SaleCoin, PaymentCoin> {
    SaleActivated { sale_id, activated_at_ms }
}

/// Build a `Purchased` event value for asserting against `event::events_by_type`.
#[test_only]
public fun test_new_purchased<SaleCoin, PaymentCoin>(
    sale_id: ID,
    buyer: address,
    receipt_id: ID,
    paid: u64,
    allocation: u64,
    raised_after: u64,
    purchased_at_ms: u64,
): Purchased<SaleCoin, PaymentCoin> {
    Purchased { sale_id, buyer, receipt_id, paid, allocation, raised_after, purchased_at_ms }
}

/// Build a `SaleFinalized` event value for asserting against `event::events_by_type`.
#[test_only]
public fun test_new_sale_finalized<SaleCoin, PaymentCoin>(
    sale_id: ID,
    raised: u64,
    closed_at_ms: u64,
): SaleFinalized<SaleCoin, PaymentCoin> {
    SaleFinalized { sale_id, raised, closed_at_ms }
}

/// The `SoftCapMissed` cancel reason, for asserting `SaleCancelled` events.
#[test_only]
public fun test_cancel_reason_soft_cap_missed(): CancelReason { CancelReason::SoftCapMissed }

/// The `AdminEmergency` cancel reason, for asserting `SaleCancelled` events.
#[test_only]
public fun test_cancel_reason_admin_emergency(): CancelReason { CancelReason::AdminEmergency }

/// Build a `SaleCancelled` event value for asserting against `event::events_by_type`.
#[test_only]
public fun test_new_sale_cancelled<SaleCoin, PaymentCoin>(
    sale_id: ID,
    raised: u64,
    reason: CancelReason,
    closed_at_ms: u64,
): SaleCancelled<SaleCoin, PaymentCoin> {
    SaleCancelled { sale_id, raised, reason, closed_at_ms }
}

/// Build a `Claimed` event value for asserting against `event::events_by_type`.
#[test_only]
public fun test_new_claimed<SaleCoin, PaymentCoin>(
    sale_id: ID,
    buyer: address,
    receipt_id: ID,
    amount: u64,
): Claimed<SaleCoin, PaymentCoin> {
    Claimed { sale_id, buyer, receipt_id, amount }
}

/// Build a `Refunded` event value for asserting against `event::events_by_type`.
#[test_only]
public fun test_new_refunded<SaleCoin, PaymentCoin>(
    sale_id: ID,
    buyer: address,
    receipt_id: ID,
    amount: u64,
): Refunded<SaleCoin, PaymentCoin> {
    Refunded { sale_id, buyer, receipt_id, amount }
}

/// Build a `ProceedsWithdrawn` event value for asserting against `event::events_by_type`.
#[test_only]
public fun test_new_proceeds_withdrawn<SaleCoin, PaymentCoin>(
    sale_id: ID,
    amount: u64,
): ProceedsWithdrawn<SaleCoin, PaymentCoin> {
    ProceedsWithdrawn { sale_id, amount }
}

/// Build an `InventoryWithdrawn` event value for asserting against `event::events_by_type`.
#[test_only]
public fun test_new_inventory_withdrawn<SaleCoin, PaymentCoin>(
    sale_id: ID,
    amount: u64,
): InventoryWithdrawn<SaleCoin, PaymentCoin> {
    InventoryWithdrawn { sale_id, amount }
}

/// A KYC allowlist for a compliance-gated `prefunded_sale` - a worked example of
/// the "wire your own scheme against these types" pattern `allowlist` leaves open.
///
/// The sales library ships **no** verification logic: `enable_allowlist` hands the
/// issuer a single `AllowlistAdmin<SaleCoin>`, and every `purchase` on an allowlist
/// sale must consume an `AllowEntry<SaleCoin>` minted under that admin. This module is
/// the missing middle - the compliance object an integrator wraps the admin in.
///
/// It implements the four-step bootstrap from `allowlist`'s docs:
///
/// 1. The issuer calls `prefunded_sale::enable_allowlist`, which returns the
///    `AllowlistAdmin<SaleCoin>`.
/// 2. `new` moves that admin into a shared `KycRegistry<SaleCoin>` and returns a
///    `KycAdminCap` (the compliance operator's key).
/// 3. The operator clears investors off-chain, then records them on-chain with
///    `approve` (and drops them with `revoke`) - cap-gated.
/// 4. A cleared buyer calls `request_entry` inside their purchase PTB to mint the
///    single-use `AllowEntry`, which `purchase` consumes in the same transaction.
///
/// ### Who decides what
///
/// This registry is a binary KYC gate: it decides **who** may buy. It deliberately
/// mints entries with `max_amount = 0` (no per-entry cap) and leaves the **how much**
/// to the sale's own knobs - `set_per_buyer_cap` for the cumulative anti-whale bound
/// (the right knob for a *cumulative* limit, per `allowlist`'s docs) and the hard/soft
/// caps for the raise. An integrator who wants a per-*purchase* ceiling can pass a
/// non-zero `max_amount` to `allowlist::new_entry` instead; see `request_entry`.
///
/// ### Why wrapping the admin is safer than holding it raw
///
/// `allowlist`'s standing footgun is that a lost `AllowlistAdmin` bricks the sale: no
/// entries can be minted, so every `purchase` aborts. Moving the admin into a *shared*
/// registry removes that failure mode structurally - the admin can never be sent to a
/// dead address because it lives inside a shared object, and `request_entry` reads it
/// permissionlessly. Only approval *management* is cap-gated, so even a lost
/// `KycAdminCap` leaves already-approved buyers able to purchase; it only costs the
/// operator the ability to approve or revoke going forward. This mirrors the sale's own
/// guarantee that buyer paths never depend on admin liveness.
///
/// Because receipts are buyer-bound and non-transferable, the KYC decision made here at
/// purchase carries all the way through to distribution (including a vesting `claim_into_vesting`):
/// a cleared buyer cannot forward their claim to an uncleared address.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `prefunded_sale` and `allowlist` primitives can be integrated. It is not
/// production-ready and must not be deployed as-is. A real KYC scheme would layer in
/// attestation provenance, expiry, jurisdiction, and revocation semantics this
/// membership set does not model.
module openzeppelin_sale::example_kyc_registry;

use openzeppelin_sale::allowlist::{Self, AllowEntry, AllowlistAdmin};
use sui::event;
use sui::vec_set::{Self, VecSet};

// === Errors ===

/// A `KycAdminCap` was presented for a different registry than the one it controls.
#[error(code = 0)]
const EWrongRegistry: vector<u8> = "Admin cap was issued for a different registry";

/// `request_entry` was called by an address that has not been KYC-cleared.
#[error(code = 1)]
const EBuyerNotApproved: vector<u8> = "Caller is not on the KYC allowlist for this sale";

// === Structs ===

/// A shared KYC allowlist for one sale. Wraps the sale's `AllowlistAdmin<SaleCoin>` -
/// the authority to mint `AllowEntry` - so it can never be stranded, and tracks the set
/// of cleared buyers. Generic over `SaleCoin` so it gates exactly the sale that issued
/// the wrapped admin.
public struct KycRegistry<phantom SaleCoin> has key {
    id: UID,
    /// The wrapped mint authority. Never exposed by `&mut`; `request_entry` only reads it.
    admin: AllowlistAdmin<SaleCoin>,
    /// KYC-cleared buyer addresses. Membership is the whole policy.
    approved: VecSet<address>,
}

/// Authority to approve and revoke buyers on a specific registry, held by the
/// compliance operator. Bound to its registry by id. Losing it never bricks purchases
/// (see the module doc) - it only forfeits approval management.
public struct KycAdminCap has key, store {
    id: UID,
    registry_id: ID,
}

// === Events ===

/// Emitted by `approve` when a buyer is added to the allowlist.
public struct BuyerApproved has copy, drop {
    registry_id: ID,
    buyer: address,
}

/// Emitted by `revoke` when a buyer is removed from the allowlist.
public struct BuyerRevoked has copy, drop {
    registry_id: ID,
    buyer: address,
}

// === Public Functions ===

/// Wrap a sale's `AllowlistAdmin<SaleCoin>` in a fresh, shared KYC registry, and return
/// the `KycAdminCap` to the caller. Taking a pre-issued admin (rather than enabling the
/// allowlist here) keeps the wrapper decoupled from sale creation - the issuer threads
/// `enable_allowlist` and this call through their setup PTB.
///
/// #### Parameters
/// - `admin`: The `AllowlistAdmin<SaleCoin>` returned by `prefunded_sale::enable_allowlist`.
///   Moved into the shared registry.
/// - `ctx`: Transaction context, used to allocate the registry and cap `UID`s.
///
/// #### Returns
/// - The `KycAdminCap` controlling the new registry.
public fun new<SaleCoin>(admin: AllowlistAdmin<SaleCoin>, ctx: &mut TxContext): KycAdminCap {
    let registry = KycRegistry<SaleCoin> {
        id: object::new(ctx),
        admin,
        approved: vec_set::empty(),
    };
    let cap = KycAdminCap { id: object::new(ctx), registry_id: object::id(&registry) };
    transfer::share_object(registry);
    cap
}

/// Add a buyer to the allowlist. **Cap-gated.** Idempotent: approving an
/// already-cleared buyer is a no-op.
///
/// #### Parameters
/// - `self`: The registry to update.
/// - `cap`: The registry's admin cap.
/// - `buyer`: The address to clear for purchases.
///
/// #### Aborts
/// - `EWrongRegistry` if `cap` controls a different registry.
public fun approve<SaleCoin>(self: &mut KycRegistry<SaleCoin>, cap: &KycAdminCap, buyer: address) {
    assert!(cap.registry_id == object::id(self), EWrongRegistry);
    if (!self.approved.contains(&buyer)) {
        self.approved.insert(buyer);
        event::emit(BuyerApproved { registry_id: object::id(self), buyer });
    };
}

/// Remove a buyer from the allowlist. **Cap-gated.** Idempotent: revoking a buyer who
/// is not cleared is a no-op. A revoked buyer cannot mint new entries, but any entry
/// already minted and consumed in a completed purchase stands - revocation is
/// forward-looking.
///
/// #### Parameters
/// - `self`: The registry to update.
/// - `cap`: The registry's admin cap.
/// - `buyer`: The address to drop.
///
/// #### Aborts
/// - `EWrongRegistry` if `cap` controls a different registry.
public fun revoke<SaleCoin>(self: &mut KycRegistry<SaleCoin>, cap: &KycAdminCap, buyer: address) {
    assert!(cap.registry_id == object::id(self), EWrongRegistry);
    if (self.approved.contains(&buyer)) {
        self.approved.remove(&buyer);
        event::emit(BuyerRevoked { registry_id: object::id(self), buyer });
    };
}

/// Mint a single-use `AllowEntry<SaleCoin>` for the caller, to be consumed by
/// `prefunded_sale::purchase` in the same PTB. **Permissionless for cleared buyers** -
/// it needs no admin cap and no operator liveness; the KYC decision was made ahead of
/// time by `approve`.
///
/// The entry is bound to `ctx.sender()`, so a buyer can only mint their own, and it
/// carries `max_amount = 0` (no per-entry payment cap) - this registry gates *who*, not
/// *how much*. To impose a per-purchase ceiling, call `allowlist::new_entry` with a
/// non-zero `max_amount`; for a cumulative per-buyer bound, configure the sale's
/// `set_per_buyer_cap`.
///
/// #### Parameters
/// - `self`: The registry gating the sale.
/// - `ctx`: Transaction context; `ctx.sender()` must be a cleared buyer and becomes the
///   entry's bound buyer.
///
/// #### Returns
/// - A single-use `AllowEntry<SaleCoin>` bound to this sale and the calling buyer.
///
/// #### Aborts
/// - `EBuyerNotApproved` if `ctx.sender()` is not on the allowlist.
public fun request_entry<SaleCoin>(
    self: &KycRegistry<SaleCoin>,
    ctx: &TxContext,
): AllowEntry<SaleCoin> {
    let buyer = ctx.sender();
    assert!(self.approved.contains(&buyer), EBuyerNotApproved);
    allowlist::new_entry(&self.admin, buyer, 0)
}

// === View helpers ===

/// Whether `buyer` is currently cleared to purchase.
public fun is_approved<SaleCoin>(self: &KycRegistry<SaleCoin>, buyer: address): bool {
    self.approved.contains(&buyer)
}

/// The number of cleared buyers.
public fun approved_count<SaleCoin>(self: &KycRegistry<SaleCoin>): u64 {
    self.approved.length()
}

/// The id of the sale this registry gates entries for (read from the wrapped admin).
public fun sale_id<SaleCoin>(self: &KycRegistry<SaleCoin>): ID {
    allowlist::admin_sale_id(&self.admin)
}

/// Shared types used across the sales library's family of sale flavors.
///
/// Includes the lifecycle enum, the per-buyer claim ticket, and the
/// optional `VestingSchedule` policy that a sale flavor may attach
/// to make distribution gradual. The schedule is issuer-defined and
/// fixed at sale construction — buyers never supply or override it.
///
/// This module owns the lifecycle enum and the per-buyer claim ticket
/// that every sale flavor reuses. Sale flavors (the v1 `prefunded_sale`,
/// the future `minting_sale`) compose these types; integrator code only
/// observes them through the flavor module's public API.
///
/// ### `Receipt<S>` is non-transferable
///
/// `Receipt<S>` has the `key` ability only — no `store`. This has three
/// concrete consequences:
///
/// - `transfer::public_transfer` rejects a receipt (it requires `store`).
/// - `transfer::transfer` is restricted to this module, so no other
///   module can move a receipt across addresses.
/// - A receipt cannot appear as a struct field elsewhere (fields require
///   `store`).
///
/// The single transfer path is `deliver_receipt`, called by sale flavors
/// at purchase time to send the receipt to the buyer. After that, the
/// receipt stays with the buyer until consumed by `claim` or `refund`.
/// `claim` and `refund` additionally assert `ctx.sender() == buyer`,
/// so even shared custody arrangements cannot delegate redemption.
///
/// Two consequences integrators should be aware of:
///
/// - **KYC/compliance enforced at purchase carries through to
///   distribution.** A verified buyer cannot forward their claim to an
///   unverified address.
/// - **No wallet rotation between purchase and claim.** The address that
///   purchased is the address that must claim or refund. Hold the
///   purchasing key safely.
///
/// Partners that want a transferable allocation market must either
/// trade the resulting `Coin<S>` after `claim` (or `Coin<P>` after
/// `refund`), or build their own ticket type with abilities and
/// compliance checks of their choosing.
module openzeppelin_sale::sale;

use sui::coin::Coin;

// === Phase ===

/// Lifecycle phases shared by every sale flavor.
///
/// Transitions:
///   - `Init      → Active`                  via the flavor's `share_and_activate`
///   - `Active    → Finalized`               via the flavor's `finalize`
///   - `Active    → Cancelled`               via the flavor's `cancel_*`
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

// === Receipt ===

/// Per-buyer claim ticket. One receipt per purchase. Non-transferable
/// (see module doc).
///
/// Fields:
/// - `sale_id`: identifies the issuing sale. Verified on every
///   redemption path.
/// - `buyer`: address that purchased. `claim` and `refund` assert
///   `ctx.sender() == buyer`.
/// - `paid`: payment amount in `P`'s smallest units. Refunds pay back
///   exactly this amount.
/// - `allocation`: sale token amount in `S`'s smallest units. `claim`
///   returns exactly this amount as `Coin<S>`.
/// - `purchased_at_ms`: timestamp at purchase time. Available to
///   integrators that need time-anchored post-finalize logic.
public struct Receipt<phantom S> has key {
    id: UID,
    sale_id: ID,
    buyer: address,
    paid: u64,
    allocation: u64,
    purchased_at_ms: u64,
}

// === Receipt views ===

public fun receipt_sale_id<S>(r: &Receipt<S>): ID { r.sale_id }

public fun receipt_buyer<S>(r: &Receipt<S>): address { r.buyer }

public fun receipt_paid<S>(r: &Receipt<S>): u64 { r.paid }

public fun receipt_allocation<S>(r: &Receipt<S>): u64 { r.allocation }

public fun receipt_purchased_at_ms<S>(r: &Receipt<S>): u64 { r.purchased_at_ms }

// === Phase predicates ===

public fun is_init(p: &Phase): bool {
    match (p) {
        Phase::Init => true,
        _ => false,
    }
}

public fun is_active(p: &Phase): bool {
    match (p) {
        Phase::Active => true,
        _ => false,
    }
}

public fun is_finalized(p: &Phase): bool {
    match (p) {
        Phase::Finalized => true,
        _ => false,
    }
}

public fun is_cancelled(p: &Phase): bool {
    match (p) {
        Phase::Cancelled => true,
        _ => false,
    }
}

// === Package-internal helpers ===
//
// Receipt construction, delivery, and consumption are package-internal.
// Sale flavors (`prefunded_sale`, future `minting_sale`) and the
// vested-claim path (`prefunded_sale::claim_into_vesting` →
// `vested_claim`) call into these helpers; no other code path can
// produce or destroy a `Receipt<S>`.

/// Mint a fresh receipt. Sale flavors call this from `purchase`.
public(package) fun new_receipt<S>(
    sale_id: ID,
    buyer: address,
    paid: u64,
    allocation: u64,
    purchased_at_ms: u64,
    ctx: &mut TxContext,
): Receipt<S> {
    Receipt<S> {
        id: object::new(ctx),
        sale_id,
        buyer,
        paid,
        allocation,
        purchased_at_ms,
    }
}

/// Deliver a freshly-minted receipt to its buyer. The only transfer
/// path for receipts. Sale flavors call this immediately after
/// `new_receipt` and never expose the receipt back to the caller.
public(package) fun deliver_receipt<S>(receipt: Receipt<S>, to: address) {
    transfer::transfer(receipt, to);
}

/// Destructively read a receipt. Used by `claim`, `claim_into_vesting`,
/// and `refund` paths in sale flavors. Deletes the receipt's UID.
///
/// Returns `(sale_id, buyer, paid, allocation, purchased_at_ms)`.
public(package) fun consume_receipt<S>(r: Receipt<S>): (ID, address, u64, u64, u64) {
    let Receipt { id, sale_id, buyer, paid, allocation, purchased_at_ms } = r;
    object::delete(id);
    (sale_id, buyer, paid, allocation, purchased_at_ms)
}

// === VestedAllocation ===
//
// Hot-potato that wraps a single buyer's claim on a vesting-attached
// sale. Returned from `prefunded_sale::claim_into_vesting`; consumed
// by a library-side router (e.g. `vested_claim::into_shared_wallet`)
// which is the only path that can extract the inner `Coin<S>`.
//
// Why a hot-potato:
//   - No `drop`: the caller cannot silently discard it.
//   - No `key` / `store`: it cannot be transferred, wrapped, or stashed
//     in a dynamic field.
//   - Fields are private to this module, so unpacking requires
//     `unpack_vested_allocation`, which is `public(package)` and
//     reachable only from sibling library modules.
//
// Net effect: once a vesting schedule is attached to a sale, the only
// way to dispose of a claim is to route it through a library-defined
// consumer that honors the schedule. Buyers cannot reach the raw coin.

/// Library-internal carrier for a vested claim. See module note above.
///
/// The hot-potato carries `Coin<S>` rather than `Balance<S>` because
/// the only consumer path (`vested_claim::into_*`) immediately feeds
/// the inner value into `vesting_wallet::deposit`, which already takes
/// a `Coin<S>` — keeping the carrier shape aligned avoids a needless
/// `Balance ↔ Coin` round-trip in the same transaction.
#[allow(lint(coin_field))]
public struct VestedAllocation<phantom C, P> {
    coin: Coin<C>,
    schedule_params: P,
    beneficiary: address,
    sale_id: ID,
}

/// Build a `VestedAllocation`. Library-internal: only sibling library
/// modules (e.g. `prefunded_sale::claim_into_vesting`) construct these.
public(package) fun new_vested_allocation<C, P>(
    coin: Coin<C>,
    schedule_params: P,
    beneficiary: address,
    sale_id: ID,
): VestedAllocation<C, P> {
    VestedAllocation<C, P> { coin, schedule_params, beneficiary, sale_id }
}

/// Destructure a `VestedAllocation`. Library-internal: only sibling
/// library modules (e.g. `vested_claim`) unpack these into the
/// downstream wallet shape.
///
/// Returns `(coin, schedule_params, beneficiary, sale_id)`.
public(package) fun unpack_vested_allocation<C, P>(
    allocation: VestedAllocation<C, P>,
): (Coin<C>, P, address, ID) {
    let VestedAllocation { coin, schedule_params, beneficiary, sale_id } = allocation;
    (coin, schedule_params, beneficiary, sale_id)
}

// === Phase factories ===

public(package) fun phase_init(): Phase { Phase::Init }

public(package) fun phase_active(): Phase { Phase::Active }

public(package) fun phase_finalized(): Phase { Phase::Finalized }

public(package) fun phase_cancelled(): Phase { Phase::Cancelled }

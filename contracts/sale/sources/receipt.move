/// The per-buyer claim ticket (`Receipt<S>`) issued by every sale flavor.
///
/// A `Receipt<S>` records one purchase - the issuing sale, the buyer, the amount
/// paid, the token allocation, and the purchase time - and is the object the buyer
/// later redeems via `claim` or `refund`. Sale flavors (the v1 `prefunded_sale`,
/// the future `minting_sale`) mint and consume it through the package-internal
/// helpers below; integrator code only observes it through the flavor module's
/// public API.
///
/// ### `Receipt<S>` is non-transferable
///
/// `Receipt<S>` has the `key` ability only - no `store`. This has three
/// concrete consequences:
///
/// - `transfer::public_transfer` rejects a receipt (it requires `store`).
/// - `transfer::transfer` is restricted to this module, so no other
///   module can move a receipt across addresses.
/// - A receipt cannot appear as a struct field elsewhere (fields require
///   `store`).
///
/// The single transfer path is `deliver`, called by sale flavors
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
module openzeppelin_sale::receipt;

// === Receipt ===

/// Per-buyer claim ticket. One receipt per purchase. Non-transferable (see module
/// doc).
public struct Receipt<phantom S> has key {
    id: UID,
    /// Id of the issuing sale. Verified on every redemption path.
    sale_id: ID,
    /// Address that purchased; `claim` and `refund` require this to be the sender.
    buyer: address,
    /// Payment amount in the payment coin's smallest units. A refund returns exactly
    /// this.
    paid: u64,
    /// Sale-token amount in `S`'s smallest units. A claim returns exactly this.
    allocation: u64,
    /// Timestamp (ms) at which the purchase happened.
    purchased_at_ms: u64,
}

// === Receipt views ===

/// The id of the sale that issued this receipt.
///
/// #### Parameters
/// - `r`: The receipt to read.
///
/// #### Returns
/// - The issuing sale's id.
public fun sale_id<S>(r: &Receipt<S>): ID { r.sale_id }

/// The address that purchased, and the only address that may redeem this receipt.
///
/// #### Parameters
/// - `r`: The receipt to read.
///
/// #### Returns
/// - The buyer's address.
public fun buyer<S>(r: &Receipt<S>): address { r.buyer }

/// The payment amount backing this receipt, in `PaymentCoin`'s smallest units. A
/// refund pays back exactly this amount.
///
/// #### Parameters
/// - `r`: The receipt to read.
///
/// #### Returns
/// - The amount paid at purchase.
public fun paid<S>(r: &Receipt<S>): u64 { r.paid }

/// The sale-token allocation promised by this receipt, in `S`'s smallest units. A
/// claim returns exactly this amount.
///
/// #### Parameters
/// - `r`: The receipt to read.
///
/// #### Returns
/// - The promised allocation.
public fun allocation<S>(r: &Receipt<S>): u64 { r.allocation }

/// The timestamp (ms) at which the purchase happened.
///
/// #### Parameters
/// - `r`: The receipt to read.
///
/// #### Returns
/// - The purchase timestamp in milliseconds.
public fun purchased_at_ms<S>(r: &Receipt<S>): u64 { r.purchased_at_ms }

// === Package-internal helpers ===
//
// Receipt construction, delivery, and consumption are package-internal.
// Sale flavors (`prefunded_sale`, future `minting_sale`) call into these
// helpers from their purchase and redemption paths (`claim`,
// `claim_into_vesting`, `refund`); no other code path can produce or
// destroy a `Receipt<S>`.

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
public(package) fun deliver<S>(receipt: Receipt<S>, to: address) {
    transfer::transfer(receipt, to);
}

/// Destructively read a receipt. Used by `claim`, `claim_into_vesting`,
/// and `refund` paths in sale flavors. Deletes the receipt's UID.
///
/// Returns `(sale_id, buyer, paid, allocation, purchased_at_ms)`.
public(package) fun consume<S>(r: Receipt<S>): (ID, address, u64, u64, u64) {
    let Receipt { id, sale_id, buyer, paid, allocation, purchased_at_ms } = r;
    object::delete(id);
    (sale_id, buyer, paid, allocation, purchased_at_ms)
}

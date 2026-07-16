/// Typed slot for compliance hooks.
///
/// The sales library does not ship verification logic. This module
/// defines the two types that integrators wire their own compliance
/// scheme against:
///
/// - `AllowlistAdmin<S>` - owned capability. Held by the consumer's
///   compliance module (KYC contract, tier-checker, merkle verifier,
///   etc.). The sale issues exactly one per `enable_allowlist` call.
/// - `AllowEntry<S>` - single-use compliance ticket. Has **no
///   abilities**, so it cannot be stored, copied, replayed, or
///   transferred. The compliance module mints an entry for a verified
///   buyer; the sale's `purchase` consumes it in the same PTB.
///
/// ### Bootstrap shape
///
/// 1. Sale module creates an `AllowlistAdmin<S>` via the sale flavor's
///    `enable_allowlist`. The admin is returned to the caller.
/// 2. Caller transfers the admin to a compliance module (typically a
///    shared object that owns the admin via a wrapping struct).
/// 3. Compliance module exposes a buyer-facing `mint_entry`-like
///    function that runs whatever checks it requires (KYC table lookup,
///    merkle proof, tier verification) and, on success, calls
///    `allowlist::new_entry` to mint an `AllowEntry<S>`.
/// 4. Buyer threads `purchase` and `mint_entry` into the same PTB. The
///    sale's `purchase` consumes the entry, asserting it was issued for
///    this sale and for this buyer.
///
/// ### Hot-potato guarantees
///
/// Because `AllowEntry<S>` has no abilities:
///
/// - It cannot be saved across transactions (no `key`/`store`).
/// - It cannot be cloned (no `copy`).
/// - It cannot be discarded silently (no `drop`) - only a function that
///   destructures it (`consume`) can dispose of it.
///
/// The single legal path is: compliance module mints -> sale consumes,
/// both in one PTB. Replay and proxy attacks are eliminated by the
/// ability system.
///
/// ### Footgun
///
/// If the consumer loses the `AllowlistAdmin<S>` (sends to a
/// non-existent address, transfers to `0x0`, etc.), the sale becomes
/// uncompletable: no entries can be minted, and any sale that has
/// `requires_allowlist == true` aborts every `purchase` call. There is
/// no library override - that would be a centralization vector. Hold
/// the admin in an access-controlled wrapper that the operator can
/// recover from.
module openzeppelin_sale::allowlist;

// === Errors ===

/// The consumed `AllowEntry` was issued for a different sale than the one
/// consuming it.
#[error(code = 0)]
const EWrongSaleId: vector<u8> = "This allowlist entry was issued for a different sale";

/// The consumed `AllowEntry`'s `buyer` does not match the transaction sender.
#[error(code = 1)]
const EWrongBuyer: vector<u8> = "This allowlist entry was issued for a different buyer";

// === Structs ===

/// Single-use compliance ticket. No abilities - must be created and
/// consumed in the same transaction.
///
/// Fields are not exposed; the integrator's compliance module
/// constructs entries via `new_entry`, and the sale module consumes
/// them via the package-internal `consume`.
public struct AllowEntry<phantom S> {
    /// Id of the sale this entry authorizes a purchase on.
    sale_id: ID,
    /// Address allowed to use this entry; must match the purchase sender.
    buyer: address,
    /// Per-entry payment cap; `0` means no per-entry cap.
    max_amount: u64,
}

/// Authority to mint `AllowEntry<S>` for a specific sale. Owned and
/// transferable so the consumer can wrap it inside their own
/// access-controlled compliance module.
public struct AllowlistAdmin<phantom S> has key, store {
    id: UID,
    /// Id of the sale this admin gates entries for.
    sale_id: ID,
}

// === Public Functions ===

/// Mint a fresh allow entry. The compliance module calls this after running
/// whatever verification it requires.
///
/// `max_amount` is **per-entry, not cumulative**. The compliance module is free to
/// mint multiple entries for the same buyer; each entry caps a single `purchase`.
/// For a cumulative per-buyer bound, the sale flavor's `set_per_buyer_cap` is the
/// right knob.
///
/// #### Parameters
/// - `admin`: The `AllowlistAdmin<S>` previously issued for the sale.
/// - `buyer`: The address that will perform the purchase. Must equal `ctx.sender()`
///   at `purchase` time - the sale asserts this.
/// - `max_amount`: Per-entry payment cap. `0` means "no per-entry cap" (the sale's
///   own per-buyer cap, if configured, still applies).
///
/// #### Returns
/// - A single-use `AllowEntry<S>` bound to `admin`'s sale and to `buyer`.
public fun new_entry<S>(admin: &AllowlistAdmin<S>, buyer: address, max_amount: u64): AllowEntry<S> {
    AllowEntry<S> {
        sale_id: admin.sale_id,
        buyer,
        max_amount,
    }
}

// === View helpers ===

/// The id of the sale this admin gates entries for.
///
/// #### Parameters
/// - `admin`: The allowlist admin to read.
///
/// #### Returns
/// - The bound sale's id.
public fun admin_sale_id<S>(admin: &AllowlistAdmin<S>): ID { admin.sale_id }

// === Package Functions ===

// === Admin issuance ===
//
// Only the sale flavor's `enable_allowlist` calls this. Issuing an
// admin commits the sale to allowlist mode (`requires_allowlist = true`)
// and is idempotent on the sale side.

/// Issue the single `AllowlistAdmin<S>` for a sale. Called once by the sale flavor's
/// `enable_allowlist`.
///
/// #### Parameters
/// - `sale_id`: Id of the sale the admin gates entries for.
/// - `ctx`: Transaction context, used to allocate the admin's `UID`.
///
/// #### Returns
/// - A fresh `AllowlistAdmin<S>` bound to `sale_id`.
public(package) fun new_admin<S>(sale_id: ID, ctx: &mut TxContext): AllowlistAdmin<S> {
    AllowlistAdmin<S> { id: object::new(ctx), sale_id }
}

// === Sale consumes entries ===

/// Consume an entry, asserting it was issued for this sale and for this buyer. The
/// sale flavor's `purchase` calls this.
///
/// #### Parameters
/// - `entry`: The `AllowEntry<S>` to consume (destroyed by this call).
/// - `expected_sale_id`: The id of the consuming sale.
/// - `expected_buyer`: The transaction sender performing the purchase.
///
/// #### Returns
/// - The entry's `max_amount`, which the sale uses to enforce the per-entry payment
///   cap (`0` means no per-entry cap).
///
/// #### Aborts
/// - `EWrongSaleId` if `entry.sale_id != expected_sale_id`.
/// - `EWrongBuyer` if `entry.buyer != expected_buyer`.
public(package) fun consume<S>(
    entry: AllowEntry<S>,
    expected_sale_id: ID,
    expected_buyer: address,
): u64 {
    let AllowEntry { sale_id, buyer, max_amount } = entry;
    assert!(sale_id == expected_sale_id, EWrongSaleId);
    assert!(buyer == expected_buyer, EWrongBuyer);
    max_amount
}

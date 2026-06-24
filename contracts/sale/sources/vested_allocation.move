module openzeppelin_sale::vested_allocation;

use sui::coin::Coin;

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
/// a `Coin<S>` - keeping the carrier shape aligned avoids a needless
/// `Balance ↔ Coin` round-trip in the same transaction.
#[allow(lint(coin_field))]
public struct VestedAllocation<phantom S, P> {
    coin: Coin<S>,
    schedule_params: P,
    beneficiary: address,
    sale_id: ID,
}

/// Build a `VestedAllocation`. Library-internal: only sibling library
/// modules (e.g. `prefunded_sale::claim_into_vesting`) construct these.
public(package) fun new<S, P>(
    coin: Coin<S>,
    schedule_params: P,
    beneficiary: address,
    sale_id: ID,
): VestedAllocation<S, P> {
    VestedAllocation<S, P> { coin, schedule_params, beneficiary, sale_id }
}

/// Destructure a `VestedAllocation`. Library-internal: only sibling
/// library modules (e.g. `vested_claim`) unpack these into the
/// downstream wallet shape.
///
/// Returns `(coin, schedule_params, beneficiary, sale_id)`.
public(package) fun unpack_vested_allocation<S, P>(
    allocation: VestedAllocation<S, P>,
): (Coin<S>, P, address, ID) {
    let VestedAllocation { coin, schedule_params, beneficiary, sale_id } = allocation;
    (coin, schedule_params, beneficiary, sale_id)
}

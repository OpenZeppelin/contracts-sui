/// Membership-filter pattern - the canonical `SortedSet` integration.
///
/// `SortedSet<K>` has no identity of its own (no `UID`). To get an on-chain allowlist you
/// embed it inside your own `has key` object and call the set's macro API from your own
/// functions. Here the wrapper is an `Allowlist` of approved token ids (`SortedSet<u64>`),
/// held as an OWNED object - only its owner can present it, so writes never contend
/// (contrast the shared `unlock_queue` / `validator_set` modules).
///
/// # The bool return earns its keep
/// `sui::vec_set::insert` ABORTS on a duplicate. This set's `upsert` instead returns `bool` and
/// never aborts: `upsert -> true` iff the id was NEWLY added. That lets us gate a side effect on a
/// genuine state change - we `event::emit` `Approved` only when the membership actually flipped -
/// and keeps the call composable mid-PTB (a benign re-approval does not roll back the whole
/// transaction).
///
/// If you want vec_set's abort-on-duplicate, layer it back on in one line:
/// `assert!(s.upsert!(k), E)` - that is exactly what `approve_strict` does.
///
/// `remove!`, by contrast, ABORTS on an absent key (matching `vec_set::remove`), so `revoke` aborts
/// rather than reporting a miss; there is no membership to gate on, and it emits `Revoked` on every
/// success.
///
/// # De-duplicating bulk build
/// `from_keys!` performs idempotent inserts, so it DE-DUPLICATES its input (vec_set's
/// `from_keys` aborts on a duplicate). `create([7, 7, 3])` yields the two-member set {3, 7}.
/// To instead REJECT duplicate input, build then `assert!(count(&s) == input.length(), E)`.
///
/// Integer keys use the bare macros (`upsert`, `remove!`, `contains!`), which assume the
/// built-in `<`. A non-integer key (address, struct) would need the `_by` forms - see
/// `validator_set`.
///
/// Lifecycle: `create_and_keep` -> `approve` / `approve_strict` / `revoke` ->
/// `is_approved` / `members` / `count`. An owned object: single-writer, no consensus.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `SortedSet` can be integrated. It is not production-ready and must not be deployed
/// as-is.
module openzeppelin_collections::sorted_set_allowlist;

use openzeppelin_collections::sorted_set::{Self, SortedSet};
use sui::event;

// === Errors ===

/// `approve_strict` was asked to add an id that is already approved. This is the integrator's
/// OWN opt-in error - it recovers `vec_set::insert`'s abort-on-duplicate on top of the set's
/// total `upsert`. It is NOT a library abort.
#[error(code = 0)]
const EAlreadyApproved: vector<u8> = "Id is already approved";

// === Structs ===

/// An allowlist of approved token ids.
public struct Allowlist has key {
    id: UID,
    /// The set of approved token ids - the allowlist's only state.
    members: SortedSet<u64>,
}

// === Events ===

/// Emitted only on a genuine first-time approval (gated on `upsert`'s `true`).
public struct Approved has copy, drop { id: u64 }

/// Emitted on every successful revocation (`remove!` aborts if the id was absent).
public struct Revoked has copy, drop { id: u64 }

// === Public Functions ===

/// Build an allowlist seeded from `initial` (DE-DUPLICATED) and transfer it to the caller.
///
/// #### Parameters
/// - `initial`: Ids to seed the allowlist with; de-duplicated.
/// - `ctx`: Transaction context; the new allowlist is transferred to its sender.
public fun create_and_keep(initial: vector<u64>, ctx: &mut TxContext) {
    transfer::transfer(create(initial, ctx), ctx.sender());
}

/// Build an allowlist seeded from `initial`. `from_keys!` de-duplicates, so `count` of the
/// result is the number of DISTINCT ids, not `initial.length()`.
///
/// #### Parameters
/// - `initial`: Ids to seed the allowlist with; de-duplicated.
/// - `ctx`: Transaction context used to allocate the object's `UID`.
///
/// #### Returns
/// - The newly built allowlist.
public fun create(initial: vector<u64>, ctx: &mut TxContext): Allowlist {
    Allowlist { id: object::new(ctx), members: sorted_set::from_keys!(initial) }
}

/// Hand the allowlist to a new owner. An owned object, so only the current holder can call this
/// - reassigning ownership is the whole transfer. The embedded set travels inline with it.
///
/// #### Parameters
/// - `list`: The allowlist to transfer (consumed).
/// - `recipient`: Address of the new owner.
public fun transfer_to(list: Allowlist, recipient: address) {
    transfer::transfer(list, recipient);
}

/// Approve `id`. Returns `true` iff it was NEWLY approved; a re-approval returns `false` and
/// does NOT abort (idempotent, total). Emits `Approved` only on the `true` (first-seen) case.
///
/// #### Parameters
/// - `list`: The allowlist to modify.
/// - `id`: Token id to approve.
///
/// #### Returns
/// - `true` if `id` was newly approved, `false` if it was already present.
public fun approve(list: &mut Allowlist, id: u64): bool {
    let added = list.members.upsert!(id);
    if (added) event::emit(Approved { id });
    added
}

/// Approve `id`, recovering `vec_set::insert`'s strict semantics on top of the total `upsert`
/// in one line. Emits `Approved` on success.
///
/// #### Parameters
/// - `list`: The allowlist to modify.
/// - `id`: Token id to approve.
///
/// #### Aborts
/// - `EAlreadyApproved` if `id` is already present.
public fun approve_strict(list: &mut Allowlist, id: u64) {
    assert!(list.members.upsert!(id), EAlreadyApproved);
    event::emit(Approved { id });
}

/// Revoke `id`, aborting if it is not approved (the set's `remove!` aborts on an absent key).
/// Emits `Revoked` on success.
///
/// #### Parameters
/// - `list`: The allowlist to modify.
/// - `id`: Token id to revoke.
///
/// #### Aborts
/// - `sorted_map::EKeyNotFound` if `id` is not approved.
public fun revoke(list: &mut Allowlist, id: u64) {
    list.members.remove!(&id);
    event::emit(Revoked { id });
}

/// True iff `id` is currently approved. Routes through the same search the writes use, so
/// `is_approved` can never disagree with `approve`/`revoke`.
///
/// #### Parameters
/// - `list`: The allowlist to query.
/// - `id`: Token id to check.
///
/// #### Returns
/// - `true` iff `id` is currently approved.
public fun is_approved(list: &Allowlist, id: u64): bool {
    list.members.contains!(&id)
}

/// Number of distinct approved ids.
///
/// #### Parameters
/// - `list`: The allowlist to query.
///
/// #### Returns
/// - The number of distinct approved ids.
public fun count(list: &Allowlist): u64 {
    list.members.length()
}

/// All approved ids in ascending order, as an owned snapshot.
///
/// #### Parameters
/// - `list`: The allowlist to query.
///
/// #### Returns
/// - All approved ids in ascending order, as an owned snapshot.
public fun members(list: &Allowlist): vector<u64> {
    list.members.keys()
}

// === Test-Only Helpers ===

/// True iff the embedded set is correctly ordered. The set delegates ordering to the wrapped
/// map, so the check reaches the map's `is_well_formed!` oracle through `inner`.
#[test_only]
public fun members_well_formed(list: &Allowlist): bool {
    list.members.inner().is_well_formed!()
}

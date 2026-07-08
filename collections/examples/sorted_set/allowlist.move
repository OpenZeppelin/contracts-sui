/// Membership-filter pattern - the canonical `SortedSet` integration.
///
/// `SortedSet<K>` has no identity of its own (no `UID`). To get an on-chain allowlist you
/// embed it inside your own `has key` object and call the set's macro API from your own
/// functions. Here the wrapper is an `Allowlist` of approved token ids (`SortedSet<u64>`),
/// held as an OWNED object - only its owner can present it, so writes never contend
/// (contrast the shared `unlock_queue` / `validator_set` modules).
///
/// # The bool return earns its keep
/// `sui::vec_set::insert` ABORTS on a duplicate and `remove` ABORTS on an absent key. This
/// set instead returns `bool` and never aborts: `insert! -> true` iff the id was NEWLY added,
/// `remove! -> true` iff it WAS present. That lets us gate a side effect on a genuine state
/// change - we `event::emit` only when the membership actually flipped - and keeps the calls
/// composable mid-PTB (a benign re-approval does not roll back the whole transaction).
///
/// If you want vec_set's abort-on-duplicate, layer it back on in one line:
/// `assert!(insert!(&mut s, k), E)` - that is exactly what `approve_strict` does.
///
/// # De-duplicating bulk build
/// `from_keys!` performs idempotent inserts, so it DE-DUPLICATES its input (vec_set's
/// `from_keys` aborts on a duplicate). `create([7, 7, 3])` yields the two-member set {3, 7}.
/// To instead REJECT duplicate input, build then `assert!(count(&s) == input.length(), E)`.
///
/// Integer keys use the bare macros (`insert!`, `remove!`, `contains!`), which assume the
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
/// total `insert!`. It is NOT a library abort.
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

/// Emitted only on a genuine first-time approval (gated on `insert!`'s `true`).
public struct Approved has copy, drop { id: u64 }

/// Emitted only when an id that WAS present is revoked (gated on `remove!`'s `true`).
public struct Revoked has copy, drop { id: u64 }

// === Public Functions ===

/// Build an allowlist seeded from `initial` (DE-DUPLICATED) and transfer it to the caller.
public fun create_and_keep(initial: vector<u64>, ctx: &mut TxContext) {
    transfer::transfer(create(initial, ctx), ctx.sender());
}

/// Build an allowlist seeded from `initial`. `from_keys!` de-duplicates, so `count` of the
/// result is the number of DISTINCT ids, not `initial.length()`.
public fun create(initial: vector<u64>, ctx: &mut TxContext): Allowlist {
    Allowlist { id: object::new(ctx), members: sorted_set::from_keys!(initial) }
}

/// Hand the allowlist to a new owner. An owned object, so only the current holder can call this
/// - reassigning ownership is the whole transfer. The embedded set travels inline with it.
public fun transfer_to(list: Allowlist, recipient: address) {
    transfer::transfer(list, recipient);
}

/// Approve `id`. Returns `true` iff it was NEWLY approved; a re-approval returns `false` and
/// does NOT abort (idempotent, total). Emits `Approved` only on the `true` (first-seen) case.
public fun approve(list: &mut Allowlist, id: u64): bool {
    let added = list.members.insert!(id);
    if (added) event::emit(Approved { id });
    added
}

/// Approve `id`, recovering `vec_set::insert`'s strict semantics on top of the total `insert!`
/// in one line. Emits `Approved` on success.
///
/// #### Aborts
/// - `EAlreadyApproved` if `id` is already present.
public fun approve_strict(list: &mut Allowlist, id: u64) {
    assert!(list.members.insert!(id), EAlreadyApproved);
    event::emit(Approved { id });
}

/// Revoke `id`. Returns `true` iff it WAS approved; revoking an absent id returns `false` and
/// does NOT abort (total). Emits `Revoked` only on the `true` case.
public fun revoke(list: &mut Allowlist, id: u64): bool {
    let removed = list.members.remove!(&id);
    if (removed) event::emit(Revoked { id });
    removed
}

/// True iff `id` is currently approved. Routes through the same search the writes use, so
/// `is_approved` can never disagree with `approve`/`revoke`.
public fun is_approved(list: &Allowlist, id: u64): bool {
    list.members.contains!(&id)
}

/// Number of distinct approved ids.
public fun count(list: &Allowlist): u64 {
    list.members.length()
}

/// All approved ids in ascending order, as an owned snapshot.
public fun members(list: &Allowlist): vector<u64> {
    list.members.keys()
}

// === Test-Only Helpers ===

/// True iff the embedded set is correctly ordered. The set delegates ordering to the wrapped
/// map, so the check reaches the map's `is_well_formed!` oracle through `inner_ref`.
#[test_only]
public fun members_well_formed(list: &Allowlist): bool {
    list.members.inner_ref().is_well_formed!()
}

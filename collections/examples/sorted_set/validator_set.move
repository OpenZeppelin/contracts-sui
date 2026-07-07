/// Custom-order, struct-key pattern - the whole reason the `_by` macros exist.
///
/// A `SortedSet<Validator>` where `Validator` is a STRUCT with no built-in `<`. The bare
/// macros (`insert!`, `contains!`) only compile for integer keys, so every operation here MUST
/// use the `_by` form and supply a comparator. Embedded in a SHARED registry; ordered by stake
/// DESCENDING (the most-staked validator is the head).
///
/// # One comparator, threaded everywhere
/// The order lives in ONE private fun, `outranks`, passed as `|a, b| outranks(a, b)` to every
/// `_by` call. The set stores no comparator, so it cannot check that you pass the same one each
/// time - mixing comparators across calls silently corrupts order, and a COARSE (non-injective)
/// comparator silently collapses byte-distinct keys. `outranks` is a STRICT TOTAL ORDER (ties on
/// stake are broken by address), which is exactly what keeps membership well-defined. Callers
/// never see the comparator, so they cannot get it wrong - the danger is entirely the library
/// author's to contain, and `validator_set_tests` includes a red test that shows what a wrong
/// comparator does (a present validator silently overwritten - no abort, no key "lost").
///
/// # Keys are immutable
/// A set key cannot be edited in place. Since `stake` is part of the key, RE-RANKING a validator
/// is remove-old-then-insert-new - that is what `restake` does - never a field write.
///
/// Lifecycle: `deploy_and_share` -> `register` / `deregister` / `restake` -> `top` / `ranking` /
/// `is_registered`. A shared object: writers serialize per object.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `SortedSet` can be integrated. It is not production-ready and must not be deployed
/// as-is.
module openzeppelin_collections::sorted_set_validator_set;

use openzeppelin_collections::sorted_set::{Self, SortedSet};
use sui::address;

#[test_only]
use openzeppelin_collections::sorted_map;

/// A validator identity: voting `stake` plus the validator's `addr`. `copy + drop + store` so it
/// can be a set key. `addr` makes the ordering injective (no two distinct validators tie).
public struct Validator has copy, drop, store {
    stake: u64,
    addr: address,
}

/// A registry of validators kept ordered by descending stake.
public struct ValidatorSet has key {
    id: UID,
    validators: SortedSet<Validator>,
}

/// THE comparator. Strict-less-than read as "a outranks b": more stake comes first; equal stake
/// is broken by the lower address. `address` has no built-in `<` (another reason a struct key
/// needs `_by`), so the tiebreak compares `address::to_u256`. Breaking ties on `addr` makes this
/// a STRICT TOTAL ORDER over distinct validators - drop the tiebreak and it becomes coarse, the
/// bug the red test shows.
fun outranks(a: &Validator, b: &Validator): bool {
    if (a.stake != b.stake) a.stake > b.stake
    else address::to_u256(a.addr) < address::to_u256(b.addr)
}

/// Construct a `Validator`. Public so callers (and tests) can name set elements.
public fun validator(stake: u64, addr: address): Validator {
    Validator { stake, addr }
}

/// Voting stake of a validator.
public fun stake(v: &Validator): u64 { v.stake }

/// Address of a validator.
public fun addr(v: &Validator): address { v.addr }

/// Create an empty registry, share it, and return its `ID`.
public fun deploy_and_share(ctx: &mut TxContext): ID {
    let vs = ValidatorSet { id: object::new(ctx), validators: sorted_set::new() };
    let id = object::id(&vs);
    transfer::share_object(vs);
    id
}

/// Register `v`. Struct key, so `insert_by!` threads the `outranks` comparator. Returns `true`
/// iff newly registered (a duplicate returns `false`, no abort).
public fun register(vs: &mut ValidatorSet, v: Validator): bool {
    sorted_set::insert_by!(&mut vs.validators, v, |a, b| outranks(a, b))
}

/// Deregister `v`. Returns `true` iff it WAS registered (total). Same comparator as `register`.
public fun deregister(vs: &mut ValidatorSet, v: &Validator): bool {
    sorted_set::remove_by!(&mut vs.validators, v, |a, b| outranks(a, b))
}

/// True iff `v` is currently registered (under the `outranks` comparator).
public fun is_registered(vs: &ValidatorSet, v: &Validator): bool {
    sorted_set::contains_by!(&vs.validators, v, |a, b| outranks(a, b))
}

/// The top-ranked validator (most stake), or `none` if the registry is empty. `head` is the
/// comparator-minimum, and under `outranks` that is the highest-staked validator.
public fun top(vs: &ValidatorSet): Option<Validator> {
    sorted_set::head(&vs.validators)
}

/// Re-rank an EXISTING validator to `new_stake`. Keys are immutable, so this removes the old
/// entry and inserts a fresh one at the new rank. Returns `true` on success.
///
/// Returns `false`, leaving the set unchanged, in two cases: `old` is not registered, or a
/// separate `(new_stake, old.addr)` entry already occupies the target slot (the set keys on the
/// whole `(stake, addr)`, so one address can hold two entries). The re-rank is atomic: on the
/// collision the just-removed `old` is restored, so a `false` return never means a validator was
/// dropped.
public fun restake(vs: &mut ValidatorSet, old: Validator, new_stake: u64): bool {
    if (!deregister(vs, &old)) return false;
    if (register(vs, validator(new_stake, old.addr))) return true;
    // Collision: `(new_stake, old.addr)` is already registered as a separate entry, so the
    // re-insert is a no-op. Restore the just-removed `old` (this re-insert necessarily succeeds)
    // so `restake` leaves the set exactly as it found it, and report the re-rank did not happen.
    register(vs, old);
    false
}

/// All validators in rank order (highest stake first), as an owned snapshot.
public fun ranking(vs: &ValidatorSet): vector<Validator> {
    sorted_set::keys(&vs.validators)
}

/// Number of registered validators.
public fun count(vs: &ValidatorSet): u64 {
    sorted_set::length(&vs.validators)
}

// === Test-only order check ===

/// True iff the embedded set is correctly ordered UNDER `outranks`. A struct key needs the
/// `_by` oracle, threading the very same comparator the writes use.
#[test_only]
public fun validators_well_formed(vs: &ValidatorSet): bool {
    sorted_map::is_well_formed_by!(sorted_set::inner_ref(&vs.validators), |a, b| outranks(a, b))
}

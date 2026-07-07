/// A tournament prize pool that holds real coins in a `SortedMap` - the
/// resource-value pattern.
///
/// `order_book` stores a `copy + drop` value; this vault stores `Coin<SUI>`, which has
/// neither. That changes the lifecycle and is where integrators most often slip:
///
/// - A `SortedMap<u64, Coin<SUI>>` is itself not droppable - it cannot fall out of
///   scope; it must be drained and then `destroy_empty`'d.
/// - Every op that could displace a value hands it back instead of dropping it
///   (`insert!` and `remove!` return `Option<Coin>`, `pop_front` returns `(rank, Coin)`),
///   and for a resource the compiler forces you to consume what you get back - so value
///   cannot silently leak.
/// - `destroy_empty` aborts `ENotEmpty` if any prize is unclaimed - the safety net that
///   stops you discarding a vault that still holds funds.
///
/// Prizes are keyed by rank (1 = champion) in ascending order, so `pop_front` pays the
/// champion first and drains down the ranking.
///
/// The map never checks the caller. This vault is shared, so the integrator gates
/// privileged ops with an `OrganizerCap` bound to one vault by ID, asserted on every
/// call (a capability and the object it authorizes are separate objects, so prove they
/// belong together).
///
/// Lifecycle: `create` (returns the shared `ID` + the cap) → `fund` → `pay_next` /
/// `pay_rank` → `close`.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `SortedMap` can be integrated. It is not production-ready and must not be deployed
/// as-is.
module openzeppelin_collections::sorted_map_prize_vault;

use openzeppelin_collections::sorted_map::{Self, SortedMap};
use sui::coin::Coin;
use sui::sui::SUI;

// === Errors ===

/// The provided capability does not authorize this vault.
#[error(code = 0)]
const EWrongVault: vector<u8> = "Capability does not authorize this vault";
/// `pay_rank` was asked for a rank that holds no prize.
#[error(code = 1)]
const ENoSuchRank: vector<u8> = "No prize at this rank";
/// `fund` was called for a rank that already holds a prize (one coin per rank).
#[error(code = 2)]
const ERankAlreadyFunded: vector<u8> = "Rank already funded";
/// `fund` was called with rank 0; ranks are 1-based (1 = champion).
#[error(code = 3)]
const EInvalidRank: vector<u8> = "Rank must be >= 1";

// === Structs ===

/// Shared prize pool. `prizes` maps rank -> the coin awarded for that rank.
public struct PrizeVault has key {
    id: UID,
    prizes: SortedMap<u64, Coin<SUI>>,
}

/// Authority to fund/pay/close exactly one vault, identified by `vault`.
public struct OrganizerCap has key, store {
    id: UID,
    vault: ID,
}

// === Public Functions ===

/// Create an empty shared vault and its bound organizer cap. Returns `(vault_id, cap)`;
/// the caller routes the cap to the organizer.
public fun create(ctx: &mut TxContext): (ID, OrganizerCap) {
    let vault = PrizeVault { id: object::new(ctx), prizes: sorted_map::new() };
    let vault_id = object::id(&vault);
    let cap = OrganizerCap { id: object::new(ctx), vault: vault_id };
    transfer::share_object(vault);
    (vault_id, cap)
}

/// Abort unless `cap` authorizes `vault`. Called by every privileged op.
fun assert_cap(vault: &PrizeVault, cap: &OrganizerCap) {
    assert!(cap.vault == object::id(vault), EWrongVault);
}

/// Fund the prize at `rank` with `coin` (one coin per rank). Ranks are 1-based (1 = champion),
/// so `fund` aborts `EInvalidRank` on rank 0. Aborts `ERankAlreadyFunded` if the rank is already
/// funded - a named guard that keeps `fund` clean: without it a re-fund would make `insert!`
/// return `some(old_coin)`, and the follow-up `destroy_none()` would abort with the opaque
/// foreign `std::option::EOPTION_IS_SET`. On the guarded fresh slot `insert!` returns `none`,
/// which `destroy_none()` consumes (a resource map's `insert!` return cannot be ignored).
public fun fund(vault: &mut PrizeVault, cap: &OrganizerCap, rank: u64, coin: Coin<SUI>) {
    assert_cap(vault, cap);
    assert!(rank >= 1, EInvalidRank);
    assert!(!vault.prizes.contains!(&rank), ERankAlreadyFunded);
    vault.prizes.insert!(rank, coin).destroy_none();
}

/// Pay the champion: remove and return the lowest-rank `(rank, coin)` via `pop_front`.
/// Aborts `EEmpty` if the vault is empty.
public fun pay_next(vault: &mut PrizeVault, cap: &OrganizerCap): (u64, Coin<SUI>) {
    assert_cap(vault, cap);
    vault.prizes.pop_front()
}

/// Pay a specific `rank`, returning its coin. `remove!` returns `none` for an absent
/// rank rather than aborting, so we surface our own `ENoSuchRank`.
public fun pay_rank(vault: &mut PrizeVault, cap: &OrganizerCap, rank: u64): Coin<SUI> {
    assert_cap(vault, cap);
    let prize = vault.prizes.remove!(&rank);
    assert!(prize.is_some(), ENoSuchRank);
    prize.destroy_some()
}

/// Number of unclaimed prizes still resting in the vault.
public fun unclaimed(vault: &PrizeVault): u64 {
    vault.prizes.length()
}

/// Destroy a fully-paid vault and its cap. Aborts `ENotEmpty` if any prize is unclaimed
/// - nothing is lost, the transaction simply reverts and the vault stands.
public fun close(vault: PrizeVault, cap: OrganizerCap) {
    assert_cap(&vault, &cap);
    let PrizeVault { id, prizes } = vault;
    prizes.destroy_empty(); // ENotEmpty here if prizes remain
    id.delete();
    let OrganizerCap { id: cap_id, vault: _ } = cap;
    cap_id.delete();
}

// === Test-Only Helpers ===

/// The map's test-only order check. Ranks are plain ascending `u64`, so the bare form.
#[test_only]
public fun vault_well_formed(vault: &PrizeVault): bool {
    vault.prizes.is_well_formed!()
}

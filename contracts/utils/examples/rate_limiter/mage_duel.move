/// Example 3 — Many limiters of mixed variants inside one type (and rate limiting outside DeFi).
///
/// A `Mage` packs four `RateLimiter`s, one per game resource:
///  - `health`  (Bucket):   consuming = taking damage; refill = passive regeneration.
///  - `mana`    (Bucket):   consuming = paying a spell's cost; refill = mana regeneration.
///  - `spell_a_cd` (Cooldown, capacity 1): gated for `CD_MS` after a single cast.
///  - `spell_b_cd` (Cooldown, capacity 3): gated for `CD_MS` after three casts.
///
/// The flow is challenge/accept and cap-gated:
///  - A challenger calls `challenge(opponent)`: this spawns both mages, shares a `Duel`, emits
///    `DuelInitiated`, and returns a `ChallengerCap` (kept by the challenger) plus a
///    `PotentialOpponentCap` invitation to be routed to the opponent.
///  - The opponent calls `accept(&mut Duel, PotentialOpponentCap)`: this burns the invitation,
///    starts the duel, emits `DuelStarted`, and returns an `OpponentCap`.
///  - Each side casts at the other through its own cap. A spell costs mana, deals damage, and burns
///    one charge of that spell's cooldown. When a mage's health reaches 0 the duel ends, the
///    winning side is recorded, and `DuelEnded` is emitted.
module openzeppelin_utils::mage_duel;

use openzeppelin_utils::rate_limiter::{Self, RateLimiter};
use sui::clock::Clock;
use sui::event;

#[error(code = 0)]
const EDuelOver: vector<u8> = "The duel already has a winner";
#[error(code = 1)]
const ENotOpponent: vector<u8> = "Only the named opponent can accept";
#[error(code = 2)]
const EAlreadyStarted: vector<u8> = "The duel has already been accepted";
#[error(code = 3)]
const ENotStarted: vector<u8> = "The duel has not been accepted yet";
#[error(code = 4)]
const EWrongDuel: vector<u8> = "This cap is for a different duel";

const MAX_HEALTH: u64 = 100;
const MAX_MANA: u64 = 60;
const CD_MS: u64 = 10_000; // 10s cooldown after a spell is exhausted

// Spell A: cheap, light hit, single charge before cooldown.
const SPELL_A_COST: u64 = 10;
const SPELL_A_DAMAGE: u64 = 15;
// Spell B: pricier, heavier hit, three charges before cooldown.
const SPELL_B_COST: u64 = 20;
const SPELL_B_DAMAGE: u64 = 30;

/// A single combatant. A plain `store` value held by the `Duel`.
public struct Mage has store {
    health: RateLimiter,
    mana: RateLimiter,
    spell_a_cd: RateLimiter,
    spell_b_cd: RateLimiter,
}

/// Shared arena holding both mages by value. `started` flips on `accept`; `challenger_won` is set
/// when one mage's health hits 0 (`true` if the challenger landed the killing blow).
public struct Duel has key {
    id: UID,
    challenger_mage: Mage,
    opponent_mage: Mage,
    started: bool,
    challenger_won: Option<bool>,
}

/// Proof that the holder is the challenger of `duel_id`. Gates the challenger's casts.
public struct ChallengerCap has key, store {
    id: UID,
    duel_id: ID,
}

/// The invitation to a duel. Handed out by `challenge` and required by `accept`, which burns it in
/// exchange for an `OpponentCap`.
public struct PotentialOpponentCap has key, store {
    id: UID,
    duel_id: ID,
}

/// Proof that the holder is the opponent of `duel_id`. Gates the opponent's casts.
public struct OpponentCap has key, store {
    id: UID,
    duel_id: ID,
}

/// Emitted when a challenger opens a duel against `opponent`.
public struct DuelInitiated has copy, drop {
    duel_id: ID,
    challenger: address,
    opponent: address,
}

/// Emitted when the opponent accepts and the duel begins.
public struct DuelStarted has copy, drop {
    duel_id: ID,
}

/// Emitted when a mage is defeated and the duel ends.
public struct DuelEnded has copy, drop {
    duel_id: ID,
    challenger_won: bool,
}

/// Open a duel against `opponent`: spawn both full-health mages and share the `Duel`. Returns a
/// `ChallengerCap` (kept by the challenger) and a `PotentialOpponentCap` (the invitation, to be
/// routed to `opponent`). The duel does not begin until the opponent calls `accept`.
public fun challenge(
    opponent: address,
    clock: &Clock,
    ctx: &mut TxContext,
): (ChallengerCap, PotentialOpponentCap) {
    let challenger = ctx.sender();
    let duel = Duel {
        id: object::new(ctx),
        challenger_mage: new_mage(clock),
        opponent_mage: new_mage(clock),
        started: false,
        challenger_won: option::none(),
    };
    let duel_id = object::id(&duel);
    event::emit(DuelInitiated { duel_id, challenger, opponent });
    transfer::share_object(duel);

    (
        ChallengerCap { id: object::new(ctx), duel_id },
        PotentialOpponentCap { id: object::new(ctx), duel_id },
    )
}

/// Accept a pending duel by burning the `PotentialOpponentCap` invitation. Starts the duel and
/// returns an `OpponentCap` that gates the opponent's casts.
public fun accept(duel: &mut Duel, cap: PotentialOpponentCap, ctx: &mut TxContext): OpponentCap {
    let PotentialOpponentCap { id, duel_id } = cap;
    assert!(duel_id == object::id(duel), ENotOpponent);
    assert!(!duel.started, EAlreadyStarted);
    id.delete();
    duel.started = true;
    event::emit(DuelStarted { duel_id });
    OpponentCap { id: object::new(ctx), duel_id }
}

/// Challenger casts spell A at the opponent.
public fun challenger_cast_spell_a(duel: &mut Duel, cap: &ChallengerCap, clock: &Clock) {
    assert!(cap.duel_id == object::id(duel), EWrongDuel);
    cast(duel, true, true, clock);
}

/// Challenger casts spell B at the opponent.
public fun challenger_cast_spell_b(duel: &mut Duel, cap: &ChallengerCap, clock: &Clock) {
    assert!(cap.duel_id == object::id(duel), EWrongDuel);
    cast(duel, true, false, clock);
}

/// Opponent casts spell A at the challenger.
public fun opponent_cast_spell_a(duel: &mut Duel, cap: &OpponentCap, clock: &Clock) {
    assert!(cap.duel_id == object::id(duel), EWrongDuel);
    cast(duel, false, true, clock);
}

/// Opponent casts spell B at the challenger.
public fun opponent_cast_spell_b(duel: &mut Duel, cap: &OpponentCap, clock: &Clock) {
    assert!(cap.duel_id == object::id(duel), EWrongDuel);
    cast(duel, false, false, clock);
}

/// Resolve a cast: burn a cooldown charge, pay mana, then damage the target. Aborts (reverting the
/// whole transaction) if the duel is not live, the spell is on cooldown, or the caster cannot
/// afford the mana.
fun cast(duel: &mut Duel, challenger_attacking: bool, is_spell_a: bool, clock: &Clock) {
    assert!(duel.started, ENotStarted);
    assert!(duel.challenger_won.is_none(), EDuelOver);

    let (attacker, target) = if (challenger_attacking) {
        (&mut duel.challenger_mage, &mut duel.opponent_mage)
    } else {
        (&mut duel.opponent_mage, &mut duel.challenger_mage)
    };

    // Attacker pays: a cooldown charge and the spell's mana cost.
    if (is_spell_a) {
        attacker.spell_a_cd.consume_or_abort(1, clock);
        attacker.mana.consume_or_abort(SPELL_A_COST, clock);
    } else {
        attacker.spell_b_cd.consume_or_abort(1, clock);
        attacker.mana.consume_or_abort(SPELL_B_COST, clock);
    };

    // Target takes damage. Clamp to remaining health so an overkill blow doesn't get rejected by
    // the limiter's all-or-nothing consume; guard the zero case (a zero-unit consume aborts).
    let damage = if (is_spell_a) SPELL_A_DAMAGE else SPELL_B_DAMAGE;
    let dealt = damage.min(target.health.available(clock));
    if (dealt > 0) target.health.consume_or_abort(dealt, clock);

    // Defeated when no health remains: record the winning side and announce the duel's end.
    if (target.health.available(clock) == 0) {
        duel.challenger_won = option::some(challenger_attacking);
        event::emit(DuelEnded { duel_id: object::id(duel), challenger_won: challenger_attacking });
    };
}

/// The challenger's current health (projects regeneration on read).
public fun challenger_health(duel: &Duel, clock: &Clock): u64 {
    duel.challenger_mage.health.available(clock)
}

/// The opponent's current health (projects regeneration on read).
public fun opponent_health(duel: &Duel, clock: &Clock): u64 {
    duel.opponent_mage.health.available(clock)
}

/// The challenger's current mana (projects regeneration on read).
public fun challenger_mana(duel: &Duel, clock: &Clock): u64 {
    duel.challenger_mage.mana.available(clock)
}

/// The opponent's current mana (projects regeneration on read).
public fun opponent_mana(duel: &Duel, clock: &Clock): u64 {
    duel.opponent_mage.mana.available(clock)
}

/// Whether the duel has ended (one mage has been defeated).
public fun is_over(duel: &Duel): bool {
    duel.challenger_won.is_some()
}

/// Spawn a full-health, full-mana mage with both spells ready.
fun new_mage(clock: &Clock): Mage {
    let now = clock.timestamp_ms();
    Mage {
        // Health as a bucket: starts full, regenerates 1 every 2s up to MAX_HEALTH.
        health: rate_limiter::new_bucket(MAX_HEALTH, 1, 2_000, MAX_HEALTH, now, clock),
        // Mana as a bucket: starts full, regenerates 5 every second up to MAX_MANA.
        mana: rate_limiter::new_bucket(MAX_MANA, 5, 1_000, MAX_MANA, now, clock),
        // Spell A: 1 charge, then a CD_MS cooldown. Starts ready (granted seed).
        spell_a_cd: rate_limiter::new_cooldown(1, CD_MS, 1, 0, clock),
        // Spell B: 3 charges, then a CD_MS cooldown. Starts ready (granted seed).
        spell_b_cd: rate_limiter::new_cooldown(3, CD_MS, 3, 0, clock),
    }
}

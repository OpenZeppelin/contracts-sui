module openzeppelin_utils::mage_duel_tests;

use openzeppelin_utils::mage_duel::{Self, challenge, Duel, ChallengerCap, OpponentCap};
use openzeppelin_utils::rate_limiter;
use std::unit_test::{destroy, assert_eq};
use sui::clock::Clock;
use sui::test_scenario::{Self as ts, Scenario};

const MAX_HEALTH: u64 = 100;
const MAX_MANA: u64 = 60;

const CD_MS: u64 = 10_000;

// Happy path: challenge, accept, then both sides trade a fireball and a meteor. With no clock
// advance there is no regen, so health and mana debit by the exact spell stats.
#[test]
fun duel_starts_and_spells_are_exchanged() {
    let challenger = @0xA;
    let opponent = @0xB;

    let mut scenario = ts::begin(challenger);
    let clock = sui::clock::create_for_testing(scenario.ctx());

    // Challenger opens the duel and holds both the challenger cap and the invitation.
    let (challenger_cap, invitation) = challenge(opponent, &clock, scenario.ctx());

    // Opponent accepts, burning the invitation for an opponent cap. The duel is now live.
    scenario.next_tx(opponent);
    let mut duel = scenario.take_shared<Duel>();
    let opponent_cap = duel.accept(invitation, scenario.ctx());

    assert_eq!(duel.challenger_health(&clock), MAX_HEALTH);
    assert_eq!(duel.opponent_health(&clock), MAX_HEALTH);

    // Both sides trade a fireball (15 dmg, 10 mana) and a meteor (30 dmg, 20 mana). With no
    // clock advance there is no regen, so the deltas are exact and cooldown charges stay unused.
    duel.challenger_cast_fireball(&challenger_cap, &clock);
    duel.opponent_cast_fireball(&opponent_cap, &clock);
    duel.challenger_cast_meteor(&challenger_cap, &clock);
    duel.opponent_cast_meteor(&opponent_cap, &clock);

    // Each mage took 15 + 30 = 45 damage and spent 10 + 20 = 30 mana.
    assert_eq!(duel.challenger_health(&clock), MAX_HEALTH - 45);
    assert_eq!(duel.opponent_health(&clock), MAX_HEALTH - 45);
    assert_eq!(duel.challenger_mana(&clock), MAX_MANA - 30);
    assert_eq!(duel.opponent_mana(&clock), MAX_MANA - 30);
    assert!(!duel.is_over());

    destroy(challenger_cap);
    destroy(opponent_cap);
    ts::return_shared(duel);
    sui::clock::destroy_for_testing(clock);
    scenario.end();
}

// Fireball's cooldown has capacity 1: the first cast succeeds, and recasting before `CD_MS`
// elapses hits the gate and aborts `ERateLimited`.
#[test, expected_failure(abort_code = rate_limiter::ERateLimited)]
fun second_fireball_aborts_before_cooldown_elapses() {
    let challenger = @0xA;
    let opponent = @0xB;

    let mut scenario = ts::begin(challenger);
    let clock = sui::clock::create_for_testing(scenario.ctx());

    let (challenger_cap, invitation) = challenge(opponent, &clock, scenario.ctx());

    scenario.next_tx(opponent);
    let mut duel = scenario.take_shared<Duel>();
    let _opponent_cap = duel.accept(invitation, scenario.ctx());

    // Fireball's cooldown has capacity 1: the first cast succeeds and exhausts it.
    duel.challenger_cast_fireball(&challenger_cap, &clock);
    assert_eq!(duel.opponent_health(&clock), MAX_HEALTH - 15); // first cast landed
    // Casting again before CD_MS elapses hits the cooldown and aborts the whole transaction.
    duel.challenger_cast_fireball(&challenger_cap, &clock);

    abort
}

// A defeated mage ends the duel: the killing blow drives health to 0, `is_over` flips true, and
// `DuelEnded` is emitted. Also exercises the overkill clamp — the final meteor's 30 damage is
// clamped to the defender's remaining 15 health by the `min` in `cast`.
#[test]
fun duel_ends_when_a_mage_is_defeated() {
    let challenger = @0xA;
    let opponent = @0xB;

    let mut scenario = ts::begin(challenger);
    let mut clock = sui::clock::create_for_testing(scenario.ctx());

    let (challenger_cap, invitation) = challenge(opponent, &clock, scenario.ctx());

    scenario.next_tx(opponent);
    let mut duel = scenario.take_shared<Duel>();
    let opponent_cap = duel.accept(invitation, scenario.ctx());

    // Three meteors at t=0: 90 damage spends the full 60 mana and exhausts the 3-charge cooldown.
    duel.challenger_cast_meteor(&challenger_cap, &clock);
    duel.challenger_cast_meteor(&challenger_cap, &clock);
    duel.challenger_cast_meteor(&challenger_cap, &clock);
    assert_eq!(duel.opponent_health(&clock), MAX_HEALTH - 90); // 10 left
    assert!(!duel.is_over());

    // Advance CD_MS so the meteor cooldown releases and mana regenerates. Opponent regenerates
    // 5 health (1 per 2s) to 15; the next meteor's 30 damage is clamped to that 15 — the killing blow.
    clock.increment_for_testing(CD_MS);
    assert_eq!(duel.opponent_health(&clock), 15);
    duel.challenger_cast_meteor(&challenger_cap, &clock);

    assert_eq!(duel.opponent_health(&clock), 0);
    assert!(duel.is_over());

    destroy(challenger_cap);
    destroy(opponent_cap);
    ts::return_shared(duel);
    sui::clock::destroy_for_testing(clock);
    scenario.end();
}

// Casting before the opponent accepts aborts `ENotStarted`.
#[test, expected_failure(abort_code = mage_duel::ENotStarted)]
fun cast_before_duel_starts_aborts() {
    let challenger = @0xA;
    let opponent = @0xB;

    let mut scenario = ts::begin(challenger);
    let clock = sui::clock::create_for_testing(scenario.ctx());

    let (challenger_cap, _invitation) = challenge(opponent, &clock, scenario.ctx());

    scenario.next_tx(challenger);
    let mut duel = scenario.take_shared<Duel>();
    // The duel was never accepted, so `started` is false.
    duel.challenger_cast_fireball(&challenger_cap, &clock);

    abort
}

// Once a duel has a winner, further casts abort `EDuelOver`.
#[test, expected_failure(abort_code = mage_duel::EDuelOver)]
fun cast_after_duel_is_over_aborts() {
    let challenger = @0xA;
    let opponent = @0xB;

    let mut scenario = ts::begin(challenger);
    let mut clock = sui::clock::create_for_testing(scenario.ctx());

    let (challenger_cap, invitation) = challenge(opponent, &clock, scenario.ctx());

    scenario.next_tx(opponent);
    let mut duel = scenario.take_shared<Duel>();
    let _opponent_cap = duel.accept(invitation, scenario.ctx());

    // Defeat the opponent (same sequence as `duel_ends_when_a_mage_is_defeated`).
    duel.challenger_cast_meteor(&challenger_cap, &clock);
    duel.challenger_cast_meteor(&challenger_cap, &clock);
    duel.challenger_cast_meteor(&challenger_cap, &clock);
    clock.increment_for_testing(CD_MS);
    duel.challenger_cast_meteor(&challenger_cap, &clock);
    assert!(duel.is_over());

    // The duel already has a winner, so any further cast aborts.
    duel.challenger_cast_meteor(&challenger_cap, &clock);

    abort
}

// `accept` rejects an invitation minted for a different duel.
#[test, expected_failure(abort_code = mage_duel::EWrongDuel)]
fun accept_with_invitation_for_another_duel_aborts() {
    let challenger = @0xA;
    let opponent = @0xB;

    let mut scenario = ts::begin(challenger);
    let clock = sui::clock::create_for_testing(scenario.ctx());

    // Duel 1: keep its invitation.
    let (_cap1, invitation1) = challenge(opponent, &clock, scenario.ctx());

    // Duel 2: a separate arena.
    scenario.next_tx(challenger);
    let (_cap2, _invitation2) = challenge(opponent, &clock, scenario.ctx());

    scenario.next_tx(opponent);
    let id2 = ts::most_recent_id_shared<Duel>().destroy_some();
    let mut duel2 = ts::take_shared_by_id<Duel>(&scenario, id2);
    // Duel 1's invitation does not match duel 2.
    let _opponent_cap = duel2.accept(invitation1, scenario.ctx());

    abort
}

// === EWrongDuel on each cast wrapper ===

#[test, expected_failure(abort_code = mage_duel::EWrongDuel)]
fun challenger_fireball_on_wrong_duel_aborts() {
    let mut scenario = ts::begin(@0xA);
    let clock = sui::clock::create_for_testing(scenario.ctx());
    let (mut duel2, challenger_cap1, opponent_cap1) = two_duels_cross_caps(&mut scenario, &clock);
    destroy(opponent_cap1);
    duel2.challenger_cast_fireball(&challenger_cap1, &clock);
    abort
}

#[test, expected_failure(abort_code = mage_duel::EWrongDuel)]
fun challenger_meteor_on_wrong_duel_aborts() {
    let mut scenario = ts::begin(@0xA);
    let clock = sui::clock::create_for_testing(scenario.ctx());
    let (mut duel2, challenger_cap1, opponent_cap1) = two_duels_cross_caps(&mut scenario, &clock);
    destroy(opponent_cap1);
    duel2.challenger_cast_meteor(&challenger_cap1, &clock);
    abort
}

#[test, expected_failure(abort_code = mage_duel::EWrongDuel)]
fun opponent_fireball_on_wrong_duel_aborts() {
    let mut scenario = ts::begin(@0xA);
    let clock = sui::clock::create_for_testing(scenario.ctx());
    let (mut duel2, challenger_cap1, opponent_cap1) = two_duels_cross_caps(&mut scenario, &clock);
    destroy(challenger_cap1);
    duel2.opponent_cast_fireball(&opponent_cap1, &clock);
    abort
}

#[test, expected_failure(abort_code = mage_duel::EWrongDuel)]
fun opponent_meteor_on_wrong_duel_aborts() {
    let mut scenario = ts::begin(@0xA);
    let clock = sui::clock::create_for_testing(scenario.ctx());
    let (mut duel2, challenger_cap1, opponent_cap1) = two_duels_cross_caps(&mut scenario, &clock);
    destroy(challenger_cap1);
    duel2.opponent_cast_meteor(&opponent_cap1, &clock);
    abort
}

// === Helpers ===

// Start a fresh duel between @0xA (challenger) and @0xB (opponent), accept it, and return the
// duel's `ID` plus both caps.
fun start_duel(scenario: &mut Scenario, clock: &Clock): (ID, ChallengerCap, OpponentCap) {
    let challenger = @0xA;
    let opponent = @0xB;

    scenario.next_tx(challenger);
    let (challenger_cap, invitation) = challenge(opponent, clock, scenario.ctx());

    scenario.next_tx(opponent);
    let id = ts::most_recent_id_shared<Duel>().destroy_some();
    let mut duel = ts::take_shared_by_id<Duel>(scenario, id);
    let opponent_cap = duel.accept(invitation, scenario.ctx());
    ts::return_shared(duel);

    (id, challenger_cap, opponent_cap)
}

// Build two independent duels and return duel 2 (taken from the inventory) together with duel 1's
// caps — so a cast against duel 2 with a duel-1 cap exercises the `EWrongDuel` guard. Duel 2's own
// caps are discarded; the caller cleans up whichever duel-1 cap it does not use.
fun two_duels_cross_caps(scenario: &mut Scenario, clock: &Clock): (Duel, ChallengerCap, OpponentCap) {
    let (_id1, challenger_cap1, opponent_cap1) = start_duel(scenario, clock);
    let (id2, challenger_cap2, opponent_cap2) = start_duel(scenario, clock);

    // Commit the `return_shared` from `start_duel` so duel 2 is takeable again.
    scenario.next_tx(@0xA);
    let duel2 = ts::take_shared_by_id<Duel>(scenario, id2);
    destroy(challenger_cap2);
    destroy(opponent_cap2);

    (duel2, challenger_cap1, opponent_cap1)
}

module openzeppelin_utils::mage_duel_tests;

use openzeppelin_utils::mage_duel::{challenge, Duel};
use openzeppelin_utils::rate_limiter;
use std::unit_test::{destroy, assert_eq};
use sui::test_scenario as ts;

const MAX_HEALTH: u64 = 100;
const MAX_MANA: u64 = 60;

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

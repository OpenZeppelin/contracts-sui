/// Scenario walkthroughs for `prize_vault` - the resource pattern (Coin<SUI> values,
/// cap-gated writes, ordered payout, drain-then-destroy, and the ENotEmpty/EEmpty safety nets).
module openzeppelin_collections::sorted_map_prize_vault_tests;

use openzeppelin_collections::sorted_map_prize_vault::{
    Self as prize_vault,
    PrizeVault,
    OrganizerCap
};
use std::unit_test::assert_eq;
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario as ts;

const ORGANIZER: address = @0x0A;
const FIRST: address = @0x01;
const SECOND: address = @0x02;
const THIRD: address = @0x03;

// === Scenario 2 - fund out of order, pay champion-first, conserve, tear down ===
//
// Teaches the resource lifecycle: a `SortedMap<u64, Coin<SUI>>` holds real coins, so
// every displacement is returned (never dropped), payout drains lowest-rank-first via
// `pop_front`, and `close` consumes the now-empty map. Conservation is checked
// end-to-end: 175 minted in == 100 + 50 + 25 paid out.
#[test]
fun fund_payout_destroy() {
    let mut scenario = ts::begin(ORGANIZER);

    // Tx1 - ORGANIZER: create the shared vault; keep its bound cap.
    {
        let (_, cap) = prize_vault::create(scenario.ctx());
        transfer::public_transfer(cap, ORGANIZER);
    };

    // Tx2 - ORGANIZER: fund ranks 3, 1, 2 out of order - the map sorts by rank.
    ts::next_tx(&mut scenario, ORGANIZER);
    {
        let mut vault = ts::take_shared<PrizeVault>(&scenario);
        let cap = ts::take_from_sender<OrganizerCap>(&scenario);
        prize_vault::fund(&mut vault, &cap, 3, coin::mint_for_testing<SUI>(25, scenario.ctx()));
        prize_vault::fund(&mut vault, &cap, 1, coin::mint_for_testing<SUI>(100, scenario.ctx()));
        prize_vault::fund(&mut vault, &cap, 2, coin::mint_for_testing<SUI>(50, scenario.ctx()));
        assert_eq!(prize_vault::unclaimed(&vault), 3);
        ts::return_to_sender(&scenario, cap);
        ts::return_shared(vault);
    };

    // Tx3 - ORGANIZER: pay champion-first; ranks come out strictly 1, 2, 3.
    ts::next_tx(&mut scenario, ORGANIZER);
    {
        let mut vault = ts::take_shared<PrizeVault>(&scenario);
        let cap = ts::take_from_sender<OrganizerCap>(&scenario);

        let (r1, c1) = prize_vault::pay_next(&mut vault, &cap);
        assert_eq!(r1, 1);
        assert_eq!(c1.value(), 100);
        transfer::public_transfer(c1, FIRST);

        let (r2, c2) = prize_vault::pay_next(&mut vault, &cap);
        assert_eq!(r2, 2);
        assert_eq!(c2.value(), 50);
        transfer::public_transfer(c2, SECOND);

        let (r3, c3) = prize_vault::pay_next(&mut vault, &cap);
        assert_eq!(r3, 3);
        assert_eq!(c3.value(), 25);
        transfer::public_transfer(c3, THIRD);

        assert_eq!(prize_vault::unclaimed(&vault), 0);
        ts::return_to_sender(&scenario, cap);
        ts::return_shared(vault);
    };

    // Tx4 - ORGANIZER: close the now-empty vault (and consume the cap).
    ts::next_tx(&mut scenario, ORGANIZER);
    {
        let vault = ts::take_shared<PrizeVault>(&scenario);
        let cap = ts::take_from_sender<OrganizerCap>(&scenario);
        prize_vault::close(vault, cap);
    };

    // Tx5 - each winner holds exactly their prize (the other half of conservation).
    ts::next_tx(&mut scenario, FIRST);
    {
        let c = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert_eq!(c.value(), 100);
        coin::burn_for_testing(c);
    };
    ts::next_tx(&mut scenario, SECOND);
    {
        let c = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert_eq!(c.value(), 50);
        coin::burn_for_testing(c);
    };
    ts::next_tx(&mut scenario, THIRD);
    {
        let c = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert_eq!(c.value(), 25);
        coin::burn_for_testing(c);
    };

    ts::end(scenario);
}

// === Scenario 4 - closing a vault with unclaimed prizes aborts ENotEmpty ===
//
// The conservation safety net: `destroy_empty` refuses to discard a map that still
// holds value. The abort is the library's ENotEmpty, at the library location - the
// transaction reverts and the vault (with its coin) stands.
#[test]
#[
    expected_failure(
        abort_code = openzeppelin_collections::sorted_map::ENotEmpty,
        location = openzeppelin_collections::sorted_map,
    ),
]
fun close_nonempty_vault_aborts() {
    let mut scenario = ts::begin(ORGANIZER);

    // Tx1 - ORGANIZER: create.
    {
        let (_, cap) = prize_vault::create(scenario.ctx());
        transfer::public_transfer(cap, ORGANIZER);
    };
    // Tx2 - ORGANIZER: fund one rank (a prize now rests in the vault).
    ts::next_tx(&mut scenario, ORGANIZER);
    {
        let mut vault = ts::take_shared<PrizeVault>(&scenario);
        let cap = ts::take_from_sender<OrganizerCap>(&scenario);
        prize_vault::fund(&mut vault, &cap, 1, coin::mint_for_testing<SUI>(100, scenario.ctx()));
        ts::return_to_sender(&scenario, cap);
        ts::return_shared(vault);
    };
    // Tx3 - ORGANIZER: close while a prize remains → ENotEmpty.
    ts::next_tx(&mut scenario, ORGANIZER);
    {
        let vault = ts::take_shared<PrizeVault>(&scenario);
        let cap = ts::take_from_sender<OrganizerCap>(&scenario);
        prize_vault::close(vault, cap); // aborts here
    };
    ts::end(scenario);
}

// === Scenario 6 - paying from an empty vault aborts EEmpty (the other drain-related library abort) ===
//
// prize_vault's second library abort: `pay_next` -> `pop_front` on an empty map asserts
// EEmpty at the library location, so an over-eager payout reverts cleanly.
#[test]
#[
    expected_failure(
        abort_code = openzeppelin_collections::sorted_map::EEmpty,
        location = openzeppelin_collections::sorted_map,
    ),
]
fun pay_next_on_empty_vault_aborts() {
    let mut scenario = ts::begin(ORGANIZER);

    // Tx1 - ORGANIZER: create an empty vault; keep its bound cap.
    {
        let (_, cap) = prize_vault::create(scenario.ctx());
        transfer::public_transfer(cap, ORGANIZER);
    };
    // Tx2 - ORGANIZER: pay from the still-empty vault -> EEmpty (aborts inside pay_next).
    ts::next_tx(&mut scenario, ORGANIZER);
    {
        let mut vault = ts::take_shared<PrizeVault>(&scenario);
        let cap = ts::take_from_sender<OrganizerCap>(&scenario);
        let (_r, c) = prize_vault::pay_next(&mut vault, &cap); // aborts here (empty)
        // Unreachable past the abort; kept well-formed for the resource checker.
        coin::burn_for_testing(c);
        ts::return_to_sender(&scenario, cap);
        ts::return_shared(vault);
    };
    ts::end(scenario);
}

// === Scenario 8 - funding rank 0 aborts EInvalidRank (ranks are 1-based) ===
//
// `pop_front` pays the lowest rank first, so a rank-0 prize would be paid before the
// champion (rank 1). `fund` guards against it with a named EInvalidRank at this module.
#[test]
#[
    expected_failure(
        abort_code = openzeppelin_collections::sorted_map_prize_vault::EInvalidRank,
        location = openzeppelin_collections::sorted_map_prize_vault,
    ),
]
fun fund_rank_zero_aborts() {
    let mut scenario = ts::begin(ORGANIZER);

    // Tx1 - ORGANIZER: create an empty vault; keep its bound cap.
    {
        let (_, cap) = prize_vault::create(scenario.ctx());
        transfer::public_transfer(cap, ORGANIZER);
    };
    // Tx2 - ORGANIZER: fund rank 0 -> EInvalidRank (aborts inside fund).
    ts::next_tx(&mut scenario, ORGANIZER);
    {
        let mut vault = ts::take_shared<PrizeVault>(&scenario);
        let cap = ts::take_from_sender<OrganizerCap>(&scenario);
        prize_vault::fund(&mut vault, &cap, 0, coin::mint_for_testing<SUI>(100, scenario.ctx()));
        // Unreachable past the abort; kept well-formed for the resource checker.
        ts::return_to_sender(&scenario, cap);
        ts::return_shared(vault);
    };
    ts::end(scenario);
}

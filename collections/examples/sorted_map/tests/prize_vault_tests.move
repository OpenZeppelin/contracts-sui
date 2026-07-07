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
    scenario.next_tx(ORGANIZER);
    {
        let mut vault = scenario.take_shared<PrizeVault>();
        let cap = scenario.take_from_sender<OrganizerCap>();
        vault.fund(&cap, 3, coin::mint_for_testing<SUI>(25, scenario.ctx()));
        vault.fund(&cap, 1, coin::mint_for_testing<SUI>(100, scenario.ctx()));
        vault.fund(&cap, 2, coin::mint_for_testing<SUI>(50, scenario.ctx()));
        assert_eq!(vault.unclaimed(), 3);
        scenario.return_to_sender(cap);
        ts::return_shared(vault);
    };

    // Tx3 - ORGANIZER: pay champion-first; ranks come out strictly 1, 2, 3.
    scenario.next_tx(ORGANIZER);
    {
        let mut vault = scenario.take_shared<PrizeVault>();
        let cap = scenario.take_from_sender<OrganizerCap>();

        let (r1, c1) = vault.pay_next(&cap);
        assert_eq!(r1, 1);
        assert_eq!(c1.value(), 100);
        transfer::public_transfer(c1, FIRST);

        let (r2, c2) = vault.pay_next(&cap);
        assert_eq!(r2, 2);
        assert_eq!(c2.value(), 50);
        transfer::public_transfer(c2, SECOND);

        let (r3, c3) = vault.pay_next(&cap);
        assert_eq!(r3, 3);
        assert_eq!(c3.value(), 25);
        transfer::public_transfer(c3, THIRD);

        assert_eq!(vault.unclaimed(), 0);
        scenario.return_to_sender(cap);
        ts::return_shared(vault);
    };

    // Tx4 - ORGANIZER: close the now-empty vault (and consume the cap).
    scenario.next_tx(ORGANIZER);
    {
        let vault = scenario.take_shared<PrizeVault>();
        let cap = scenario.take_from_sender<OrganizerCap>();
        vault.close(cap);
    };

    // Tx5 - each winner holds exactly their prize (the other half of conservation).
    scenario.next_tx(FIRST);
    {
        let c = scenario.take_from_sender<Coin<SUI>>();
        assert_eq!(c.value(), 100);
        c.burn_for_testing();
    };
    scenario.next_tx(SECOND);
    {
        let c = scenario.take_from_sender<Coin<SUI>>();
        assert_eq!(c.value(), 50);
        c.burn_for_testing();
    };
    scenario.next_tx(THIRD);
    {
        let c = scenario.take_from_sender<Coin<SUI>>();
        assert_eq!(c.value(), 25);
        c.burn_for_testing();
    };

    scenario.end();
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
    scenario.next_tx(ORGANIZER);
    {
        let mut vault = scenario.take_shared<PrizeVault>();
        let cap = scenario.take_from_sender<OrganizerCap>();
        vault.fund(&cap, 1, coin::mint_for_testing<SUI>(100, scenario.ctx()));
        scenario.return_to_sender(cap);
        ts::return_shared(vault);
    };
    // Tx3 - ORGANIZER: close while a prize remains → ENotEmpty.
    scenario.next_tx(ORGANIZER);
    {
        let vault = scenario.take_shared<PrizeVault>();
        let cap = scenario.take_from_sender<OrganizerCap>();
        vault.close(cap); // aborts here
    };
    scenario.end();
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
    scenario.next_tx(ORGANIZER);
    {
        let mut vault = scenario.take_shared<PrizeVault>();
        let cap = scenario.take_from_sender<OrganizerCap>();
        let (_r, c) = vault.pay_next(&cap); // aborts here (empty)
        // Unreachable past the abort; kept well-formed for the resource checker.
        c.burn_for_testing();
        scenario.return_to_sender(cap);
        ts::return_shared(vault);
    };
    scenario.end();
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
    scenario.next_tx(ORGANIZER);
    {
        let mut vault = scenario.take_shared<PrizeVault>();
        let cap = scenario.take_from_sender<OrganizerCap>();
        vault.fund(&cap, 0, coin::mint_for_testing<SUI>(100, scenario.ctx()));
        // Unreachable past the abort; kept well-formed for the resource checker.
        scenario.return_to_sender(cap);
        ts::return_shared(vault);
    };
    scenario.end();
}

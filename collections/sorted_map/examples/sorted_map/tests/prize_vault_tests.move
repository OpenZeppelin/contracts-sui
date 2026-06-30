/// Scenario walkthroughs for `prize_vault` - the resource pattern (Coin<SUI> values,
/// cap-gated writes, ordered payout, drain-then-destroy, the ENotEmpty safety net).
module openzeppelin_sorted_map::prize_vault_tests;

use openzeppelin_sorted_map::prize_vault::{Self, PrizeVault, OrganizerCap};
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
        assert!(prize_vault::unclaimed(&vault) == 3);
        ts::return_to_sender(&scenario, cap);
        ts::return_shared(vault);
    };

    // Tx3 - ORGANIZER: pay champion-first; ranks come out strictly 1, 2, 3.
    ts::next_tx(&mut scenario, ORGANIZER);
    {
        let mut vault = ts::take_shared<PrizeVault>(&scenario);
        let cap = ts::take_from_sender<OrganizerCap>(&scenario);

        let (r1, c1) = prize_vault::pay_next(&mut vault, &cap);
        assert!(r1 == 1 && c1.value() == 100);
        transfer::public_transfer(c1, FIRST);

        let (r2, c2) = prize_vault::pay_next(&mut vault, &cap);
        assert!(r2 == 2 && c2.value() == 50);
        transfer::public_transfer(c2, SECOND);

        let (r3, c3) = prize_vault::pay_next(&mut vault, &cap);
        assert!(r3 == 3 && c3.value() == 25);
        transfer::public_transfer(c3, THIRD);

        assert!(prize_vault::unclaimed(&vault) == 0);
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
        assert!(c.value() == 100);
        coin::burn_for_testing(c);
    };
    ts::next_tx(&mut scenario, SECOND);
    {
        let c = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(c.value() == 50);
        coin::burn_for_testing(c);
    };
    ts::next_tx(&mut scenario, THIRD);
    {
        let c = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(c.value() == 25);
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
        abort_code = openzeppelin_sorted_map::sorted_map::ENotEmpty,
        location = openzeppelin_sorted_map::sorted_map,
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

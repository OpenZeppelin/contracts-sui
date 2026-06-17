module openzeppelin_utils::rare_coin_tests;

use openzeppelin_utils::rare_coin::{Self, RARE_COIN};
use std::unit_test::{destroy, assert_eq};
use sui::coin::Coin;
use sui::test_scenario as ts;

// Verifies the example's `init`: a fixed supply of 10,000 units is minted to the publisher,
// and exactly one coin object is delivered.
#[test]
fun init_mints_fixed_supply_to_publisher() {
    let publisher = @0xA;

    let mut scenario = ts::begin(publisher);
    rare_coin::init_for_testing(scenario.ctx());

    scenario.next_tx(publisher);

    let coins = scenario.take_from_sender<Coin<RARE_COIN>>();
    assert_eq!(coins.value(), 10_000);
    // The whole supply lands in a single coin object - nothing else was minted to the publisher.
    assert!(!scenario.has_most_recent_for_sender<Coin<RARE_COIN>>());

    destroy(coins);
    scenario.end();
}

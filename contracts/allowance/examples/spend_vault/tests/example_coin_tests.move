module openzeppelin_allowance::example_coin_tests;

use openzeppelin_allowance::example_coin::{Self, EXAMPLE_COIN};
use std::unit_test::{destroy, assert_eq};
use sui::coin::Coin;
use sui::test_scenario as ts;

// Verifies the example's `init`: a fixed supply of 1,000,000 units is minted to the
// publisher, and exactly one coin object is delivered.
#[test]
fun init_mints_fixed_supply_to_publisher() {
    let publisher = @0xA;

    let mut scenario = ts::begin(publisher);
    example_coin::init_for_testing(scenario.ctx());

    scenario.next_tx(publisher);

    let coins = scenario.take_from_sender<Coin<EXAMPLE_COIN>>();
    assert_eq!(coins.value(), 1_000_000);
    // The whole supply lands in a single coin object: nothing else was minted to the publisher.
    assert!(!scenario.has_most_recent_for_sender<Coin<EXAMPLE_COIN>>());

    destroy(coins);
    scenario.end();
}

/// Scenario walkthrough for `tick_registry` - the ordered-navigation pattern
/// (next/prev, ceiling/floor on integer keys).
module openzeppelin_collections::sorted_map_tick_registry_tests;

use openzeppelin_collections::sorted_map_tick_registry::{Self as tick_registry, TickRegistry};
use std::unit_test::assert_eq;
use sui::test_scenario as ts;

const ALICE: address = @0x0A;
const BOB: address = @0x0B;

// === Scenario 5 - CLMM tick navigation: add out of order, walk, ceiling/floor ===
//
// Exercises the sorted map's signature capability that the other modules don't: given
// an arbitrary price, find the nearest active tick in either direction. `tick_above`/
// `tick_below` cross to the adjacent tick; `ceiling_tick`/`floor_tick` answer for a
// target that need not itself be an active tick - the thing a hash map cannot do.
#[test]
fun tick_navigation_walkthrough() {
    let mut scenario = ts::begin(ALICE);

    // Tx1 - ALICE: deploy the shared registry.
    {
        tick_registry::deploy_and_share(scenario.ctx());
    };

    // Tx2 - ALICE: activate ticks 3000, 1000, 2000 (out of order). Each is fresh.
    ts::next_tx(&mut scenario, ALICE);
    {
        let mut reg = ts::take_shared<TickRegistry>(&scenario);
        assert!(!tick_registry::add_tick(&mut reg, 3000, 300, 0));
        assert!(!tick_registry::add_tick(&mut reg, 1000, 100, 0));
        assert!(!tick_registry::add_tick(&mut reg, 2000, 200, 0));
        ts::return_shared(reg);
    };

    // Tx3 - BOB: activate tick 4000.
    ts::next_tx(&mut scenario, BOB);
    {
        let mut reg = ts::take_shared<TickRegistry>(&scenario);
        assert!(!tick_registry::add_tick(&mut reg, 4000, 400, 0));
        ts::return_shared(reg);
    };

    // Tx4 - ALICE: walk and query the now-sorted ticks {1000,2000,3000,4000}.
    ts::next_tx(&mut scenario, ALICE);
    {
        let mut reg = ts::take_shared<TickRegistry>(&scenario);

        assert_eq!(tick_registry::min_tick(&reg), option::some(1000));
        assert_eq!(tick_registry::max_tick(&reg), option::some(4000));

        // Crossing upward / downward: next_key / prev_key. Ends terminate with none.
        assert_eq!(tick_registry::tick_above(&reg, 1000), option::some(2000));
        assert_eq!(tick_registry::tick_above(&reg, 2000), option::some(3000));
        assert!(tick_registry::tick_above(&reg, 4000).is_none());
        assert_eq!(tick_registry::tick_below(&reg, 4000), option::some(3000));
        assert!(tick_registry::tick_below(&reg, 1000).is_none());

        // Ceiling / floor for a target BETWEEN active ticks (1500 is not a tick).
        assert_eq!(tick_registry::ceiling_tick(&reg, 1500), option::some(2000));
        assert_eq!(tick_registry::floor_tick(&reg, 1500), option::some(1000));
        // Exact match: inclusive ceiling and floor both return the tick itself.
        assert_eq!(tick_registry::ceiling_tick(&reg, 2000), option::some(2000));
        assert_eq!(tick_registry::floor_tick(&reg, 2000), option::some(2000));
        // Past the ends: none.
        assert!(tick_registry::ceiling_tick(&reg, 4500).is_none());
        assert!(tick_registry::floor_tick(&reg, 500).is_none());

        // Mutate fee growth in place, then overwrite a tick's liquidity (replace).
        tick_registry::accrue_fees(&mut reg, 1000, 50);
        assert_eq!(tick_registry::fee_growth(tick_registry::borrow_tick(&reg, 1000)), 50);
        assert!(tick_registry::add_tick(&mut reg, 1000, 999, 999)); // replaces -> true
        assert_eq!(tick_registry::liquidity_net(tick_registry::borrow_tick(&reg, 1000)), 999);

        assert!(tick_registry::ticks_well_formed(&reg));
        ts::return_shared(reg);
    };

    // Tx5 - BOB: deactivate the lowest tick; min advances to 2000.
    ts::next_tx(&mut scenario, BOB);
    {
        let mut reg = ts::take_shared<TickRegistry>(&scenario);
        assert!(tick_registry::remove_tick(&mut reg, 1000));
        assert!(!tick_registry::contains_tick(&reg, 1000));
        assert_eq!(tick_registry::min_tick(&reg), option::some(2000));
        ts::return_shared(reg);
    };

    ts::end(scenario);
}

// === Borrowing an inactive tick aborts EKeyNotFound (the library abort, pinned) ===
//
// The failing companion to the walkthrough: `borrow_tick` on a tick that was never
// activated aborts the library's `EKeyNotFound` at `location = ...::sorted_map` (the
// abort originates in the library, not here). Gate with `contains_tick` to avoid it.
#[test]
#[
    expected_failure(
        abort_code = openzeppelin_collections::sorted_map::EKeyNotFound,
        location = openzeppelin_collections::sorted_map,
    ),
]
fun borrow_inactive_tick_aborts() {
    let mut scenario = ts::begin(ALICE);
    {
        tick_registry::deploy_and_share(scenario.ctx());
    };
    ts::next_tx(&mut scenario, ALICE);
    {
        let mut reg = ts::take_shared<TickRegistry>(&scenario);
        let _ = tick_registry::add_tick(&mut reg, 1000, 100, 0);
        let _ = tick_registry::borrow_tick(&reg, 2000); // 2000 inactive -> aborts
        ts::return_shared(reg); // unreachable
    };
    ts::end(scenario);
}

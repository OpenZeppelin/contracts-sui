/// Scenario walkthrough for `tick_registry` - the ordered-navigation pattern
/// (next/prev, ceiling/floor on integer keys).
module openzeppelin_collections::sorted_map_tick_registry_tests;

use openzeppelin_collections::sorted_map as sm;
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
    scenario.next_tx(ALICE);
    {
        let mut reg = scenario.take_shared<TickRegistry>();
        assert!(!reg.add_tick(3000, 300, 0));
        assert!(!reg.add_tick(1000, 100, 0));
        assert!(!reg.add_tick(2000, 200, 0));
        ts::return_shared(reg);
    };

    // Tx3 - BOB: activate tick 4000.
    scenario.next_tx(BOB);
    {
        let mut reg = scenario.take_shared<TickRegistry>();
        assert!(!reg.add_tick(4000, 400, 0));
        ts::return_shared(reg);
    };

    // Tx4 - ALICE: walk and query the now-sorted ticks {1000,2000,3000,4000}.
    scenario.next_tx(ALICE);
    {
        let mut reg = scenario.take_shared<TickRegistry>();

        assert_eq!(reg.min_tick(), option::some(1000));
        assert_eq!(reg.max_tick(), option::some(4000));

        // Crossing upward / downward: next_key / prev_key. Ends terminate with none.
        assert_eq!(reg.tick_above(1000), option::some(2000));
        assert_eq!(reg.tick_above(2000), option::some(3000));
        assert!(reg.tick_above(4000).is_none());
        assert_eq!(reg.tick_below(4000), option::some(3000));
        assert!(reg.tick_below(1000).is_none());

        // Ceiling / floor for a target BETWEEN active ticks (1500 is not a tick).
        assert_eq!(reg.ceiling_tick(1500), option::some(2000));
        assert_eq!(reg.floor_tick(1500), option::some(1000));
        // Exact match: inclusive ceiling and floor both return the tick itself.
        assert_eq!(reg.ceiling_tick(2000), option::some(2000));
        assert_eq!(reg.floor_tick(2000), option::some(2000));
        // Past the ends: none.
        assert!(reg.ceiling_tick(4500).is_none());
        assert!(reg.floor_tick(500).is_none());

        // Mutate fee growth in place, then overwrite a tick's liquidity (replace).
        reg.accrue_fees(1000, 50);
        assert_eq!(reg.borrow_tick(1000).fee_growth(), 50);
        assert!(reg.add_tick(1000, 999, 999)); // replaces -> true
        assert_eq!(reg.borrow_tick(1000).liquidity_net(), 999);

        assert!(reg.ticks_well_formed());
        ts::return_shared(reg);
    };

    // Tx5 - BOB: deactivate the lowest tick; min advances to 2000.
    scenario.next_tx(BOB);
    {
        let mut reg = scenario.take_shared<TickRegistry>();
        assert_eq!(reg.remove_tick(1000), tick_registry::new_tick(999, 999));
        assert!(!reg.contains_tick(1000));
        assert_eq!(reg.min_tick(), option::some(2000));
        ts::return_shared(reg);
    };

    scenario.end();
}

// === Borrowing an inactive tick aborts EKeyNotFound (the library abort, pinned) ===
//
// The failing companion to the walkthrough: `borrow_tick` on a tick that was never
// activated aborts the library's `EKeyNotFound` at `location = ...::sorted_map` (the
// abort originates in the library, not here). Gate with `contains_tick` to avoid it.
#[test, expected_failure(abort_code = sm::EKeyNotFound, location = sm)]
fun borrow_inactive_tick_aborts() {
    let mut scenario = ts::begin(ALICE);
    {
        tick_registry::deploy_and_share(scenario.ctx());
    };
    scenario.next_tx(ALICE);
    {
        let mut reg = scenario.take_shared<TickRegistry>();
        let _ = reg.add_tick(1000, 100, 0);
        let _ = reg.borrow_tick(2000); // 2000 inactive -> aborts
        ts::return_shared(reg); // unreachable
    };
    scenario.end();
}

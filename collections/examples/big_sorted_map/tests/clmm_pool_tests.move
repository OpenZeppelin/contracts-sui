/// Scenario walkthroughs for `clmm_pool` - the hand-rolled leaf-walk cursor (the large-tier
/// signature integration) and the `EInvalidDegree` floor guard.
module openzeppelin_collections::big_sorted_map_clmm_pool_tests;

use openzeppelin_collections::big_sorted_map_clmm_pool::{Self as clmm_pool, Pool};
use std::unit_test::assert_eq;
use sui::test_scenario as ts;

const PUBLISHER: address = @0x0F;
const KEEPER: address = @0x0E;
const SWAPPER: address = @0x05;

// === Scenario 1 - a swap crosses a run of ticks in place via the leaf-walk cursor ===
//
// Teaches the cursor: deploy a LOW-degree pool (so 12 ticks form a real multi-leaf tree),
// initialize ticks, then run swaps that cross upward from a starting price. `cross_up_from`
// seeds with one `locate_leaf!` descent and then steps leaf-to-leaf, mutating each crossed
// tick's value in place - never re-descending. Crossing is idempotent, and the sorted order
// survives the in-place mutation (values change, keys do not).
#[test]
fun clmm_swap_crosses_ticks_in_place() {
    let mut scenario = ts::begin(PUBLISHER);

    // Tx1 - PUBLISHER: deploy a low-degree pool. inner=4, leaf=3 -> the 12 ticks form SIX
    // two-key leaves ([10,20] [30,40] [50,60] [70,80] [90,100] [110,120]): a leaf overflows at
    // length 4 and splits 2+2 (the split target is (leaf_max_degree + 1) / 2 = 2).
    {
        clmm_pool::deploy_and_share(4, 3, scenario.ctx());
    };

    // Tx2 - KEEPER: initialize 12 ticks at 10,20,...,120; liquidity_net == the tick index.
    ts::next_tx(&mut scenario, KEEPER);
    {
        let mut pool = ts::take_shared<Pool>(&scenario);
        let mut t = 1u64;
        while (t <= 12) {
            clmm_pool::set_tick(&mut pool, t * 10, t * 10);
            t = t + 1;
        };
        assert_eq!(clmm_pool::tick_count(&pool), 12);
        assert_eq!(
            clmm_pool::ticks_from(&pool, 0, 100),
            vector[10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120],
        );
        // Structural proof the swap below MUST cross leaf boundaries: 12 ticks cannot fit one
        // degree-3 leaf, so the start (55) and the max (120) live in DIFFERENT leaves. Without
        // this, every assertion in Tx3/Tx4 would pass even if all ticks lived in one leaf.
        assert!(clmm_pool::seed_leaf_for(&pool, 55) != clmm_pool::seed_leaf_for(&pool, 120));
        // Exercise set_tick's overwrite branch: re-initializing an existing tick is a REPLACE
        // (insert! returns some(old), which is dropped), so the count is unchanged. Restore the
        // value afterward so the swap arithmetic below is unaffected.
        clmm_pool::set_tick(&mut pool, 60, 999);
        assert_eq!(clmm_pool::tick_count(&pool), 12); // replace, not insert
        clmm_pool::set_tick(&mut pool, 60, 60); // restore liquidity_net = 60
        ts::return_shared(pool);
    };

    // Tx3 - SWAPPER: price moves up from 55. Crosses every tick >= 55: 60,70,...,120 (7 ticks),
    // spanning four leaves ([50,60] -> [70,80] -> [90,100] -> [110,120]) that the cursor walks
    // via the leaf chain (seeded at [50,60], where 50 is filtered out as < 55).
    ts::next_tx(&mut scenario, SWAPPER);
    {
        let mut pool = ts::take_shared<Pool>(&scenario);
        let liquidity = clmm_pool::cross_up_from(&mut pool, 55);
        // 60+70+80+90+100+110+120 = 630
        assert_eq!(liquidity, 630);
        assert_eq!(clmm_pool::active_liquidity(&pool), 630);
        // crossed: 60..120; not crossed: 50 (in the seed leaf but < 55) and everything below.
        assert!(clmm_pool::tick_crossed(&pool, 60));
        assert!(clmm_pool::tick_crossed(&pool, 120));
        assert!(!clmm_pool::tick_crossed(&pool, 50));
        assert!(!clmm_pool::tick_crossed(&pool, 10));
        // The in-place value mutation left the key order (and leaf chain) intact.
        assert_eq!(
            clmm_pool::ticks_from(&pool, 0, 100),
            vector[10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120],
        );
        ts::return_shared(pool);
    };

    // Tx4 - SWAPPER: a deeper move from 25 - idempotent. Ticks 60..120 are already crossed and
    // skipped; only the NEW ticks 30,40,50 add liquidity.
    ts::next_tx(&mut scenario, SWAPPER);
    {
        let mut pool = ts::take_shared<Pool>(&scenario);
        let liquidity = clmm_pool::cross_up_from(&mut pool, 25);
        // 630 + (30+40+50) = 750
        assert_eq!(liquidity, 750);
        assert_eq!(clmm_pool::active_liquidity(&pool), 750);
        assert!(clmm_pool::tick_crossed(&pool, 30));
        assert!(!clmm_pool::tick_crossed(&pool, 20)); // 20 < 25, still uncrossed
        ts::return_shared(pool);
    };

    ts::end(scenario);
}

// === Scenario 2 - deploying below the degree floor aborts EInvalidDegree, at the library ===
//
// The min-fill floor (`inner >= 4`, `leaf >= 3`) is the denial-of-service guard: it keeps a
// node at least half full so the tree cannot degenerate into a one-entry-per-node shape an
// attacker could use to blow the dynamic-field load budget. A degree below the floor is
// rejected at construction, before any object is created.
#[test]
#[
    expected_failure(
        abort_code = openzeppelin_collections::big_sorted_map::EInvalidDegree,
        location = openzeppelin_collections::big_sorted_map,
    ),
]
fun deploy_below_degree_floor_aborts() {
    let mut scenario = ts::begin(PUBLISHER);
    {
        clmm_pool::deploy_and_share(2, 2, scenario.ctx()); // leaf=2 < floor 3 -> EInvalidDegree
    };
    ts::end(scenario); // unreachable; satisfies the type checker
}

/// A concentrated-liquidity tick map whose swap path crosses ticks with a hand-rolled
/// **leaf-walk cursor** - the integration `BigSortedMap` is built for and the small tier
/// cannot do.
///
/// # The problem this module exists to show
/// A CLMM swap crosses a *run* of ticks in order, mutating each. The obvious way - call
/// `borrow_mut!` once per tick - re-descends the whole tree on every tick (a fresh
/// root-to-leaf walk), so a deep swap loads thousands of dynamic fields and breaches the
/// ~1000-df per-transaction cap at ~167-250 ticks. The library deliberately does NOT ship
/// a blessed iterator; instead it PUBLISHES the leaf-walk primitives so an integrator can
/// own the walk:
///
/// - `locate_leaf!` - ONE descent to seed the cursor at the starting leaf.
/// - `borrow_node_mut` + `node_leaf_mut` - the leaf's data map, mutable, no re-descent.
/// - `leaf_next` / `null_index` - step to the next leaf along the doubly-linked leaf
///   chain; stop at the sentinel.
///
/// `cross_up_from` walks the chain forward from the seed leaf, mutating each crossed tick
/// in place - one descent total, then O(1) per leaf. That is the entire performance story.
///
/// # Why mutating values this way is safe
/// The cursor reaches into a leaf's `SortedMap` and calls `value_at_mut` - it changes tick
/// *values*, never *keys*, so the sorted order it is walking cannot desync. (It also never
/// inserts or removes during the walk; a structural change would invalidate the cursor and
/// you would re-seed with a fresh `locate_leaf!`.) Crossing is idempotent: a tick already
/// `crossed` is skipped, so re-running a swap from a lower tick adds only the new ticks.
///
/// # Degrees are exposed on purpose
/// `deploy_and_share` takes the node degrees so this example can force a *low* degree and
/// build a genuine multi-leaf tree at a handful of ticks - otherwise the leaf-walk would
/// have nothing to walk. Production picks large degrees. The degrees are floored
/// (`inner >= 4`, `leaf >= 3`); a value below the floor aborts `EInvalidDegree`, the guard
/// that keeps the tree from degenerating into a denial-of-service-able shape.
///
/// Lifecycle: `deploy_and_share` -> `set_tick` -> `cross_up_from` (the cursor) ->
/// `active_liquidity` / `tick_crossed` / `ticks_from`.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `BigSortedMap` can be integrated. It is not production-ready and must not be deployed
/// as-is.
module openzeppelin_big_sorted_map::clmm_pool;

use openzeppelin_big_sorted_map::big_sorted_map::{Self as bsm, BigSortedMap};
use openzeppelin_sorted_map::sorted_map;

/// One initialized tick. `liquidity_net` is the liquidity delta added to the pool's active
/// liquidity when price crosses this tick upward (real CLMMs use a signed type; a `u64`
/// keeps the example focused on the cursor). `crossed` flips the first time a swap crosses
/// it - observable proof the in-place walk reached this tick.
public struct Tick has store, copy, drop {
    liquidity_net: u64,
    crossed: bool,
}

/// A pool whose initialized ticks are a large-tier map: tick index -> `Tick`, ascending.
public struct Pool has key {
    id: UID,
    ticks: BigSortedMap<u64, Tick>,
    active_liquidity: u64,
}

// === Deployment ===

/// Create an empty pool with explicit node degrees, share it, and return its `ID`. Degrees
/// are exposed so a caller can force a low fan-out (a multi-leaf tree at few ticks). Below
/// the floor (`inner >= 4`, `leaf >= 3`) the library aborts `EInvalidDegree`.
public fun deploy_and_share(inner_max_degree: u64, leaf_max_degree: u64, ctx: &mut TxContext): ID {
    let pool = Pool {
        id: object::new(ctx),
        ticks: bsm::new_with_config(inner_max_degree, leaf_max_degree, ctx), // EInvalidDegree below floor
        active_liquidity: 0,
    };
    let id = object::id(&pool);
    transfer::share_object(pool);
    id
}

/// Initialize (or overwrite) the tick at `index` with `liquidity_net`. One macro expansion
/// in its own body. The displaced `Tick`, if any, is droppable and discarded.
public fun set_tick(pool: &mut Pool, index: u64, liquidity_net: u64) {
    let displaced = bsm::insert!(&mut pool.ticks, index, Tick { liquidity_net, crossed: false });
    let _ = displaced;
}

// === The leaf-walk cursor (the reason this module exists) ===

/// Cross every initialized tick `>= start_tick`, ascending, adding each tick's
/// `liquidity_net` to the pool's active liquidity and marking it `crossed`. Returns the new
/// active liquidity.
///
/// This is the hand-rolled cursor: `locate_leaf!` descends ONCE to seed `leaf_id`, then the
/// loop steps leaf-to-leaf via `leaf_next` and mutates each leaf's ticks through
/// `node_leaf_mut` - no per-tick re-descent. Crossing is idempotent (already-`crossed` ticks
/// are skipped). The mutable leaf borrow is confined to the inner block so the immutable
/// borrow for `leaf_next` is free of it.
public fun cross_up_from(pool: &mut Pool, start_tick: u64): u64 {
    let mut acc = pool.active_liquidity;
    let mut leaf_id = bsm::locate_leaf!(&pool.ticks, &start_tick); // ONE descent, seeds the cursor
    while (leaf_id != bsm::null_index()) {
        // --- mutate this leaf's ticks in place; no re-descent ---
        {
            let leaf = bsm::node_leaf_mut(bsm::borrow_node_mut(&mut pool.ticks, leaf_id));
            let n = sorted_map::length(leaf);
            let mut i = 0;
            while (i < n) {
                // Keys ascend, so once we pass start_tick every later key qualifies; the
                // check only ever filters the lower part of the SEED leaf.
                if (*sorted_map::key_at(leaf, i) >= start_tick) {
                    let tick = sorted_map::value_at_mut(leaf, i); // &mut VALUE only - keys untouched
                    if (!tick.crossed) {
                        tick.crossed = true;
                        acc = acc + tick.liquidity_net;
                    };
                };
                i = i + 1;
            };
        };
        // --- step to the next leaf along the chain ---
        leaf_id = bsm::leaf_next(bsm::borrow_node(&pool.ticks, leaf_id));
    };
    pool.active_liquidity = acc;
    acc
}

// === Reads ===

/// The pool's current active liquidity.
public fun active_liquidity(pool: &Pool): u64 {
    pool.active_liquidity
}

/// True iff the tick at `index` has been crossed. Aborts `EKeyNotFound` (at the library) if
/// the tick is not initialized.
public fun tick_crossed(pool: &Pool, index: u64): bool {
    let tick = bsm::borrow!(&pool.ticks, &index);
    tick.crossed
}

/// Number of initialized ticks (O(1) cached length).
public fun tick_count(pool: &Pool): u64 {
    bsm::length(&pool.ticks)
}

/// Up to `limit` initialized tick indices, ascending, from the first `>= from`. `limit` is a
/// mandatory df-cap safety bound (same as `order_book::ask_levels`). Used here to confirm the
/// leaf chain stayed correctly ordered through the in-place walk.
public fun ticks_from(pool: &Pool, from: u64, limit: u64): vector<u64> {
    bsm::keys_from!(&pool.ticks, &from, true, limit)
}

/// Test-only: the id of the leaf that holds (or would hold) `key`. Lets a scenario assert
/// structurally that two keys live in DIFFERENT leaves - i.e. that the cursor genuinely
/// crosses a leaf boundary rather than touching only the seed leaf.
#[test_only]
public fun seed_leaf_for(pool: &Pool, key: u64): u64 {
    bsm::locate_leaf!(&pool.ticks, &key)
}

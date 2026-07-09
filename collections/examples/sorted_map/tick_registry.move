/// A concentrated-liquidity tick registry - the ordered-navigation pattern.
///
/// The other modules read the map at its extremes (`head`/`tail`/`pop_front`) or by
/// exact key. A sorted map's distinctive power - the reason to pick it over a hash
/// map - is point-relative navigation: from an arbitrary key, find the nearest stored
/// key in either direction. A CLMM pool crossing price ticks is the textbook use:
///
/// - `tick_above` / `tick_below` → `next_key!` / `prev_key!` - the next active tick
///   strictly above / below the current one.
/// - `ceiling_tick` / `floor_tick` → `find_next!(.., true)` / `find_prev!(.., true)` -
///   the nearest active tick at-or-above / at-or-below an arbitrary target price that
///   need not itself be an active tick.
///
/// Ticks are plain `u64` keys, so every call uses the bare macros (no comparator).
///
/// Lifecycle: `deploy_and_share` → `add_tick` → navigate / `accrue_fees` →
/// `remove_tick`. A shared object: writers serialize per object.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `SortedMap` can be integrated. It is not production-ready and must not be deployed
/// as-is.
module openzeppelin_collections::sorted_map_tick_registry;

use openzeppelin_collections::sorted_map::{Self, SortedMap};

// === Structs ===

/// Per-tick liquidity state.
public struct TickInfo has copy, drop, store {
    /// Net liquidity added when the pool price crosses into this tick.
    liquidity_net: u64,
    /// Cumulative fee growth recorded at this tick.
    fee_growth: u128,
}

/// A pool's active ticks, embedded in a shared object.
///
/// This vector-backed map lives inline in the object, so the registry assumes a bounded tick
/// population - see the capacity notes in the package README.
public struct TickRegistry has key {
    id: UID,
    /// tick index -> liquidity state, ascending.
    ticks: SortedMap<u64, TickInfo>,
}

// === Public Functions ===

/// Create an empty registry, share it, and return its `ID`.
public fun deploy_and_share(ctx: &mut TxContext): ID {
    let reg = TickRegistry { id: object::new(ctx), ticks: sorted_map::new() };
    let id = object::id(&reg);
    transfer::share_object(reg);
    id
}

/// Activate (or overwrite) a tick. Returns true if an existing tick was replaced.
public fun add_tick(reg: &mut TickRegistry, tick: u64, liquidity_net: u64, fee_growth: u128): bool {
    let old = reg.ticks.upsert!(tick, TickInfo { liquidity_net, fee_growth });
    old.is_some()
}

/// Deactivate a tick.
public fun remove_tick(reg: &mut TickRegistry, tick: u64): TickInfo {
    let info = reg.ticks.remove!(&tick);
    info
}

/// True iff `tick` is currently active in the registry.
public fun contains_tick(reg: &TickRegistry, tick: u64): bool {
    reg.ticks.contains!(&tick)
}

/// State at an active `tick`.
///
/// #### Aborts
/// - `EKeyNotFound` if the tick is inactive - gate with `contains_tick`, or discover live
///   ticks via the navigation ops.
public fun borrow_tick(reg: &TickRegistry, tick: u64): &TickInfo {
    reg.ticks.borrow!(&tick)
}

/// Accumulate fee growth into an active tick in place.
///
/// #### Aborts
/// - `EKeyNotFound` (from `borrow_mut!`) if the tick is inactive - gate with `contains_tick`.
/// - Native `u128` overflow if `fee_growth + delta` exceeds `u128::MAX`.
public fun accrue_fees(reg: &mut TickRegistry, tick: u64, delta: u128) {
    let info = reg.ticks.borrow_mut!(&tick);
    info.fee_growth = info.fee_growth + delta;
}

/// Lowest / highest active tick (positional - no comparator).
public fun min_tick(reg: &TickRegistry): Option<u64> { reg.ticks.head() }

public fun max_tick(reg: &TickRegistry): Option<u64> { reg.ticks.tail() }

/// Next active tick strictly above / below `tick` - price crossing up / down. At the
/// ends these return `none`, the signal to stop walking.
public fun tick_above(reg: &TickRegistry, tick: u64): Option<u64> {
    reg.ticks.next_key!(&tick)
}

public fun tick_below(reg: &TickRegistry, tick: u64): Option<u64> {
    reg.ticks.prev_key!(&tick)
}

/// Nearest active tick at-or-above / at-or-below `target` (inclusive). `target` need
/// not itself be an active tick - this is exactly what a hash map cannot answer.
public fun ceiling_tick(reg: &TickRegistry, target: u64): Option<u64> {
    reg.ticks.find_next!(&target, true)
}

public fun floor_tick(reg: &TickRegistry, target: u64): Option<u64> {
    reg.ticks.find_prev!(&target, true)
}

public fun length(reg: &TickRegistry): u64 { reg.ticks.length() }

public fun is_empty(reg: &TickRegistry): bool { reg.ticks.is_empty() }

public fun liquidity_net(info: &TickInfo): u64 { info.liquidity_net }

public fun fee_growth(info: &TickInfo): u128 { info.fee_growth }

// === Test-Only Helpers ===

/// The map's test-only order check (ascending).
#[test_only]
public fun ticks_well_formed(reg: &TickRegistry): bool {
    reg.ticks.is_well_formed!()
}

#[test_only]
public fun new_tick(liquidity_net: u64, fee_growth: u128): TickInfo {
    TickInfo {
        liquidity_net,
        fee_growth,
    }
}

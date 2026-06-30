/// Scenario walkthroughs for `order_book` - the large-tier embed pattern: migrate two
/// small-tier snapshots into a shared object, post with the split merge-upsert, read/page,
/// fill, and the drain-then-`destroy_empty` teardown. Plus the two library aborts an
/// integrator most needs to understand here (both pinned to `big_sorted_map`).
module openzeppelin_big_sorted_map::order_book_tests;

use openzeppelin_big_sorted_map::order_book::{Self, OrderBook, Level};
use openzeppelin_sorted_map::sorted_map::{Self, SortedMap};
use std::unit_test::assert_eq;
use sui::test_scenario as ts;

const PUBLISHER: address = @0x0F;
const ALICE: address = @0x0A;
const BOB: address = @0x0B;

// === Snapshot builders (simulate the OLD small-tier book's two SortedMaps) ===
//
// A `SortedMap` stores entries in the order of the comparator used to build it: asks were
// kept ascending (bare `<`), bids descending (`|a,b| *a > *b`). Each insert is one macro
// expansion in its own wrapper body.

fun snap_ins(m: &mut SortedMap<u64, Level>, price: u64, size: u64) {
    sorted_map::insert!(m, price, order_book::new_level(size));
}

fun snap_ins_desc(m: &mut SortedMap<u64, Level>, price: u64, size: u64) {
    sorted_map::insert_by!(m, price, order_book::new_level(size), |a, b| *a > *b);
}

/// Correctly ascending ask snapshot: prices 100, 101, 102.
fun build_ask_snapshot(): SortedMap<u64, Level> {
    let mut m = sorted_map::new<u64, Level>();
    snap_ins(&mut m, 100, 10);
    snap_ins(&mut m, 101, 7);
    snap_ins(&mut m, 102, 5);
    m
}

/// Correctly descending bid snapshot: prices 99, 98 (stored largest-first under `>`).
fun build_bid_snapshot(): SortedMap<u64, Level> {
    let mut m = sorted_map::new<u64, Level>();
    snap_ins_desc(&mut m, 99, 4);
    snap_ins_desc(&mut m, 98, 6);
    m
}

/// A WRONG bid snapshot: built ascending, so it is NOT sorted under the `>` comparator the
/// bid bridge threads. Used by the failing case.
fun build_ascending_bid_snapshot(): SortedMap<u64, Level> {
    let mut m = sorted_map::new<u64, Level>();
    snap_ins(&mut m, 98, 6); // ascending 98, 99 - invalid for a descending book
    snap_ins(&mut m, 99, 4);
    m
}

// === Scenario 1 - migrate, post (merge), read/page, fill, drain, destroy ===
//
// Teaches the whole large-tier lifecycle and the migration: bridge two small-tier snapshots
// into a shared book (`from_sorted_map` bare + `_by`), grow it with the split merge-upsert,
// read best/L2 (paged), fill the best ask, then decommission via paged drain +
// `destroy_empty`.
#[test]
fun order_book_migration_lifecycle() {
    let mut scenario = ts::begin(PUBLISHER);

    // Tx1 - PUBLISHER: migrate the two small-tier snapshots into a shared large-tier book.
    {
        let asks = build_ask_snapshot();
        let bids = build_bid_snapshot();
        order_book::migrate_and_share(asks, bids, scenario.ctx());
    };

    // Tx2 - ALICE: post more - merge into an existing level, and add new ones.
    ts::next_tx(&mut scenario, ALICE);
    {
        let mut book = ts::take_shared<OrderBook>(&scenario);
        order_book::place_ask(&mut book, 100, 3); // 100 -> 13 (merge)
        order_book::place_ask(&mut book, 103, 2); // new
        order_book::place_bid(&mut book, 99, 2); // 99  -> 6  (merge)
        order_book::place_bid(&mut book, 97, 5); // new
        ts::return_shared(book);
    };

    // Tx3 - BOB: read best of each side, a merged size, and the L2 depth (full + paged).
    ts::next_tx(&mut scenario, BOB);
    {
        let book = ts::take_shared<OrderBook>(&scenario);
        assert_eq!(order_book::best_ask(&book), option::some(100)); // lowest ask
        assert_eq!(order_book::best_bid(&book), option::some(99)); // highest bid (descending head)
        assert_eq!(order_book::ask_size_at(&book, 100), 13); // merged, not duplicated
        assert_eq!(order_book::ask_count(&book), 4);
        // Full ascending depth, then paginate: a first page, then resume strictly after its
        // last key - the pages tile with no gap or overlap.
        assert_eq!(order_book::ask_levels(&book, 0, true, 10), vector[100, 101, 102, 103]);
        assert_eq!(order_book::ask_levels(&book, 0, true, 2), vector[100, 101]);
        assert_eq!(order_book::ask_levels(&book, 101, false, 2), vector[102, 103]);
        ts::return_shared(book);
    };

    // Tx4 - ALICE: fill (take) the best ask; the next-best becomes best.
    ts::next_tx(&mut scenario, ALICE);
    {
        let mut book = ts::take_shared<OrderBook>(&scenario);
        let (price, size) = order_book::fill_best_ask(&mut book);
        assert!(price == 100 && size == 13);
        assert_eq!(order_book::best_ask(&book), option::some(101));
        ts::return_shared(book);
    };

    // Tx5 - PUBLISHER: decommission - paged drain of both sides, then destroy the empty book.
    ts::next_tx(&mut scenario, PUBLISHER);
    {
        let mut book = ts::take_shared<OrderBook>(&scenario);
        let (ask_prices, ask_levels) = order_book::drain_asks_page(&mut book, 100); // 101,102,103
        assert_eq!(ask_prices, vector[101, 102, 103]);
        assert_eq!(ask_levels.length(), 3);
        let (bid_prices, bid_levels) = order_book::drain_bids_page(&mut book, 100); // 99,98,97 desc
        assert_eq!(bid_prices, vector[99, 98, 97]);
        assert_eq!(bid_levels.length(), 3);
        assert_eq!(order_book::ask_count(&book), 0);
        order_book::close(book); // both sides drained -> succeeds
    };

    ts::end(scenario);
}

// === Scenario 2 - closing a non-empty book aborts EMapNotEmpty, at the library ===
//
// `destroy_empty` is the orphan-safety net: a populated large-tier map cannot be dropped
// (that would orphan its dynamic-field nodes), so `close` aborts unless both sides are
// drained first. The abort originates in the library module.
#[test]
#[
    expected_failure(
        abort_code = openzeppelin_big_sorted_map::big_sorted_map::EMapNotEmpty,
        location = openzeppelin_big_sorted_map::big_sorted_map,
    ),
]
fun close_nonempty_book_aborts() {
    let mut scenario = ts::begin(PUBLISHER);

    // Tx1 - PUBLISHER: deploy an empty book.
    {
        order_book::deploy_and_share(scenario.ctx());
    };
    // Tx2 - PUBLISHER: post one ask, then try to close without draining -> EMapNotEmpty.
    ts::next_tx(&mut scenario, PUBLISHER);
    {
        let mut book = ts::take_shared<OrderBook>(&scenario);
        order_book::place_ask(&mut book, 100, 10);
        order_book::close(book); // aborts here (asks not drained)
    };
    ts::end(scenario); // unreachable; satisfies the type checker
}

// === Scenario 3 - migrating a misordered snapshot aborts ESourceNotSortedUnderComparator ===
//
// The bid bridge threads `|a,b| *a > *b` and re-validates the source against it BEFORE
// writing any node. A bid snapshot built ascending (the classic "I already have a sorted
// map, just bridge it" slip) is not sorted under `>`, so the guard fires - turning what
// would otherwise be silent tree-wide corruption into a clean, pre-write abort at the library.
#[test]
#[
    expected_failure(
        abort_code = openzeppelin_big_sorted_map::big_sorted_map::ESourceNotSortedUnderComparator,
        location = openzeppelin_big_sorted_map::big_sorted_map,
    ),
]
fun migrate_misordered_bids_aborts() {
    let mut scenario = ts::begin(PUBLISHER);

    // Tx1 - PUBLISHER: ascending asks (valid) + ascending bids (INVALID for a `>` book).
    {
        let asks = build_ask_snapshot();
        let bad_bids = build_ascending_bid_snapshot();
        order_book::migrate_and_share(asks, bad_bids, scenario.ctx()); // aborts at the bid bridge
    };
    ts::end(scenario); // unreachable; satisfies the type checker
}

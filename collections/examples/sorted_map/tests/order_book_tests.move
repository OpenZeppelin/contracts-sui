/// Scenario walkthroughs for `order_book` - the embed pattern (integer keys, bare +
/// reverse-`_by`, pagination, the EKeyNotFound abort).
module openzeppelin_collections::sorted_map_order_book_tests;

use openzeppelin_collections::sorted_map as sm;
use openzeppelin_collections::sorted_map_order_book::{Self as order_book, OrderBook};
use std::unit_test::assert_eq;
use sui::test_scenario as ts;

const ALICE: address = @0x0A;
const BOB: address = @0x0B;

// === Scenario 1 - two-sided book: post out of order, merge, read best/L2, fill ===
//
// Teaches the canonical flow: embed two maps in a shared object, post asks (ascending,
// bare) and bids (descending, `_by`), read the best of each via `head`, page the L2
// depth, and consume the best ask via `pop_front`.
#[test]
fun order_book_lifecycle() {
    let mut scenario = ts::begin(ALICE);

    // Tx1 - ALICE: deploy & share an empty book.
    {
        order_book::deploy_and_share(scenario.ctx());
    };

    // Tx2 - ALICE: post asks (out of price order) and bids.
    scenario.next_tx(ALICE);
    {
        let mut book = scenario.take_shared<OrderBook>();
        book.place_ask(102, 5);
        book.place_ask(100, 10);
        book.place_ask(101, 7);
        book.place_bid(98, 6);
        book.place_bid(99, 4);
        ts::return_shared(book);
    };

    // Tx3 - BOB: add size at existing levels - merges, never duplicates.
    scenario.next_tx(BOB);
    {
        let mut book = scenario.take_shared<OrderBook>();
        book.place_ask(100, 3); // 100 -> 13
        book.place_bid(99, 2); // 99  -> 6
        ts::return_shared(book);
    };

    // Tx4 - ALICE: read best prices, L2 depth (with resume), and the order oracle.
    scenario.next_tx(ALICE);
    {
        let book = scenario.take_shared<OrderBook>();

        assert_eq!(book.best_ask(), option::some(100)); // lowest ask
        assert_eq!(book.best_bid(), option::some(99)); // highest bid (descending head)
        assert_eq!(book.ask_size_at(100), 13); // merged, not duplicated

        // Full ascending depth.
        assert_eq!(book.ask_levels(0, true, 10), vector[100, 101, 102]);
        // Paginate: a first page, then resume strictly after its last key - pages tile.
        assert_eq!(book.ask_levels(0, true, 2), vector[100, 101]);
        assert_eq!(book.ask_levels(101, false, 2), vector[102]);

        // A consumer's test reaches the library's #[test_only] order oracle, both ways.
        assert!(book.bids_well_formed()); // encapsulated _by oracle
        assert!(book.asks_ref().is_well_formed!()); // direct bare oracle

        ts::return_shared(book);
    };

    // Tx5 - BOB: fill (take) the best ask; the next-best becomes best.
    scenario.next_tx(BOB);
    {
        let mut book = scenario.take_shared<OrderBook>();
        let (price, size) = book.fill_best_ask();
        assert_eq!(price, 100);
        assert_eq!(size, 13);
        assert_eq!(book.best_ask(), option::some(101));
        ts::return_shared(book);
    };

    scenario.end();
}

// === Scenario 3 - querying an empty level aborts EKeyNotFound, at the library ===
//
// `borrow!` aborts when the key is absent. The abort originates inside the `sorted_map`
// module, not in this consumer module - so `#[expected_failure]` must pin
// `location = openzeppelin_collections::sorted_map`.
#[test, expected_failure(abort_code = sm::EKeyNotFound, location = sm)]
fun ask_size_at_absent_aborts() {
    let mut scenario = ts::begin(ALICE);

    // Tx1 - ALICE: deploy.
    {
        order_book::deploy_and_share(scenario.ctx());
    };
    // Tx2 - ALICE: one resting ask at 100.
    scenario.next_tx(ALICE);
    {
        let mut book = scenario.take_shared<OrderBook>();
        book.place_ask(100, 10);
        ts::return_shared(book);
    };
    // Tx3 - BOB: query a price with no resting level → EKeyNotFound.
    scenario.next_tx(BOB);
    {
        let book = scenario.take_shared<OrderBook>();
        book.ask_size_at(555); // aborts here
        ts::return_shared(book); // unreachable; satisfies the type checker
    };
    scenario.end();
}

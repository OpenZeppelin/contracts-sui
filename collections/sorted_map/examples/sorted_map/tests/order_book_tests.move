/// Scenario walkthroughs for `order_book` - the embed pattern (integer keys, bare +
/// reverse-`_by`, pagination, the EKeyNotFound abort).
module openzeppelin_sorted_map::order_book_tests;

use sui::test_scenario::{Self as ts};
use openzeppelin_sorted_map::order_book::{Self, OrderBook};
use openzeppelin_sorted_map::sorted_map;

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
    ts::next_tx(&mut scenario, ALICE);
    {
        let mut book = ts::take_shared<OrderBook>(&scenario);
        order_book::place_ask(&mut book, 102, 5);
        order_book::place_ask(&mut book, 100, 10);
        order_book::place_ask(&mut book, 101, 7);
        order_book::place_bid(&mut book, 98, 6);
        order_book::place_bid(&mut book, 99, 4);
        ts::return_shared(book);
    };

    // Tx3 - BOB: add size at existing levels - merges, never duplicates.
    ts::next_tx(&mut scenario, BOB);
    {
        let mut book = ts::take_shared<OrderBook>(&scenario);
        order_book::place_ask(&mut book, 100, 3); // 100 -> 13
        order_book::place_bid(&mut book, 99, 2);  // 99  -> 6
        ts::return_shared(book);
    };

    // Tx4 - ALICE: read best prices, L2 depth (with resume), and the order oracle.
    ts::next_tx(&mut scenario, ALICE);
    {
        let book = ts::take_shared<OrderBook>(&scenario);

        assert!(order_book::best_ask(&book) == option::some(100)); // lowest ask
        assert!(order_book::best_bid(&book) == option::some(99));  // highest bid (descending head)
        assert!(order_book::ask_size_at(&book, 100) == 13);        // merged, not duplicated

        // Full ascending depth.
        assert!(order_book::ask_levels(&book, 0, true, 10) == vector[100, 101, 102]);
        // Paginate: a first page, then resume strictly after its last key - pages tile.
        assert!(order_book::ask_levels(&book, 0, true, 2) == vector[100, 101]);
        assert!(order_book::ask_levels(&book, 101, false, 2) == vector[102]);

        // A consumer's test reaches the library's #[test_only] order oracle, both ways.
        assert!(order_book::bids_well_formed(&book));                     // encapsulated _by oracle
        assert!(sorted_map::is_well_formed!(order_book::asks_ref(&book))); // direct bare oracle

        ts::return_shared(book);
    };

    // Tx5 - BOB: fill (take) the best ask; the next-best becomes best.
    ts::next_tx(&mut scenario, BOB);
    {
        let mut book = ts::take_shared<OrderBook>(&scenario);
        let (price, size) = order_book::fill_best_ask(&mut book);
        assert!(price == 100 && size == 13);
        assert!(order_book::best_ask(&book) == option::some(101));
        ts::return_shared(book);
    };

    ts::end(scenario);
}

// === Scenario 3 - querying an empty level aborts EKeyNotFound, at the library ===
//
// `borrow!` aborts when the key is absent. The abort originates inside the `sorted_map`
// module, not in this consumer module - so `#[expected_failure]` must pin
// `location = openzeppelin_sorted_map::sorted_map`.
#[test]
#[expected_failure(
    abort_code = openzeppelin_sorted_map::sorted_map::EKeyNotFound,
    location = openzeppelin_sorted_map::sorted_map,
)]
fun ask_size_at_absent_aborts() {
    let mut scenario = ts::begin(ALICE);

    // Tx1 - ALICE: deploy.
    {
        order_book::deploy_and_share(scenario.ctx());
    };
    // Tx2 - ALICE: one resting ask at 100.
    ts::next_tx(&mut scenario, ALICE);
    {
        let mut book = ts::take_shared<OrderBook>(&scenario);
        order_book::place_ask(&mut book, 100, 10);
        ts::return_shared(book);
    };
    // Tx3 - BOB: query a price with no resting level → EKeyNotFound.
    ts::next_tx(&mut scenario, BOB);
    {
        let book = ts::take_shared<OrderBook>(&scenario);
        order_book::ask_size_at(&book, 555); // aborts here
        ts::return_shared(book);             // unreachable; satisfies the type checker
    };
    ts::end(scenario);
}

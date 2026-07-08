/// A minimal two-sided DEX order book - the canonical `SortedMap` integration.
///
/// `SortedMap<K, V>` has no identity of its own (no `UID`). To get a shared, on-chain
/// book you embed one (here two) inside your own `has key` object and call the map's
/// macro API from your own functions.
///
/// # Two sides, two orders
/// - **Asks** ascend, so the best (lowest) ask sits at index 0. Ascending integer
///   keys use the plain macros (`insert!`, `borrow_mut!`, `keys_from!`).
/// - **Bids** descend, so the best (highest) bid sits at index 0. A custom order needs a
///   comparator: the strict order lives in one private fn, `outbids`, threaded as
///   `|a, b| outbids(a, b)` to every bid call.
///
/// The bid comparator lives only in this module and is passed to every bid call. It
/// must be the same on every call - the map stores no comparator, so a mix silently
/// corrupts its order. Callers never see it, so they cannot get it wrong.
///
/// `head`/`tail`/`pop_front` are positional (index 0 / n-1), so `best_bid` is just
/// `head(&bids)`: the descending order already placed the highest price first.
///
/// Lifecycle: `deploy_and_share` → `place_ask`/`place_bid` → `best_*` / `ask_levels` /
/// `ask_size_at` → `fill_best_ask`. A shared object: writers serialize per object.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `SortedMap` can be integrated. It is not production-ready and must not be deployed
/// as-is.
module openzeppelin_collections::sorted_map_order_book;

use openzeppelin_collections::sorted_map::{Self, SortedMap};

// === Structs ===

/// Aggregate resting size at one price.
public struct Level has copy, drop, store {
    /// Total resting size aggregated at this price level.
    size: u64,
}

/// A two-sided book embedding two `SortedMap`s - the only state the integrator owns.
public struct OrderBook has key {
    id: UID,
    /// price -> resting size, ascending (best ask = lowest price = head).
    asks: SortedMap<u64, Level>,
    /// price -> resting size, descending (best bid = highest price = head).
    bids: SortedMap<u64, Level>,
}

// === Public Functions ===

/// Create an empty book, share it, and return its `ID`.
public fun deploy_and_share(ctx: &mut TxContext): ID {
    let book = OrderBook {
        id: object::new(ctx),
        asks: sorted_map::new(),
        bids: sorted_map::new(),
    };
    let id = object::id(&book);
    transfer::share_object(book);
    id
}

/// Add `size` at `price` on the ask side, merging into an existing level if present.
///
/// #### Aborts
/// - Arithmetic overflow if merging `size` into an existing level exceeds `u64`.
public fun place_ask(book: &mut OrderBook, price: u64, size: u64) {
    if (book.asks.contains!(&price)) {
        let lvl = book.asks.borrow_mut!(&price);
        lvl.size = lvl.size + size;
    } else {
        book.asks.insert!(price, Level { size });
    }
}

/// Add `size` at `price` on the bid side, merging if present. Bids descend, so every
/// call threads the same `|a, b| outbids(a, b)`.
///
/// #### Aborts
/// - Arithmetic overflow if merging `size` into an existing level exceeds `u64`.
public fun place_bid(book: &mut OrderBook, price: u64, size: u64) {
    if (book.bids.contains_by!(&price, |a, b| outbids(a, b))) {
        let lvl = book.bids.borrow_mut_by!(&price, |a, b| outbids(a, b));
        lvl.size = lvl.size + size;
    } else {
        book.bids.insert_by!(price, Level { size }, |a, b| outbids(a, b));
    }
}

/// Best (lowest) ask, or `none` if the ask side is empty.
public fun best_ask(book: &OrderBook): Option<u64> {
    book.asks.head()
}

/// Best (highest) bid, or `none` if the bid side is empty. `head` reads index 0, which
/// the descending order placed the maximum price at.
public fun best_bid(book: &OrderBook): Option<u64> {
    book.bids.head()
}

/// Level-2 ask snapshot: up to `limit` ask prices, ascending, starting at the first
/// price `>= from` (when `include`) or `> from` (strict). Page a deep book by reading
/// the first page with `include = true`, then resuming from the last returned price
/// with `include = false` - the pages tile with no gap or overlap.
public fun ask_levels(book: &OrderBook, from: u64, include: bool, limit: u64): vector<u64> {
    book.asks.keys_from!(&from, include, limit)
}

/// Resting size at a specific ask `price` - gate with `contains!`, or read live prices via
/// `best_ask` / `ask_levels`.
///
/// #### Aborts
/// - `EKeyNotFound` if no level rests at `price`.
public fun ask_size_at(book: &OrderBook, price: u64): u64 {
    let lvl = book.asks.borrow!(&price);
    lvl.size
}

/// Remove and return the best (lowest) ask as `(price, size)`.
///
/// #### Aborts
/// - `EEmpty` if the ask side is empty - guard with `best_ask` first.
public fun fill_best_ask(book: &mut OrderBook): (u64, u64) {
    let (price, lvl) = book.asks.pop_front();
    let Level { size } = lvl;
    (price, size)
}

// === Private Functions ===

/// The bid comparator: strict "a outbids b" = higher price first. Defined once here and
/// threaded as `|a, b| outbids(a, b)` to every `_by` call, so the order cannot drift.
fun outbids(a: &u64, b: &u64): bool { *a > *b }

// === Test-Only Helpers ===
//
// `sorted_map` ships a test-only helper that verifies a map is correctly ordered.
// These wrappers let this package's tests call it; the bid wrapper keeps the bid
// comparator encapsulated, while `asks_ref` exposes the ask map for a direct call.

/// True iff the bid side is correctly ordered under the book's (descending) comparator.
#[test_only]
public fun bids_well_formed(book: &OrderBook): bool {
    book.bids.is_well_formed_by!(|a, b| outbids(a, b))
}

/// Read-only view of the ask map, so a test can order-check it directly.
#[test_only]
public fun asks_ref(book: &OrderBook): &SortedMap<u64, Level> {
    &book.asks
}

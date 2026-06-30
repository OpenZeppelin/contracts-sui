/// A shared two-sided DEX order book on the **large tier** - the canonical
/// `BigSortedMap` embed, and the proof that migrating a small-tier `SortedMap` book to
/// the large tier is a real (but mechanical) refactor, not a rewrite.
///
/// # Why the big tier
/// A `SortedMap` book lives in one Sui object (~250 KB / ~16k `u64` levels). A venue
/// that outgrows that needs `BigSortedMap`: a real object whose nodes are dynamic
/// fields, so it scales past the single-object ceiling. The query-side API is identical
/// to `SortedMap` - `head`, `keys_from!`, `borrow!` - so read sites port verbatim. What
/// changes is everything around the object's *identity and lifetime*; this module is
/// where those differences live, each in its own section below.
///
/// ## The book OWNS objects, not values
/// `OrderBook` embeds two `BigSortedMap`s. Each is a real object (it owns a `UID` and a
/// dynamic-field arena); a `BigSortedMap` therefore has `store` but neither `copy` nor
/// `drop`. The enclosing `OrderBook` cannot fall out of scope - it must be explicitly
/// torn down (see the teardown section).
///
/// ## Migration threads the comparator into the bridge - split per body
/// `migrate_and_share` builds a live book from two small-tier snapshots via the
/// `from_sorted_map*` bridge. Asks ascend (built-in `<`, the bare bridge); bids descend
/// (a `|a,b| *a > *b` comparator, the `_by` bridge). Each bridge RE-VALIDATES its OWN
/// source against the comparator you thread and aborts `ESourceNotSortedUnderComparator`
/// before writing any of THAT tree's nodes - so a snapshot built in the wrong order is
/// caught, not silently turned into tree-wide corruption. (Struct fields evaluate
/// left-to-right, so the asks tree is built first; a misordered `bids_snapshot` aborts
/// only after the asks object already exists this tx - the whole tx then reverts,
/// committing nothing.) Each bridge is a full comparator-descent macro, so each lives in
/// its OWN one-line wrapper fun (`build_asks` / `build_bids`): two macro expansions in one
/// body overflow Move's 256-locals ceiling.
///
/// ## The merge-upsert is SPLIT into one-expansion wrappers
/// On the small tier `place_ask` was one body: `if contains! { borrow_mut! } else
/// { insert! }`. On the big tier those three macros in one body are a compiler ICE. The
/// fix is the documented pattern: each macro gets its own wrapper fun (`asks_has` /
/// `asks_bump` / `asks_add`), and `place_ask` only *calls* them (a call is a jump, not a
/// paste - zero expansions in its body). This is the refactor every migrating integrator
/// must do, shown end to end.
///
/// ## Teardown is drain-then-`destroy_empty` (orphan safety)
/// A populated `BigSortedMap` cannot be dropped - that would orphan its dynamic-field
/// nodes. `close` unpacks the book and calls `destroy_empty`, which aborts `EMapNotEmpty`
/// unless the map is already drained. Drain first via the paged `drain_*_page`
/// (`pop_front_n`) helpers - for a genuinely large book this is a multi-transaction job,
/// because a single tx can only touch ~1000 dynamic fields.
///
/// The bid comparator `|a,b| *a > *b` is threaded to EVERY bid call and to the bid
/// bridge - the tree stores no comparator, so a mix silently corrupts its order. Callers
/// never see it.
///
/// Lifecycle: `deploy_and_share` (or `migrate_and_share`) -> `place_ask` / `place_bid` ->
/// `best_*` / `ask_levels` / `ask_size_at` -> `fill_best_ask` -> `drain_*_page` -> `close`.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `BigSortedMap` can be integrated. It is not production-ready and must not be deployed
/// as-is.
module openzeppelin_big_sorted_map::order_book;

use openzeppelin_big_sorted_map::big_sorted_map::{Self as bsm, BigSortedMap};
use openzeppelin_sorted_map::sorted_map::SortedMap;

/// Aggregate resting size at one price. `store` so it can live in a node; `copy + drop`
/// for convenience.
public struct Level has copy, drop, store {
    size: u64,
}

/// Construct a `Level` - e.g. to assemble a small-tier snapshot before bridging it in via
/// `migrate_and_share`.
public fun new_level(size: u64): Level {
    Level { size }
}

/// A two-sided book embedding two large-tier maps - the only state the integrator owns.
/// `has key` (a shared object); each `BigSortedMap` field contributes `store` but no
/// `drop`, so the book must be torn down explicitly (see `close`).
public struct OrderBook has key {
    id: UID,
    /// price -> resting size, ascending (best ask = lowest price = head).
    asks: BigSortedMap<u64, Level>,
    /// price -> resting size, descending (best bid = highest price = head).
    bids: BigSortedMap<u64, Level>,
}

// === Deployment ===

/// Create an empty book at default degrees, share it, and return its `ID`.
public fun deploy_and_share(ctx: &mut TxContext): ID {
    let book = OrderBook {
        id: object::new(ctx),
        asks: bsm::new(ctx),
        bids: bsm::new(ctx),
    };
    let id = object::id(&book);
    transfer::share_object(book);
    id
}

/// Migrate two small-tier snapshots into a shared large-tier book (the migration bridge).
/// `asks_snapshot` MUST be ascending under `<` and `bids_snapshot` MUST be descending under
/// `|a,b| *a > *b`. Each bridge re-validates its OWN source and aborts
/// `ESourceNotSortedUnderComparator` before writing any of THAT tree's nodes. The asks tree
/// is bridged first (struct fields evaluate left-to-right), so a misordered `bids_snapshot`
/// aborts only after the asks object has been built this tx - corruption is prevented by
/// whole-tx revert (nothing commits), not by nothing having executed. Returns the book's `ID`.
public fun migrate_and_share(
    asks_snapshot: SortedMap<u64, Level>,
    bids_snapshot: SortedMap<u64, Level>,
    ctx: &mut TxContext,
): ID {
    let book = OrderBook {
        id: object::new(ctx),
        asks: build_asks(asks_snapshot, ctx),
        bids: build_bids(bids_snapshot, ctx),
    };
    let id = object::id(&book);
    transfer::share_object(book);
    id
}

/// Bridge the ascending ask snapshot (bare `<`). One macro expansion, its own body.
fun build_asks(snapshot: SortedMap<u64, Level>, ctx: &mut TxContext): BigSortedMap<u64, Level> {
    bsm::from_sorted_map!(snapshot, ctx)
}

/// Bridge the descending bid snapshot, threading the same `>` comparator the bid ops use.
/// One macro expansion, its own body.
fun build_bids(snapshot: SortedMap<u64, Level>, ctx: &mut TxContext): BigSortedMap<u64, Level> {
    bsm::from_sorted_map_by!(snapshot, |a, b| *a > *b, ctx)
}

// === Posting (the split merge-upsert) ===

/// Add `size` at `price` on the ask side, merging into an existing level if present.
/// `place_ask` itself contains NO macro expansion - it only calls the three single-
/// expansion wrappers below. That is the whole point: the merge-upsert is composed from
/// jumps, never pasted into one body.
public fun place_ask(book: &mut OrderBook, price: u64, size: u64) {
    if (asks_has(book, price)) asks_bump(book, price, size) else asks_add(book, price, size);
}

/// Add `size` at `price` on the bid side, merging if present. Bids descend, so every
/// wrapper threads the same `|a,b| *a > *b`.
public fun place_bid(book: &mut OrderBook, price: u64, size: u64) {
    if (bids_has(book, price)) bids_bump(book, price, size) else bids_add(book, price, size);
}

// One comparator-macro expansion per wrapper body.
fun asks_has(book: &OrderBook, price: u64): bool {
    bsm::contains!(&book.asks, &price)
}

fun asks_bump(book: &mut OrderBook, price: u64, size: u64) {
    let lvl = bsm::borrow_mut!(&mut book.asks, &price);
    lvl.size = lvl.size + size;
}

fun asks_add(book: &mut OrderBook, price: u64, size: u64) {
    let displaced = bsm::insert!(&mut book.asks, price, Level { size });
    displaced.destroy_none(); // fresh slot -> none; asserts we did not clobber a level
}

fun bids_has(book: &OrderBook, price: u64): bool {
    bsm::contains_by!(&book.bids, &price, |a, b| *a > *b)
}

fun bids_bump(book: &mut OrderBook, price: u64, size: u64) {
    let lvl = bsm::borrow_mut_by!(&mut book.bids, &price, |a, b| *a > *b);
    lvl.size = lvl.size + size;
}

fun bids_add(book: &mut OrderBook, price: u64, size: u64) {
    let displaced = bsm::insert_by!(&mut book.bids, price, Level { size }, |a, b| *a > *b);
    displaced.destroy_none();
}

// === Reads (query-side, identical to the small-tier book) ===

/// Best (lowest) ask, or `none` if the ask side is empty. Comparator-free, O(1).
public fun best_ask(book: &OrderBook): Option<u64> {
    bsm::head(&book.asks)
}

/// Best (highest) bid, or `none`. `head` reads the first key, which the descending order
/// placed the maximum price at. Comparator-free, O(1).
public fun best_bid(book: &OrderBook): Option<u64> {
    bsm::head(&book.bids)
}

/// Level-2 ask snapshot: up to `limit` ask prices, ascending, from the first price `>= from`
/// (when `include`) or `> from` (strict). `limit` is a MANDATORY safety bound on the big
/// tier - an unbounded scan loads one df per ~half-leaf and would breach the ~1000-df cap.
/// Page a deep book: first page with `include = true`, then resume from the last returned
/// price with `include = false` - the pages tile with no gap or overlap.
public fun ask_levels(book: &OrderBook, from: u64, include: bool, limit: u64): vector<u64> {
    bsm::keys_from!(&book.asks, &from, include, limit)
}

/// Resting size at a specific ask `price`. Aborts `EKeyNotFound` (at the library) if no
/// level rests there - gate with the live reads (`best_ask` / `ask_levels`) first.
public fun ask_size_at(book: &OrderBook, price: u64): u64 {
    let lvl = bsm::borrow!(&book.asks, &price);
    lvl.size
}

/// Number of resting ask levels (O(1) cached length).
public fun ask_count(book: &OrderBook): u64 {
    bsm::length(&book.asks)
}

// === Taking ===

/// Remove and return the best (lowest) ask as `(price, size)`. Aborts `EEmpty` (at the
/// library) on an empty ask side - guard with `best_ask` first.
public fun fill_best_ask(book: &mut OrderBook): (u64, u64) {
    let (price, lvl) = bsm::pop_front(&mut book.asks);
    let Level { size } = lvl;
    (price, size)
}

// === Teardown (drain-then-destroy) ===

/// Drain up to `n` ask levels from the front, returning them as parallel `(prices, levels)`
/// vectors. The paged-drain primitive: a large book is decommissioned across several
/// transactions, `n` levels at a time, because one tx can only touch ~1000 dynamic fields.
public fun drain_asks_page(book: &mut OrderBook, n: u64): (vector<u64>, vector<Level>) {
    bsm::pop_front_n(&mut book.asks, n)
}

/// Drain up to `n` bid levels from the front (descending price order).
public fun drain_bids_page(book: &mut OrderBook, n: u64): (vector<u64>, vector<Level>) {
    bsm::pop_front_n(&mut book.bids, n)
}

/// Destroy a fully-drained book. `destroy_empty` aborts `EMapNotEmpty` (at the library) if
/// either side still holds a level - the safety net that stops you orphaning the dynamic-
/// field nodes of a non-empty tree. Drain both sides via `drain_*_page` first.
public fun close(book: OrderBook) {
    let OrderBook { id, asks, bids } = book;
    bsm::destroy_empty(asks); // EMapNotEmpty here if asks were not drained
    bsm::destroy_empty(bids);
    id.delete();
}

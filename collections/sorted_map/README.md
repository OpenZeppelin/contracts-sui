# `openzeppelin_sorted_map`

An ordered key->value map for Sui Move, backed by a single sorted vector: embed it in your own object like `sui::vec_map::VecMap` and read it in key order, with no dynamic fields.

`SortedMap<K, V>` keeps its entries sorted by key, so every read can answer *ordered* questions - smallest, largest, floor, ceiling, "the next 50 keys from here" - not just point lookups. It is the small tier of OpenZeppelin's two-tier sorted-map family: reach for it when your dataset is bounded and fits inside one object (order-book levels, a tick registry, a leaderboard, a prize vault). When a single map would outgrow Sui's object-size cap, the sibling [`openzeppelin_big_sorted_map`](../big_sorted_map) (a dynamic-field-backed B+Tree) takes over with a parallel API.

> [!WARNING]
> The map stores **no comparator**. Order is defined per call by a strict less-than `lt: |&K, &K| -> bool` you supply, and it MUST be a strict total order threaded *consistently* to every call on a given map. The library cannot detect a violation; a non-strict (`<=`) or inconsistent (`<` mixed with `>`) comparator silently corrupts order - duplicate inserts, missed removes, stranded values. See [Security Notes](#security-notes).

## Install

```toml
[dependencies]
openzeppelin_sorted_map = { r.mvr = "@openzeppelin-move/sorted_map" }
```

## Module Snapshot

| Module | Summary |
|--------|---------|
| `sorted_map` | An ordered `SortedMap<K, V>` over one sorted vector: O(log N) lookup, bare and `_by` comparator macros, and exactly one stored-object access per operation. |

---

## Sorted Map

`SortedMap<K, V>` is a UID-less value type, shaped like `sui::vec_map::VecMap`: it has no identity of its own and no dynamic fields - every entry lives inline in one vector. You embed it in a `has key` object you own and call its macro API from your own functions; authorization, events, and the ownership model are yours, the library only maintains comparator-driven key order.

| Type | Role |
|------|------|
| `SortedMap<K, V>` (value) | The ordered map. Embed it in your `has key` object; it cannot be transferred or shared on its own. |
| `Entry<K, V>` (value) | One inline key-value pair. Read-only from outside; keys are never mutable in place. |
| The embedding object | Supplies the `UID`, on-chain identity, authorization, and events. |

Abilities materialize jointly over `K` and `V`: `SortedMap<u64, u64>` is `copy + drop + store`, while `SortedMap<u64, Coin<T>>` is store-only (because `Coin` lacks `copy`/`drop`) and must be drained then `destroy_empty`'d.

### When to use it

| Use it when |
| --- |
| You need bounded ordered state inside an object you own - order books, tick registries, leaderboards, prize vaults. |
| You ask ordered questions (head/tail, floor/ceiling, next key, a sorted page), not just "is this key present?". |
| Your data fits one ~256 KB object (≈16k `u64`/`u64` entries). Past that, use `openzeppelin_big_sorted_map`. |

### Lifecycle

1. **Construct** - `new()` takes no `TxContext`; embed the result as a field on your object.
2. **Read / write** - use the bare macros (`insert!`, `borrow!`, `remove!`, ...) for integer keys; use the `_by` macros with a consistently threaded comparator for non-integer keys.
3. **Drain** - a store-only `V` (e.g. `Coin`) cannot be dropped: remove every value, then `destroy_empty`.

### Usage

A price book embeds a `SortedMap<u64, u64>` (price -> resting size) in a `has key` object. `u64` keys sort under the built-in integer `<`, so every call uses the bare macros.

```move
module my_protocol::price_book;

use openzeppelin_sorted_map::sorted_map::{Self, SortedMap};

/// A shared book embedding one ascending price->size map.
public struct PriceBook has key {
    id: UID,
    levels: SortedMap<u64, u64>, // price -> resting size, ascending (best = head)
}

public fun deploy_and_share(ctx: &mut TxContext) {
    let book = PriceBook { id: object::new(ctx), levels: sorted_map::new() };
    transfer::share_object(book);
}

/// Add `size` at `price`, merging into an existing level if present.
public fun place(book: &mut PriceBook, price: u64, size: u64) {
    if (sorted_map::contains!(&book.levels, &price)) {
        let cur = sorted_map::borrow_mut!(&mut book.levels, &price);
        *cur = *cur + size;
    } else {
        sorted_map::insert!(&mut book.levels, price, size);
    };
}

/// Best (lowest) price, or `none` if the book is empty.
public fun best_price(book: &PriceBook): Option<u64> {
    sorted_map::head(&book.levels)
}

/// Up to `limit` prices ascending from the first price `>= from`. Resume a page by
/// passing the last returned price back as `from` with `include = false`.
public fun levels_from(book: &PriceBook, from: u64, include: bool, limit: u64): vector<u64> {
    sorted_map::keys_from!(&book.levels, &from, include, limit)
}
```

For non-integer keys, or to sort descending, pass a comparator with the `_by` macros (threaded consistently): `sorted_map::insert_by!(&mut bids, price, size, |a, b| *a > *b)`.

### Examples

> [!Warning]
> These are **unaudited illustrations** of how the primitive can be integrated, not production-ready code.

Complete integration examples live in [`examples/sorted_map/`](examples/sorted_map):

- [`order_book`](examples/sorted_map/order_book.move) - the canonical embed: a `has key` book holding asks (bare integer `<`) and bids (a reverse `_by` comparator) in one module.
- [`prize_vault`](examples/sorted_map/prize_vault.move) - resource values: `Coin<SUI>` payouts (no `copy`/`drop`), drain-then-`destroy_empty`, and both library aborts.
- [`tick_registry`](examples/sorted_map/tick_registry.move) - the ordered-navigation surface (`next`/`prev`/`ceiling`/`floor`/`keys_from`), the reason to choose a sorted map over a hash map.

## Security Notes

- **Comparator footgun (the #1 hazard).** The map stores no comparator; a non-strict or inconsistent `lt` silently corrupts order, and the library cannot detect it. Keep one strict total order in a private function and thread it through every `_by` call. A reverse comparator used consistently is legitimate (it flips the order so `head` returns the largest key). In tests, call `sorted_map::is_well_formed_by!(&map, lt)` after `_by` sequences.
- **Exactly three aborts, all at the library's location.** `borrow`/`borrow_mut` -> `EKeyNotFound`; `destroy_empty` on a non-empty map -> `ENotEmpty`; `pop_front`/`pop_back` on an empty map -> `EEmpty`. Everything else is total (returns `Option`/`bool`/`vector`). Consumer `#[expected_failure]` tests must pin `location = openzeppelin_sorted_map::sorted_map`.
- **Resource-`V` conservation.** `insert`'s upsert returns the displaced value (`some(old)`) rather than dropping it; `remove`/`pop_*` move values out; `destroy_empty` refuses a non-empty map. A store-only `V` like `Coin<T>` is never silently burned.
- **Forced-public internals are not an API.** Macro hygiene forces `search!`, `insert_at`, `remove_at`, `make_entry`, `split_off`, `append` to be `public`. `insert_at`/`remove_at`/`split_off`/`append` write or move at a caller-given position with no order check - calling them directly can corrupt order. They exist only to serve the `big_sorted_map` sibling; use the macro API.
- **No events.** A UID-less value has no on-chain identity; emit events yourself at your entry functions.
- **Shared = per-object serialization.** Embedding in a shared object serializes writers per object, not per key. Shard into multiple maps or use an owned object for hot paths.
- **Capacity.** Every operation loads exactly one stored object, so the map is structurally immune to Sui's per-transaction dynamic-field-access cap; byte size is the only ceiling. On localnet (sui 1.73.1) a `SortedMap<u64, u64>` holds ≈15,997 entries before `insert` aborts at the Sui runtime with `MoveObjectTooBig`; `remove` always survives at the ceiling, so a full map is never soft-bricked (hence no `ECapacityExceeded` guard). The ceiling scales inversely with entry size.
- **Deliberate omissions.** No non-aborting `Option<&V>` borrow (Move cannot put a reference in `Option`) - use `if (contains!(..)) borrow!(..)`. No descending pagination - use a reverse comparator. No `version` field - the layout is frozen at publish, and a layout change ships as a parallel `SortedMapV2`.

## Learn More

- [Sorted map package overview](https://docs.openzeppelin.com/contracts-sui/1.x/sorted_map)
- [Sorted map API reference](https://docs.openzeppelin.com/contracts-sui/1.x/api/sorted_map)
- [`llms.txt`](https://raw.githubusercontent.com/OpenZeppelin/contracts-sui/main/llms.txt): discovery entry point for AI integrators
- [OpenZeppelin Contracts for Sui](https://docs.openzeppelin.com/contracts-sui)

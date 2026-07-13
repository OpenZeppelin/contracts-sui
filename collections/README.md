# `openzeppelin_collections`

The ordered-collections family for Sui Move: two modules for ordered key/value and set data that share one comparator model and a parallel API. Reach for the single-object `sorted_map` (an ordered `SortedMap<K, V>` over one sorted vector) for key/value data, or its set counterpart `sorted_set` for ordered membership. Both read in key order - head/tail, floor/ceiling, next key, sorted pages - not just point lookups.

> [!WARNING]
> Every module stores **no comparator**. Order is defined per call by a strict less-than `lt: |&K, &K| -> bool` you supply, and it MUST be a strict total order threaded *consistently* to every call on a given collection. The library cannot detect a violation; a non-strict (`<=`) or inconsistent (`<` mixed with `>`) comparator silently corrupts order - duplicate inserts, missed removes, wrong membership answers. The bare (non-`_by`) forms remove the footgun entirely for integer keys. See [Security Notes](#security-notes).

## Install

```toml
[dependencies]
openzeppelin_collections = { r.mvr = "@openzeppelin-move/collections" }
```

Consumers write `use openzeppelin_collections::sorted_map;` (or `::sorted_set`) and install this one package.

## Modules

| Module | Summary |
|--------|---------|
| `sorted_map` | An ordered `SortedMap<K, V>` over one sorted vector: O(log N) lookup, bare and `_by` comparator macros, and exactly one stored-object access per operation. |
| `sorted_set` | An ordered `SortedSet<K>` wrapping `SortedMap<K, Unit>`: `bool`-returning `upsert` (no abort-on-duplicate) and abort-on-absent `remove`, nearest-neighbour navigation, and a single-object footprint. |

---

## SortedMap

`SortedMap<K, V>` is a UID-less value type, shaped like `sui::vec_map::VecMap`: no identity of its own and no dynamic fields - every entry lives inline in one sorted vector. You embed it in a `has key` object you own and call its macro API from your own functions; authorization, events, and the ownership model are yours, the library only maintains comparator-driven key order.

Abilities materialize jointly over `K` and `V`: `SortedMap<u64, u64>` is `copy + drop + store`, while `SortedMap<u64, Coin<T>>` is store-only (because `Coin` lacks `copy`/`drop`) and must be drained then `destroy_empty`'d.

### When to use it

- You need bounded ordered state inside an object you own - order books, tick registries, leaderboards, prize vaults.
- You ask ordered questions (head/tail, floor/ceiling, next key, a sorted page), not just "is this key present?".
- Your data fits one ~250 KB object (≈16k `u64`/`u64` entries).

### Lifecycle

1. **Construct** - `new()` (empty), `singleton(k, v)`, or `from_sorted_keys_values!(keys, values)` (parallel vectors that must be strictly increasing under the comparator - aborts otherwise; unlike `sorted_set`'s de-duplicating `from_keys!`). None take a `TxContext`; embed the result as a field on your object.
2. **Read / write** - use the bare macros (`upsert`, `borrow!`, `remove!`, ...) for integer keys; use the `_by` macros with a consistently threaded comparator for non-integer keys.
3. **Drain** - a store-only `V` (e.g. `Coin`) cannot be dropped: remove every value, then `destroy_empty`.

### Usage

A price book embeds a `SortedMap<u64, u64>` (price -> resting size) in a `has key` object. `u64` keys sort under the built-in integer `<`, so every call uses the bare macros.

```move
module my_protocol::price_book;

use openzeppelin_collections::sorted_map::{Self, SortedMap};

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
        sorted_map::upsert!(&mut book.levels, price, size);
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

For non-integer keys, or to sort descending, pass a comparator with the `_by` macros (threaded consistently): `sorted_map::upsert_by!(&mut bids, price, size, |a, b| *a > *b)`.

Complete integration examples live in [`examples/sorted_map/`](examples/sorted_map):

- [`order_book`](examples/sorted_map/order_book.move) - the canonical embed: a `has key` book holding asks (bare integer `<`) and bids (a reverse `_by` comparator) in one module.
- [`prize_vault`](examples/sorted_map/prize_vault.move) - resource values: `Coin<SUI>` payouts (no `copy`/`drop`), drain-then-`destroy_empty`, and both drain-related library aborts (`ENotEmpty`/`EEmpty`).
- [`tick_registry`](examples/sorted_map/tick_registry.move) - the ordered-navigation surface (`next`/`prev`/`ceiling`/`floor`/`keys_from`), the reason to choose a sorted map over a hash map.

## SortedSet

`SortedSet<K>` is a thin wrapper over `SortedMap<K, Unit>`, exactly as `BTreeSet<K> = BTreeMap<K, ()>` in Rust (`Unit` is an empty marker struct; a set is a map whose values carry no information). It is a UID-less value type, shaped like `sui::vec_set::VecSet`: no identity of its own, no dynamic fields - every key lives inline in one sorted vector inside the wrapped map. Because the value is always the trivial `Unit`, a `SortedSet<K>` has **exactly the abilities `K` does**: a `copy + drop + store` key (e.g. `u64`) gives a `copy + drop + store` set, while a non-`drop` key gives a store-only set that must be drained then `destroy_empty`'d - exactly like a resource-valued `SortedMap`. There is still no resource *value* set and no value-conservation machinery (the value is always `Unit`).

### When to use it

- You need ordered membership - watchlists, allow/deny lists, price ladders, tick sets, dedup'd id registries.
- You ask "is `k` present?" *and* "what's the next key after `k`?" or "give me a sorted page".
- You want a near-drop-in for `vec_set` with ordered iteration.

### Lifecycle

1. **Construct** - `new()` / `singleton(k)` / `from_keys!(keys)` (any order, de-duplicates, never aborts) / `from_sorted_keys!(keys)` (pre-sorted input, O(N), de-duplicates; aborts `EKeysNotSorted` otherwise). Takes no `TxContext`; embed the result as a field.
2. **Membership** - `upsert` returns `bool` (`true` = newly added, never aborts); `remove!` aborts `EKeyNotFound` on an absent key; `contains!` tests presence. Bare macros for integer keys, `_by` macros with a consistent comparator otherwise.
3. **Iterate** - `head`/`tail`, `next_key!`/`prev_key!`, `find_next!`/`find_prev!`, `keys_from!` pages, `pop_front`/`pop_back`. A set with a `drop` key (the common case) just falls out of scope; a set with a non-`drop` key must be drained then `destroy_empty`'d.

### Usage

A watchlist embeds a `SortedSet<u64>` and uses the `upsert` `bool` to emit an event only the first time an id is watched.

```move
module my_app::watchlist;

use openzeppelin_collections::sorted_set::{Self, SortedSet};
use sui::event;

public struct Watchlist has key { id: UID, ids: SortedSet<u64> }

public struct Added has copy, drop { id: u64 }

public fun new(ctx: &mut TxContext): Watchlist {
    Watchlist { id: object::new(ctx), ids: sorted_set::new() }
}

/// Add a token id; emit only the FIRST time it is watched - the `bool` return earns its keep.
public fun watch(w: &mut Watchlist, id: u64) {
    if (sorted_set::upsert!(&mut w.ids, id)) {
        event::emit(Added { id });
    }
}

/// Ascending page of up to `limit` ids at or after `from`. Resume by passing the last id
/// back with `include = false`.
public fun page(w: &Watchlist, from: u64, include: bool, limit: u64): vector<u64> {
    sorted_set::keys_from!(&w.ids, &from, include, limit)
}
```

For non-integer keys, or to sort descending, use the `_by` macros with a consistently threaded comparator. To recover `vec_set`'s abort-on-duplicate, wrap the bool: `assert!(sorted_set::upsert!(&mut s, k), EAlreadyThere)`.

Complete integration examples live in [`examples/sorted_set/`](examples/sorted_set):

- [`allowlist`](examples/sorted_set/allowlist.move) - the canonical embed and the headline `vec_set` divergence: `upsert` returns `bool` (never aborts on a duplicate), a side effect gated on a real state change, `from_keys!` de-dup; `remove!` aborts on an absent key.
- [`validator_set`](examples/sorted_set/validator_set.move) - the `_by` struct-key story and the comparator footgun: a coarse (non-injective) comparator silently collapses byte-distinct keys, shown with a red test.
- [`unlock_queue`](examples/sorted_set/unlock_queue.move) - ordered drain / priority queue (head/tail peek, pop extremes) and the set's `EEmpty` abort pinned to `openzeppelin_collections::sorted_set`.

## Security Notes

The comparator footgun applies to both modules and is stated once at the top of this README. Beyond it:

### SortedMap

- **Aborts, all at the library's location.** Only these abort: `borrow`/`borrow_mut`/`remove`/`remove_by` -> `EKeyNotFound`; `add`/`add_by` on a duplicate key -> `EKeyAlreadyExists`; `destroy_empty` on a non-empty map -> `ENotEmpty`; `pop_front`/`pop_back` on an empty map -> `EEmpty`; `from_sorted_keys_values`/`_by` -> `EUnequalLengths` or `EKeysNotStrictlyIncreasing` on invalid input. Everything else is total (returns `Option`/`bool`/`vector`). Consumer `#[expected_failure]` tests must pin `location = openzeppelin_collections::sorted_map`.
- **Resource-`V` conservation.** `upsert`'s upsert returns the displaced value (`some(old)`) rather than dropping it; `remove`/`pop_*` move values out; `destroy_empty` refuses a non-empty map. A store-only `V` like `Coin<T>` is never silently burned.
- **Forced-public internals are not an API.** Macro hygiene forces several helpers - `search!`, `insert_at`, `remove_at`, `key`, and similar - to be `public`. `insert_at`/`remove_at` write at a caller-given position with no order check - calling them directly can corrupt order. They exist only to serve the macro bodies; use the macro API.
- **No events.** A UID-less value has no on-chain identity; emit events yourself at your entry functions. Embedding in a shared object serializes writers per object, not per key - shard into multiple maps or use an owned object for hot paths.
- **Capacity.** Every operation loads exactly one stored object, so the map is structurally immune to Sui's per-transaction dynamic-field-access cap; byte size is the only ceiling. Illustratively, measured on localnet (Sui 1.74.1), a `SortedMap<u64, u64>` holds 15,997 entries before `upsert` aborts at the Sui runtime with `MoveObjectTooBig` - treat this as a guide, not a guarantee (the protocol size cap is config-governed and can change). `remove` always survives at the ceiling, so a full map is never soft-bricked (hence no `ECapacityExceeded` guard). The ceiling scales inversely with entry size.
- **Deliberate omissions.** No non-aborting `Option<&V>` borrow (Move cannot put a reference in `Option`) - use `if (contains!(..)) borrow!(..)`. No `values()`/`entries()` copy-out - `V` is only `store` (it may be a non-copyable resource like `Coin`), so values cannot be copied into a `vector`; read them per key via `borrow!`, or snapshot keys with `keys()` (or page with `keys_from!`) and `borrow!` each. No descending pagination - use a reverse comparator.

### SortedSet

- **No resource value is ever lost; a coarse comparator can still drop a key.** Unlike the map (which can strand a `Coin` on misuse), the set's value is the trivial `Unit`, so there is no resource to conserve - the decisive simplification over the map. Two comparator failure modes remain, and they need different oracles. An inconsistent or non-strict comparator *desorts* the set: membership answers go wrong but every key is physically present and recoverable via `keys()`; `sorted_map::is_well_formed_by!(sorted_set::inner(&s), lt)` catches it (returns `false`). A **coarse (non-injective)** comparator is worse - it reports two byte-distinct keys as equal and `upsert` collapses them to one: the earlier key is dropped and is *not* recoverable, yet the set stays sorted so `is_well_formed_by!` still returns `true`. Detect that failure with a cardinality check (`length(&s)` vs. the expected distinct count), not the order oracle.
- **`upsert` returns `bool` and does not abort; `add`/`remove` abort.** `upsert -> true` iff newly added (diverges from `vec_set`'s abort-on-duplicate). To recover `vec_set`'s strict insert, call `add!`/`add_by!` (a duplicate aborts) or wrap the bool with one `assert!`. `remove!` aborts `EKeyNotFound` on an absent key, matching `vec_set::remove`. `from_keys!` de-duplicates.
- **Five aborts.** `pop_front`/`pop_back` on an empty set abort `EEmpty`, `from_sorted_keys!`/`_by` on unsorted input abort `EKeysNotSorted`, and `destroy_empty` on a non-empty set aborts `ENotEmpty`, all three at this module's location. Two more are DELEGATED to the wrapped map and abort at the *map's* location: `remove!` on an absent key (`sorted_map::EKeyNotFound`) and `add!`/`add_by!` on a duplicate key (`sorted_map::EKeyAlreadyExists`). Consumer `#[expected_failure]` tests must pin `location` accordingly (`openzeppelin_collections::sorted_set` for the first three, `::sorted_map` for the delegated pair). Every other operation is total.
- **Forced-public internals are not an API.** `inner`, `inner_mut`, `unit`, and `assert_sorted` are `public` only for macro hygiene. Driving the wrapped map through `inner_mut` with an inconsistent comparator can desort the set (order-only, local to that set). Use the macro API.
- **No capabilities, `Clock`, `Random`, global state, or events.** The library never checks the caller; gate your own entry functions and emit your own events.
- **Capacity.** Every operation loads exactly one stored object, so the set is structurally immune to Sui's per-transaction dynamic-field-access cap; byte size is the only ceiling. Illustratively, measured on localnet (Sui 1.74.1), the ceiling is 28,440 `u64` keys (≈1.78× the map's 15,997 `u64`/`u64` entries - each set entry is 9 bytes: an 8-byte key plus the 1-byte `Unit`); treat it as a guide, not a guarantee. Past it, `upsert` self-limits via `MoveObjectTooBig` (no capacity guard); the set is never soft-bricked.

## Learn More

- [Collections package overview](https://docs.openzeppelin.com/contracts-sui/1.x/collections)
- [Collections API reference](https://docs.openzeppelin.com/contracts-sui/1.x/api/collections)
- [`llms.txt`](https://raw.githubusercontent.com/OpenZeppelin/contracts-sui/main/llms.txt): discovery entry point for AI integrators
- [OpenZeppelin Contracts for Sui](https://docs.openzeppelin.com/contracts-sui)

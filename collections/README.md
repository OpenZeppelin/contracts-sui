# `openzeppelin_collections`

The ordered-collections family for Sui Move: three modules for ordered key/value and set data that share one comparator model and a parallel API. Reach for the single-object `sorted_map` (an ordered `SortedMap<K, V>` over one sorted vector) or its set counterpart `sorted_set` when your data fits inside one object; step up to the dynamic-field-backed `big_sorted_map` (a B+Tree) when it outgrows Sui's ~256 KB object-size cap. All three read in key order - head/tail, floor/ceiling, next key, sorted pages - not just point lookups.

> [!WARNING]
> Every module stores **no comparator**. Order is defined per call by a strict less-than `lt: |&K, &K| -> bool` you supply, and it MUST be a strict total order threaded *consistently* to every call on a given collection (and, for `big_sorted_map`, to the `from_sorted_map` bridge). The library cannot detect a violation; a non-strict (`<=`) or inconsistent (`<` mixed with `>`) comparator silently corrupts order - duplicate inserts, missed removes, wrong membership answers. The bare (non-`_by`) forms remove the footgun entirely for integer keys. It is worst for `big_sorted_map`: corruption spans the whole tree (leaf order *and* routing keys) and is **unrepairable in place**, whereas in the small tier it is confined to one object. See [Security Notes](#security-notes).

## Install

```toml
[dependencies]
openzeppelin_collections = { r.mvr = "@openzeppelin-move/collections" }
```

Consumers write `use openzeppelin_collections::sorted_map;` (or `::sorted_set` / `::big_sorted_map`) and install this one package.

## Modules

| Module | Summary |
|--------|---------|
| `sorted_map` | An ordered `SortedMap<K, V>` over one sorted vector: O(log N) lookup, bare and `_by` comparator macros, and exactly one stored-object access per operation. |
| `sorted_set` | An ordered `SortedSet<K>` wrapping `SortedMap<K, Unit>`: `bool`-returning `insert`/`remove` (no abort-on-duplicate), nearest-neighbour navigation, and a single-object footprint. |
| `big_sorted_map` | An ordered `BigSortedMap<K, V>` B+Tree over dynamic fields: `SortedMap` node payloads, a `SortedMap`-mirrored query API, a mandatory `keys_from` limit, paged teardown, and a capacity-guarded cross-tier bridge. |

---

## SortedMap

`SortedMap<K, V>` is a UID-less value type, shaped like `sui::vec_map::VecMap`: no identity of its own and no dynamic fields - every entry lives inline in one sorted vector. You embed it in a `has key` object you own and call its macro API from your own functions; authorization, events, and the ownership model are yours, the library only maintains comparator-driven key order.

Abilities materialize jointly over `K` and `V`: `SortedMap<u64, u64>` is `copy + drop + store`, while `SortedMap<u64, Coin<T>>` is store-only (because `Coin` lacks `copy`/`drop`) and must be drained then `destroy_empty`'d.

### When to use it

- You need bounded ordered state inside an object you own - order books, tick registries, leaderboards, prize vaults.
- You ask ordered questions (head/tail, floor/ceiling, next key, a sorted page), not just "is this key present?".
- Your data fits one ~256 KB object (≈16k `u64`/`u64` entries). Past that, use `big_sorted_map`.

### Lifecycle

1. **Construct** - `new()` takes no `TxContext`; embed the result as a field on your object.
2. **Read / write** - use the bare macros (`insert!`, `borrow!`, `remove!`, ...) for integer keys; use the `_by` macros with a consistently threaded comparator for non-integer keys.
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

Complete integration examples live in [`examples/sorted_map/`](examples/sorted_map):

- [`order_book`](examples/sorted_map/order_book.move) - the canonical embed: a `has key` book holding asks (bare integer `<`) and bids (a reverse `_by` comparator) in one module.
- [`prize_vault`](examples/sorted_map/prize_vault.move) - resource values: `Coin<SUI>` payouts (no `copy`/`drop`), drain-then-`destroy_empty`, and both library aborts.
- [`tick_registry`](examples/sorted_map/tick_registry.move) - the ordered-navigation surface (`next`/`prev`/`ceiling`/`floor`/`keys_from`), the reason to choose a sorted map over a hash map.

## SortedSet

`SortedSet<K>` is a thin wrapper over `SortedMap<K, Unit>`, exactly as `BTreeSet<K> = BTreeMap<K, ()>` in Rust (`Unit` is an empty marker struct; a set is a map whose values carry no information). It is a UID-less value type, shaped like `sui::vec_set::VecSet`: no identity of its own, no dynamic fields - every key lives inline in one sorted vector inside the wrapped map. Because the value is always the trivial `Unit`, a `SortedSet<K>` is **unconditionally `copy + drop + store`** - there is no resource-valued set, no value-conservation machinery, and no `destroy_empty` terminal.

### When to use it

- You need ordered membership - watchlists, allow/deny lists, price ladders, tick sets, dedup'd id registries.
- You ask "is `k` present?" *and* "what's the next key after `k`?" or "give me a sorted page".
- You want a near-drop-in for `vec_set` with ordered iteration.

### Lifecycle

1. **Construct** - `new()` / `singleton(k)` / `from_keys!(keys)` (de-duplicates, never aborts). Takes no `TxContext`; embed the result as a field.
2. **Membership** - `insert!`/`remove!` return `bool` (`true` = the set changed); `contains!` tests presence. Bare macros for integer keys, `_by` macros with a consistent comparator otherwise.
3. **Iterate** - `head`/`tail`, `next_key!`/`prev_key!`, `find_next!`/`find_prev!`, `keys_from!` pages, `pop_front`/`pop_back`. A set is always droppable, so there is no `destroy_empty`.

### Usage

A watchlist embeds a `SortedSet<u64>` and uses the `insert!` `bool` to emit an event only the first time an id is watched.

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
    if (sorted_set::insert!(&mut w.ids, id)) {
        event::emit(Added { id });
    }
}

/// Ascending page of up to `limit` ids at or after `from`. Resume by passing the last id
/// back with `include = false`.
public fun page(w: &Watchlist, from: u64, include: bool, limit: u64): vector<u64> {
    sorted_set::keys_from!(&w.ids, &from, include, limit)
}
```

For non-integer keys, or to sort descending, use the `_by` macros with a consistently threaded comparator. To recover `vec_set`'s abort-on-duplicate, wrap the bool: `assert!(sorted_set::insert!(&mut s, k), EAlreadyThere)`.

Complete integration examples live in [`examples/sorted_set/`](examples/sorted_set):

- [`allowlist`](examples/sorted_set/allowlist.move) - the canonical embed and the headline `vec_set` divergence: `insert!`/`remove!` return `bool` (never abort), side effects gated on a real state change, `from_keys!` de-dup.
- [`validator_set`](examples/sorted_set/validator_set.move) - the `_by` struct-key story and the comparator footgun: a coarse (non-injective) comparator silently collapses byte-distinct keys, shown with a red test.
- [`unlock_queue`](examples/sorted_set/unlock_queue.move) - ordered drain / priority queue (head/tail peek, pop extremes) and the set's single `EEmpty` abort pinned to `openzeppelin_collections::sorted_set`.

## BigSortedMap

`BigSortedMap<K, V>` is the large tier: a B+Tree whose every node's payload is an ordinary `SortedMap` (a leaf stores `key -> V`, an inner node stores `subtreeMax -> childId`, max-key routing). It is a real Sui object that owns a `UID` and a dynamic-field arena: the root node lives inline and every other node is a `dynamic_field` keyed by a `u64` id off the object's `UID`, so a tree scales past `SortedMap`'s ~256 KB single-object ceiling while keeping a query API 1:1 with `SortedMap`. You embed it in your own `has key` object (owned, shared, or wrapped); the dynamic-field nodes travel with the enclosing object atomically.

Because it is df-backed it is `has key, store` with `copy`/`drop` forced off, so a populated tree can never be silently dropped (which would orphan its dynamic-field children); the only terminal is `destroy_empty` after the tree is drained.

### When to use it

- Your ordered state has outgrown one ~256 KB `SortedMap` object (≈16k `u64`/`u64` entries).
- You run a CLOB order book, a global registry, a CLMM tick map, or an unbounded leaderboard.
- You can budget a one-time refactor up from `SortedMap` (it is not a drop-in rename - see [Migrating up a tier](#security-notes) below).

### Lifecycle

1. **Construct** - `new(ctx)` or `new_with_config(inner, leaf, ctx)`; it is an object, so a `&mut TxContext` is required. Embed it in your `has key` object.
2. **Read / write** - bare macros for integer keys, `_by` macros with a consistently threaded comparator otherwise. **At most one comparator macro per function body** (two overflow Move's 256-locals ceiling); compose multi-op flows from one-line wrapper functions.
3. **Page** - `keys_from!`'s `limit` is a mandatory safety bound (a long scan loads many dynamic fields); page large reads, never scan unbounded.
4. **Teardown** - drain with `pop_front`/`pop_back`/`pop_*_n` (multi-transaction for a large tree), then `destroy_empty`. There is no one-shot bulk drop, even for a droppable `V`.
5. **Migrate** - move data between tiers with `from_sorted_map[_by]!` (re-validates source order before any write) and `into_sorted_map` (drains back, capacity-guarded).

### Usage

A large-tier account registry embeds a `BigSortedMap<u64, u64>` in a shared object. The check-then-act credit flow is split across one-line wrappers, because two comparator macros in one body would hit the 256-locals ceiling.

```move
module my_protocol::registry;

use openzeppelin_collections::big_sorted_map::{Self as bsm, BigSortedMap};

public struct Registry has key {
    id: UID,
    balances: BigSortedMap<u64, u64>, // account -> balance, ascending
}

/// A BigSortedMap is an object, so `new` needs the TxContext.
public fun deploy_and_share(ctx: &mut TxContext) {
    transfer::share_object(Registry { id: object::new(ctx), balances: bsm::new(ctx) });
}

/// Add `amount`, creating the account if absent. Split across wrappers - two comparator
/// macros in one body would overflow Move's 256-locals ceiling.
public fun credit(reg: &mut Registry, account: u64, amount: u64) {
    if (has(reg, account)) bump(reg, account, amount) else set(reg, account, amount);
}
fun has(reg: &Registry, account: u64): bool { bsm::contains!(&reg.balances, &account) }
fun bump(reg: &mut Registry, account: u64, amount: u64) {
    let bal = bsm::borrow_mut!(&mut reg.balances, &account); *bal = *bal + amount;
}
fun set(reg: &mut Registry, account: u64, amount: u64) {
    bsm::insert!(&mut reg.balances, account, amount).destroy_none(); // absent branch -> always fresh
}

/// Up to `limit` accounts ascending from the first id `>= from`. `limit` is a MANDATORY
/// dynamic-field-cap safety bound - page a large registry, never scan it unbounded.
public fun accounts_from(reg: &Registry, from: u64, include: bool, limit: u64): vector<u64> {
    bsm::keys_from!(&reg.balances, &from, include, limit)
}
```

Complete integration examples live in [`examples/big_sorted_map/`](examples/big_sorted_map):

- [`order_book`](examples/big_sorted_map/order_book.move) - the large-tier embed plus the migration story: the tier-1 -> tier-2 refactor, the merge-upsert split into wrapper functions, the `from_sorted_map*` bridge with order re-validation, and paged drain-then-`destroy_empty` teardown.
- [`clmm_pool`](examples/big_sorted_map/clmm_pool.move) - the hand-rolled leaf-walk cursor (`locate_leaf!` + `borrow_node_mut` + `leaf_next`), the dynamic-field-load story, and the degree-floor `EInvalidDegree` guard.

## Security Notes

The comparator footgun applies to all three modules and is stated once at the top of this README. Beyond it:

### SortedMap

- **Four aborts, all at the library's location.** `borrow`/`borrow_mut` -> `EKeyNotFound`; `destroy_empty` on a non-empty map -> `ENotEmpty`; `pop_front`/`pop_back` on an empty map -> `EEmpty`; and the forced-public `split_off` -> `EBadSplit` on an out-of-range index (a bounds guard, not part of the supported total API). Everything else is total (returns `Option`/`bool`/`vector`). Consumer `#[expected_failure]` tests must pin `location = openzeppelin_collections::sorted_map`.
- **Resource-`V` conservation.** `insert`'s upsert returns the displaced value (`some(old)`) rather than dropping it; `remove`/`pop_*` move values out; `destroy_empty` refuses a non-empty map. A store-only `V` like `Coin<T>` is never silently burned.
- **Forced-public internals are not an API.** Macro hygiene forces `search!`, `insert_at`, `remove_at`, `make_entry`, `split_off`, `append` to be `public`. `insert_at`/`remove_at`/`split_off`/`append` write or move at a caller-given position with no order check - calling them directly can corrupt order. They exist only to serve the `big_sorted_map` module; use the macro API.
- **No events.** A UID-less value has no on-chain identity; emit events yourself at your entry functions. Embedding in a shared object serializes writers per object, not per key - shard into multiple maps or use an owned object for hot paths.
- **Capacity.** Every operation loads exactly one stored object, so the map is structurally immune to Sui's per-transaction dynamic-field-access cap; byte size is the only ceiling. On localnet (sui 1.73.1) a `SortedMap<u64, u64>` holds ≈15,997 entries before `insert` aborts at the Sui runtime with `MoveObjectTooBig`; `remove` always survives at the ceiling, so a full map is never soft-bricked (hence no `ECapacityExceeded` guard). The ceiling scales inversely with entry size.
- **Deliberate omissions.** No non-aborting `Option<&V>` borrow (Move cannot put a reference in `Option`) - use `if (contains!(..)) borrow!(..)`. No descending pagination - use a reverse comparator. No `version` field - the layout is frozen at publish, and a layout change ships as a parallel `SortedMapV2`.

### SortedSet

- **The worst case is order-only - no key is ever lost.** Unlike the map (which can strand a `Coin` on misuse), the set's value is the trivial `Unit`, so a comparator violation gives wrong membership *answers* on a desorted set, but every key is still physically present and recoverable via `keys()`. This is the decisive simplification over the map. In tests, call `sorted_map::is_well_formed_by!(sorted_set::inner_ref(&s), lt)` after `_by` sequences.
- **`insert`/`remove` return `bool` and do not abort.** `insert! -> true` iff newly added; `remove! -> true` iff was present. `from_keys!` de-duplicates. Diverges from `vec_set`; recover the abort with one `assert!`.
- **Exactly one abort.** `pop_front`/`pop_back` on an empty set abort `EEmpty` at this module's location; consumer `#[expected_failure]` tests must pin `location = openzeppelin_collections::sorted_set`. Every other operation is total.
- **Forced-public internals are not an API.** `inner_ref`, `inner_mut`, and `unit` are `public` only for macro hygiene. Driving the wrapped map through `inner_mut` with an inconsistent comparator can desort the set (order-only, local to that set). Use the macro API.
- **No capabilities, `Clock`, `Random`, global state, or events.** The library never checks the caller; gate your own entry functions and emit your own events.
- **Capacity.** Every operation loads exactly one stored object, so the set is structurally immune to Sui's per-transaction dynamic-field-access cap; byte size is the only ceiling. On localnet (sui 1.73.1) the ceiling is ≈28,440 `u64` keys (≈1.78× the map's 15,997 `u64`/`u64` entries - each set entry is 9 bytes: an 8-byte key plus the 1-byte `Unit`). Past it, `insert` self-limits via `MoveObjectTooBig` (no capacity guard); the set is never soft-bricked. For larger or unbounded workloads, use `big_sorted_map`.

### BigSortedMap

- **`EInvalidDegree` is the anti-DoS floor.** `new_with_config` asserts `leaf >= 3`, `inner >= 4` first. The half-fill floor blocks the one-entry-per-leaf scan attack that would breach the dynamic-field-load cap. The default `new` is always safe.
- **Liveness: `keys_from`'s `limit` is mandatory, not a convenience.** Unlike `SortedMap` (one object per op), a `BigSortedMap` op touches multiple nodes. A point op loads O(log N) dynamic fields (<=2 across the whole tier-1 range at the default degree), but an unbounded scan, a long mutating walk, or a teardown can load hundreds. So `keys_from!` is count-bounded by `limit`, teardown is paged via `pop_*_n`, and a mutating walk should use the DIY leaf-walk cursor (one descent), not `borrow_mut!` per key. A shared tree serializes all writers on its one object id (per-object, not per-key) - shard per domain for throughput.
- **At most one comparator macro per function body.** Two expand two full descents inline and overflow Move's 256-locals ceiling (a compiler error). Compose multi-op flows from one-line wrapper functions; the canonical check-then-act merge-upsert must be split.
- **Seven aborts, all at the library's location.** `borrow`/`borrow_mut` -> `EKeyNotFound`; `destroy_empty` on a non-empty tree -> `EMapNotEmpty`; `pop_front`/`pop_back` on an empty tree -> `EEmpty`; `new_with_config` below the floor -> `EInvalidDegree`; `into_sorted_map` over the tier-1 heuristic -> `EWouldExceedTier1EntryHeuristic`; `from_sorted_map` on an out-of-order source -> `ESourceNotSortedUnderComparator`; a wrong-kind node accessor -> `EWrongNodeKind`. Everything else is total. Consumer `#[expected_failure]` tests must pin `location = openzeppelin_collections::big_sorted_map`.
- **Resource-`V` conservation.** Nodes are non-`drop`, so a `V: drop` instantiation can never orphan a subtree. `insert`'s upsert returns the displaced value; `remove`/`pop_*` move values out; `destroy_empty` refuses a non-empty tree; the bridge moves (never copies/drops) values.
- **Forced-public internals are not an API.** Macro hygiene forces the descent macros, their positional kernels, and the read accessors to be `public`; the structural cascade and the arena/routing mutators are private. Calling the forced-public surface directly can corrupt routing/order. A small subset is published deliberately for a DIY leaf-walk cursor: `locate_leaf_by!`, `borrow_node{,_mut}`, `node_leaf{,_mut}`, `leaf_next`/`leaf_prev`, `null_index`, `root_index`.
- **Never `public_share_object` a bare tree.** A directly shared `BigSortedMap` is mutable by anyone in a PTB: `pop_front`/`pop_back` hand the popped `(K, V)` to the caller (a third party could drain a `Coin` `V`), and the forced-public kernels let an attacker corrupt routing and order. Wrap the tree in your own access-controlled `has key` object and share *that*, so only your gated functions hand out `&mut`.
- **Migrating up a tier is a real refactor, not a rename.** The query-side API is identical, but `new` takes a `TxContext`, the enclosing struct owns/transfers an object, teardown is drain-then-`destroy_empty`, `keys_from`'s `limit` becomes mandatory, and a two-comparator-macro body must be split. Bridge with `from_sorted_map_by!`, never bulk-load then read under a different comparator.
- **No events, capabilities, `Clock`/`Random`, or module state; frozen layout, no `version` field.** Gate your own entry functions and emit your own events (the tree has a stable object id). A layout change ships as a parallel `BigSortedMapV2` with consumer-driven copy-migration.
- **Capacity.** There is no fixed entry ceiling - each node is its own dynamic-field object. Measured on testnet (sui 1.73.1) at the default degrees `64/64`: a tree holding the entire tier-1 range (~16k entries) is depth 2 (point op loads <=2 dynamic fields); a single tree was built to 60,000 `u64`/`u64` entries, still depth 2; node size ≈ 1 KB at leaf degree 64, so size the degree DOWN for a fat `V` via `new_with_config`. These figures are provisional pending a localnet sweep at scale, and are enough to keep `64/64` a sound conservative default. For bounded data that fits one object, use `sorted_map`.

## Learn More

- [Collections package overview](https://docs.openzeppelin.com/contracts-sui/1.x/collections)
- [Collections API reference](https://docs.openzeppelin.com/contracts-sui/1.x/api/collections)
- [`llms.txt`](https://raw.githubusercontent.com/OpenZeppelin/contracts-sui/main/llms.txt): discovery entry point for AI integrators
- [OpenZeppelin Contracts for Sui](https://docs.openzeppelin.com/contracts-sui)

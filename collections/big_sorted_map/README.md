# `openzeppelin_big_sorted_map`

A generic, ordered key->value B+Tree for Sui Move - the large tier of the sorted-map family, for data that outgrows a single object. Non-root nodes live in dynamic fields, so a `BigSortedMap<K, V>` scales past `SortedMap`'s ~250 KB single-object ceiling while keeping a query API that is 1:1 with [`SortedMap`](../sorted_map).

Under the hood it is a B+Tree whose every node's payload is an ordinary `SortedMap` (a leaf stores `key -> V`, an inner node stores `subtreeMax -> childId`, max-key routing). The container is a real Sui object: the root node lives inline and every other node is a `dynamic_field` keyed by a `u64` id off the object's `UID`. Because it is df-backed it is `has key, store` with `copy`/`drop` forced off, so a populated tree can never be silently dropped (which would orphan its dynamic-field children); the only terminal is `destroy_empty` after the tree is drained.

> [!WARNING]
> The tree stores **no comparator**; order is defined per call by a strict less-than `lt: |&K, &K| -> bool` you supply, threaded *consistently* to every call AND to the `from_sorted_map` bridge. An inconsistent or non-strict comparator silently corrupts both leaf order and routing keys **tree-wide**, and - unlike the small tier, where corruption is confined to one object - is **unrepairable in place**. This is the worst footgun in the family. See [Security Notes](#security-notes).

## Install

```toml
[dependencies]
openzeppelin_big_sorted_map = { r.mvr = "@openzeppelin-move/big_sorted_map" }
```

The sibling `openzeppelin_sorted_map` package is pulled in transitively (a node's payload is a `SortedMap`); list it yourself only if you also build the `SortedMap` snapshot the cross-tier bridge consumes.

## Module Snapshot

| Module | Summary |
|--------|---------|
| `big_sorted_map` | An ordered `BigSortedMap<K, V>` B+Tree over dynamic fields: `SortedMap` node payloads, a `SortedMap`-mirrored query API, a mandatory `keys_from` limit, paged teardown, and a capacity-guarded cross-tier bridge. |

---

## Big Sorted Map

`BigSortedMap<K, V>` is a real Sui object that owns a `UID` and a dynamic-field arena. You embed it in your own `has key` object (owned, shared, or wrapped); the dynamic-field nodes travel with the enclosing object atomically. Authorization, events, and the ownership model are yours, the library only maintains comparator-driven key order.

| Object | Role |
|--------|------|
| `BigSortedMap<K, V>` (`has key, store`) | The tree container: an inline root plus a dynamic-field arena of nodes. `copy`/`drop` are forced off, so it must be explicitly drained and `destroy_empty`'d. |
| Each node | An ordinary `SortedMap` payload, stored as a dynamic field; never handled directly. |
| The embedding object | Supplies on-chain identity, authorization, and events. |

### When to use it

| Use it when |
| --- |
| Your ordered state has outgrown one ~250 KB `SortedMap` object (≈16k `u64`/`u64` entries). |
| You run a CLOB order book, a global registry, a CLMM tick map, or an unbounded leaderboard. |
| You can budget a one-time refactor up from `SortedMap` (it is not a drop-in rename - see below). |

### Lifecycle

1. **Construct** - `new(ctx)` or `new_with_config(leaf, inner, ctx)`; it is an object, so a `&mut TxContext` is required. Embed it in your `has key` object.
2. **Read / write** - bare macros for integer keys, `_by` macros with a consistently threaded comparator otherwise. **At most one comparator macro per function body** (two overflow Move's 256-locals ceiling); compose multi-op flows from one-line wrapper functions.
3. **Page** - `keys_from!`'s `limit` is a mandatory safety bound (a long scan loads many dynamic fields); page large reads, never scan unbounded.
4. **Teardown** - drain with `pop_front`/`pop_back`/`pop_*_n` (multi-transaction for a large tree), then `destroy_empty`. There is no one-shot bulk drop, even for a droppable `V`.
5. **Migrate** - move data between tiers with `from_sorted_map[_by]!` (re-validates source order before any write) and `into_sorted_map` (drains back, capacity-guarded).

### Usage

A large-tier account registry embeds a `BigSortedMap<u64, u64>` in a shared object. The check-then-act credit flow is split across one-line wrappers, because three comparator macros in one body would hit the 256-locals ceiling.

```move
module my_protocol::registry;

use openzeppelin_big_sorted_map::big_sorted_map::{Self as bsm, BigSortedMap};

public struct Registry has key {
    id: UID,
    balances: BigSortedMap<u64, u64>, // account -> balance, ascending
}

/// A BigSortedMap is an object, so `new` needs the TxContext.
public fun deploy_and_share(ctx: &mut TxContext) {
    transfer::share_object(Registry { id: object::new(ctx), balances: bsm::new(ctx) });
}

/// Add `amount`, creating the account if absent. Split across wrappers - three comparator
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

### Examples

> [!Warning]
> These are **unaudited illustrations** of how the primitive can be integrated, not production-ready code.

Complete integration examples live in [`examples/big_sorted_map/`](examples/big_sorted_map):

- [`order_book`](examples/big_sorted_map/order_book.move) - the large-tier embed plus the migration story: the tier-1 -> tier-2 refactor, the merge-upsert split into wrapper functions, the `from_sorted_map*` bridge with order re-validation, and paged drain-then-`destroy_empty` teardown.
- [`clmm_pool`](examples/big_sorted_map/clmm_pool.move) - the hand-rolled leaf-walk cursor (`locate_leaf!` + `borrow_node_mut` + `leaf_next`), the dynamic-field-load story, and the degree-floor `EInvalidDegree` guard.

## Security Notes

- **Comparator footgun (tree-wide, unrepairable - the #1 hazard).** A non-strict or inconsistent comparator silently corrupts leaf order and routing keys across the whole tree, and cannot be repaired in place. The library cannot detect it. Keep one strict total order in one place and thread it everywhere, including the `from_sorted_map` bridge. In tests, run a paged well-formedness check after `_by` sequences.
- **`EInvalidDegree` is the anti-DoS floor.** `new_with_config` asserts `leaf >= 3`, `inner >= 4` first. The half-fill floor blocks the one-entry-per-leaf scan attack that would breach the dynamic-field-load cap. The default `new` is always safe.
- **Liveness: `keys_from`'s `limit` is mandatory, not a convenience.** Unlike `SortedMap` (one object per op), a `BigSortedMap` op touches multiple nodes. A point op loads O(log N) dynamic fields (<=2 across the whole tier-1 range at the default degree), but an unbounded scan, a long mutating walk, or a teardown can load hundreds. So `keys_from!` is count-bounded by `limit`, teardown is paged via `pop_*_n`, and a mutating walk should use the DIY leaf-walk cursor (one descent), not `borrow_mut!` per key. A shared tree serializes all writers on its one object id (per-object, not per-key) - shard per domain for throughput.
- **At most one comparator macro per function body.** Two expand two full descents inline and overflow Move's 256-locals ceiling (a compiler error). Compose multi-op flows from one-line wrapper functions; the canonical check-then-act merge-upsert must be split.
- **Seven aborts, all at the library's location.** `borrow`/`borrow_mut` -> `EKeyNotFound`; `destroy_empty` on a non-empty tree -> `EMapNotEmpty`; `pop_front`/`pop_back` on an empty tree -> `EEmpty`; `new_with_config` below the floor -> `EInvalidDegree`; `into_sorted_map` over the tier-1 heuristic -> `EWouldExceedTier1EntryHeuristic`; `from_sorted_map` on an out-of-order source -> `ESourceNotSortedUnderComparator`; a wrong-kind node accessor -> `EWrongNodeKind`. Everything else is total. Consumer `#[expected_failure]` tests must pin `location = openzeppelin_big_sorted_map::big_sorted_map`.
- **Resource-`V` conservation.** Nodes are non-`drop`, so a `V: drop` instantiation can never orphan a subtree. `insert`'s upsert returns the displaced value; `remove`/`pop_*` move values out; `destroy_empty` refuses a non-empty tree; the bridge moves (never copies/drops) values.
- **Forced-public internals are not an API.** Macro hygiene forces the descent macros, their positional kernels, and the read accessors to be `public`; the structural cascade and the arena/routing mutators are private. Calling the forced-public surface directly can corrupt routing/order. A small subset is published deliberately for a DIY leaf-walk cursor: `locate_leaf_by!`, `borrow_node{,_mut}`, `node_leaf{,_mut}`, `leaf_next`/`leaf_prev`, `null_index`.
- **Migrating up a tier is a real refactor, not a rename.** The query-side API is identical, but `new` takes a `TxContext`, the enclosing struct owns/transfers an object, teardown is drain-then-`destroy_empty`, `keys_from`'s `limit` becomes mandatory, and a two-comparator-macro body must be split. Bridge with `from_sorted_map_by!`, never bulk-load then read under a different comparator.
- **No events, capabilities, `Clock`/`Random`, or module state; frozen layout, no `version` field.** Gate your own entry functions and emit your own events (the tree has a stable object id). A layout change ships as a parallel `BigSortedMapV2` with consumer-driven copy-migration.
- **Capacity.** There is no fixed entry ceiling - each node is its own dynamic-field object. Measured on testnet (sui 1.73.1) at the default degrees `64/64`: a tree holding the entire tier-1 range (~16k entries) is depth 2 (point op loads <=2 dynamic fields); a single tree was built to 60,000 `u64`/`u64` entries, still depth 2; node size ≈ 1 KB at leaf degree 64, so size the degree DOWN for a fat `V` via `new_with_config`. These figures are provisional pending a localnet sweep at scale, and are enough to keep `64/64` a sound conservative default. For bounded data that fits one object, use the small tier `openzeppelin_sorted_map`.

## Learn More

- [Big sorted map package overview](https://docs.openzeppelin.com/contracts-sui/1.x/big_sorted_map)
- [Big sorted map API reference](https://docs.openzeppelin.com/contracts-sui/1.x/api/big_sorted_map)
- [`llms.txt`](https://raw.githubusercontent.com/OpenZeppelin/contracts-sui/main/llms.txt): discovery entry point for AI integrators
- [OpenZeppelin Contracts for Sui](https://docs.openzeppelin.com/contracts-sui)

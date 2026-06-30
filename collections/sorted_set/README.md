# `openzeppelin_sorted_set`

A generic, ordered set of unique keys for Sui Move - the gap [`sui::vec_set`](https://docs.sui.io/references/framework/sui/vec_set) leaves. `vec_set` is unordered and hash-keyed; `SortedSet<K>` iterates in comparator order, answers range and nearest-neighbour queries, and pages results - while staying a UID-less value you embed directly in your own object.

`SortedSet<K>` is a thin wrapper over [`SortedMap<K, Unit>`](../sorted_map), exactly as `BTreeSet<K> = BTreeMap<K, ()>` in Rust (`Unit` is an empty marker struct; a set is a map whose values carry no information). It inherits the map's sorted-vector engine and comparator model, while shedding the map's hardest property: because the value is always the trivial `Unit`, a `SortedSet<K>` is **unconditionally `copy + drop + store`** - there is no resource-valued set, no value-conservation machinery, and no `destroy_empty` terminal.

> [!WARNING]
> The set stores **no comparator**. Order is defined per call by a strict less-than `lt: |&K, &K| -> bool` you supply, and it MUST be a strict total order threaded *consistently* to every call on a given set. The library cannot detect a violation; a non-strict or inconsistent comparator silently desorts the set (wrong membership answers). The worst case is order-only - no key is ever lost. See [Security Notes](#security-notes).

## Install

```toml
[dependencies]
openzeppelin_sorted_set = { r.mvr = "@openzeppelin-move/sorted_set" }
```

The sibling `openzeppelin_sorted_map` package is pulled in transitively; you do not list it yourself unless you also use the map directly.

## Module Snapshot

| Module | Summary |
|--------|---------|
| `sorted_set` | An ordered `SortedSet<K>` wrapping `SortedMap<K, Unit>`: `bool`-returning `insert`/`remove` (no abort-on-duplicate), comparator macros, nearest-neighbour navigation, and a single-object footprint. |

---

## Sorted Set

`SortedSet<K>` is a UID-less value type, shaped like `sui::vec_set::VecSet`: no identity of its own, no dynamic fields - every key lives inline in one sorted vector inside the wrapped map. You embed it in a `has key` object you own; authorization and events are yours, the library only maintains comparator-driven key order.

| Type | Role |
|------|------|
| `SortedSet<K>` (value) | The ordered set. Embed it in your `has key` object; it cannot be transferred or shared on its own. Unconditionally `copy + drop + store`. |
| `Unit` | Internal membership marker (the `()` of `map<K, ()>`). Consumers never construct or read it. |
| The embedding object | Supplies the `UID`, on-chain identity, authorization, and events. |

### When to use it

| Use it when |
| --- |
| You need ordered membership - watchlists, allow/deny lists, price ladders, tick sets, dedup'd id registries. |
| You ask "is `k` present?" *and* "what's the next key after `k`?" or "give me a sorted page". |
| You want a near-drop-in for `vec_set` with ordered iteration. |

### Lifecycle

1. **Construct** - `new()` / `singleton(k)` / `from_keys!(keys)` (de-duplicates, never aborts). Takes no `TxContext`; embed the result as a field.
2. **Membership** - `insert!`/`remove!` return `bool` (`true` = the set changed); `contains!` tests presence. Bare macros for integer keys, `_by` macros with a consistent comparator otherwise.
3. **Iterate** - `head`/`tail`, `next_key!`/`prev_key!`, `find_next!`/`find_prev!`, `keys_from!` pages, `pop_front`/`pop_back`. A set is always droppable, so there is no `destroy_empty`.

### Usage

A watchlist embeds a `SortedSet<u64>` and uses the `insert!` `bool` to emit an event only the first time an id is watched.

```move
module my_app::watchlist;

use openzeppelin_sorted_set::sorted_set::{Self, SortedSet};
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

### Examples

> [!Warning]
> These are **unaudited illustrations** of how the primitive can be integrated, not production-ready code.

Complete integration examples live in [`examples/sorted_set/`](examples/sorted_set):

- [`allowlist`](examples/sorted_set/allowlist.move) - the canonical embed and the headline `vec_set` divergence: `insert!`/`remove!` return `bool` (never abort), side effects gated on a real state change, `from_keys!` de-dup.
- [`validator_set`](examples/sorted_set/validator_set.move) - the `_by` struct-key story and the comparator footgun: a coarse (non-injective) comparator silently collapses byte-distinct keys, shown with a red test.
- [`unlock_queue`](examples/sorted_set/unlock_queue.move) - ordered drain / priority queue (head/tail peek, pop extremes) and the set's single `EEmpty` abort pinned to `openzeppelin_sorted_set::sorted_set`.

## Security Notes

- **Comparator footgun (the #1 hazard).** A non-strict (`<=`) or inconsistent (`<` then `>`) comparator silently desorts the set - the same hazard Rust's `BTreeSet` carries with a custom `Ord`. The library cannot detect it. Thread one strict total order everywhere; the bare forms remove the footgun entirely for integer keys. In tests, call `sorted_map::is_well_formed_by!(sorted_set::inner_ref(&s), lt)` after `_by` sequences.
- **The worst case is order-only - no key is ever lost.** Unlike the map (which can strand a `Coin` on misuse), the set's value is the trivial `Unit`, so a comparator violation gives wrong membership *answers* on a desorted set, but every key is still physically present and recoverable via `keys()`. This is the decisive simplification over the map.
- **`insert`/`remove` return `bool` and do not abort.** `insert! -> true` iff newly added; `remove! -> true` iff was present. `from_keys!` de-duplicates. Diverges from `vec_set`; recover the abort with one `assert!`.
- **Exactly one abort.** `pop_front`/`pop_back` on an empty set abort `EEmpty` at this package's location; consumer `#[expected_failure]` tests must pin `location = openzeppelin_sorted_set::sorted_set`. Every other operation is total.
- **Forced-public internals are not an API.** `inner_ref`, `inner_mut`, and `unit` are `public` only for macro hygiene. Driving the wrapped map through `inner_mut` with an inconsistent comparator can desort the set (order-only, local to that set). Use the macro API.
- **No capabilities, `Clock`, `Random`, global state, or events.** The library never checks the caller; gate your own entry functions and emit your own events.
- **Capacity.** Every operation loads exactly one stored object, so the set is structurally immune to Sui's per-transaction dynamic-field-access cap; byte size is the only ceiling. On localnet (sui 1.73.1) the ceiling is ≈28,440 `u64` keys (≈1.78× the map's 15,997 `u64`/`u64` entries - each set entry is 9 bytes: an 8-byte key plus the 1-byte `Unit`). Past it, `insert` self-limits via `MoveObjectTooBig` (no capacity guard); the set is never soft-bricked. For larger or unbounded workloads, use `openzeppelin_big_sorted_map`.

## Learn More

- [Sorted set package overview](https://docs.openzeppelin.com/contracts-sui/1.x/sorted_set)
- [Sorted set API reference](https://docs.openzeppelin.com/contracts-sui/1.x/api/sorted_set)
- [`llms.txt`](https://raw.githubusercontent.com/OpenZeppelin/contracts-sui/main/llms.txt): discovery entry point for AI integrators
- [OpenZeppelin Contracts for Sui](https://docs.openzeppelin.com/contracts-sui)

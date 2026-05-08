---
stage: research
project: sorted-map
mode: greenfield
extends: null
status: draft
timestamp: 2026-05-08
author: nenad
previous_stage: null
tags: [data-structures, collections, generic, ordered-iteration, b+tree, sorted-vector]
---

# Sorted Map — Research Report

## Summary
A generic, key-and-value-parametric sorted map is **viable and currently absent from Sui**. Sui's `sui::vec_map` explicitly defers sorted iteration ("should be handwritten"), `sui::table` / `linked_table` provide no key ordering, and no third-party generic sorted map exists in the ecosystem. Aptos ships exactly this primitive (`OrderedMap` + `BigOrderedMap`), and it is heavily used. The recommendation is **build it**, mirroring Aptos's two-tier shape (in-struct sorted-vector + dynamic-field-backed B+-tree), but with Sui's missing `std::cmp` worked around via Move 2024 macro-functions that take a `|&K, &K| -> u8` lambda as the comparator. The single hardest design call is the comparator strategy — every other decision flows from it.

## Existing Sui Implementations

### `sui::vec_map` — unsorted, vector-backed
- Source: [`vec_map.move`](https://github.com/MystenLabs/sui/blob/main/crates/sui-framework/packages/sui-framework/sources/vec_map.move), docs: [Module sui::vec_map](https://docs.sui.io/references/framework/sui-framework/vec_map).
- Generic over `K: copy + drop` and `V`. Backed by `vector<Entry<K, V>>` in **insertion order**. All ops are O(N).
- Documentation explicitly states: *"Maps that need sorted iteration rather than insertion order iteration should be handwritten."* — i.e. official acknowledgement of the gap this project fills.
- **Limitation:** No ordered iteration, no `lower_bound` / `upper_bound`, no range scans, no min/max in O(log n).

### `sui::table`, `sui::object_table` — hash-style, unordered
- Backed by dynamic fields under a parent object id. O(1) get/insert/remove per key.
- Iteration over keys is **not supported on-chain at all**; off-chain indexers walk dynamic fields.
- **Limitation:** No ordering, no enumeration; not even a candidate for sorted use.

### `sui::linked_table` — insertion-order only
- Source: [`linked_table.move`](https://github.com/MystenLabs/sui/blob/main/crates/sui-framework/packages/sui-framework/sources/linked_table.move).
- Doubly-linked list overlaid on a dynamic-field-backed table. Supports `push_front`, `push_back`, `front`, `back`, ordered traversal.
- **Order is by insertion, not by key.** Cannot answer "smallest key ≥ x" without a full scan.

### `sui::vec_set` — unsorted set (tracked for completeness)
- Same shape as `vec_map` minus values. Same limitations.

### DeepBook v2 — domain-specific crit-bit tree (not reusable)
- Source: [`deepbook` package in sui-framework](https://github.com/MystenLabs/sui/tree/main/crates/sui-framework/packages/deepbook), v3 at [MystenLabs/deepbookv3](https://github.com/MystenLabs/deepbookv3).
- Uses a two-level nested **crit-bit tree** for tick-price ordering of bids/asks.
- Crit-bit is a digital tree over fixed-width unsigned integer keys (price ticks). Coupled to the order-book domain — keys are `u64`, values are order ids; not generic.
- **Takeaway:** Confirms ordered-key data structures are first-class infrastructure for serious Sui DeFi, but the crit-bit module is not exposed as a reusable library and the tree is specialized.

### Cetus / Bluefin — domain-specific tick maps
- Cetus's CLMM uses a tick module ([`tick.move` in cetus-clmm](https://github.com/CetusProtocol/cetus-contracts/tree/main/packages/cetus_clmm)) with Uniswap-V3-style tick bitmaps + linked-list-of-initialized-ticks; specialized to `i32` ticks and liquidity values.
- Bluefin's on-chain settlement layer pairs with an off-chain order book ([orderbook design](https://learn.bluefin.io/bluefin/bluefin-exchange/trading/orderbook-design)) — they explicitly avoid maintaining a sorted on-chain order tree at scale. This is a useful negative data point: when the dataset is huge, teams move the sort off-chain. Our target use cases must therefore handle bounded-but-meaningful sizes well (≤ low thousands of entries on-chain), not unbounded.

### Third-party Sui sorted maps
- **None found.** The Awesome-Sui list ([sui-foundation/awesome-sui](https://github.com/sui-foundation/awesome-sui)) and broad GitHub queries return no generic sorted-map / ordered-tree library for Sui Move. There is genuine green field here.

## Cross-Ecosystem Implementations

### Aptos Move — the closest analog, two-tier design

Aptos ships a generic ordered-map family in `aptos-framework`. The two-tier split is the most useful reference for our design.

**`OrderedMap<K, V>`** — in-resource, sorted-vector backed
- Source: [`ordered_map.move`](https://github.com/aptos-labs/aptos-core/blob/main/aptos-move/framework/aptos-framework/sources/datastructures/ordered_map.move).
- Shape:
  ```move
  enum OrderedMap<K, V> has drop, copy, store {
      SortedVectorMap { entries: vector<Entry<K, V>> }
  }
  struct Entry<K, V> has drop, copy, store { key: K, value: V }
  ```
- Comparison via Aptos's built-in `std::cmp::compare(&K, &K) -> Ordering` — works on **any Move value generically** (primitives natively, structs lexicographically). No comparator function passed in; comparison is intrinsic to the language's stdlib.
- O(log n) lookup (binary search), O(n) insert/remove (vector shift).
- Single resource — fits inside another struct, sized to the parent.
- Replaced the deprecated `SimpleMap`.

**`BigOrderedMap<K, V>`** — B+-tree, dynamic-field-backed
- Source: [`big_ordered_map.move`](https://github.com/aptos-labs/aptos-core/blob/main/aptos-move/framework/aptos-framework/sources/datastructures/big_ordered_map.move).
- B+-tree spread across multiple storage items, with `inner_max_degree` / `leaf_max_degree` knobs.
- Chosen because *"the majority of cost comes from loading and writing to storage items, and there is no partial read/write of them"* — same property holds on Sui (dynamic fields are loaded as whole objects).
- Replaced the deprecated `SmartTable`.
- `to_ordered_map()` materialization helper, but flagged as expensive for large maps.

**Aptos lessons:**
1. The two-tier split (in-struct vs storage-spanning) is intentional and right — different cost regimes.
2. B+-tree was preferred over RB-tree / skiplist precisely because of the load-whole-node cost model that Sui's dynamic fields share.
3. Generic comparison only works because of `std::cmp::compare`. Sui has no equivalent — see Gap Analysis.
4. The interior implementation is a "tagged enum" struct (`SortedVectorMap` variant) so future representation changes don't break the public type.

### Solidity / EVM — ordered-key support is third-party, never standardized

- **OpenZeppelin Contracts** has `EnumerableMap` and `EnumerableSet`, but documentation is explicit: *"no guarantees are made on the ordering"*. Iteration is a side-effect of an internal index array, not a sort. Source: [`EnumerableMap.sol`](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/structs/EnumerableMap.sol). **No sorted variant exists in OZ Solidity.** This is informative for OZ Sui's positioning — there is appetite, OZ Solidity just never built it because Solidity has no good shape for it.
- **Solady's `RedBlackTreeLib`** ([source](https://github.com/vectorized/solady/blob/main/src/utils/RedBlackTreeLib.sol)) — gas-optimised RB-tree, but values are `uint256` only (no `value`-side, it's a sorted set), and it forbids zero. Modeled on BokkyPooBah's library.
- **`BokkyPooBahsRedBlackTreeLibrary`** ([source](https://github.com/bokkypoobah/BokkyPooBahsRedBlackTreeLibrary)) — the canonical Solidity RB-tree. ~68k–127k gas per insert depending on size. `uint256` keys, values are external (the tree is just an index).
- **`solidity-treemap`** ([source](https://github.com/saurfang/solidity-treemap)) — RB-tree-backed navigable sorted treemap; experimental, low adoption.
- **Hitchens `OrderStatisticsTree`** — adds rank/select on top of an RB-tree; same key/value-uint256 shape.
- **Uniswap V3 tick bitmap** — domain-specific ordered structure, not a general library.

**Solidity lessons:**
1. Every Solidity sorted-map library uses `uint256` keys and stores values out-of-band. There is no Solidity equivalent of a generic-K, generic-V sorted map. We have a stronger primitive on Move (real generics) and should use it.
2. Choice of tree: RB-tree dominates Solidity because per-storage-slot cost is uniform. On Sui (and Aptos), B+-tree wins because the cost unit is "load this dynamic field," and B+-trees pack more data per loaded node.
3. Sorted *set* is the more common ask than sorted *map* in DeFi. We should make sure the sorted-map design degrades cleanly to a set (V = `()` or a thin `sorted_set` wrapper).

### Other ecosystems (brief)

- **Solana / Rust** — Account model means each map node would be its own account; in practice protocols use `BTreeMap` from Rust std inside a single account or store a sort key in an off-chain index. Not directly comparable.
- **CosmWasm** — `cw-storage-plus::Map` is unordered; ordered iteration relies on the underlying storage's lexicographic key prefix. Not a generic sorted-map library.

## Ecosystem Needs

Concrete on-chain workloads in the Sui ecosystem that need ordered-by-key access and currently each rebuild it:

| Use case | Today | A sorted-map would give them |
|---|---|---|
| On-chain order books (DeepBook v3, future challengers) | Custom crit-bit tree | Reusable B+-tree for tick→order-list |
| CLMM tick maps (Cetus, Turbos, Bluefin spot) | Bitmap + custom linked list | Generic ordered tick→liquidity map |
| Time-bucketed reward / vesting schedules | `vec_map<u64, ...>` + linear scan | O(log n) "next cliff", "release everything ≤ now" |
| Auctions / leaderboards (top-N by bid or score) | `vector<...>` + sort on read | Native `lower_bound`, `last` |
| Governance proposal queues by execution-eligible time | Manual heap-in-vector | Min-key removal in O(log n) |
| Lending / health-factor priority queues for liquidation eligibility | Off-chain bots only | On-chain liquidation queue |
| Time-weighted average price (TWAP) ring with arbitrary timestamps | `linked_table` (insertion order ≠ time order if backfilled) | Sorted by timestamp |
| Generic LRU / TTL caches on-chain | Hand-rolled per project | `pop_first` semantics |

The pattern is consistent: every team that needs ordered-key access today either rolls their own (the DeFi protocols) or punts the ordering off-chain (Bluefin). A vetted, audited OZ-quality sorted-map fills a real and currently-private hole.

A second signal: Aptos shipped exactly this primitive *into the framework*, deprecated `SimpleMap` and `SmartTable` in favor of the ordered variants, and Aptos teams adopted them. The Move ecosystem has voted with adoption that this is a needed piece. Sui has not done this. OZ Sui is well-positioned to standardize.

## Gap Analysis

### What's missing on Sui
1. **Any** generic sorted map — neither in `sui-framework` nor in any third-party library found.
2. The single language primitive that makes Aptos's design simple — `std::cmp::compare(&T, &T)` — **does not exist on Sui** (verified against the full module list of `sui_std`/`move-stdlib`: `address, ascii, bcs, bit_vector, bool, debug, fixed_point32, hash, internal, macros, option, string, type_name, u8/u16/u32/u64/u128/u256, uq32_32, uq64_64, vector` — no `cmp`).
3. No standard sorted *set* either; `vec_set` and `Bag` keys give no order.
4. No standard priority-queue / heap. (Out of scope for this project, but adjacent — and a sorted map subsumes it.)

### What this implies for the design
- A generic sorted map on Sui must supply its own comparison mechanism. The realistic options:

  | Strategy | Pros | Cons |
  |---|---|---|
  | **A. Macro-functions taking `|&K, &K| -> u8` lambda** (Move 2024) | Truly generic K. Zero runtime overhead. Idiomatic Move 2024. Comparator inlined. | Comparator is supplied at every call site — risk of inconsistency between insert and lookup. Can't put the macro in a vtable. |
  | B. Comparator-witness struct + module method | Bind comparator to map at construction. Type-safe consistency. | Verbose. Each comparator needs its own module. Awkward for generic V. |
  | C. Per-key-type modules (`sorted_map_u64`, `sorted_map_address`, …) | Simple, fast, no macro complexity. | Combinatorial explosion. Loses generic-K. |
  | D. BCS-bytewise comparator as a default | One implementation handles any K with `store`. | **BCS uses little-endian for ints — bytewise compare ≠ numeric compare for `u64`.** Only correct for `vector<u8>`, ASCII, and fixed-width big-endian custom encodings. Treacherous if blind-applied. |

  Recommended primary strategy: **A with B as a safety wrapper.** Expose a low-level `sorted_map` whose ops are macros taking a comparator lambda; layer a small set of pre-bound modules (`sorted_map_u64`, `sorted_map_u128`, `sorted_map_address`, `sorted_map_ascii_string`) on top that pass the canonical comparator. End users who want a custom comparator use the macros directly; users who want a stable, type-bound contract use the pre-bound modules. This mirrors how the Sui stdlib uses macros (`vector::do!`, `option::map!`) while still shipping ergonomic typed wrappers.

- A two-tier shape, like Aptos's, is the right answer for Sui too. Sui dynamic fields are loaded whole, so B+-tree's "pack many entries per node" property carries over.

  - **Tier 1: `sorted_map<K, V>`** — single Move struct, sorted `vector<Entry<K, V>>`. For maps that fit comfortably in a parent object (target: ≤ a few hundred entries — the bound is set by per-tx Move computation gas + parent-object size). Cheap, embeddable.
  - **Tier 2: `big_sorted_map<K, V>`** — B+-tree across dynamic fields, configurable degrees. For unbounded growth.

### What could go wrong (design traps to flag for Stage 2)
- **Comparator inconsistency.** A user that calls `insert!` with one comparator and `get!` with another corrupts the structure silently. Mitigation: store a "comparator id" (e.g. a phantom marker type) inside the map and assert it on every operation, or only expose macro APIs with a single canonical comparator argument and document loudly. Stage 2 needs to land on one of these.
- **BCS encoding gotchas.** Move BCS encodes `u64` as little-endian bytes — a bytewise lex compare yields 256 < 1 < 2. Any "default" comparator must not naively use `bcs::to_bytes` for numerics. The pre-bound modules must convert to big-endian (or just use the native `<` operator).
- **Ability constraints.** For Tier 1, K and V must be `store + drop`; K additionally `copy` for typical lookup ergonomics. For Tier 2, K must additionally be hashable as a dynamic-field key, which on Sui means `copy + drop + store`. This is the same constraint set as `sui::table`.
- **Iteration during mutation.** Sui has no native iterator types; iteration is a `while` loop over indices. Stage 2 must decide whether to expose `keys() -> vector<K>` (allocation, but safe) or only macro-level visitation (`do!`, `do_ref!`).
- **Determinism of structural reorganization.** B+-tree node-splitting must be deterministic and not depend on object IDs that vary across replays.
- **Storage-rebate accounting.** Tier 2 deletions free dynamic fields and earn rebates (~99% of the original storage fee). Insertion-heavy workloads pay storage upfront; the API should not surprise the caller.
- **Object-vs-value confusion ("shared package" wording).** A sorted map is a *value type* that lives inside another object (or as the only field of an object the user wraps and shares). It is not itself an object with `key`. Stage 2 should explicitly settle this and document a recommended "make my map a shared object" wrapper pattern.

## Recommendation

- **Verdict:** **Build it.**
- **Recommended approach:** Mirror Aptos's two-tier design — a Tier 1 in-struct sorted-vector map for small/medium sizes and a Tier 2 B+-tree-on-dynamic-fields for large sizes — but adapt to Sui's lack of `std::cmp` by making the comparison a Move 2024 macro-function lambda `|&K, &K| -> u8`. Provide a thin layer of typed wrappers (`sorted_map_u64`, `sorted_map_address`, …) for the common cases. Position the package alongside the existing `openzeppelin_math` / `openzeppelin_fp_math` packages as the OZ Sui collections primitive — same shape, same quality bar.

- **Key design considerations (for Stage 2):**
  1. **Comparator strategy.** Pick decisively between (A) macro-only with a per-call comparator, (B) macro + stored comparator-marker for runtime invariant checks, or (C) generated typed wrappers for a fixed set of primitive keys. Recommendation: A + a thin wrapper layer for primitives; defer (B) unless audit feedback forces it.
  2. **Two-tier API surface.** Define `sorted_map<K, V>` and `big_sorted_map<K, V>` with identical conceptual operations: `new`, `insert`, `remove`, `contains`, `borrow`, `borrow_mut`, `lower_bound`, `upper_bound`, `min`, `max`, `pop_min`, `pop_max`, `length`, `is_empty`, `keys`, `do!` / `do_mut!` (macro iteration). Diverge only where the storage shape forces it.
  3. **B+-tree node sizing.** Set sane defaults for `inner_max_degree` and `leaf_max_degree`; allow override at construction. Document the cost model: each node = one dynamic field load.
  4. **Set/heap derivability.** Ensure the design supports a trivial `sorted_set<K>` derivation (V = `()`-like marker) and is at least usable as a min-heap via `pop_min`.
  5. **Deterministic comparator integrity.** Decide and document the contract: comparators must be a total order; reusing a different comparator on the same map is undefined behavior; Stage 3 (Invariants) should include this.

- **Risks:**
  - Comparator-inconsistency footgun (mitigated by API design, never fully removable without runtime overhead).
  - The lambda-comparator macro form is Move-2024-only; older callers can't use it. Acceptable since OZ Sui already requires recent toolchain (`sui` 1.71.1, Move edition 2024).
  - B+-tree implementation complexity. There is no battle-tested Sui-Move B+-tree to fork; implementing splits/merges/rebalances correctly is the bulk of the work and the riskiest invariant surface. This is by far the largest engineering and audit cost; Stage 2 should plan for it.
  - Adoption uncertainty. Even with a real gap, OZ-blessed libraries on Sui take time to displace bespoke per-protocol implementations. Mitigation: ship Tier 1 first as a small, easy win, then Tier 2.

## Out of Scope

- **Priority queue / heap as a separate primitive** — a sorted map subsumes it; if a dedicated `priority_queue` is wanted, file separately.
- **Sorted set as a co-shipped sibling** — derivable from the map; whether to ship a dedicated wrapper is a Stage 2 API call.
- **Off-chain index integration** — out of scope; this is an on-chain library.
- **Concurrent / parallel-mutation semantics** — Sui's transaction-isolation model handles this at a higher layer; the data structure is single-writer per transaction.
- **Order-statistic queries (rank/select)** — useful but secondary; flag for Stage 2 to consider as an extension if cheap.
- **MoveVM-level changes** (e.g. lobbying for a `std::cmp` upstream) — not a deliverable here, but worth raising with Mysten separately.
- **Cross-chain / bridged keys** — same as above.

## Dev Notes

(For dev to fill in.)

## Open Questions

1. **Scope of Tier 2 in v1?** Ship Tier 1 alone first and add Tier 2 in a follow-up, or co-design and ship both? The Tier 2 B+-tree is the harder, riskier piece. Recommendation: design both in Stage 2 but consider phased delivery.
2. **Comparator strategy commitment.** Reconfirm A + typed-wrappers in Stage 2, or do the cost-benefit on the witness-struct approach (B) with Stage 2's API draft in hand.
3. **Which typed wrappers ship in v1?** Minimum likely: `u64`, `u128`, `address`. Open: `u256`, `ascii::String`, `vector<u8>` (lex order), `TypeName`. Decide in Stage 2.
4. **Naming.** `sorted_map` vs `ordered_map` vs `tree_map`. Aptos chose `ordered_map`; Sui's stdlib uses `vec_map`; OZ Solidity uses `EnumerableMap`. The OZ Sui collection should pick a naming convention consistent with whatever pattern is already established in this repo's other packages (`openzeppelin_math`, `openzeppelin_fp_math`).
5. **Repo placement.** Should this live under `contracts/`, under a new `collections/` top-level directory, or alongside `math/`? The OZ Sui repo currently has `contracts/access`, `math/core`, `math/fixed_point` — a `collections/sorted_map` mirrors this layout cleanly. Decide before Stage 4.
6. **Should there be a runtime assert on comparator consistency?** Cheapest version: store a `vector<u8>` "comparator id" tag the user supplies once; assert equality on every macro invocation. Adds one byte-vector compare per op. Worth the cost? — Stage 2 / Stage 3.

## Sources

- [Module sui::vec_map (Sui docs)](https://docs.sui.io/references/framework/sui-framework/vec_map)
- [`vec_map.move` (sui-framework)](https://github.com/MystenLabs/sui/blob/main/crates/sui-framework/packages/sui-framework/sources/vec_map.move)
- [`linked_table.move` (sui-framework)](https://github.com/MystenLabs/sui/blob/main/crates/sui-framework/packages/sui-framework/sources/linked_table.move)
- [`object_table.move` (sui-framework)](https://github.com/MystenLabs/sui/blob/main/crates/sui-framework/packages/sui-framework/sources/object_table.move)
- [Sui Standard Library module index (`sui_std`)](https://docs.sui.io/references/framework/sui_std/) — verified absence of `cmp`
- [`ordered_map.move` (Aptos framework)](https://github.com/aptos-labs/aptos-core/blob/main/aptos-move/framework/aptos-framework/sources/datastructures/ordered_map.move)
- [`big_ordered_map.move` (Aptos framework)](https://github.com/aptos-labs/aptos-core/blob/main/aptos-move/framework/aptos-framework/sources/datastructures/big_ordered_map.move)
- [Aptos `big_ordered_map` reference docs](https://aptos.dev/move-reference/devnet/aptos-framework/big_ordered_map)
- [Introducing New Utilities and Collections in Aptos Framework (Aptos Labs)](https://medium.com/aptoslabs/introducing-new-utilities-and-collections-in-aptos-framework-4346d39b6e8e)
- [Move 2024: Macro Functions Guide (Sui blog)](https://blog.sui.io/move-2024-macros-beta/)
- [Macro Functions reference (The Move Book)](https://move-book.com/reference/functions/macros/)
- [DeepBook v3 source (MystenLabs/deepbookv3)](https://github.com/MystenLabs/deepbookv3)
- [DeepBookV3 docs (Sui)](https://docs.sui.io/standards/deepbook)
- [Cetus CLMM contracts (`cetus_clmm` package)](https://github.com/CetusProtocol/cetus-contracts/tree/main/packages/cetus_clmm)
- [Bluefin orderbook design](https://learn.bluefin.io/bluefin/bluefin-exchange/trading/orderbook-design)
- [`EnumerableMap.sol` (OpenZeppelin Solidity)](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/structs/EnumerableMap.sol)
- [Solady `RedBlackTreeLib.sol`](https://github.com/vectorized/solady/blob/main/src/utils/RedBlackTreeLib.sol)
- [BokkyPooBahsRedBlackTreeLibrary](https://github.com/bokkypoobah/BokkyPooBahsRedBlackTreeLibrary)
- [`solidity-treemap` (saurfang)](https://github.com/saurfang/solidity-treemap)
- [Sui storage costs (docs)](https://docs.sui.io/concepts/sui-architecture/sui-storage)
- [Awesome Sui (sui-foundation)](https://github.com/sui-foundation/awesome-sui)

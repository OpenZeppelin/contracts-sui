# Collections

Ordered-collection primitives for Sui smart contract development.

**AI agents:** [`llms.txt`](https://raw.githubusercontent.com/OpenZeppelin/contracts-sui/main/llms.txt) is the discovery entry point for integrating this library into a downstream project.

---

## Packages

| Package | MVR | Move package | Docs | Highlights |
|---------|----------|--------------|------|-----------|
| [`sorted_map/`](sorted_map/) | [`@openzeppelin-move/sorted_map`](https://www.moveregistry.com/package/@openzeppelin-move/sorted_map) | `openzeppelin_sorted_map` | [docs](https://docs.openzeppelin.com/contracts-sui/1.x/sorted_map) | An ordered key-value map (`SortedMap<K, V>`) backed by a single sorted vector: embed it in your own object like `vec_map`, read it in key order (head/tail, floor/ceiling, paginate), O(log N) lookup with one stored-object access per op. See [`sorted_map/examples/sorted_map/`](sorted_map/examples/sorted_map) for integration examples. |
| [`sorted_set/`](sorted_set/) | [`@openzeppelin-move/sorted_set`](https://www.moveregistry.com/package/@openzeppelin-move/sorted_set) | `openzeppelin_sorted_set` | [docs](https://docs.openzeppelin.com/contracts-sui/1.x/sorted_set) | An ordered set of unique keys (`SortedSet<K>`), a thin wrapper over `SortedMap<K, Unit>`: the ordered counterpart to `vec_set`, with `bool`-returning `insert`/`remove` (no abort-on-duplicate), nearest-neighbour navigation, and pagination. See [`sorted_set/examples/sorted_set/`](sorted_set/examples/sorted_set) for integration examples. |
| [`big_sorted_map/`](big_sorted_map/) | [`@openzeppelin-move/big_sorted_map`](https://www.moveregistry.com/package/@openzeppelin-move/big_sorted_map) | `openzeppelin_big_sorted_map` | [docs](https://docs.openzeppelin.com/contracts-sui/1.x/big_sorted_map) | The large tier: an ordered key-value B+Tree (`BigSortedMap<K, V>`) whose nodes are dynamic fields, scaling past the single-object cap while reusing `SortedMap` as each node's payload and mirroring its query API. See [`big_sorted_map/examples/big_sorted_map/`](big_sorted_map/examples/big_sorted_map) for integration examples. |

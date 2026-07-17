/// A generic, ordered key->value map with O(log N) lookup and ordered navigation. Every operation
/// loads exactly one stored object, so capacity is bounded by object size, not a per-transaction
/// dynamic-field cap.
///
/// `SortedMap` is a UID-less value: no identity of its own, no dynamic fields. Every entry
/// lives inline in one vector, shaped like `sui::vec_map::VecMap`. A bare map is not `key`, so
/// embed it in your own `has key` object for owned or shared semantics:
/// ```move
/// public struct AskBook has key { id: UID, asks: SortedMap<u64, Level> }
/// ```
///
/// # Essentials
///
/// - **One comparator, threaded to every call.** You supply a strict total order
///   `|&K, &K| -> bool`; the map stores none. A different or non-strict comparator on a later
///   call silently corrupts the map (see below).
/// - **Bare vs `_by`.** Bare ops (`upsert`, `borrow!`) assume the built-in integer `<` and
///   compile only for integer keys; `_by` ops take your `lt` lambda and are required for
///   `address`, struct, or any non-integer key.
/// - **Non-droppable entries must be drained.** If either `K` or `V` lacks `drop`, the map cannot
///   be dropped. Remove every entry, consume both returned parts, and then call `destroy_empty`.
/// - **Bounded by object size.** O(log N) lookup, O(N) insert/remove, one object loaded per
///   call - so the only ceiling is Sui's ~250 KB object cap.
///
/// # The comparator
///
/// Move has no storable function values, so the comparator can't live in the struct - and a
/// phantom witness couldn't validate the actual `lt` passed at runtime anyway. Move also has no
/// standard ordering trait, so ordering is a lambda you supply, not a property of `K`.
///
/// You pass a strict less-than; equality is derived as `!lt(a, b) && !lt(b, a)`. It MUST be a
/// strict total order (irreflexive, asymmetric, transitive, total) and MUST be the same on every
/// call to a given map. The library cannot detect a violation, and the failure is silent:
/// - a non-strict `<=` never detects equal keys, causing duplicate inserts and missed removes
///   and lookups;
/// - mixing `<` and `>` across calls corrupts order: wrong values, spurious misses, values
///   stranded at unreachable positions.
///
/// A coarse (non-injective) comparator reports two byte-distinct keys as equal, collapsing them
/// into one entry. On that collision an upsert overwrites the stored key with the incoming one -
/// last-write-wins: the previously stored key is dropped and the new key is stored - so which
/// byte-variant is retained is well-defined only under an injective comparator.
///
/// A reverse comparator used consistently is legitimate: it flips the order, so `head` returns
/// the largest numeric key. In tests, call `is_well_formed_by!(&map, lt)` after a `_by` sequence
/// to catch a comparator mistake.
///
/// # Complexity and limits
///
/// Writes are O(N) because of the vector shift. Loading one object per call, not one per entry,
/// is why the map never approaches Sui's per-transaction dynamic-field access cap - object byte
/// size is the only limit.
///
/// The `_by` macros expand `search!` inline. A single function with many distinct macro calls can
/// therefore hit Move's ~256 local-variable limit (compiler error `value (N) cannot exceed
/// (255)`) - split the function, or drive the calls from one reused loop body.
///
/// # Forced-public internals
///
/// Move 2024 macro hygiene requires every symbol a macro body references to be `public` at the
/// consumer's expansion site, so `search!`, `insert_at`, `remove_at`, `key`, and similar are
/// `public`. They are not a supported mutation API: `insert_at` / `remove_at` write at a
/// caller-given position with no order check, so calling them directly can corrupt sorted order.
/// Use the macro API.
///
/// # Upgrade compatibility
///
/// The on-chain struct layout is frozen at first publish by Sui's upgrade checker. There is
/// deliberately no `version` field: on a frozen-layout embedded value it could only ever hold its
/// initial constant. A future layout change ships as a parallel `SortedMapV2` with consumer-driven
/// migration, never an in-place edit - which would break BCS deserialization of every downstream
/// object embedding the old layout.
module openzeppelin_collections::sorted_map;

// === Errors ===

/// A key was not present in the map.
#[error(code = 0)]
const EKeyNotFound: vector<u8> = "Key not found";

/// `destroy_empty` was called on a non-empty map.
#[error(code = 1)]
const ENotEmpty: vector<u8> = "Map is not empty";

/// `pop_front`/`pop_back` was called on an empty map.
#[error(code = 2)]
const EEmpty: vector<u8> = "Map is empty";

/// A bulk constructor (`from_sorted_keys_values`) received keys that are not strictly increasing
/// under the comparator (out of order, or a duplicate).
#[error(code = 3)]
const EKeysNotStrictlyIncreasing: vector<u8> = "Keys are not strictly increasing";

/// A bulk constructor (`from_sorted_keys_values`) received `keys` and `values` of different
/// lengths.
#[error(code = 4)]
const EUnequalLengths: vector<u8> = "Keys and values differ in length";

/// A key was present in the map.
#[error(code = 5)]
const EKeyAlreadyExists: vector<u8> = "Key already exists";

// === Structs ===

/// One key-value pair, stored inline in the map's vector.
///
/// Abilities materialize jointly over `K` and `V`: `Entry<u64, u64>` is `copy + drop +
/// store`, while `Entry<u64, Coin<T>>` is store-only.
public struct Entry<K, V> has copy, drop, store {
    /// The entry's key.
    key: K,
    /// The entry's value.
    value: V,
}

/// A map kept sorted by key. Every operation loads exactly one stored object, so it is bounded
/// by object size (~250 KB), not by any per-transaction dynamic-field cap; lookup is O(log N)
/// and writes are O(N).
///
/// A pure value - no `UID`, no dynamic fields - so it embeds directly in an integrator's
/// object, exactly like `sui::vec_map::VecMap`. `copy`/`drop` materialize only when both
/// `K` and `V` allow them: `SortedMap<u64, u64>` is `copy + drop + store`;
/// `SortedMap<u64, Coin<T>>` is store-only and must be drained then `destroy_empty`'d.
public struct SortedMap<K, V> has copy, drop, store {
    /// The map's entries. Across the supported (macro) API this vector is strictly
    /// increasing under the (consistently supplied) comparator: sorted, with no duplicate
    /// keys. The forced-public position-based writers (`insert_at`/`remove_at`) can break
    /// this if misused - see the forced-public internals note in the module header.
    entries: vector<Entry<K, V>>,
}

// === Public Functions ===

// === Lifecycle ===

/// Create a new, empty map. Takes no `&mut TxContext`: a `SortedMap` is a value, not an
/// object.
///
/// #### Returns
/// - An empty map.
public fun new<K, V>(): SortedMap<K, V> {
    SortedMap { entries: vector[] }
}

/// A map holding a single `key`/`value` entry. O(1); needs no comparator, since one entry is
/// trivially sorted. For more than one entry from pre-sorted data, use `from_sorted_keys_values!`.
///
/// #### Parameters
/// - `key`: The sole entry's key.
/// - `value`: The sole entry's value.
///
/// #### Returns
/// - A one-entry map.
public fun singleton<K, V>(key: K, value: V): SortedMap<K, V> {
    SortedMap { entries: vector[Entry { key, value }] }
}

/// Destroy an empty map.
///
/// This is the terminal for a map whose key or value type lacks `drop` (for example,
/// `SortedMap<K, Coin<T>>`). Drain every entry via `remove` or `pop_*`, consume both the returned
/// key and value, and then call this function.
///
/// #### Aborts
/// - `ENotEmpty` if the map still holds entries.
public fun destroy_empty<K, V>(map: SortedMap<K, V>) {
    let SortedMap { entries } = map;
    // Assert before the inner `destroy_empty` so a non-empty map surfaces `ENotEmpty` at this
    // module's location rather than a lower-level abort.
    assert!(entries.is_empty(), ENotEmpty);
    entries.destroy_empty();
}

// === Size and bounds (no comparator) ===

/// Number of entries.
public fun length<K, V>(map: &SortedMap<K, V>): u64 {
    map.entries.length()
}

/// True iff the map holds no entries.
public fun is_empty<K, V>(map: &SortedMap<K, V>): bool {
    map.entries.is_empty()
}

/// Smallest key under the comparator, or `none` if empty. O(1). With a reverse
/// comparator this returns the largest numeric key.
public fun head<K: copy, V>(map: &SortedMap<K, V>): Option<K> {
    if (map.entries.is_empty()) option::none() else option::some(map.entries.borrow(0).key)
}

/// Largest key under the comparator, or `none` if empty. O(1).
public fun tail<K: copy, V>(map: &SortedMap<K, V>): Option<K> {
    let n = map.entries.length();
    if (n == 0) option::none() else option::some(map.entries.borrow(n - 1).key)
}

// === Macro-internal accessors and search (forced-public; NOT a supported API) ===
//
// Everything in this section is `public` because Move 2024 macro hygiene requires every
// symbol a macro body references to be public at the consumer's expansion site (plus
// `value`, which completes the `entries` read surface). In particular
// `insert_at`/`remove_at` write at a caller-given index with no ordering check, so calling
// them directly can corrupt sorted order. Use the macro API (`upsert`, `remove!`, ...) instead.

/// Immutable view of the backing vector. There is deliberately no `&mut`/owning
/// counterpart, so bulk reordering or bulk value-destruction is unrepresentable through
/// this surface.
///
/// #### Parameters
/// - `map`: The map to read.
///
/// #### Returns
/// - Reference to the backing entry vector, in ascending key order.
public fun entries<K, V>(map: &SortedMap<K, V>): &vector<Entry<K, V>> {
    &map.entries
}

/// Borrow an entry's key. Macro bodies must read keys through this (not `.key`), since
/// the field is private at the expansion site.
///
/// #### Parameters
/// - `e`: The entry to read.
///
/// #### Returns
/// - Reference to the entry's key.
public fun key<K, V>(e: &Entry<K, V>): &K {
    &e.key
}

/// Borrow an entry's value. Unlike its neighbors in this section, no macro body references
/// it - it is public as the value-reading complement to `key`, completing the read
/// surface of `entries` (the `Entry` fields are private).
///
/// #### Parameters
/// - `e`: The entry to read.
///
/// #### Returns
/// - Reference to the entry's value.
public fun value<K, V>(e: &Entry<K, V>): &V {
    &e.value
}

/// Build an entry from `key`/`value` (consumed by move) and insert it at index `i`, shifting
/// later entries right. Takes the key and value rather than a prebuilt `Entry` because `Entry`
/// is unconstructable outside this module.
///
/// > **Warning:** low-level primitive intended solely for use by this module's macro API
/// > (`upsert`, ...), which computes `i` from a sorted search. It performs no ordering
/// > check: passing an `i` that breaks sorted order silently corrupts the map and
/// > invalidates every lookup, insertion, and removal thereafter. Avoid calling it directly -
/// > use the macro API.
///
/// #### Parameters
/// - `map`: The map to mutate.
/// - `key`: The new entry's key.
/// - `value`: The new entry's value.
/// - `i`: Insertion index.
///
/// #### Aborts
/// - `std::vector::EINDEX_OUT_OF_BOUNDS` (code `0x20000`, location `std::vector`) if
///   `i > length`.
public fun insert_at<K, V>(map: &mut SortedMap<K, V>, key: K, value: V, i: u64) {
    map.entries.insert(Entry { key, value }, i);
}

/// Remove the entry at index `i`, shifting later entries left, and return its (key, value) pair.
///
/// #### Parameters
/// - `map`: The map to mutate.
/// - `i`: Index of the entry to remove.
///
/// #### Returns
/// - The (key, value) pair at index `i`.
///
/// #### Aborts
/// - `std::vector::EINDEX_OUT_OF_BOUNDS` (code `0x20000`, location `std::vector`) if
///   `i >= length`.
public fun remove_at<K, V>(map: &mut SortedMap<K, V>, i: u64): (K, V) {
    let Entry { key, value } = map.entries.remove(i);
    (key, value)
}

/// Borrow the value at index `i` (read-only).
///
/// #### Parameters
/// - `map`: The map to read.
/// - `i`: Index of the value to borrow.
///
/// #### Returns
/// - Reference to the value at index `i`.
///
/// #### Aborts
/// - A native vector bounds error (`vector_error`, minor status 1) if `i >= length`.
public fun value_at<K, V>(map: &SortedMap<K, V>, i: u64): &V {
    &map.entries.borrow(i).value
}

/// Mutably borrow the value at index `i`. Yields `&mut V`, never `&mut Entry`, so the key
/// stays unreachable for in-place mutation and value mutation is order-safe.
///
/// #### Parameters
/// - `map`: The map to mutate.
/// - `i`: Index of the value to borrow.
///
/// #### Returns
/// - Mutable reference to the value at index `i`.
///
/// #### Aborts
/// - A native vector bounds error (`vector_error`, minor status 1) if `i >= length`.
public fun value_at_mut<K, V>(map: &mut SortedMap<K, V>, i: u64): &mut V {
    &mut map.entries.borrow_mut(i).value
}

/// Abort `EKeyNotFound` if `found` is false. Routing absent-key lookups through this
/// regular fun guarantees the abort fires at this module's location, not in the
/// consumer's inlined macro body.
///
/// #### Aborts
/// - `EKeyNotFound` if `found` is false.
public fun assert_key_found(found: bool) {
    assert!(found, EKeyNotFound);
}

/// Abort `EKeyAlreadyExists` if `absent` is false. Routed through this regular fun so `add`'s
/// abort fires at this module's location, not the consumer's inlined macro body (and so the
/// module-internal `EKeyAlreadyExists` const is not referenced from the expansion site).
///
/// #### Aborts
/// - `EKeyAlreadyExists` if `absent` is false.
public fun assert_key_absent(absent: bool) {
    assert!(absent, EKeyAlreadyExists);
}

/// Abort `EUnequalLengths` if `equal` is false. Routed through this regular fun so the bulk
/// constructor's abort fires at this module's location, not the consumer's inlined macro body.
///
/// #### Aborts
/// - `EUnequalLengths` if `equal` is false.
public fun assert_equal_lengths(equal: bool) {
    assert!(equal, EUnequalLengths);
}

/// Abort `EKeysNotStrictlyIncreasing` if `increasing` is false. Routed through this regular fun
/// so the abort fires at this module's location, not the consumer's inlined macro body.
///
/// #### Aborts
/// - `EKeysNotStrictlyIncreasing` if `increasing` is false.
public fun assert_strictly_increasing(increasing: bool) {
    assert!(increasing, EKeysNotStrictlyIncreasing);
}

/// Binary search for `target` under `$lt`.
///
/// #### Parameters
/// - `map`: The map to read.
/// - `target`: Key to locate.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - `(true, idx)` when `entries[idx].key` equals `target` (derived: neither
///   `lt(k, t)` nor `lt(t, k)`). The supported API keeps entries strictly sorted - at most
///   one entry per key - so the match is unique; on a map corrupted via the index writers the
///   library gives no guarantee which entry is returned (the sorted/unique invariant is broken).
/// - `(false, idx)` when absent, where `idx` is the lower-bound insertion point - the
///   number of keys strictly less than `target`, in `[0, n]`.
public macro fun search<$K, $V>(
    $map: &SortedMap<$K, $V>,
    $target: &$K,
    $lt: |&$K, &$K| -> bool,
): (bool, u64) {
    let map = $map;
    let target = $target;
    let es = map.entries();
    let n = es.length();
    let mut lo = 0;
    let mut hi = n;
    let mut found = false;
    let mut idx = n;
    while (lo < hi) {
        let mid = lo + (hi - lo) / 2;
        let mk = es.borrow(mid).key();
        if ($lt(mk, target)) {
            lo = mid + 1;
        } else if ($lt(target, mk)) {
            hi = mid;
        } else {
            found = true;
            idx = mid;
            break
        };
    };
    if (found) (true, idx) else (false, lo)
}

// === Bulk construction (macros: bare + `_by`) ===

/// Build a map from parallel `keys`/`values` that MUST already be strictly increasing under
/// `$lt` (sorted, no duplicate keys). O(n): one pass validates each adjacent pair, then appends
/// at the back - no per-element search. Prefer this to a loop of `upsert_by!`, which is O(n^2)
/// for unsorted input.
///
/// Unlike `sorted_set::from_keys!` (which de-duplicates), this ABORTS on any out-of-order or
/// duplicate key: values are conserved (a resource `V` can never be silently displaced), so a
/// duplicate cannot be collapsed away.
///
/// If your keys are not yet ordered, sort them under the same comparator first, then call this.
/// A sort-internally variant is intentionally omitted: it would add a sorting dependency, run in
/// O(n log n) at best (O(n^2) worst) instead of O(n), and would still reject duplicate keys.
///
/// #### Parameters
/// - `keys`: Strictly-increasing keys under `lt`.
/// - `values`: Values positionally paired with `keys`.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - A map with `keys[i]` -> `values[i]`, in ascending order.
///
/// #### Aborts
/// - `EUnequalLengths` if `keys` and `values` differ in length.
/// - `EKeysNotStrictlyIncreasing` if `keys` is not strictly increasing under `lt`.
public macro fun from_sorted_keys_values_by<$K, $V>(
    $keys: vector<$K>,
    $values: vector<$V>,
    $lt: |&$K, &$K| -> bool,
): SortedMap<$K, $V> {
    let mut keys = $keys;
    let mut values = $values;
    assert_equal_lengths(keys.length() == values.length());
    let n = keys.length();
    let mut i = 1;
    while (i < n) {
        assert_strictly_increasing($lt(keys.borrow(i - 1), keys.borrow(i)));
        i = i + 1;
    };
    // Validated: consume both vectors front-to-back (reverse, then O(1) `pop_back` each),
    // appending at the back so the result keeps the input's ascending order.
    keys.reverse();
    values.reverse();
    let mut map = new();
    while (!keys.is_empty()) {
        let k = keys.pop_back();
        let v = values.pop_back();
        let at = map.length();
        map.insert_at(k, v, at);
    };
    keys.destroy_empty();
    values.destroy_empty();
    map
}

/// `from_sorted_keys_values_by` with the built-in integer `<`.
///
/// #### Returns
/// - A map with `keys[i]` -> `values[i]`, in ascending order.
///
/// #### Aborts
/// - `EUnequalLengths` / `EKeysNotStrictlyIncreasing` - see `from_sorted_keys_values_by`.
public macro fun from_sorted_keys_values<$K, $V>(
    $keys: vector<$K>,
    $values: vector<$V>,
): SortedMap<$K, $V> {
    from_sorted_keys_values_by!($keys, $values, |a, b| *a < *b)
}

// === Point access (macros: bare + `_by`) ===

/// True iff `key` is present, under `$lt`. Pure, total read: agrees exactly with `borrow`
/// succeeding, since both route through `search!`.
///
/// #### Parameters
/// - `map`: The map to read.
/// - `key`: Key to test.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - `true` iff `key` is present.
public macro fun contains_by<$K, $V>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): bool {
    let map = $map;
    let (found, _idx) = map.search!($key, $lt);
    found
}

/// `contains_by` with the built-in integer `<`.
///
/// #### Returns
/// - `true` iff `key` is present.
public macro fun contains<$K, $V>($map: &SortedMap<$K, $V>, $key: &$K): bool {
    contains_by!($map, $key, |a, b| *a < *b)
}

/// Immutable borrow of `key`'s value, under `$lt`.
///
/// #### Parameters
/// - `map`: The map to read.
/// - `key`: Key to look up.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - Reference to `key`'s value.
///
/// #### Aborts
/// - `EKeyNotFound` if `key` is absent.
public macro fun borrow_by<$K, $V>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): &$V {
    let map = $map;
    let (found, idx) = map.search!($key, $lt);
    // Assert before the indexed read: on a miss `idx` is the lower-bound insertion point,
    // so reading it first would silently return the successor's value (or abort
    // out-of-bounds at `idx == n`).
    assert_key_found(found);
    map.value_at(idx)
}

/// `borrow_by` with the built-in integer `<`.
///
/// #### Returns
/// - Reference to `key`'s value.
///
/// #### Aborts
/// - `EKeyNotFound` if `key` is absent.
public macro fun borrow<$K, $V>($map: &SortedMap<$K, $V>, $key: &$K): &$V {
    borrow_by!($map, $key, |a, b| *a < *b)
}

/// Mutable borrow of `key`'s value, under `$lt`. Yields `&mut V`, never `&mut Entry`, so
/// the key cannot be desynced from its sorted position.
///
/// #### Parameters
/// - `map`: The map to mutate.
/// - `key`: Key to look up.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - Mutable reference to `key`'s value.
///
/// #### Aborts
/// - `EKeyNotFound` if `key` is absent.
public macro fun borrow_mut_by<$K, $V>(
    $map: &mut SortedMap<$K, $V>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): &mut $V {
    let map = $map;
    let (found, idx) = map.search!($key, $lt);
    assert_key_found(found);
    map.value_at_mut(idx)
}

/// `borrow_mut_by` with the built-in integer `<`.
///
/// #### Returns
/// - Mutable reference to `key`'s value.
///
/// #### Aborts
/// - `EKeyNotFound` if `key` is absent.
public macro fun borrow_mut<$K, $V>($map: &mut SortedMap<$K, $V>, $key: &$K): &mut $V {
    borrow_mut_by!($map, $key, |a, b| *a < *b)
}

/// Insert `key`/`value` under `$lt`, aborting if `key` is already present (length + 1).
/// `key` is taken by value and moved into storage; nothing is returned.
///
/// Matches `sui::vec_map::insert`: a strict insert that refuses to touch an existing entry,
/// so a duplicate is always a caller bug rather than a silent overwrite. Use [`upsert_by`]
/// instead when replacing an existing value is the intended behavior - it returns the
/// displaced value rather than aborting.
///
/// #### Parameters
/// - `map`: The map to mutate.
/// - `key`: Key to insert; must not already be present.
/// - `value`: Value to store.
/// - `lt`: Strict less-than comparator.
///
/// #### Aborts
/// - `EKeyAlreadyExists` if `key` is already present.
public macro fun add_by<$K, $V>(
    $map: &mut SortedMap<$K, $V>,
    $key: $K,
    $value: $V,
    $lt: |&$K, &$K| -> bool,
) {
    let map = $map;
    let key = $key;
    let value = $value;
    let (found, idx) = map.search!(&key, $lt);
    assert_key_absent(!found);
    map.insert_at(key, value, idx);
}

/// `add_by` with the built-in integer `<`.
///
/// #### Aborts
/// - `EKeyAlreadyExists` if `key` is already present.
public macro fun add<$K, $V>($map: &mut SortedMap<$K, $V>, $key: $K, $value: $V) {
    add_by!($map, $key, $value, |a, b| *a < *b)
}

/// Insert `key`/`value`, or replace the value if `key` is already present, under `$lt`. `key`
/// is taken by value: on a fresh insert it is moved into storage; on a replace the previously
/// stored key is dropped and this `key` is stored in its place (last-write-wins for the key bytes -
/// observable only under a coarse comparator). The displaced VALUE is returned - never dropped - so
/// a resource `V` is safe; `K` must be `drop` (only because the displaced key is dropped on replace).
///
/// Deliberate divergence from `sui::vec_map::insert`, which aborts on a duplicate key: this
/// is a total upsert, matching `sorted_set`'s divergence from `vec_set`. For abort-on-duplicate,
/// prefer `add!` (a strict insert); or, when `V: drop`, assert on the returned option:
///
/// ```move
/// assert!(m.upsert!(k, v).is_none(), E);
/// ```
/// For a resource `V` (no `drop`) the returned option cannot be dropped, so bind and
/// consume it instead:
///
/// ```move
/// let old = m.upsert!(k, v);
/// assert!(old.is_none(), E);
/// old.destroy_none();
/// ```
///
/// #### Parameters
/// - `map`: The map to mutate.
/// - `key`: Key to insert or update (taken by value).
/// - `value`: Value to store.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - `some(old_value)` on replace (length unchanged), `none` on a fresh insert (length + 1).
public macro fun upsert_by<$K: drop, $V>(
    $map: &mut SortedMap<$K, $V>,
    $key: $K,
    $value: $V,
    $lt: |&$K, &$K| -> bool,
): Option<$V> {
    let map = $map;
    let key = $key;
    let value = $value;
    let (found, idx) = map.search!(&key, $lt);
    if (found) {
        // Extract-then-reinsert, deliberately NOT `*map.value_at_mut(..) = value`: overwriting
        // in place would drop the old value (requiring `V: drop`) and silently destroy a `Coin`.
        // The old key is dropped (`K: drop`) and the incoming `key` stored in its place, so a
        // coarse-comparator re-insert keeps the LAST key's bytes (last-write-wins).
        let (_, old_value) = map.remove_at(idx);
        map.insert_at(key, value, idx);
        let res = option::some(old_value);
        res
    } else {
        map.insert_at(key, value, idx);
        let res = option::none();
        res
    }
}

/// `upsert_by` with the built-in integer `<`.
///
/// #### Returns
/// - `some(old)` on replace, `none` on a fresh insert.
public macro fun upsert<$K: drop, $V>(
    $map: &mut SortedMap<$K, $V>,
    $key: $K,
    $value: $V,
): Option<$V> {
    upsert_by!($map, $key, $value, |a, b| *a < *b)
}

/// Remove `key`'s entry and return its `(key, value)` pair, under `$lt` (length - 1, order
/// preserved).
///
/// Uses a shifting `vector::remove`, never `swap_remove`, which would break strict order.
///
/// #### Parameters
/// - `map`: The map to mutate.
/// - `key`: Key to remove.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - The removed (key, value) tuple.
///
/// #### Aborts
/// - `EKeyNotFound` if `key` is absent.
public macro fun remove_by<$K, $V>(
    $map: &mut SortedMap<$K, $V>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): ($K, $V) {
    let map = $map;
    let (found, idx) = map.search!($key, $lt);
    assert_key_found(found);
    let (key, value) = map.remove_at(idx);
    (key, value)
}

/// `remove_by` with the built-in integer `<`.
///
/// #### Returns
/// - The removed (key, value) tuple.
///
/// #### Aborts
/// - `EKeyNotFound` if `key` is absent.
public macro fun remove<$K, $V>($map: &mut SortedMap<$K, $V>, $key: &$K): ($K, $V) {
    remove_by!($map, $key, |a, b| *a < *b)
}

// === Ordered navigation (macros: bare + `_by`) ===

/// Smallest key `>= key` when `include` (the ceiling), else smallest key `> key` (strict
/// next); `none` if there is no such key. Pure, total read. Any returned key satisfies
/// `contains`.
///
/// #### Parameters
/// - `map`: The map to read.
/// - `key`: Reference key.
/// - `include`: Whether an exact match of `key` qualifies.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - The ceiling/strict-next key, or `none`.
public macro fun find_next_by<$K: copy, $V>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
    $include: bool,
    $lt: |&$K, &$K| -> bool,
): Option<$K> {
    let map = $map;
    let include = $include;
    let (found, idx) = map.search!($key, $lt);
    let es = map.entries();
    let n = es.length();
    if (found) {
        if (include) {
            option::some(*es.borrow(idx).key())
        } else if (idx + 1 < n) {
            option::some(*es.borrow(idx + 1).key())
        } else {
            option::none()
        }
    } else if (idx < n) {
        // miss: idx is the insertion point = first key strictly greater than `key`,
        // which is the ceiling too (key is absent), so `include` doesn't matter here.
        option::some(*es.borrow(idx).key())
    } else {
        option::none()
    }
}

/// `find_next_by` with the built-in integer `<`.
///
/// #### Returns
/// - The ceiling/strict-next key, or `none`.
public macro fun find_next<$K: copy, $V>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
    $include: bool,
): Option<$K> {
    find_next_by!($map, $key, $include, |a, b| *a < *b)
}

/// Largest key `<= key` when `include` (the floor), else largest key `< key` (strict
/// prev); `none` if there is no such key. Pure, total read. Any returned key satisfies
/// `contains`.
///
/// #### Parameters
/// - `map`: The map to read.
/// - `key`: Reference key.
/// - `include`: Whether an exact match of `key` qualifies.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - The floor/strict-prev key, or `none`.
public macro fun find_prev_by<$K: copy, $V>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
    $include: bool,
    $lt: |&$K, &$K| -> bool,
): Option<$K> {
    let map = $map;
    let include = $include;
    let (found, idx) = map.search!($key, $lt);
    let es = map.entries();
    if (found) {
        if (include) {
            option::some(*es.borrow(idx).key())
        } else if (idx > 0) {
            option::some(*es.borrow(idx - 1).key())
        } else {
            option::none()
        }
    } else if (idx > 0) {
        // miss: idx is the insertion point, so idx-1 is the last key strictly less than
        // `key` - the floor too (key is absent), so `include` doesn't matter here.
        option::some(*es.borrow(idx - 1).key())
    } else {
        option::none()
    }
}

/// `find_prev_by` with the built-in integer `<`.
///
/// #### Returns
/// - The floor/strict-prev key, or `none`.
public macro fun find_prev<$K: copy, $V>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
    $include: bool,
): Option<$K> {
    find_prev_by!($map, $key, $include, |a, b| *a < *b)
}

/// Smallest key strictly greater than `key`, or `none`. Sugar for
/// `find_next_by(.., false)`. `next_key(tail) == none` is the forward-cursor termination
/// signal.
///
/// #### Parameters
/// - `map`: The map to read.
/// - `key`: Reference key.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - The strict-next key, or `none`.
public macro fun next_key_by<$K: copy, $V>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): Option<$K> {
    find_next_by!($map, $key, false, $lt)
}

/// `next_key_by` with the built-in integer `<`.
///
/// #### Returns
/// - The strict-next key, or `none`.
public macro fun next_key<$K: copy, $V>($map: &SortedMap<$K, $V>, $key: &$K): Option<$K> {
    next_key_by!($map, $key, |a, b| *a < *b)
}

/// Largest key strictly less than `key`, or `none`. Sugar for
/// `find_prev_by(.., false)`. `prev_key(head) == none` is the backward-cursor termination
/// signal.
///
/// #### Parameters
/// - `map`: The map to read.
/// - `key`: Reference key.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - The strict-prev key, or `none`.
public macro fun prev_key_by<$K: copy, $V>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): Option<$K> {
    find_prev_by!($map, $key, false, $lt)
}

/// `prev_key_by` with the built-in integer `<`.
///
/// #### Returns
/// - The strict-prev key, or `none`.
public macro fun prev_key<$K: copy, $V>($map: &SortedMap<$K, $V>, $key: &$K): Option<$K> {
    prev_key_by!($map, $key, |a, b| *a < *b)
}

// === Bounded iteration / pagination (macros: bare + `_by`) ===

/// Up to `limit` keys in strict ascending order, a contiguous run starting at the first
/// key `>= from` (when `include`) or `> from` (strict). Returns at most `limit` keys;
/// fewer if the tail is reached.
///
/// Resume a page by passing the last returned key back as `from` with `include == false`.
/// While the ordered key set is unchanged, successive pages have no overlap or gap, so
/// concatenating them reconstructs the tail exactly. A cursor reused after a key-set mutation has
/// keyset semantics: each call reads the keys currently after `from`. Keys inserted at or before
/// the cursor are skipped, keys inserted after it can appear, and removed keys do not appear. With
/// a positive `limit`, an empty page means no key follows the cursor at that moment, not that a
/// persisted scan is permanently complete. `limit == 0`, an empty map, or `from` past the current
/// tail all yield the empty vector.
///
/// #### Parameters
/// - `map`: The map to read.
/// - `from`: Lower-bound key.
/// - `include`: Whether an exact match of `from` is included.
/// - `limit`: Maximum number of keys to return.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - Up to `limit` keys in ascending order.
public macro fun keys_from_by<$K: copy, $V>(
    $map: &SortedMap<$K, $V>,
    $from: &$K,
    $include: bool,
    $limit: u64,
    $lt: |&$K, &$K| -> bool,
): vector<$K> {
    let map = $map;
    let include = $include;
    let limit = $limit;
    let (found, idx) = map.search!($from, $lt);
    // First qualifying index = the insertion point, skipping an exact hit only when the
    // boundary is exclusive. On a miss `idx` is already the first key > from (the
    // ceiling), so `include` does not shift it.
    let start = if (found && !include) idx + 1 else idx;
    let es = map.entries();
    let n = es.length();
    let mut out = vector[];
    let mut i = start;
    // Not bounding on `i < start + limit`, as it would overflow when `limit` is near
    // `u64::MAX`.
    while (i < n && out.length() < limit) {
        out.push_back(*es.borrow(i).key());
        i = i + 1;
    };
    out
}

/// `keys_from_by` with the built-in integer `<`.
///
/// #### Returns
/// - Up to `limit` keys in ascending order.
public macro fun keys_from<$K: copy, $V>(
    $map: &SortedMap<$K, $V>,
    $from: &$K,
    $include: bool,
    $limit: u64,
): vector<$K> {
    keys_from_by!($map, $from, $include, $limit, |a, b| *a < *b)
}

// === Pop extremes (regular funs; abort EEmpty) ===

/// Remove and return the smallest entry `(key, value)`.
///
/// The operation is O(N), as it shifts every remaining entry.
/// Prefer `pop_back` for bulk drains, as it's O(1).
///
/// #### Returns
/// - The smallest `(key, value)` pair.
///
/// #### Aborts
/// - `EEmpty` if the map is empty.
public fun pop_front<K, V>(map: &mut SortedMap<K, V>): (K, V) {
    // Check first: `remove(0)` on an empty vector would abort with
    // `std::vector::EINDEX_OUT_OF_BOUNDS` (code `0x20000`), not `EEmpty`.
    assert!(!map.is_empty(), EEmpty);
    let Entry { key, value } = map.entries.remove(0);
    (key, value)
}

/// Remove and return the largest entry `(key, value)`. Length - 1. O(1) (no shift).
///
/// #### Returns
/// - The largest `(key, value)` pair.
///
/// #### Aborts
/// - `EEmpty` if the map is empty.
public fun pop_back<K, V>(map: &mut SortedMap<K, V>): (K, V) {
    // Check first: `pop_back` on an empty vector would raise a native vector bounds error
    // (`vector_error`, minor status 2), not `EEmpty`.
    assert!(!map.is_empty(), EEmpty);
    let Entry { key, value } = map.entries.pop_back();
    (key, value)
}

// === Full enumeration (regular fun; no comparator) ===

/// All keys in ascending comparator order as an owned `vector<K>`. O(N) in output size with
/// no `limit`; for large or near-ceiling maps prefer the paged `keys_from!`. Loads exactly
/// one stored object regardless of N.
///
/// #### Returns
/// - Every key, in ascending comparator order.
public fun keys<K: copy, V>(map: &SortedMap<K, V>): vector<K> {
    map.entries.map_ref!(|entry| entry.key)
}

// === Test-Only Helpers ===

/// Returns true iff `entries` is strictly increasing under `$lt` - i.e. sorted with no
/// duplicate keys. A non-strict step (`!lt(prev, cur)`) means either an out-of-order pair
/// or an equal-comparing duplicate. This is the order check for tests, directly
/// re-verifying the sorted-order property that production code maintains by construction
/// but never re-validates.
///
/// `#[test_only]`, so it is absent from published bytecode and cannot be called from
/// production consumer code (an O(n) walk per O(log n) op would erase the single-object
/// performance thesis). It IS visible to a dependent's test code - consumers call it in
/// their own suites after `_by` sequences to catch comparator mistakes. Returns `bool`
/// rather than asserting, so callers compose it into their own assertions.
///
/// #### Parameters
/// - `map`: The map to read.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - `true` iff the map is strictly increasing under `lt`.
#[test_only]
public macro fun is_well_formed_by<$K, $V>(
    $map: &SortedMap<$K, $V>,
    $lt: |&$K, &$K| -> bool,
): bool {
    let map = $map;
    let es = map.entries();
    let n = es.length();
    let mut ok = true;
    let mut i = 1;
    while (i < n) {
        if (!$lt(es.borrow(i - 1).key(), es.borrow(i).key())) {
            ok = false;
            break
        };
        i = i + 1;
    };
    ok
}

/// `is_well_formed_by` with the built-in integer `<`.
///
/// #### Returns
/// - `true` iff the map is strictly increasing under the built-in `<`.
#[test_only]
public macro fun is_well_formed<$K, $V>($map: &SortedMap<$K, $V>): bool {
    is_well_formed_by!($map, |a, b| *a < *b)
}

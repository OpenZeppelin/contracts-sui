/// A generic, ordered key->value map backed by a single sorted `vector<Entry<K, V>>`.
///
/// `SortedMap` is a UID-less value type (shaped like `sui::vec_map::VecMap`): it has
/// no object identity and no dynamic fields - every entry lives inline in one vector.
/// Embed it directly in your own object:
/// ```
/// public struct AskBook has key { id: UID, asks: SortedMap<u64, Level> }
/// ```
/// A bare `SortedMap` cannot be `transfer`/`share`d (it is not `key`); wrap it in your
/// own `has key` object to get owned or shared semantics.
///
/// # Complexity and liveness
///
/// Lookup is O(log N) binary search over one in-memory vector; insert and remove are
/// O(N) (a shift in that vector). Every operation - including a full `keys_from` page -
/// loads exactly ONE stored object regardless of N, so the map can never approach Sui's
/// per-transaction dynamic-field access cap. The binding limit is byte size: the
/// enclosing object must stay under Sui's object-size cap (~256 KB).
///
/// # Comparator contract (read this)
///
/// The map stores no comparator. Order is defined per call by a strict less-than
/// `|&K, &K| -> bool` you supply. Equality is derived as `!lt(a, b) && !lt(b, a)`. Each
/// comparator-needing operation comes in two forms:
/// - bare (`insert!`, `borrow!`, ...) assumes the built-in integer `<`; valid only for
///   integer keys (`u8`..`u256`).
/// - `_by` (`insert_by!`, `borrow_by!`, ...) takes the `lt` lambda; required for
///   non-integer keys (`address`, structs, ...).
///
/// The comparator MUST be a strict total order (irreflexive, asymmetric, transitive,
/// total) and MUST be threaded consistently to every call on a given map. The library
/// cannot detect a violation; the failure is silent:
/// - passing `<=` (non-strict) means equal keys are never detected, causing duplicate
///   inserts and missed removes/contains;
/// - mixing `<` and `>` across calls corrupts ordering: wrong values, spurious misses,
///   stranded (unreachable) values.
///
/// A reverse comparator used consistently is legitimate - it simply flips the order
/// (`head` then returns the largest key). In tests, call `is_well_formed_by!(&map, lt)`
/// after `_by` sequences to catch comparator mistakes.
///
/// # Aborts
///
/// Four operations abort; everything else is total (returns `Option`/`bool`/`vector`):
/// `borrow`/`borrow_mut` (`EKeyNotFound`), `destroy_empty` (`ENotEmpty`), `pop_front`/
/// `pop_back` (`EEmpty`), and the forced-public `split_off` (`EBadSplit`, an out-of-range
/// bounds guard - not part of the supported total API). All aborts originate in this
/// module, so consumer `#[expected_failure]` tests must pin
/// `location = openzeppelin_sorted_map::sorted_map`.
///
/// # Library internals are forced-public
///
/// Move 2024 macro hygiene requires every symbol a macro body references to be `public`
/// at the consumer's expansion site, so `search!`, `insert_at`, `remove_at`,
/// `make_entry`, `entry_key`, etc. - plus the bulk primitives `split_off`/`append` (added
/// for the `big_sorted_map` sibling) - are `public`. They are NOT a supported mutation
/// API. In particular `insert_at`/`remove_at`/`append` write at a caller-given position
/// with no order check, and `split_off` aborts `EBadSplit` on an out-of-range index -
/// calling them directly can corrupt sorted order. Use the macro API.
///
/// # Upgrade policy
///
/// The on-chain struct layout is frozen at first publish by Sui's upgrade-compatibility
/// checker. There is deliberately no `version` field: on a frozen-layout embedded value
/// it could only ever hold its initial constant. A future layout change ships as a
/// parallel `SortedMapV2` with consumer-driven migration - never an in-place edit, which
/// would break BCS deserialization of every downstream object embedding the old layout.
module openzeppelin_sorted_map::sorted_map;

// === Errors ===

/// A key was not present in the map. Raised by `borrow`/`borrow_mut`.
#[error(code = 0)]
const EKeyNotFound: vector<u8> = "Key not found";

/// `destroy_empty` was called on a non-empty map.
#[error(code = 1)]
const ENotEmpty: vector<u8> = "Map is not empty";

/// `pop_front`/`pop_back` was called on an empty map.
#[error(code = 2)]
const EEmpty: vector<u8> = "Map is empty";

/// `split_off` was called with `at > length`. A bounds guard only, not an order check.
/// Unreachable via correct `big_sorted_map` operation; ships as a defensive guard for
/// direct misuse of the forced-public surface, pinning the abort at this module.
#[error(code = 3)]
const EBadSplit: vector<u8> = "Split index out of bounds";

// === Structs ===

/// One key-value pair, stored inline in the map's vector.
///
/// The fields are module-private: outside this module an `Entry` is read only via
/// `entry_key`/`entry_value` and built only via `make_entry`. No `&mut Entry` is ever
/// exposed, so a key cannot be mutated in place and can never desync from its sorted
/// position.
///
/// Abilities materialize jointly over `K` and `V`: `Entry<u64, u64>` is `copy + drop +
/// store`, while `Entry<u64, Coin<T>>` is store-only.
public struct Entry<K: copy + drop + store, V: store> has copy, drop, store {
    key: K,
    value: V,
}

/// A map kept sorted by key, backed by one contiguous `vector<Entry<K, V>>`.
///
/// A pure value - no `UID`, no dynamic fields - so it embeds directly in an integrator's
/// object, exactly like `sui::vec_map::VecMap`. `copy`/`drop` materialize only when both
/// `K` and `V` allow them: `SortedMap<u64, u64>` is `copy + drop + store`;
/// `SortedMap<u64, Coin<T>>` is store-only and must be drained then `destroy_empty`'d.
///
/// Across every public operation, `entries` is strictly increasing under the
/// (consistently supplied) comparator: sorted, with no duplicate keys.
public struct SortedMap<K: copy + drop + store, V: store> has copy, drop, store {
    entries: vector<Entry<K, V>>,
}

// === Public Functions ===

// === Lifecycle ===

/// Create a new, empty map. Takes no `&mut TxContext`: a `SortedMap` is a value, not an
/// object.
public fun new<K: copy + drop + store, V: store>(): SortedMap<K, V> {
    SortedMap { entries: vector[] }
}

/// Destroy an empty map.
///
/// This is the only terminal for a map whose value type lacks `drop` (e.g.
/// `SortedMap<K, Coin<T>>`): drain every value via `remove`/`pop_*` first, then call
/// this. The assert runs before the inner `vector::destroy_empty`, so a non-empty map
/// surfaces `ENotEmpty` at this module's location rather than a lower-level abort.
///
/// #### Aborts
/// - `ENotEmpty` if the map still holds entries.
public fun destroy_empty<K: copy + drop + store, V: store>(map: SortedMap<K, V>) {
    let SortedMap { entries } = map;
    assert!(entries.is_empty(), ENotEmpty);
    entries.destroy_empty();
}

// === Size and bounds (no comparator) ===

/// Number of entries.
public fun length<K: copy + drop + store, V: store>(map: &SortedMap<K, V>): u64 {
    map.entries.length()
}

/// True iff the map holds no entries.
public fun is_empty<K: copy + drop + store, V: store>(map: &SortedMap<K, V>): bool {
    map.entries.is_empty()
}

/// Smallest key under the comparator, or `none` if empty. O(1). With a reverse
/// comparator this returns the largest numeric key.
public fun head<K: copy + drop + store, V: store>(map: &SortedMap<K, V>): Option<K> {
    if (map.entries.is_empty()) option::none() else option::some(map.entries.borrow(0).key)
}

/// Largest key under the comparator, or `none` if empty. O(1).
public fun tail<K: copy + drop + store, V: store>(map: &SortedMap<K, V>): Option<K> {
    let n = map.entries.length();
    if (n == 0) option::none() else option::some(map.entries.borrow(n - 1).key)
}

// === Macro-internal accessors and search (forced-public; NOT a supported API) ===
//
// Everything in this section is `public` ONLY because Move 2024 macro hygiene requires
// every symbol a macro body references to be public at the consumer's expansion site.
// In particular `insert_at`/`remove_at` write at a caller-given index with no ordering
// check, so calling them directly can corrupt sorted order. Use the macro API
// (`insert!`, `remove!`, ...) instead.

/// Immutable view of the backing vector. There is deliberately no `&mut`/owning
/// counterpart, so bulk reordering or bulk value-destruction is unrepresentable through
/// this surface.
public fun entries_ref<K: copy + drop + store, V: store>(
    map: &SortedMap<K, V>,
): &vector<Entry<K, V>> {
    &map.entries
}

/// Borrow an entry's key. Macro bodies must read keys through this (not `.key`), since
/// the field is private at the expansion site.
public fun entry_key<K: copy + drop + store, V: store>(e: &Entry<K, V>): &K {
    &e.key
}

/// Borrow an entry's value.
public fun entry_value<K: copy + drop + store, V: store>(e: &Entry<K, V>): &V {
    &e.value
}

/// Construct an entry, consuming `key` and `value` by move (no copy, no implicit drop).
/// Harmless until fed to `insert_at`.
public fun make_entry<K: copy + drop + store, V: store>(key: K, value: V): Entry<K, V> {
    Entry { key, value }
}

/// Insert `e` at index `i`, shifting later entries right. Order-corruption surface: a
/// non-sorted `i` leaves the vector unsorted.
///
/// #### Parameters
/// - `i`: Insertion index.
///
/// #### Aborts
/// - Native out-of-bounds abort inside `std::vector` if `i > length`.
public fun insert_at<K: copy + drop + store, V: store>(
    map: &mut SortedMap<K, V>,
    i: u64,
    e: Entry<K, V>,
) {
    map.entries.insert(e, i);
}

/// Remove the entry at index `i`, shifting later entries left, and return its value. The
/// key is dropped; the value is moved out and returned, so no value is lost.
/// Order-corruption surface if `i` is wrong.
///
/// #### Returns
/// - The value at index `i`.
///
/// #### Aborts
/// - Native out-of-bounds abort inside `std::vector` if `i >= length`.
public fun remove_at<K: copy + drop + store, V: store>(map: &mut SortedMap<K, V>, i: u64): V {
    let Entry { key: _, value } = map.entries.remove(i);
    value
}

/// Borrow the value at index `i` (read-only).
///
/// #### Aborts
/// - Native out-of-bounds abort inside `std::vector` if `i >= length`.
public fun value_at<K: copy + drop + store, V: store>(map: &SortedMap<K, V>, i: u64): &V {
    &map.entries.borrow(i).value
}

/// Mutably borrow the value at index `i`. Yields `&mut V`, never `&mut Entry`, so the key
/// stays unreachable for in-place mutation and value mutation is order-safe.
///
/// #### Aborts
/// - Native out-of-bounds abort inside `std::vector` if `i >= length`.
public fun value_at_mut<K: copy + drop + store, V: store>(
    map: &mut SortedMap<K, V>,
    i: u64,
): &mut V {
    &mut map.entries.borrow_mut(i).value
}

/// Borrow the key at index `i` (read-only).
///
/// #### Aborts
/// - Native out-of-bounds abort inside `std::vector` if `i >= length`.
public fun key_at<K: copy + drop + store, V: store>(map: &SortedMap<K, V>, i: u64): &K {
    &map.entries.borrow(i).key
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

/// Binary search for `target` under `$lt`.
///
/// #### Parameters
/// - `target`: Key to locate.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - `(true, idx)` when `entries[idx].key` equals `target` (derived: neither
///   `lt(k, t)` nor `lt(t, k)`); the match is unique under strict ordering.
/// - `(false, idx)` when absent, where `idx` is the lower-bound insertion point - the
///   number of keys strictly less than `target`, in `[0, n]`.
public macro fun search<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $target: &$K,
    $lt: |&$K, &$K| -> bool,
): (bool, u64) {
    let map = $map;
    let target = $target;
    let es = entries_ref(map);
    let n = es.length();
    let mut lo = 0;
    let mut hi = n;
    let mut found = false;
    let mut idx = n;
    while (lo < hi) {
        let mid = lo + (hi - lo) / 2;
        let mk = entry_key(es.borrow(mid));
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

// === Bulk / structural primitives (forced-public; NOT a supported API) ===
//
// These two move-only, comparator-free functions exist to serve the `big_sorted_map`
// sibling package, whose B+Tree node payload IS a `SortedMap`. Splitting and merging
// tree nodes are positional operations (the affected index is known structurally), so
// threading a comparator would be dead weight. They are `public` (not `public(package)`)
// only because that sibling is a separate package.
//
// Like `insert_at`/`remove_at`, they are an order-corruption surface: each has a
// structural precondition this module does NOT check. Used outside their preconditions
// they silently break strict sorted order. Use the macro API for ordinary operations.

/// Split `self` at index `at`: entries `[at, len)` are MOVED into a fresh returned map
/// (relative order preserved), `self` retains `[0, at)`. O(len - at): pops the suffix off
/// the back (O(1) each) then reverses once - no value is copied or dropped, so it is safe
/// for a non-`drop` `V` (e.g. `Coin`). Caller precondition (unchecked): `self` is sorted,
/// so both halves come out sorted and every retained key < every returned key.
///
/// #### Parameters
/// - `at`: Split index; `at == len` is valid and yields an empty result.
///
/// #### Returns
/// - A new map owning entries `[at, len)`.
///
/// #### Aborts
/// - `EBadSplit` if `at > len`.
public fun split_off<K: copy + drop + store, V: store>(
    self: &mut SortedMap<K, V>,
    at: u64,
): SortedMap<K, V> {
    let n = self.entries.length();
    assert!(at <= n, EBadSplit);
    let mut suffix = vector[];
    while (self.entries.length() > at) {
        suffix.push_back(self.entries.pop_back());
    };
    suffix.reverse();
    SortedMap { entries: suffix }
}

/// Move-concatenate `other` onto the end of `self`, consuming `other` entirely. Every
/// entry (hence every `V`) is moved, nothing copied or dropped, so it is correct for a
/// non-`drop` `V`. The `V: store` bound deliberately omits `V: drop` (a `drop` bound
/// would let an overwrite silently burn a value). Caller precondition (unchecked):
/// `other` is disjoint from and strictly after `self` (`self.tail < other.head`), so the
/// result stays sorted. The adjacent-sibling merge in `big_sorted_map` guarantees this by
/// construction; there is no defensive re-check (it would require a comparator).
public fun append<K: copy + drop + store, V: store>(
    self: &mut SortedMap<K, V>,
    other: SortedMap<K, V>,
) {
    let SortedMap { entries } = other;
    self.entries.append(entries);
}

// === Point access (macros: bare + `_by`) ===

/// True iff `key` is present, under `$lt`. Pure, total read: agrees exactly with `borrow`
/// succeeding, since both route through `search!`.
///
/// #### Parameters
/// - `key`: Key to test.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - `true` iff `key` is present.
public macro fun contains_by<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): bool {
    let map = $map;
    let (found, _idx) = search!(map, $key, $lt);
    found
}

/// `contains_by` with the built-in integer `<`.
public macro fun contains<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
): bool {
    contains_by!($map, $key, |a, b| *a < *b)
}

/// Immutable borrow of `key`'s value, under `$lt`. `assert_key_found` runs before the
/// indexed read: on a miss `idx` is the insertion point, so reading it first would
/// silently return the successor's value (or abort out-of-bounds at `idx == n`).
///
/// #### Parameters
/// - `key`: Key to look up.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - Reference to `key`'s value.
///
/// #### Aborts
/// - `EKeyNotFound` if `key` is absent.
public macro fun borrow_by<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): &$V {
    let map = $map;
    let (found, idx) = search!(map, $key, $lt);
    assert_key_found(found);
    value_at(map, idx)
}

/// `borrow_by` with the built-in integer `<`.
///
/// #### Aborts
/// - `EKeyNotFound` if `key` is absent.
public macro fun borrow<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
): &$V {
    borrow_by!($map, $key, |a, b| *a < *b)
}

/// Mutable borrow of `key`'s value, under `$lt`. Yields `&mut V`, never `&mut Entry`, so
/// the key cannot be desynced from its sorted position.
///
/// #### Parameters
/// - `key`: Key to look up.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - Mutable reference to `key`'s value.
///
/// #### Aborts
/// - `EKeyNotFound` if `key` is absent.
public macro fun borrow_mut_by<$K: copy + drop + store, $V: store>(
    $map: &mut SortedMap<$K, $V>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): &mut $V {
    let map = $map;
    let (found, idx) = search!(map, $key, $lt);
    assert_key_found(found);
    value_at_mut(map, idx)
}

/// `borrow_mut_by` with the built-in integer `<`.
///
/// #### Aborts
/// - `EKeyNotFound` if `key` is absent.
public macro fun borrow_mut<$K: copy + drop + store, $V: store>(
    $map: &mut SortedMap<$K, $V>,
    $key: &$K,
): &mut $V {
    borrow_mut_by!($map, $key, |a, b| *a < *b)
}

/// Upsert: insert `key`/`value`, or replace the value if `key` is already present, under
/// `$lt`.
///
/// On replace it extracts the old value via `remove_at` and reinserts a fresh entry at
/// the same index - storing the new key bytes and returning the displaced value rather
/// than dropping it. This is deliberately NOT `*value_at_mut(..) = value`, which would
/// drop the old value (requires `V: drop`) and silently destroy a `Coin`.
///
/// #### Parameters
/// - `key`: Key to insert or update.
/// - `value`: Value to store.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - `some(old)` on replace (length unchanged), `none` on a fresh insert (length + 1).
public macro fun insert_by<$K: copy + drop + store, $V: store>(
    $map: &mut SortedMap<$K, $V>,
    $key: $K,
    $value: $V,
    $lt: |&$K, &$K| -> bool,
): Option<$V> {
    let map = $map;
    let key = $key;
    let value = $value;
    let (found, idx) = search!(map, &key, $lt);
    if (found) {
        let old = remove_at(map, idx);
        insert_at(map, idx, make_entry(key, value));
        option::some(old)
    } else {
        insert_at(map, idx, make_entry(key, value));
        option::none()
    }
}

/// `insert_by` with the built-in integer `<`.
///
/// #### Returns
/// - `some(old)` on replace, `none` on a fresh insert.
public macro fun insert<$K: copy + drop + store, $V: store>(
    $map: &mut SortedMap<$K, $V>,
    $key: $K,
    $value: $V,
): Option<$V> {
    insert_by!($map, $key, $value, |a, b| *a < *b)
}

/// Remove `key`'s entry, under `$lt`. Total - never aborts. Uses a shifting
/// `vector::remove`, never `swap_remove`, which would break strict order.
///
/// #### Parameters
/// - `key`: Key to remove.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - `some(value)` if present (length - 1, order preserved), `none` if absent (map
///   unchanged).
public macro fun remove_by<$K: copy + drop + store, $V: store>(
    $map: &mut SortedMap<$K, $V>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): Option<$V> {
    let map = $map;
    let (found, idx) = search!(map, $key, $lt);
    if (found) option::some(remove_at(map, idx)) else option::none()
}

/// `remove_by` with the built-in integer `<`.
///
/// #### Returns
/// - `some(value)` if present, `none` if absent.
public macro fun remove<$K: copy + drop + store, $V: store>(
    $map: &mut SortedMap<$K, $V>,
    $key: &$K,
): Option<$V> {
    remove_by!($map, $key, |a, b| *a < *b)
}

// === Ordered navigation (macros: bare + `_by`) ===

/// Smallest key `>= key` when `include` (the ceiling), else smallest key `> key` (strict
/// next); `none` if there is no such key. Pure, total read. Any returned key satisfies
/// `contains`.
///
/// #### Parameters
/// - `key`: Reference key.
/// - `include`: Whether an exact match of `key` qualifies.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - The ceiling/strict-next key, or `none`.
public macro fun find_next_by<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
    $include: bool,
    $lt: |&$K, &$K| -> bool,
): Option<$K> {
    let map = $map;
    let include = $include;
    let (found, idx) = search!(map, $key, $lt);
    let es = entries_ref(map);
    let n = es.length();
    if (found) {
        if (include) {
            option::some(*entry_key(es.borrow(idx)))
        } else if (idx + 1 < n) {
            option::some(*entry_key(es.borrow(idx + 1)))
        } else {
            option::none()
        }
    } else if (idx < n) {
        // miss: idx is the insertion point = first key strictly greater than `key`,
        // which is the ceiling too (key is absent), so `include` doesn't matter here.
        option::some(*entry_key(es.borrow(idx)))
    } else {
        option::none()
    }
}

/// `find_next_by` with the built-in integer `<`.
///
/// #### Returns
/// - The ceiling/strict-next key, or `none`.
public macro fun find_next<$K: copy + drop + store, $V: store>(
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
/// - `key`: Reference key.
/// - `include`: Whether an exact match of `key` qualifies.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - The floor/strict-prev key, or `none`.
public macro fun find_prev_by<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
    $include: bool,
    $lt: |&$K, &$K| -> bool,
): Option<$K> {
    let map = $map;
    let include = $include;
    let (found, idx) = search!(map, $key, $lt);
    let es = entries_ref(map);
    if (found) {
        if (include) {
            option::some(*entry_key(es.borrow(idx)))
        } else if (idx > 0) {
            option::some(*entry_key(es.borrow(idx - 1)))
        } else {
            option::none()
        }
    } else if (idx > 0) {
        // miss: idx is the insertion point, so idx-1 is the last key strictly less than
        // `key` - the floor too (key is absent), so `include` doesn't matter here.
        option::some(*entry_key(es.borrow(idx - 1)))
    } else {
        option::none()
    }
}

/// `find_prev_by` with the built-in integer `<`.
///
/// #### Returns
/// - The floor/strict-prev key, or `none`.
public macro fun find_prev<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
    $include: bool,
): Option<$K> {
    find_prev_by!($map, $key, $include, |a, b| *a < *b)
}

/// Smallest key strictly greater than `key`, or `none`. Sugar for
/// `find_next_by(.., false)`. `next_key(tail) == none` is the forward-cursor termination
/// signal.
public macro fun next_key_by<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): Option<$K> {
    find_next_by!($map, $key, false, $lt)
}

/// `next_key_by` with the built-in integer `<`.
public macro fun next_key<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
): Option<$K> {
    find_next_by!($map, $key, false, |a, b| *a < *b)
}

/// Largest key strictly less than `key`, or `none`. Sugar for
/// `find_prev_by(.., false)`. `prev_key(head) == none` is the backward-cursor termination
/// signal.
public macro fun prev_key_by<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): Option<$K> {
    find_prev_by!($map, $key, false, $lt)
}

/// `prev_key_by` with the built-in integer `<`.
public macro fun prev_key<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $key: &$K,
): Option<$K> {
    find_prev_by!($map, $key, false, |a, b| *a < *b)
}

// === Bounded iteration / pagination (macros: bare + `_by`) ===

/// Up to `limit` keys in strict ascending order, a contiguous run starting at the first
/// key `>= from` (when `include`) or `> from` (strict). Returns at most `limit` keys;
/// fewer if the tail is reached. Pure, total read.
///
/// Resume a page by passing the last returned key back as `from` with `include == false`:
/// successive pages have no overlap and no gap, so concatenating them reconstructs the
/// tail exactly. `limit == 0`, an empty map, or `from` past the tail all yield the empty
/// vector. The walk is bounded by `out.length() < limit`, never `i < start + limit` - the
/// latter would overflow when `limit` is near `u64::MAX`.
///
/// #### Parameters
/// - `from`: Lower-bound key.
/// - `include`: Whether an exact match of `from` is included.
/// - `limit`: Maximum number of keys to return.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - Up to `limit` keys in ascending order.
public macro fun keys_from_by<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $from: &$K,
    $include: bool,
    $limit: u64,
    $lt: |&$K, &$K| -> bool,
): vector<$K> {
    let map = $map;
    let include = $include;
    let limit = $limit;
    let (found, idx) = search!(map, $from, $lt);
    // First qualifying index = the insertion point, skipping an exact hit only when the
    // boundary is exclusive. On a miss `idx` is already the first key > from (the
    // ceiling), so `include` does not shift it.
    let start = if (found && !include) idx + 1 else idx;
    let es = entries_ref(map);
    let n = es.length();
    let mut out = vector[];
    let mut i = start;
    while (i < n && out.length() < limit) {
        out.push_back(*entry_key(es.borrow(i)));
        i = i + 1;
    };
    out
}

/// `keys_from_by` with the built-in integer `<`.
///
/// #### Returns
/// - Up to `limit` keys in ascending order.
public macro fun keys_from<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $from: &$K,
    $include: bool,
    $limit: u64,
): vector<$K> {
    keys_from_by!($map, $from, $include, $limit, |a, b| *a < *b)
}

// === Pop extremes (regular funs; abort EEmpty) ===

/// Remove and return the smallest entry `(key, value)`. Length - 1.
///
/// Returns `(K, V)`, not `Option<(K, V)>`: a tuple cannot be a generic type argument in
/// Move, so emptiness is signalled by a runtime abort rather than an `Option`. The empty
/// check is the first statement - otherwise `remove(0)` on an empty vector would abort
/// with a foreign out-of-bounds code instead of the named `EEmpty`.
///
/// #### Returns
/// - The smallest `(key, value)` pair.
///
/// #### Aborts
/// - `EEmpty` if the map is empty.
public fun pop_front<K: copy + drop + store, V: store>(map: &mut SortedMap<K, V>): (K, V) {
    assert!(!is_empty(map), EEmpty);
    let Entry { key, value } = map.entries.remove(0);
    (key, value)
}

/// Remove and return the largest entry `(key, value)`. Length - 1.
///
/// The empty check is first so `n - 1` cannot underflow at `n == 0`.
///
/// #### Returns
/// - The largest `(key, value)` pair.
///
/// #### Aborts
/// - `EEmpty` if the map is empty.
public fun pop_back<K: copy + drop + store, V: store>(map: &mut SortedMap<K, V>): (K, V) {
    assert!(!is_empty(map), EEmpty);
    let n = map.entries.length();
    let Entry { key, value } = map.entries.remove(n - 1);
    (key, value)
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
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - `true` iff the map is strictly increasing under `lt`.
#[test_only]
public macro fun is_well_formed_by<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
    $lt: |&$K, &$K| -> bool,
): bool {
    let map = $map;
    let es = entries_ref(map);
    let n = es.length();
    let mut ok = true;
    let mut i = 1;
    while (i < n) {
        if (!$lt(entry_key(es.borrow(i - 1)), entry_key(es.borrow(i)))) {
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
public macro fun is_well_formed<$K: copy + drop + store, $V: store>(
    $map: &SortedMap<$K, $V>,
): bool {
    is_well_formed_by!($map, |a, b| *a < *b)
}

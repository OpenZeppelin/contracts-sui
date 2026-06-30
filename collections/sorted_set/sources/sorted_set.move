/// A generic, ordered set of unique keys - the gap `sui::vec_set` leaves (`vec_set` is
/// unordered and hash-keyed). Iterates in comparator order.
///
/// `SortedSet<K>` is a thin wrapper over `SortedMap<K, Unit>` (`Unit` is an empty marker
/// struct): a set is a map whose values carry no information, exactly as `BTreeSet<K> =
/// BTreeMap<K, ()>` in Rust. It is a UID-less value type (shaped like `sui::vec_set::
/// VecSet`): no object identity, no dynamic fields - every key lives inline in one vector
/// inside the wrapped map. Embed it directly in your own object:
/// ```
/// public struct Watchlist has key { id: UID, ids: SortedSet<u64> }
/// ```
/// A bare `SortedSet` cannot be `transfer`/`share`d (it is not `key`); wrap it in your
/// own `has key` object to get owned or shared semantics.
///
/// # Abilities
///
/// Unlike `SortedMap` - which is `copy`/`drop` only when its value type allows - a
/// `SortedSet<K>` is unconditionally `copy + drop + store` (the value is always the
/// trivial `Unit`). So there is no resource-valued set and no `destroy_empty` terminal: a
/// set simply falls out of scope. A copy is a deep, independent snapshot - mutating the
/// copy never touches the original.
///
/// # Comparator contract (read this)
///
/// Inherited verbatim from `SortedMap`. The set stores no comparator. Order is defined per
/// call by a strict less-than `|&K, &K| -> bool` you supply; equality is derived as
/// `!lt(a, b) && !lt(b, a)`, so membership is under the comparator, not byte-identity.
/// Each comparator-needing operation comes in two forms:
/// - bare (`insert!`, `contains!`, ...) assumes the built-in integer `<`; valid only for
///   integer keys (`u8`..`u256`).
/// - `_by` (`insert_by!`, `contains_by!`, ...) takes the `lt` lambda; required for
///   non-integer keys (`address`, structs, ...).
///
/// The comparator MUST be a strict total order and MUST be threaded consistently to every
/// call on a given set. The library cannot detect a violation; the failure is silent (a
/// desorted set returns wrong membership answers). Unlike the map, the worst case is
/// order-only - no value can ever be lost (the value is `Unit`). A reverse comparator used
/// consistently is legitimate (`head` then returns the largest key). Under a coarse
/// (non-injective) `_by` comparator, byte-distinct keys that compare equal collapse to one
/// element keeping the last inserted key's bytes - so first-seen gating on `insert!`'s bool
/// is well-defined only under an injective comparator. In tests, call
/// `sorted_map::is_well_formed_by!(inner_ref(&set), lt)` after `_by` sequences.
///
/// # `insert`/`remove` return `bool` - they do NOT abort on duplicates
///
/// Deliberate divergence from `sui::vec_set` (whose `insert`/`remove` abort). `insert! ->
/// true` iff the key was newly added; `remove! -> true` iff it was present. This matches
/// the wrapped map's total upsert, keeps the API composable mid-PTB, and is strictly more
/// general: to get vec_set's abort-on-duplicate, write `assert!(insert!(&mut s, k), E)`.
/// `from_keys` likewise de-duplicates rather than aborting; to reject duplicates, build
/// then `assert!(length(&s) == n, E)` where `n` is the input length.
///
/// # Aborts
///
/// Exactly ONE operation aborts; everything else is total (returns `Option`/`bool`/
/// `vector`/`u64`): `pop_front`/`pop_back` (`EEmpty`). The assert fires at THIS module's
/// location, so consumer `#[expected_failure]` tests must pin `location =
/// openzeppelin_sorted_set::sorted_set`. (The wrapped map's own `EEmpty` is at the map's
/// location and is never reached through the set's own `pop_*`.)
///
/// # Library internals are forced-public
///
/// Move 2024 macro hygiene requires every symbol a macro body references to be `public` at
/// the consumer's expansion site, so `inner_ref`, `inner_mut`, and `unit` are `public`.
/// They are NOT a supported API. In particular `inner_mut` hands out
/// `&mut SortedMap<K, Unit>`: driving `sorted_map` ops on it directly with an inconsistent
/// comparator (or `insert_at`/`remove_at` at a wrong index) can corrupt this set's order.
/// Use the macro API. The corruption is order-only and local to that one set - no value is
/// ever lost.
///
/// # Upgrade policy
///
/// The on-chain struct layout of `SortedSet` and of `Unit` is frozen at first publish by
/// Sui's upgrade-compatibility checker. There is deliberately no `version` field. `Unit`
/// must stay a zero-field empty struct (1 BCS byte); adding a field would break BCS
/// deserialization of every downstream object and shrink the capacity ceiling. A future
/// layout change ships as a parallel `SortedSetV2` with consumer-driven migration. The set
/// also transitively depends on the `openzeppelin_sorted_map` package's frozen layout.
module openzeppelin_sorted_set::sorted_set;

use openzeppelin_sorted_map::sorted_map::{Self, SortedMap};

// === Errors ===

/// `pop_front`/`pop_back` was called on an empty set. The only abort in this library,
/// asserted at this module's location - distinct from the wrapped map's `EEmpty`.
#[error(code = 0)]
const EEmpty: vector<u8> = "Set is empty";

// === Structs ===

/// Internal membership marker so a set can reuse `SortedMap<K, Unit>`. A zero-field empty
/// struct carrying no data - it serializes to 1 BCS byte, has nothing to read or
/// destructure, and is the correct "no value" marker for a set (`set = map<K, ()>`).
///
/// `public` only because it appears in the forced-public accessors' signatures (macro
/// hygiene). Consumers never construct it (`unit()` does, internally) or read it. Declared
/// `copy, drop, store` so the value conjunction of `SortedMap<K, Unit>` collapses onto `K`
/// alone, making `SortedSet<K>` unconditionally `copy + drop + store`.
public struct Unit has copy, drop, store {}

/// An ordered set of unique keys, backed by one sorted vector via `SortedMap<K, Unit>`.
///
/// A pure value - no `UID`, no dynamic fields - so it embeds directly in an integrator's
/// object, exactly like `sui::vec_set::VecSet`. Because the value is always the
/// `copy + drop + store` `Unit`, `SortedSet<K>` is unconditionally `copy + drop + store`
/// for any admissible `K` - there is no store-only set analogous to `SortedMap<K, Coin<T>>`.
///
/// Across every public operation, by delegation to the inner map, the keys are strictly
/// increasing under the (consistently supplied) comparator: sorted, no duplicates.
public struct SortedSet<K: copy + drop + store> has copy, drop, store {
    inner: SortedMap<K, Unit>,
}

// === Public Functions ===

// === Macro-internal accessors (forced-public; NOT a supported API) ===
//
// These three items are `public` ONLY because Move 2024 macro hygiene requires every
// symbol a macro body references to be public at the consumer's expansion site. They are
// NOT a supported mutation API. `inner_mut` in particular lets a caller drive the wrapped
// map directly with an inconsistent comparator or a wrong index and desort this set -
// order-only corruption, local to that one set, no value ever lost. Use the macro API
// (`insert!`, `remove!`, ...) instead.

/// Immutable view of the wrapped map - what read macros (`contains!`, `find_*!`,
/// `keys_from!`) expand against. Read-only: cannot be upgraded to `&mut`. Also the test
/// order-check handle: `sorted_map::is_well_formed!(inner_ref(&set))`.
public fun inner_ref<K: copy + drop + store>(set: &SortedSet<K>): &SortedMap<K, Unit> {
    &set.inner
}

/// Mutable view of the wrapped map - what write macros (`insert!`, `remove!`) expand
/// against. Order-corruption surface: see the module header. Obtaining it requires
/// `&mut SortedSet` (hence `&mut` on the enclosing object), so the consumer's reference
/// discipline still gates every write.
public fun inner_mut<K: copy + drop + store>(set: &mut SortedSet<K>): &mut SortedMap<K, Unit> {
    &mut set.inner
}

/// Construct the membership marker. Forced public because set macros build it at the
/// consumer's expansion site (`Unit {}` won't compile at a foreign site). The returned
/// `Unit` is inert - there is no set op that accepts a value, so a consumer-held `Unit`
/// can never be threaded into a set.
public fun unit(): Unit {
    Unit {}
}

// === Lifecycle ===

/// Create a new, empty set. Takes no `&mut TxContext`: a `SortedSet` is a value, not an
/// object. `length` is 0 and `is_empty` is true.
public fun new<K: copy + drop + store>(): SortedSet<K> {
    SortedSet { inner: sorted_map::new() }
}

/// A set containing exactly the one given key. Needs no comparator: a single element is
/// trivially sorted, so it is placed at index 0 of the (empty) backing vector - the one
/// provably order-safe direct `insert_at` the set performs.
///
/// #### Parameters
/// - `key`: The sole member of the new set.
///
/// #### Returns
/// - A one-element set.
public fun singleton<K: copy + drop + store>(key: K): SortedSet<K> {
    let mut set = new();
    set.inner.insert_at(0, sorted_map::make_entry(key, unit()));
    set
}

/// Build a set from a vector of keys by idempotent insertion, under `$lt`. Duplicates are
/// silently collapsed - the result holds each distinct key once, in comparator order, so
/// `length(result)` is the number of distinct keys, NOT the input length. This diverges
/// from `sui::vec_set::from_keys`, which aborts on a duplicate; to reject duplicates
/// instead, build then `assert!(length(&s) == keys.length(), E)`.
///
/// Under a coarse `_by` comparator, byte-distinct compare-equal keys collapse to one
/// element keeping the last one's bytes. Drives the inserts via a `do!` loop body (one
/// reused expansion), never a straight-line sequence, to stay under Move's locals limit.
///
/// #### Parameters
/// - `keys`: Keys to insert; duplicates are collapsed.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - A set of the distinct keys, in comparator order.
public macro fun from_keys_by<$K: copy + drop + store>(
    $keys: vector<$K>,
    $lt: |&$K, &$K| -> bool,
): SortedSet<$K> {
    let keys = $keys;
    let mut set = new();
    keys.do!(|k| { insert_by!(&mut set, k, $lt); });
    set
}

/// `from_keys_by` with the built-in integer `<`. De-duplicates - see `from_keys_by`.
///
/// #### Returns
/// - A set of the distinct keys, in ascending order.
public macro fun from_keys<$K: copy + drop + store>($keys: vector<$K>): SortedSet<$K> {
    from_keys_by!($keys, |a, b| *a < *b)
}

// === Size and bounds (regular funs, no comparator) ===

/// Number of distinct keys.
public fun length<K: copy + drop + store>(set: &SortedSet<K>): u64 {
    set.inner.length()
}

/// True iff the set holds no keys.
public fun is_empty<K: copy + drop + store>(set: &SortedSet<K>): bool {
    set.inner.is_empty()
}

/// Smallest key under the comparator, or `none` if empty. O(1). With a reverse comparator
/// this is the largest numeric key.
public fun head<K: copy + drop + store>(set: &SortedSet<K>): Option<K> {
    set.inner.head()
}

/// Largest key under the comparator, or `none` if empty. O(1).
public fun tail<K: copy + drop + store>(set: &SortedSet<K>): Option<K> {
    set.inner.tail()
}

// === Pop extremes (regular funs; abort EEmpty) ===

/// Remove and return the smallest key. Length - 1.
///
/// The set's own `EEmpty` is asserted FIRST, before delegating, so an empty-set pop aborts
/// at THIS module's location - the wrapped map's `EEmpty` is never reached through here.
/// The map returns `(K, Unit)`; the marker is dropped and only `K` is returned.
///
/// #### Returns
/// - The smallest key.
///
/// #### Aborts
/// - `EEmpty` if the set is empty.
public fun pop_front<K: copy + drop + store>(set: &mut SortedSet<K>): K {
    assert!(!is_empty(set), EEmpty);
    let (key, _unit) = set.inner.pop_front();
    key
}

/// Remove and return the largest key. Length - 1. Set-owned `EEmpty` asserted first;
/// marker dropped.
///
/// #### Returns
/// - The largest key.
///
/// #### Aborts
/// - `EEmpty` if the set is empty.
public fun pop_back<K: copy + drop + store>(set: &mut SortedSet<K>): K {
    assert!(!is_empty(set), EEmpty);
    let (key, _unit) = set.inner.pop_back();
    key
}

// === All keys (regular fun, no comparator) ===

/// ALL keys in strict ascending (comparator) order as an owned `vector<K>` - sorted and
/// duplicate-free. NOT a reference: the set stores `Entry<K, Unit>`, so there is no
/// `vector<K>` to borrow (contrast `vec_set::keys`); each key is copied out.
///
/// O(N) in output size with no `limit` - the one read whose result scales with N. For
/// large or near-ceiling sets, prefer the paged `keys_from!`.
///
/// #### Returns
/// - Every key, in ascending comparator order.
public fun keys<K: copy + drop + store>(set: &SortedSet<K>): vector<K> {
    let entries = set.inner.entries_ref();
    vector::tabulate!(entries.length(), |i| *entries.borrow(i).entry_key())
}

// === Membership (macros: bare + `_by`) ===

/// True iff `key` is present, under `$lt`. Pure, total read. Routes through the same
/// `search!` (via the map's `contains_by!`) that `insert!`/`remove!` route through, so the
/// three never disagree.
///
/// #### Parameters
/// - `key`: Key to test.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - `true` iff `key` is present.
public macro fun contains_by<$K: copy + drop + store>(
    $set: &SortedSet<$K>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): bool {
    sorted_map::contains_by!(inner_ref($set), $key, $lt)
}

/// `contains_by` with the built-in integer `<`.
public macro fun contains<$K: copy + drop + store>($set: &SortedSet<$K>, $key: &$K): bool {
    contains_by!($set, $key, |a, b| *a < *b)
}

/// Insert `key`, under `$lt`. Idempotent and total (never aborts). On a fresh insert:
/// length + 1 and `contains!(key)` flips false -> true. On a duplicate: length unchanged,
/// key stays present. Diverges from `vec_set::insert` (which aborts on a duplicate); for
/// that behavior write `assert!(insert!(&mut s, k), E)`.
///
/// The returned bool is `insert_by!(...).is_none()` - the inner upsert returns `none`
/// exactly on a fresh insert. This is the opposite projection from `remove!`'s
/// `.is_some()`. The displaced marker (`some(Unit)` on a replace) is dropped.
///
/// #### Parameters
/// - `key`: Key to insert.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - `true` iff the key was newly added, `false` if it was already present.
public macro fun insert_by<$K: copy + drop + store>(
    $set: &mut SortedSet<$K>,
    $key: $K,
    $lt: |&$K, &$K| -> bool,
): bool {
    let set = $set;
    sorted_map::insert_by!(inner_mut(set), $key, unit(), $lt).is_none()
}

/// `insert_by` with the built-in integer `<`.
///
/// #### Returns
/// - `true` iff the key was newly added.
public macro fun insert<$K: copy + drop + store>($set: &mut SortedSet<$K>, $key: $K): bool {
    insert_by!($set, $key, |a, b| *a < *b)
}

/// Remove `key`, under `$lt`. Total, never aborts. On a hit: length - 1 and
/// `contains!(key)` flips true -> false. Diverges from `vec_set::remove` (which aborts when
/// absent); for that behavior write `assert!(remove!(&mut s, k), E)`.
///
/// The returned bool is `remove_by!(...).is_some()` - the inner remove returns `some(Unit)`
/// on a hit. This is the opposite projection from `insert!`'s `.is_none()`. The extracted
/// marker is dropped.
///
/// #### Parameters
/// - `key`: Key to remove.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - `true` iff the key was present, `false` if it was absent.
public macro fun remove_by<$K: copy + drop + store>(
    $set: &mut SortedSet<$K>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): bool {
    let set = $set;
    sorted_map::remove_by!(inner_mut(set), $key, $lt).is_some()
}

/// `remove_by` with the built-in integer `<`.
///
/// #### Returns
/// - `true` iff the key was present.
public macro fun remove<$K: copy + drop + store>($set: &mut SortedSet<$K>, $key: &$K): bool {
    remove_by!($set, $key, |a, b| *a < *b)
}

// === Ordered navigation (macros: bare + `_by`) ===

/// Smallest key `>= key` when `include` (the ceiling), else smallest key `> key` (strict
/// next); `none` if there is no such key. Pure, total read; any returned key satisfies
/// `contains!`.
///
/// #### Parameters
/// - `key`: Reference key.
/// - `include`: Whether an exact match of `key` qualifies.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - The ceiling/strict-next key, or `none`.
public macro fun find_next_by<$K: copy + drop + store>(
    $set: &SortedSet<$K>,
    $key: &$K,
    $include: bool,
    $lt: |&$K, &$K| -> bool,
): Option<$K> {
    sorted_map::find_next_by!(inner_ref($set), $key, $include, $lt)
}

/// `find_next_by` with the built-in integer `<`.
///
/// #### Returns
/// - The ceiling/strict-next key, or `none`.
public macro fun find_next<$K: copy + drop + store>(
    $set: &SortedSet<$K>,
    $key: &$K,
    $include: bool,
): Option<$K> {
    find_next_by!($set, $key, $include, |a, b| *a < *b)
}

/// Largest key `<= key` when `include` (the floor), else largest key `< key` (strict prev);
/// `none` if there is no such key. Pure, total read; any returned key satisfies `contains!`.
///
/// #### Parameters
/// - `key`: Reference key.
/// - `include`: Whether an exact match of `key` qualifies.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - The floor/strict-prev key, or `none`.
public macro fun find_prev_by<$K: copy + drop + store>(
    $set: &SortedSet<$K>,
    $key: &$K,
    $include: bool,
    $lt: |&$K, &$K| -> bool,
): Option<$K> {
    sorted_map::find_prev_by!(inner_ref($set), $key, $include, $lt)
}

/// `find_prev_by` with the built-in integer `<`.
///
/// #### Returns
/// - The floor/strict-prev key, or `none`.
public macro fun find_prev<$K: copy + drop + store>(
    $set: &SortedSet<$K>,
    $key: &$K,
    $include: bool,
): Option<$K> {
    find_prev_by!($set, $key, $include, |a, b| *a < *b)
}

/// Smallest key strictly greater than `key`, or `none`. Sugar for `find_next_by(.., false)`.
/// `next_key!(tail) == none` is the forward-cursor termination signal.
public macro fun next_key_by<$K: copy + drop + store>(
    $set: &SortedSet<$K>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): Option<$K> {
    find_next_by!($set, $key, false, $lt)
}

/// `next_key_by` with the built-in integer `<`.
public macro fun next_key<$K: copy + drop + store>($set: &SortedSet<$K>, $key: &$K): Option<$K> {
    find_next_by!($set, $key, false, |a, b| *a < *b)
}

/// Largest key strictly less than `key`, or `none`. Sugar for `find_prev_by(.., false)`.
/// `prev_key!(head) == none` is the backward-cursor termination signal.
public macro fun prev_key_by<$K: copy + drop + store>(
    $set: &SortedSet<$K>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): Option<$K> {
    find_prev_by!($set, $key, false, $lt)
}

/// `prev_key_by` with the built-in integer `<`.
public macro fun prev_key<$K: copy + drop + store>($set: &SortedSet<$K>, $key: &$K): Option<$K> {
    find_prev_by!($set, $key, false, |a, b| *a < *b)
}

// === Bounded iteration / pagination (macros: bare + `_by`) ===

/// Up to `limit` keys in strict ascending order - a contiguous run starting at the first
/// key `>= from` (when `include`) or `> from` (strict); fewer than `limit` only at the
/// tail. Resume a page by passing the last returned key back as `from` with `include ==
/// false`: successive pages have no overlap and no gap. `limit == 0`, an empty set, or
/// `from` past the tail all yield the empty vector.
///
/// #### Parameters
/// - `from`: Lower-bound key.
/// - `include`: Whether an exact match of `from` is included.
/// - `limit`: Maximum number of keys to return.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - Up to `limit` keys in ascending order.
public macro fun keys_from_by<$K: copy + drop + store>(
    $set: &SortedSet<$K>,
    $from: &$K,
    $include: bool,
    $limit: u64,
    $lt: |&$K, &$K| -> bool,
): vector<$K> {
    sorted_map::keys_from_by!(inner_ref($set), $from, $include, $limit, $lt)
}

/// `keys_from_by` with the built-in integer `<`.
///
/// #### Returns
/// - Up to `limit` keys in ascending order.
public macro fun keys_from<$K: copy + drop + store>(
    $set: &SortedSet<$K>,
    $from: &$K,
    $include: bool,
    $limit: u64,
): vector<$K> {
    keys_from_by!($set, $from, $include, $limit, |a, b| *a < *b)
}

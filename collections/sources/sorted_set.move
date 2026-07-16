/// A generic, ordered set of unique keys - the gap `sui::vec_set` leaves. Iterates in
/// comparator order.
///
/// `SortedSet<K>` is a thin wrapper over `SortedMap<K, Unit>`, where `Unit` is an empty marker:
/// a set is a map whose values carry no information, exactly as `BTreeSet<K> = BTreeMap<K, ()>`
/// in Rust. Like `sui::vec_set::VecSet` it is a UID-less value - no identity, no dynamic fields,
/// every key inline in one vector. A bare set is not `key`, so embed it in your own `has key`
/// object:
/// ```move
/// public struct Watchlist has key { id: UID, ids: SortedSet<u64> }
/// ```
///
/// # Essentials
///
/// - **A set is a `SortedMap<K, Unit>`.** Ordered, unique keys; the comparator rules below are
///   inherited from the map.
/// - **One comparator, threaded to every call.** Same rule as the map (see its header for why the
///   order isn't stored). A different or non-strict comparator silently desorts the set.
/// - **`upsert` returns `bool` and never aborts** on a duplicate key, unlike `sui::vec_set`;
///   `add!` is the strict counterpart that aborts on a duplicate, matching `sui::vec_set::insert`.
///   `remove!` aborts on an absent key, matching `sui::vec_set`.
/// - **Abilities follow `K`.** The value is always the `copy + drop + store` `Unit`, so
///   `SortedSet<K>` has exactly the abilities `K` does. A set of droppable keys just falls out of
///   scope; a set of non-`drop` keys (rare - e.g. a resource key) is itself non-`drop` and must be
///   drained then `destroy_empty`'d, exactly like `SortedMap<K, Coin<T>>`.
/// - **Five aborts:** `pop_front` / `pop_back` on an empty set (`EEmpty`), `remove!` on an absent
///   key (`sorted_map::EKeyNotFound`), `add!` / `add_by!` on a duplicate key
///   (`sorted_map::EKeyAlreadyExists`), `from_sorted_keys!` on unsorted input (`EKeysNotSorted`),
///   and `destroy_empty` on a non-empty set (`ENotEmpty`); every other supported op is total
///   provided the caller-supplied comparator does not itself abort.
///
/// # The comparator
///
/// Inherited from `SortedMap` - see that module's header for the full contract and for why the
/// order is a lambda you pass, not a stored value. You supply a strict total order, the same on
/// every call; the set stores none and cannot detect a violation. The worst case is milder than
/// the map's: a desorted set returns wrong membership answers, but no value is ever lost (the
/// value is `Unit`). A reverse comparator used consistently is fine, and `head` then returns the
/// largest numeric key.
///
/// A coarse (non-injective) comparator reports two byte-distinct keys as equal, collapsing them
/// to one element. On that collision the last-written key's bytes win (upsert overwrites the stored
/// key with the incoming one), so which byte-variant is retained is well-defined only under an
/// injective comparator. In tests, call
/// `sorted_map::is_well_formed_by!(inner(&set), lt)` after a `_by` sequence.
///
/// # `upsert` returns `bool`, not an abort
///
/// `upsert -> true` iff the key was newly added; this matches the wrapped map's `upsert`, stays
/// composable mid-PTB, and is strictly more general: for vec_set's abort-on-duplicate, call `add!`
/// (the strict insert) directly, or write `assert!(s.upsert!(k), E)`. `remove!`, by contrast,
/// aborts on an absent key like `sui::vec_set::remove`. `from_keys` likewise de-duplicates;
/// to reject duplicates instead, build then `assert!(length(&s) == n, E)`. `from_sorted_keys!`
/// de-duplicates the same way but needs pre-sorted input and runs in O(N) (see Complexity).
///
/// # Complexity and limits
///
/// Costs mirror `SortedMap`, which the set wraps: O(log N) membership, O(N) insert and remove, one
/// object loaded per call, and the same ~250 KB object-size ceiling. `pop_front` is O(N) - it
/// shifts every remaining key - while `pop_back` is O(1). `from_keys!` is O(N^2) in the worst
/// case: each upsert does a logarithmic search, then can shift a linear suffix.
/// `from_sorted_keys!` validates once and appends pre-sorted input, building in O(N).
///
/// The set's `_by` macros expand the map's `search!` inline. A single function with many distinct
/// macro calls can therefore hit Move's ~256 local-variable limit (compiler error `value (N)
/// cannot exceed (255)`) - split the function, or drive the calls from one reused loop body.
///
/// # Forced-public internals
///
/// Move 2024 macro hygiene requires every symbol a macro body references to be `public` at the
/// consumer's expansion site, so `inner`, `inner_mut`, `unit`, and `assert_sorted` are `public`.
/// They are not a supported API. In particular `inner_mut` hands out `&mut SortedMap<K, Unit>`:
/// driving map ops on it with an inconsistent comparator (or `insert_at` / `remove_at` at a wrong
/// index) can desort the set. Use the macro API. The corruption is order-only and local to that one
/// set - no value is ever lost.
///
/// # Upgrade compatibility
///
/// The on-chain layout of `SortedSet` and of `Unit` is frozen at first publish by Sui's upgrade
/// checker, and there is deliberately no `version` field. `Unit` must stay a zero-field empty
/// struct (1 BCS byte); adding a field would break BCS deserialization of every downstream object
/// and shrink the capacity ceiling. A future layout change ships as a parallel `SortedSetV2` with
/// consumer-driven migration. The set also depends on the sibling `sorted_map` module's frozen
/// layout.
module openzeppelin_collections::sorted_set;

use openzeppelin_collections::sorted_map::{Self, SortedMap};

// === Errors ===

/// `pop_front`/`pop_back` was called on an empty set. Asserted at this module's location -
/// distinct from the wrapped map's `EEmpty`.
#[error(code = 0)]
const EEmpty: vector<u8> = "Set is empty";

/// A sorted constructor (`from_sorted_keys`/`from_sorted_keys_by`) received keys that are not
/// sorted under the comparator - a strictly decreasing adjacent pair. Asserted at this module's
/// location.
#[error(code = 1)]
const EKeysNotSorted: vector<u8> = "Keys are not sorted";

/// `destroy_empty` was called on a set that still holds keys. Asserted at this module's location -
/// distinct from the wrapped map's `ENotEmpty`.
#[error(code = 2)]
const ENotEmpty: vector<u8> = "Set is not empty";

// === Structs ===

/// Internal membership marker so a set can reuse `SortedMap<K, Unit>`. A zero-field empty
/// struct carrying no data - it serializes to 1 BCS byte, has nothing to read or
/// destructure, and is the correct "no value" marker for a set (`set = map<K, ()>`).
///
/// `public` only because it appears in the forced-public accessors' signatures (macro
/// hygiene). Consumers never construct it (`unit()` does, internally) or read it. Declared
/// `copy, drop, store` so the value conjunction of `SortedMap<K, Unit>` collapses onto `K`
/// alone: `SortedSet<K>` then has exactly the abilities `K` does.
public struct Unit has copy, drop, store {}

/// An ordered set of unique keys, backed by one sorted vector via `SortedMap<K, Unit>`.
///
/// A pure value - no `UID`, no dynamic fields - so it embeds directly in an integrator's
/// object, exactly like `sui::vec_set::VecSet`. Because the value is always the
/// `copy + drop + store` `Unit`, `SortedSet<K>` has exactly the abilities `K` does:
/// with a `copy + drop + store` key it is `copy + drop + store`; with a non-`drop` (e.g.
/// resource) key it is store-only and must be `destroy_empty`'d, like `SortedMap<K, Coin<T>>`.
///
/// Across the supported macro API, by delegation to the inner map, the keys are strictly
/// increasing under the consistently supplied comparator: sorted, no duplicates. The
/// forced-public internals described above can bypass this guarantee and are not supported.
public struct SortedSet<K> has copy, drop, store {
    /// Backing map: every key is a set member; every value is the inert `Unit` marker.
    inner: SortedMap<K, Unit>,
}

// === Public Functions ===

// === Lifecycle ===

/// Create a new, empty set. Takes no `&mut TxContext`: a `SortedSet` is a value, not an
/// object. `length` is 0 and `is_empty` is true.
///
/// #### Returns
/// - An empty set.
public fun new<K>(): SortedSet<K> {
    SortedSet { inner: sorted_map::new() }
}

/// A set containing exactly the one given key.
///
/// #### Parameters
/// - `key`: The sole member of the new set.
///
/// #### Returns
/// - A one-element set.
public fun singleton<K>(key: K): SortedSet<K> {
    SortedSet { inner: sorted_map::singleton(key, Unit {}) }
}

/// Destroy an empty set.
///
/// Only needed when `K` lacks `drop` (e.g. a resource key): such a `SortedSet<K>` is itself
/// non-`drop` and cannot fall out of scope, so drain every key via `remove!`/`pop_*` first, then
/// call this. A set of droppable keys never needs it.
///
/// #### Aborts
/// - `ENotEmpty` if the set still holds keys.
public fun destroy_empty<K>(set: SortedSet<K>) {
    // Assert the set's own `ENotEmpty` FIRST so a non-empty set aborts at THIS module's location;
    // the wrapped map's `ENotEmpty` is never reached through here.
    assert!(set.is_empty(), ENotEmpty);
    let SortedSet { inner } = set;
    inner.destroy_empty();
}

// === Macro-internal accessors (forced-public; NOT a supported API) ===
//
// These items are `public` ONLY because Move 2024 macro hygiene requires every
// symbol a macro body references to be public at the consumer's expansion site. They are
// NOT a supported mutation API. `inner_mut` in particular lets a caller drive the wrapped
// map directly with an inconsistent comparator or a wrong index and desort this set -
// order-only corruption, local to that one set, no value ever lost. Use the macro API
// (`upsert`, `remove!`, ...) instead.

/// Immutable view of the wrapped map - what read macros (`contains!`, `find_*!`,
/// `keys_from!`) expand against. Read-only: cannot be upgraded to `&mut`.
public fun inner<K>(set: &SortedSet<K>): &SortedMap<K, Unit> {
    &set.inner
}

/// Mutable view of the wrapped map - what write macros (`upsert`, `remove!`) expand
/// against.
///
/// > **Warning:** order-corruption surface. Mutating the map directly (rather than through
/// > the macro API) can break sorted order and invalidate every lookup, insertion, and
/// > removal thereafter; see the module header. Obtaining this reference requires
/// > `&mut SortedSet` (hence `&mut` on the enclosing object), so the consumer's reference
/// > discipline still gates every write.
public fun inner_mut<K>(set: &mut SortedSet<K>): &mut SortedMap<K, Unit> {
    &mut set.inner
}

/// Construct the membership marker. Forced public because set macros build it at the
/// consumer's expansion site (`Unit {}` won't compile at a foreign site). The returned
/// `Unit` is inert - there is no set op that accepts a value, so a consumer-held `Unit`
/// can never be threaded into a set.
public fun unit(): Unit {
    Unit {}
}

/// Abort `EKeysNotSorted` if `sorted` is false. Routed through this regular fun so the sorted
/// constructor's abort fires at this module's location, not the consumer's inlined macro body.
///
/// #### Aborts
/// - `EKeysNotSorted` if `sorted` is false.
public fun assert_sorted(sorted: bool) {
    assert!(sorted, EKeysNotSorted);
}

/// Build a set from a vector of keys by idempotent insertion, under `$lt`. Duplicates are
/// silently collapsed - the result holds each distinct key once, in comparator order, so
/// `length(result)` is the number of distinct keys, NOT the input length. This diverges
/// from `sui::vec_set::from_keys`, which aborts on a duplicate; to reject duplicates
/// instead, build then `assert!(length(&s) == keys.length(), E)`.
///
/// Under a coarse `_by` comparator, byte-distinct compare-equal keys collapse to one
/// element keeping the last one's bytes (each re-insert is a last-write-wins upsert). Uses a
/// `fold!` loop body (one reused expansion), never a straight-line sequence, to stay under Move's
/// locals limit.
///
/// #### Parameters
/// - `keys`: Keys to insert; duplicates are collapsed.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - A set of the distinct keys, in comparator order.
public macro fun from_keys_by<$K: drop>($keys: vector<$K>, $lt: |&$K, &$K| -> bool): SortedSet<$K> {
    let keys = $keys;
    keys.fold!(new(), |mut set, k| { set.upsert_by!(k, $lt); set })
}

/// `from_keys_by` with the built-in integer `<`. De-duplicates - see `from_keys_by`.
///
/// #### Returns
/// - A set of the distinct keys, in ascending order.
public macro fun from_keys<$K: drop>($keys: vector<$K>): SortedSet<$K> {
    from_keys_by!($keys, |a, b| *a < *b)
}

/// Build a set from `keys` that are ALREADY sorted (non-decreasing) under `$lt`. O(N): one pass
/// validates each adjacent pair and appends at the back - no per-element search - so prefer this to
/// `from_keys!` (which is O(N^2)) when the input is pre-sorted.
///
/// De-duplicates exactly like `from_keys!`: a run of compare-equal keys collapses to one element,
/// keeping the LAST key's bytes (observable only under a coarse, non-injective comparator) - it
/// overwrites the stored key with each later compare-equal one, matching `upsert!`'s
/// last-write-wins rule. A set has no value to lose, so a duplicate collapses rather than aborts -
/// the divergence from the map's `from_sorted_keys_values!`, which aborts on a duplicate to
/// conserve values. The only rejection is genuinely unsorted input.
///
/// If your keys are not yet ordered, use `from_keys!` (any order, O(N^2)) or sort them first.
///
/// #### Parameters
/// - `keys`: Keys sorted (non-decreasing) under `lt`; compare-equal runs are collapsed to the last.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - A set of the distinct keys, in comparator order.
///
/// #### Aborts
/// - `EKeysNotSorted` if `keys` has an adjacent pair not sorted under `lt`.
public macro fun from_sorted_keys_by<$K: drop>(
    $keys: vector<$K>,
    $lt: |&$K, &$K| -> bool,
): SortedSet<$K> {
    let mut keys = $keys;
    // Consume `keys` front-to-back (reverse, then O(1) `pop_back` each) so keys move into the set by
    // value - no `copy` bound, matching `from_keys_by`/`from_sorted_keys_values_by`.
    let mut set = new();
    if (!keys.is_empty()) {
        keys.reverse();
        // Lag by one: `prev` holds the last key kept for the current compare-equal run, moved into
        // the set only once the next distinct key confirms the run has ended. `prev` always equals
        // the previous input element, so the sorted check compares each adjacent input pair.
        let mut prev = keys.pop_back();
        while (!keys.is_empty()) {
            let cur = keys.pop_back();
            // Input MUST be sorted: reject a strictly decreasing pair (`cur` < `prev`).
            assert_sorted(!$lt(&cur, &prev));
            if ($lt(&prev, &cur)) {
                // Strictly greater than `prev` - the run ended; append `prev` at the back (O(1)).
                let at = set.length();
                set.inner_mut().insert_at(prev, unit(), at);
            };
            // Compare-equal collapses the run to the LAST key: reassigning drops the old `prev`
            // (last-write-wins, matching `upsert!`/`from_keys!`); after a distinct key, `prev` was
            // moved into the set above, so this just advances the window.
            prev = cur;
        };
        let at = set.length();
        set.inner_mut().insert_at(prev, unit(), at);
    };
    keys.destroy_empty();
    set
}

/// `from_sorted_keys_by` with the built-in integer `<`. De-duplicates - see `from_sorted_keys_by`.
///
/// #### Returns
/// - A set of the distinct keys, in ascending order.
///
/// #### Aborts
/// - `EKeysNotSorted` if `keys` is not ascending.
public macro fun from_sorted_keys<$K: drop>($keys: vector<$K>): SortedSet<$K> {
    from_sorted_keys_by!($keys, |a, b| *a < *b)
}

// === Size and bounds (regular funs, no comparator) ===

/// Number of distinct keys.
public fun length<K>(set: &SortedSet<K>): u64 {
    set.inner.length()
}

/// True iff the set holds no keys.
public fun is_empty<K>(set: &SortedSet<K>): bool {
    set.inner.is_empty()
}

/// Smallest key under the comparator, or `none` if empty. O(1). With a reverse comparator
/// this is the largest numeric key.
public fun head<K: copy>(set: &SortedSet<K>): Option<K> {
    set.inner.head()
}

/// Largest key under the comparator, or `none` if empty. O(1).
public fun tail<K: copy>(set: &SortedSet<K>): Option<K> {
    set.inner.tail()
}

// === Pop extremes (regular funs; abort EEmpty) ===

/// Remove and return the smallest key. Length - 1. O(N): shifts every remaining entry
/// (`pop_back` is O(1)); a front-heavy drain loop is quadratic.
///
/// #### Returns
/// - The smallest key.
///
/// #### Aborts
/// - `EEmpty` if the set is empty.
/// - `sorted_map::EEmpty` (guarded by the prior `is_empty` check; unreachable in normal
///   operation).
public fun pop_front<K>(set: &mut SortedSet<K>): K {
    // Assert the set's own `EEmpty` FIRST, before delegating, so an empty-set pop aborts at THIS
    // module's location - the wrapped map's `EEmpty` is never reached through here.
    assert!(!set.is_empty(), EEmpty);
    let (key, _unit) = set.inner.pop_front();
    key
}

/// Remove and return the largest key. Length - 1. O(1).
///
/// #### Returns
/// - The largest key.
///
/// #### Aborts
/// - `EEmpty` if the set is empty.
/// - `sorted_map::EEmpty` (guarded by the prior `is_empty` check; unreachable in normal
///   operation).
public fun pop_back<K>(set: &mut SortedSet<K>): K {
    // Assert the set's own `EEmpty` FIRST so an empty-set pop aborts at THIS module's location;
    // the wrapped map's `EEmpty` is never reached through here.
    assert!(!set.is_empty(), EEmpty);
    let (key, _unit) = set.inner.pop_back();
    key
}

// === All keys (regular fun, no comparator) ===

/// ALL keys in strict ascending (comparator) order as an owned `vector<K>` - sorted and
/// duplicate-free. NOT a reference: the set stores `Entry<K, Unit>`, so there is no
/// `vector<K>` to borrow (contrast `vec_set::keys`).
///
/// O(N) in output size with no `limit` - the one read whose result scales with N. For
/// large or near-ceiling sets, prefer the paged `keys_from!`.
///
/// #### Returns
/// - Every key, in ascending comparator order.
public fun keys<K: copy>(set: &SortedSet<K>): vector<K> {
    set.inner.keys()
}

// === Membership (macros: bare + `_by`) ===

/// True iff `key` is present, under `$lt`. Pure, total read.
///
/// #### Parameters
/// - `set`: The set to read.
/// - `key`: Key to test.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - `true` iff `key` is present.
public macro fun contains_by<$K>($set: &SortedSet<$K>, $key: &$K, $lt: |&$K, &$K| -> bool): bool {
    let set = $set;
    set.inner().contains_by!($key, $lt)
}

/// `contains_by` with the built-in integer `<`.
///
/// #### Returns
/// - `true` iff `key` is present.
public macro fun contains<$K>($set: &SortedSet<$K>, $key: &$K): bool {
    contains_by!($set, $key, |a, b| *a < *b)
}

/// Insert `key`, under `$lt`, aborting if it is already present (length + 1, `contains!(key)`
/// flips false -> true). Nothing is returned. The strict counterpart to the total `upsert`:
/// this matches `sui::vec_set::insert`, which also aborts on a duplicate, so a duplicate is a
/// caller bug rather than a silent no-op. Use `upsert`/`upsert_by` when a duplicate should be
/// absorbed silently (and reported via the returned bool) instead of aborting.
///
/// #### Parameters
/// - `set`: The set to mutate.
/// - `key`: Key to insert; must not already be present.
/// - `lt`: Strict less-than comparator.
///
/// #### Aborts
/// - `sorted_map::EKeyAlreadyExists` if `key` is already present.
public macro fun add_by<$K>($set: &mut SortedSet<$K>, $key: $K, $lt: |&$K, &$K| -> bool) {
    let set = $set;
    set.inner_mut().add_by!($key, unit(), $lt);
}

/// `add_by` with the built-in integer `<`.
///
/// #### Aborts
/// - `sorted_map::EKeyAlreadyExists` if `key` is already present.
public macro fun add<$K>($set: &mut SortedSet<$K>, $key: $K) {
    add_by!($set, $key, |a, b| *a < *b)
}

/// Insert `key`, under `$lt`. Idempotent and total (never aborts). `key` is taken by value
/// (mirroring the wrapped map's `upsert`). On a fresh insert: length + 1 and `contains!(key)`
/// flips false -> true. On a duplicate: length unchanged, but the stored key is overwritten with
/// this one (last-write-wins for the key bytes, observable only under a coarse comparator).
/// Diverges from `vec_set::insert` (which aborts on a duplicate); for that behavior call `add!`,
/// or write `assert!(s.upsert!(k), E)`.
///
/// #### Parameters
/// - `set`: The set to mutate.
/// - `key`: Key to insert (taken by value).
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - `true` iff the key was newly added, `false` if it was already present.
public macro fun upsert_by<$K: drop>(
    $set: &mut SortedSet<$K>,
    $key: $K,
    $lt: |&$K, &$K| -> bool,
): bool {
    let set = $set;
    let res = set.inner_mut().upsert_by!($key, unit(), $lt).is_none();
    res
}

/// `upsert_by` with the built-in integer `<`.
///
/// #### Returns
/// - `true` iff the key was newly added.
public macro fun upsert<$K: drop>($set: &mut SortedSet<$K>, $key: $K): bool {
    upsert_by!($set, $key, |a, b| *a < *b)
}

/// Remove `key`, under `$lt`. On success: length - 1 and `contains!(key)` flips
/// true -> false. Matches `vec_set::remove`, which also aborts when the key is absent.
///
/// #### Parameters
/// - `set`: The set to mutate.
/// - `key`: Key to remove.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - The removed key.
///
/// #### Aborts
/// - `sorted_map::EKeyNotFound` if `key` is absent.
public macro fun remove_by<$K>($set: &mut SortedSet<$K>, $key: &$K, $lt: |&$K, &$K| -> bool): $K {
    let set = $set;
    // The map's `remove_by!` returns the removed `(key, Unit)` pair; discard the `Unit` value and
    // return the key.
    let (k, _) = set.inner_mut().remove_by!($key, $lt);
    k
}

/// `remove_by` with the built-in integer `<`.
///
/// #### Parameters
/// - `set`: The set to mutate.
/// - `key`: Key to remove.
///
/// #### Returns
/// - The removed key.
///
/// #### Aborts
/// - `sorted_map::EKeyNotFound` if `key` is absent.
public macro fun remove<$K>($set: &mut SortedSet<$K>, $key: &$K): $K {
    remove_by!($set, $key, |a, b| *a < *b)
}

// === Ordered navigation (macros: bare + `_by`) ===

/// Smallest key `>= key` when `include` (the ceiling), else smallest key `> key` (strict
/// next); `none` if there is no such key. Pure, total read; any returned key satisfies
/// `contains!`.
///
/// #### Parameters
/// - `set`: The set to read.
/// - `key`: Reference key.
/// - `include`: Whether an exact match of `key` qualifies.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - The ceiling/strict-next key, or `none`.
public macro fun find_next_by<$K: copy>(
    $set: &SortedSet<$K>,
    $key: &$K,
    $include: bool,
    $lt: |&$K, &$K| -> bool,
): Option<$K> {
    let set = $set;
    set.inner().find_next_by!($key, $include, $lt)
}

/// `find_next_by` with the built-in integer `<`.
///
/// #### Returns
/// - The ceiling/strict-next key, or `none`.
public macro fun find_next<$K: copy>($set: &SortedSet<$K>, $key: &$K, $include: bool): Option<$K> {
    find_next_by!($set, $key, $include, |a, b| *a < *b)
}

/// Largest key `<= key` when `include` (the floor), else largest key `< key` (strict prev);
/// `none` if there is no such key. Pure, total read; any returned key satisfies `contains!`.
///
/// #### Parameters
/// - `set`: The set to read.
/// - `key`: Reference key.
/// - `include`: Whether an exact match of `key` qualifies.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - The floor/strict-prev key, or `none`.
public macro fun find_prev_by<$K: copy>(
    $set: &SortedSet<$K>,
    $key: &$K,
    $include: bool,
    $lt: |&$K, &$K| -> bool,
): Option<$K> {
    let set = $set;
    set.inner().find_prev_by!($key, $include, $lt)
}

/// `find_prev_by` with the built-in integer `<`.
///
/// #### Returns
/// - The floor/strict-prev key, or `none`.
public macro fun find_prev<$K: copy>($set: &SortedSet<$K>, $key: &$K, $include: bool): Option<$K> {
    find_prev_by!($set, $key, $include, |a, b| *a < *b)
}

/// Smallest key strictly greater than `key`, or `none`. Sugar for `find_next_by(.., false)`.
/// `next_key!(tail) == none` is the forward-cursor termination signal.
///
/// #### Parameters
/// - `set`: The set to read.
/// - `key`: Reference key.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - The strict-next key, or `none`.
public macro fun next_key_by<$K: copy>(
    $set: &SortedSet<$K>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): Option<$K> {
    find_next_by!($set, $key, false, $lt)
}

/// `next_key_by` with the built-in integer `<`.
///
/// #### Returns
/// - The strict-next key, or `none`.
public macro fun next_key<$K: copy>($set: &SortedSet<$K>, $key: &$K): Option<$K> {
    find_next_by!($set, $key, false, |a, b| *a < *b)
}

/// Largest key strictly less than `key`, or `none`. Sugar for `find_prev_by(.., false)`.
/// `prev_key!(head) == none` is the backward-cursor termination signal.
///
/// #### Parameters
/// - `set`: The set to read.
/// - `key`: Reference key.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - The strict-prev key, or `none`.
public macro fun prev_key_by<$K: copy>(
    $set: &SortedSet<$K>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): Option<$K> {
    find_prev_by!($set, $key, false, $lt)
}

/// `prev_key_by` with the built-in integer `<`.
///
/// #### Returns
/// - The strict-prev key, or `none`.
public macro fun prev_key<$K: copy>($set: &SortedSet<$K>, $key: &$K): Option<$K> {
    find_prev_by!($set, $key, false, |a, b| *a < *b)
}

// === Bounded iteration / pagination (macros: bare + `_by`) ===

/// Up to `limit` keys in strict ascending order - a contiguous run starting at the first key
/// `>= from` (when `include`) or `> from` (strict); fewer than `limit` if the current tail is
/// reached. Resume a page by passing the last returned key back as `from` with `include == false`.
/// While the ordered key set is unchanged, successive pages have no overlap or gap. A cursor reused
/// after a key-set mutation has keyset semantics: each call reads the keys currently after `from`.
/// Keys inserted at or before the cursor are skipped, keys inserted after it can appear, and
/// removed keys do not appear. With a positive `limit`, an empty page means no key follows the
/// cursor at that moment, not that a persisted scan is permanently complete. `limit == 0`, an
/// empty set, or `from` past the current tail yields the empty vector.
///
/// #### Parameters
/// - `set`: The set to read.
/// - `from`: Lower-bound key.
/// - `include`: Whether an exact match of `from` is included.
/// - `limit`: Maximum number of keys to return.
/// - `lt`: Strict less-than comparator.
///
/// #### Returns
/// - Up to `limit` keys in ascending order.
public macro fun keys_from_by<$K: copy>(
    $set: &SortedSet<$K>,
    $from: &$K,
    $include: bool,
    $limit: u64,
    $lt: |&$K, &$K| -> bool,
): vector<$K> {
    let set = $set;
    set.inner().keys_from_by!($from, $include, $limit, $lt)
}

/// `keys_from_by` with the built-in integer `<`.
///
/// #### Returns
/// - Up to `limit` keys in ascending order.
public macro fun keys_from<$K: copy>(
    $set: &SortedSet<$K>,
    $from: &$K,
    $include: bool,
    $limit: u64,
): vector<$K> {
    keys_from_by!($set, $from, $include, $limit, |a, b| *a < *b)
}

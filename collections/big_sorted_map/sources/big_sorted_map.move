/// A generic, ordered key->value B+Tree for workloads past `SortedMap`'s single-object
/// (~250 KB, ~16k `u64/u64`) ceiling - the **large tier** of the sorted-map family.
///
/// `BigSortedMap` is a real Sui **object** (`has key, store`, own `id: UID`): the root node
/// lives inline, every other node is a raw `dynamic_field` keyed by a `u64` id off that UID.
/// `copy`/`drop` are forced off by the `UID`, so a populated tree can NEVER be silently
/// dropped (which would orphan its df children); the sole terminal is `destroy_empty` after
/// the tree is drained. Each node's payload is an ordinary `SortedMap`: a leaf stores
/// `key->V`, an inner node stores `subtreeMax->childId` (max-key 1:1 routing).
///
/// # Tier choice (vs `SortedMap`)
/// Use `SortedMap` until your data outgrows one object (~250 KB). Use `BigSortedMap` when it
/// will not - a CLOB order book, a global registry, a tick map. The query-side API is 1:1
/// with `SortedMap` so call sites port verbatim, but MIGRATION IS A REAL REFACTOR, not a
/// rename: `new` takes `&mut TxContext`, the enclosing struct owns/transfers an object (not a
/// bare value), teardown is drain-then-`destroy_empty` (multi-tx for large trees), and
/// `keys_from`'s `limit` becomes a MANDATORY safety bound.
///
/// # Liveness divergence (READ THIS)
/// Unlike `SortedMap` (every op touches exactly one object), a `BigSortedMap` op touches
/// MULTIPLE df nodes. A point op loads at most `depth - 1` nodes (O(log N), two-to-three
/// orders under Sui's ~1000-df-access cap), but an unbounded scan, a long mutating walk, or
/// a teardown can load hundreds. Hence: `keys_from` is count-bounded by `limit` (a safety
/// parameter - a k-key scan loads ~k/ceil(leaf/2) leaves), teardown is paged via
/// `pop_front`/`pop_back`/`pop_*_n`, and there is NO production one-shot bulk drop even for a
/// droppable `V`. A shared `BigSortedMap` serializes ALL writers on its one object id
/// (per-object, not per-key - shard per domain).
///
/// # Comparator contract (same as `SortedMap`)
/// The tree stores no comparator. Order is defined per call by a strict less-than
/// `|&K, &K| -> bool` you supply, threaded CONSISTENTLY to every call (and to the
/// `from_sorted_map` bridge). Comparator-needing ops come in two forms: **bare** (`insert!`,
/// built-in integer `<`, integer keys only) and **`_by`** (`insert_by!`, your `lt` lambda,
/// required for non-integer keys). A reverse comparator used consistently is legitimate (it
/// flips order: `head` returns the largest key). An INCONSISTENT comparator silently corrupts
/// BOTH leaf order and routing keys tree-wide and is UNREPAIRABLE in place - the worst
/// footgun in the family (worse than `SortedMap`, where corruption is confined to one object).
/// The library cannot detect a violation; in tests verify tree well-formedness with the paged
/// check.
///
/// # At most ONE comparator-bearing macro expansion per function body
/// Each `_by`/bare macro expands a full comparator descent inline; two in one body overflow
/// Move's 256-locals ceiling (a compiler ICE). Compose multi-op flows from ONE-LINE WRAPPER
/// FUNS (a call is a jump, not a paste) or loops. The canonical check-then-act merge-upsert
/// does NOT fit one body and must be split.
///
/// # Library internals are forced-public
/// The comparator descent must be a macro (regular funs cannot take a lambda), and a macro body
/// expands at the CONSUMER's call site, so every symbol the macro references is forced `public`
/// - a wider surface than `SortedMap`'s. Because each macro is THIN (it only descends, then
/// calls a positional regular-fun kernel), the forced-public set is the descent macros + the
/// kernels they call (`apply_insert`/`apply_remove`/`next_key_from`/.../`build_from_sorted`) + the
/// read accessors they touch (`is_leaf`/`node_len`/`node_leaf{,_mut}`/`node_inner`/`child_id_at`/
/// `max_key`). The structural CASCADE (split/merge/borrow/collapse) and the dangerous arena and
/// routing MUTATORS (`add_node`/`remove_node`/`alloc_id`/`take_root`/`fill_root`/`node_inner_mut`/
/// `set_routing_key_at`) are PRIVATE - nothing external needs them. The forced-public surface is
/// NOT a supported API: calling it directly can corrupt routing/order. Separately published for a
/// hand-rolled cursor: `locate_leaf_by!`, `borrow_node{,_mut}`, `node_leaf{,_mut}`, `leaf_next`/
/// `leaf_prev`, `null_index`, `root_index`. Use the macro + regular-fun consumer surface.
///
/// # Upgrade policy
/// The on-chain layout (container + node + the frozen `prev`/`next` leaf links) is frozen at
/// first publish. There is deliberately no `version` field and no enum/single-variant wrapper
/// (Sui rejects added enum variants, and a frozen-layout version field could only hold its
/// initial constant). A future layout change ships as a parallel `BigSortedMapV2` with
/// consumer-driven multi-tx copy-migration - never an in-place edit.
module openzeppelin_big_sorted_map::big_sorted_map;

use openzeppelin_sorted_map::sorted_map::{Self, SortedMap};
use sui::dynamic_field as df;

// === Errors ===

/// `destroy_empty` was called on a non-empty tree. The sole guard against orphaning
/// df children - read off the O(1) cached `length` BEFORE `object::delete`.
#[error(code = 0)]
const EMapNotEmpty: vector<u8> = "Map is not empty";

/// A key was not present. Raised by `borrow`/`borrow_mut`. The found-assert runs
/// strictly before any indexed leaf read.
#[error(code = 1)]
const EKeyNotFound: vector<u8> = "Key not found";

/// `pop_front`/`pop_back`/`pop_*_n` was called on an empty tree. The empty-check is
/// the first statement, before any min/max-leaf df load.
#[error(code = 2)]
const EEmpty: vector<u8> = "Map is empty";

/// `new_with_config` was given a degree below the half-fill floor (`leaf >= 3`, `inner >= 4`).
/// THE load-bearing guard: the floor (`ceil(m/2) >= 2`) IS the half-full-floor DoS-safety
/// guarantee - it blocks the 1-entry-per-leaf scan attack that would breach the df-load cap.
#[error(code = 3)]
const EInvalidDegree: vector<u8> = "Degree below min-fill floor";

/// `into_sorted_map` would produce a `SortedMap` past the safe tier-1 size. A COUNT
/// heuristic, deliberately unsound for fat `V` - documented safe only for small bounded `V`.
#[error(code = 4)]
const EWouldExceedTier1EntryHeuristic: vector<u8> = "Drained map would exceed tier-1 capacity";

/// `from_sorted_map[_by]` source was not strictly increasing under the threaded comparator.
/// Fires BEFORE any df write - the only catch for a wrong-ordered bulk-load source,
/// which would otherwise become tree-wide unrepairable corruption.
#[error(code = 5)]
const ESourceNotSortedUnderComparator: vector<u8> = "Source map is not sorted under comparator";

/// An asserting node accessor was used against the wrong node kind (a leaf accessor on an
/// inner node or vice versa). The sole backstop for the two-field discriminant on
/// the `<u64,u64>` instantiation, where the compiler gives zero cross-field protection.
#[error(code = 6)]
const EWrongNodeKind: vector<u8> = "Wrong node kind for this accessor";

// === Constants ===

/// The "no node" sentinel id. Terminates the leaf chain at both
/// ends and marks an absent child. `alloc_id` never returns it.
const NULL_INDEX: u64 = 0;

/// The logical id of the INLINE root (it lives in the `root: Option<Node>` field, not a df).
/// `alloc_id` never returns it.
const ROOT_INDEX: u64 = 1;

/// First id `alloc_id` hands out - the counter pre-increments from here, so live ids are
/// always `>= 2`, never colliding with `NULL_INDEX`/`ROOT_INDEX`.
const FIRST_ALLOC_INDEX: u64 = 2;

/// Hard floor for `leaf_max_degree`. `ceil(3/2) = 2`, so a half-full leaf holds
/// >= 2 entries - the structural form of the DoS scan-cost bound.
const LEAF_MIN_DEGREE: u64 = 3;

/// Hard floor for `inner_max_degree`. `ceil(4/2) = 2`, so a half-full inner node
/// has >= 2 children.
const INNER_MIN_DEGREE: u64 = 4;

/// Default max entries per leaf, used by `new`. 64 is a conservative choice for `u64/u64`
/// (well under the object/df caps); size it DOWN for a fat `V` via `new_with_config`, since
/// the node must stay under the object byte cap. Tests force degree 3/4 to fire splits
/// cheaply, so this default does not affect the structural test coverage.
const DEFAULT_LEAF_MAX_DEGREE: u64 = 64;

/// Default max children per inner node, used by `new`. Routing entries (`K` + `u64` child id)
/// are small, so this can be generous.
const DEFAULT_INNER_MAX_DEGREE: u64 = 64;

/// `into_sorted_map`'s capacity heuristic: refuse to drain a tree larger than this
/// into a single-object `SortedMap`. A COUNT heuristic, deliberately unsound for fat `V` -
/// documented safe only for small bounded `V`. 10_000 is conservatively below the measured
/// tier-1 `u64/u64` ceiling (~15_997 entries) to leave margin for larger value types.
const MAX_TIER1_ENTRY_COUNT: u64 = 10_000;

// === Structs ===

/// The large-tier ordered map. A real Sui object: `id` anchors a df arena of non-root nodes,
/// the root is inline.
///
/// `has key, store`: df-backed, so an object (ability follows storage). `copy`/`drop` are
/// FORCED OFF by `id: UID` (a `UID` is neither) - exactly the orphan-safety wanted: the tree
/// can only end via `destroy_empty`, never by silently dropping its df children. There is no
/// `version` field and no enum wrapper (frozen layout; Sui rejects added enum variants).
///
/// `K`/`V` are NOT `phantom` (both appear in `Node<K,V>`'s field types). The cached
/// `length` makes `is_empty`/`destroy_empty` O(1) and df-load-free; an O(n) leaf-walk
/// recount would itself breach the df-load cap (a liveness bug). `min_leaf_index`/
/// `max_leaf_index` are the O(1) spine anchors for `head`/`tail`/`pop_*`.
/// `next_node_index` is monotone from `FIRST_ALLOC_INDEX`, never reused.
public struct BigSortedMap<K: copy + drop + store, V: store> has key, store {
    /// df arena: every non-root node is a raw `dynamic_field` keyed by its `u64` id off this UID.
    id: UID,
    /// INLINE root. `Some` in every observable state of a live tree; `None` only transiently
    /// mid-first-split (`take_root`/`fill_root` - Move has no yield point, so it never spans a
    /// public-call boundary).
    root: Option<Node<K, V>>,
    /// Cached live-entry count, maintained by a single +/-1 at the one leaf op (never by the
    /// cascade).
    length: u64,
    /// Id of the globally-leftmost leaf -> O(1) `head`/`pop_front` and the paged-drain front.
    min_leaf_index: u64,
    /// Id of the globally-rightmost leaf -> O(1) `tail`/`pop_back`.
    max_leaf_index: u64,
    /// Monotone, never-reused id counter; pre-increments on alloc (no free list).
    next_node_index: u64,
    /// Max children per inner node, set at construction and frozen (>= `INNER_MIN_DEGREE`).
    inner_max_degree: u64,
    /// Max entries per leaf node, set at construction and frozen (>= `LEAF_MIN_DEGREE`).
    leaf_max_degree: u64,
}

/// One B+Tree node, leaf or inner, discriminated by `is_leaf`. The payload is an ordinary
/// `SortedMap`: exactly ONE of the two maps is populated, the other is dormant-empty.
/// - leaf  (`is_leaf == true`):  `leaf`  holds `key -> V`              (the data)
/// - inner (`is_leaf == false`): `inner` holds `subtreeMax -> childId` (max-key 1:1 routing)
///
/// `has store` ONLY - deliberately NOT `drop`, NOT `copy`. The missing `drop` is
/// load-bearing: an inner node's values are child ids, so a droppable node would let a
/// `V: drop` instantiation silently ORPHAN an entire subtree's df entries. Forcing every node
/// to be explicitly unpacked makes that orphan type-unrepresentable.
///
/// "Exactly one map populated" is a CONVENTION, not type-enforced: on the flagship
/// `<u64,u64>` instantiation `leaf` and `inner` are the same type, so the compiler gives ZERO
/// cross-field protection. It is enforced instead by the asserting accessors (`node_leaf*`/
/// `node_inner*` -> `EWrongNodeKind`) plus the `new_leaf`/`new_inner` funnels (`is_leaf` is set
/// only at construction, never flipped).
///
/// `prev`/`next` are sibling-link ids, load-bearing at the LEAF level (the doubly-linked leaf
/// chain) for ordered scans, paged drain, and the DIY cursor. They are frozen into
/// v1 even though no v1 op walks inner siblings: a frozen df-backed layout cannot add fields
/// post-publish, so the deferred blessed cursor's layout must exist now.
public struct Node<K: copy + drop + store, V: store> has store {
    is_leaf: bool,
    leaf: SortedMap<K, V>, // populated iff is_leaf
    inner: SortedMap<K, u64>, // populated iff !is_leaf  (value = child node id)
    prev: u64, // same-level sibling links; NULL_INDEX terminates the chain
    next: u64,
}

// === Public Functions ===

// === Sentinel accessors ===

/// The "no node" sentinel (0). Consumers test a leaf-walk for termination with this.
public fun null_index(): u64 { NULL_INDEX }

/// The logical id of the inline root (1).
public fun root_index(): u64 { ROOT_INDEX }

// === Node accessors ===

//
// EVERY payload-field touch in the module goes through these: there is no direct
// `node.leaf`/`node.inner` access anywhere. On the flagship `<u64,u64>` instantiation the two
// maps are the same type, so the compiler gives zero cross-field protection - these asserting
// accessors are the sole backstop, turning a wrong-field touch into a loud `EWrongNodeKind`
// abort. `is_leaf` is read directly (it is the discriminant, not a payload field). The read
// accessors (`is_leaf`/`node_len`/`node_leaf`/`node_inner`/`node_leaf_mut`) are public - the
// macro descent and the DIY cursor need them; `node_inner_mut` is private (cascade-only - a
// public mutable routing view would let a consumer corrupt routing keys).

/// True iff `n` is a leaf node. The discriminant; set only at construction, never flipped.
public fun is_leaf<K: copy + drop + store, V: store>(n: &Node<K, V>): bool {
    n.is_leaf
}

/// Number of live entries in `n`'s populated map (leaf entries or routing children). The basis
/// for the overflow (`> max_degree`) and underflow (`< ceil(max_degree/2)`) cascade decisions.
public fun node_len<K: copy + drop + store, V: store>(n: &Node<K, V>): u64 {
    if (n.is_leaf) node_leaf(n).length() else node_inner(n).length()
}

/// Immutable view of a leaf's data map.
///
/// #### Aborts
/// - `EWrongNodeKind` if `n` is an inner node.
public fun node_leaf<K: copy + drop + store, V: store>(n: &Node<K, V>): &SortedMap<K, V> {
    assert!(n.is_leaf, EWrongNodeKind);
    &n.leaf
}

/// Mutable view of a leaf's data map.
///
/// #### Aborts
/// - `EWrongNodeKind` if `n` is an inner node.
public fun node_leaf_mut<K: copy + drop + store, V: store>(
    n: &mut Node<K, V>,
): &mut SortedMap<K, V> {
    assert!(n.is_leaf, EWrongNodeKind);
    &mut n.leaf
}

/// Immutable view of an inner node's routing map.
///
/// #### Aborts
/// - `EWrongNodeKind` if `n` is a leaf.
public fun node_inner<K: copy + drop + store, V: store>(n: &Node<K, V>): &SortedMap<K, u64> {
    assert!(!n.is_leaf, EWrongNodeKind);
    &n.inner
}

// === Arena / addressing ===

//
// Non-root nodes live in raw dynamic fields keyed by their `u64` id off the container UID; the
// root is the inline `Option<Node>`. `borrow_node{,_mut}` are DUAL-SOURCE: id
// `ROOT_INDEX` reads the inline root, every other id reads a df - mutually exclusive and
// exhaustive. The `&mut` descent pattern is descend-by-id-then-fresh-reborrow (never a live
// borrow held across a descent), so the borrow checker accepts the deep mutation walk.
//
// The MUTATORS here (`alloc_id`/`add_node`/`remove_node`/`take_root`/`fill_root`) are PRIVATE:
// no macro body or published DIY-cursor primitive needs them, and direct external use would
// orphan/corrupt the tree. Only `borrow_node{,_mut}` are public (read-borrow; the cursor uses
// `borrow_node_mut` for in-place value mutation - see the DIY-cursor primitives).

/// Dual-source immutable node borrow: inline root for `ROOT_INDEX`, else the df.
///
/// #### Aborts
/// - Natively (in `dynamic_field`) if `id != ROOT_INDEX` and no node is stored under `id`.
public fun borrow_node<K: copy + drop + store, V: store>(
    map: &BigSortedMap<K, V>,
    id: u64,
): &Node<K, V> {
    if (id == ROOT_INDEX) map.root.borrow() else df::borrow(&map.id, id)
}

/// Dual-source mutable node borrow: inline root for `ROOT_INDEX`, else the df.
///
/// #### Aborts
/// - Natively (in `dynamic_field`) if `id != ROOT_INDEX` and no node is stored under `id`.
public fun borrow_node_mut<K: copy + drop + store, V: store>(
    map: &mut BigSortedMap<K, V>,
    id: u64,
): &mut Node<K, V> {
    if (id == ROOT_INDEX) map.root.borrow_mut() else df::borrow_mut(&mut map.id, id)
}

// === Routing / child navigation ===

//
// Reads (`child_id_at`/`max_key`/`leaf_next`/`leaf_prev`) are public: the macro descent needs
// `child_id_at`, and the DIY cursor + external structural checks use the rest. The routing
// MUTATOR `set_routing_key_at` is private (cascade-only) - NOT a supported API. These reads are
// the published primitives for a hand-rolled cursor; misuse cannot corrupt state (read-only).

/// The child id stored at routing index `idx` of an inner node.
///
/// #### Aborts
/// - `EWrongNodeKind` if `n` is a leaf (via `node_inner`).
/// - Natively (out of bounds, in `std::vector`) if `idx` is past the routing map's length.
public fun child_id_at<K: copy + drop + store, V: store>(n: &Node<K, V>, idx: u64): u64 {
    *node_inner(n).value_at(idx)
}

/// The maximum key present in `n`'s populated map - i.e. the subtree max used as `n`'s routing
/// key in its parent. For a leaf, the largest data key; for an inner node, its last
/// routing key (which already equals the whole-subtree max). Returns `K` by copy.
/// Precondition: `n` is non-empty (every non-root node is half-full; the root is non-empty
/// unless the tree is empty, where callers short-circuit on `length`).
///
/// #### Aborts
/// - Natively (arithmetic underflow on `length - 1`, then out of bounds) if `n` is empty.
public fun max_key<K: copy + drop + store, V: store>(n: &Node<K, V>): K {
    if (n.is_leaf) {
        let m = node_leaf(n);
        *m.key_at(m.length() - 1)
    } else {
        let m = node_inner(n);
        *m.key_at(m.length() - 1)
    }
}

/// The next-sibling leaf id (`NULL_INDEX` at the chain tail). Published for the DIY cursor.
public fun leaf_next<K: copy + drop + store, V: store>(n: &Node<K, V>): u64 {
    n.next
}

/// The prev-sibling leaf id (`NULL_INDEX` at the chain head). Published for the DIY cursor.
public fun leaf_prev<K: copy + drop + store, V: store>(n: &Node<K, V>): u64 {
    n.prev
}

// === Lifecycle ===

/// Create an empty tree with the default degrees (`new_with_config` with `DEFAULT_*_DEGREE`).
/// Takes `&mut TxContext` because a `BigSortedMap` is an OBJECT (it owns a `UID`), unlike the
/// value-type `SortedMap`/`SortedSet`. The empty tree is a single inline leaf root.
public fun new<K: copy + drop + store, V: store>(ctx: &mut TxContext): BigSortedMap<K, V> {
    new_with_config(DEFAULT_INNER_MAX_DEGREE, DEFAULT_LEAF_MAX_DEGREE, ctx)
}

/// Create an empty tree with explicit degrees. The min-degree floor (`leaf >= LEAF_MIN_DEGREE`,
/// `inner >= INNER_MIN_DEGREE`) is asserted FIRST - it is THE load-bearing guard:
/// `ceil(m/2) >= 2` is the half-full-floor DoS-safety guarantee blocking the 1-entry-per-leaf
/// scan attack. Size `leaf_max_degree` DOWN for a fat `V` (the node must stay under the object
/// byte cap; the count-based degree carries no per-insert byte check).
///
/// #### Aborts
/// - `EInvalidDegree` if `leaf_max_degree < LEAF_MIN_DEGREE` or
///   `inner_max_degree < INNER_MIN_DEGREE`.
public fun new_with_config<K: copy + drop + store, V: store>(
    inner_max_degree: u64,
    leaf_max_degree: u64,
    ctx: &mut TxContext,
): BigSortedMap<K, V> {
    // The floor IS the DoS guarantee - asserted before any object is created.
    assert!(leaf_max_degree >= LEAF_MIN_DEGREE, EInvalidDegree);
    assert!(inner_max_degree >= INNER_MIN_DEGREE, EInvalidDegree);
    BigSortedMap {
        id: object::new(ctx),
        // empty tree = single inline empty leaf root, chain links NULL on both ends.
        root: option::some(new_leaf(NULL_INDEX, NULL_INDEX)),
        length: 0,
        min_leaf_index: ROOT_INDEX,
        max_leaf_index: ROOT_INDEX,
        next_node_index: FIRST_ALLOC_INDEX,
        inner_max_degree,
        leaf_max_degree,
    }
}

/// Destroy an EMPTY tree and reclaim its object id. Reads the O(1) cached `length` BEFORE
/// deleting anything - the sole guard against orphaning df children (the `table::drop`
/// footgun). A non-empty tree must be drained first via `pop_front`/`pop_back`/`pop_*_n`
/// (multi-tx for a large tree - the df-access cap binds).
///
/// At `length == 0` the tree is a single inline leaf root with NO df children (the remove
/// cascade collapses depth back to 0 as the last entries leave), so this deletes
/// exactly the inline root and the UID; there is nothing in the df arena to orphan.
///
/// #### Aborts
/// - `EMapNotEmpty` if the tree still holds entries.
public fun destroy_empty<K: copy + drop + store, V: store>(map: BigSortedMap<K, V>) {
    let BigSortedMap {
        id,
        root,
        length,
        min_leaf_index: _,
        max_leaf_index: _,
        next_node_index: _,
        inner_max_degree: _,
        leaf_max_degree: _,
    } = map;
    assert!(length == 0, EMapNotEmpty); // trust the O(1) cache; an O(n) walk would breach the df cap
    destroy_empty_node(root.destroy_some()); // the empty inline leaf root
    id.delete();
}

// === Size & bounds ===

/// Number of live entries. O(1) cached - never an O(n) leaf walk.
public fun length<K: copy + drop + store, V: store>(map: &BigSortedMap<K, V>): u64 {
    map.length
}

/// True iff the tree holds no entries. O(1).
public fun is_empty<K: copy + drop + store, V: store>(map: &BigSortedMap<K, V>): bool {
    map.length == 0
}

/// Smallest key under the comparator, or `none` if empty. O(1), comparator-free: the
/// minimum lives at index 0 of the leftmost leaf (`min_leaf_index`). A reverse comparator makes
/// this the largest numeric key. For a single-leaf tree `min_leaf_index == ROOT_INDEX`, so this
/// loads zero df nodes.
public fun head<K: copy + drop + store, V: store>(map: &BigSortedMap<K, V>): Option<K> {
    if (map.length == 0) {
        option::none()
    } else {
        let leaf = node_leaf(borrow_node(map, map.min_leaf_index));
        option::some(*leaf.key_at(0))
    }
}

/// Largest key under the comparator, or `none` if empty. O(1), comparator-free: the
/// maximum lives at the last index of the rightmost leaf (`max_leaf_index`).
public fun tail<K: copy + drop + store, V: store>(map: &BigSortedMap<K, V>): Option<K> {
    if (map.length == 0) {
        option::none()
    } else {
        let leaf = node_leaf(borrow_node(map, map.max_leaf_index));
        let n = leaf.length();
        option::some(*leaf.key_at(n - 1))
    }
}

// === Descent ===

//
// The comparator descent MUST be a macro - a regular fun cannot take a `|&K,&K|->bool`
// lambda. `find_path_by!` is the single source of truth for routing: an immutable
// root-to-leaf walk recording the id `path` (root..leaf) and the `child_idxs` taken at each
// inner level, then the leaf search `(found, idx)`. It holds NO live borrow across the descent
// (each loop iteration's node borrow ends before the next), so a caller can re-borrow `&mut`
// afterward (the descend-by-id-then-reborrow pattern). At most ONE such expansion fits a
// function body (the 256-locals ICE) - the cascade is deliberately kept OUT of the
// macro, in positional regular funs.

/// Descend to the leaf that contains or would contain `$key` under `$lt`. Returns
/// `(leaf_id, path, child_idxs, found, idx)`: `leaf_id` is the located leaf (== last of
/// `path`); `path` is the root->leaf id chain; `child_idxs[i]` is the routing index taken in
/// `path[i]`; `found`/`idx` is the leaf-internal `search!` result. At each inner node the child
/// is the lower_bound (first routing key >= key); falling off the right end (key >
/// subtree max) takes the LAST child (so a new-global-max insert reaches the rightmost leaf and
/// a lookup of an absent over-max key reaches a leaf that reports `found == false`).
public macro fun find_path_by<$K: copy + drop + store, $V: store>(
    $map: &BigSortedMap<$K, $V>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): (u64, vector<u64>, vector<u64>, bool, u64) {
    let map = $map;
    let key = $key;
    let mut path = vector[root_index()];
    let mut child_idxs = vector[];
    let mut cur_id = root_index();
    // The loop BREAKS WITH the leaf result `(found, idx)` rather than writing dummy-initialized
    // accumulators. This avoids both the `W09003 unused assignment` warning (no dead `= false`/`= 0`)
    // AND the `E04024` "immutable assigned multiple times in a loop" error that a deferred-init
    // immutable binding hits when this macro is expanded INSIDE a caller's own loop (e.g. a batch
    // `while { insert!(..) }`). `leaf_found`/`leaf_idx` are immutable, bound from the loop's value.
    let (leaf_found, leaf_idx) = loop {
        let node = borrow_node(map, cur_id);
        if (is_leaf(node)) {
            break sorted_map::search!(node_leaf(node), key, $lt) // comparator site 2
        };
        let inner = node_inner(node);
        let (_found, lb) = sorted_map::search!(inner, key, $lt); // comparator site 1 (lower_bound)
        let count = inner.length();
        let cidx = if (lb < count) lb else count - 1; // off the right end -> descend the last child
        cur_id = child_id_at(node, cidx);
        child_idxs.push_back(cidx);
        path.push_back(cur_id);
    };
    (cur_id, path, child_idxs, leaf_found, leaf_idx)
}

/// Locate the leaf id that contains or would contain `$key`. The published DIY-cursor entry
/// point: walk leaves from here via `leaf_next`/`leaf_prev` + `borrow_node{,_mut}`,
/// re-seeding after any structural change. Wraps `find_path_by!`.
public macro fun locate_leaf_by<$K: copy + drop + store, $V: store>(
    $map: &BigSortedMap<$K, $V>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): u64 {
    let (leaf_id, _path, _child_idxs, _found, _idx) = find_path_by!($map, $key, $lt);
    leaf_id
}

/// `locate_leaf_by` with the built-in integer `<`.
public macro fun locate_leaf<$K: copy + drop + store, $V: store>(
    $map: &BigSortedMap<$K, $V>,
    $key: &$K,
): u64 {
    locate_leaf_by!($map, $key, |a, b| *a < *b)
}

// === Point access ===

/// Abort `EKeyNotFound` if `found` is false. The single abort router for absent-key
/// lookups: routing through this regular fun pins the abort at THIS module's location,
/// not in the consumer's inlined macro body.
///
/// #### Aborts
/// - `EKeyNotFound` if `found` is false.
public fun assert_key_found(found: bool) {
    assert!(found, EKeyNotFound);
}

/// Immutable value at `idx` of the leaf `leaf_id`. Positional (the descent already found `idx`).
///
/// #### Aborts
/// - `EWrongNodeKind` if `leaf_id` names an inner node.
/// - Native out-of-bounds abort inside `std::vector` if `idx` is past the leaf's length.
/// - Native dynamic-field abort if `leaf_id` is absent (a corrupted-tree id).
public fun leaf_value_at<K: copy + drop + store, V: store>(
    map: &BigSortedMap<K, V>,
    leaf_id: u64,
    idx: u64,
): &V {
    node_leaf(borrow_node(map, leaf_id)).value_at(idx)
}

/// Mutable value at `idx` of the leaf `leaf_id` (dual-source via `borrow_node_mut`). Positional.
///
/// #### Aborts
/// - `EWrongNodeKind` if `leaf_id` names an inner node.
/// - Native out-of-bounds abort inside `std::vector` if `idx` is past the leaf's length.
/// - Native dynamic-field abort if `leaf_id` is absent (a corrupted-tree id).
public fun leaf_value_at_mut<K: copy + drop + store, V: store>(
    map: &mut BigSortedMap<K, V>,
    leaf_id: u64,
    idx: u64,
): &mut V {
    node_leaf_mut(borrow_node_mut(map, leaf_id)).value_at_mut(idx)
}

/// True iff `$key` is present, under `$lt`. Agrees exactly with `borrow` succeeding.
public macro fun contains_by<$K: copy + drop + store, $V: store>(
    $map: &BigSortedMap<$K, $V>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): bool {
    let (_leaf_id, _path, _child_idxs, found, _idx) = find_path_by!($map, $key, $lt);
    found
}

/// `contains_by` with the built-in integer `<`.
public macro fun contains<$K: copy + drop + store, $V: store>(
    $map: &BigSortedMap<$K, $V>,
    $key: &$K,
): bool {
    contains_by!($map, $key, |a, b| *a < *b)
}

/// Immutable borrow of `$key`'s value, under `$lt`. The found-assert runs STRICTLY before the
/// indexed leaf read.
///
/// #### Aborts
/// - `EKeyNotFound` if `$key` is absent.
public macro fun borrow_by<$K: copy + drop + store, $V: store>(
    $map: &BigSortedMap<$K, $V>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): &$V {
    let map = $map;
    let (leaf_id, _path, _child_idxs, found, idx) = find_path_by!(map, $key, $lt);
    assert_key_found(found); // assert before the indexed read
    leaf_value_at(map, leaf_id, idx)
}

/// `borrow_by` with the built-in integer `<`.
///
/// #### Aborts
/// - `EKeyNotFound` if `$key` is absent.
public macro fun borrow<$K: copy + drop + store, $V: store>(
    $map: &BigSortedMap<$K, $V>,
    $key: &$K,
): &$V {
    borrow_by!($map, $key, |a, b| *a < *b)
}

/// Mutable borrow of `$key`'s value, under `$lt`. Descends immutably (the `find_path_by!` walk
/// freezes `$map`), then re-borrows `&mut` at the leaf - so the dual-source `&mut` agrees with
/// the read descent. Yields `&mut V`, never `&mut` to the key, so sorted order cannot be
/// desynced.
///
/// #### Aborts
/// - `EKeyNotFound` if `$key` is absent.
public macro fun borrow_mut_by<$K: copy + drop + store, $V: store>(
    $map: &mut BigSortedMap<$K, $V>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): &mut $V {
    let map = $map;
    let (leaf_id, _path, _child_idxs, found, idx) = find_path_by!(map, $key, $lt);
    assert_key_found(found); // assert before the indexed read
    leaf_value_at_mut(map, leaf_id, idx)
}

/// `borrow_mut_by` with the built-in integer `<`.
///
/// #### Aborts
/// - `EKeyNotFound` if `$key` is absent.
public macro fun borrow_mut<$K: copy + drop + store, $V: store>(
    $map: &mut BigSortedMap<$K, $V>,
    $key: &$K,
): &mut $V {
    borrow_mut_by!($map, $key, |a, b| *a < *b)
}

// === Insert ===

//
// `insert_by!` is THIN: descend (the one comparator expansion), then hand off to the positional
// `apply_insert`. ALL mutation - the leaf upsert, the routing-key refresh, the overflow split
// cascade - is comparator-free positional regular-fun code (the descent already found the leaf
// index), so it carries unlimited locals and never approaches the macro ICE ceiling.

/// Upsert `$key`/`$value`, or replace the value if present, under `$lt`. Returns `some(old)` on
/// replace (length unchanged), `none` on a fresh insert (length +1, split-on-overflow).
/// THIN: descent (one comparator expansion) -> positional `apply_insert`.
public macro fun insert_by<$K: copy + drop + store, $V: store>(
    $map: &mut BigSortedMap<$K, $V>,
    $key: $K,
    $value: $V,
    $lt: |&$K, &$K| -> bool,
): Option<$V> {
    let map = $map;
    let key = $key;
    let value = $value;
    let (leaf_id, path, child_idxs, found, idx) = find_path_by!(map, &key, $lt);
    apply_insert(map, path, child_idxs, leaf_id, found, idx, key, value)
}

/// `insert_by` with the built-in integer `<`.
public macro fun insert<$K: copy + drop + store, $V: store>(
    $map: &mut BigSortedMap<$K, $V>,
    $key: $K,
    $value: $V,
): Option<$V> {
    insert_by!($map, $key, $value, |a, b| *a < *b)
}

/// Positional insert kernel (forced-public: referenced by `insert_by!`). Given the descent
/// result, performs the leaf upsert at the found index, maintains the cached `length` by a
/// single +/-0/+1, refreshes ancestor routing keys when the touched entry is the
/// leaf's max, then runs the overflow split cascade. Comparator-free.
public fun apply_insert<K: copy + drop + store, V: store>(
    map: &mut BigSortedMap<K, V>,
    path: vector<u64>,
    child_idxs: vector<u64>,
    leaf_id: u64,
    found: bool,
    idx: u64,
    key: K,
    value: V,
): Option<V> {
    if (found) {
        // Upsert-replace: extract the old value (NOT `*value_at_mut = value`, which would drop
        // it), reinsert NEW key bytes at the same index. Length unchanged.
        let leaf = node_leaf_mut(borrow_node_mut(map, leaf_id));
        let old = leaf.remove_at(idx);
        leaf.insert_at(idx, sorted_map::make_entry(copy key, value));
        let leaf_len = node_leaf(borrow_node(map, leaf_id)).length();
        if (idx + 1 == leaf_len) {
            // replaced the leaf max: refresh ancestor routing-key bytes (byte-fidelity)
            refresh_max_along_path(map, &path, &child_idxs, key);
        };
        option::some(old)
    } else {
        // Fresh insert at the found index. Length +1 (applied at the leaf op only).
        let leaf = node_leaf_mut(borrow_node_mut(map, leaf_id));
        leaf.insert_at(idx, sorted_map::make_entry(copy key, value));
        map.length = map.length + 1;
        let leaf_len = node_leaf(borrow_node(map, leaf_id)).length();
        if (idx + 1 == leaf_len) {
            // inserted the new leaf max: bump every ancestor routing key for which this leaf is
            // the largest child (new-global-max right-spine bump + interior-leaf-max).
            refresh_max_along_path(map, &path, &child_idxs, key);
        };
        // Overflow split cascade. Runs AFTER the refresh so child_idxs stay valid.
        cascade_after_insert(map, &path, &child_idxs);
        option::none()
    }
}

// === Remove + rebalance ===

//
// Same thin shape as insert: `remove_by!` descends (one comparator expansion), then the
// positional `apply_remove`/`do_remove` perform the leaf delete, the delete-max routing
// cascade, and the borrow-then-merge rebalance that keeps every non-root node at or
// above the half-full floor (the DoS-safety guarantee). Merge direction is FIXED:
// the right (larger-keys) node is always folded into its immediate-LEFT sibling, so
// `append`'s `self.max < other.min` precondition holds by construction.

/// Remove `$key` under `$lt`. Total - never aborts: `some(value)` on a hit (length
/// -1, full rebalance), `none` on a miss (tree unchanged). THIN: descent -> positional kernel.
public macro fun remove_by<$K: copy + drop + store, $V: store>(
    $map: &mut BigSortedMap<$K, $V>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): Option<$V> {
    let map = $map;
    let (leaf_id, path, child_idxs, found, idx) = find_path_by!(map, $key, $lt);
    apply_remove(map, path, child_idxs, leaf_id, found, idx)
}

/// `remove_by` with the built-in integer `<`.
public macro fun remove<$K: copy + drop + store, $V: store>(
    $map: &mut BigSortedMap<$K, $V>,
    $key: &$K,
): Option<$V> {
    remove_by!($map, $key, |a, b| *a < *b)
}

/// Positional remove kernel (forced-public: referenced by `remove_by!`). On a miss returns
/// `none` (tree untouched). On a hit, drops the key (SortedMap-`remove` parity) and returns
/// `some(value)` via the shared `do_remove`.
public fun apply_remove<K: copy + drop + store, V: store>(
    map: &mut BigSortedMap<K, V>,
    path: vector<u64>,
    child_idxs: vector<u64>,
    leaf_id: u64,
    found: bool,
    idx: u64,
): Option<V> {
    if (!found) {
        option::none()
    } else {
        let (_k, v) = do_remove(map, &path, &child_idxs, leaf_id, idx);
        option::some(v)
    }
}

// === Pop extremes + bounded drain ===

//
// `pop_front`/`pop_back` remove the global min/max via a POSITIONAL descent (always the leftmost
// / rightmost child - no comparator) to record the path the rebalance needs, then reuse
// `do_remove`. They are the paged-drain primitives: safe to call even when the comparator is
// unavailable at teardown. Each call is a fresh O(depth) descent, so `pop_*_n` cost is
// ~n * depth df loads - size the page to stay under the df-access cap.

/// Remove and return the smallest entry `(key, value)`. The empty check is the FIRST statement,
/// before any leaf load. Length -1.
///
/// #### Aborts
/// - `EEmpty` if the tree is empty.
public fun pop_front<K: copy + drop + store, V: store>(map: &mut BigSortedMap<K, V>): (K, V) {
    assert!(map.length > 0, EEmpty); // empty check first
    let (path, child_idxs) = descend_leftmost(map);
    let leaf_id = *path.borrow(path.length() - 1);
    do_remove(map, &path, &child_idxs, leaf_id, 0) // the min is at index 0 of the leftmost leaf
}

/// Remove and return the largest entry `(key, value)`. Length -1. Triggers the delete-max
/// routing cascade (it removes a leaf's max).
///
/// #### Aborts
/// - `EEmpty` if the tree is empty.
public fun pop_back<K: copy + drop + store, V: store>(map: &mut BigSortedMap<K, V>): (K, V) {
    assert!(map.length > 0, EEmpty); // empty check first
    let (path, child_idxs) = descend_rightmost(map);
    let leaf_id = *path.borrow(path.length() - 1);
    let last_idx = node_len(borrow_node(map, leaf_id)) - 1;
    do_remove(map, &path, &child_idxs, leaf_id, last_idx)
}

/// Drain up to `n` entries from the front in ascending key order, as parallel `(keys, values)`
/// vectors (Move cannot put a tuple in a vector, so `vector<(K,V)>` is realized as two aligned
/// vectors). STOPS at empty without aborting and `n == 0` returns empty pair. Size `n`
/// to a measured safe page: cost is ~n * depth df loads.
public fun pop_front_n<K: copy + drop + store, V: store>(
    map: &mut BigSortedMap<K, V>,
    n: u64,
): (vector<K>, vector<V>) {
    let mut keys = vector[];
    let mut vals = vector[];
    let mut i = 0;
    while (i < n && map.length > 0) {
        let (k, v) = pop_front(map);
        keys.push_back(k);
        vals.push_back(v);
        i = i + 1;
    };
    (keys, vals)
}

/// Drain up to `n` entries from the back in DESCENDING key order (pop order), as parallel
/// `(keys, values)` vectors. STOPS at empty without aborting; `n == 0` returns empty.
public fun pop_back_n<K: copy + drop + store, V: store>(
    map: &mut BigSortedMap<K, V>,
    n: u64,
): (vector<K>, vector<V>) {
    let mut keys = vector[];
    let mut vals = vector[];
    let mut i = 0;
    while (i < n && map.length > 0) {
        let (k, v) = pop_back(map);
        keys.push_back(k);
        vals.push_back(v);
        i = i + 1;
    };
    (keys, vals)
}

// === Ordered navigation + bounded iteration ===

//
// Pure total reads over the GLOBAL ordered sequence, crossing leaf boundaries via the
// doubly-linked chain. Each is a single comparator descent (`find_path_by!`) handing
// off to a positional regular fun that reads the leaf and, when the answer is in an adjacent
// leaf, follows one chain link. Inclusive-flag semantics mirror `SortedMap` exactly.

/// Resolve `find_next` from a descent result: smallest key `>= from` when `include`, else
/// `> from`. Positional; follows one `leaf_next` link when the answer is the next leaf's head.
public fun next_key_from<K: copy + drop + store, V: store>(
    map: &BigSortedMap<K, V>,
    leaf_id: u64,
    found: bool,
    idx: u64,
    include: bool,
): Option<K> {
    let n = node_leaf(borrow_node(map, leaf_id)).length();
    if (found && include) {
        option::some(*node_leaf(borrow_node(map, leaf_id)).key_at(idx))
    } else {
        // strict-after a hit advances one; a miss leaves `idx` at the first key > from (ceiling)
        let next_idx = if (found) idx + 1 else idx;
        if (next_idx < n) {
            option::some(*node_leaf(borrow_node(map, leaf_id)).key_at(next_idx))
        } else {
            first_key_of_next_leaf(map, leaf_id)
        }
    }
}

/// Resolve `find_prev` from a descent result: largest key `<= from` when `include`, else
/// `< from`. Positional; follows one `leaf_prev` link when the answer is the prev leaf's tail.
public fun prev_key_from<K: copy + drop + store, V: store>(
    map: &BigSortedMap<K, V>,
    leaf_id: u64,
    found: bool,
    idx: u64,
    include: bool,
): Option<K> {
    if (found && include) {
        option::some(*node_leaf(borrow_node(map, leaf_id)).key_at(idx))
    } else {
        // both a strict-before-hit and a miss want the largest index < `idx`
        if (idx > 0) {
            option::some(*node_leaf(borrow_node(map, leaf_id)).key_at(idx - 1))
        } else {
            last_key_of_prev_leaf(map, leaf_id)
        }
    }
}

/// Collect up to `limit` keys ascending starting at `start` in leaf `leaf_id`, following the leaf
/// chain across boundaries. Count-bounded by `out.length() < limit` (never `start +
/// limit`, which overflows near `u64::MAX`). The `limit` is the MANDATORY df-cap safety bound.
public fun collect_keys_from<K: copy + drop + store, V: store>(
    map: &BigSortedMap<K, V>,
    leaf_id: u64,
    start: u64,
    limit: u64,
): vector<K> {
    let mut out = vector[];
    let mut cur = leaf_id;
    let mut i = start;
    while (cur != NULL_INDEX && out.length() < limit) {
        let node = borrow_node(map, cur);
        let leaf = node_leaf(node);
        let n = leaf.length();
        while (i < n && out.length() < limit) {
            out.push_back(*leaf.key_at(i));
            i = i + 1;
        };
        cur = leaf_next(node);
        i = 0; // subsequent leaves start at their head
    };
    out
}

/// Smallest key `>= key` when `include` (ceiling), else `> key` (strict next); `none` if none.
public macro fun find_next_by<$K: copy + drop + store, $V: store>(
    $map: &BigSortedMap<$K, $V>,
    $key: &$K,
    $include: bool,
    $lt: |&$K, &$K| -> bool,
): Option<$K> {
    let map = $map;
    let include = $include;
    let (leaf_id, _path, _child_idxs, found, idx) = find_path_by!(map, $key, $lt);
    next_key_from(map, leaf_id, found, idx, include)
}

/// `find_next_by` with the built-in integer `<`.
public macro fun find_next<$K: copy + drop + store, $V: store>(
    $map: &BigSortedMap<$K, $V>,
    $key: &$K,
    $include: bool,
): Option<$K> {
    find_next_by!($map, $key, $include, |a, b| *a < *b)
}

/// Largest key `<= key` when `include` (floor), else `< key` (strict prev); `none` if none.
public macro fun find_prev_by<$K: copy + drop + store, $V: store>(
    $map: &BigSortedMap<$K, $V>,
    $key: &$K,
    $include: bool,
    $lt: |&$K, &$K| -> bool,
): Option<$K> {
    let map = $map;
    let include = $include;
    let (leaf_id, _path, _child_idxs, found, idx) = find_path_by!(map, $key, $lt);
    prev_key_from(map, leaf_id, found, idx, include)
}

/// `find_prev_by` with the built-in integer `<`.
public macro fun find_prev<$K: copy + drop + store, $V: store>(
    $map: &BigSortedMap<$K, $V>,
    $key: &$K,
    $include: bool,
): Option<$K> {
    find_prev_by!($map, $key, $include, |a, b| *a < *b)
}

/// Smallest key strictly greater than `key`, or `none` (the forward-cursor termination signal).
public macro fun next_key_by<$K: copy + drop + store, $V: store>(
    $map: &BigSortedMap<$K, $V>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): Option<$K> {
    find_next_by!($map, $key, false, $lt)
}

/// `next_key_by` with the built-in integer `<`.
public macro fun next_key<$K: copy + drop + store, $V: store>(
    $map: &BigSortedMap<$K, $V>,
    $key: &$K,
): Option<$K> {
    find_next_by!($map, $key, false, |a, b| *a < *b)
}

/// Largest key strictly less than `key`, or `none` (the backward-cursor termination signal).
public macro fun prev_key_by<$K: copy + drop + store, $V: store>(
    $map: &BigSortedMap<$K, $V>,
    $key: &$K,
    $lt: |&$K, &$K| -> bool,
): Option<$K> {
    find_prev_by!($map, $key, false, $lt)
}

/// `prev_key_by` with the built-in integer `<`.
public macro fun prev_key<$K: copy + drop + store, $V: store>(
    $map: &BigSortedMap<$K, $V>,
    $key: &$K,
): Option<$K> {
    find_prev_by!($map, $key, false, |a, b| *a < *b)
}

/// Up to `limit` keys ascending, a contiguous run from the first key `>= from` (when `include`)
/// or `> from` (strict). `limit` is a MANDATORY safety bound, not a convenience: an unbounded
/// scan loads ~k/ceil(leaf/2) leaves and breaches the df-access cap. Page by passing
/// the last returned key back with `include == false`.
public macro fun keys_from_by<$K: copy + drop + store, $V: store>(
    $map: &BigSortedMap<$K, $V>,
    $from: &$K,
    $include: bool,
    $limit: u64,
    $lt: |&$K, &$K| -> bool,
): vector<$K> {
    let map = $map;
    let include = $include;
    let limit = $limit;
    let (leaf_id, _path, _child_idxs, found, idx) = find_path_by!(map, $from, $lt);
    // skip an exact hit only when the boundary is exclusive; on a miss `idx` is already the ceiling
    let start = if (found && !include) idx + 1 else idx;
    collect_keys_from(map, leaf_id, start, limit)
}

/// `keys_from_by` with the built-in integer `<`.
public macro fun keys_from<$K: copy + drop + store, $V: store>(
    $map: &BigSortedMap<$K, $V>,
    $from: &$K,
    $include: bool,
    $limit: u64,
): vector<$K> {
    keys_from_by!($map, $from, $include, $limit, |a, b| *a < *b)
}

// === Cross-tier bridge ===

//
// `from_sorted_map` and `into_sorted_map` conserve every (K,V) and both move (never
// copy/drop) values. They use BULK node-level moves, NOT per-element loops: a per-element
// build/drain would be O(n * depth) df accesses and breach the ~1000-df cap for a tier-1-sized
// source. `from_sorted_map` re-validates source order BEFORE any df write; the build
// distributes entries EVENLY so every node stays >= ceil(m/2) including the tail.

/// Abort `ESourceNotSortedUnderComparator` if `ok` is false. Routed through this fun so
/// the abort pins at this module's location (the macro can't reference the private error const).
///
/// #### Aborts
/// - `ESourceNotSortedUnderComparator` if `ok` is false.
public fun assert_source_sorted(ok: bool) {
    assert!(ok, ESourceNotSortedUnderComparator);
}

/// Assert the source `SortedMap` is strictly increasing under `$lt`, BEFORE any df write.
/// One comparator macro expansion; pairs with the positional builder.
///
/// #### Aborts
/// - `ESourceNotSortedUnderComparator` if the source is not strictly increasing under `$lt`.
public macro fun assert_source_sorted_by<$K: copy + drop + store, $V: store>(
    $source: &SortedMap<$K, $V>,
    $lt: |&$K, &$K| -> bool,
) {
    let src = $source;
    let es = src.entries_ref();
    let n = es.length();
    let mut ok = true;
    let mut i = 1;
    while (i < n) {
        if (!$lt(es.borrow(i - 1).entry_key(), es.borrow(i).entry_key())) {
            ok = false;
            break
        };
        i = i + 1;
    };
    assert_source_sorted(ok);
}

/// Positional bulk build of a tree from a pre-validated sorted source at default degrees.
public fun build_from_sorted_default<K: copy + drop + store, V: store>(
    source: SortedMap<K, V>,
    ctx: &mut TxContext,
): BigSortedMap<K, V> {
    build_from_sorted(source, DEFAULT_INNER_MAX_DEGREE, DEFAULT_LEAF_MAX_DEGREE, ctx)
}

/// Positional bulk build. The source MUST already be strictly increasing under
/// the comparator (the macro re-validates first). Distributes entries EVENLY across leaves, then
/// builds inner levels bottom-up the same way, so every node - including each level's rightmost
/// - holds >= ceil(m/2) entries. ~1 df add per node, so a tier-1-sized source fits the
/// df cap. Values are MOVED (the source's `SortedMap`s become node payloads) - no copy/drop.
///
/// #### Aborts
///
/// - `EInvalidDegree` if `leaf_max_degree` or `inner_max_degree` is below the min-fill
///   floor (via `new_with_config`).
public fun build_from_sorted<K: copy + drop + store, V: store>(
    source: SortedMap<K, V>,
    inner_max_degree: u64,
    leaf_max_degree: u64,
    ctx: &mut TxContext,
): BigSortedMap<K, V> {
    let mut map = new_with_config<K, V>(inner_max_degree, leaf_max_degree, ctx);
    let n = source.length();
    if (n == 0) {
        source.destroy_empty();
        return map
    };
    if (n <= leaf_max_degree) {
        // Fits one leaf: move the source straight into the (empty) inline root leaf.
        node_leaf_mut(borrow_node_mut(&mut map, ROOT_INDEX)).append(source);
        map.length = n;
        return map
    };
    // Phase 1 - leaves, built RIGHT-TO-LEFT by BACK-peeling: each `split_off` returns only the
    // small tail chunk (O(chunk)), so the whole pass is O(n). Front-peeling would return the big
    // remainder every time - O(n^2/m), which for a near-max tier-1 source approaches the compute
    // budget. leaf_count = ceil(n/m); even distribution keeps every leaf (incl. the tail) at
    // >= ceil(m/2).
    let leaf_count = (n + leaf_max_degree - 1) / leaf_max_degree;
    let base = n / leaf_count;
    let extra = n % leaf_count;
    let mut remaining = source; // holds [0, cum)
    let mut cum = n;
    let mut ids_rev = vector[]; // leaf ids, right-to-left (reversed before Phase 2)
    let mut maxes_rev = vector[]; // leaf subtree maxes, right-to-left
    let mut right_id = NULL_INDEX; // the already-built leaf immediately to the right
    let mut li = leaf_count;
    while (li > 0) {
        li = li - 1;
        let csize = base + if (li < extra) 1 else 0;
        let at = cum - csize;
        let chunk = remaining.split_off(at); // chunk = [at, cum), the small tail
        cum = at;
        let cmax = *chunk.key_at(csize - 1);
        let id = alloc_id(&mut map);
        // next = the right neighbour (built last iteration); prev is set when the left neighbour builds
        add_node(&mut map, id, leaf_node_with(chunk, NULL_INDEX, right_id));
        if (right_id != NULL_INDEX) {
            set_node_prev(borrow_node_mut(&mut map, right_id), id);
        } else {
            map.max_leaf_index = id; // first built == rightmost leaf
        };
        ids_rev.push_back(id);
        maxes_rev.push_back(cmax);
        right_id = id;
    };
    remaining.destroy_empty(); // [0,0) - fully consumed
    map.min_leaf_index = right_id; // last built == leftmost leaf
    ids_rev.reverse(); // -> left-to-right for the bottom-up inner build
    maxes_rev.reverse();
    let mut level_ids = ids_rev;
    let mut level_maxes = maxes_rev;
    // Phase 2 - inner levels, bottom-up, same even distribution, until one node remains.
    while (level_ids.length() > 1) {
        let m = level_ids.length();
        let pcount = (m + inner_max_degree - 1) / inner_max_degree;
        let pbase = m / pcount;
        let pextra = m % pcount;
        let mut parent_ids = vector[];
        let mut parent_maxes = vector[];
        let mut consumed = 0;
        let mut pi = 0;
        while (pi < pcount) {
            let psize = pbase + if (pi < pextra) 1 else 0;
            let mut routing = sorted_map::new<K, u64>();
            let mut j = 0;
            while (j < psize) {
                let cid = *level_ids.borrow(consumed + j);
                let cmax = *level_maxes.borrow(consumed + j);
                routing.insert_at(j, sorted_map::make_entry(cmax, cid));
                j = j + 1;
            };
            let pmax = *level_maxes.borrow(consumed + psize - 1);
            let pid = alloc_id(&mut map);
            add_node(&mut map, pid, inner_node_with(routing, NULL_INDEX, NULL_INDEX));
            parent_ids.push_back(pid);
            parent_maxes.push_back(pmax);
            consumed = consumed + psize;
            pi = pi + 1;
        };
        level_ids = parent_ids;
        level_maxes = parent_maxes;
    };
    // Promote the single top node into the inline root, discarding the empty starter root.
    let top = remove_node(&mut map, *level_ids.borrow(0));
    destroy_empty_node(take_root(&mut map));
    fill_root(&mut map, top);
    map.length = n;
    map
}

/// Drain the tree IN PLACE (NOT by-value) into a returned `SortedMap`, leaving an emptied
/// `BigSortedMap` for the caller to `destroy_empty`. The capacity heuristic is
/// statement 1, so on the abort path the tree is INTACT (no (K,V) lost). Bulk: collects data via
/// the leaf chain (ascending) and frees inner nodes via a cheap inner-only traversal.
///
/// #### Aborts
/// - `EWouldExceedTier1EntryHeuristic` if the drained map would exceed the tier-1 entry
///   heuristic (`MAX_TIER1_ENTRY_COUNT`).
public fun into_sorted_map<K: copy + drop + store, V: store>(
    map: &mut BigSortedMap<K, V>,
): SortedMap<K, V> {
    assert!(map.length <= MAX_TIER1_ENTRY_COUNT, EWouldExceedTier1EntryHeuristic); // stmt 1
    let mut result = sorted_map::new<K, V>();
    if (map.length == 0) {
        return result
    };
    if (map.min_leaf_index == ROOT_INDEX) {
        // Single-leaf root (depth 0): move its data out, reinstall a fresh empty leaf root.
        let Node { is_leaf: _, leaf, inner, prev: _, next: _ } = take_root(map);
        result.append(leaf);
        inner.destroy_empty();
        fill_root(map, new_leaf(NULL_INDEX, NULL_INDEX));
        map.length = 0;
        return result
    };
    // Depth >= 1: collect df inner ids (read-only), free leaves via the chain (ascending) moving
    // their data into `result`, then free the inner nodes, then reset the inline root.
    let inner_ids = collect_inner_ids(map);
    let mut cur = map.min_leaf_index;
    while (cur != NULL_INDEX) {
        let next = leaf_next(borrow_node(map, cur));
        let Node { is_leaf: _, leaf, inner, prev: _, next: _ } = remove_node(map, cur);
        result.append(leaf); // ascending, disjoint -> stays sorted
        inner.destroy_empty(); // dormant-empty
        cur = next;
    };
    let mut k = 0;
    while (k < inner_ids.length()) {
        destroy_inner_node(remove_node(map, *inner_ids.borrow(k)));
        k = k + 1;
    };
    destroy_inner_node(take_root(map)); // the old inline inner root
    fill_root(map, new_leaf(NULL_INDEX, NULL_INDEX));
    map.length = 0;
    map.min_leaf_index = ROOT_INDEX;
    map.max_leaf_index = ROOT_INDEX;
    result
}

/// Build a tree from a `SortedMap` at default degrees, under `$lt`. Re-validates source order
/// BEFORE any df write. Conserves every (K,V).
///
/// #### Aborts
/// - `ESourceNotSortedUnderComparator` if the source is not strictly increasing under `$lt`.
public macro fun from_sorted_map_by<$K: copy + drop + store, $V: store>(
    $source: SortedMap<$K, $V>,
    $lt: |&$K, &$K| -> bool,
    $ctx: &mut TxContext,
): BigSortedMap<$K, $V> {
    let source = $source;
    assert_source_sorted_by!(&source, $lt);
    build_from_sorted_default(source, $ctx)
}

/// `from_sorted_map_by` with the built-in integer `<`.
///
/// #### Aborts
/// - `ESourceNotSortedUnderComparator` if the source is not strictly increasing.
public macro fun from_sorted_map<$K: copy + drop + store, $V: store>(
    $source: SortedMap<$K, $V>,
    $ctx: &mut TxContext,
): BigSortedMap<$K, $V> {
    from_sorted_map_by!($source, |a, b| *a < *b, $ctx)
}

/// `from_sorted_map_by` with explicit degrees (parity with `new_with_config`; lets a migration
/// match an existing tree's degrees). Asserts the min-degree floor via `new_with_config`.
///
/// #### Aborts
/// - `ESourceNotSortedUnderComparator` if the source is not strictly increasing under `$lt`.
/// - `EInvalidDegree` if a degree is below the floor (via `new_with_config`).
public macro fun from_sorted_map_with_config_by<$K: copy + drop + store, $V: store>(
    $source: SortedMap<$K, $V>,
    $inner_max_degree: u64,
    $leaf_max_degree: u64,
    $lt: |&$K, &$K| -> bool,
    $ctx: &mut TxContext,
): BigSortedMap<$K, $V> {
    let source = $source;
    assert_source_sorted_by!(&source, $lt);
    build_from_sorted(source, $inner_max_degree, $leaf_max_degree, $ctx)
}

/// `from_sorted_map_with_config_by` with the built-in integer `<`.
///
/// #### Aborts
/// - `ESourceNotSortedUnderComparator` if the source is not strictly increasing.
/// - `EInvalidDegree` if a degree is below the floor (via `new_with_config`).
public macro fun from_sorted_map_with_config<$K: copy + drop + store, $V: store>(
    $source: SortedMap<$K, $V>,
    $inner_max_degree: u64,
    $leaf_max_degree: u64,
    $ctx: &mut TxContext,
): BigSortedMap<$K, $V> {
    from_sorted_map_with_config_by!(
        $source,
        $inner_max_degree,
        $leaf_max_degree,
        |a, b| *a < *b,
        $ctx,
    )
}

// === Private Functions ===

// === Node construction funnels ===

//
// Nodes are born ONLY here: each sets `is_leaf` once and leaves the dormant map empty
// by construction, so the "exactly one map populated" convention holds at birth. `is_leaf` is
// never written again - there is no flip path. Private: only `new*`, the cascade, and the
// first-split relocation create nodes, all within this module (no macro references them).

/// A fresh empty leaf node with the given sibling links. `inner` is dormant-empty.
fun new_leaf<K: copy + drop + store, V: store>(prev: u64, next: u64): Node<K, V> {
    Node { is_leaf: true, leaf: sorted_map::new(), inner: sorted_map::new(), prev, next }
}

/// A fresh empty inner node with the given sibling links. `leaf` is dormant-empty. The caller
/// populates `inner` with `(subtreeMax -> childId)` routing entries via the asserting accessors.
fun new_inner<K: copy + drop + store, V: store>(prev: u64, next: u64): Node<K, V> {
    Node { is_leaf: false, leaf: sorted_map::new(), inner: sorted_map::new(), prev, next }
}

// === Asserting node accessors ===

/// Mutable view of an inner node's routing map. Aborts `EWrongNodeKind` on a leaf.
fun node_inner_mut<K: copy + drop + store, V: store>(n: &mut Node<K, V>): &mut SortedMap<K, u64> {
    assert!(!n.is_leaf, EWrongNodeKind);
    &mut n.inner
}

// === Arena / addressing ===

/// Return a fresh, never-reused node id (`>= FIRST_ALLOC_INDEX`) and advance the counter.
/// No free list - a freed id is permanently retired. The first call returns
/// `FIRST_ALLOC_INDEX (2)`, so a live id never collides with `NULL_INDEX`/`ROOT_INDEX`.
fun alloc_id<K: copy + drop + store, V: store>(map: &mut BigSortedMap<K, V>): u64 {
    let id = map.next_node_index;
    map.next_node_index = id + 1;
    id
}

/// Install `node` as a df under `id`. Sole df inserter; `id` is always an `alloc_id`
/// result (`>= 2`), never `ROOT_INDEX`/`NULL_INDEX`. Aborts inside `dynamic_field` on a
/// duplicate id (an indirect backstop against live-id reuse).
fun add_node<K: copy + drop + store, V: store>(
    map: &mut BigSortedMap<K, V>,
    id: u64,
    node: Node<K, V>,
) {
    df::add(&mut map.id, id, node);
}

/// Remove and return the df node under `id`. Sole df remover; the id is NOT returned
/// to any free list. Aborts inside `dynamic_field` if `id` is absent.
fun remove_node<K: copy + drop + store, V: store>(
    map: &mut BigSortedMap<K, V>,
    id: u64,
): Node<K, V> {
    df::remove(&mut map.id, id)
}

/// Move the inline root OUT, leaving `root == None`. Pairs with `fill_root` inside a
/// single uninterrupted op, so the None window never spans a public-call boundary. Aborts (in
/// `option`) on a second `take_root` without an intervening `fill_root` - a loud fail.
fun take_root<K: copy + drop + store, V: store>(map: &mut BigSortedMap<K, V>): Node<K, V> {
    map.root.extract()
}

/// Move `node` INTO the (currently `None`) inline root slot. Pairs with `take_root`.
fun fill_root<K: copy + drop + store, V: store>(map: &mut BigSortedMap<K, V>, node: Node<K, V>) {
    map.root.fill(node);
}

// === Routing / child navigation ===

/// Rewrite the routing key at index `idx` to `new_key`, keeping the same child id at the same
/// position. Keys are immutable, so this is a positional remove-then-reinsert at `idx`.
/// Precondition (caller's, by construction): `new_key` keeps the routing map sorted at `idx` -
/// true for the right-spine bump (new_key > all, idx is last) and the delete-max cascade
/// (new_key stays strictly between the idx-1 and idx+1 routing keys, because the child's key
/// RANGE relative to its siblings is unchanged).
fun set_routing_key_at<K: copy + drop + store, V: store>(n: &mut Node<K, V>, idx: u64, new_key: K) {
    let inner = node_inner_mut(n);
    let child_id = inner.remove_at(idx); // returns the u64 child id (move out)
    inner.insert_at(idx, sorted_map::make_entry(new_key, child_id));
}

// === Leaf-link setters ===

fun set_node_next<K: copy + drop + store, V: store>(n: &mut Node<K, V>, next: u64) {
    n.next = next;
}

fun set_node_prev<K: copy + drop + store, V: store>(n: &mut Node<K, V>, prev: u64) {
    n.prev = prev;
}

// === Lifecycle ===

/// Destructure an EMPTY node (both maps drained). Used only by `destroy_empty` and the cascade
/// when a node's payload has already been moved out. Both `destroy_empty` calls are
/// construction-safe (the maps are empty); for a non-drop `V` there is no value to leak.
fun destroy_empty_node<K: copy + drop + store, V: store>(node: Node<K, V>) {
    let Node { is_leaf: _, leaf, inner, prev: _, next: _ } = node;
    leaf.destroy_empty();
    inner.destroy_empty();
}

// === Insert ===

/// Build a leaf `Node` around an already-populated data map (the dormant routing map is empty).
fun leaf_node_with<K: copy + drop + store, V: store>(
    leaf: SortedMap<K, V>,
    prev: u64,
    next: u64,
): Node<K, V> {
    Node { is_leaf: true, leaf, inner: sorted_map::new(), prev, next }
}

/// Build an inner `Node` around an already-populated routing map (the dormant data map is empty).
fun inner_node_with<K: copy + drop + store, V: store>(
    inner: SortedMap<K, u64>,
    prev: u64,
    next: u64,
): Node<K, V> {
    Node { is_leaf: false, leaf: sorted_map::new(), inner, prev, next }
}

/// True iff node `id` holds MORE than its kind's max degree (the split trigger). Scoped so the
/// immutable node borrow ends before the caller re-borrows `&mut`.
fun node_overflows<K: copy + drop + store, V: store>(map: &BigSortedMap<K, V>, id: u64): bool {
    let node = borrow_node(map, id);
    let max_degree = if (is_leaf(node)) map.leaf_max_degree else map.inner_max_degree;
    node_len(node) > max_degree
}

/// Walk the path from the leaf's parent upward, refreshing each ancestor routing key to `new_key`
/// while the touched child is that ancestor's LAST child (so its subtree max equals `new_key`).
/// Stop at the first ancestor where it is not the last child (its max is unchanged). Unifies the
/// new-global-max right-spine bump, the interior-leaf-max update, and the coarse-comparator byte
/// refresh. Positional: each rewrite is a same-index remove+reinsert.
fun refresh_max_along_path<K: copy + drop + store, V: store>(
    map: &mut BigSortedMap<K, V>,
    path: &vector<u64>,
    child_idxs: &vector<u64>,
    new_key: K,
) {
    let mut j = child_idxs.length();
    while (j > 0) {
        j = j - 1;
        let ancestor_id = *path.borrow(j);
        let ci = *child_idxs.borrow(j);
        // The descended child's subtree-max became `new_key`, so its routing key at THIS ancestor
        // MUST be rewritten regardless of the child's position - including an INTERIOR (non-last)
        // child (the delete-max / byte-refresh case; omitting this write strands a stale-high
        // routing key).
        let is_last = ci + 1 == node_len(borrow_node(map, ancestor_id));
        set_routing_key_at(borrow_node_mut(map, ancestor_id), ci, copy new_key);
        // Ascend only if this child was the ancestor's LAST child - then the ancestor's OWN max
        // also became `new_key`; otherwise the ancestor's max is unchanged and we stop.
        if (!is_last) break;
    }
}

/// Split every node on the path that overflowed, bottom-up, until one does not (or the root
/// splits). At a non-root level, `split_child` rebuilds the child in place; at the root,
/// `split_root` grows height by one. `child_idxs[i-1]` locates `path[i]` in its parent.
fun cascade_after_insert<K: copy + drop + store, V: store>(
    map: &mut BigSortedMap<K, V>,
    path: &vector<u64>,
    child_idxs: &vector<u64>,
) {
    let mut i = path.length() - 1; // start at the leaf
    loop {
        if (!node_overflows(map, *path.borrow(i))) break;
        if (i == 0) {
            split_root(map); // root overflow: the only height-increase path
            break
        };
        split_child(map, *path.borrow(i - 1), *child_idxs.borrow(i - 1));
        i = i - 1;
    }
}

/// Split the (non-root) child at routing index `ci` of `parent_id`. Remove the
/// child, partition its map at `(max_degree+1)/2` via `split_off`, and rebuild: the LARGER-keys
/// (right) half re-takes the ORIGINAL `child_id` (its parent routing key = old max stays correct
/// - no rewrite), the SMALLER-keys (left) half gets a NEW id whose routing entry (= left max) is
/// inserted at `ci` (shifting the right entry to `ci+1`). The unified copy-up kernel: NOTHING is
/// removed/moved up; the left max merely STAYS in the left half. Leaf splits also
/// splice the new left leaf into the doubly-linked chain.
fun split_child<K: copy + drop + store, V: store>(
    map: &mut BigSortedMap<K, V>,
    parent_id: u64,
    ci: u64,
) {
    let child_id = child_id_at(borrow_node(map, parent_id), ci);
    let Node { is_leaf, leaf, inner, prev, next } = remove_node(map, child_id);
    let left_id = alloc_id(map);
    let left_max = if (is_leaf) {
        let mut data = leaf;
        inner.destroy_empty(); // dormant-empty
        let target = (map.leaf_max_degree + 1) / 2;
        let right_half = data.split_off(target); // data=[0,target) LEFT; right_half=RIGHT
        let left_node = leaf_node_with(data, prev, child_id);
        let right_node = leaf_node_with(right_half, left_id, next);
        let lm = max_key(&left_node);
        add_node(map, left_id, left_node);
        add_node(map, child_id, right_node); // RIGHT keeps the original id
        // Chain fixup: the left leaf is spliced BEFORE child_id; the old next's prev is still
        // child_id (right kept the id), so only the old prev's `next` and `min_leaf_index` move.
        if (prev != NULL_INDEX) {
            set_node_next(borrow_node_mut(map, prev), left_id);
        };
        if (map.min_leaf_index == child_id) {
            map.min_leaf_index = left_id;
        };
        lm
    } else {
        let mut routing = inner;
        leaf.destroy_empty(); // dormant-empty
        let target = (map.inner_max_degree + 1) / 2;
        let right_half = routing.split_off(target);
        let left_node = inner_node_with(routing, prev, child_id);
        let right_node = inner_node_with(right_half, left_id, next);
        let lm = max_key(&left_node);
        add_node(map, left_id, left_node);
        add_node(map, child_id, right_node); // RIGHT keeps the original id
        lm // inner split: no leaf-chain / min-max fixup (leaves are deeper)
    };
    // Insert the left half's routing entry at the recorded descent index (NOT at the
    // parent's end, which would misorder a non-rightmost-child split).
    node_inner_mut(borrow_node_mut(map, parent_id)).insert_at(
        ci,
        sorted_map::make_entry(left_max, left_id),
    );
}

/// Split the overflowing INLINE root, growing height by one - the only height-increase path.
/// Partition the old root at `(max_degree+1)/2` into two fresh df nodes (left_id,
/// right_id - exactly TWO allocs), then build a NEW inner root inline at ROOT_INDEX
/// (no alloc) routing to both. On the FIRST split (a leaf root) this also seeds the leaf chain
/// and `min`/`max_leaf_index`; a subsequent inner-root split leaves the leaf chain untouched.
fun split_root<K: copy + drop + store, V: store>(map: &mut BigSortedMap<K, V>) {
    let Node { is_leaf, leaf, inner, prev: _, next: _ } = take_root(map); // root transiently None
    let left_id = alloc_id(map);
    let right_id = alloc_id(map);
    let (left_max, right_max) = if (is_leaf) {
        let mut data = leaf;
        inner.destroy_empty();
        let target = (map.leaf_max_degree + 1) / 2;
        let right_half = data.split_off(target);
        // The two leaves are the whole chain now: left is leftmost (prev NULL), right is rightmost.
        let left_node = leaf_node_with(data, NULL_INDEX, right_id);
        let right_node = leaf_node_with(right_half, left_id, NULL_INDEX);
        let lm = max_key(&left_node);
        let rm = max_key(&right_node);
        add_node(map, left_id, left_node);
        add_node(map, right_id, right_node);
        map.min_leaf_index = left_id;
        map.max_leaf_index = right_id;
        (lm, rm)
    } else {
        let mut routing = inner;
        leaf.destroy_empty();
        let target = (map.inner_max_degree + 1) / 2;
        let right_half = routing.split_off(target);
        let left_node = inner_node_with(routing, NULL_INDEX, NULL_INDEX);
        let right_node = inner_node_with(right_half, NULL_INDEX, NULL_INDEX);
        let lm = max_key(&left_node);
        let rm = max_key(&right_node);
        add_node(map, left_id, left_node);
        add_node(map, right_id, right_node);
        (lm, rm) // inner-root split: leaf chain + min/max_leaf_index unchanged
    };
    let mut new_root = new_inner(NULL_INDEX, NULL_INDEX);
    let routing = node_inner_mut(&mut new_root);
    routing.insert_at(0, sorted_map::make_entry(left_max, left_id));
    routing.insert_at(1, sorted_map::make_entry(right_max, right_id));
    fill_root(map, new_root);
}

// === Remove + rebalance ===

/// The shared positional removal: delete entry `idx` from leaf `leaf_id` (returning its key AND
/// value - so `pop_*` can reuse this), maintain the cached `length` by -1, run the
/// delete-max routing cascade if the leaf's max was removed, then the borrow-then-merge
/// rebalance. Used by `apply_remove` and `pop_front`/`pop_back`/`pop_*_n`.
fun do_remove<K: copy + drop + store, V: store>(
    map: &mut BigSortedMap<K, V>,
    path: &vector<u64>,
    child_idxs: &vector<u64>,
    leaf_id: u64,
    idx: u64,
): (K, V) {
    let leaf = node_leaf_mut(borrow_node_mut(map, leaf_id));
    let len_before = leaf.length();
    let k = *leaf.key_at(idx); // copy the key out before remove_at drops it
    let v = leaf.remove_at(idx);
    map.length = map.length - 1;
    let new_len = len_before - 1;
    // removed the leaf's max and the leaf is still non-empty -> its subtree-max shrank;
    // cascade a routing-key update to the new max up the right spine (before any rebalance).
    if (idx == new_len && new_len > 0) {
        let new_max = max_key(borrow_node(map, leaf_id));
        refresh_max_along_path(map, path, child_idxs, new_max);
    };
    cascade_after_remove(map, path, child_idxs);
    (k, v)
}

/// True iff node `id` holds FEWER than its kind's half-full floor `ceil(m/2)` (the rebalance
/// trigger). The root is exempt (callers only test non-root nodes).
fun node_underflows<K: copy + drop + store, V: store>(map: &BigSortedMap<K, V>, id: u64): bool {
    let node = borrow_node(map, id);
    let max_degree = if (is_leaf(node)) map.leaf_max_degree else map.inner_max_degree;
    node_len(node) < (max_degree + 1) / 2 // ceil(m/2)
}

/// True iff the sibling at routing index `sib_ci` of `parent_id` has an entry to spare (strictly
/// above the half-full floor), so borrowing one keeps it legal.
fun sibling_has_spare<K: copy + drop + store, V: store>(
    map: &BigSortedMap<K, V>,
    parent_id: u64,
    sib_ci: u64,
): bool {
    let sib_id = child_id_at(borrow_node(map, parent_id), sib_ci);
    let node = borrow_node(map, sib_id);
    let max_degree = if (is_leaf(node)) map.leaf_max_degree else map.inner_max_degree;
    node_len(node) > (max_degree + 1) / 2
}

/// Bottom-up borrow-then-merge rebalance after a removal. At each underfull non-root level,
/// borrow from a spare adjacent sibling (resolves the underflow without changing the parent ->
/// stop) else merge (shrinks the parent -> continue up). At the root, collapse if it became a
/// single-child inner node (the only height-decrease path).
fun cascade_after_remove<K: copy + drop + store, V: store>(
    map: &mut BigSortedMap<K, V>,
    path: &vector<u64>,
    child_idxs: &vector<u64>,
) {
    let mut i = path.length() - 1; // start at the leaf
    loop {
        if (i == 0) {
            maybe_collapse_root(map);
            break
        };
        if (!node_underflows(map, *path.borrow(i))) break;
        let merged = rebalance_child(map, *path.borrow(i - 1), *child_idxs.borrow(i - 1));
        if (!merged) break; // a borrow resolved it; the parent is unchanged
        i = i - 1; // a merge removed a child from the parent; it may now underflow
    }
}

/// Resolve an underfull child at routing index `ci` of `parent_id`. Prefer borrowing from a spare
/// LEFT sibling, else a spare RIGHT sibling; if neither has spare, MERGE.
/// Returns true iff a merge happened (the parent lost a child).
fun rebalance_child<K: copy + drop + store, V: store>(
    map: &mut BigSortedMap<K, V>,
    parent_id: u64,
    ci: u64,
): bool {
    let child_count = node_len(borrow_node(map, parent_id));
    if (ci > 0 && sibling_has_spare(map, parent_id, ci - 1)) {
        borrow_from_left(map, parent_id, ci);
        false
    } else if (ci + 1 < child_count && sibling_has_spare(map, parent_id, ci + 1)) {
        borrow_from_right(map, parent_id, ci);
        false
    } else if (ci > 0) {
        merge_pair(map, parent_id, ci - 1); // fold child (ci) into its left sibling (ci-1)
        true
    } else {
        merge_pair(map, parent_id, ci); // leftmost child: fold its right sibling (1) into it (0)
        true
    }
}

/// Move the left sibling's MAX entry to the front of the underfull child. The child's
/// max is unchanged (it gained a new min); the left sibling's max shrank, so its parent routing
/// key (at `ci-1`) is rewritten to its new max. The child is not the parent's last (a left
/// sibling exists), so the parent's own max is unaffected.
fun borrow_from_left<K: copy + drop + store, V: store>(
    map: &mut BigSortedMap<K, V>,
    parent_id: u64,
    ci: u64,
) {
    let left_id = child_id_at(borrow_node(map, parent_id), ci - 1);
    let child_id = child_id_at(borrow_node(map, parent_id), ci);
    if (is_leaf(borrow_node(map, child_id))) {
        let (k, v) = node_leaf_mut(borrow_node_mut(map, left_id)).pop_back();
        node_leaf_mut(borrow_node_mut(map, child_id)).insert_at(
            0,
            sorted_map::make_entry(k, v),
        );
    } else {
        let (k, cid) = node_inner_mut(borrow_node_mut(map, left_id)).pop_back();
        node_inner_mut(borrow_node_mut(map, child_id)).insert_at(
            0,
            sorted_map::make_entry(k, cid),
        );
    };
    let left_new_max = max_key(borrow_node(map, left_id));
    set_routing_key_at(borrow_node_mut(map, parent_id), ci - 1, left_new_max);
}

/// Move the right sibling's MIN entry to the back of the underfull child. The child
/// gained a new max, so its parent routing key (at `ci`) is rewritten; the right sibling's max is
/// unchanged. Borrow-from-right is chosen only when a right sibling exists, so the child is not
/// the parent's last child and the parent's own max is unaffected.
fun borrow_from_right<K: copy + drop + store, V: store>(
    map: &mut BigSortedMap<K, V>,
    parent_id: u64,
    ci: u64,
) {
    let child_id = child_id_at(borrow_node(map, parent_id), ci);
    let right_id = child_id_at(borrow_node(map, parent_id), ci + 1);
    if (is_leaf(borrow_node(map, child_id))) {
        let (k, v) = node_leaf_mut(borrow_node_mut(map, right_id)).pop_front();
        let n = node_len(borrow_node(map, child_id));
        node_leaf_mut(borrow_node_mut(map, child_id)).insert_at(
            n,
            sorted_map::make_entry(k, v),
        );
    } else {
        let (k, cid) = node_inner_mut(borrow_node_mut(map, right_id)).pop_front();
        let n = node_len(borrow_node(map, child_id));
        node_inner_mut(borrow_node_mut(map, child_id)).insert_at(
            n,
            sorted_map::make_entry(k, cid),
        );
    };
    let child_new_max = max_key(borrow_node(map, child_id));
    set_routing_key_at(borrow_node_mut(map, parent_id), ci, child_new_max);
}

/// Merge the children at `left_ci` (LEFT, survivor) and `left_ci+1` (RIGHT, absorbed) of
/// `parent_id`. The right node is removed and its payload `append`ed into the left
/// (disjoint, `left.max < right.min` by adjacency); the right's routing entry is
/// removed from the parent and the left's routing key is rewritten to its new (= right's old)
/// max. Leaf merges also splice the right leaf out of the doubly-linked chain.
fun merge_pair<K: copy + drop + store, V: store>(
    map: &mut BigSortedMap<K, V>,
    parent_id: u64,
    left_ci: u64,
) {
    let left_id = child_id_at(borrow_node(map, parent_id), left_ci);
    let right_id = child_id_at(borrow_node(map, parent_id), left_ci + 1);
    let Node { is_leaf, leaf: r_leaf, inner: r_inner, prev: _, next: r_next } = remove_node(
        map,
        right_id,
    );
    if (is_leaf) {
        r_inner.destroy_empty(); // dormant-empty
        node_leaf_mut(borrow_node_mut(map, left_id)).append(r_leaf); // left absorbs right
        // Chain: skip the removed right leaf. Its old next's prev becomes left_id.
        set_node_next(borrow_node_mut(map, left_id), r_next);
        if (r_next != NULL_INDEX) {
            set_node_prev(borrow_node_mut(map, r_next), left_id);
        };
        if (map.max_leaf_index == right_id) {
            map.max_leaf_index = left_id; // the absorbed right was the rightmost leaf
        };
    } else {
        r_leaf.destroy_empty(); // dormant-empty
        node_inner_mut(borrow_node_mut(map, left_id)).append(r_inner); // left absorbs right's routing
    };
    let left_new_max = max_key(borrow_node(map, left_id));
    let parent = borrow_node_mut(map, parent_id);
    let _ = node_inner_mut(parent).remove_at(left_ci + 1); // drop the right child id
    set_routing_key_at(parent, left_ci, left_new_max); // left's routing key -> new (= right's old) max
}

/// Collapse the root if it is an INNER node reduced to a single child: promote that child into
/// the inline root slot and drop the old one-child root (exactly one df deleted, no orphan).
/// The only height-decrease path. A leaf root never collapses.
fun maybe_collapse_root<K: copy + drop + store, V: store>(map: &mut BigSortedMap<K, V>) {
    let root = borrow_node(map, ROOT_INDEX);
    if (is_leaf(root) || node_len(root) != 1) return;
    collapse_root(map);
}

/// Promote the inline root's sole child to be the new inline root. The child is pulled
/// out of the df, swapped into the root slot, and the old one-child inner root is destructured
/// (its single routing entry drained, no orphan). If the promoted child is a leaf, the tree is
/// now a single-leaf root: reset its chain links and `min`/`max_leaf_index` to ROOT_INDEX.
fun collapse_root<K: copy + drop + store, V: store>(map: &mut BigSortedMap<K, V>) {
    let child_id = child_id_at(borrow_node(map, ROOT_INDEX), 0);
    let child_node = remove_node(map, child_id);
    let old_root = take_root(map); // root transiently None
    fill_root(map, child_node); // the promoted child is now the inline root
    // Destructure the discarded one-child inner root: drain its single routing entry, free both maps.
    let Node { is_leaf: _, leaf, inner, prev: _, next: _ } = old_root;
    leaf.destroy_empty(); // dormant-empty
    let mut inner = inner;
    let _ = inner.remove_at(0); // drop the lone child id
    inner.destroy_empty();
    // If the new root is a leaf, it is the whole tree: fix its identity as the sole leaf.
    if (is_leaf(borrow_node(map, ROOT_INDEX))) {
        let r = borrow_node_mut(map, ROOT_INDEX);
        set_node_prev(r, NULL_INDEX);
        set_node_next(r, NULL_INDEX);
        map.min_leaf_index = ROOT_INDEX;
        map.max_leaf_index = ROOT_INDEX;
    }
}

// === Pop extremes ===

/// Record the root->min-leaf path by always descending child 0 (comparator-free).
fun descend_leftmost<K: copy + drop + store, V: store>(
    map: &BigSortedMap<K, V>,
): (vector<u64>, vector<u64>) {
    let mut path = vector[ROOT_INDEX];
    let mut child_idxs = vector[];
    let mut cur = ROOT_INDEX;
    loop {
        let node = borrow_node(map, cur);
        if (is_leaf(node)) break;
        cur = child_id_at(node, 0);
        child_idxs.push_back(0);
        path.push_back(cur);
    };
    (path, child_idxs)
}

/// Record the root->max-leaf path by always descending the last child (comparator-free).
fun descend_rightmost<K: copy + drop + store, V: store>(
    map: &BigSortedMap<K, V>,
): (vector<u64>, vector<u64>) {
    let mut path = vector[ROOT_INDEX];
    let mut child_idxs = vector[];
    let mut cur = ROOT_INDEX;
    loop {
        let node = borrow_node(map, cur);
        if (is_leaf(node)) break;
        let last = node_len(node) - 1;
        cur = child_id_at(node, last);
        child_idxs.push_back(last);
        path.push_back(cur);
    };
    (path, child_idxs)
}

// === Ordered navigation ===

/// First key in the prev leaf's tail / next leaf's head, used when the answer spills past a leaf
/// boundary. `none` at the chain ends.
fun first_key_of_next_leaf<K: copy + drop + store, V: store>(
    map: &BigSortedMap<K, V>,
    leaf_id: u64,
): Option<K> {
    let next = leaf_next(borrow_node(map, leaf_id));
    if (next == NULL_INDEX) {
        option::none()
    } else {
        option::some(*node_leaf(borrow_node(map, next)).key_at(0))
    }
}

fun last_key_of_prev_leaf<K: copy + drop + store, V: store>(
    map: &BigSortedMap<K, V>,
    leaf_id: u64,
): Option<K> {
    let prev = leaf_prev(borrow_node(map, leaf_id));
    if (prev == NULL_INDEX) {
        option::none()
    } else {
        let pleaf = node_leaf(borrow_node(map, prev));
        option::some(*pleaf.key_at(pleaf.length() - 1))
    }
}

// === Cross-tier bridge ===

/// Collect every df inner-node id (excluding the inline root) for teardown. Traverses ONLY inner
/// nodes: at each, it probes the first child to learn whether the children are leaves (equal
/// depth -> all children of a node are the same kind) and descends only when they are inner, so
/// it never enumerates the (many) leaves. ~O(inner-node count) df reads.
fun collect_inner_ids<K: copy + drop + store, V: store>(map: &BigSortedMap<K, V>): vector<u64> {
    let mut inner_ids = vector[];
    let mut queue = vector[ROOT_INDEX];
    while (!queue.is_empty()) {
        let id = queue.pop_back();
        if (id != ROOT_INDEX) {
            inner_ids.push_back(id);
        };
        let inner = node_inner(borrow_node(map, id));
        let c = inner.length();
        if (c > 0 && !is_leaf(borrow_node(map, *inner.value_at(0)))) {
            // children are inner nodes -> enqueue them all (leaf children are left untouched)
            let mut j = 0;
            while (j < c) {
                queue.push_back(*node_inner(borrow_node(map, id)).value_at(j));
                j = j + 1;
            };
        };
    };
    inner_ids
}

/// Destructure an inner node, draining its (droppable u64-valued) routing map. The dormant data
/// map is empty. Used only in teardown after a node's logical children/data are gone.
fun destroy_inner_node<K: copy + drop + store, V: store>(node: Node<K, V>) {
    let Node { is_leaf: _, leaf, inner, prev: _, next: _ } = node;
    leaf.destroy_empty(); // dormant-empty
    let mut inner = inner;
    while (!inner.is_empty()) {
        let _ = inner.remove_at(0); // drop key + u64 child id
    };
    inner.destroy_empty();
}

// === Test-Only Helpers ===

/// TEST ONLY. Count the live df arena nodes by probing every id ever handed out
/// (`FIRST_ALLOC_INDEX ..< next_node_index`; ids are monotone and never reused, so this range is
/// the exact universe of allocated nodes). The inline root is NOT a df, so it is never counted.
/// After a full drain to empty this must be 0 - a teardown regression that strands a node leaves
/// its df present here, so the orphan-accounting test fails loudly instead of silently leaking.
#[test_only]
public fun live_df_node_count_for_testing<K: copy + drop + store, V: store>(
    map: &BigSortedMap<K, V>,
): u64 {
    let mut count = 0;
    let mut id = FIRST_ALLOC_INDEX;
    while (id < map.next_node_index) {
        if (df::exists(&map.id, id)) count = count + 1;
        id = id + 1;
    };
    count
}

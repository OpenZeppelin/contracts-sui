/// Shared test utilities for the `big_sorted_map` (BSM) suite.
///
/// # Why thin wrappers
/// Every BSM comparator macro expands the full `find_path_by!` descent INLINE at the call site.
/// TWO such expansions in one function body overflow Move's 256-locals ceiling (`remove_by!`
/// alone is ~230/255). The whole suite therefore routes every comparator-bearing op through a
/// one-macro-per-function wrapper here; a *call* to a wrapper is a jump, not a paste, so test
/// bodies and loops stay far under the limit. This is the exact discipline a consumer must follow.
///
/// # Why structural checks live in tests
/// Because every load-bearing structural/comparator property is maintained BY CONSTRUCTION and
/// NEVER re-checked in production (an O(n) tree walk would itself breach the ~1000-df-load cap),
/// the ONLY way to catch a logical routing-key bug is in tests. This module provides BOTH halves:
///   - `bsm_well_formed` - the recursive well-formedness check: equal leaf depth, half-full
///     floor, per-node strictly-sorted, routing_key == child-subtree-max,
///     the doubly-linked leaf chain == cached length == recursive multiset,
///     and head/tail == structural global extremes.
///   - `Ref` - a trivially-correct linear sorted-vector reference model; the differential suite
///     drives BSM and `Ref` through identical op streams and asserts agreement at every step. The
///     reference model is the only catch for a logical routing-key bug that leaves the tree
///     internally self-consistent (which `bsm_well_formed` alone cannot see).
///
/// The well-formedness check is u64-key specialized (the differential/structural suites run on
/// `<u64, u64>` at forced low degree 3/4) and is unit-test-BOUNDED: trees stay tiny (far under 1000
/// nodes), so a single recursive pass suffices without paging machinery. An `ascending` flag lets it
/// validate a tree built under a reverse comparator.
///
/// # Deriving tree shape without public getters
/// The code (thin-macro architecture) exposes NO public getter for `min_leaf_index`/
/// `max_leaf_index`/`leaf_max_degree`/`inner_max_degree`. So the well-formedness check DERIVES the
/// leftmost leaf structurally (descend child 0) and takes the construction degrees as parameters;
/// the cached spine pointers are verified INDIRECTLY but robustly via `head`/`tail`/`pop_*` against
/// the structurally-computed extremes.
module openzeppelin_collections::big_sorted_map_test_util;

use openzeppelin_collections::big_sorted_map::{Self as bsm, BigSortedMap};
use openzeppelin_collections::sorted_map::{Self as sm, SortedMap};

/// The reference model's `ref_get` was called on an absent key (the differential test only
/// reads keys it has confirmed present, so this is unreachable in practice).
const EKeyNotFound: u64 = 0;

// ===========================================================================
// Witness types
// ===========================================================================

/// Non-droppable, non-copyable value witness. Storing this as V makes the compiler
/// forbid implicitly dropping a value: any test that fails to thread every value back out simply
/// will not compile, turning a silent `V: drop` conservation bug into a build error.
public struct NoDrop has store { id: u64 }

public fun nd(id: u64): NoDrop { NoDrop { id } }

public fun nd_id(w: &NoDrop): u64 { w.id }

/// Mutate a `NoDrop`'s payload IN PLACE (no drop of the old value) - used to exercise `borrow_mut`
/// over a non-droppable V (a `*ref = new` would try to drop the old NoDrop and fail to compile).
public fun nd_set_id(w: &mut NoDrop, id: u64) { w.id = id; }

/// Consume a `NoDrop`, returning its id. The only way to dispose of one (it has no `drop`).
public fun nd_unwrap(w: NoDrop): u64 {
    let NoDrop { id } = w;
    id
}

/// A "coarse" key ordered on `id` ALONE: two byte-distinct keys (same `id`, different
/// `tag`) compare equal under the comparator. Lets a test observe WHICH key bytes survive an
/// upsert and propagate into a routing key.
public struct CoarseKey has copy, drop, store { id: u64, tag: u64 }

public fun ck(id: u64, tag: u64): CoarseKey { CoarseKey { id, tag } }

public fun ck_id(k: &CoarseKey): u64 { k.id }

public fun ck_tag(k: &CoarseKey): u64 { k.tag }

/// A generic non-integer struct key ordered on `id` (`_by` demonstration).
public struct Key has copy, drop, store { id: u64 }

public fun mk(id: u64): Key { Key { id } }

public fun key_id(k: &Key): u64 { k.id }

// ===========================================================================
// Thin wrappers - u64/u64, bare forms (built-in integer `<`)
// ===========================================================================

public fun ins(m: &mut BigSortedMap<u64, u64>, k: u64, v: u64): Option<u64> {
    bsm::insert!(m, k, v)
}

public fun has(m: &BigSortedMap<u64, u64>, k: u64): bool { bsm::contains!(m, &k) }

public fun get(m: &BigSortedMap<u64, u64>, k: u64): u64 { *bsm::borrow!(m, &k) }

/// Overwrite the value at `k` in place via `borrow_mut!` (aborts `EKeyNotFound` if absent).
public fun set(m: &mut BigSortedMap<u64, u64>, k: u64, v: u64) { *bsm::borrow_mut!(m, &k) = v; }

public fun rem(m: &mut BigSortedMap<u64, u64>, k: u64): Option<u64> { bsm::remove!(m, &k) }

public fun fnext(m: &BigSortedMap<u64, u64>, k: u64, inc: bool): Option<u64> {
    bsm::find_next!(m, &k, inc)
}

public fun fprev(m: &BigSortedMap<u64, u64>, k: u64, inc: bool): Option<u64> {
    bsm::find_prev!(m, &k, inc)
}

public fun nxt(m: &BigSortedMap<u64, u64>, k: u64): Option<u64> { bsm::next_key!(m, &k) }

public fun prv(m: &BigSortedMap<u64, u64>, k: u64): Option<u64> { bsm::prev_key!(m, &k) }

public fun kfrom(m: &BigSortedMap<u64, u64>, from: u64, inc: bool, lim: u64): vector<u64> {
    bsm::keys_from!(m, &from, inc, lim)
}

public fun locate(m: &BigSortedMap<u64, u64>, k: u64): u64 { bsm::locate_leaf!(m, &k) }

// ===========================================================================
// Thin wrappers - u64/u64, reverse comparator `>` (used CONSISTENTLY: the legitimate case)
// ===========================================================================

public fun ins_rev(m: &mut BigSortedMap<u64, u64>, k: u64, v: u64): Option<u64> {
    bsm::insert_by!(m, k, v, |a, b| *a > *b)
}

public fun has_rev(m: &BigSortedMap<u64, u64>, k: u64): bool {
    bsm::contains_by!(m, &k, |a, b| *a > *b)
}

public fun get_rev(m: &BigSortedMap<u64, u64>, k: u64): u64 {
    *bsm::borrow_by!(m, &k, |a, b| *a > *b)
}

public fun rem_rev(m: &mut BigSortedMap<u64, u64>, k: u64): Option<u64> {
    bsm::remove_by!(m, &k, |a, b| *a > *b)
}

public fun kfrom_rev(m: &BigSortedMap<u64, u64>, from: u64, inc: bool, lim: u64): vector<u64> {
    bsm::keys_from_by!(m, &from, inc, lim, |a, b| *a > *b)
}

// ===========================================================================
// Thin wrappers - u64/u64, BAD comparators (footguns, for RED well-formedness tests)
// ===========================================================================

/// Non-strict `<=`: derived equality (`!lt(a,b) && !lt(b,a)`) never fires, so every insert is
/// treated as fresh and duplicate keys land. Demonstrates the silent-corruption class.
public fun ins_le(m: &mut BigSortedMap<u64, u64>, k: u64, v: u64): Option<u64> {
    bsm::insert_by!(m, k, v, |a, b| *a <= *b)
}

/// Insert under `>` (descending) into a tree built with `<` (ascending): an INCONSISTENT
/// comparator. Routes/places against an ascending structure under descending logic, corrupting
/// both leaf order and routing keys. Demonstrates the inconsistent-comparator class.
public fun ins_gt(m: &mut BigSortedMap<u64, u64>, k: u64, v: u64): Option<u64> {
    bsm::insert_by!(m, k, v, |a, b| *a > *b)
}

// ===========================================================================
// Thin wrappers - BigSortedMap<u64, NoDrop> (conservation)
// ===========================================================================

public fun ins_nd(m: &mut BigSortedMap<u64, NoDrop>, k: u64, w: NoDrop): Option<NoDrop> {
    bsm::insert!(m, k, w)
}

public fun has_nd(m: &BigSortedMap<u64, NoDrop>, k: u64): bool { bsm::contains!(m, &k) }

public fun nd_value_id(m: &BigSortedMap<u64, NoDrop>, k: u64): u64 { nd_id(bsm::borrow!(m, &k)) }

/// In-place mutate a stored NoDrop via `borrow_mut!` - no drop of the old value.
public fun set_nd(m: &mut BigSortedMap<u64, NoDrop>, k: u64, id: u64) {
    nd_set_id(bsm::borrow_mut!(m, &k), id)
}

public fun rem_nd(m: &mut BigSortedMap<u64, NoDrop>, k: u64): Option<NoDrop> { bsm::remove!(m, &k) }

// ===========================================================================
// Thin wrappers - BigSortedMap<CoarseKey, u64> ordered on `id` (byte fidelity)
// ===========================================================================

public fun ins_ck(m: &mut BigSortedMap<CoarseKey, u64>, k: CoarseKey, v: u64): Option<u64> {
    bsm::insert_by!(m, k, v, |a, b| a.id < b.id)
}

public fun get_ck(m: &BigSortedMap<CoarseKey, u64>, id: u64): u64 {
    *bsm::borrow_by!(m, &CoarseKey { id, tag: 0 }, |a, b| a.id < b.id)
}

public fun rem_ck(m: &mut BigSortedMap<CoarseKey, u64>, id: u64): Option<u64> {
    bsm::remove_by!(m, &CoarseKey { id, tag: 0 }, |a, b| a.id < b.id)
}

// ===========================================================================
// Thin wrappers - BigSortedMap<Key, u64> ordered on `id` (non-integer `_by`)
// ===========================================================================

public fun ins_k(m: &mut BigSortedMap<Key, u64>, k: Key, v: u64): Option<u64> {
    bsm::insert_by!(m, k, v, |a, b| a.id < b.id)
}

public fun has_k(m: &BigSortedMap<Key, u64>, id: u64): bool {
    bsm::contains_by!(m, &Key { id }, |a, b| a.id < b.id)
}

public fun get_k(m: &BigSortedMap<Key, u64>, id: u64): u64 {
    *bsm::borrow_by!(m, &Key { id }, |a, b| a.id < b.id)
}

public fun rem_k(m: &mut BigSortedMap<Key, u64>, id: u64): Option<u64> {
    bsm::remove_by!(m, &Key { id }, |a, b| a.id < b.id)
}

/// Ascending struct-key page from `from_id` (inclusive). Lets a struct-key test assert strict
/// `id` ordering of the global sequence - a structural check the u64-only well-formedness check cannot run.
public fun kf_k(m: &BigSortedMap<Key, u64>, from_id: u64, lim: u64): vector<Key> {
    bsm::keys_from_by!(m, &Key { id: from_id }, true, lim, |a, b| a.id < b.id)
}

// ===========================================================================
// Source-SortedMap builders + cross-tier bridge wrappers
// ===========================================================================

public fun sm_ins(m: &mut SortedMap<u64, u64>, k: u64, v: u64) { sm::insert!(m, k, v); }

public fun sm_get(m: &SortedMap<u64, u64>, k: u64): u64 { *sm::borrow!(m, &k) }

/// Build a sorted source `SortedMap` of keys `1..=n` with value `k*10`.
public fun sm_build(n: u64): SortedMap<u64, u64> {
    let mut s = sm::new<u64, u64>();
    let mut k = 1u64;
    while (k <= n) {
        sm_ins(&mut s, k, k * 10);
        k = k + 1;
    };
    s
}

/// Build a source `SortedMap` ordered DESCENDING under `>` (keys `n..1`) - a valid source for the
/// reverse-comparator bridge (`from_sorted_map_by!` with `>` revalidates strictly-increasing-under-
/// `>`, i.e. descending). Has exactly one macro expansion in its body.
public fun sm_build_desc(n: u64): SortedMap<u64, u64> {
    let mut s = sm::new<u64, u64>();
    let mut k = 1u64;
    while (k <= n) {
        sm::insert_by!(&mut s, k, k * 10, |a, b| *a > *b);
        k = k + 1;
    };
    s
}

/// `from_sorted_map` at forced low degree (inner 4 / leaf 3) -> a multi-level bulk build.
public fun from_sm_lowdeg(
    source: SortedMap<u64, u64>,
    ctx: &mut TxContext,
): BigSortedMap<u64, u64> {
    bsm::from_sorted_map_with_config!(source, 4, 3, ctx)
}

/// `from_sorted_map` at default degrees (one-shot path).
public fun from_sm_default(
    source: SortedMap<u64, u64>,
    ctx: &mut TxContext,
): BigSortedMap<u64, u64> {
    bsm::from_sorted_map!(source, ctx)
}

/// `from_sorted_map` at inner 4 / leaf 4 - bulk-builds keys `1..=9` into the exact 3-leaf shape
/// `[1,2,3][4,5,6][7,8,9]` with root routing `[3,6,9]` (the delete-interior-max fixture).
public fun from_sm_44(source: SortedMap<u64, u64>, ctx: &mut TxContext): BigSortedMap<u64, u64> {
    bsm::from_sorted_map_with_config!(source, 4, 4, ctx)
}

/// `from_sorted_map` under a consistent REVERSE comparator at low degree (the bridge case).
public fun from_sm_rev(source: SortedMap<u64, u64>, ctx: &mut TxContext): BigSortedMap<u64, u64> {
    bsm::from_sorted_map_with_config_by!(source, 4, 3, |a, b| *a > *b, ctx)
}

/// `from_sorted_map_by!` - the bare `_by` form at DEFAULT degrees (the one `from_*` macro form not
/// otherwise exercised with a non-`<` comparator). Threads a reverse `>` lambda into the
/// default-degree dispatch (distinct body from `from_sorted_map!`'s hardwired `<` and from
/// `from_sorted_map_with_config_by!`'s explicit degrees). One macro expansion.
public fun from_sm_default_rev(
    source: SortedMap<u64, u64>,
    ctx: &mut TxContext,
): BigSortedMap<u64, u64> {
    bsm::from_sorted_map_by!(source, |a, b| *a > *b, ctx)
}

// ===========================================================================
// Teardown helpers - drain then destroy_empty (the only terminal)
// ===========================================================================
//
// A `BigSortedMap` is `key, store` with copy/drop FORCED OFF, so it can never fall out of scope:
// a populated tree must be drained (here via comparator-free `pop_front`) and then `destroy_empty`d.
// These also serve as the "drain-then-destroy_empty teardown, no implicit drop" witnesses.

public fun drain_destroy(mut map: BigSortedMap<u64, u64>) {
    while (!bsm::is_empty(&map)) {
        let (_k, _v) = bsm::pop_front(&mut map);
    };
    bsm::destroy_empty(map);
}

/// Non-drop V: every drained value must be explicitly consumed (`nd_unwrap`) - no silent burn.
public fun drain_destroy_nd(mut map: BigSortedMap<u64, NoDrop>) {
    while (!bsm::is_empty(&map)) {
        let (_k, w) = bsm::pop_front(&mut map);
        nd_unwrap(w);
    };
    bsm::destroy_empty(map);
}

public fun drain_destroy_ck(mut map: BigSortedMap<CoarseKey, u64>) {
    while (!bsm::is_empty(&map)) {
        let (_k, _v) = bsm::pop_front(&mut map);
    };
    bsm::destroy_empty(map);
}

public fun drain_destroy_k(mut map: BigSortedMap<Key, u64>) {
    while (!bsm::is_empty(&map)) {
        let (_k, _v) = bsm::pop_front(&mut map);
    };
    bsm::destroy_empty(map);
}

// ===========================================================================
// THE WELL-FORMEDNESS CHECK - bsm_well_formed
// ===========================================================================

/// Strict order under the chosen direction: ascending = `a < b`, descending = `a > b`.
fun lt(a: u64, b: u64, ascending: bool): bool { if (ascending) a < b else a > b }

/// Structural well-formedness check for a `<u64, u64>` tree built at the given degrees under the
/// given order direction. Returns `bool` (composable into a caller's assert), checking the full
/// load-bearing structural set in one bounded recursive pass:
///   - empty tree is a single empty leaf root with NULL chain links.
///   - equal leaf depth (every leaf at the same height).
///   - every non-root node in `[ceil(m/2), m]`; an internal root has `>= 2` children.
///   - strictly sorted keys within every node (both kinds), under `ascending`.
///   - every inner routing key EQUALS its child subtree's max; children are contiguous.
///   - the doubly-linked leaf chain is ascending, gap/dup-free, NULL-terminated.
///   - recursive leaf-entry count == cached `length` == leaf-chain count.
///   - `head`/`tail` (which read the cached spine pointers) == structural extremes.
public fun bsm_well_formed<V: store>(
    map: &BigSortedMap<u64, V>,
    inner_max_degree: u64,
    leaf_max_degree: u64,
    ascending: bool,
): bool {
    let len_cached = bsm::length(map);
    // empty tree = single empty inline leaf root, chain links NULL on both ends.
    if (len_cached == 0) {
        let root = bsm::borrow_node(map, bsm::root_index());
        return bsm::is_leaf(root)
            && bsm::node_len(root) == 0
            && bsm::leaf_next(root) == bsm::null_index()
            && bsm::leaf_prev(root) == bsm::null_index()
    };
    // Expected depth = number of inner levels from the root (descend child 0).
    let depth = tree_depth(map);
    // Recursive structural check; (gmin, gmax) are the whole tree's extremes (root subtree spans all).
    // `child_ids` accumulates every child id visited - a shared child (a DAG / two parents) appears
    // twice, which the routing graph forbids.
    let mut child_ids = vector[];
    let (ok_struct, gmin, gmax, leaf_total) = check_subtree(
        map,
        bsm::root_index(),
        depth,
        true,
        inner_max_degree,
        leaf_max_degree,
        ascending,
        &mut child_ids,
    );
    // unique parent / no shared child id / no DAG in the routing graph.
    let ok_unique = !has_dup(&child_ids);
    // recursive leaf-entry total == cached length.
    let ok_len = leaf_total == len_cached;
    // independent leaf-chain walk (forward + backward links, global order, count).
    let ok_chain = check_leaf_chain(map, len_cached, ascending);
    // head/tail read the CACHED spine pointers; they must equal the structural extremes.
    let ok_extremes = bsm::head(map) == option::some(gmin) && bsm::tail(map) == option::some(gmax);
    ok_struct && ok_unique && ok_len && ok_chain && ok_extremes
}

/// True iff `v` contains a duplicate u64 (O(n^2); fine on unit-test-bounded trees). Backs the
/// unique-child-id check.
fun has_dup(v: &vector<u64>): bool {
    let n = v.length();
    let mut i = 0;
    while (i < n) {
        let mut j = i + 1;
        while (j < n) {
            if (*v.borrow(i) == *v.borrow(j)) return true;
            j = j + 1;
        };
        i = i + 1;
    };
    false
}

/// Validate the subtree rooted at `id`, returning `(ok, subtree_min, subtree_max, leaf_count)`.
/// `height_remaining` is the number of inner levels expected below `id` (0 => `id` must be a leaf),
/// which is how equal depth is enforced. Generic over `V` (it reads keys only, never V),
/// so a non-droppable-V tree gets the SAME structural check the u64-V tree does.
fun check_subtree<V: store>(
    map: &BigSortedMap<u64, V>,
    id: u64,
    height_remaining: u64,
    is_root: bool,
    inner_max_degree: u64,
    leaf_max_degree: u64,
    ascending: bool,
    visited_child_ids: &mut vector<u64>, // accumulate every child id (a DAG repeats one)
): (bool, u64, u64, u64) {
    let is_leaf = bsm::is_leaf(bsm::borrow_node(map, id));
    // a node is a leaf IFF it sits at the bottom level.
    if (is_leaf != (height_remaining == 0)) return (false, 0, 0, 0);

    if (is_leaf) {
        let node = bsm::borrow_node(map, id);
        let leaf = bsm::node_leaf(node);
        let len = sm::length(leaf);
        // non-root leaf half-full..full; root leaf 0..full (exempt from the floor).
        let floor = (leaf_max_degree + 1) / 2;
        if (len > leaf_max_degree) return (false, 0, 0, 0);
        if (!is_root && len < floor) return (false, 0, 0, 0);
        if (len == 0) return (is_root, 0, 0, 0); // only an empty root leaf is legal here
        // strictly increasing keys within the leaf.
        let mut ok = true;
        let mut i = 1;
        while (i < len) {
            if (!lt(*sm::key_at(leaf, i - 1), *sm::key_at(leaf, i), ascending)) {
                ok = false;
                break
            };
            i = i + 1;
        };
        let mink = *sm::key_at(leaf, 0);
        let maxk = *sm::key_at(leaf, len - 1);
        (ok, mink, maxk, len)
    } else {
        // Copy out (routing_key, child_id) pairs BEFORE recursing (avoid holding a node borrow).
        let nchild = bsm::node_len(bsm::borrow_node(map, id));
        let floor = (inner_max_degree + 1) / 2;
        // internal root needs >= 2 children; non-root inner in [ceil(m/2), m].
        if (nchild > inner_max_degree) return (false, 0, 0, 0);
        if (is_root && nchild < 2) return (false, 0, 0, 0);
        if (!is_root && nchild < floor) return (false, 0, 0, 0);

        let mut routing_keys = vector[];
        let mut child_ids = vector[];
        let mut j = 0;
        while (j < nchild) {
            let node = bsm::borrow_node(map, id);
            routing_keys.push_back(*sm::key_at(bsm::node_inner(node), j));
            let cid = bsm::child_id_at(node, j);
            child_ids.push_back(cid);
            visited_child_ids.push_back(cid); // record for the global uniqueness check
            j = j + 1;
        };
        // routing keys strictly increasing.
        let mut ok = true;
        let mut k = 1;
        while (k < nchild) {
            if (!lt(*routing_keys.borrow(k - 1), *routing_keys.borrow(k), ascending)) {
                ok = false;
            };
            k = k + 1;
        };
        // Recurse each child; check routing==subtree-max + sibling contiguity (order).
        let mut total = 0;
        let mut submin = 0;
        let mut submax = 0;
        let mut prev_max = 0;
        let mut have_prev = false;
        let mut c = 0;
        while (c < nchild) {
            let (cok, cmin, cmax, ccount) = check_subtree(
                map,
                *child_ids.borrow(c),
                height_remaining - 1,
                false,
                inner_max_degree,
                leaf_max_degree,
                ascending,
                visited_child_ids,
            );
            if (!cok) ok = false;
            // routing key at index c equals child c's subtree max.
            if (*routing_keys.borrow(c) != cmax) ok = false;
            // Global order: previous child's max strictly precedes this child's min.
            if (have_prev && !lt(prev_max, cmin, ascending)) ok = false;
            if (c == 0) submin = cmin;
            submax = cmax;
            prev_max = cmax;
            have_prev = true;
            total = total + ccount;
            c = c + 1;
        };
        (ok, submin, submax, total)
    }
}

/// Walk the doubly-linked leaf chain from the structural leftmost leaf via `leaf_next`, asserting:
/// strictly-increasing keys across the whole chain, exactly `expected_count` entries visited,
/// NULL-terminated endpoints (head `prev == NULL`, tail `next == NULL`), AND that every interior
/// BACKWARD link agrees with the forward chain (`leaf_prev(R) == id(L)` for each adjacent L->R) -
/// without the backward check, a corrupted interior `prev` pointer stays invisible to a forward-only
/// walk.
fun check_leaf_chain<V: store>(
    map: &BigSortedMap<u64, V>,
    expected_count: u64,
    ascending: bool,
): bool {
    // Structural leftmost leaf.
    let mut cur = bsm::root_index();
    loop {
        let n = bsm::borrow_node(map, cur);
        if (bsm::is_leaf(n)) break;
        cur = bsm::child_id_at(n, 0);
    };
    let mut ok = true;
    let mut count = 0;
    let mut prev_key = 0;
    let mut have_prev = false;
    let mut prev_leaf_id = bsm::null_index(); // the previous leaf's id; NULL before the head leaf
    loop {
        let node = bsm::borrow_node(map, cur);
        // Backward-link agreement (unifies head `prev == NULL` and every interior `prev == id(L)`).
        if (bsm::leaf_prev(node) != prev_leaf_id) ok = false;
        let leaf = bsm::node_leaf(node);
        let n = sm::length(leaf);
        let mut i = 0;
        while (i < n) {
            let kk = *sm::key_at(leaf, i);
            if (have_prev && !lt(prev_key, kk, ascending)) ok = false;
            prev_key = kk;
            have_prev = true;
            count = count + 1;
            i = i + 1;
        };
        let nxt = bsm::leaf_next(node);
        if (nxt == bsm::null_index()) break;
        prev_leaf_id = cur;
        cur = nxt;
    };
    ok && count == expected_count
}

// ===========================================================================
// Non-drop-V source builders + bridge (conservation)
// ===========================================================================

/// Insert a fresh `(k, NoDrop{id})` into a source `SortedMap`; the `none` returned on a fresh
/// insert is destroyed without a `drop` bound (precondition: `k` not already present).
public fun sm_ins_nd(m: &mut SortedMap<u64, NoDrop>, k: u64, id: u64) {
    sm::insert!(m, k, nd(id)).destroy_none()
}

/// Build a sorted `SortedMap<u64, NoDrop>` of keys `1..=n` with value-id `k*1000`.
public fun sm_build_nd(n: u64): SortedMap<u64, NoDrop> {
    let mut s = sm::new<u64, NoDrop>();
    let mut k = 1u64;
    while (k <= n) {
        sm_ins_nd(&mut s, k, k * 1000);
        k = k + 1;
    };
    s
}

/// Drain and destroy a `SortedMap<u64, NoDrop>`, explicitly consuming every value (no silent burn).
public fun sm_drain_destroy_nd(mut m: SortedMap<u64, NoDrop>) {
    while (!sm::is_empty(&m)) {
        let (_k, w) = sm::pop_front(&mut m);
        nd_unwrap(w);
    };
    sm::destroy_empty(m);
}

/// `from_sorted_map` of a non-drop-V source at forced low degree (a multi-level move-only build).
public fun from_sm_nd_lowdeg(
    source: SortedMap<u64, NoDrop>,
    ctx: &mut TxContext,
): BigSortedMap<u64, NoDrop> {
    bsm::from_sorted_map_with_config!(source, 4, 3, ctx)
}

// ===========================================================================
// White-box shape inspectors (for the structural suite - generic, comparator-free)
// ===========================================================================

/// Number of inner levels from the root to a leaf (0 => a single leaf root, depth 0).
public fun tree_depth<K: copy + drop + store, V: store>(map: &BigSortedMap<K, V>): u64 {
    let mut depth = 0;
    let mut cur = bsm::root_index();
    loop {
        let n = bsm::borrow_node(map, cur);
        if (bsm::is_leaf(n)) break;
        cur = bsm::child_id_at(n, 0);
        depth = depth + 1;
    };
    depth
}

public fun root_is_leaf<K: copy + drop + store, V: store>(map: &BigSortedMap<K, V>): bool {
    bsm::is_leaf(bsm::borrow_node(map, bsm::root_index()))
}

/// Number of entries/children in the root node (leaf entries if a leaf root, else child count).
public fun root_child_count<K: copy + drop + store, V: store>(map: &BigSortedMap<K, V>): u64 {
    bsm::node_len(bsm::borrow_node(map, bsm::root_index()))
}

/// The root inner node's routing key at index `idx` (u64 keys). Aborts (EWrongNodeKind) on a leaf
/// root. Used to white-box-pin the routing == subtree-max property.
public fun root_routing_key_at(map: &BigSortedMap<u64, u64>, idx: u64): u64 {
    *sm::key_at(bsm::node_inner(bsm::borrow_node(map, bsm::root_index())), idx)
}

/// The `tag` bytes of a single-leaf-root CoarseKey map's key at `idx` - observes WHICH key bytes
/// survived a coarse-comparator upsert (leaf byte fidelity).
public fun root_leaf_ck_tag(map: &BigSortedMap<CoarseKey, u64>, idx: u64): u64 {
    ck_tag(sm::key_at(bsm::node_leaf(bsm::borrow_node(map, bsm::root_index())), idx))
}

/// The `id` and `tag` bytes of the root inner node's routing key at `idx` (CoarseKey map) - observes
/// whether a coarse-comparator upsert of a subtree-max propagated its NEW bytes into the routing
/// key (routing byte fidelity).
public fun root_routing_ck_id(map: &BigSortedMap<CoarseKey, u64>, idx: u64): u64 {
    ck_id(sm::key_at(bsm::node_inner(bsm::borrow_node(map, bsm::root_index())), idx))
}

public fun root_routing_ck_tag(map: &BigSortedMap<CoarseKey, u64>, idx: u64): u64 {
    ck_tag(sm::key_at(bsm::node_inner(bsm::borrow_node(map, bsm::root_index())), idx))
}

/// The `tag` of the key at `key_idx` in the root's child leaf at `child_idx` (CoarseKey map) -
/// reads one level below an inner root to observe a leaf-max's stored bytes after an upsert.
public fun child_leaf_ck_tag(
    map: &BigSortedMap<CoarseKey, u64>,
    child_idx: u64,
    key_idx: u64,
): u64 {
    let root = bsm::borrow_node(map, bsm::root_index());
    let child_id = bsm::child_id_at(root, child_idx);
    ck_tag(sm::key_at(bsm::node_leaf(bsm::borrow_node(map, child_id)), key_idx))
}

// ===========================================================================
// Reference model - a linear sorted-vector map used as ground truth
// ===========================================================================
//
// Plain, obviously-correct O(n) code. The differential test drives this and the real BSM through
// identical op streams and asserts they agree at every step.

public struct Ref has drop {
    keys: vector<u64>,
    vals: vector<u64>,
}

public fun ref_new(): Ref { Ref { keys: vector[], vals: vector[] } }

public fun ref_length(r: &Ref): u64 { r.keys.length() }

/// Upsert. Returns `some(old)` on replace, `none` on fresh insert. Keeps `keys` ascending.
public fun ref_insert(r: &mut Ref, k: u64, v: u64): Option<u64> {
    let n = r.keys.length();
    let mut i = 0;
    while (i < n) {
        let ki = *r.keys.borrow(i);
        if (ki == k) {
            let old = *r.vals.borrow(i);
            *r.vals.borrow_mut(i) = v;
            return option::some(old)
        };
        if (ki > k) break;
        i = i + 1;
    };
    r.keys.insert(k, i);
    r.vals.insert(v, i);
    option::none()
}

public fun ref_remove(r: &mut Ref, k: u64): Option<u64> {
    let n = r.keys.length();
    let mut i = 0;
    while (i < n) {
        if (*r.keys.borrow(i) == k) {
            r.keys.remove(i);
            let v = r.vals.remove(i);
            return option::some(v)
        };
        i = i + 1;
    };
    option::none()
}

public fun ref_contains(r: &Ref, k: u64): bool {
    let n = r.keys.length();
    let mut i = 0;
    while (i < n) {
        if (*r.keys.borrow(i) == k) return true;
        i = i + 1;
    };
    false
}

public fun ref_get(r: &Ref, k: u64): u64 {
    let n = r.keys.length();
    let mut i = 0;
    while (i < n) {
        if (*r.keys.borrow(i) == k) return *r.vals.borrow(i);
        i = i + 1;
    };
    abort EKeyNotFound
}

public fun ref_head(r: &Ref): Option<u64> {
    if (r.keys.is_empty()) option::none() else option::some(*r.keys.borrow(0))
}

public fun ref_tail(r: &Ref): Option<u64> {
    let n = r.keys.length();
    if (n == 0) option::none() else option::some(*r.keys.borrow(n - 1))
}

/// Remove and return the minimum `(k, v)`. Precondition: non-empty (caller guards on length).
public fun ref_pop_front(r: &mut Ref): (u64, u64) {
    let k = r.keys.remove(0);
    let v = r.vals.remove(0);
    (k, v)
}

/// Remove and return the maximum `(k, v)`. Precondition: non-empty (caller guards on length).
public fun ref_pop_back(r: &mut Ref): (u64, u64) {
    let n = r.keys.length();
    let k = r.keys.remove(n - 1);
    let v = r.vals.remove(n - 1);
    (k, v)
}

public fun ref_find_next(r: &Ref, k: u64, inc: bool): Option<u64> {
    let n = r.keys.length();
    let mut i = 0;
    while (i < n) {
        let ki = *r.keys.borrow(i);
        if (inc && ki >= k) return option::some(ki);
        if (!inc && ki > k) return option::some(ki);
        i = i + 1;
    };
    option::none()
}

public fun ref_find_prev(r: &Ref, k: u64, inc: bool): Option<u64> {
    let n = r.keys.length();
    let mut i = n;
    while (i > 0) {
        i = i - 1;
        let ki = *r.keys.borrow(i);
        if (inc && ki <= k) return option::some(ki);
        if (!inc && ki < k) return option::some(ki);
    };
    option::none()
}

public fun ref_keys_from(r: &Ref, from: u64, inc: bool, lim: u64): vector<u64> {
    let n = r.keys.length();
    let mut out = vector[];
    let mut i = 0;
    while (i < n && out.length() < lim) {
        let ki = *r.keys.borrow(i);
        let qualifies = if (inc) ki >= from else ki > from;
        if (qualifies) out.push_back(ki);
        i = i + 1;
    };
    out
}

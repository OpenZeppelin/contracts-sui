/// Shared test utilities for the `sorted_map` suite.
///
/// # Why thin wrappers
/// Every macro call expands `search!` + its body INLINE at the call site. A function
/// with many distinct macro calls overflows Move's ~256-locals-per-function limit
/// (observed: compiler panic `value (351) cannot exceed (255)`). The fix used throughout
/// the suite: each comparator-needing op is wrapped in a one-macro-per-function helper
/// here. A *call* to such a wrapper does NOT expand the macro at the caller, so test
/// bodies and loops stay well under the limit.
///
/// This module also provides the witness types the conservation/type tests need and
/// a tiny sorted-vector REFERENCE MODEL used as ground truth for the differential test.
module openzeppelin_collections::sorted_map_test_util;

use openzeppelin_collections::sorted_map::{Self as sm, SortedMap};

/// The reference model's `ref_get` was called on an absent key (the differential test only
/// reads keys it has confirmed present, so this is unreachable in practice).
#[error(code = 0)]
const EKeyNotFound: vector<u8> = "Reference model queried for an absent key";

// === Witness types ===

/// Non-droppable, non-copyable value witness. Storing this as V means
/// the compiler forbids implicitly dropping a value: any test that fails to thread every
/// value back out simply will not compile, turning silent `V: drop` conservation bugs
/// into build errors.
public struct NoDrop has store { id: u64 }

public fun nd(id: u64): NoDrop { NoDrop { id } }

public fun nd_id(w: &NoDrop): u64 { w.id }

/// Consume a `NoDrop`, returning its id. The only way to dispose of one (it has no `drop`).
public fun nd_unwrap(w: NoDrop): u64 {
    let NoDrop { id } = w;
    id
}

/// A "coarse" key ordered on `id` ALONE: two byte-distinct keys (same `id`,
/// different `tag`) compare equal under the comparator. Also serves as the generic
/// non-integer (struct) key for the `_by` demonstrations when ids are distinct.
public struct CoarseKey has copy, drop, store { id: u64, tag: u64 }

public fun ck(id: u64, tag: u64): CoarseKey { CoarseKey { id, tag } }

public fun ck_id(k: &CoarseKey): u64 { k.id }

public fun ck_tag(k: &CoarseKey): u64 { k.tag }

/// Two distinct value types for the cross-instantiation test.
public struct Bid has copy, drop, store { px: u64 }

public struct Ask has copy, drop, store { px: u64 }

public fun bid(px: u64): Bid { Bid { px } }

public fun ask(px: u64): Ask { Ask { px } }

public fun bid_px(b: &Bid): u64 { b.px }

public fun ask_px(a: &Ask): u64 { a.px }

// === Thin wrappers - u64/u64, bare forms (built-in integer `<`) ===

public fun ins(m: &mut SortedMap<u64, u64>, k: u64, v: u64): Option<u64> { m.upsert!(&k, v) }

/// Strict insert (aborts `EKeyAlreadyExists` on a duplicate). Takes the key by value.
public fun add(m: &mut SortedMap<u64, u64>, k: u64, v: u64) { m.add!(k, v) }

public fun has(m: &SortedMap<u64, u64>, k: u64): bool { m.contains!(&k) }

public fun get(m: &SortedMap<u64, u64>, k: u64): u64 { *m.borrow!(&k) }

/// Overwrite the value at `k` in place via `borrow_mut!` (aborts `EKeyNotFound` if absent).
public fun set(m: &mut SortedMap<u64, u64>, k: u64, v: u64) { *m.borrow_mut!(&k) = v; }

public fun rm(m: &mut SortedMap<u64, u64>, k: u64): u64 {
    let (_, v) = m.remove!(&k);
    v
}

public fun fnext(m: &SortedMap<u64, u64>, k: u64, inc: bool): Option<u64> {
    m.find_next!(&k, inc)
}

public fun fprev(m: &SortedMap<u64, u64>, k: u64, inc: bool): Option<u64> {
    m.find_prev!(&k, inc)
}

public fun nxt(m: &SortedMap<u64, u64>, k: u64): Option<u64> { m.next_key!(&k) }

public fun prv(m: &SortedMap<u64, u64>, k: u64): Option<u64> { m.prev_key!(&k) }

public fun kfrom(m: &SortedMap<u64, u64>, from: u64, inc: bool, lim: u64): vector<u64> {
    m.keys_from!(&from, inc, lim)
}

/// Well-formedness check under the bare integer `<`.
public fun wf(m: &SortedMap<u64, u64>): bool { m.is_well_formed!() }

// === Thin wrappers - u64/u64, reverse comparator `>` (used CONSISTENTLY: legit case) ===

public fun ins_rev(m: &mut SortedMap<u64, u64>, k: u64, v: u64): Option<u64> {
    m.upsert_by!(&k, v, |a, b| *a > *b)
}

/// Strict insert under the reverse comparator (aborts `EKeyAlreadyExists` on a duplicate).
public fun add_rev(m: &mut SortedMap<u64, u64>, k: u64, v: u64) {
    m.add_by!(k, v, |a, b| *a > *b)
}

public fun has_rev(m: &SortedMap<u64, u64>, k: u64): bool {
    m.contains_by!(&k, |a, b| *a > *b)
}

public fun get_rev(m: &SortedMap<u64, u64>, k: u64): u64 { *m.borrow_by!(&k, |a, b| *a > *b) }

public fun rm_rev(m: &mut SortedMap<u64, u64>, k: u64): u64 {
    let (_, v) = m.remove_by!(&k, |a, b| *a > *b);
    v
}

/// Well-formedness check under the reverse comparator: a consistently-reversed map is
/// well-formed under `>` even though it is NOT under `<`.
public fun wf_rev(m: &SortedMap<u64, u64>): bool { m.is_well_formed_by!(|a, b| *a > *b) }

// Reverse-comparator navigation / pagination `_by` wrappers (used CONSISTENTLY with `>`).
// These are the ONLY exercise of the custom-comparator navigation/pagination macro surface
// (find_next_by/find_prev_by/next_key_by/prev_key_by/keys_from_by) - every other navigation
// test threads the bare integer `<`.

public fun fnext_rev(m: &SortedMap<u64, u64>, k: u64, inc: bool): Option<u64> {
    m.find_next_by!(&k, inc, |a, b| *a > *b)
}

public fun fprev_rev(m: &SortedMap<u64, u64>, k: u64, inc: bool): Option<u64> {
    m.find_prev_by!(&k, inc, |a, b| *a > *b)
}

public fun nxt_rev(m: &SortedMap<u64, u64>, k: u64): Option<u64> {
    m.next_key_by!(&k, |a, b| *a > *b)
}

public fun prv_rev(m: &SortedMap<u64, u64>, k: u64): Option<u64> {
    m.prev_key_by!(&k, |a, b| *a > *b)
}

public fun kfrom_rev(m: &SortedMap<u64, u64>, from: u64, inc: bool, lim: u64): vector<u64> {
    m.keys_from_by!(&from, inc, lim, |a, b| *a > *b)
}

// === Thin wrappers - u64/u64, BAD comparators (footguns) ===

/// Non-strict `<=`: `search!` never derives equality, so equal keys are never detected
/// (every insert is treated as fresh) -> duplicate keys land. Demonstrates footgun (a).
public fun ins_le(m: &mut SortedMap<u64, u64>, k: u64, v: u64): Option<u64> {
    m.upsert_by!(&k, v, |a, b| *a <= *b)
}

/// Remove under `>` against a map built with `<`: the descending search reads ascending
/// data and returns `found=false` -> the value is stranded. Demonstrates footgun (b).
public fun rm_gt(m: &mut SortedMap<u64, u64>, k: u64): u64 {
    let (_, v) = m.remove_by!(&k, |a, b| *a > *b);
    v
}

// === Thin wrappers - SortedMap<u64, NoDrop> (conservation) ===

public fun ins_nd(m: &mut SortedMap<u64, NoDrop>, k: u64, w: NoDrop): Option<NoDrop> {
    m.upsert!(&k, w)
}

public fun has_nd(m: &SortedMap<u64, NoDrop>, k: u64): bool { m.contains!(&k) }

public fun nd_value_id(m: &SortedMap<u64, NoDrop>, k: u64): u64 { m.borrow!(&k).nd_id() }

public fun rm_nd(m: &mut SortedMap<u64, NoDrop>, k: u64): NoDrop {
    let (_, w) = m.remove!(&k);
    w
}

// === Thin wrappers - SortedMap<CoarseKey, u64> ordered on `id` ===

public fun ins_ck(m: &mut SortedMap<CoarseKey, u64>, k: CoarseKey, v: u64): Option<u64> {
    m.upsert_by!(&k, v, |a, b| a.id < b.id)
}

/// Strict insert ordered on `id` alone (aborts `EKeyAlreadyExists` when a stored key
/// compares equal, i.e. shares the `id`, regardless of `tag`).
public fun add_ck(m: &mut SortedMap<CoarseKey, u64>, k: CoarseKey, v: u64) {
    m.add_by!(k, v, |a, b| a.id < b.id)
}

public fun has_ck(m: &SortedMap<CoarseKey, u64>, id: u64): bool {
    m.contains_by!(&CoarseKey { id, tag: 0 }, |a, b| a.id < b.id)
}

public fun get_ck(m: &SortedMap<CoarseKey, u64>, id: u64): u64 {
    *m.borrow_by!(&CoarseKey { id, tag: 0 }, |a, b| a.id < b.id)
}

public fun rm_ck(m: &mut SortedMap<CoarseKey, u64>, id: u64): u64 {
    let (_, v) = m.remove_by!(&CoarseKey { id, tag: 0 }, |a, b| a.id < b.id);
    v
}

/// Overwrite the value at `id` via `borrow_mut_by!` under the id-order comparator (aborts
/// `EKeyNotFound` if absent). The ONLY exercise of the MUTABLE point-access `_by` path
/// (`u::set` covers only the bare `borrow_mut!`).
public fun set_ck(m: &mut SortedMap<CoarseKey, u64>, id: u64, v: u64) {
    *m.borrow_mut_by!(&CoarseKey { id, tag: 0 }, |a, b| a.id < b.id) = v;
}

/// `head` returns the surviving stored key (including its `tag` bytes) - lets a test
/// observe which key bytes won an upsert.
public fun head_ck_tag(m: &SortedMap<CoarseKey, u64>): u64 {
    let h = m.head();
    h.borrow().ck_tag()
}

public fun wf_ck(m: &SortedMap<CoarseKey, u64>): bool {
    m.is_well_formed_by!(|a, b| a.id < b.id)
}

// === Thin wrappers - distinct instantiations coexist ===

public fun ins_bid(m: &mut SortedMap<u64, Bid>, k: u64, v: Bid): Option<Bid> {
    m.upsert!(&k, v)
}

public fun ins_ask(m: &mut SortedMap<u64, Ask>, k: u64, v: Ask): Option<Ask> {
    m.upsert!(&k, v)
}

public fun get_bid_px(m: &SortedMap<u64, Bid>, k: u64): u64 { m.borrow!(&k).bid_px() }

public fun get_ask_px(m: &SortedMap<u64, Ask>, k: u64): u64 { m.borrow!(&k).ask_px() }

// === Builders ===

/// Deterministic scramble (coprime multiplier mod a prime) so a "build N" walks keys in a
/// non-sorted order, exercising arbitrary insertion points.
public fun scrambled(i: u64): u64 { (i * 7919) % 100003 }

/// Build a `u64/u64` map of `n` scrambled keys via the public `upsert` path.
public fun build_scrambled(n: u64): SortedMap<u64, u64> {
    let mut m = sm::new<u64, u64>();
    let mut i = 0;
    while (i < n) {
        ins(&mut m, scrambled(i), i);
        i = i + 1;
    };
    m
}

// === Reference model - a linear sorted-vector map used as ground truth ===
//
// Plain, obviously-correct O(n) code. The differential test drives this and the real
// `SortedMap` through identical op streams and asserts they agree at every step.

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

public fun ref_remove(r: &mut Ref, k: u64): u64 {
    let n = r.keys.length();
    let mut i = 0;
    while (i < n) {
        if (*r.keys.borrow(i) == k) {
            r.keys.remove(i);
            let v = r.vals.remove(i);
            return v
        };
        i = i + 1;
    };
    abort EKeyNotFound
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

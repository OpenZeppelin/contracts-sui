/// Shared test utilities for the `openzeppelin_sorted_set` suite.
///
/// # Why thin wrappers
/// Every set macro expands its body AND the map macro AND `search!` INLINE at the call
/// site - THREE inlining layers (four for `from_keys`). A `#[test]` body with many distinct
/// macro calls overflows Move's ~256-locals-per-function limit (the map suite already hit
/// `value (351) cannot exceed (255)`), and the set hits it SOONER. The fix used throughout:
/// each comparator-needing op is wrapped in a one-macro-per-function helper here. A *call* to
/// such a wrapper does NOT expand the macro at the caller, so test bodies and 1,000+-op loops
/// stay far under the limit. This file's mere existence is the 256-locals mitigation in practice.
///
/// It also provides: the well-formedness check reused from the map, a keys-only sorted-vector
/// REFERENCE MODEL (`RefSet`) used as ground truth for the differential test, a
/// coarse struct key, bad-comparator and `inner_mut`-misuse drivers, and ability witnesses.
module openzeppelin_sorted_set::test_util;

use openzeppelin_sorted_set::sorted_set::{Self as ss, SortedSet};
use openzeppelin_sorted_map::sorted_map;

// ===========================================================================
// Thin wrappers - u64, bare forms (built-in integer `<`)
// ===========================================================================

public fun ins(s: &mut SortedSet<u64>, k: u64): bool { ss::insert!(s, k) }

public fun rem(s: &mut SortedSet<u64>, k: u64): bool { ss::remove!(s, &k) }

public fun has(s: &SortedSet<u64>, k: u64): bool { ss::contains!(s, &k) }

public fun fnext(s: &SortedSet<u64>, k: u64, inc: bool): Option<u64> { ss::find_next!(s, &k, inc) }

public fun fprev(s: &SortedSet<u64>, k: u64, inc: bool): Option<u64> { ss::find_prev!(s, &k, inc) }

public fun nkey(s: &SortedSet<u64>, k: u64): Option<u64> { ss::next_key!(s, &k) }

public fun pkey(s: &SortedSet<u64>, k: u64): Option<u64> { ss::prev_key!(s, &k) }

public fun page(s: &SortedSet<u64>, from: u64, inc: bool, lim: u64): vector<u64> {
    ss::keys_from!(s, &from, inc, lim)
}

public fun fromk(ks: vector<u64>): SortedSet<u64> { ss::from_keys!(ks) }

/// Well-formedness check under the bare integer `<` - REUSED from the map across the package
/// boundary. No separate set checker exists.
public fun wf(s: &SortedSet<u64>): bool { sorted_map::is_well_formed!(ss::inner_ref(s)) }

// ===========================================================================
// Thin wrappers - u64, reverse comparator `>` used CONSISTENTLY (legit case)
// ===========================================================================

public fun ins_rev(s: &mut SortedSet<u64>, k: u64): bool { ss::insert_by!(s, k, |a, b| *a > *b) }

public fun rem_rev(s: &mut SortedSet<u64>, k: u64): bool { ss::remove_by!(s, &k, |a, b| *a > *b) }

public fun has_rev(s: &SortedSet<u64>, k: u64): bool { ss::contains_by!(s, &k, |a, b| *a > *b) }

/// Well-formedness check under the reverse comparator: a consistently-reversed set is well-formed
/// under `>` even though it is NOT under `<`.
public fun wf_rev(s: &SortedSet<u64>): bool {
    sorted_map::is_well_formed_by!(ss::inner_ref(s), |a, b| *a > *b)
}

/// Reverse-comparator navigation/pagination wrappers (one macro per helper). The `>`
/// lambda is the SAME reverse strict order `ins_rev` builds with, threaded consistently - so
/// "next"/"prev"/page are about lt-extremes (numeric-descending), not numeric order.
public fun fnext_rev(s: &SortedSet<u64>, k: u64, inc: bool): Option<u64> {
    ss::find_next_by!(s, &k, inc, |a, b| *a > *b)
}

public fun fprev_rev(s: &SortedSet<u64>, k: u64, inc: bool): Option<u64> {
    ss::find_prev_by!(s, &k, inc, |a, b| *a > *b)
}

public fun nkey_rev(s: &SortedSet<u64>, k: u64): Option<u64> { ss::next_key_by!(s, &k, |a, b| *a > *b) }

public fun pkey_rev(s: &SortedSet<u64>, k: u64): Option<u64> { ss::prev_key_by!(s, &k, |a, b| *a > *b) }

public fun page_rev(s: &SortedSet<u64>, from: u64, inc: bool, lim: u64): vector<u64> {
    ss::keys_from_by!(s, &from, inc, lim, |a, b| *a > *b)
}

// ===========================================================================
// Thin wrappers - u64, BAD comparators (footguns)
// ===========================================================================

/// Non-strict `<=`: `search!` never derives equality, so equal-comparing keys are treated as
/// fresh -> a byte-distinct equal key lands again (length grows).
public fun ins_le(s: &mut SortedSet<u64>, k: u64): bool { ss::insert_by!(s, k, |a, b| *a <= *b) }

/// Probe/remove under the SAME non-strict `<=`: `search!` never derives equality, so an
/// equal-comparing key is MISSED (returns false) even though it is present (the "miss" half).
public fun has_le(s: &SortedSet<u64>, k: u64): bool { ss::contains_by!(s, &k, |a, b| *a <= *b) }

public fun rem_le(s: &mut SortedSet<u64>, k: u64): bool { ss::remove_by!(s, &k, |a, b| *a <= *b) }

/// Remove under `>` against a set built with `<`: the descending search reads ascending data,
/// returns found=false, so the bool is wrong (a no-op).
public fun rem_gt(s: &mut SortedSet<u64>, k: u64): bool { ss::remove_by!(s, &k, |a, b| *a > *b) }

/// Insert under `>` against a set built with `<`: lands a key under the wrong order, desorting
/// the set (visible to the `<` well-formedness check).
public fun ins_gt(s: &mut SortedSet<u64>, k: u64): bool { ss::insert_by!(s, k, |a, b| *a > *b) }

// ===========================================================================
// `inner_mut` misuse drivers - the public but unchecked order-ONLY corruption surface
// ===========================================================================

/// Drive the wrapped map's `insert_at` directly at a caller-chosen index. With a wrong index
/// this desorts THAT set's inner vector - order-only, NO value lost (the value is `Unit`).
public fun misuse_insert_at(s: &mut SortedSet<u64>, idx: u64, k: u64) {
    sorted_map::insert_at(ss::inner_mut(s), idx, sorted_map::make_entry(k, ss::unit()));
}

/// Drive the wrapped map's `insert_by!` with an INCONSISTENT comparator through `inner_mut`.
public fun misuse_insert_inconsistent(s: &mut SortedSet<u64>, k: u64) {
    let _ = sorted_map::insert_by!(ss::inner_mut(s), k, ss::unit(), |a, b| *a > *b);
}

/// Direct `pop_front` on the inner map - bypasses the set's own `EEmpty`.
/// On an empty inner map this aborts at the MAP's location/code, not the set's.
public fun misuse_pop_front_inner(s: &mut SortedSet<u64>) {
    let (_k, _u) = sorted_map::pop_front(ss::inner_mut(s));
}

/// Direct `pop_back` on the inner map - the symmetric bypass of the set's own `EEmpty`.
/// On an empty inner map this aborts at the MAP's location/code, not the set's.
public fun misuse_pop_back_inner(s: &mut SortedSet<u64>) {
    let (_k, _u) = sorted_map::pop_back(ss::inner_mut(s));
}

// ===========================================================================
// Ability witnesses - instantiating these proves the ability holds
// ===========================================================================

public fun needs_copy<T: copy>() { let _ = std::type_name::with_defining_ids<T>(); }

public fun needs_drop<T: drop>() { let _ = std::type_name::with_defining_ids<T>(); }

public fun needs_store<T: store>() { let _ = std::type_name::with_defining_ids<T>(); }

// ===========================================================================
// Coarse struct key ordered on `id` ALONE (non-integer `_by`)
// ===========================================================================
//
// Two byte-distinct keys with the same `id` but different `tag` compare EQUAL under the
// comparator - so membership is under-the-comparator, not byte-identity.

public struct Key has copy, drop, store { id: u64, tag: u64 }

public fun mk(id: u64, tag: u64): Key { Key { id, tag } }

public fun key_tag(k: &Key): u64 { k.tag }

public fun key_id(k: &Key): u64 { k.id }

public fun ins_k(s: &mut SortedSet<Key>, k: Key): bool { ss::insert_by!(s, k, |a, b| a.id < b.id) }

public fun rem_k(s: &mut SortedSet<Key>, id: u64): bool {
    ss::remove_by!(s, &Key { id, tag: 0 }, |a, b| a.id < b.id)
}

public fun has_k(s: &SortedSet<Key>, id: u64): bool {
    ss::contains_by!(s, &Key { id, tag: 0 }, |a, b| a.id < b.id)
}

public fun keys_k(s: &SortedSet<Key>): vector<Key> { ss::keys(s) }

public fun len_k(s: &SortedSet<Key>): u64 { ss::length(s) }

public fun fromk_k(ks: vector<Key>): SortedSet<Key> { ss::from_keys_by!(ks, |a, b| a.id < b.id) }

public fun wf_k(s: &SortedSet<Key>): bool {
    sorted_map::is_well_formed_by!(ss::inner_ref(s), |a, b| a.id < b.id)
}

/// Struct-key navigation/pagination via the `_by` forms - the ONLY admissible path for a
/// non-integer key (bare won't compile: no built-in `<`). One macro per helper. The
/// `a.id < b.id` lambda is defined HERE (where `Key.id` is in-scope) so it cannot be inlined at a
/// foreign test module - hence these wrappers. Probe keys carry `tag: 0` (membership is by `id`).
public fun fnext_k(s: &SortedSet<Key>, id: u64, inc: bool): Option<Key> {
    ss::find_next_by!(s, &Key { id, tag: 0 }, inc, |a, b| a.id < b.id)
}

public fun fprev_k(s: &SortedSet<Key>, id: u64, inc: bool): Option<Key> {
    ss::find_prev_by!(s, &Key { id, tag: 0 }, inc, |a, b| a.id < b.id)
}

public fun nkey_k(s: &SortedSet<Key>, id: u64): Option<Key> {
    ss::next_key_by!(s, &Key { id, tag: 0 }, |a, b| a.id < b.id)
}

public fun pkey_k(s: &SortedSet<Key>, id: u64): Option<Key> {
    ss::prev_key_by!(s, &Key { id, tag: 0 }, |a, b| a.id < b.id)
}

public fun page_k(s: &SortedSet<Key>, from_id: u64, inc: bool, lim: u64): vector<Key> {
    ss::keys_from_by!(s, &Key { id: from_id, tag: 0 }, inc, lim, |a, b| a.id < b.id)
}

// ===========================================================================
// Builders
// ===========================================================================

/// Deterministic scramble (coprime multiplier mod a prime), same as the map suite, so a
/// "build N" walks keys in a non-sorted order, exercising arbitrary insertion points.
public fun scrambled(i: u64): u64 { (i * 7919) % 100003 }

/// Build a set of `n` scrambled keys via the public `insert!` path.
public fun build_scrambled(n: u64): SortedSet<u64> {
    let mut s = ss::new<u64>();
    let mut i = 0u64;
    while (i < n) {
        ins(&mut s, scrambled(i));
        i = i + 1;
    };
    s
}

// ===========================================================================
// Reference model - a keys-only linear sorted-vector set used as ground truth
// ===========================================================================
//
// Plain, obviously-correct O(n) code. The differential test drives this and the real
// `SortedSet` through identical op streams and asserts they agree at every step,
// including the insert!/remove! booleans and membership conservation.

public struct RefSet has drop { keys: vector<u64> }

public fun rs_new(): RefSet { RefSet { keys: vector[] } }

public fun rs_len(r: &RefSet): u64 { r.keys.length() }

/// Insert keeping `keys` ascending. Returns `true` iff the key was NEWLY added (mirrors the
/// set's `insert!` bool polarity).
public fun rs_insert(r: &mut RefSet, k: u64): bool {
    let n = r.keys.length();
    let mut i = 0u64;
    while (i < n) {
        let ki = *r.keys.borrow(i);
        if (ki == k) return false; // already present
        if (ki > k) break;
        i = i + 1;
    };
    r.keys.insert(k, i);
    true
}

/// Remove. Returns `true` iff the key WAS present (mirrors `remove!`).
public fun rs_remove(r: &mut RefSet, k: u64): bool {
    let n = r.keys.length();
    let mut i = 0u64;
    while (i < n) {
        if (*r.keys.borrow(i) == k) {
            r.keys.remove(i);
            return true
        };
        i = i + 1;
    };
    false
}

public fun rs_contains(r: &RefSet, k: u64): bool {
    let n = r.keys.length();
    let mut i = 0u64;
    while (i < n) {
        if (*r.keys.borrow(i) == k) return true;
        i = i + 1;
    };
    false
}

public fun rs_head(r: &RefSet): Option<u64> {
    if (r.keys.is_empty()) option::none() else option::some(*r.keys.borrow(0))
}

public fun rs_tail(r: &RefSet): Option<u64> {
    let n = r.keys.length();
    if (n == 0) option::none() else option::some(*r.keys.borrow(n - 1))
}

public fun rs_find_next(r: &RefSet, k: u64, inc: bool): Option<u64> {
    let n = r.keys.length();
    let mut i = 0u64;
    while (i < n) {
        let ki = *r.keys.borrow(i);
        if (inc && ki >= k) return option::some(ki);
        if (!inc && ki > k) return option::some(ki);
        i = i + 1;
    };
    option::none()
}

public fun rs_find_prev(r: &RefSet, k: u64, inc: bool): Option<u64> {
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

public fun rs_keys_from(r: &RefSet, from: u64, inc: bool, lim: u64): vector<u64> {
    let n = r.keys.length();
    let mut out = vector[];
    let mut i = 0u64;
    while (i < n && out.length() < lim) {
        let ki = *r.keys.borrow(i);
        let qualifies = if (inc) ki >= from else ki > from;
        if (qualifies) out.push_back(ki);
        i = i + 1;
    };
    out
}

/// The full ascending key list (ground truth for `keys`).
public fun rs_keys(r: &RefSet): vector<u64> { r.keys }

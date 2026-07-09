/// The highest-leverage wrapper suite: `upsert` `bool` POLARITY, `remove!` delegation by
/// EFFECT, and `contains!` agreement.
///
/// Why `upsert`'s bool is the riskiest property: `upsert = ...upsert_by!(...).is_none()` is a
/// projection of the inner map's `Option`. Inverting that projection COMPILES, keeps the set
/// perfectly well-formed, conserves nothing-to-conserve, and is INVISIBLE to the well-formedness
/// check (`is_well_formed!`). Only a test that asserts the exact boolean on a known transition
/// catches it. These tests assert both directions explicitly and cross-check every bool against
/// `contains!` before/after.
///
/// `remove!` has no bool to invert - it returns nothing and ABORTS on an absent key (the
/// abort itself is pinned in `abort_tests`). What can still silently break is DELEGATION: a
/// wrapper that drops the wrong element, or none at all, still type-checks. So the remove tests
/// here assert the EFFECT (the `contains!` flip and the length/keys delta) on every position.
module openzeppelin_collections::sorted_set_polarity_tests;

use openzeppelin_collections::sorted_set as ss;
use openzeppelin_collections::sorted_set_test_util as u;
use std::unit_test::assert_eq;

// === upsert polarity: true on fresh, false on re-insert ===

#[test]
fun insert_true_on_fresh_false_on_reinsert() {
    let mut s = ss::new<u64>();
    assert!(u::ins(&mut s, 10)); // fresh -> TRUE (inner upsert returned none)
    assert_eq!(s.length(), 1);
    assert!(u::has(&s, 10)); // contains! flips false -> true
    assert!(!u::ins(&mut s, 10)); // re-insert -> FALSE (idempotent, length unchanged)
    assert_eq!(s.length(), 1);
    assert!(u::has(&s, 10)); // still present
    assert!(u::wf(&s));
}

// === remove! effect: the contains! flip and length/keys delta at head/middle/tail ===

#[test]
fun remove_present_flips_contains_and_shrinks() {
    let mut s = u::fromk(vector[10u64, 20]);
    u::rem(&mut s, 10); // head
    assert_eq!(s.length(), 1);
    assert!(!u::has(&s, 10)); // contains! flips true -> false
    assert!(u::wf(&s));
    // Pin a direct MIDDLE and TAIL remove! too - the shifting remove_at path at each position
    // (differential covers them only transitively).
    let mut s3 = u::fromk(vector[10u64, 20, 30]);
    u::rem(&mut s3, 20); // middle
    assert_eq!(s3.keys(), vector[10u64, 30]);
    u::rem(&mut s3, 30); // tail
    assert_eq!(s3.keys(), vector[10u64]);
    assert!(u::wf(&s3));
}

#[test]
fun contains_boundaries() {
    // The full contains! boundary table in one place - below-min, above-max, interior
    // gap, and present (head/middle/tail) - on a POPULATED set. Today these are pinned only
    // transitively inside the 1200-op differential, never as a named boundary enumeration.
    let s = u::fromk(vector[10u64, 20, 30]);
    assert!(!u::has(&s, 5)); // below min
    assert!(!u::has(&s, 35)); // above max
    assert!(!u::has(&s, 15)); // interior gap
    assert!(u::has(&s, 10)); // present (head)
    assert!(u::has(&s, 20)); // present (middle)
    assert!(u::has(&s, 30)); // present (tail)
}

// === transitions: upsert's bool and remove!'s effect agree with the contains! flip ===

#[test]
fun insert_remove_transitions_agree_with_contains() {
    let mut s = ss::new<u64>();
    // Before each insert, contains! predicts the bool: upsert true iff NOT contained.
    let before_ins = u::has(&s, 5);
    let ins_bool = u::ins(&mut s, 5);
    assert_eq!(ins_bool, !before_ins); // was absent -> newly added
    assert!(u::has(&s, 5));

    let before_reins = u::has(&s, 5);
    let reins_bool = u::ins(&mut s, 5);
    assert_eq!(reins_bool, !before_reins); // was present -> false

    // remove! of the present key flips contains! true -> false.
    assert!(u::has(&s, 5));
    u::rem(&mut s, 5);
    assert!(!u::has(&s, 5));
}

#[test]
fun insert_remove_roundtrip() {
    // remove-then-reinsert is a clean round trip.
    let mut s = ss::new<u64>();
    assert!(u::ins(&mut s, 1));
    u::rem(&mut s, 1);
    assert!(!u::has(&s, 1));
    assert!(u::ins(&mut s, 1)); // fresh again after removal
    assert!(u::has(&s, 1));
}

// === polarity under a deterministic op stream: counters must match exactly ===

#[test]
fun polarity_counters_over_sequence() {
    // Count TRUE returns of upsert over a deterministic op stream. The partitions are
    // deliberately ASYMMETRIC so the counter can be hit ONLY under correct polarity - an inverted
    // projection changes the total, not just which call in a pair returns true. (A symmetric
    // fresh/duplicate split would be inversion-invariant and thus vacuous.) The remove half then
    // drains a present cohort and pins the exact length delta by EFFECT (remove! has no bool).
    let mut s = ss::new<u64>();
    let mut true_inserts = 0u64;

    // Insert 0..49 ONCE (50 fresh -> true), then re-insert ONLY 0..9 (10 duplicates -> false).
    // Correct polarity: 50 + 0 == 50. Inverted insert (.is_some()): 0 + 10 == 10 != 50 -> FAIL.
    let mut i = 0u64;
    while (i < 50) {
        if (u::ins(&mut s, i)) true_inserts = true_inserts + 1;
        i = i + 1;
    };
    let mut d = 0u64;
    while (d < 10) {
        if (u::ins(&mut s, d)) true_inserts = true_inserts + 1; // duplicate -> false
        d = d + 1;
    };
    assert_eq!(true_inserts, 50);
    assert_eq!(s.length(), 50);

    // Remove a present cohort 0..9 (10 present) - each must shrink the set by exactly one.
    // A delegation bug that removed the wrong element or none would break the final length.
    let mut k = 0u64;
    while (k < 10) {
        u::rem(&mut s, k);
        k = k + 1;
    };
    assert_eq!(s.length(), 40); // 50 - 10 removed
    let mut c = 0u64;
    while (c < 10) {
        assert!(!u::has(&s, c)); // every removed key is gone
        c = c + 1;
    };
    assert!(u::wf(&s));
}

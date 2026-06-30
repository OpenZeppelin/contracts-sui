/// The highest-leverage wrapper suite: `insert!`/`remove!` `bool` POLARITY and
/// `contains!` agreement.
///
/// Why this is the riskiest property: `insert! = ...insert_by!(...).is_none()` and
/// `remove! = ...remove_by!(...).is_some()` are OPPOSITE projections of the inner map's
/// `Option`. Inverting either projection COMPILES, keeps the set perfectly well-formed, conserves
/// nothing-to-conserve, and is INVISIBLE to the well-formedness check (`is_well_formed!`). Only a
/// test that asserts the exact boolean on a known transition catches it. These tests assert both
/// directions explicitly and cross-check every bool against `contains!` before/after.
module openzeppelin_sorted_set::polarity_tests;

use openzeppelin_sorted_set::sorted_set as ss;
use openzeppelin_sorted_set::test_util as u;
use std::unit_test::assert_eq;

// === insert! polarity: true on fresh, false on re-insert ===

#[test]
fun insert_true_on_fresh_false_on_reinsert() {
    let mut s = ss::new<u64>();
    assert!(u::ins(&mut s, 10)); // fresh -> TRUE (inner upsert returned none)
    assert_eq!(ss::length(&s), 1);
    assert!(u::has(&s, 10)); // contains! flips false -> true
    assert!(!u::ins(&mut s, 10)); // re-insert -> FALSE (idempotent, length unchanged)
    assert_eq!(ss::length(&s), 1);
    assert!(u::has(&s, 10)); // still present
    assert!(u::wf(&s));
}

// === remove! polarity: true on present, false on absent ===

#[test]
fun remove_true_on_present_false_on_absent() {
    let mut s = u::fromk(vector[10u64, 20]);
    assert!(u::rem(&mut s, 10)); // present -> TRUE (inner remove returned some)
    assert_eq!(ss::length(&s), 1);
    assert!(!u::has(&s, 10)); // contains! flips true -> false
    assert!(!u::rem(&mut s, 10)); // absent -> FALSE, total (no abort)
    assert_eq!(ss::length(&s), 1);
    assert!(!u::rem(&mut s, 999)); // never-present -> FALSE
    assert!(u::wf(&s));
    // The asserts above remove the HEAD (10). Pin a direct MIDDLE and TAIL remove! too - the
    // shifting remove_at path at each position (differential covers them only transitively).
    let mut s3 = u::fromk(vector[10u64, 20, 30]);
    assert!(u::rem(&mut s3, 20)); // middle present -> true
    assert_eq!(ss::keys(&s3), vector[10u64, 30]);
    assert!(u::rem(&mut s3, 30)); // tail present -> true
    assert_eq!(ss::keys(&s3), vector[10u64]);
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

// === transitions: bool agrees with the contains! flip and the length delta ===

#[test]
fun insert_remove_transitions_agree_with_contains() {
    let mut s = ss::new<u64>();
    // Before each mutator, contains! predicts the bool: insert! true iff NOT contained;
    // remove! true iff contained.
    let before_ins = u::has(&s, 5);
    let ins_bool = u::ins(&mut s, 5);
    assert_eq!(ins_bool, !before_ins); // was absent -> newly added
    assert!(u::has(&s, 5));

    let before_reins = u::has(&s, 5);
    let reins_bool = u::ins(&mut s, 5);
    assert_eq!(reins_bool, !before_reins); // was present -> false

    let before_rem = u::has(&s, 5);
    let rem_bool = u::rem(&mut s, 5);
    assert_eq!(rem_bool, before_rem); // was present -> true
    assert!(!u::has(&s, 5));

    let before_rem2 = u::has(&s, 5);
    let rem2_bool = u::rem(&mut s, 5);
    assert_eq!(rem2_bool, before_rem2); // was absent -> false
}

#[test]
fun insert_remove_roundtrip() {
    // remove-then-reinsert is a clean round trip.
    let mut s = ss::new<u64>();
    assert!(u::ins(&mut s, 1));
    assert!(u::rem(&mut s, 1));
    assert!(!u::has(&s, 1));
    assert!(u::ins(&mut s, 1)); // fresh again after removal
    assert!(u::has(&s, 1));
}

// === polarity under a deterministic op stream: counters must match exactly ===

#[test]
fun polarity_counters_over_sequence() {
    // Count TRUE returns over a deterministic op stream. The partitions are deliberately
    // ASYMMETRIC so the counters can be hit ONLY under correct polarity - an inverted
    // projection changes the totals, not just which call in a pair returns true. (A symmetric
    // fresh/duplicate split would be inversion-invariant and thus vacuous: inverting either
    // projection leaves the symmetric version green. This asymmetric version FAILS under either
    // inversion.)
    let mut s = ss::new<u64>();
    let mut true_inserts = 0u64;
    let mut true_removes = 0u64;

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
    assert_eq!(ss::length(&s), 50);

    // Remove a present cohort 0..9 (10 present -> true), then a DISJOINT never-present cohort
    // 100..102 (3 absent -> false). Unequal sizes break the tie a count alone could mask.
    // Correct polarity: 10 + 0 == 10. Inverted remove (.is_none()): 0 + 3 == 3 != 10 -> FAIL.
    let mut k = 0u64;
    while (k < 10) {
        if (u::rem(&mut s, k)) true_removes = true_removes + 1;
        k = k + 1;
    };
    let mut a = 100u64;
    while (a < 103) {
        if (u::rem(&mut s, a)) true_removes = true_removes + 1; // never present -> false
        a = a + 1;
    };
    assert_eq!(true_removes, 10);
    assert_eq!(ss::length(&s), 40); // 50 - 10 removed
    assert!(u::wf(&s));
}

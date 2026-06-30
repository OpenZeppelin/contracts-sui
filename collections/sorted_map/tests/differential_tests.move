/// The authoritative correctness proof.
///
/// Drives the real `SortedMap` and a linear sorted-vector REFERENCE MODEL (`test_util::Ref`)
/// through an identical stream of randomized ops, asserting they agree at every step, and
/// re-checks `is_well_formed` after EVERY op. This is where the maintained-by-construction
/// core (search soundness, sorted order, mutation semantics) is actually pinned down - none
/// of it has a runtime guard in production.
///
/// All ops route through `test_util` wrappers, so the 1,200-op loop body expands no macros
/// and stays far under the 256-locals limit.
module openzeppelin_sorted_map::differential_tests;

use openzeppelin_sorted_map::sorted_map as sm;
use openzeppelin_sorted_map::test_util as u;
use std::unit_test::assert_eq;

const MASK: u128 = 0xFFFFFFFFFFFFFFFF;

#[test]
fun differential_1200_ops() {
    let mut m = sm::new<u64, u64>();
    let mut r = u::ref_new();
    let mut seed: u128 = 0x9E3779B97F4A7C15;
    let mut vseq = 1_000_000u64; // monotonically unique inserted values
    let mut i = 0u64;
    while (i < 1200) {
        // LCG in u128 to avoid overflow-abort; mask back to 64 bits.
        seed = (seed * 6364136223846793005 + 1442695040888963407) & MASK;
        let s = (seed as u64);
        let k = (s >> 33) % 250; // keyspace 0..249 -> mix of hits and misses
        let op = (s >> 17) % 8;
        if (op == 0 || op == 1) {
            // bias toward mutation to churn the structure. The value is a unique counter
            // (NOT a function of the key), so on a replace the returned some(old) carries a
            // value distinguishable from the new one - this is what makes the Option
            // equality genuinely verify the upsert's returned old value, not just
            // the some/none discrimination.
            let v = vseq;
            vseq = vseq + 1;
            assert_eq!(u::ins(&mut m, k, v), u::ref_insert(&mut r, k, v));
        } else if (op == 2) {
            assert_eq!(u::rm(&mut m, k), u::ref_remove(&mut r, k));
        } else if (op == 3) {
            assert_eq!(u::has(&m, k), u::ref_contains(&r, k));
            if (u::has(&m, k)) assert_eq!(u::get(&m, k), u::ref_get(&r, k));
        } else if (op == 4) {
            assert_eq!(u::fnext(&m, k, true), u::ref_find_next(&r, k, true));
            assert_eq!(u::fnext(&m, k, false), u::ref_find_next(&r, k, false));
        } else if (op == 5) {
            assert_eq!(u::fprev(&m, k, true), u::ref_find_prev(&r, k, true));
            assert_eq!(u::fprev(&m, k, false), u::ref_find_prev(&r, k, false));
        } else if (op == 6) {
            assert_eq!(u::nxt(&m, k), u::ref_find_next(&r, k, false));
            assert_eq!(u::prv(&m, k), u::ref_find_prev(&r, k, false));
        } else {
            assert_eq!(sm::length(&m), u::ref_length(&r));
            assert_eq!(sm::head(&m), u::ref_head(&r));
            assert_eq!(sm::tail(&m), u::ref_tail(&r));
        };
        assert!(u::wf(&m)); // strictly increasing after every op
        i = i + 1;
    };
    // Final: the head + next_key walk must reproduce the reference's exact ordered key
    // sequence (verifies the next_key cursor chain end to end), and an independent
    // keys_from page must agree too.
    assert_eq!(sm::length(&m), u::ref_length(&r));
    let mut walked = vector[];
    let mut cur = sm::head(&m);
    while (cur.is_some()) {
        let kk = *cur.borrow();
        walked.push_back(kk);
        cur = u::nxt(&m, kk);
    };
    assert_eq!(walked, u::ref_keys_from(&r, 0, true, 100000));
    assert_eq!(u::kfrom(&m, 0, true, 100000), u::ref_keys_from(&r, 0, true, 100000));
}

/// Large-N functional regression: build ~1,000 entries and scan ALL of them in a single
/// `keys_from` call, with per-build `is_well_formed`. The property that this touches exactly
/// ONE stored object regardless of N is structural (the map is one inline vector, no dynamic
/// fields) and is not observable from a Move unit test. This test pins the functional result:
/// a full-map walk over 1,000 entries stays correct and is one call, by construction.
#[test]
fun large_n_build_and_full_walk() {
    let n = 1000;
    let m = u::build_scrambled(n);
    assert_eq!(sm::length(&m), n);
    assert!(u::wf(&m));
    // full-map page in a single op
    let all = u::kfrom(&m, 0, true, n + 10);
    assert_eq!(all.length(), n);
}

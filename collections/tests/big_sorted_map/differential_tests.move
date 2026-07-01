/// The authoritative correctness proof - the differential test.
///
/// Drives the real `BigSortedMap` and a trivially-correct linear sorted-vector reference model
/// (`test_util::Ref`) through an identical stream of randomized ops, asserting they agree at every
/// step, and re-runs the full well-formedness check `bsm_well_formed` AFTER EVERY OP (including
/// removes and pops - an insert-only check would miss routing-key corruption introduced by a
/// remove or pop). This is the only catch for the logical routing-key bugs `is_well_formed` alone
/// cannot see and the place where the maintained-by-construction core (equal depth,
/// half-full, routing==subtree-max, sorted leaf chain, upsert/remove semantics) is actually pinned.
///
/// Forced LOW degree so a single op triggers split/merge/collapse cheaply and the whole tree stays
/// far under the df-load cap (so a single-pass check is sound, unit-test-bounded).
/// Run at MULTIPLE degree configs + seeds (thorough sweep). Every op routes through `test_util`
/// wrappers, so the multi-thousand-op loop body expands no macros.
module openzeppelin_collections::big_sorted_map_differential_tests;

use openzeppelin_collections::big_sorted_map::{Self as bsm, BigSortedMap};
use openzeppelin_collections::big_sorted_map_test_util as u;
use std::unit_test::assert_eq;

const MASK: u128 = 0xFFFFFFFFFFFFFFFF;

/// One randomized differential run at the given degrees, op count, seed, and keyspace. Inserts are
/// biased to churn structure; the value is a unique monotone counter (NOT a function of the key) so
/// the `some(old)` returned on an upsert carries a value distinguishable from the new one - that is
/// what makes the `Option` equality genuinely verify the returned OLD value, not just the
/// some/none discrimination. Pops exercise the spine cache + positional rebalance.
/// `oracle_every`: run the full well-formedness check every Nth op (1 => after EVERY op, the gold
/// standard; a larger N trades per-op well-formedness coverage for higher op counts under the
/// per-test gas budget - used by the high-volume run, which still checks frequently + at the end).
fun run_diff(
    inner_deg: u64,
    leaf_deg: u64,
    n_ops: u64,
    seed0: u128,
    keyspace: u64,
    oracle_every: u64,
) {
    let mut ctx = tx_context::dummy();
    let mut m = bsm::new_with_config<u64, u64>(inner_deg, leaf_deg, &mut ctx);
    let mut r = u::ref_new();
    let mut seed: u128 = seed0;
    let mut vseq = 1_000_000u64;
    let mut i = 0;
    while (i < n_ops) {
        seed = (seed * 6364136223846793005 + 1442695040888963407) & MASK;
        let s = (seed as u64);
        let k = (s >> 33) % keyspace;
        let op = (s >> 17) % 10;
        if (op == 0 || op == 1 || op == 2) {
            let v = vseq;
            vseq = vseq + 1;
            assert_eq!(u::ins(&mut m, k, v), u::ref_insert(&mut r, k, v));
        } else if (op == 3) {
            assert_eq!(u::rem(&mut m, k), u::ref_remove(&mut r, k));
        } else if (op == 4) {
            assert_eq!(u::has(&m, k), u::ref_contains(&r, k));
            if (u::has(&m, k)) {
                assert_eq!(u::get(&m, k), u::ref_get(&r, k));
                // borrow_mut in-place value rewrite (unique counter), mirrored in the reference model -
                // the later get-equality op then cross-checks it. Brings borrow_mut under the check.
                let nv = vseq;
                vseq = vseq + 1;
                u::set(&mut m, k, nv);
                u::ref_insert(&mut r, k, nv); // upsert of a present key == in-place value change
                assert_eq!(u::get(&m, k), nv);
            };
        } else if (op == 5) {
            assert_eq!(u::fnext(&m, k, true), u::ref_find_next(&r, k, true));
            assert_eq!(u::fnext(&m, k, false), u::ref_find_next(&r, k, false));
        } else if (op == 6) {
            assert_eq!(u::fprev(&m, k, true), u::ref_find_prev(&r, k, true));
            assert_eq!(u::fprev(&m, k, false), u::ref_find_prev(&r, k, false));
        } else if (op == 7) {
            assert_eq!(u::nxt(&m, k), u::ref_find_next(&r, k, false));
            assert_eq!(u::prv(&m, k), u::ref_find_prev(&r, k, false));
        } else if (op == 8) {
            // pop_front: compare the (k,v) extreme, guarded on non-empty (lengths agree by invariant).
            if (bsm::length(&m) > 0) {
                let (mk, mv) = bsm::pop_front(&mut m);
                let (rk, rv) = u::ref_pop_front(&mut r);
                assert!(mk == rk && mv == rv);
            } else {
                assert_eq!(u::ref_length(&r), 0);
            };
        } else {
            // structural / size agreement + (occasionally) pop_back.
            assert_eq!(bsm::length(&m), u::ref_length(&r));
            assert_eq!(bsm::head(&m), u::ref_head(&r));
            assert_eq!(bsm::tail(&m), u::ref_tail(&r));
            if (bsm::length(&m) > 0) {
                let (mk, mv) = bsm::pop_back(&mut m);
                let (rk, rv) = u::ref_pop_back(&mut r);
                assert!(mk == rk && mv == rv);
            };
        };
        // full well-formedness check (every op when oracle_every == 1), including removes/pops.
        if (oracle_every <= 1 || i % oracle_every == 0) {
            assert!(u::bsm_well_formed(&m, inner_deg, leaf_deg, true));
        };
        i = i + 1;
    };
    assert!(u::bsm_well_formed(&m, inner_deg, leaf_deg, true)); // final structural check
    // Final cross-checks: the head + next_key walk reproduces the reference's exact ordered key
    // sequence (end-to-end leaf-chain / cursor), and an independent keys_from page agrees too.
    assert_eq!(bsm::length(&m), u::ref_length(&r));
    let mut walked = vector[];
    let mut cur = bsm::head(&m);
    while (cur.is_some()) {
        let kk = *cur.borrow();
        walked.push_back(kk);
        cur = u::nxt(&m, kk);
    };
    assert_eq!(walked, u::ref_keys_from(&r, 0, true, 1_000_000));
    assert_eq!(u::kfrom(&m, 0, true, 1_000_000), u::ref_keys_from(&r, 0, true, 1_000_000));
    u::drain_destroy(m);
}

// Per-op well-formedness check (oracle_every == 1) across several degree configs + seeds, each
// sized to stay under the default per-test gas budget.

#[test]
fun differential_deg_3_4_seed_a() {
    run_diff(4, 3, 1000, 0x9E3779B97F4A7C15, 40, 1);
}

#[test]
fun differential_deg_4_4_seed_b() {
    run_diff(4, 4, 800, 0xD1B54A32D192ED03, 50, 1);
}

#[test]
fun differential_deg_6_5_seed_c() {
    run_diff(6, 5, 700, 0xA0761D6478BD642F, 80, 1);
}

/// A tight keyspace at the minimum degree maximizes structural churn (constant splits, merges,
/// collapses, and re-growth on a small, dense keyspace) - the harshest test of the rebalance core.
#[test]
fun differential_min_degree_dense_churn() {
    run_diff(4, 3, 1000, 0x2545F4914F6CDD1D, 20, 1);
}

/// High-volume run: drive the reference-model agreement through many more states in one continuous
/// stream, with the (expensive) well-formedness check every 25 ops + at the end. Sized to stay under
/// the default per-test gas budget (the individual descend+cascade ops, not just the check, are the
/// gas cost - so total ops are bounded ~1500 per test).
#[test]
fun differential_high_volume() {
    run_diff(4, 3, 1500, 0x14057B7EF767814F, 50, 25);
}

/// Large-N functional regression: bulk-build ~1,000 entries at low degree (a deep, wide tree),
/// confirm well-formedness, then scan ALL of them in a single bounded `keys_from`. Exercises the
/// bulk-build packer + a full leaf-chain traversal at scale.
#[test]
fun large_n_build_and_full_walk() {
    let mut ctx = tx_context::dummy();
    let n = 1000u64;
    let src = u::sm_build(n); // keys 1..=n ascending
    let map = u::from_sm_lowdeg(src, &mut ctx); // inner 4 / leaf 3 -> many levels
    assert_eq!(bsm::length(&map), n);
    assert!(u::bsm_well_formed(&map, 4, 3, true));
    assert!(u::tree_depth(&map) >= 4); // genuinely deep
    let all = u::kfrom(&map, 1, true, n + 10);
    assert_eq!(all.length(), n);
    let mut j = 1;
    while (j < all.length()) {
        assert!(*all.borrow(j - 1) < *all.borrow(j));
        j = j + 1;
    };
    assert!(bsm::head(&map) == option::some(1) && bsm::tail(&map) == option::some(n));
    u::drain_destroy(map);
}

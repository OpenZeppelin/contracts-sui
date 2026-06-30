/// The authoritative correctness proof for the maintained-not-checked core.
///
/// Drives the real `SortedSet` and a keys-only sorted-vector REFERENCE MODEL (`test_util::RefSet`)
/// through an identical stream of deterministic-pseudorandom ops, asserting they agree at every
/// step - including the `insert!`/`remove!` BOOLEANS and `contains!` - and re-checks
/// `is_well_formed!` after EVERY op. None of this has a runtime guard in production; the
/// differential is where it is actually pinned. Membership conservation is the cross-cutting
/// consequence: a key the reference model holds is never reported absent unless a
/// `remove!`/`pop_*` removed it.
///
/// All ops route through `test_util` wrappers, so the loop body expands no macros and stays far
/// under the ~256-locals limit.
module openzeppelin_sorted_set::differential_tests;

use openzeppelin_sorted_set::sorted_set::{Self as ss};
use openzeppelin_sorted_set::test_util as u;
use std::unit_test::assert_eq;

const MASK: u128 = 0xFFFFFFFFFFFFFFFF;

#[test]
fun differential_1200_ops() {
    let mut s = ss::new<u64>();
    let mut r = u::rs_new();
    let mut seed: u128 = 0x9E3779B97F4A7C15;
    let mut i = 0u64;
    while (i < 1200) {
        // LCG in u128 to avoid overflow-abort; mask back to 64 bits.
        seed = (seed * 6364136223846793005 + 1442695040888963407) & MASK;
        let x = (seed as u64);
        let k = (x >> 33) % 250; // keyspace 0..249 -> mix of hits and misses
        let op = (x >> 17) % 8;
        if (op == 0 || op == 1) {
            // bias toward insert to churn the structure. The BOOL must match the reference
            // model's newly-added verdict exactly.
            assert_eq!(u::ins(&mut s, k), u::rs_insert(&mut r, k));
        } else if (op == 2) {
            // remove BOOL must match the reference model's was-present verdict.
            assert_eq!(u::rem(&mut s, k), u::rs_remove(&mut r, k));
        } else if (op == 3) {
            // contains! agrees with the reference model - no silent membership drift.
            assert_eq!(u::has(&s, k), u::rs_contains(&r, k));
        } else if (op == 4) {
            assert_eq!(u::fnext(&s, k, true), u::rs_find_next(&r, k, true));
            assert_eq!(u::fnext(&s, k, false), u::rs_find_next(&r, k, false));
        } else if (op == 5) {
            assert_eq!(u::fprev(&s, k, true), u::rs_find_prev(&r, k, true));
            assert_eq!(u::fprev(&s, k, false), u::rs_find_prev(&r, k, false));
        } else if (op == 6) {
            assert_eq!(u::nkey(&s, k), u::rs_find_next(&r, k, false));
            assert_eq!(u::pkey(&s, k), u::rs_find_prev(&r, k, false));
        } else {
            assert_eq!(ss::length(&s), u::rs_len(&r));
            assert_eq!(ss::head(&s), u::rs_head(&r));
            assert_eq!(ss::tail(&s), u::rs_tail(&r));
        };
        assert!(u::wf(&s)); // strictly increasing after every op
        i = i + 1;
    };
    // Final: the head + next_key walk must reproduce the reference's exact ordered key sequence
    // (verifies the next_key cursor chain end to end), and an independent keys_from page
    // plus keys() must agree too.
    assert_eq!(ss::length(&s), u::rs_len(&r));
    let mut walked = vector[];
    let mut cur = ss::head(&s);
    while (cur.is_some()) {
        let kk = *cur.borrow();
        walked.push_back(kk);
        cur = u::nkey(&s, kk);
    };
    let truth = u::rs_keys_from(&r, 0, true, 1000000);
    assert_eq!(walked, truth);
    assert_eq!(u::page(&s, 0, true, 1000000), truth);
    assert_eq!(ss::keys(&s), truth);
}

/// Membership conservation. A fixed cohort of "members" is inserted, then a long
/// churn of UNRELATED keys is interleaved; every member must stay present (contains! true) until
/// (and only until) it is explicitly removed. A silently de-listed member is a security event for
/// an allowlist/registry, so this is asserted directly, not just via the differential.
#[test]
fun membership_conservation() {
    let mut s = ss::new<u64>();
    // members live in a high band; churn keys in a low band -> no accidental overlap.
    let members = vector[1000u64, 1001, 1002, 1003, 1004, 1005, 1006, 1007];
    let mut mi = 0;
    while (mi < members.length()) {
        assert!(u::ins(&mut s, members[mi])); // each freshly added
        mi = mi + 1;
    };
    // Interleave churn (insert+remove of low-band keys) and re-check all members after each step.
    let mut seed: u128 = 0x1234_5678_9ABC_DEF0;
    let mut step = 0u64;
    while (step < 400) {
        seed = (seed * 6364136223846793005 + 1442695040888963407) & MASK;
        let ck = ((seed as u64) >> 33) % 200; // low band 0..199
        u::ins(&mut s, ck);
        u::rem(&mut s, ck + 1);
        // every member still present - no churn ever evicts one.
        let mut j = 0;
        while (j < members.length()) {
            assert!(u::has(&s, members[j]));
            j = j + 1;
        };
        step = step + 1;
    };
    // Now remove members one at a time: each disappears exactly when removed, none before.
    let mut ri = 0;
    while (ri < members.length()) {
        assert!(u::has(&s, members[ri])); // present right up until removal
        assert!(u::rem(&mut s, members[ri]));
        assert!(!u::has(&s, members[ri])); // gone immediately after
        ri = ri + 1;
    };
    assert!(u::wf(&s));
}

/// Build ~1,000 entries and scan ALL of them in a single `keys_from!` call, well-formed
/// throughout. The actual "touches exactly ONE stored object regardless of N" claim is structural
/// (one inline vector, no dynamic fields) and is NOT observable from a Move unit test - it is
/// proven by out-of-band localnet evidence. This pins the functional half: a full-set walk over
/// 1,000 entries stays correct in one call.
#[test]
fun large_n_build_and_full_walk() {
    let n = 1000;
    let s = u::build_scrambled(n);
    assert_eq!(ss::length(&s), n); // scrambled() is injective over 0..999 -> no dedup loss
    assert!(u::wf(&s));
    let all = u::page(&s, 0, true, n + 10); // full-set page in a single op
    assert_eq!(all.length(), n);
    assert_eq!(ss::keys(&s).length(), n);
}

/// pop_front/pop_back delegation-correctness AT SCALE: pops are ABSENT from the 1200-op
/// differential loop (op-branches 0..7 cover insert/remove/contains/nav/length only), so the only
/// pop-returns-extreme evidence is a fixed N=4 happy path. This drains a 100-key scrambled set via
/// alternating pops and asserts each equals the expected sorted min/max from the keys() ground
/// truth, well-formed between every pop.
#[test]
fun pop_drains_true_extremes_at_scale() {
    let s0 = u::build_scrambled(100);
    let sorted = ss::keys(&s0); // ascending ground truth
    let n = sorted.length();
    assert_eq!(n, 100); // scrambled() injective over 0..99 -> no dedup loss
    let mut s = s0;
    let mut lo = 0;
    let mut hi = n;
    while (lo < hi) {
        assert_eq!(ss::pop_front(&mut s), sorted[lo]); // current min
        lo = lo + 1;
        if (lo < hi) {
            hi = hi - 1;
            assert_eq!(ss::pop_back(&mut s), sorted[hi]); // current max
        };
        assert!(u::wf(&s)); // strictly increasing after every pop
    };
    assert!(ss::is_empty(&s));
}

/// Pagination at scale: resume keys_from in many small pages over a ~1000-key set; the pages must
/// concatenate to the full ascending keys() with no gap/overlap and be strictly increasing. The
/// 1200-op differential only checks a SINGLE full-width page at scale, never a real resume loop.
#[test]
fun keys_from_multipage_contiguity() {
    let s = u::build_scrambled(1000);
    let mut acc = vector[];
    let mut from = 0u64;
    let mut inc = true; // first page includes the minimum (scrambled(0) == 0)
    loop {
        let pg = u::page(&s, from, inc, 50);
        if (pg.is_empty()) break;
        let last = pg[pg.length() - 1];
        acc.append(pg);
        from = last;
        inc = false; // resume strictly past the last key of the previous page
    };
    assert_eq!(acc, ss::keys(&s)); // pages reconstruct the full ascending list exactly
    let mut i = 1;
    while (i < acc.length()) {
        assert!(acc[i - 1] < acc[i]); // strictly increasing -> no duplicate/overlap across pages
        i = i + 1;
    };
}

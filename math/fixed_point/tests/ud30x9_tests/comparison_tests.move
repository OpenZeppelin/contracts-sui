#[test_only]
module openzeppelin_fp_math::ud30x9_comparison_tests;

use openzeppelin_fp_math::ud30x9_test_helpers::{fixed, pair, unpack};

const MAX_VALUE: u128 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
const SCALE: u128 = 1_000_000_000;

#[test]
fun comparison_helpers_cover_all_outcomes() {
    let low = fixed(10 * SCALE);
    let high = fixed(20 * SCALE);

    assert!(low.lt(high));
    assert!(!high.lt(low));

    assert!(high.gt(low));
    assert!(!low.gt(high));

    assert!(high.gte(low));
    assert!(high.gte(high));
    assert!(!low.gte(high));

    assert!(low.lte(high));
    assert!(low.lte(low));
    assert!(!high.lte(low));

    assert!(low.eq(low));
    assert!(!low.eq(high));

    assert!(low.neq(high));
    assert!(!low.neq(low));

    let zero = fixed(0);
    assert!(zero.is_zero());
    assert!(!high.is_zero());
}

#[test]
fun compare_equal_values() {
    let x = fixed(42 * SCALE);
    assert!(x.eq(fixed(42 * SCALE)));
    assert!(x.lte(fixed(42 * SCALE)));
    assert!(x.gte(fixed(42 * SCALE)));
}

#[test]
fun compare_zero_and_nonzero() {
    assert!(fixed(0).lt(fixed(SCALE)));
    assert!(fixed(SCALE).gt(fixed(0)));
}

#[test]
fun compare_large_values() {
    assert!(fixed(MAX_VALUE - 1).lt(fixed(MAX_VALUE)));
}

#[test]
fun is_zero_only_for_zero() {
    assert!(fixed(0).is_zero());
    assert!(!fixed(SCALE).is_zero());
}

#[test]
fun eq_and_neq_consistency() {
    let pairs = vector[
        pair(fixed(0), fixed(0)),
        pair(fixed(42 * SCALE), fixed(42 * SCALE)),
        pair(fixed(SCALE), fixed(SCALE)),
    ];
    pairs.destroy!(|p| {
        let (a, b) = p.unpack();
        assert!(a.eq(b));
        assert!(!a.neq(b));
    });
}

#[test]
fun compare_adjacent() {
    assert!(fixed(99 * SCALE).lt(fixed(100 * SCALE)));
    assert!(fixed(100 * SCALE).gt(fixed(99 * SCALE)));
}

#[test]
fun lte_and_gte_symmetry() {
    let pairs = vector[
        pair(fixed(SCALE), fixed(2 * SCALE)),
        pair(fixed(0), fixed(SCALE)),
        pair(fixed(SCALE), fixed(SCALE + 1)),
    ];
    pairs.destroy!(|p| {
        let (a, b) = p.unpack();
        assert!(a.lte(b));
        assert!(b.gte(a));
    });
}

#[test]
fun compare_scale_values() {
    assert!(fixed(SCALE).gt(fixed(SCALE - 1)));
    assert!(fixed(SCALE).lt(fixed(SCALE + 1)));
}

#[test]
fun neq_distinct_values() {
    assert!(fixed(SCALE).neq(fixed(2 * SCALE)));
}

#[test]
fun lt_is_strict() {
    assert!(!fixed(5 * SCALE).lt(fixed(5 * SCALE)));
}

#[test]
fun gt_is_strict() {
    assert!(!fixed(5 * SCALE).gt(fixed(5 * SCALE)));
}

#[test_only]
module openzeppelin_fp_math::sd29x9_comparison_tests;

use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_test_helpers::{pos, neg};

const MAX_POSITIVE_VALUE: u128 = 0x7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
const SCALE: u128 = 1_000_000_000;

#[test]
fun comparison_helpers_handle_all_cases() {
    let neg_two = neg(2 * SCALE);
    let neg_four = neg(4 * SCALE);
    let pos_two = pos(2 * SCALE);

    assert!(neg_four.lt(neg_two));
    assert!(neg_two.lt(pos_two));
    assert!(!pos_two.lt(neg_two));

    assert!(pos_two.gt(neg_two));
    assert!(pos_two.gte(pos_two));
    assert!(!neg_four.gte(neg_two));

    assert!(pos_two.lte(pos_two));
    assert!(neg_four.lte(neg_two));
    assert!(!pos_two.lte(neg_two));

    assert!(pos_two.eq(pos_two));
    assert!(neg_two.neq(pos_two));
}

#[test]
fun compare_zero_with_positive() {
    let zero = sd29x9::zero();
    let one = sd29x9::one();
    assert!(zero.lt(one));
    assert!(one.gt(zero));
    assert!(zero.lte(one));
    assert!(one.gte(zero));
    assert!(!zero.gt(one));
}

#[test]
fun compare_zero_with_negative() {
    let zero = sd29x9::zero();
    let minus_one = sd29x9::one().negate();
    assert!(minus_one.lt(zero));
    assert!(zero.gt(minus_one));
    assert!(minus_one.lte(zero));
    assert!(zero.gte(minus_one));
    assert!(!zero.lt(minus_one));
}

#[test]
fun compare_min_and_max() {
    assert!(sd29x9::min().lt(sd29x9::max()));
    assert!(sd29x9::max().gt(sd29x9::min()));
}

#[test]
fun compare_equal_values() {
    assert!(pos(42 * SCALE).eq(pos(42 * SCALE)));
    assert!(neg(7 * SCALE).eq(neg(7 * SCALE)));
    assert!(!pos(42 * SCALE).neq(pos(42 * SCALE)));
}

#[test]
fun compare_adjacent_positive() {
    assert!(pos(SCALE).lt(pos(2 * SCALE)));
    assert!(pos(2 * SCALE).gt(pos(SCALE)));
    assert!(!pos(2 * SCALE).lt(pos(SCALE)));
}

#[test]
fun compare_adjacent_negative() {
    assert!(neg(2 * SCALE).lt(neg(SCALE)));
    assert!(neg(SCALE).gt(neg(2 * SCALE)));
    assert!(!neg(SCALE).lt(neg(2 * SCALE)));
}

#[test]
fun eq_reflexivity() {
    let values = vector[
        sd29x9::zero(),
        sd29x9::one(),
        sd29x9::one().negate(),
        sd29x9::max(),
        sd29x9::min(),
    ];
    values.destroy!(|x| {
        assert!(x.eq(x));
    });
}

#[test]
fun neq_with_different_sign() {
    assert!(pos(5 * SCALE).neq(neg(5 * SCALE)));
    assert!(neg(5 * SCALE).neq(pos(5 * SCALE)));
}

#[test]
fun lte_and_gte_for_equal() {
    assert!(pos(3 * SCALE).lte(pos(3 * SCALE)));
    assert!(pos(3 * SCALE).gte(pos(3 * SCALE)));
    assert!(neg(3 * SCALE).lte(neg(3 * SCALE)));
    assert!(neg(3 * SCALE).gte(neg(3 * SCALE)));
}

#[test]
fun is_zero_only_for_zero() {
    assert!(sd29x9::zero().is_zero());
    assert!(!sd29x9::one().is_zero());
    assert!(!sd29x9::one().negate().is_zero());
}

#[test]
fun compare_pos_and_neg_large() {
    assert!(neg(MAX_POSITIVE_VALUE).lt(pos(MAX_POSITIVE_VALUE)));
    assert!(pos(MAX_POSITIVE_VALUE).gt(neg(MAX_POSITIVE_VALUE)));
}

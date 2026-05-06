#[test_only]
module openzeppelin_fp_math::sd29x9_arithmetic_tests;

use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_base;
use openzeppelin_fp_math::sd29x9_test_helpers::{pos, neg, pair, unpack};
use std::unit_test::assert_eq;

const SCALE: u128 = 1_000_000_000;

#[test]
fun addition_and_subtraction_cover_signs() {
    assert_eq!(pos(10 * SCALE).add(neg(5 * SCALE)), pos(5 * SCALE));
    assert_eq!(neg(10 * SCALE).add(pos(5 * SCALE)), neg(5 * SCALE));
    assert_eq!(neg(7 * SCALE).add(neg(9 * SCALE)), neg(16 * SCALE));

    assert_eq!(pos(20 * SCALE).sub(pos(7 * SCALE)), pos(13 * SCALE));
    assert_eq!(pos(7 * SCALE).sub(pos(20 * SCALE)), neg(13 * SCALE));
    assert_eq!(neg(9 * SCALE).sub(neg(4 * SCALE)), neg(5 * SCALE));
}

#[test]
fun sum_handles_edge_cases() {
    let (min, max, zero) = (sd29x9::min(), sd29x9::max(), sd29x9::zero());
    assert_eq!(min.add(zero), min);
    assert_eq!(max.add(zero), max);
    assert_eq!(zero.add(min), min);
    assert_eq!(zero.add(max), max);

    let epsilon = pos(1);
    assert_eq!(max.negate().add(epsilon.negate()), min);
    assert_eq!(max.sub(epsilon).add(epsilon), max);
    assert_eq!(min.add(epsilon).add(epsilon).negate().add(epsilon), max);
}

#[test]
fun sum_can_reach_minimum_value() {
    let min = sd29x9::min();
    let epsilon = pos(1);
    let min_plus_epsilon = min.add(epsilon);
    let zero = sd29x9::zero();

    assert_eq!(zero.add(min), min);
    assert_eq!(min_plus_epsilon.add(neg(1)), min);
}

#[test]
fun sub_handles_edge_cases() {
    let (min, max, zero) = (sd29x9::min(), sd29x9::max(), sd29x9::zero());
    assert_eq!(min.sub(zero), min);
    assert_eq!(max.sub(zero), max);

    let epsilon = pos(1);
    let min_plus_epsilon = min.add(epsilon);
    assert_eq!(zero.sub(min_plus_epsilon), max);
    assert_eq!(zero.sub(max), min_plus_epsilon);

    assert_eq!(max.negate().sub(epsilon), min);
    assert_eq!(max.sub(epsilon).sub(epsilon.negate()), max);
    assert_eq!(min.add(epsilon).add(epsilon).negate().sub(epsilon.negate()), max);
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun checked_add_overflow_aborts() {
    let max = sd29x9::max();
    let epsilon = pos(1);
    max.add(epsilon);
}

#[test, expected_failure(abort_code = sd29x9_base::EOverflow)]
fun checked_sub_overflow_aborts() {
    let min = sd29x9::min();
    let epsilon = pos(1);
    min.sub(epsilon);
}

#[test]
fun add_zero_is_identity() {
    let zero = sd29x9::zero();
    let x_pos = pos(12_345_678_901);
    let x_neg = neg(9_876_543_210);

    assert_eq!(x_pos.add(zero), x_pos);
    assert_eq!(zero.add(x_pos), x_pos);
    assert_eq!(x_neg.add(zero), x_neg);
    assert_eq!(zero.add(x_neg), x_neg);
    assert_eq!(zero.add(zero), zero);
}

#[test]
fun sub_self_is_zero() {
    let zero = sd29x9::zero();
    assert_eq!(sd29x9::one().sub(sd29x9::one()), zero);
    assert_eq!(neg(42 * SCALE).sub(neg(42 * SCALE)), zero);
    assert_eq!(pos(999_999_999).sub(pos(999_999_999)), zero);
    assert_eq!(sd29x9::max().sub(sd29x9::max()), zero);
}

#[test]
fun add_commutativity() {
    let pairs = vector[
        pair(pos(3 * SCALE), pos(7 * SCALE)),
        pair(pos(100 * SCALE), neg(50 * SCALE)),
        pair(neg(8 * SCALE), neg(2 * SCALE)),
        pair(pos(SCALE + 1), neg(SCALE - 1)),
    ];
    pairs.destroy!(|p| {
        let (a, b) = p.unpack();
        assert_eq!(a.add(b).unwrap(), b.add(a).unwrap());
    });
}

#[test]
fun sub_negation_equivalence() {
    let pairs = vector[
        pair(pos(10 * SCALE), pos(3 * SCALE)),
        pair(pos(100 * SCALE), pos(SCALE)),
        pair(pos(50 * SCALE), pos(50 * SCALE)),
        pair(pos(10 * SCALE + 250_000_000), pos(3 * SCALE + 125_000_000)),
    ];
    pairs.destroy!(|p| {
        let (a, b) = p.unpack();
        assert_eq!(a.sub(b), a.add(b.negate()));
    });
}

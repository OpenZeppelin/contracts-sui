#[test_only]
module openzeppelin_fp_math::sd29x9_sqrt_tests;

use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_base;
use openzeppelin_fp_math::sd29x9_test_helpers::{pos, neg, expect};

const SCALE: u128 = 1_000_000_000;

// ==== Tests ====

#[test]
fun sqrt_of_zero_is_zero() {
    expect(sd29x9::zero().sqrt(), sd29x9::zero());
}

#[test]
fun sqrt_of_positive_one() {
    expect(pos(SCALE).sqrt(), pos(SCALE));
}

#[test]
fun sqrt_of_positive_perfect_squares() {
    // sqrt(+4.0) = +2.0
    expect(pos(4 * SCALE).sqrt(), pos(2 * SCALE));
    // sqrt(+9.0) = +3.0
    expect(pos(9 * SCALE).sqrt(), pos(3 * SCALE));
    // sqrt(+25.0) = +5.0
    expect(pos(25 * SCALE).sqrt(), pos(5 * SCALE));
    // sqrt(+100.0) = +10.0
    expect(pos(100 * SCALE).sqrt(), pos(10 * SCALE));
    // sqrt(+10000.0) = +100.0
    expect(pos(10_000 * SCALE).sqrt(), pos(100 * SCALE));
}

#[test]
fun sqrt_of_positive_fractional_squares() {
    // sqrt(+0.25) = +0.5
    expect(pos(250_000_000).sqrt(), pos(500_000_000));
    // sqrt(+0.01) = +0.1
    expect(pos(10_000_000).sqrt(), pos(100_000_000));
    // sqrt(+2.25) = +1.5
    expect(pos(2_250_000_000).sqrt(), pos(1_500_000_000));
}

#[test]
fun sqrt_truncates_irrational_results() {
    // sqrt(+2.0) = +1.414213562 (truncated)
    expect(pos(2 * SCALE).sqrt(), pos(1_414_213_562));
    // sqrt(+3.0) = +1.732050807 (truncated)
    expect(pos(3 * SCALE).sqrt(), pos(1_732_050_807));
    // sqrt(+5.0) = +2.236067977 (truncated)
    expect(pos(5 * SCALE).sqrt(), pos(2_236_067_977));
}

#[test]
fun sqrt_floor_property_for_non_perfect_squares() {
    let values = vector[
        pos(2 * SCALE),
        pos(3 * SCALE),
        pos(7 * SCALE),
        pos(SCALE + 1),
    ];
    values.destroy!(|x| {
        let r = x.sqrt().unwrap() as u256;
        let scaled = (x.unwrap() as u256) * (SCALE as u256);
        assert!(r * r <= scaled);
        assert!((r + 1) * (r + 1) > scaled);
    });
}

#[test]
fun sqrt_of_max_positive() {
    // sqrt(sd29x9::max()) should not abort and satisfy the floor property
    let result = sd29x9::max().sqrt();
    let r = result.unwrap() as u256;
    let max_scaled = (sd29x9::max().unwrap() as u256) * (SCALE as u256);
    assert!(r * r <= max_scaled);
    assert!((r + 1) * (r + 1) > max_scaled);
}

#[test]
fun sqrt_result_is_always_non_negative() {
    let values = vector[
        sd29x9::zero(),
        pos(SCALE),
        pos(2 * SCALE),
        pos(100 * SCALE),
        sd29x9::max(),
    ];
    values.destroy!(|x| {
        let result = x.sqrt();
        // Result is non-negative: raw bits should not have sign bit set
        assert!(result.unwrap() <= 0x7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF);
    });
}

#[test]
fun sqrt_squared_roundtrip_for_perfect_squares() {
    let values = vector[
        pos(4 * SCALE),
        pos(9 * SCALE),
        pos(25 * SCALE),
        pos(250_000_000), // 0.25
    ];
    values.destroy!(|x| {
        let root = x.sqrt();
        expect(root.mul(root), x);
    });
}

#[test, expected_failure(abort_code = sd29x9_base::ENegativeSqrt)]
fun sqrt_of_negative_aborts() {
    neg(SCALE).sqrt();
}

#[test, expected_failure(abort_code = sd29x9_base::ENegativeSqrt)]
fun sqrt_of_small_negative_aborts() {
    neg(1).sqrt();
}

#[test, expected_failure(abort_code = sd29x9_base::ENegativeSqrt)]
fun sqrt_of_min_value_aborts() {
    sd29x9::min().sqrt();
}

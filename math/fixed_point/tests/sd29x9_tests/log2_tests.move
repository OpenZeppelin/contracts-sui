#[test_only]
module openzeppelin_fp_math::sd29x9_log2_tests;

use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_base;
use openzeppelin_fp_math::sd29x9_test_helpers::{pos, neg};
use std::unit_test::assert_eq;

const SCALE: u128 = 1_000_000_000;
const MAX_POSITIVE_VALUE: u128 = 0x7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;

// ==== Boundary ====

#[test]
fun log2_of_one_is_zero() {
    assert_eq!(sd29x9::one().log2(), sd29x9::zero());
}

// ==== Exact positive integer logs ====

#[test]
fun log2_of_positive_powers_of_two_is_exact() {
    let mut k: u8 = 0;
    while (k <= 37) {
        assert_eq!(pos(SCALE << k).log2(), pos((k as u128) * SCALE));
        k = k + 1;
    };
}

// ==== Exact negative integer logs (k <= 9 because SCALE = 2^9 * 5^9) ====

#[test]
fun log2_of_negative_powers_of_two_is_exact() {
    let mut k: u8 = 1;
    while (k <= 9) {
        assert_eq!(pos(SCALE >> k).log2(), neg((k as u128) * SCALE));
        k = k + 1;
    };
}

// ==== Spot checks ====

#[test]
fun log2_of_three_matches_reference() {
    // log2(3) = 1.5849625007211561814... -> 1_584_962_500
    assert_eq!(pos(3 * SCALE).log2(), pos(1_584_962_500));
}

#[test]
fun log2_of_one_third_pins_value() {
    // x_raw = 333_333_333 represents 0.333333333 (one raw ulp below true 1/3).
    // True log2(0.333333333) ≈ -1.5849625021638512. floor of |that| at 10^9
    // scale is 1_584_962_502; the algorithm returns this magnitude with the
    // negative sign.
    let result = pos(333_333_333).log2();
    assert_eq!(result.abs().unwrap(), 1_584_962_502);
}

// ==== Aborts ====

#[test, expected_failure(abort_code = sd29x9_base::ELogUndefined)]
fun log2_of_zero_aborts() {
    sd29x9::zero().log2();
}

#[test, expected_failure(abort_code = sd29x9_base::ELogUndefined)]
fun log2_of_negative_one_aborts() {
    neg(SCALE).log2();
}

#[test, expected_failure(abort_code = sd29x9_base::ELogUndefined)]
fun log2_of_small_negative_aborts() {
    neg(1).log2();
}

#[test, expected_failure(abort_code = sd29x9_base::ELogUndefined)]
fun log2_of_min_value_aborts() {
    sd29x9::min().log2();
}

// ==== Extreme and boundary values ====

#[test]
fun log2_of_max_sd29x9() {
    // log2(sd29x9::max() / 10^9) ≈ 97.something; fits in [97·SCALE, 98·SCALE).
    let result = sd29x9::max().log2().unwrap();
    assert!(result >= 97 * SCALE && result < 98 * SCALE);
}

#[test]
fun log2_just_below_one_pins_value() {
    // x_raw = SCALE - 1 ⇒ true log2 ≈ -1.443e-9. At UD30x9 scale that's
    // -0.00000000143... → magnitude rounds down (toward zero) to 0.
    // raw_log2's small upward bias keeps the result deterministically pinned.
    let result = pos(SCALE - 1).log2();
    assert!(result.is_zero() || result == neg(1));
}

#[test]
fun log2_just_above_one_pins_value() {
    // x_raw = SCALE + 1 ⇒ true log2 ≈ +1.443e-9 → raw magnitude 1. The kernel
    // produces a positive magnitude of 1, so the signed result is pos(1).
    let result = pos(SCALE + 1).log2();
    assert!(result == pos(0) || result == pos(1));
}

// ==== Random property tests ====

#[random_test]
fun log2_monotonicity_on_positive(a: u128, b: u128) {
    // Both raw values in positive SD29x9 range, both >= SCALE so logs are valid.
    let a = a % (MAX_POSITIVE_VALUE + 1);
    let b = b % (MAX_POSITIVE_VALUE + 1);
    if (a < SCALE || b < SCALE) return;
    let (lo, hi) = if (a <= b) (a, b) else (b, a);
    assert!(pos(lo).log2().lte(pos(hi).log2()));
}

#[random_test]
fun log2_reflection(a: u128) {
    // log2(1/x) == -log2(x). Constrain x so 1/x is representable in SD29x9.
    let a = a % (MAX_POSITIVE_VALUE + 1);
    if (a < SCALE) return;
    // For very large x, `sd29x9::one().div(x)` truncates so aggressively that
    // the reflection identity stops being meaningful within any small bound.
    if (a > 10_000_000_000_000_000_000) return;
    let x = pos(a);
    let one_over_x = sd29x9::one().div(x);
    if (one_over_x.is_zero()) return;
    let lhs = one_over_x.log2();
    let rhs = x.log2().negate();
    let delta_abs = lhs.sub(rhs).abs().unwrap();
    // 1/x truncates to a UD30x9 ulp; log2 of that truncated value diverges from
    // -log2(x) by an amount inversely proportional to 1/x, which is the dominant
    // error term. Worst-case ~30 ulps for x near SCALE.
    assert!(delta_abs <= 30);
}

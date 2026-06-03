#[test_only]
module openzeppelin_fp_math::horner_tests;

use openzeppelin_fp_math::horner::{
    Self,
    SignedScaled256,
    horner_eval,
    mul_div_nearest_u256,
    signed_add,
    signed_add_coeff,
    signed_from_coeff,
    signed_from_unsigned,
    signed_mul_wad,
    signed_zero
};
use std::unit_test::assert_eq;

// === WAD-scale literals (10^18) ===

const WAD: u256 = 1_000_000_000_000_000_000;
const HALF_WAD: u256 = 500_000_000_000_000_000;
const QUARTER_WAD: u256 = 250_000_000_000_000_000;
const TWO_WAD: u256 = 2_000_000_000_000_000_000;
const THREE_WAD: u256 = 3_000_000_000_000_000_000;
const SEVENTEEN_WAD: u256 = 17_000_000_000_000_000_000;

// === Helpers ===

fun pos(mag: u256): SignedScaled256 { signed_from_unsigned(mag) }

// All test magnitudes fit u128, so signed values can be built directly via
// `signed_from_coeff`; zero is routed through `signed_zero()` to match the
// canonical encoding.
fun signed(mag: u256, neg: bool): SignedScaled256 {
    if (mag == 0) signed_zero() else signed_from_coeff(mag as u128, neg)
}

// === signed_zero / signed_from_* / accessors ===

#[test]
fun signed_zero_is_canonical() {
    let z = signed_zero();
    assert_eq!(horner::mag(&z), 0);
    assert_eq!(horner::is_neg(&z), false);
}

#[test]
fun signed_from_unsigned_is_positive() {
    let x = signed_from_unsigned(WAD);
    assert_eq!(horner::mag(&x), WAD);
    assert_eq!(horner::is_neg(&x), false);
}

#[test]
fun signed_from_coeff_canonicalizes_zero() {
    // Even with neg=true, magnitude=0 must canonicalize to (0, false).
    let x = signed_from_coeff(0, true);
    assert_eq!(horner::mag(&x), 0);
    assert_eq!(horner::is_neg(&x), false);
}

#[test]
fun signed_from_coeff_preserves_sign() {
    let x = signed_from_coeff(5_000_000_000_000_000_000, true);
    assert_eq!(horner::mag(&x), 5_000_000_000_000_000_000);
    assert_eq!(horner::is_neg(&x), true);
}

// === signed_add ===

#[test]
fun signed_add_zero_left() {
    let r = signed_add(signed_zero(), pos(WAD));
    assert_eq!(r, pos(WAD));
}

#[test]
fun signed_add_zero_right() {
    let r = signed_add(pos(WAD), signed_zero());
    assert_eq!(r, pos(WAD));
}

#[test]
fun signed_add_same_sign_positive() {
    // (3, +) + (5, +) = (8, +)
    let r = signed_add(pos(3), pos(5));
    assert_eq!(r, pos(8));
}

#[test]
fun signed_add_same_sign_negative() {
    // (3, -) + (5, -) = (8, -)
    let r = signed_add(signed(3, true), signed(5, true));
    assert_eq!(r, signed(8, true));
}

#[test]
fun signed_add_opposite_signs_a_smaller() {
    // (3, -) + (5, +) = (2, +)
    let r = signed_add(signed(3, true), pos(5));
    assert_eq!(r, pos(2));
}

#[test]
fun signed_add_opposite_signs_a_larger() {
    // (5, -) + (3, +) = (2, -)
    let r = signed_add(signed(5, true), pos(3));
    assert_eq!(r, signed(2, true));
}

#[test]
fun signed_add_exact_cancellation() {
    // (5, -) + (5, +) = canonical zero
    let r = signed_add(signed(5, true), pos(5));
    assert_eq!(r, signed_zero());
    assert_eq!(horner::is_neg(&r), false);
}

// === signed_add_coeff (folded cast + add used on the Horner hot loop) ===

#[test]
fun signed_add_coeff_matches_add_from_coeff() {
    // signed_add_coeff(acc, m, n) ≡ signed_add(acc, signed_from_coeff(m, n)).
    let acc = signed(THREE_WAD, false);
    let m: u128 = 5_000_000_000_000_000_000;
    assert_eq!(signed_add_coeff(acc, m, true), signed_add(acc, signed_from_coeff(m, true)));
    assert_eq!(signed_add_coeff(acc, m, false), signed_add(acc, signed_from_coeff(m, false)));
    // Opposite-sign with acc.mag > coeff.mag (subtract, keep acc's sign).
    let acc2 = signed(5_000_000_000_000_000_000, false); // 5.0
    let m2: u128 = 3_000_000_000_000_000_000; // 3.0
    assert_eq!(signed_add_coeff(acc2, m2, true), signed_add(acc2, signed_from_coeff(m2, true)));
}

#[test]
fun signed_add_coeff_zero_is_noop() {
    let acc = signed(THREE_WAD, true);
    assert_eq!(signed_add_coeff(acc, 0, true), acc);
    assert_eq!(signed_add_coeff(acc, 0, false), acc);
}

#[test]
fun signed_add_coeff_onto_zero_takes_coeff() {
    let r = signed_add_coeff(signed_zero(), 7, true);
    assert_eq!(r, signed(7, true));
}

#[test]
fun signed_add_coeff_exact_cancellation() {
    // (5, +) + coeff (5, -) = canonical zero
    let r = signed_add_coeff(pos(5), 5, true);
    assert_eq!(r, signed_zero());
    assert_eq!(horner::is_neg(&r), false);
}

// === signed_mul_wad ===

#[test]
fun signed_mul_wad_identity_positive() {
    // 1.0 × x = x  (positive x)
    let r = signed_mul_wad(pos(WAD), pos(THREE_WAD));
    assert_eq!(r, pos(THREE_WAD));
}

#[test]
fun signed_mul_wad_identity_negative() {
    // 1.0 × (-x) = (-x)
    let r = signed_mul_wad(pos(WAD), signed(THREE_WAD, true));
    assert_eq!(r, signed(THREE_WAD, true));
}

#[test]
fun signed_mul_wad_negate() {
    // (-1.0) × x = -x
    let r = signed_mul_wad(signed(WAD, true), pos(THREE_WAD));
    assert_eq!(r, signed(THREE_WAD, true));
}

#[test]
fun signed_mul_wad_half_squared() {
    // 0.5 × 0.5 = 0.25
    let r = signed_mul_wad(pos(HALF_WAD), pos(HALF_WAD));
    assert_eq!(r, pos(QUARTER_WAD));
}

#[test]
fun signed_mul_wad_neg_times_neg_is_pos() {
    // (-0.5) × (-0.5) = 0.25 (XOR signs)
    let r = signed_mul_wad(signed(HALF_WAD, true), signed(HALF_WAD, true));
    assert_eq!(r, pos(QUARTER_WAD));
}

#[test]
fun signed_mul_wad_with_zero_canonicalizes() {
    // 0 × x = canonical zero (regardless of x's sign)
    let r = signed_mul_wad(signed_zero(), signed(THREE_WAD, true));
    assert_eq!(r, signed_zero());
    assert_eq!(horner::is_neg(&r), false);
}

#[test]
fun signed_mul_wad_truncates_subwad_to_zero() {
    // (1, -) × (1, -) at WAD floors to 0 because 1 × 1 / 10^18 = 0.
    // Magnitude → 0 must canonicalize sign to false.
    let r = signed_mul_wad(signed(1, true), signed(1, true));
    assert_eq!(horner::mag(&r), 0);
    assert_eq!(horner::is_neg(&r), false);
}

// === mul_div_nearest_u256 (final WAD→10^9 ratio, half-up ties away from zero) ===

#[test]
fun mul_div_nearest_rounds_down_below_half() {
    // 1 / 4 = 0.25 → 0 (remainder 1 < d - remainder = 3).
    assert_eq!(mul_div_nearest_u256(1, 1, 4), 0);
}

#[test]
fun mul_div_nearest_rounds_up_on_tie() {
    // 1 / 2 = 0.5 and 3 / 2 = 1.5 are exact ties → round away from zero.
    assert_eq!(mul_div_nearest_u256(1, 1, 2), 1);
    assert_eq!(mul_div_nearest_u256(3, 1, 2), 2);
}

#[test]
fun mul_div_nearest_rounds_up_above_half() {
    // 7 / 4 = 1.75 → 2 (remainder 3 > d - remainder = 1).
    assert_eq!(mul_div_nearest_u256(7, 1, 4), 2);
}

#[test]
fun mul_div_nearest_exact_division_no_roundup() {
    // 12 / 3 = 4 exactly (remainder 0 never rounds up).
    assert_eq!(mul_div_nearest_u256(6, 2, 3), 4);
}

#[test]
fun mul_div_nearest_no_overflow_near_u256_max() {
    // Regression for the overflow-free rounding check: with `d` just above
    // 2^255 and remainder 2^255, the naive `rem × 2 ≥ d` test would overflow
    // u256. The `rem ≥ d - rem` form returns the correct rounded-up result.
    let two_255 = 1u256 << 255;
    assert_eq!(mul_div_nearest_u256(two_255, 1, two_255 + 1), 1);
}

#[test, expected_failure(arithmetic_error, location = openzeppelin_fp_math::horner)]
fun mul_div_nearest_aborts_on_zero_divisor() {
    // d == 0 → native division-by-zero abort.
    let _ = mul_div_nearest_u256(1, 1, 0);
}

// === horner_eval! ===

#[test]
fun horner_eval_quadratic_positive() {
    // p(x) = 3x² + 2x + 1, evaluated at x=2 should give 17.
    let mags = vector[WAD, TWO_WAD, THREE_WAD];
    let negs = vector[false, false, false];
    let z = pos(TWO_WAD);
    let r = horner_eval!(z, mags.length(), |i| (mags[i] as u128, negs[i]));
    assert_eq!(r, pos(SEVENTEEN_WAD));
}

#[test]
fun horner_eval_linear_negative_result() {
    // p(x) = 1 - x, evaluated at x=2 should give -1.
    let mags = vector[WAD, WAD];
    let negs = vector[false, true];
    let z = pos(TWO_WAD);
    let r = horner_eval!(z, mags.length(), |i| (mags[i] as u128, negs[i]));
    assert_eq!(r, signed(WAD, true));
}

#[test]
fun horner_eval_constant_polynomial() {
    // p(x) = 5, single coefficient — value is 5 regardless of x.
    let mags = vector[5 * WAD];
    let negs = vector[false];
    let z = pos(TWO_WAD); // arbitrary z
    let r = horner_eval!(z, mags.length(), |i| (mags[i] as u128, negs[i]));
    assert_eq!(r, pos(5 * WAD));
}

#[test]
fun horner_eval_zero_polynomial_canonicalizes() {
    // p(x) = 0 (single zero coefficient) → canonical zero regardless of input.
    let mags = vector[0u256];
    let negs = vector[false];
    let z = pos(TWO_WAD);
    let r = horner_eval!(z, mags.length(), |i| (mags[i] as u128, negs[i]));
    assert_eq!(r, signed_zero());
    assert_eq!(horner::is_neg(&r), false);
}

#[test, expected_failure(abort_code = horner::EEmptyPolynomial)]
fun horner_eval_aborts_on_empty_polynomial() {
    // Empty polynomial must abort, not silently return zero.
    let mags = vector<u256>[];
    let negs = vector<bool>[];
    let z = pos(TWO_WAD);
    let _ = horner_eval!(z, mags.length(), |i| (mags[i] as u128, negs[i]));
}

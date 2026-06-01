#[test_only]
module openzeppelin_fp_math::horner_tests;

use openzeppelin_fp_math::gaussian::{
    Self,
    SignedScaled256,
    horner_eval,
    signed_add,
    signed_from_coeff,
    signed_from_unsigned,
    signed_mul_wad,
    signed_zero,
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

fun signed(mag: u256, neg: bool): SignedScaled256 {
    if (mag == 0) signed_zero() else signed_from_coeff_u256(mag, neg)
}

// `signed_from_coeff` only accepts u128; we synthesize a u256-backed value via
// the same canonicalization path for tests that need full-range magnitudes.
fun signed_from_coeff_u256(mag: u256, neg: bool): SignedScaled256 {
    if (mag <= (std::u128::max_value!() as u256)) {
        signed_from_coeff(mag as u128, neg)
    } else {
        // Test cases never need this branch on the central domain, but keep it
        // total in case a future test uses it.
        abort 0
    }
}

// === signed_zero / signed_from_* / accessors ===

#[test]
fun test_signed_zero_is_canonical() {
    let z = signed_zero();
    assert_eq!(gaussian::mag(&z), 0);
    assert_eq!(gaussian::is_neg(&z), false);
}

#[test]
fun test_signed_from_unsigned() {
    let x = signed_from_unsigned(WAD);
    assert_eq!(gaussian::mag(&x), WAD);
    assert_eq!(gaussian::is_neg(&x), false);
}

#[test]
fun test_signed_from_coeff_canonicalizes_zero() {
    // Even with neg=true, magnitude=0 must canonicalize to (0, false).
    let x = signed_from_coeff(0, true);
    assert_eq!(gaussian::mag(&x), 0);
    assert_eq!(gaussian::is_neg(&x), false);
}

#[test]
fun test_signed_from_coeff_preserves_sign() {
    let x = signed_from_coeff(5_000_000_000_000_000_000, true);
    assert_eq!(gaussian::mag(&x), 5_000_000_000_000_000_000);
    assert_eq!(gaussian::is_neg(&x), true);
}

// === signed_add ===

#[test]
fun test_signed_add_zero_left() {
    let r = signed_add(signed_zero(), pos(WAD));
    assert_eq!(r, pos(WAD));
}

#[test]
fun test_signed_add_zero_right() {
    let r = signed_add(pos(WAD), signed_zero());
    assert_eq!(r, pos(WAD));
}

#[test]
fun test_signed_add_same_sign_positive() {
    // (3, +) + (5, +) = (8, +)
    let r = signed_add(pos(3), pos(5));
    assert_eq!(r, pos(8));
}

#[test]
fun test_signed_add_same_sign_negative() {
    // (3, -) + (5, -) = (8, -)
    let r = signed_add(signed(3, true), signed(5, true));
    assert_eq!(r, signed(8, true));
}

#[test]
fun test_signed_add_opposite_signs_a_smaller() {
    // (3, -) + (5, +) = (2, +)
    let r = signed_add(signed(3, true), pos(5));
    assert_eq!(r, pos(2));
}

#[test]
fun test_signed_add_opposite_signs_a_larger() {
    // (5, -) + (3, +) = (2, -)
    let r = signed_add(signed(5, true), pos(3));
    assert_eq!(r, signed(2, true));
}

#[test]
fun test_signed_add_exact_cancellation() {
    // (5, -) + (5, +) = canonical zero
    let r = signed_add(signed(5, true), pos(5));
    assert_eq!(r, signed_zero());
    assert_eq!(gaussian::is_neg(&r), false);
}

// === signed_mul_wad ===

#[test]
fun test_signed_mul_wad_identity_positive() {
    // 1.0 × x = x  (positive x)
    let r = signed_mul_wad(pos(WAD), pos(THREE_WAD));
    assert_eq!(r, pos(THREE_WAD));
}

#[test]
fun test_signed_mul_wad_identity_negative() {
    // 1.0 × (-x) = (-x)
    let r = signed_mul_wad(pos(WAD), signed(THREE_WAD, true));
    assert_eq!(r, signed(THREE_WAD, true));
}

#[test]
fun test_signed_mul_wad_negate() {
    // (-1.0) × x = -x
    let r = signed_mul_wad(signed(WAD, true), pos(THREE_WAD));
    assert_eq!(r, signed(THREE_WAD, true));
}

#[test]
fun test_signed_mul_wad_half_squared() {
    // 0.5 × 0.5 = 0.25
    let r = signed_mul_wad(pos(HALF_WAD), pos(HALF_WAD));
    assert_eq!(r, pos(QUARTER_WAD));
}

#[test]
fun test_signed_mul_wad_neg_times_neg_is_pos() {
    // (-0.5) × (-0.5) = 0.25 (XOR signs)
    let r = signed_mul_wad(signed(HALF_WAD, true), signed(HALF_WAD, true));
    assert_eq!(r, pos(QUARTER_WAD));
}

#[test]
fun test_signed_mul_wad_with_zero_canonicalizes() {
    // 0 × x = canonical zero (regardless of x's sign)
    let r = signed_mul_wad(signed_zero(), signed(THREE_WAD, true));
    assert_eq!(r, signed_zero());
    assert_eq!(gaussian::is_neg(&r), false);
}

#[test]
fun test_signed_mul_wad_truncates_subwad_to_zero() {
    // (1, -) × (1, -) at WAD floors to 0 because 1 × 1 / 10^18 = 0.
    // Magnitude → 0 must canonicalize sign to false.
    let r = signed_mul_wad(signed(1, true), signed(1, true));
    assert_eq!(gaussian::mag(&r), 0);
    assert_eq!(gaussian::is_neg(&r), false);
}

// === horner_eval! ===

#[test]
fun test_horner_eval_quadratic_positive() {
    // p(x) = 3x² + 2x + 1, evaluated at x=2 should give 17.
    let mags = vector[WAD, TWO_WAD, THREE_WAD];
    let negs = vector[false, false, false];
    let z = pos(TWO_WAD);
    let r = horner_eval!(z, mags.length(), |i| (mags[i] as u128, negs[i]));
    assert_eq!(r, pos(SEVENTEEN_WAD));
}

#[test]
fun test_horner_eval_linear_negative_result() {
    // p(x) = 1 - x, evaluated at x=2 should give -1.
    let mags = vector[WAD, WAD];
    let negs = vector[false, true];
    let z = pos(TWO_WAD);
    let r = horner_eval!(z, mags.length(), |i| (mags[i] as u128, negs[i]));
    assert_eq!(r, signed(WAD, true));
}

#[test]
fun test_horner_eval_constant_polynomial() {
    // p(x) = 5, single coefficient — value is 5 regardless of x.
    let mags = vector[5 * WAD];
    let negs = vector[false];
    let z = pos(TWO_WAD); // arbitrary z
    let r = horner_eval!(z, mags.length(), |i| (mags[i] as u128, negs[i]));
    assert_eq!(r, pos(5 * WAD));
}

#[test]
fun test_horner_eval_zero_polynomial_canonicalizes() {
    // p(x) = 0 (single zero coefficient) → canonical zero regardless of input.
    let mags = vector[0u256];
    let negs = vector[false];
    let z = pos(TWO_WAD);
    let r = horner_eval!(z, mags.length(), |i| (mags[i] as u128, negs[i]));
    assert_eq!(r, signed_zero());
    assert_eq!(gaussian::is_neg(&r), false);
}

#[test, expected_failure(abort_code = gaussian::EEmptyPolynomial)]
fun test_horner_eval_aborts_on_empty_polynomial() {
    // INV-6: empty polynomial must abort, not silently return zero.
    let mags = vector<u256>[];
    let negs = vector<bool>[];
    let z = pos(TWO_WAD);
    let _ = horner_eval!(z, mags.length(), |i| (mags[i] as u128, negs[i]));
}

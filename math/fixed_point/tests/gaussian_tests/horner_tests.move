#[test_only]
module openzeppelin_fp_math::horner_tests;

use openzeppelin_fp_math::horner::{
    Self,
    SignedScaled256,
    add,
    add_coeff,
    from_coeff,
    from_unsigned,
    horner_eval,
    mul_wad,
    zero
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

fun pos(mag: u256): SignedScaled256 { from_unsigned(mag) }

// All test magnitudes fit u128, so signed values can be built directly via
// `from_coeff`; zero is routed through `zero()` to match the canonical
// encoding.
fun signed(mag: u256, neg: bool): SignedScaled256 {
    if (mag == 0) zero() else from_coeff(mag as u128, neg)
}

// === zero / from_* / accessors ===

#[test]
fun zero_is_canonical() {
    let z = zero();
    assert_eq!(horner::mag(&z), 0);
    assert_eq!(horner::is_neg(&z), false);
}

#[test]
fun from_unsigned_is_positive() {
    let x = from_unsigned(WAD);
    assert_eq!(horner::mag(&x), WAD);
    assert_eq!(horner::is_neg(&x), false);
}

#[test]
fun from_coeff_canonicalizes_zero() {
    // Even with neg=true, magnitude=0 must canonicalize to (0, false).
    let x = from_coeff(0, true);
    assert_eq!(horner::mag(&x), 0);
    assert_eq!(horner::is_neg(&x), false);
}

#[test]
fun from_coeff_preserves_sign() {
    let x = from_coeff(5_000_000_000_000_000_000, true);
    assert_eq!(horner::mag(&x), 5_000_000_000_000_000_000);
    assert_eq!(horner::is_neg(&x), true);
}

// === add ===

#[test]
fun add_zero_left() {
    let r = add(zero(), pos(WAD));
    assert_eq!(r, pos(WAD));
}

#[test]
fun add_zero_right() {
    let r = add(pos(WAD), zero());
    assert_eq!(r, pos(WAD));
}

#[test]
fun add_same_sign_positive() {
    // (3, +) + (5, +) = (8, +)
    let r = add(pos(3), pos(5));
    assert_eq!(r, pos(8));
}

#[test]
fun add_same_sign_negative() {
    // (3, -) + (5, -) = (8, -)
    let r = add(signed(3, true), signed(5, true));
    assert_eq!(r, signed(8, true));
}

#[test]
fun add_opposite_signs_a_smaller() {
    // (3, -) + (5, +) = (2, +)
    let r = add(signed(3, true), pos(5));
    assert_eq!(r, pos(2));
    // Mirror combo: (3, +) + (5, -) = (2, -) - result must take b's actual sign.
    assert_eq!(add(pos(3), signed(5, true)), signed(2, true));
}

#[test]
fun add_opposite_signs_a_larger() {
    // (5, -) + (3, +) = (2, -)
    let r = add(signed(5, true), pos(3));
    assert_eq!(r, signed(2, true));
    // Mirror combo: (5, +) + (3, -) = (2, +) - result must keep a's actual sign.
    assert_eq!(add(pos(5), signed(3, true)), pos(2));
}

#[test]
fun add_exact_cancellation() {
    // (5, -) + (5, +) = canonical zero
    let r = add(signed(5, true), pos(5));
    assert_eq!(r, zero());
    assert_eq!(horner::is_neg(&r), false);
}

// === add_coeff (folded cast + add used on the Horner hot loop) ===

#[test]
fun add_coeff_matches_add_from_coeff() {
    // add_coeff(acc, m, n) ≡ add(acc, from_coeff(m, n)).
    let acc = signed(THREE_WAD, false);
    let m: u128 = 5_000_000_000_000_000_000;
    assert_eq!(add_coeff(acc, m, true), add(acc, from_coeff(m, true)));
    assert_eq!(add_coeff(acc, m, false), add(acc, from_coeff(m, false)));
    // Opposite-sign with acc.mag > coeff.mag (subtract, keep acc's sign).
    let acc2 = signed(5_000_000_000_000_000_000, false); // 5.0
    let m2: u128 = 3_000_000_000_000_000_000; // 3.0
    assert_eq!(add_coeff(acc2, m2, true), add(acc2, from_coeff(m2, true)));
}

#[test]
fun add_coeff_zero_is_noop() {
    let acc = signed(THREE_WAD, true);
    assert_eq!(add_coeff(acc, 0, true), acc);
    assert_eq!(add_coeff(acc, 0, false), acc);
}

#[test]
fun add_coeff_onto_zero_takes_coeff() {
    let r = add_coeff(zero(), 7, true);
    assert_eq!(r, signed(7, true));
}

#[test]
fun add_coeff_exact_cancellation() {
    // (5, +) + coeff (5, -) = canonical zero
    let r = add_coeff(pos(5), 5, true);
    assert_eq!(r, zero());
    assert_eq!(horner::is_neg(&r), false);
}

// === mul_wad ===

#[test]
fun mul_wad_identity_positive() {
    // 1.0 × x = x  (positive x)
    let r = mul_wad(pos(WAD), pos(THREE_WAD));
    assert_eq!(r, pos(THREE_WAD));
}

#[test]
fun mul_wad_identity_negative() {
    // 1.0 × (-x) = (-x)
    let r = mul_wad(pos(WAD), signed(THREE_WAD, true));
    assert_eq!(r, signed(THREE_WAD, true));
}

#[test]
fun mul_wad_negate() {
    // (-1.0) × x = -x
    let r = mul_wad(signed(WAD, true), pos(THREE_WAD));
    assert_eq!(r, signed(THREE_WAD, true));
}

#[test]
fun mul_wad_half_squared() {
    // 0.5 × 0.5 = 0.25
    let r = mul_wad(pos(HALF_WAD), pos(HALF_WAD));
    assert_eq!(r, pos(QUARTER_WAD));
}

#[test]
fun mul_wad_neg_times_neg_is_pos() {
    // (-0.5) × (-0.5) = 0.25 (XOR signs)
    let r = mul_wad(signed(HALF_WAD, true), signed(HALF_WAD, true));
    assert_eq!(r, pos(QUARTER_WAD));
}

#[test]
fun mul_wad_with_zero_canonicalizes() {
    // 0 × x = canonical zero (regardless of x's sign)
    let r = mul_wad(zero(), signed(THREE_WAD, true));
    assert_eq!(r, zero());
    assert_eq!(horner::is_neg(&r), false);
}

#[test]
fun mul_wad_truncates_subwad_to_zero() {
    // (1, -) × (1, -) at WAD floors to 0 because 1 × 1 / 10^18 = 0.
    // Magnitude → 0 must canonicalize sign to false.
    let r = mul_wad(signed(1, true), signed(1, true));
    assert_eq!(horner::mag(&r), 0);
    assert_eq!(horner::is_neg(&r), false);
}

#[test]
fun mul_wad_truncates_remainder_toward_zero() {
    // 3 × (0.5 WAD + 1 wei) = 1.5e18 + 3 → floors to 1 wei; round-nearest would give 2.
    let b = signed(500_000_000_000_000_001, false);
    assert_eq!(mul_wad(signed(3, false), b), pos(1));
    // Same on the negative side: truncation is toward zero, not toward -infinity.
    assert_eq!(mul_wad(signed(3, true), b), signed(1, true));
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
    // p(x) = 5, single coefficient - value is 5 regardless of x.
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
    assert_eq!(r, zero());
    assert_eq!(horner::is_neg(&r), false);
}

#[test]
fun horner_eval_invokes_accessor_once_per_coefficient() {
    // Doc contract: $coeff_at runs exactly once per coefficient.
    let mags = vector[WAD, TWO_WAD, THREE_WAD];
    let negs = vector[false, false, false];
    let mut calls = 0u64;
    let r = horner_eval!(pos(TWO_WAD), mags.length(), |i| {
        calls = calls + 1;
        (mags[i] as u128, negs[i])
    });
    assert_eq!(r, pos(SEVENTEEN_WAD));
    assert_eq!(calls, 3);
}

#[test, expected_failure(abort_code = horner::EEmptyPolynomial)]
fun horner_eval_aborts_on_empty_polynomial() {
    // Empty polynomial must abort, not silently return zero.
    let mags = vector<u256>[];
    let negs = vector<bool>[];
    let z = pos(TWO_WAD);
    let _ = horner_eval!(z, mags.length(), |i| (mags[i] as u128, negs[i]));
}

module openzeppelin_fp_math::horner_tests;

use openzeppelin_fp_math::horner::{
    Self,
    SignedScaled256,
    from_coeff,
    from_unsigned,
    horner_eval,
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
    assert_eq!(z.mag(), 0);
    assert_eq!(z.is_neg(), false);
}

#[test]
fun from_unsigned_is_positive() {
    let x = from_unsigned(WAD);
    assert_eq!(x.mag(), WAD);
    assert_eq!(x.is_neg(), false);
}

#[test]
fun from_coeff_canonicalizes_zero() {
    // Even with neg=true, magnitude=0 must canonicalize to (0, false).
    let x = from_coeff(0, true);
    assert_eq!(x.mag(), 0);
    assert_eq!(x.is_neg(), false);
}

#[test]
fun from_coeff_preserves_sign() {
    let x = from_coeff(5_000_000_000_000_000_000, true);
    assert_eq!(x.mag(), 5_000_000_000_000_000_000);
    assert_eq!(x.is_neg(), true);
}

// === add ===

#[test]
fun add_zero_left() {
    let r = zero().add(pos(WAD));
    assert_eq!(r, pos(WAD));
}

#[test]
fun add_zero_right() {
    let r = pos(WAD).add(zero());
    assert_eq!(r, pos(WAD));
}

#[test]
fun add_same_sign_positive() {
    // (3, +) + (5, +) = (8, +)
    let r = pos(3).add(pos(5));
    assert_eq!(r, pos(8));
}

#[test]
fun add_same_sign_negative() {
    // (3, -) + (5, -) = (8, -)
    let r = signed(3, true).add(signed(5, true));
    assert_eq!(r, signed(8, true));
}

#[test]
fun add_opposite_signs_a_smaller() {
    // (3, -) + (5, +) = (2, +)
    let r = signed(3, true).add(pos(5));
    assert_eq!(r, pos(2));
    // Mirror combo: (3, +) + (5, -) = (2, -) - result must take b's actual sign.
    assert_eq!(pos(3).add(signed(5, true)), signed(2, true));
}

#[test]
fun add_opposite_signs_a_larger() {
    // (5, -) + (3, +) = (2, -)
    let r = signed(5, true).add(pos(3));
    assert_eq!(r, signed(2, true));
    // Mirror combo: (5, +) + (3, -) = (2, +) - result must keep a's actual sign.
    assert_eq!(pos(5).add(signed(3, true)), pos(2));
}

#[test]
fun add_exact_cancellation() {
    // (5, -) + (5, +) = canonical zero
    let r = signed(5, true).add(pos(5));
    assert_eq!(r, zero());
    assert_eq!(r.is_neg(), false);
}

// === add_coeff (folded cast + add used on the Horner hot loop) ===

#[test]
fun add_coeff_matches_add_from_coeff() {
    // add_coeff(acc, m, n) ≡ add(acc, from_coeff(m, n)).
    let acc = signed(THREE_WAD, false);
    let m: u128 = 5_000_000_000_000_000_000;
    assert_eq!(acc.add_coeff(m, true), acc.add(from_coeff(m, true)));
    assert_eq!(acc.add_coeff(m, false), acc.add(from_coeff(m, false)));
    // Opposite-sign with acc.mag > coeff.mag (subtract, keep acc's sign).
    let acc2 = signed(5_000_000_000_000_000_000, false); // 5.0
    let m2: u128 = 3_000_000_000_000_000_000; // 3.0
    assert_eq!(acc2.add_coeff(m2, true), acc2.add(from_coeff(m2, true)));
}

#[test]
fun add_coeff_zero_is_noop() {
    let acc = signed(THREE_WAD, true);
    assert_eq!(acc.add_coeff(0, true), acc);
    assert_eq!(acc.add_coeff(0, false), acc);
}

#[test]
fun add_coeff_onto_zero_takes_coeff() {
    let r = zero().add_coeff(7, true);
    assert_eq!(r, signed(7, true));
}

#[test]
fun add_coeff_exact_cancellation() {
    // (5, +) + coeff (5, -) = canonical zero
    let r = pos(5).add_coeff(5, true);
    assert_eq!(r, zero());
    assert_eq!(r.is_neg(), false);
}

// === mul_wad ===

#[test]
fun mul_wad_identity_positive() {
    // 1.0 × x = x  (positive x)
    let r = pos(WAD).mul_wad(pos(THREE_WAD), WAD);
    assert_eq!(r, pos(THREE_WAD));
}

#[test]
fun mul_wad_identity_negative() {
    // 1.0 × (-x) = (-x)
    let r = pos(WAD).mul_wad(signed(THREE_WAD, true), WAD);
    assert_eq!(r, signed(THREE_WAD, true));
}

#[test]
fun mul_wad_negate() {
    // (-1.0) × x = -x
    let r = signed(WAD, true).mul_wad(pos(THREE_WAD), WAD);
    assert_eq!(r, signed(THREE_WAD, true));
}

#[test]
fun mul_wad_half_squared() {
    // 0.5 × 0.5 = 0.25
    let r = pos(HALF_WAD).mul_wad(pos(HALF_WAD), WAD);
    assert_eq!(r, pos(QUARTER_WAD));
}

#[test]
fun mul_wad_neg_times_neg_is_pos() {
    // (-0.5) × (-0.5) = 0.25 (XOR signs)
    let r = signed(HALF_WAD, true).mul_wad(signed(HALF_WAD, true), WAD);
    assert_eq!(r, pos(QUARTER_WAD));
}

#[test]
fun mul_wad_with_zero_canonicalizes() {
    // 0 × x = canonical zero (regardless of x's sign)
    let r = zero().mul_wad(signed(THREE_WAD, true), WAD);
    assert_eq!(r, zero());
    assert_eq!(r.is_neg(), false);
}

#[test]
fun mul_wad_truncates_subwad_to_zero() {
    // (1, -) × (1, -) at WAD floors to 0 because 1 × 1 / 10^18 = 0.
    // Magnitude → 0 must canonicalize sign to false.
    let r = signed(1, true).mul_wad(signed(1, true), WAD);
    assert_eq!(r.mag(), 0);
    assert_eq!(r.is_neg(), false);
}

#[test]
fun mul_wad_truncates_remainder_toward_zero() {
    // 3 × (0.5 WAD + 1 wei) = 1.5e18 + 3 → floors to 1 wei; round-nearest would give 2.
    let b = signed(500_000_000_000_000_001, false);
    assert_eq!(signed(3, false).mul_wad(b, WAD), pos(1));
    // Same on the negative side: truncation is toward zero, not toward -infinity.
    assert_eq!(signed(3, true).mul_wad(b, WAD), signed(1, true));
}

#[test]
fun mul_wad_respects_scale_argument() {
    // The divisor scale is a per-call argument. Same operands, finer scale ->
    // smaller magnitude: (1e18 · 1e18) / 1e18 = 1e18, but / 1e36 = 1.
    let one = pos(WAD);
    let scale36: u256 = 1_000_000_000_000_000_000_000_000_000_000_000_000; // 10^36
    assert_eq!(one.mul_wad(one, WAD), pos(WAD));
    assert_eq!(one.mul_wad(one, scale36).mag(), 1);
}

// === horner_eval! ===

#[test]
fun horner_eval_quadratic_positive() {
    // p(x) = 3x² + 2x + 1, evaluated at x=2 should give 17.
    let mags = vector[WAD, TWO_WAD, THREE_WAD];
    let negs = vector[false, false, false];
    let z = pos(TWO_WAD);
    let r = horner_eval!(z, mags.length(), |i| (mags[i] as u128, negs[i]), WAD);
    assert_eq!(r, pos(SEVENTEEN_WAD));
}

#[test]
fun horner_eval_linear_negative_result() {
    // p(x) = 1 - x, evaluated at x=2 should give -1.
    let mags = vector[WAD, WAD];
    let negs = vector[false, true];
    let z = pos(TWO_WAD);
    let r = horner_eval!(z, mags.length(), |i| (mags[i] as u128, negs[i]), WAD);
    assert_eq!(r, signed(WAD, true));
}

#[test]
fun horner_eval_constant_polynomial() {
    // p(x) = 5, single coefficient - value is 5 regardless of x.
    let mags = vector[5 * WAD];
    let negs = vector[false];
    let z = pos(TWO_WAD); // arbitrary z
    let r = horner_eval!(z, mags.length(), |i| (mags[i] as u128, negs[i]), WAD);
    assert_eq!(r, pos(5 * WAD));
}

#[test]
fun horner_eval_zero_polynomial_canonicalizes() {
    // p(x) = 0 (single zero coefficient) → canonical zero regardless of input.
    let mags = vector[0u256];
    let negs = vector[false];
    let z = pos(TWO_WAD);
    let r = horner_eval!(z, mags.length(), |i| (mags[i] as u128, negs[i]), WAD);
    assert_eq!(r, zero());
    assert_eq!(r.is_neg(), false);
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
    }, WAD);
    assert_eq!(r, pos(SEVENTEEN_WAD));
    assert_eq!(calls, 3);
}

#[test, expected_failure(abort_code = horner::EEmptyPolynomial)]
fun horner_eval_aborts_on_empty_polynomial() {
    // Empty polynomial must abort, not silently return zero.
    let mags = vector<u256>[];
    let negs = vector<bool>[];
    let z = pos(TWO_WAD);
    let _ = horner_eval!(z, mags.length(), |i| (mags[i] as u128, negs[i]), WAD);
}

module openzeppelin_fp_math::sd29x9_pdf_tests;

use openzeppelin_fp_math::pdf;
use openzeppelin_fp_math::pdf_coefficients;
use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_base;
use openzeppelin_fp_math::sd29x9_test_helpers::{assert_within, neg, pos};
use std::unit_test::assert_eq;

// === Constants ===

const SCALE: u128 = 1_000_000_000; // SD29x9 raw scale (10^9)
const MAX_Z_RAW: u128 = 6_402_729_806; // 6.402729806 at SD29x9 scale
const ONE_WAD: u128 = 1_000_000_000_000_000_000_000_000_000_000_000_000; // 1.0 at WAD scale (10^36, coefficient injection)

// 5 ULP at the SD29x9 scale (≡ 5 × 10^-9 absolute), per the accuracy contract.
const TOLERANCE: u128 = 5;

// Reference φ values at the SD29x9 raw scale (rounded from scipy/mpmath at 100
// dps). φ is even, so φ(-z) = φ(z). The peak φ(0) is returned bit-exactly.
const PDF_0_RAW: u128 = 398_942_280;
const PDF_1_RAW: u128 = 241_970_725;
const PDF_2_RAW: u128 = 53_990_967;
const PDF_3_RAW: u128 = 4_431_848;

// === Bit-exact / well-known points ===

#[test]
fun pdf_zero_is_peak() {
    // With D(0) = 1 the rational returns the exact peak; no z = 0 special case.
    assert_eq!(sd29x9::zero().pdf().unwrap(), PDF_0_RAW);
}

#[test]
fun pdf_one_well_known() {
    assert_within(pos(SCALE).pdf().unwrap(), PDF_1_RAW, TOLERANCE);
}

#[test]
fun pdf_two_well_known() {
    assert_within(pos(2 * SCALE).pdf().unwrap(), PDF_2_RAW, TOLERANCE);
}

#[test]
fun pdf_three_well_known() {
    assert_within(pos(3 * SCALE).pdf().unwrap(), PDF_3_RAW, TOLERANCE);
}

// φ is even: negative inputs return the same density as their positive mirror.

#[test]
fun pdf_minus_one_equals_pdf_one() {
    assert_within(neg(SCALE).pdf().unwrap(), PDF_1_RAW, TOLERANCE);
}

#[test]
fun pdf_minus_two_equals_pdf_two() {
    assert_within(neg(2 * SCALE).pdf().unwrap(), PDF_2_RAW, TOLERANCE);
}

#[test]
fun pdf_minus_three_equals_pdf_three() {
    assert_within(neg(3 * SCALE).pdf().unwrap(), PDF_3_RAW, TOLERANCE);
}

// === Saturation ===

#[test]
fun saturation_above_max_z() {
    assert_eq!(pos(MAX_Z_RAW).pdf().unwrap(), 0);
    assert_eq!(pos(MAX_Z_RAW + 1).pdf().unwrap(), 0);
    assert_eq!(pos(7 * SCALE).pdf().unwrap(), 0);
}

#[test]
fun saturation_below_min_z() {
    assert_eq!(neg(MAX_Z_RAW).pdf().unwrap(), 0);
    assert_eq!(neg(MAX_Z_RAW + 1).pdf().unwrap(), 0);
    assert_eq!(neg(7 * SCALE).pdf().unwrap(), 0);
}

#[test]
fun saturation_at_sd29x9_extremes() {
    // sd29x9::max() and sd29x9::min() are far above the saturation threshold;
    // both must clamp to 0 without going through the rational path.
    assert_eq!(sd29x9::max().pdf().unwrap(), 0);
    assert_eq!(sd29x9::min().pdf().unwrap(), 0);
}

#[test]
fun max_z_raw_is_analytical_saturation_point() {
    // Pin the saturation domain bound to 6.402729806 - the smallest z whose φ
    // rounds to 0 at the 10^9 scale. Moving the domain would slip past the
    // behavioral saturation tests and the Python sweep, but is caught here.
    assert_eq!(pdf_coefficients::max_z_raw(), MAX_Z_RAW);
}

// === Output range ===

#[test]
fun output_range_bounded_by_peak() {
    // Sweep a 64-point grid spanning [-7, 7] (both saturation regions and the
    // central domain) and confirm every output stays in [0, PDF_0_RAW].
    let n: u64 = 64;
    let step = 14 * SCALE / ((n - 1) as u128);
    n.do!(|i| {
        let offset = (i as u128) * step;
        let z = if (offset < 7 * SCALE) {
            neg(7 * SCALE - offset)
        } else {
            pos(offset - 7 * SCALE)
        };
        let v = z.pdf().unwrap();
        assert!(v <= PDF_0_RAW);
    });
}

// === Monotonicity (in |z|) ===

#[test]
fun monotonic_decreasing_in_magnitude() {
    // φ is unimodal with its peak at 0; on the non-negative half it is
    // non-increasing. Sweep magnitudes across [0, 6.402729806].
    let n: u64 = 64;
    let step = MAX_Z_RAW / ((n - 1) as u128);
    let mut prev: u128 = PDF_0_RAW; // φ at |z| = 0 is the peak
    n.do!(|i| {
        let curr = pos((i as u128) * step).pdf().unwrap();
        assert!(curr <= prev);
        prev = curr;
    });
}

// === Symmetry (even function) ===

#[test]
fun symmetry_on_well_known_points() {
    // φ(z) = φ(-z) bit-exactly: both calls evaluate the same |z| magnitude.
    let probes: vector<u128> = vector[
        0,
        100_000_000,
        500_000_000,
        SCALE,
        2 * SCALE,
        3 * SCALE,
        5 * SCALE,
        6 * SCALE,
        MAX_Z_RAW,
        7 * SCALE,
    ];
    probes.destroy!(|raw| {
        assert_eq!(pos(raw).pdf().unwrap(), neg(raw).pdf().unwrap());
    });
}

#[random_test]
fun pdf_is_even(raw: u128) {
    // φ(z) = φ(-z) for every input. Bound the magnitude into the valid signed
    // range (well within 2^127), covering both the central domain and the tail.
    let mag = raw % (7 * SCALE);
    assert_eq!(pos(mag).pdf().unwrap(), neg(mag).pdf().unwrap());
}

// === Determinism ===

#[test]
fun pdf_is_deterministic() {
    let z = pos(SCALE);
    let a = z.pdf().unwrap();
    let b = z.pdf().unwrap();
    let c = z.pdf().unwrap();
    assert_eq!(a, b);
    assert_eq!(b, c);
}

#[test]
fun coefficient_arrays_have_matching_lengths() {
    // The Horner loop iterates by the mags-vector length and indexes the
    // parallel negs vector, so the two must stay the same length.
    assert_eq!(
        pdf_coefficients::pdf_num_mags().length(),
        pdf_coefficients::pdf_num_negs().length(),
    );
    assert_eq!(
        pdf_coefficients::pdf_den_mags().length(),
        pdf_coefficients::pdf_den_negs().length(),
    );
}

// === Integrity asserts (defense-in-depth; unreachable via the public API) ===

#[test, expected_failure(abort_code = pdf::EInternalNumNegative)]
fun numerator_negative_aborts() {
    // A constant numerator of -1.0 forces N(z) < 0 on the central domain.
    let _ = pdf::eval_rational_for_test(
        SCALE, // z = 1.0, inside [0, 6.402729806)
        vector[ONE_WAD],
        vector[true],
        vector[ONE_WAD],
        vector[false],
    );
}

#[test, expected_failure(abort_code = pdf::EInternalDenNonPositive)]
fun denominator_nonpositive_aborts() {
    // A constant denominator of -1.0 forces D(z) < 0 on the central domain.
    let _ = pdf::eval_rational_for_test(
        SCALE,
        vector[ONE_WAD],
        vector[false],
        vector[ONE_WAD],
        vector[true],
    );
}

#[test, expected_failure(abort_code = pdf::EInternalDenNonPositive)]
fun denominator_zero_aborts() {
    // A constant denominator of 0 evaluates to canonical zero, which must trip
    // the `mag(d) > 0` half of the guard rather than reach the division.
    let _ = pdf::eval_rational_for_test(
        SCALE,
        vector[ONE_WAD],
        vector[false],
        vector[0],
        vector[false],
    );
}

#[test]
fun numerator_zero_passes_guard_returns_zero() {
    // N(z) = 0 is non-negative: the integrity guard must pass and the ratio
    // 0 / D(z) must come back as exactly 0.
    let v = pdf::eval_rational_for_test(
        SCALE,
        vector[0],
        vector[false],
        vector[ONE_WAD],
        vector[false],
    );
    assert_eq!(v, 0);
}

// === Method dispatch ===

#[test]
fun method_dispatch_signed() {
    // `z.pdf()` on an SD29x9 must resolve to sd29x9_base::pdf.
    let z = pos(SCALE);
    let via_method = z.pdf();
    let via_function = sd29x9_base::pdf(z);
    assert_eq!(via_method, via_function);
}

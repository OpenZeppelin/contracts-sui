module openzeppelin_fp_math::ud30x9_pdf_tests;

use openzeppelin_fp_math::pdf_coefficients;
use openzeppelin_fp_math::ud30x9;
use openzeppelin_fp_math::ud30x9_base;
use openzeppelin_fp_math::ud30x9_test_helpers::{assert_within, fixed};
use std::unit_test::assert_eq;

// === Constants ===

const SCALE: u128 = 1_000_000_000; // UD30x9 raw scale (10^9)
const MAX_Z_RAW: u128 = 6_402_729_806; // 6.402729806 at UD30x9 scale

// 5 ULP at the UD30x9 scale (≡ 5 × 10^-9 absolute), per the accuracy contract.
const TOLERANCE: u128 = 5;

// Reference φ values at the UD30x9 raw scale (rounded from scipy/mpmath at
// 100 dps). The peak φ(0) = 1/sqrt(2*pi) is returned bit-exactly.
const PDF_0_RAW: u128 = 398_942_280;
const PDF_1_RAW: u128 = 241_970_725;
const PDF_2_RAW: u128 = 53_990_967;
const PDF_3_RAW: u128 = 4_431_848;

// === Bit-exact / well-known points ===

#[test]
fun pdf_zero_is_peak() {
    // With D(0) = 1 the rational returns the exact peak; no z = 0 special case.
    assert_eq!(ud30x9::zero().pdf().unwrap(), PDF_0_RAW);
}

#[test]
fun pdf_one_well_known() {
    assert_within(fixed(SCALE).pdf().unwrap(), PDF_1_RAW, TOLERANCE);
}

#[test]
fun pdf_two_well_known() {
    assert_within(fixed(2 * SCALE).pdf().unwrap(), PDF_2_RAW, TOLERANCE);
}

#[test]
fun pdf_three_well_known() {
    assert_within(fixed(3 * SCALE).pdf().unwrap(), PDF_3_RAW, TOLERANCE);
}

// === Saturation ===

#[test]
fun max_z_raw_is_analytical_saturation_point() {
    // Pin the saturation bound (6.402729806, the smallest z whose φ rounds to 0)
    // to the generated coefficient table so the saturation cases below fail if a
    // regenerated bound drifts.
    assert_eq!(pdf_coefficients::max_z_raw(), MAX_Z_RAW);
}

#[test]
fun saturation_above_max_z() {
    assert_eq!(fixed(MAX_Z_RAW).pdf().unwrap(), 0);
    assert_eq!(fixed(MAX_Z_RAW + 1).pdf().unwrap(), 0);
    assert_eq!(fixed(7 * SCALE).pdf().unwrap(), 0);
}

#[test]
fun saturation_at_ud30x9_extreme() {
    // ud30x9::max() is far above the saturation threshold; it must clamp to 0
    // without going through the rational path.
    assert_eq!(ud30x9::max().pdf().unwrap(), 0);
}

// === Output range ===

#[test]
fun output_range_bounded_by_peak() {
    // φ peaks at φ(0); sweep a 64-point grid over [0, 7] and confirm every
    // output is in [0, PDF_0_RAW].
    let n: u64 = 64;
    let step = 7 * SCALE / ((n - 1) as u128);
    n.do!(|i| {
        let v = fixed((i as u128) * step).pdf().unwrap();
        assert!(v <= PDF_0_RAW);
    });
}

#[random_test]
fun pdf_bounded_by_peak(raw: u128) {
    // For every input, 0 ≤ φ(z) ≤ φ(0). Saturated inputs return 0; central
    // inputs never exceed the peak.
    assert!(ud30x9::wrap(raw).pdf().unwrap() <= PDF_0_RAW);
}

// === Monotonicity ===

#[test]
fun monotonic_decreasing_on_grid() {
    // 64-point grid across [0, 6.402729806]. φ is non-increasing on the non-negative
    // half; strict decrease degenerates to equality across the saturated tail.
    let n: u64 = 64;
    let step = MAX_Z_RAW / ((n - 1) as u128);
    let mut prev: u128 = PDF_0_RAW; // φ at z = 0 is the peak
    n.do!(|i| {
        let curr = fixed((i as u128) * step).pdf().unwrap();
        assert!(curr <= prev);
        prev = curr;
    });
}

// === Determinism ===

#[test]
fun pdf_is_deterministic() {
    let z = fixed(SCALE);
    let a = z.pdf().unwrap();
    let b = z.pdf().unwrap();
    let c = z.pdf().unwrap();
    assert_eq!(a, b);
    assert_eq!(b, c);
}

// === Cross-type equivalence with SD29x9 ===

#[test]
fun matches_sd29x9_pdf_on_positives() {
    // `UD30x9::pdf(z)` and `SD29x9::pdf(z)` route through the same
    // `pdf::pdf_nonneg_raw` helper, exercising the public `into_SD29x9`
    // conversion, so the results must agree bit-for-bit.
    let probes: vector<u128> = vector[
        0,
        100_000_000,
        500_000_000,
        SCALE,
        2 * SCALE,
        3 * SCALE,
        6 * SCALE,
        MAX_Z_RAW - 1,
        MAX_Z_RAW,
        MAX_Z_RAW + 1,
        7 * SCALE,
    ];
    probes.destroy!(|raw| {
        let via_unsigned = fixed(raw).pdf().unwrap();
        let via_signed = fixed(raw).into_SD29x9().pdf().unwrap();
        assert_eq!(via_unsigned, via_signed);
    });
}

// === Method dispatch ===

#[test]
fun method_dispatch_unsigned() {
    // `z.pdf()` on a UD30x9 must resolve to ud30x9_base::pdf.
    let z = fixed(SCALE);
    let via_method = z.pdf();
    let via_function = ud30x9_base::pdf(z);
    assert_eq!(via_method, via_function);
}

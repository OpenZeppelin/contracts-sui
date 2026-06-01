#[test_only]
module openzeppelin_fp_math::sd29x9_cdf_tests;

use openzeppelin_fp_math::cdf_coefficients;
use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_base;
use openzeppelin_fp_math::sd29x9_test_helpers::{neg, pos};
use std::unit_test::assert_eq;

// === Constants ===

const SCALE: u128 = 1_000_000_000; // SD29x9 raw scale (10^9)
const HALF_RAW: u128 = 500_000_000;
const ONE_RAW: u128 = 1_000_000_000;
const MAX_Z_RAW: u128 = 6_300_000_000; // 6.3 at SD29x9 scale

// 5 ULP at the SD29x9 scale (≡ 5 × 10^-9 absolute), per the accuracy contract.
const TOLERANCE: u128 = 5;

// Reference Φ values at the UD30x9 raw scale (rounded from scipy/mpmath at
// 100 dps). The well-known-value tests read like statistics-table entries.
const PHI_1_RAW: u128 = 841_344_746;
const PHI_2_RAW: u128 = 977_249_868;
const PHI_3_RAW: u128 = 998_650_102;

// === Helpers ===

fun abs_diff(a: u128, b: u128): u128 {
    if (a >= b) a - b else b - a
}

fun assert_within(actual: u128, expected: u128, tol: u128) {
    let diff = abs_diff(actual, expected);
    assert!(diff <= tol, 0xC0DE);
}

// === Bit-exact / well-known points ===

#[test]
fun phi_zero_is_exactly_one_half() {
    // Bit-exact special case at z = 0.
    assert_eq!(sd29x9::zero().cdf().unwrap(), HALF_RAW);
}

#[test]
fun phi_one_well_known() {
    assert_within(pos(SCALE).cdf().unwrap(), PHI_1_RAW, TOLERANCE);
}

#[test]
fun phi_two_well_known() {
    assert_within(pos(2 * SCALE).cdf().unwrap(), PHI_2_RAW, TOLERANCE);
}

#[test]
fun phi_three_well_known() {
    assert_within(pos(3 * SCALE).cdf().unwrap(), PHI_3_RAW, TOLERANCE);
}

#[test]
fun phi_minus_one_well_known() {
    assert_within(neg(SCALE).cdf().unwrap(), ONE_RAW - PHI_1_RAW, TOLERANCE);
}

#[test]
fun phi_minus_two_well_known() {
    assert_within(neg(2 * SCALE).cdf().unwrap(), ONE_RAW - PHI_2_RAW, TOLERANCE);
}

#[test]
fun phi_minus_three_well_known() {
    assert_within(neg(3 * SCALE).cdf().unwrap(), ONE_RAW - PHI_3_RAW, TOLERANCE);
}

// === Saturation ===

#[test]
fun saturation_above_max_z() {
    assert_eq!(pos(MAX_Z_RAW).cdf().unwrap(), ONE_RAW);
    assert_eq!(pos(MAX_Z_RAW + 1).cdf().unwrap(), ONE_RAW);
    assert_eq!(pos(7 * SCALE).cdf().unwrap(), ONE_RAW);
}

#[test]
fun saturation_below_min_z() {
    assert_eq!(neg(MAX_Z_RAW).cdf().unwrap(), 0);
    assert_eq!(neg(MAX_Z_RAW + 1).cdf().unwrap(), 0);
    assert_eq!(neg(7 * SCALE).cdf().unwrap(), 0);
}

#[test]
fun saturation_at_sd29x9_extremes() {
    // sd29x9::max() and sd29x9::min() are far above the saturation threshold;
    // both must clamp cleanly without going through the rational path.
    assert_eq!(sd29x9::max().cdf().unwrap(), ONE_RAW);
    assert_eq!(sd29x9::min().cdf().unwrap(), 0);
}

// === Output range ===

#[test]
fun output_range_bounded_by_unit_interval() {
    // Sweep a 64-point grid spanning [-7, 7] (covering both saturation regions
    // and the central domain) and confirm every output stays in [0, 10^9].
    let n: u64 = 64;
    let step = 14 * SCALE / ((n - 1) as u128);
    let mut i: u64 = 0;
    while (i < n) {
        let offset = (i as u128) * step;
        // shift to negative half: when i < 32 → negative, else → positive
        let z = if (offset < 7 * SCALE) {
            neg(7 * SCALE - offset)
        } else {
            pos(offset - 7 * SCALE)
        };
        let v = z.cdf().unwrap();
        assert!(v <= ONE_RAW, 0xC0DE);
        i = i + 1;
    };
}

// === Last-ULP overshoot guard ===

#[test]
fun no_overshoot_at_high_z() {
    // Just below max_z, N(z)/D(z) is extremely close to 1.0; the nearest-rounding
    // ratio could in principle produce ONE_RAW + 1. The clamp must keep the
    // output a valid probability.
    let probes: vector<u128> = vector[
        MAX_Z_RAW - 1,
        6_299_999_000,
        6_290_000_000,
        6_000_000_000,
        5_500_000_000,
    ];
    let mut i = 0;
    let n = probes.length();
    while (i < n) {
        let v = pos(probes[i]).cdf().unwrap();
        assert!(v <= ONE_RAW, 0xC0DE);
        i = i + 1;
    };
}

// === Monotonicity ===

#[test]
fun monotonic_on_grid() {
    // 64-point grid across [-6.3, 6.3]. Strict monotonicity across saturated
    // regions degenerates to equality; both are accepted.
    let n: u64 = 64;
    let step = (2 * MAX_Z_RAW) / ((n - 1) as u128);
    let mut prev: u128 = 0; // cdf at lower bound saturates to 0
    let mut i: u64 = 0;
    while (i < n) {
        let offset = (i as u128) * step;
        let z = if (offset < MAX_Z_RAW) {
            neg(MAX_Z_RAW - offset)
        } else {
            pos(offset - MAX_Z_RAW)
        };
        let curr = z.cdf().unwrap();
        assert!(curr >= prev, 0xC0DE);
        prev = curr;
        i = i + 1;
    };
}

// === Symmetry ===

#[test]
fun symmetry_on_well_known_points() {
    let probes: vector<u128> = vector[
        100_000_000, 500_000_000, SCALE, 2 * SCALE, 3 * SCALE, 5 * SCALE, 6 * SCALE,
    ];
    let mut i = 0;
    let n = probes.length();
    while (i < n) {
        let raw = probes[i];
        let cdf_pos = pos(raw).cdf().unwrap();
        let cdf_neg = neg(raw).cdf().unwrap();
        // |cdf(z) + cdf(-z) - 1| ≤ 5 ULP
        let sum = cdf_pos + cdf_neg;
        assert_within(sum, ONE_RAW, TOLERANCE);
        i = i + 1;
    };
}

// === Determinism ===

#[test]
fun cdf_is_deterministic() {
    let z = pos(SCALE);
    let a = z.cdf().unwrap();
    let b = z.cdf().unwrap();
    let c = z.cdf().unwrap();
    assert_eq!(a, b);
    assert_eq!(b, c);
}

#[test]
fun coefficient_accessors_are_deterministic() {
    // Two consecutive reads must return the same vectors.
    assert_eq!(cdf_coefficients::cdf_num_mags(), cdf_coefficients::cdf_num_mags());
    assert_eq!(cdf_coefficients::cdf_num_negs(), cdf_coefficients::cdf_num_negs());
    assert_eq!(cdf_coefficients::cdf_den_mags(), cdf_coefficients::cdf_den_mags());
    assert_eq!(cdf_coefficients::cdf_den_negs(), cdf_coefficients::cdf_den_negs());
    assert_eq!(cdf_coefficients::cdf_num_len(), cdf_coefficients::cdf_num_len());
    assert_eq!(cdf_coefficients::cdf_den_len(), cdf_coefficients::cdf_den_len());
}

#[test]
fun coefficient_table_lengths_match_array_lengths() {
    // Sanity: the *_len accessors track the actual vector length (caller relies
    // on this implicitly when binding to locals and indexing).
    assert_eq!(cdf_coefficients::cdf_num_mags().length(), cdf_coefficients::cdf_num_len());
    assert_eq!(cdf_coefficients::cdf_num_negs().length(), cdf_coefficients::cdf_num_len());
    assert_eq!(cdf_coefficients::cdf_den_mags().length(), cdf_coefficients::cdf_den_len());
    assert_eq!(cdf_coefficients::cdf_den_negs().length(), cdf_coefficients::cdf_den_len());
}

// === Method dispatch ===

#[test]
fun method_dispatch_signed() {
    // `z.cdf()` on an SD29x9 must resolve to sd29x9_base::cdf.
    let z = pos(SCALE);
    let via_method = z.cdf();
    let via_function = sd29x9_base::cdf(z);
    assert_eq!(via_method, via_function);
}

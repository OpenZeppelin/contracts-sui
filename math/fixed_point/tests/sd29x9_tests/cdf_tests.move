module openzeppelin_fp_math::sd29x9_cdf_tests;

use openzeppelin_fp_math::cdf;
use openzeppelin_fp_math::cdf_coefficients;
use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_base;
use openzeppelin_fp_math::sd29x9_test_helpers::{assert_within, neg, pos};
use std::unit_test::assert_eq;

// === Constants ===

const SCALE: u128 = 1_000_000_000; // SD29x9 raw scale (10^9)
const HALF_RAW: u128 = 500_000_000;
const ONE_RAW: u128 = 1_000_000_000;
const MAX_Z_RAW: u128 = 6_109_410_205; // 6.109410205 at SD29x9 scale
const ONE_ACC_SCALE: u128 = 1_000_000_000_000_000_000_000_000_000_000_000_000; // 1.0 at the accumulation scale (10^36, coefficient injection)

// 5 ULP at the SD29x9 scale (≡ 5 × 10^-9 absolute), per the accuracy contract.
const TOLERANCE: u128 = 5;

// Reference Φ values at the UD30x9 raw scale (rounded from scipy/mpmath at
// 100 dps). The well-known-value tests read like statistics-table entries.
const PHI_1_RAW: u128 = 841_344_746;
const PHI_2_RAW: u128 = 977_249_868;
const PHI_3_RAW: u128 = 998_650_102;

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

#[test]
fun max_z_raw_is_analytical_saturation_point() {
    // Pin the saturation domain bound to 6.109410205 - the smallest z whose Φ
    // rounds to 1.000000000 at the 10^9 scale. Moving the domain would slip past
    // the behavioral saturation tests and the Python sweep, but is caught here.
    assert_eq!(cdf_coefficients::max_z_raw(), MAX_Z_RAW);
}

// === Output range ===

#[test]
fun output_range_bounded_by_unit_interval() {
    // Sweep a 64-point grid spanning [-7, 7] (covering both saturation regions
    // and the central domain) and confirm every output stays in [0, 10^9].
    let n: u64 = 64;
    let step = 14 * SCALE / ((n - 1) as u128);
    n.do!(|i| {
        let offset = (i as u128) * step;
        // shift to negative half: when i < 32 → negative, else → positive
        let z = if (offset < 7 * SCALE) {
            neg(7 * SCALE - offset)
        } else {
            pos(offset - 7 * SCALE)
        };
        let v = z.cdf().unwrap();
        assert!(v <= ONE_RAW);
    });
}

// === Last-ULP overshoot guard ===

#[test]
fun no_overshoot_at_high_z() {
    // Just below max_z, N(z)/D(z) is extremely close to 1.0; the nearest-rounding
    // ratio could in principle produce ONE_RAW + 1. The clamp must keep the
    // output a valid probability.
    let probes: vector<u128> = vector[
        MAX_Z_RAW - 1,
        6_109_000_000,
        6_100_000_000,
        6_000_000_000,
        5_500_000_000,
    ];
    probes.destroy!(|raw| assert!(pos(raw).cdf().unwrap() <= ONE_RAW));
}

#[test]
fun overshoot_clamps_to_one() {
    // N(z)/D(z) = 2.0 exceeds 1.0, so the last-ULP overshoot clamp must pin the
    // result to ONE_RAW. This branch is dead for the committed coefficients, so
    // it is driven directly through the eval_rational seam.
    let v = cdf::eval_rational_for_test(
        SCALE,
        vector[2 * ONE_ACC_SCALE],
        vector[false],
        vector[ONE_ACC_SCALE],
        vector[false],
    );
    assert_eq!(v, ONE_RAW);
}

// === Monotonicity ===

#[test]
fun monotonic_on_grid() {
    // 64-point grid across [-6.109410205, 6.109410205]. Strict monotonicity across saturated
    // regions degenerates to equality; both are accepted.
    let n: u64 = 64;
    let step = (2 * MAX_Z_RAW) / ((n - 1) as u128);
    let mut prev: u128 = 0; // cdf at lower bound saturates to 0
    n.do!(|i| {
        let offset = (i as u128) * step;
        let z = if (offset < MAX_Z_RAW) {
            neg(MAX_Z_RAW - offset)
        } else {
            pos(offset - MAX_Z_RAW)
        };
        let curr = z.cdf().unwrap();
        assert!(curr >= prev);
        prev = curr;
    });
}

// === Symmetry ===

#[test]
fun symmetry_on_well_known_points() {
    // Probes span the zero special case, the rational central domain, and the
    // saturated region - the reflection identity must hold on every branch.
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
        let cdf_pos = pos(raw).cdf().unwrap();
        let cdf_neg = neg(raw).cdf().unwrap();
        // cdf(z) + cdf(-z) == 1 bit-exactly: both calls share the same Φ(|z|)
        // evaluation and the negative branch reflects it as 10^9 - Φ(|z|).
        assert_eq!(cdf_pos + cdf_neg, ONE_RAW);
    });
}

// === Negative-branch near-zero (underflow guard) ===

#[test]
fun negative_near_zero_no_underflow() {
    // The negative branch computes `10^9 - phi`, closest to the
    // EInternalNegSubUnderflow guard as |z| → 0 (where phi → 0.5). Neither the
    // well-known points (smallest 0.1) nor the Python sweep (smallest ≈ 6.1e-4)
    // probe this region; reaching the assert proves the guard did not fire.
    let probes: vector<u128> = vector[1, 100, 10_000, 1_000_000, 50_000_000];
    probes.destroy!(|raw| {
        assert!(neg(raw).cdf().unwrap() <= HALF_RAW); // Φ(−|z|) ≤ 0.5
    });
    assert_within(neg(1).cdf().unwrap(), HALF_RAW, TOLERANCE);
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
fun coefficient_arrays_have_matching_lengths() {
    // The Horner loop iterates by the mags-vector length and indexes the
    // parallel negs vector, so the two must stay the same length.
    assert_eq!(
        cdf_coefficients::cdf_num_mags().length(),
        cdf_coefficients::cdf_num_negs().length(),
    );
    assert_eq!(
        cdf_coefficients::cdf_den_mags().length(),
        cdf_coefficients::cdf_den_negs().length(),
    );
}

// === Integrity asserts (defense-in-depth; unreachable via the public API) ===

#[test, expected_failure(abort_code = cdf::EInternalNumNegative)]
fun numerator_negative_aborts() {
    // A constant numerator of -1.0 forces N(z) < 0 on the central domain.
    let _ = cdf::eval_rational_for_test(
        SCALE, // z = 1.0, inside [0, 6.109410205)
        vector[ONE_ACC_SCALE],
        vector[true],
        vector[ONE_ACC_SCALE],
        vector[false],
    );
}

#[test, expected_failure(abort_code = cdf::EInternalDenNonPositive)]
fun denominator_nonpositive_aborts() {
    // A constant denominator of -1.0 forces D(z) < 0 on the central domain.
    let _ = cdf::eval_rational_for_test(
        SCALE,
        vector[ONE_ACC_SCALE],
        vector[false],
        vector[ONE_ACC_SCALE],
        vector[true],
    );
}

#[test, expected_failure(abort_code = cdf::EInternalDenNonPositive)]
fun denominator_zero_aborts() {
    // A constant denominator of 0 evaluates to canonical zero, which must trip
    // the `mag(d) > 0` half of the guard rather than reach the division.
    let _ = cdf::eval_rational_for_test(
        SCALE,
        vector[ONE_ACC_SCALE],
        vector[false],
        vector[0],
        vector[false],
    );
}

#[test]
fun numerator_zero_passes_guard_returns_zero() {
    // N(z) = 0 is non-negative: the integrity guard must pass and the
    // ratio 0 / D(z) must come back as exactly 0.
    let v = cdf::eval_rational_for_test(
        SCALE,
        vector[0],
        vector[false],
        vector[ONE_ACC_SCALE],
        vector[false],
    );
    assert_eq!(v, 0);
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

module openzeppelin_fp_math::sd29x9_inverse_cdf_tests;

use openzeppelin_fp_math::inverse_cdf;
use openzeppelin_fp_math::inverse_cdf_coefficients;
use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_base;
use openzeppelin_fp_math::sd29x9_test_helpers::{assert_within, neg, pos};
use std::unit_test::assert_eq;

// === Constants ===

const SCALE: u128 = 1_000_000_000; // SD29x9 raw scale (10^9)
const HALF_RAW: u128 = 500_000_000; // p = 0.5
const ONE_RAW: u128 = 1_000_000_000; // p = 1.0
const MAX_Z_RAW: u128 = 6_300_000_000; // 6.3 at SD29x9 scale (output saturation)
const SPLIT_RAW: u128 = 975_000_000; // central/tail probability split
const ONE_WAD: u128 = 1_000_000_000_000_000_000; // 1.0 at WAD scale (coefficient injection)

// 5 ULP at the SD29x9 scale (≡ 5 × 10^-9 absolute), per the accuracy contract.
const TOLERANCE: u128 = 5;
// Round-trip through cdf ∘ inverse_cdf stacks two approximations plus the
// probability-space mapping; still tight since dp = φ(z)·dz shrinks the z error.
const ROUND_TRIP_TOL: u128 = 10;

// Reference Φ⁻¹ values at the SD29x9 raw scale (from mpmath erfinv at 100 dps).
// The well-known-value tests read like statistics-table entries.
const Z_90_RAW: u128 = 1_281_551_566; // Φ⁻¹(0.90)
const Z_95_RAW: u128 = 1_644_853_627; // Φ⁻¹(0.95)
const Z_975_RAW: u128 = 1_959_963_985; // Φ⁻¹(0.975) - the 1.96 of a 95% CI
const Z_99_RAW: u128 = 2_326_347_874; // Φ⁻¹(0.99)
const Z_TAIL_RAW: u128 = 5_997_807_015; // Φ⁻¹(1 − 1e-9)

// === Bit-exact / well-known points ===

#[test]
fun quantile_half_is_exactly_zero() {
    // Bit-exact special case at p = 0.5.
    assert_eq!(pos(HALF_RAW).inverse_cdf().unwrap(), 0);
}

#[test]
fun quantile_p975_well_known() {
    let z = pos(975_000_000).inverse_cdf();
    assert!(!z.is_negative());
    assert_within(z.abs().unwrap(), Z_975_RAW, TOLERANCE);
}

#[test]
fun quantile_p90_p95_p99_well_known() {
    assert_within(pos(900_000_000).inverse_cdf().abs().unwrap(), Z_90_RAW, TOLERANCE);
    assert_within(pos(950_000_000).inverse_cdf().abs().unwrap(), Z_95_RAW, TOLERANCE);
    assert_within(pos(990_000_000).inverse_cdf().abs().unwrap(), Z_99_RAW, TOLERANCE);
}

#[test]
fun quantile_of_phi_one_is_one() {
    // Φ(1) = 0.841344746, so Φ⁻¹(0.841344746) = 1.0 (a clean central anchor).
    let z = pos(841_344_746).inverse_cdf();
    assert!(!z.is_negative());
    assert_within(z.abs().unwrap(), SCALE, TOLERANCE);
}

#[test]
fun quantile_below_half_is_negative() {
    // Reflection: p < 0.5 yields a negative quantile of the same magnitude.
    let z25 = pos(25_000_000).inverse_cdf(); // Φ⁻¹(0.025) = -1.959963985
    assert!(z25.is_negative());
    assert_within(z25.abs().unwrap(), Z_975_RAW, TOLERANCE);

    let z10 = pos(100_000_000).inverse_cdf(); // Φ⁻¹(0.10) = -1.281551566
    assert!(z10.is_negative());
    assert_within(z10.abs().unwrap(), Z_90_RAW, TOLERANCE);
}

// === Saturation ===

#[test]
fun saturates_at_one() {
    // Φ⁻¹(1) = +∞, clamped to +MAX_Z.
    let z = pos(ONE_RAW).inverse_cdf();
    assert!(!z.is_negative());
    assert_eq!(z.abs().unwrap(), MAX_Z_RAW);
}

#[test]
fun saturates_at_zero() {
    // Φ⁻¹(0) = -∞, clamped (via reflection) to -MAX_Z.
    let z = pos(0).inverse_cdf();
    assert!(z.is_negative());
    assert_eq!(z.abs().unwrap(), MAX_Z_RAW);
}

#[test]
fun deep_tail_is_finite_below_max_z() {
    // The deepest representable interior input p = 1 − 1e-9 maps to z ≈ 5.998,
    // strictly below the 6.3 saturation sentinel (only p = 1 exactly saturates).
    let z = pos(ONE_RAW - 1).inverse_cdf();
    assert!(!z.is_negative());
    assert!(z.abs().unwrap() < MAX_Z_RAW);
    assert_within(z.abs().unwrap(), Z_TAIL_RAW, TOLERANCE);
}

#[test]
fun domain_bounds_pinned() {
    // Pin the output saturation clamp and the central/tail split. Moving either
    // would slip past the behavioral tests and the Python sweep; caught here.
    assert_eq!(inverse_cdf_coefficients::max_z_raw(), MAX_Z_RAW);
    assert_eq!(inverse_cdf_coefficients::central_threshold_raw(), SPLIT_RAW);
}

// === Output range ===

#[test]
fun output_range_bounded_by_max_z() {
    // Sweep a 64-point grid of probabilities across [0, 1] and confirm every
    // quantile magnitude stays within [0, MAX_Z].
    let n: u64 = 64;
    let step = ONE_RAW / ((n - 1) as u128);
    n.do!(|i| {
        let z = pos((i as u128) * step).inverse_cdf();
        assert!(z.abs().unwrap() <= MAX_Z_RAW);
    });
}

// === Monotonicity ===

#[test]
fun monotonic_on_grid() {
    // 64-point probability grid across [0, 1]. Φ⁻¹ is increasing, so the signed
    // quantile must be non-decreasing (crossing the central/tail seam at 0.975).
    let n: u64 = 64;
    let step = ONE_RAW / ((n - 1) as u128);
    let mut prev = sd29x9::min();
    n.do!(|i| {
        let curr = pos((i as u128) * step).inverse_cdf();
        assert!(prev.lte(curr));
        prev = curr;
    });
}

// === Symmetry ===

#[test]
fun symmetry_reflection_identity() {
    // Probes span the zero special case, both rational regions, the seam, and the
    // saturated endpoints: Φ⁻¹(p) == -Φ⁻¹(1 - p) must hold bit-exactly on each.
    let probes: vector<u128> = vector[
        0,
        1,
        25_000_000,
        100_000_000,
        500_000_000,
        750_000_000,
        975_000_000,
        999_000_000,
        999_999_999,
        ONE_RAW,
    ];
    probes.destroy!(|p_raw| {
        let z = pos(p_raw).inverse_cdf();
        let z_refl = pos(ONE_RAW - p_raw).inverse_cdf();
        assert_eq!(z, z_refl.negate());
    });
}

// === Round-trip against cdf ===

#[test]
fun round_trip_probability_space() {
    // cdf(inverse_cdf(p)) recovers p to within a few ULP, on both sides of 0.5.
    let probes: vector<u128> = vector[
        25_000_000,
        100_000_000,
        250_000_000,
        400_000_000,
        600_000_000,
        750_000_000,
        900_000_000,
        975_000_000,
    ];
    probes.destroy!(|p_raw| {
        let z = pos(p_raw).inverse_cdf(); // z = Φ⁻¹(p)
        let p_recovered = z.cdf().unwrap(); // Φ(z) ≈ p
        assert_within(p_recovered, p_raw, ROUND_TRIP_TOL);
    });
}

#[test]
fun round_trip_z_anchor() {
    // z → cdf → inverse_cdf recovers z near the center (|z| ≤ 1, where dz/dp is
    // modest). Uses the exact anchor Φ(1) = 0.841344746.
    let z = pos(SCALE); // 1.0
    let recovered = z.cdf().inverse_cdf(); // ≈ 1.0
    assert!(!recovered.is_negative());
    assert_within(recovered.abs().unwrap(), SCALE, 20);
}

// === Determinism ===

#[test]
fun inverse_cdf_is_deterministic() {
    let p = pos(750_000_000);
    let a = p.inverse_cdf();
    let b = p.inverse_cdf();
    let c = p.inverse_cdf();
    assert_eq!(a, b);
    assert_eq!(b, c);
}

#[test]
fun coefficient_arrays_have_matching_lengths() {
    // The Horner loop iterates by the mags-vector length and indexes the parallel
    // negs vector, so the two must stay the same length - in both regions.
    assert_eq!(
        inverse_cdf_coefficients::central_num_mags().length(),
        inverse_cdf_coefficients::central_num_negs().length(),
    );
    assert_eq!(
        inverse_cdf_coefficients::central_den_mags().length(),
        inverse_cdf_coefficients::central_den_negs().length(),
    );
    assert_eq!(
        inverse_cdf_coefficients::tail_num_mags().length(),
        inverse_cdf_coefficients::tail_num_negs().length(),
    );
    assert_eq!(
        inverse_cdf_coefficients::tail_den_mags().length(),
        inverse_cdf_coefficients::tail_den_negs().length(),
    );
}

// === Integrity asserts (defense-in-depth; unreachable via the public API) ===

#[test, expected_failure(abort_code = inverse_cdf::EInternalNumNegative)]
fun numerator_negative_aborts() {
    // A constant numerator of -1.0 forces N(x) < 0.
    let _ = inverse_cdf::eval_rational_for_test(
        SCALE,
        vector[ONE_WAD],
        vector[true],
        vector[ONE_WAD],
        vector[false],
    );
}

#[test, expected_failure(abort_code = inverse_cdf::EInternalDenNonPositive)]
fun denominator_nonpositive_aborts() {
    // A constant denominator of -1.0 forces D(x) < 0.
    let _ = inverse_cdf::eval_rational_for_test(
        SCALE,
        vector[ONE_WAD],
        vector[false],
        vector[ONE_WAD],
        vector[true],
    );
}

#[test, expected_failure(abort_code = inverse_cdf::EInternalDenNonPositive)]
fun denominator_zero_aborts() {
    // A constant denominator of 0 evaluates to canonical zero, tripping the
    // `mag(d) > 0` half of the guard before the division.
    let _ = inverse_cdf::eval_rational_for_test(
        SCALE,
        vector[ONE_WAD],
        vector[false],
        vector[0],
        vector[false],
    );
}

#[test]
fun numerator_zero_passes_guard_returns_zero() {
    // N(x) = 0 is non-negative: the guard passes and 0 / D(x) is exactly 0.
    let v = inverse_cdf::eval_rational_for_test(
        SCALE,
        vector[0],
        vector[false],
        vector[ONE_WAD],
        vector[false],
    );
    assert_eq!(v, 0);
}

#[test]
fun overshoot_clamps_to_max_z() {
    // N(x)/D(x) = 7.0 exceeds the 6.3 output bound, so the clamp must pin the
    // result to MAX_Z_RAW. Dead for the committed coefficients; driven directly.
    let v = inverse_cdf::eval_rational_for_test(
        SCALE,
        vector[7 * ONE_WAD],
        vector[false],
        vector[ONE_WAD],
        vector[false],
    );
    assert_eq!(v, MAX_Z_RAW);
}

// === Tail transform kernel fidelity ===

#[test]
fun tail_transform_matches_offline_mirror() {
    // The on-chain tail variable `r = sqrt(-2 ln(1 - p))` must match the offline
    // integer mirror (`scripts/gaussian_codegen/shared/arithmetic.py::tail_r_raw`)
    // bit-for-bit, so the codegen validator faithfully re-runs the on-chain path.
    // `r` is a pure function of the `common` log kernel and `u256::sqrt` -
    // independent of the fit coefficients - so these values are stable across
    // coefficient regeneration.
    assert_eq!(inverse_cdf::tail_variable_raw_for_test(975_000_000), 2_716_203_031);
    assert_eq!(inverse_cdf::tail_variable_raw_for_test(980_000_000), 2_797_149_622);
    assert_eq!(inverse_cdf::tail_variable_raw_for_test(990_000_000), 3_034_854_258);
    assert_eq!(inverse_cdf::tail_variable_raw_for_test(999_000_000), 3_716_922_188);
    assert_eq!(inverse_cdf::tail_variable_raw_for_test(999_990_000), 4_798_525_911);
    assert_eq!(inverse_cdf::tail_variable_raw_for_test(999_999_999), 6_437_898_078);
}

// === Caller-facing domain aborts ===

#[test, expected_failure(abort_code = sd29x9_base::EProbabilityOutOfRange)]
fun probability_above_one_aborts() {
    let _ = pos(ONE_RAW + 1).inverse_cdf();
}

#[test, expected_failure(abort_code = sd29x9_base::EProbabilityOutOfRange)]
fun negative_probability_aborts() {
    let _ = neg(1).inverse_cdf();
}

// === Method dispatch ===

#[test]
fun method_dispatch_signed() {
    // `p.inverse_cdf()` on an SD29x9 must resolve to sd29x9_base::inverse_cdf.
    let p = pos(975_000_000);
    assert_eq!(p.inverse_cdf(), sd29x9_base::inverse_cdf(p));
}

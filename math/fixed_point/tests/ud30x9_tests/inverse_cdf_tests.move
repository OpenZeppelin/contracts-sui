module openzeppelin_fp_math::ud30x9_inverse_cdf_tests;

use openzeppelin_fp_math::inverse_cdf_coefficients;
use openzeppelin_fp_math::ud30x9_base;
use openzeppelin_fp_math::ud30x9_test_helpers::{assert_within, fixed};
use std::unit_test::assert_eq;

// === Constants ===

const SCALE: u128 = 1_000_000_000; // UD30x9 raw scale (10^9)
const HALF_RAW: u128 = 500_000_000; // p = 0.5, the domain lower bound
const ONE_RAW: u128 = 1_000_000_000; // p = 1.0
const MAX_Z_RAW: u128 = 6_300_000_000; // 6.3 at UD30x9 scale (output saturation)
const SPLIT_RAW: u128 = 975_000_000; // central/tail probability split

// 5 ULP at the UD30x9 scale (≡ 5 × 10^-9 absolute), per the accuracy contract.
const TOLERANCE: u128 = 5;
const ROUND_TRIP_TOL: u128 = 10;

// Reference Φ⁻¹ values at the UD30x9 raw scale (from mpmath erfinv at 100 dps).
const Z_90_RAW: u128 = 1_281_551_566; // Φ⁻¹(0.90)
const Z_95_RAW: u128 = 1_644_853_627; // Φ⁻¹(0.95)
const Z_975_RAW: u128 = 1_959_963_985; // Φ⁻¹(0.975)
const Z_99_RAW: u128 = 2_326_347_874; // Φ⁻¹(0.99)
const Z_TAIL_RAW: u128 = 5_997_807_015; // Φ⁻¹(1 − 1e-9)

// === Bit-exact / well-known points ===

#[test]
fun quantile_half_is_exactly_zero() {
    // Bit-exact special case at p = 0.5.
    assert_eq!(fixed(HALF_RAW).inverse_cdf().unwrap(), 0);
}

#[test]
fun quantile_well_known_points() {
    assert_within(fixed(900_000_000).inverse_cdf().unwrap(), Z_90_RAW, TOLERANCE);
    assert_within(fixed(950_000_000).inverse_cdf().unwrap(), Z_95_RAW, TOLERANCE);
    assert_within(fixed(975_000_000).inverse_cdf().unwrap(), Z_975_RAW, TOLERANCE);
    assert_within(fixed(990_000_000).inverse_cdf().unwrap(), Z_99_RAW, TOLERANCE);
}

#[test]
fun quantile_of_phi_one_is_one() {
    // Φ(1) = 0.841344746, so Φ⁻¹(0.841344746) = 1.0.
    assert_within(fixed(841_344_746).inverse_cdf().unwrap(), SCALE, TOLERANCE);
}

// === Saturation ===

#[test]
fun saturates_at_one() {
    // Φ⁻¹(1) = +∞, clamped to MAX_Z.
    assert_eq!(fixed(ONE_RAW).inverse_cdf().unwrap(), MAX_Z_RAW);
}

#[test]
fun deep_tail_is_finite_below_max_z() {
    // p = 1 − 1e-9 maps to z ≈ 5.998, strictly below the 6.3 saturation sentinel.
    let z = fixed(ONE_RAW - 1).inverse_cdf().unwrap();
    assert!(z < MAX_Z_RAW);
    assert_within(z, Z_TAIL_RAW, TOLERANCE);
}

#[test]
fun domain_bounds_pinned() {
    assert_eq!(inverse_cdf_coefficients::max_z_raw(), MAX_Z_RAW);
    assert_eq!(inverse_cdf_coefficients::central_threshold_raw(), SPLIT_RAW);
}

// === Output range ===

#[test]
fun output_range_bounded_by_max_z() {
    // UD30x9 inputs are `p ≥ 0.5`, so `z ≥ 0`. Sweep a 64-point grid over
    // [0.5, 1] and confirm every output is in [0, MAX_Z].
    let n: u64 = 64;
    let step = HALF_RAW / ((n - 1) as u128); // spans [0.5, 1]
    n.do!(|i| {
        let v = fixed(HALF_RAW + (i as u128) * step).inverse_cdf().unwrap();
        assert!(v <= MAX_Z_RAW);
    });
}

// === Monotonicity ===

#[test]
fun monotonic_on_grid() {
    // 64-point grid across [0.5, 1]. Φ⁻¹ is non-decreasing, crossing the
    // central/tail seam at 0.975.
    let n: u64 = 64;
    let step = HALF_RAW / ((n - 1) as u128);
    let mut prev: u128 = 0; // Φ⁻¹(0.5) = 0
    n.do!(|i| {
        let curr = fixed(HALF_RAW + (i as u128) * step).inverse_cdf().unwrap();
        assert!(curr >= prev);
        prev = curr;
    });
}

// === Round-trip against cdf ===

#[test]
fun round_trip_probability_space() {
    // cdf(inverse_cdf(p)) recovers p to within a few ULP on the upper half.
    let probes: vector<u128> = vector[
        500_000_000,
        600_000_000,
        750_000_000,
        900_000_000,
        975_000_000,
    ];
    probes.destroy!(|p_raw| {
        let z = fixed(p_raw).inverse_cdf(); // z = Φ⁻¹(p) ≥ 0
        let p_recovered = z.cdf().unwrap(); // Φ(z) ≈ p
        assert_within(p_recovered, p_raw, ROUND_TRIP_TOL);
    });
}

// === Cross-type equivalence with SD29x9 ===

#[test]
fun matches_sd29x9_inverse_cdf_on_upper_half() {
    // `UD30x9::inverse_cdf(p)` and `SD29x9::inverse_cdf(p.into_SD29x9())` must
    // agree bit-for-bit on `p ≥ 0.5`: both route through the same
    // `inverse_cdf::inverse_cdf_upper_raw` helper. Exercises `into_SD29x9`.
    let probes: vector<u128> = vector[
        500_000_000,
        600_000_000,
        841_344_746,
        975_000_000,
        990_000_000,
        999_999_999,
        ONE_RAW,
    ];
    probes.destroy!(|p_raw| {
        let via_unsigned = fixed(p_raw).inverse_cdf().unwrap();
        let via_signed = fixed(p_raw).into_SD29x9().inverse_cdf();
        assert!(!via_signed.is_negative());
        assert_eq!(via_unsigned, via_signed.unwrap());
    });
}

// === Determinism ===

#[test]
fun inverse_cdf_is_deterministic() {
    let p = fixed(750_000_000);
    let a = p.inverse_cdf();
    let b = p.inverse_cdf();
    assert_eq!(a, b);
}

#[test]
fun coefficient_arrays_have_matching_lengths() {
    assert_eq!(
        inverse_cdf_coefficients::central_num_mags().length(),
        inverse_cdf_coefficients::central_num_negs().length(),
    );
    assert_eq!(
        inverse_cdf_coefficients::tail_num_mags().length(),
        inverse_cdf_coefficients::tail_num_negs().length(),
    );
}

// === Caller-facing domain aborts ===

#[test, expected_failure(abort_code = ud30x9_base::EProbabilityBelowHalf)]
fun probability_below_half_aborts() {
    // p < 0.5 would yield a negative quantile, unrepresentable in UD30x9.
    let _ = fixed(HALF_RAW - 1).inverse_cdf();
}

#[test, expected_failure(abort_code = ud30x9_base::EProbabilityOutOfRange)]
fun probability_above_one_aborts() {
    let _ = fixed(ONE_RAW + 1).inverse_cdf();
}

// === Method dispatch ===

#[test]
fun method_dispatch_unsigned() {
    // `p.inverse_cdf()` on a UD30x9 must resolve to ud30x9_base::inverse_cdf.
    let p = fixed(975_000_000);
    assert_eq!(p.inverse_cdf(), ud30x9_base::inverse_cdf(p));
}

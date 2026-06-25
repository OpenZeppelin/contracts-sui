module openzeppelin_fp_math::ud30x9_cdf_tests;

use openzeppelin_fp_math::ud30x9;
use openzeppelin_fp_math::ud30x9_base;
use openzeppelin_fp_math::ud30x9_test_helpers::{assert_within, fixed};
use std::unit_test::assert_eq;

// === Constants ===

const SCALE: u128 = 1_000_000_000; // UD30x9 raw scale (10^9)
const HALF_RAW: u128 = 500_000_000;
const ONE_RAW: u128 = 1_000_000_000;
const MAX_Z_RAW: u128 = 6_300_000_000; // 6.3 at UD30x9 scale

// 5 ULP at the UD30x9 scale (≡ 5 × 10^-9 absolute), per the accuracy contract.
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
    assert_eq!(ud30x9::zero().cdf().unwrap(), HALF_RAW);
}

#[test]
fun phi_one_well_known() {
    assert_within(fixed(SCALE).cdf().unwrap(), PHI_1_RAW, TOLERANCE);
}

#[test]
fun phi_two_well_known() {
    assert_within(fixed(2 * SCALE).cdf().unwrap(), PHI_2_RAW, TOLERANCE);
}

#[test]
fun phi_three_well_known() {
    assert_within(fixed(3 * SCALE).cdf().unwrap(), PHI_3_RAW, TOLERANCE);
}

// === Saturation ===

#[test]
fun saturation_above_max_z() {
    assert_eq!(fixed(MAX_Z_RAW).cdf().unwrap(), ONE_RAW);
    assert_eq!(fixed(MAX_Z_RAW + 1).cdf().unwrap(), ONE_RAW);
    assert_eq!(fixed(7 * SCALE).cdf().unwrap(), ONE_RAW);
}

#[test]
fun saturation_at_ud30x9_extreme() {
    // ud30x9::max() is far above the saturation threshold; it must clamp
    // cleanly without going through the rational path.
    assert_eq!(ud30x9::max().cdf().unwrap(), ONE_RAW);
}

// === Output range ===

#[test]
fun output_range_bounded_above_half() {
    // UD30x9 inputs are non-negative, so Φ(z) ≥ 0.5 mathematically. Sweep a
    // 64-point grid over [0, 7] and confirm every output is in [HALF_RAW, ONE_RAW].
    let n: u64 = 64;
    let step = 7 * SCALE / ((n - 1) as u128);
    n.do!(|i| {
        let v = fixed((i as u128) * step).cdf().unwrap();
        assert!(v >= HALF_RAW);
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
        6_299_999_000,
        6_290_000_000,
        6_000_000_000,
        5_500_000_000,
    ];
    probes.destroy!(|raw| assert!(fixed(raw).cdf().unwrap() <= ONE_RAW));
}

// === Monotonicity ===

#[test]
fun monotonic_on_grid() {
    // 64-point grid across [0, 6.3]. Strict monotonicity across the saturated
    // region degenerates to equality; both are accepted.
    let n: u64 = 64;
    let step = MAX_Z_RAW / ((n - 1) as u128);
    let mut prev: u128 = HALF_RAW; // cdf at z = 0 is exactly 0.5
    n.do!(|i| {
        let curr = fixed((i as u128) * step).cdf().unwrap();
        assert!(curr >= prev);
        prev = curr;
    });
}

// === Determinism ===

#[test]
fun cdf_is_deterministic() {
    let z = fixed(SCALE);
    let a = z.cdf().unwrap();
    let b = z.cdf().unwrap();
    let c = z.cdf().unwrap();
    assert_eq!(a, b);
    assert_eq!(b, c);
}

// === Cross-type equivalence with SD29x9 ===

#[test]
fun matches_sd29x9_cdf_on_positives() {
    // Verifies that `UD30x9::cdf(z)` and `SD29x9::cdf(z.into_SD29x9())` produce
    // the same raw probability for every positive `z`, exercising the public
    // `into_SD29x9` conversion. Both paths route through the same
    // `cdf::cdf_nonneg_raw` helper, so the results must agree bit-for-bit.
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
        let via_unsigned = fixed(raw).cdf().unwrap();
        let via_signed = fixed(raw).into_SD29x9().cdf().unwrap();
        assert_eq!(via_unsigned, via_signed);
    });
}

// === Method dispatch ===

#[test]
fun method_dispatch_unsigned() {
    // `z.cdf()` on a UD30x9 must resolve to ud30x9_base::cdf.
    let z = fixed(SCALE);
    let via_method = z.cdf();
    let via_function = ud30x9_base::cdf(z);
    assert_eq!(via_method, via_function);
}

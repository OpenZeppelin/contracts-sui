module openzeppelin_fp_math::example_zscore_tests;

use openzeppelin_fp_math::example_zscore;
use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_convert;
use std::unit_test::assert_eq;

// === Constants ===

/// The shared `SD29x9` / `UD30x9` raw scale (`10^9`): one whole unit.
const SCALE: u128 = 1_000_000_000;

/// `Φ(0) = 0.5` at the raw scale. The library special-cases `z = 0`, so this
/// is bit-exact and pinned with `assert_eq!` (NOT a tolerance check).
const HALF_RAW: u128 = 500_000_000;

/// Textbook standard-normal values, the way they appear in a statistics table:
/// `Φ(1) ≈ 0.8413` and `Φ(-1) ≈ 0.1587`. These are approximations of the true
/// CDF, so the relevant asserts are tolerance-based per the styleguide.
const PHI_1_RAW: u128 = 841_300_000; // 0.8413
const PHI_NEG_1_RAW: u128 = 158_700_000; // 0.1587

/// Tolerance of `10^-4` (`100_000` raw units) for the CDF approximation
/// checks. Comfortably covers the gap between the rounded textbook value and
/// the library's higher-precision result while still being a tight bound.
const TOLERANCE: u128 = 100_000;

// === Helpers ===

// Assert that `actual` is within `TOLERANCE` of `expected` at the raw scale.
// Tolerance asserts are the styleguide-sanctioned form for CDF approximations.
fun assert_within(actual: u128, expected: u128) {
    let diff = if (actual >= expected) actual - expected else expected - actual;
    assert!(diff <= TOLERANCE);
}

// A profile with mean = 10.0 and stddev = 5.0. Chosen so that z-scores come
// out as clean whole numbers, letting the arithmetic asserts be bit-exact.
fun profile_10_5(): example_zscore::RiskProfile {
    let mean = sd29x9_convert::from_u64(10, false);
    let stddev = sd29x9_convert::from_u64(5, false);
    example_zscore::new(mean, stddev)
}

// === Construction ===

#[test]
fun new_stores_mean_and_stddev() {
    let profile = profile_10_5();
    // Exact: whole-number conversions are lossless, so pin the raw bits.
    assert_eq!(profile.mean().unwrap(), 10 * SCALE);
    assert_eq!(profile.stddev().unwrap(), 5 * SCALE);
}

#[test]
fun new_accepts_a_negative_mean() {
    // A distribution centered below zero (e.g. an asset with negative expected
    // return) is valid. The negative is built with the sign-flag constructor.
    let mean = sd29x9_convert::from_u64(3, true); // -3.0
    let stddev = sd29x9_convert::from_u64(2, false);
    let profile = example_zscore::new(mean, stddev);

    assert!(profile.mean().is_negative());
    let (whole, neg) = profile.mean().to_parts_trunc();
    assert_eq!(whole, 3);
    assert!(neg);
}

// === z-score arithmetic (exact) ===

#[test]
fun z_score_above_mean_is_positive_and_exact() {
    let profile = profile_10_5();
    // value = 20.0: z = (20 - 10) / 5 = 2.0 exactly.
    let z = profile.z_score(sd29x9_convert::from_u64(20, false));
    assert!(!z.is_negative());
    assert_eq!(z.unwrap(), 2 * SCALE);
}

#[test]
fun z_score_below_mean_is_negative_and_exact() {
    let profile = profile_10_5();
    // value = 5.0: z = (5 - 10) / 5 = -1.0 exactly. `sub` yields a negative
    // deviation; `div` by a positive stddev preserves the sign.
    let z = profile.z_score(sd29x9_convert::from_u64(5, false));

    // Sign handling, verified explicitly.
    assert!(z.is_negative());

    // -1.0 == negate(1.0): the negated whole value is bit-identical.
    let neg_one = sd29x9_convert::from_u64(1, false).negate();
    assert!(z.eq(neg_one));

    // And its magnitude is exactly 1.0.
    let (whole, neg) = z.to_parts_trunc();
    assert_eq!(whole, 1);
    assert!(neg);
}

// === CDF integration (exact at 0, tolerance elsewhere) ===

#[test]
fun probability_at_mean_is_one_half_exact() {
    let profile = profile_10_5();
    // value == mean => z = 0 => Φ(0) = 0.5, which the library returns exactly.
    let p = profile.probability_below(sd29x9_convert::from_u64(10, false));
    assert_eq!(p.unwrap(), HALF_RAW);
}

#[test]
fun probability_one_sigma_above_matches_phi_of_one() {
    let profile = profile_10_5();
    // value = 15.0 => z = +1.0 => Φ(1) ≈ 0.8413 (left tail). Approximation:
    // tolerance assert, not exact.
    let p = profile.probability_below(sd29x9_convert::from_u64(15, false));
    assert_within(p.unwrap(), PHI_1_RAW);
}

#[test]
fun probability_one_sigma_below_matches_phi_of_minus_one() {
    let profile = profile_10_5();
    // value = 5.0 => z = -1.0 => Φ(-1) ≈ 0.1587 (left tail of a NEGATIVE
    // z-score). This is the signed path: a negative z fed into the CDF.
    let p = profile.probability_below(sd29x9_convert::from_u64(5, false));
    assert_within(p.unwrap(), PHI_NEG_1_RAW);
}

#[test]
fun left_and_right_tails_sum_to_exactly_one() {
    let profile = profile_10_5();
    let threshold = sd29x9_convert::from_u64(13, false); // z = 0.6, arbitrary

    let below = profile.probability_below(threshold); // Φ(z)
    let above = profile.probability_above(threshold); // Φ(-z) = 1 - Φ(z)

    // The library guarantees Φ(z) + Φ(-z) == 1 bit-exactly, so this is an
    // EXACT assert even though the individual values are approximations.
    assert_eq!(below.add(above).unwrap(), SCALE);
}

// === Sign classification + cross-type conversion ===

#[test]
fun is_downside_flags_values_below_the_mean() {
    let profile = profile_10_5();
    assert!(profile.is_downside(sd29x9_convert::from_u64(9, false))); // below
    assert!(!profile.is_downside(sd29x9_convert::from_u64(10, false))); // at mean
    assert!(!profile.is_downside(sd29x9_convert::from_u64(11, false))); // above
}

#[test]
fun probability_narrows_to_unsigned_ud30x9() {
    let profile = profile_10_5();
    // A probability is non-negative, so the fallible cross-type conversion
    // always succeeds and round-trips bit-for-bit.
    let p = profile.probability_below(sd29x9_convert::from_u64(10, false));
    let narrowed = example_zscore::probability_as_ud30x9(p);
    assert!(narrowed.is_some());
    assert_eq!(narrowed.destroy_some().unwrap(), p.unwrap());
}

#[test]
fun negative_value_cannot_narrow_to_ud30x9() {
    // try_into_UD30x9 returns none on a negative input: demonstrates the safe,
    // non-aborting narrowing on the impossible-for-a-probability negative case.
    let negative = sd29x9_convert::from_u64(1, true); // -1.0
    let narrowed = example_zscore::probability_as_ud30x9(negative);
    assert!(narrowed.is_none());
}

#[test]
fun from_signed_whole_builds_both_signs() {
    let pos = example_zscore::from_signed_whole(7, false);
    let neg = example_zscore::from_signed_whole(7, true);
    assert!(!pos.is_negative());
    assert!(neg.is_negative());
    // Same magnitude, opposite sign: neg == negate(pos).
    assert!(neg.eq(pos.negate()));
}

// === Expected failures ===

#[test, expected_failure(abort_code = example_zscore::ENonPositiveStdDev)]
fun new_rejects_zero_stddev() {
    let mean = sd29x9_convert::from_u64(10, false);
    let stddev = sd29x9::zero();
    // Aborts: a zero spread is not a valid distribution.
    example_zscore::new(mean, stddev);
    abort
}

#[test, expected_failure(abort_code = example_zscore::ENonPositiveStdDev)]
fun new_rejects_negative_stddev() {
    let mean = sd29x9_convert::from_u64(10, false);
    let stddev = sd29x9_convert::from_u64(5, true); // -5.0
    // Aborts: a negative spread would invert the z-score sign.
    example_zscore::new(mean, stddev);
    abort
}

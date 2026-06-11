/// Standard-normal CDF Φ central-domain evaluator.
///
/// Consumes the AAA-rational coefficients from `cdf_coefficients` and the
/// generic sign-magnitude / Horner primitives from `horner`. The public typed
/// APIs live in `sd29x9_base::cdf` and `ud30x9_base::cdf`, which call
/// `cdf_nonneg_raw` here.
///
/// Forward-compat: `pdf` and `inverse_cdf` get their own sibling modules
/// (`pdf.move`, `inverse_cdf.move`), each importing only its own coefficient
/// table and reusing `horner` unchanged.
module openzeppelin_fp_math::cdf;

use openzeppelin_fp_math::cdf_coefficients;
use openzeppelin_fp_math::common;
use openzeppelin_fp_math::horner;
use openzeppelin_math::rounding;
use openzeppelin_math::u256;

// === Errors ===

/// Numerator polynomial returned a negative value on the central domain
#[error(code = 0)]
const EInternalNumNegative: vector<u8> =
    "CDF numerator polynomial returned a negative value on the central domain";

/// Denominator polynomial returned a non-positive value on the central domain
#[error(code = 1)]
const EInternalDenNonPositive: vector<u8> =
    "CDF denominator polynomial returned a non-positive value on the central domain";

// === Constants ===

/// `Φ(0)` at the `UD30x9` raw scale (`10^9`).
const HALF_RAW: u128 = 500_000_000;

/// `Φ(+∞)` upper bound at the `UD30x9` raw scale (`10^9`).
const ONE_RAW: u128 = 1_000_000_000;

// === CDF Central-Domain Helper ===

/// Self-contained Φ evaluator on `|z|_raw` at the `UD30x9` scale (`10^9`).
///
/// Behavior:
/// - Saturates to `ONE_RAW` (`10^9`) for `z_raw ≥ cdf_coefficients::max_z_raw()`
///   (`|z| ≥ 6.3`).
/// - Returns `HALF_RAW` (`5 × 10^8`) exactly for `z_raw == 0` (`Φ(0)`).
/// - Otherwise evaluates the AAA rational `N(z) / D(z)` from
///   `cdf_coefficients` via Horner at WAD scale and rounds the ratio back to
///   `UD30x9` scale in a single half-up step, clamping any last-ULP overshoot
///   to `ONE_RAW`.
///
/// Returned value is in `[HALF_RAW, ONE_RAW]`. Caller is responsible for
/// sign-flipping (`ONE_RAW - phi`) when the original input was negative.
public(package) fun cdf_nonneg_raw(z_raw: u128): u128 {
    if (z_raw >= cdf_coefficients::max_z_raw()) return ONE_RAW;
    if (z_raw == 0) return HALF_RAW; // Φ(0) special case

    eval_rational(
        z_raw,
        cdf_coefficients::cdf_num_mags(),
        cdf_coefficients::cdf_num_negs(),
        cdf_coefficients::cdf_den_mags(),
        cdf_coefficients::cdf_den_negs(),
    )
}

/// Evaluate `N(z) / D(z)` for a central-domain `z_raw` (`0 < z_raw < max_z`),
/// given the coefficient tables. Split out from `cdf_nonneg_raw` so its
/// integrity asserts can be exercised with injected coefficients in tests.
fun eval_rational(
    z_raw: u128,
    num_mags: vector<u128>,
    num_negs: vector<bool>,
    den_mags: vector<u128>,
    den_negs: vector<bool>,
): u128 {
    // Promote |z| from UD30x9 (10^9) to WAD (10^18).
    let z_wad = (z_raw as u256) * (common::scale_u256!());
    let z_signed = horner::from_unsigned(z_wad);

    let n = horner::horner_eval!(z_signed, num_mags.length(), |i| (num_mags[i], num_negs[i]));
    let d = horner::horner_eval!(z_signed, den_mags.length(), |i| (den_mags[i], den_negs[i]));

    // Integrity guards on the AAA fit. A corrupted coefficient table would
    // surface here rather than silently producing a garbled output.
    assert!(!horner::is_neg(&n), EInternalNumNegative);
    assert!(!horner::is_neg(&d) && horner::mag(&d) > 0, EInternalDenNonPositive);

    // Final ratio: N(z) / D(z) at WAD, cast to UD30x9 (10^9) with a single
    // nearest-rounding step. The result is bounded by ~10^29 on the central
    // domain — well under u256 capacity, so `destroy_some` cannot abort.
    let phi_raw_u256 = u256::mul_div(
        horner::mag(&n),
        common::scale_u256!(),
        horner::mag(&d),
        rounding::nearest(),
    ).destroy_some();
    // Last-ULP overshoot guard: rounding can produce ONE_RAW + 1 raw at z just
    // below max_z; clamp to keep the output a valid probability.
    if (phi_raw_u256 > (ONE_RAW as u256)) ONE_RAW
    else (phi_raw_u256 as u128)
}

/// Test-only window onto `eval_rational` so the `EInternalNumNegative` /
/// `EInternalDenNonPositive` integrity asserts — unreachable through the public
/// API with the committed coefficients — can be driven with crafted tables.
#[test_only]
public(package) fun eval_rational_for_test(
    z_raw: u128,
    num_mags: vector<u128>,
    num_negs: vector<bool>,
    den_mags: vector<u128>,
    den_negs: vector<bool>,
): u128 {
    eval_rational(z_raw, num_mags, num_negs, den_mags, den_negs)
}

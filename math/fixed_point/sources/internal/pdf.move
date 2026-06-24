/// Standard-normal PDF φ central-domain evaluator.
///
/// Consumes the AAA-rational coefficients from `pdf_coefficients` and the
/// generic sign-magnitude / Horner primitives from `horner`. The public typed
/// APIs live in `sd29x9_base::pdf` and `ud30x9_base::pdf`, which call
/// `pdf_nonneg_raw` here.
///
/// φ is even (φ(-z) = φ(z)), so the signed API evaluates this on `|z|` with no
/// reflection. Unlike `cdf`, there is no `z = 0` special case (with `D(0) = 1`
/// the rational already returns the exact peak `φ(0)`) and no overshoot clamp
/// (φ has no round upper bound to pin to).
module openzeppelin_fp_math::pdf;

use openzeppelin_fp_math::common;
use openzeppelin_fp_math::horner;
use openzeppelin_fp_math::pdf_coefficients;
use openzeppelin_math::rounding;
use openzeppelin_math::u256;

// === Errors ===

/// Numerator polynomial returned a negative value on the central domain.
#[error(code = 0)]
const EInternalNumNegative: vector<u8> =
    "PDF numerator polynomial returned a negative value on the central domain";

/// Denominator polynomial returned a non-positive value on the central domain.
#[error(code = 1)]
const EInternalDenNonPositive: vector<u8> =
    "PDF denominator polynomial returned a non-positive value on the central domain";

// === Package Functions ===

// === PDF Central-Domain Helper ===

/// Self-contained φ evaluator on `|z|_raw` at the `UD30x9` scale (`10^9`).
///
/// Behavior:
/// - Saturates to `0` for `z_raw ≥ pdf_coefficients::max_z_raw()` (`|z| ≥ 6.5`),
///   where `φ` has already decayed below the `10^-9` output resolution.
/// - Otherwise evaluates the AAA rational `N(z) / D(z)` from `pdf_coefficients`
///   via Horner at WAD scale and rounds the ratio back to `UD30x9` scale in a
///   single half-up step.
///
/// Returned value is in `[0, φ(0)]` (peak `398_942_280`). The result depends
/// only on `|z|`, so the signed caller reuses it directly for negative inputs
/// (φ is even) - no reflection is needed.
public(package) fun pdf_nonneg_raw(z_raw: u128): u128 {
    if (z_raw >= pdf_coefficients::max_z_raw()) return 0;

    eval_rational(
        z_raw,
        pdf_coefficients::pdf_num_mags(),
        pdf_coefficients::pdf_num_negs(),
        pdf_coefficients::pdf_den_mags(),
        pdf_coefficients::pdf_den_negs(),
    )
}

// === Private Functions ===

/// Evaluate `N(z) / D(z)` for a central-domain `z_raw` (`0 ≤ z_raw < max_z`),
/// given the coefficient tables. Split out from `pdf_nonneg_raw` so its
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
    assert!(!n.is_neg(), EInternalNumNegative);
    assert!(!d.is_neg() && d.mag() > 0, EInternalDenNonPositive);

    // Final ratio: N(z) / D(z) at WAD, cast to UD30x9 (10^9) with a single
    // nearest-rounding step. On the central domain (degree-10 Horner at
    // |z| ≤ 6.5) the peak intermediate is ~3 × 10^38, far below u256 capacity
    // (~1.16 × 10^77), so `destroy_some` cannot abort. The peak `φ(0)` is well
    // under `1.0`, so no overshoot clamp is needed.
    let pdf_raw_u256 = u256::mul_div(
        n.mag(),
        common::scale_u256!(),
        d.mag(),
        rounding::nearest(),
    ).destroy_some();
    pdf_raw_u256 as u128
}

// === Test-Only Helpers ===

/// Test-only window onto `eval_rational` so the `EInternalNumNegative` /
/// `EInternalDenNonPositive` integrity asserts - unreachable through the public
/// API with the committed coefficients - can be driven with crafted tables.
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

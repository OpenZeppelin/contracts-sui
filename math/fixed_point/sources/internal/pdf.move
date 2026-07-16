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

use openzeppelin_fp_math::horner;
use openzeppelin_fp_math::pdf_coefficients;

// === Constants ===

/// Internal Horner-accumulation scale (`10^36`). An order of magnitude finer than
/// the user-facing `10^9`: it keeps per-step floor-truncation noise far below the
/// tail's true per-step decrement, so the quantized `φ` is strictly monotone
/// non-increasing in `|z|` (a coarser scale leaves 1-ULP inversions in the far
/// tail). Free at runtime - the arithmetic already runs in `u256` - and the
/// rescaled coefficients still fit `u128`. The PDF's degree-10 rational leaves
/// ~8 bits of headroom under `2^256` - tighter than the CDF's ~10 - guarded by
/// the codegen overflow gate.
const WAD: u256 = 1_000_000_000_000_000_000_000_000_000_000_000_000; // 10^36

// === Package Functions ===

// === PDF Central-Domain Helper ===

/// Self-contained φ evaluator on `|z|_raw` at the `UD30x9` scale (`10^9`).
///
/// Behavior:
/// - Saturates to `0` for `z_raw ≥ pdf_coefficients::max_z_raw()`
///   (`|z| ≥ 6.402729806`), where `φ` has already decayed below the `10^-9`
///   output resolution.
/// - Otherwise evaluates the AAA rational `N(z) / D(z)` from `pdf_coefficients`
///   via Horner at WAD scale and rounds the ratio back to `UD30x9` scale in a
///   single half-up step.
///
/// Returned value is in `[0, φ(0)]` (peak `398_942_280`). The result depends
/// only on `|z|`, so the signed caller reuses it directly for negative inputs
/// (φ is even) - no reflection is needed.
///
/// #### Aborts
/// - `EInternalNumNegative` if the numerator polynomial evaluates to a negative
///   value (defense-in-depth against a corrupted regenerated coefficient table;
///   unreachable with the committed coefficient tables).
/// - `EInternalDenNonPositive` if the denominator polynomial evaluates to a
///   non-positive value (defense-in-depth against a corrupted regenerated
///   coefficient table; unreachable with the committed coefficient tables).
/// - A vector index out of bounds abort if a magnitude table and its paired sign
///   table have different lengths (unreachable with the committed coefficient
///   tables).
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

/// Evaluate `N(z) / D(z)` for a central-domain `z_raw` (`0 ≤ z_raw < max_z`)
/// via the shared `horner::eval_rational` evaluator at `WAD` scale. The peak
/// `φ(0)` is well under `1.0`, so no overshoot clamp is needed and the ratio
/// always fits `u128`. Split out from `pdf_nonneg_raw` so the path can be
/// exercised with injected coefficients in tests.
///
/// #### Aborts
/// - `horner::EInternalNumNegative` if the numerator polynomial evaluates to a
///   negative value (defense-in-depth against a corrupted regenerated
///   coefficient table; unreachable with the committed coefficient tables).
/// - `horner::EInternalDenNonPositive` if the denominator polynomial evaluates
///   to a non-positive value (defense-in-depth against a corrupted regenerated
///   coefficient table; unreachable with the committed coefficient tables).
/// - A vector index out of bounds abort if a magnitude table and its paired sign
///   table have different lengths (unreachable with the committed coefficient
///   tables).
fun eval_rational(
    z_raw: u128,
    num_mags: vector<u128>,
    num_negs: vector<bool>,
    den_mags: vector<u128>,
    den_negs: vector<bool>,
): u128 {
    horner::eval_rational(z_raw, num_mags, num_negs, den_mags, den_negs, WAD) as u128
}

// === Test-Only Helpers ===

/// Test-only window onto `eval_rational` so the shared integrity asserts
/// (`horner::EInternalNumNegative` / `horner::EInternalDenNonPositive`) -
/// unreachable through the public API with the committed coefficients - can be
/// driven with crafted tables.
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

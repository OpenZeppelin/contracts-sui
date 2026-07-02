/// Standard-normal quantile (inverse CDF) `Φ⁻¹` upper-half evaluator.
///
/// Consumes the two-region AAA-rational coefficients from
/// `inverse_cdf_coefficients` and the generic sign-magnitude / Horner primitives
/// from `horner`. The public typed APIs live in `sd29x9_base::inverse_cdf` and
/// `ud30x9_base::inverse_cdf`, which call `inverse_cdf_upper_raw` here and (for
/// the signed variant) reflect `p < 0.5` via `Φ⁻¹(p) = -Φ⁻¹(1 - p)`.
///
/// A single rational in `p` cannot be evaluated in fixed point near `p = 1` (its
/// numerator and denominator both collapse toward zero and underflow the WAD
/// scale). So the upper half is split, exactly like Acklam/AS241:
/// - `p ∈ [0.5, threshold)`: a rational in `u = p - 0.5` (`central_*` table).
/// - `p ∈ [threshold, 1)`: a rational in `r = sqrt(-2 * ln(1 - p))` (`tail_*`
///   table); the change of variable linearizes the tail's growth and keeps the
///   denominator well away from zero.
///
/// The tail variable is built from the internal `common::raw_log2` /
/// `apply_log2_factor` and `u256::sqrt` kernels - never the typed
/// `sd29x9_base::ln`/`sqrt` - so this module stays strictly below the base
/// modules in the dependency graph (they depend on it).
module openzeppelin_fp_math::inverse_cdf;

use openzeppelin_fp_math::common;
use openzeppelin_fp_math::horner;
use openzeppelin_fp_math::inverse_cdf_coefficients;
use openzeppelin_math::rounding;
use openzeppelin_math::u256;

// === Errors ===

/// Numerator polynomial returned a negative value on the domain.
#[error(code = 0)]
const EInternalNumNegative: vector<u8> =
    "Inverse-CDF numerator polynomial returned a negative value on the domain";

/// Denominator polynomial returned a non-positive value on the domain.
#[error(code = 1)]
const EInternalDenNonPositive: vector<u8> =
    "Inverse-CDF denominator polynomial returned a non-positive value on the domain";

// === Constants ===

/// `Φ⁻¹(0.5) = 0`: the input probability at the `UD30x9` raw scale (`10^9`) whose
/// quantile is exactly zero, and the lower bound of the representable upper half.
const HALF_RAW: u128 = 500_000_000;

/// `p = 1.0` at the `UD30x9` raw scale (`10^9`): the saturation trigger, where
/// `Φ⁻¹(1) = +∞` is clamped to `MAX_Z`.
const ONE_RAW: u128 = 1_000_000_000;

// === Package Functions ===

// === Inverse-CDF Upper-Half Helper ===

/// Self-contained `Φ⁻¹` evaluator on the upper half: `p_raw ∈ [HALF_RAW, ONE_RAW]`
/// at the `UD30x9` scale (`10^9`), returning `z_raw ≥ 0`.
///
/// Behavior:
/// - Saturates to `inverse_cdf_coefficients::max_z_raw()` for `p_raw ≥ ONE_RAW`
///   (`Φ⁻¹(1) = +∞`, clamped). Guarded first, before the tail transform, because
///   `ln(1 - 1) = ln(0)` is undefined.
/// - Returns `0` exactly for `p_raw == HALF_RAW` (`Φ⁻¹(0.5)`).
/// - Otherwise evaluates the central rational in `u = p - 0.5` (for
///   `p < central_threshold`) or the tail rational in `r = sqrt(-2 ln(1 - p))`
///   (for `p ≥ central_threshold`) via Horner at WAD scale, rounding the ratio
///   back to `10^9` in a single nearest step.
///
/// Returned value is in `[0, MAX_Z_RAW]`. Caller handles `p < 0.5` via reflection
/// (`Φ⁻¹(p) = -Φ⁻¹(1 - p)`) and rejects out-of-range probabilities.
public(package) fun inverse_cdf_upper_raw(p_raw: u128): u128 {
    if (p_raw >= ONE_RAW) return inverse_cdf_coefficients::max_z_raw(); // Φ⁻¹(1) saturates
    if (p_raw == HALF_RAW) return 0; // Φ⁻¹(0.5) special case

    if (p_raw < inverse_cdf_coefficients::central_threshold_raw()) {
        eval_rational(
            p_raw - HALF_RAW, // u = p - 0.5, exact
            inverse_cdf_coefficients::central_num_mags(),
            inverse_cdf_coefficients::central_num_negs(),
            inverse_cdf_coefficients::central_den_mags(),
            inverse_cdf_coefficients::central_den_negs(),
        )
    } else {
        eval_rational(
            tail_variable_raw(p_raw), // r = sqrt(-2 * ln(1 - p))
            inverse_cdf_coefficients::tail_num_mags(),
            inverse_cdf_coefficients::tail_num_negs(),
            inverse_cdf_coefficients::tail_den_mags(),
            inverse_cdf_coefficients::tail_den_negs(),
        )
    }
}

// === Private Functions ===

/// The tail change of variable `r = sqrt(-2 * ln(1 - p))` at the `10^9` scale.
///
/// `1 - p` is computed exactly as `SCALE - p_raw` and lies in `(0, 1)` on the
/// tail domain, so `common::raw_log2` takes its sub-one branch and returns
/// `|log2(1 - p)|` at `10^18`; `apply_log2_factor` scales that by `ln 2` to
/// `|ln(1 - p)|` at `10^9`. Doubling yields `-2 * ln(1 - p)` (positive), and
/// `u256::sqrt` with the `* SCALE` precision lift (as in `ud30x9_base::sqrt`)
/// returns `r` at the `10^9` scale, truncated down.
fun tail_variable_raw(p_raw: u128): u128 {
    let complement_raw = common::scale!() - p_raw; // 1 - p at 10^9, exact, in (0, 1)
    let (_, log2_mag_e18) = common::raw_log2(complement_raw); // |log2(1 - p)| at 10^18
    let ln_mag_raw = common::apply_log2_factor(log2_mag_e18, common::ln2_e18!()); // |ln(1 - p)| at 10^9
    let arg_raw = 2 * ln_mag_raw; // -2 * ln(1 - p) at 10^9 (positive)
    u256::sqrt((arg_raw as u256) * common::scale_u256!(), rounding::down()) as u128
}

/// Evaluate `N(x) / D(x)` for a transformed argument `x_raw` (`u` or `r`) at the
/// `10^9` scale, given a region's coefficient tables. Split out from
/// `inverse_cdf_upper_raw` so its integrity asserts can be exercised with
/// injected coefficients in tests, mirroring `cdf::eval_rational`.
fun eval_rational(
    x_raw: u128,
    num_mags: vector<u128>,
    num_negs: vector<bool>,
    den_mags: vector<u128>,
    den_negs: vector<bool>,
): u128 {
    // Promote the transformed argument from 10^9 to WAD (10^18).
    let x_wad = (x_raw as u256) * (common::scale_u256!());
    let x_signed = horner::from_unsigned(x_wad);

    let n = horner::horner_eval!(x_signed, num_mags.length(), |i| (num_mags[i], num_negs[i]));
    let d = horner::horner_eval!(x_signed, den_mags.length(), |i| (den_mags[i], den_negs[i]));

    // Integrity guards on the AAA fit. On the upper half `z ≥ 0`, so `N ≥ 0` and
    // `D > 0`; a corrupted coefficient table would surface here rather than
    // silently producing a garbled output. The `mul_wad` u256 precondition is
    // re-established for these coefficients and domains: the peak Horner
    // intermediate is ~1.7 × 10^39 (tail region), ~38 orders below `u256::max`.
    assert!(!n.is_neg(), EInternalNumNegative);
    assert!(!d.is_neg() && d.mag() > 0, EInternalDenNonPositive);

    // Final ratio: z = N(x) / D(x) at WAD, cast to 10^9 with a single
    // nearest-rounding step.
    let z_raw_u256 = u256::mul_div(
        n.mag(),
        common::scale_u256!(),
        d.mag(),
        rounding::nearest(),
    ).destroy_some();
    // Defense-in-depth clamp to the representable maximum, mirroring cdf's
    // `ONE_RAW` clamp. The committed fit peaks at `z ≈ 5.998 < MAX_Z`, so this
    // never fires with the shipped coefficients.
    let max_z_raw = inverse_cdf_coefficients::max_z_raw();
    if (z_raw_u256 > (max_z_raw as u256)) max_z_raw
    else (z_raw_u256 as u128)
}

// === Test-Only Helpers ===

/// Test-only window onto `eval_rational` so the `EInternalNumNegative` /
/// `EInternalDenNonPositive` integrity asserts - unreachable through the public
/// API with the committed coefficients - can be driven with crafted tables.
#[test_only]
public(package) fun eval_rational_for_test(
    x_raw: u128,
    num_mags: vector<u128>,
    num_negs: vector<bool>,
    den_mags: vector<u128>,
    den_negs: vector<bool>,
): u128 {
    eval_rational(x_raw, num_mags, num_negs, den_mags, den_negs)
}

/// Test-only window onto `tail_variable_raw` so the on-chain tail change of
/// variable `r = sqrt(-2 * ln(1 - p))` - composed from `common::raw_log2`,
/// `apply_log2_factor` and `u256::sqrt` - can be asserted bit-for-bit against the
/// offline integer mirror in `scripts/gaussian_codegen/shared/arithmetic.py`
/// (`tail_r_raw`), which the codegen validator relies on. `r` depends only on
/// those fixed kernels, not on the fit coefficients.
#[test_only]
public(package) fun tail_variable_raw_for_test(p_raw: u128): u128 {
    tail_variable_raw(p_raw)
}

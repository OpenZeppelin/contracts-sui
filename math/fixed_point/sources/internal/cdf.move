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
use openzeppelin_fp_math::horner;

// === Constants ===

/// Internal Horner-accumulation scale (`10^36`). An order of magnitude finer than
/// the user-facing `10^9`: it keeps per-step floor-truncation noise far below the
/// tail's true per-step increment, so the quantized `Φ` is strictly monotone (a
/// coarser scale leaves 1-ULP inversions in the far tail). Free at runtime - the
/// arithmetic already runs in `u256` - and the rescaled coefficients still fit
/// `u128`.
const WAD: u256 = 1_000_000_000_000_000_000_000_000_000_000_000_000; // 10^36

/// `Φ(0)` at the `UD30x9` raw scale (`10^9`).
const HALF_RAW: u128 = 500_000_000;

/// `Φ(+∞)` upper bound at the `UD30x9` raw scale (`10^9`).
const ONE_RAW: u128 = 1_000_000_000;

// === Package Functions ===

// === Accessors ===

/// `Φ(0)` at the raw scale - the lower bound of `cdf_nonneg_raw`'s return
/// range. Exposed so callers can check the `phi ≥ 0.5` contract against the
/// same constant the evaluator uses.
public(package) fun half_raw(): u128 { HALF_RAW }

// === CDF Central-Domain Helper ===

/// Self-contained Φ evaluator on `|z|_raw` at the `UD30x9` scale (`10^9`).
///
/// Behavior:
/// - Saturates to `ONE_RAW` (`10^9`) for `z_raw ≥ cdf_coefficients::max_z_raw()`
///   (`|z| ≥ 6.109410205`).
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

// === Private Functions ===

/// Evaluate `N(z) / D(z)` for a central-domain `z_raw` (`0 < z_raw < max_z`)
/// via the shared `horner::eval_rational` evaluator at `WAD` scale, then apply
/// the CDF-specific overshoot clamp. Split out from `cdf_nonneg_raw` so the
/// clamp can be exercised with injected coefficients in tests.
fun eval_rational(
    z_raw: u128,
    num_mags: vector<u128>,
    num_negs: vector<bool>,
    den_mags: vector<u128>,
    den_negs: vector<bool>,
): u128 {
    let phi_raw_u256 = horner::eval_rational(z_raw, num_mags, num_negs, den_mags, den_negs, WAD);
    // Last-ULP overshoot guard: rounding can produce ONE_RAW + 1 raw at z just
    // below max_z; clamp to keep the output a valid probability.
    if (phi_raw_u256 > (ONE_RAW as u256)) ONE_RAW
    else (phi_raw_u256 as u128)
}

// === Test-Only Helpers ===

/// Test-only window onto `eval_rational` so the shared integrity asserts
/// (`horner::EInternalNumNegative` / `horner::EInternalDenNonPositive`) and the
/// overshoot clamp - unreachable through the public API with the committed
/// coefficients - can be driven with crafted tables.
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

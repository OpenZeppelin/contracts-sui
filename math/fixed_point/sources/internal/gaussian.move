/// Internal helpers for the gaussian function family (`cdf`, future `pdf`,
/// `inverse_cdf`). All exports are `public(package)`; consumers are the
/// `sd29x9_base` and `ud30x9_base` modules that expose the typed public APIs.
///
/// Two concerns live here:
/// - **Sign-magnitude `u256` arithmetic at WAD scale**: a `SignedScaled256`
///   value, sign-aware add/multiply, and the `horner_eval!` macro that
///   evaluates a polynomial via Horner's method given a `(u128, bool)`
///   coefficient accessor. Plus `mul_div_nearest_u256` for the final
///   WAD→UD30x9 ratio with half-up rounding.
/// - **The CDF central-domain helper** `cdf_nonneg_raw(z_raw: u128): u128`,
///   self-contained over the full input domain: saturates to `ONE_RAW` for
///   `z_raw ≥ MAX_Z_RAW`, special-cases `Φ(0)` to `HALF_RAW`, otherwise
///   evaluates the AAA rational from `cdf_coefficients`.
module openzeppelin_fp_math::gaussian;

use openzeppelin_fp_math::cdf_coefficients;
use openzeppelin_fp_math::common;

// === Errors ===

/// Polynomial must have at least one coefficient
#[error(code = 0)]
const EEmptyPolynomial: vector<u8> = "Polynomial must have at least one coefficient";

/// Numerator polynomial returned a negative value on the central domain
#[error(code = 1)]
const EInternalNumNegative: vector<u8> = "CDF numerator polynomial returned a negative value on the central domain";

/// Denominator polynomial returned a non-positive value on the central domain
#[error(code = 2)]
const EInternalDenNonPositive: vector<u8> = "CDF denominator polynomial returned a non-positive value on the central domain";

// === Constants ===

const WAD_U256: u256 = 1_000_000_000_000_000_000;

/// Saturation threshold `|z|` at the `UD30x9` raw scale (`10^9`). Inputs whose
/// magnitude meets or exceeds this value short-circuit to `ONE_RAW` without
/// consulting the rational.
const MAX_Z_RAW: u128 = 6_300_000_000; // 6.3 × 10^9

/// `Φ(0)` at the `UD30x9` raw scale (`10^9`).
const HALF_RAW: u128 = 500_000_000;

/// `Φ(+∞)` upper bound at the `UD30x9` raw scale (`10^9`).
const ONE_RAW: u128 = 1_000_000_000;

// === Sign-Magnitude Value Type ===

/// Sign-magnitude representation used during Horner accumulation at WAD scale.
///
/// The magnitude is `u256` so that the WAD-scale product `a × b` cannot
/// overflow for any `|z| ≤ MAX_Z_RAW` — the central-domain values stay well
/// below `2^256`. The sign rides as a separate flag because Move lacks signed
/// integer types.
///
/// Visibility note: the type is declared `public` because Move 2024 does not
/// yet support `public(package)` on struct declarations, but it is effectively
/// package-internal: only `public(package)` constructors in this module can
/// produce one, and the abilities deliberately omit `store`/`key` so it cannot
/// be persisted or wrapped in a stored type by an external consumer.
///
/// Convention: zero is always represented canonically as `(mag = 0, neg = false)`.
public struct SignedScaled256 has copy, drop {
    mag: u256,
    neg: bool,
}

// === Constructors ===

/// The neutral additive element.
public(package) fun signed_zero(): SignedScaled256 {
    SignedScaled256 { mag: 0, neg: false }
}

/// Wrap a non-negative WAD-scaled magnitude.
public(package) fun signed_from_unsigned(mag: u256): SignedScaled256 {
    SignedScaled256 { mag, neg: false }
}

/// Wrap a `(u128 magnitude, bool sign)` coefficient encoding, promoting the
/// magnitude to `u256` and canonicalizing zero to `(0, false)`.
public(package) fun signed_from_coeff(mag: u128, neg: bool): SignedScaled256 {
    let mag_u256 = mag as u256;
    SignedScaled256 {
        mag: mag_u256,
        neg: if (mag_u256 == 0) false else neg,
    }
}

// === Accessors ===

public(package) fun mag(x: &SignedScaled256): u256 { x.mag }

public(package) fun is_neg(x: &SignedScaled256): bool { x.neg }

// === Arithmetic ===

/// Sign-magnitude addition.
/// - Same-sign: add magnitudes, keep the sign.
/// - Opposite-sign: subtract the smaller from the larger, inherit the larger's sign.
/// - Exact cancellation: return canonical zero.
public(package) fun signed_add(a: SignedScaled256, b: SignedScaled256): SignedScaled256 {
    if (a.mag == 0) return b;
    if (b.mag == 0) return a;
    if (a.neg == b.neg) {
        SignedScaled256 { mag: a.mag + b.mag, neg: a.neg }
    } else if (a.mag > b.mag) {
        SignedScaled256 { mag: a.mag - b.mag, neg: a.neg }
    } else if (b.mag > a.mag) {
        SignedScaled256 { mag: b.mag - a.mag, neg: b.neg }
    } else {
        signed_zero()
    }
}

/// WAD-scaled multiplication: `(a × b) / WAD` with truncation toward zero on
/// the magnitude (equivalent to `mul_div(..., Down)` rounding) and XOR signs.
/// Zero canonicalization ensures any product whose magnitude floors to zero
/// returns canonical zero.
public(package) fun signed_mul_wad(a: SignedScaled256, b: SignedScaled256): SignedScaled256 {
    let mag = (a.mag * b.mag) / WAD_U256;
    let neg = if (mag == 0) false else (a.neg != b.neg);
    SignedScaled256 { mag, neg }
}

// === Final-Ratio Helper ===

/// Compute `(a × b) / d` rounded to the nearest integer, half-up.
///
/// Used by `cdf_nonneg_raw` to cast the WAD-scale rational `N(z) / D(z)` to a
/// `UD30x9`-scale (`10^9`) probability in a single rounding step. Caller
/// guarantees `d > 0` and that the full-width product `a × b` fits in `u256`
/// (verified empirically: worst-case intermediate during CDF evaluation on
/// `[0, 6.3]` is ~`1.4 × 10^38`, well under `u256::max ≈ 1.16 × 10^77`).
///
/// #### Aborts
/// - Aborts if `d == 0`.
public(package) fun mul_div_nearest_u256(a: u256, b: u256, d: u256): u256 {
    let prod = a * b;
    let quot = prod / d;
    let rem = prod - quot * d;
    // Half-up: round when remainder ≥ d - remainder, i.e. 2 × rem ≥ d.
    if (rem * 2 >= d) quot + 1 else quot
}

// === Horner Evaluator ===

/// Helper used by `horner_eval!` so the macro body can preflight the length
/// without referencing a module-private constant from the caller's scope.
public(package) fun assert_polynomial_nonempty(len: u64) {
    assert!(len > 0, EEmptyPolynomial);
}

/// Evaluate the polynomial
///
///   `c[len-1] · z^(len-1) + ... + c[1] · z + c[0]`
///
/// via Horner's method. Coefficients are pulled in *ascending* power order by
/// `$coeff_at`, which returns `(u128 magnitude, bool is_negative)` at WAD
/// scale. The accessor is invoked exactly once per coefficient.
///
/// All arithmetic is sign-magnitude `u256` at WAD; `$z` must already be WAD-scaled.
///
/// #### Aborts
/// - Aborts with `EEmptyPolynomial` if `$len == 0`.
public(package) macro fun horner_eval(
    $z: SignedScaled256,
    $len: u64,
    $coeff_at: |u64| -> (u128, bool),
): SignedScaled256 {
    let z = $z;
    let len = $len;
    openzeppelin_fp_math::gaussian::assert_polynomial_nonempty(len);

    let last = len - 1;
    let (m_last, n_last) = $coeff_at(last);
    let mut acc = openzeppelin_fp_math::gaussian::signed_from_coeff(m_last, n_last);

    let mut i = last;
    while (i > 0) {
        i = i - 1;
        acc = openzeppelin_fp_math::gaussian::signed_mul_wad(acc, z);
        let (m_i, n_i) = $coeff_at(i);
        acc = openzeppelin_fp_math::gaussian::signed_add(
            acc,
            openzeppelin_fp_math::gaussian::signed_from_coeff(m_i, n_i),
        );
    };
    acc
}

// === CDF Central-Domain Helper ===

/// Self-contained Φ evaluator on `|z|_raw` at the `UD30x9` scale (`10^9`).
///
/// Behavior:
/// - Saturates to `ONE_RAW` (`10^9`) for `z_raw ≥ MAX_Z_RAW` (`|z| ≥ 6.3`).
/// - Returns `HALF_RAW` (`5 × 10^8`) bit-exactly for `z_raw == 0` (`Φ(0)`).
/// - Otherwise evaluates the AAA rational `N(z) / D(z)` from
///   `cdf_coefficients` via Horner at WAD scale and rounds the ratio back to
///   `UD30x9` scale in a single half-up step, clamping any last-ULP overshoot
///   to `ONE_RAW`.
///
/// Returned value is in `[HALF_RAW, ONE_RAW]`. Caller is responsible for
/// sign-flipping (`ONE_RAW - phi`) when the original input was negative.
public(package) fun cdf_nonneg_raw(z_raw: u128): u128 {
    if (z_raw >= MAX_Z_RAW) return ONE_RAW;
    if (z_raw == 0) return HALF_RAW; // Φ(0) special case

    // Promote |z| from UD30x9 (10^9) to WAD (10^18).
    let z_wad = (z_raw as u256) * (common::scale_u256!());
    let z_signed: SignedScaled256 = signed_from_unsigned(z_wad);

    // Bind the constant tables once per call so the Horner inner loop indexes
    // local vectors instead of reloading the module constants every iteration.
    let num_mags = cdf_coefficients::cdf_num_mags();
    let num_negs = cdf_coefficients::cdf_num_negs();
    let den_mags = cdf_coefficients::cdf_den_mags();
    let den_negs = cdf_coefficients::cdf_den_negs();

    let n = horner_eval!(z_signed, num_mags.length(), |i| (num_mags[i], num_negs[i]));
    let d = horner_eval!(z_signed, den_mags.length(), |i| (den_mags[i], den_negs[i]));

    // Integrity guards on the AAA fit. A corrupted coefficient table would
    // surface here rather than silently producing a garbled output.
    assert!(!n.neg, EInternalNumNegative);
    assert!(!d.neg && d.mag > 0, EInternalDenNonPositive);

    // Final ratio: N(z) / D(z) at WAD, cast to UD30x9 (10^9) with a single
    // nearest-rounding step. The full-width product `n.mag × 10^9` is bounded
    // by ~10^29 on the central domain — well under u256 capacity.
    let phi_raw_u256 = mul_div_nearest_u256(n.mag, common::scale_u256!(), d.mag);
    // Last-ULP overshoot guard: rounding can produce ONE_RAW + 1 raw at z just
    // below MAX_Z_RAW; clamp to keep the output a valid probability.
    if (phi_raw_u256 > (ONE_RAW as u256)) ONE_RAW else (phi_raw_u256 as u128)
}

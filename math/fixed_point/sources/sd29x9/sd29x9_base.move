/// Base utility functions for the `SD29x9` fixed-point type.
///
/// Tailored to the signed `SD29x9` representation (two's complement stored in `u128` with 9 decimal places).
module openzeppelin_fp_math::sd29x9_base;

use openzeppelin_fp_math::cdf::{cdf_nonneg_raw, half_raw};
use openzeppelin_fp_math::common;
use openzeppelin_fp_math::pdf::pdf_nonneg_raw;
use openzeppelin_fp_math::sd29x9::{SD29x9, from_bits, zero, min, one, two_complement, wrap};
use openzeppelin_fp_math::ud30x9::{Self, UD30x9};
use openzeppelin_math::rounding;
use openzeppelin_math::u256;

// === Errors ===

/// Value overflows `SD29x9` (must fit in 2^127 signed range)
#[error(code = 0)]
const EOverflow: vector<u8> = "Value overflows SD29x9 (must fit in 2^127 signed range)";

/// Value cannot be converted to `UD30x9`
#[error(code = 1)]
const ECannotBeConvertedToUD30x9: vector<u8> = "Value cannot be converted to UD30x9";

/// Divisor must be non-zero
#[error(code = 2)]
const EDivideByZero: vector<u8> = "Divisor must be non-zero";

/// Cannot compute square root of a negative value
#[error(code = 3)]
const ENegativeSqrt: vector<u8> = "Cannot compute square root of a negative value";

/// Logarithm is undefined: input must be strictly positive
#[error(code = 4)]
const ELogUndefined: vector<u8> = "Logarithm is undefined: input must be strictly positive";

/// `cdf_nonneg_raw` returned a value below `Φ(0) = 0.5`, which would make the
/// negative-input sign-flip subtraction `10^9 - phi` produce a result greater
/// than `0.5`. Defense-in-depth against an AAA-fit regression.
#[error(code = 5)]
const EInternalNegSubUnderflow: vector<u8> =
    "CDF sign-flip subtraction underflowed: internal evaluation returned a value below 0.5";

// === Structs ===

/// Sign-magnitude decomposition of a signed fixed-point value.
public struct Components has copy, drop {
    /// Whether the value is negative (`true`) or non-negative (`false`).
    neg: bool,
    /// Absolute value (magnitude) in raw fixed-point units.
    mag: u256,
}

// === Public Functions ===

// === Conversion ===

/// Converts a `SD29x9` value to a `UD30x9` value.
///
/// #### Parameters
/// - `x`: Input `SD29x9` value.
///
/// #### Returns
/// - The `UD30x9` representation of `x`.
///
/// #### Aborts
/// - `ECannotBeConvertedToUD30x9` if `x` is negative.
public fun into_UD30x9(x: SD29x9): UD30x9 {
    let Components { neg, mag } = decompose(x.unwrap());
    assert!(!neg, ECannotBeConvertedToUD30x9);
    ud30x9::wrap(mag as u128)
}

/// Tries to convert a `SD29x9` value to a `UD30x9` value.
///
/// #### Parameters
/// - `x`: Input `SD29x9` value.
///
/// #### Returns
/// - The `UD30x9` representation of `x` if `x` is non-negative, otherwise `none`.
public fun try_into_UD30x9(x: SD29x9): Option<UD30x9> {
    let Components { neg, mag } = decompose(x.unwrap());
    if (neg) {
        option::none()
    } else {
        option::some(ud30x9::wrap(mag as u128))
    }
}

/// Returns the absolute value of a `SD29x9`.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - The non-negative value of `x`.
///
/// #### Aborts
/// - `EOverflow` if `x` is the minimum representable value (`-2^127`), because `+2^127` is not representable.
public fun abs(x: SD29x9): SD29x9 {
    let mut components = decompose(x.unwrap());
    components.neg = false;
    components.wrap_components()
}

/// Adds two `SD29x9` values.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The sum `x + y`.
///
/// #### Aborts
/// - `EOverflow` if the resulting magnitude exceeds the representable `SD29x9` range.
public fun add(x: SD29x9, y: SD29x9): SD29x9 {
    let result = decompose(x.unwrap()).add_components(decompose(y.unwrap()));
    result.wrap_components()
}

/// Rounds toward positive infinity to the nearest integer multiple of `1e9`.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - `x` rounded up (ceiling) at integer precision.
///
/// #### Aborts
/// - `EOverflow` if the rounded positive result exceeds the representable `SD29x9` range.
public fun ceil(x: SD29x9): SD29x9 {
    let Components { neg, mag } = decompose(x.unwrap());
    let scale = common::scale_u256!();
    let fractional = mag % scale;
    if (fractional == 0) {
        return x
    };
    let int_part = mag / scale;
    let result = if (!neg) {
        Components { mag: (int_part + 1) * scale, neg: false }
    } else {
        Components { mag: int_part * scale, neg: true }
    };
    result.wrap_components()
}

/// Standard-normal cumulative distribution function `Φ(z)`.
///
/// Returns the probability `Φ(z) ∈ [0, 1]` represented as a non-negative
/// `SD29x9`. The implementation evaluates an AAA-rational approximation
/// `N(|z|) / D(|z|)` at WAD scale via Horner's method on a sign-magnitude
/// `u256` accumulator; the final ratio is cast back to `SD29x9` (`10^9`)
/// in a single nearest-rounding step. Negative inputs reflect via
/// `Φ(-z) = 1 - Φ(z)`.
///
/// #### Parameters
/// - `z`: Input value.
///
/// #### Returns
/// - The probability `Φ(z)` as a non-negative `SD29x9` in `[0, 1]`.
///
/// #### Behavior
/// - Saturates exactly to `0` for `z ≤ -6.3` and to `1` for `z ≥ 6.3`. At
///   those bounds `Φ` is already within `~10⁻¹⁰` of the saturated value,
///   well below the output's `10⁻⁹` resolution.
/// - `Φ(0)` is exactly `0.5`.
/// - Max absolute error `≤ 5 × 10⁻⁹` (5 ULP at the `SD29x9` scale).
///   Empirical worst-case from the committed coefficients is `~7 × 10⁻¹⁰`.
/// - `cdf(z) + cdf(z.negate())` is exactly `1` for every input: both
///   evaluations share the same `Φ(|z|)` value, which the negative branch
///   reflects as `1 - Φ(|z|)`.
/// - Monotone non-decreasing across the dense offline validation grid
///   (enforced by the codegen CI gate). A 1-ULP local inversion between
///   neighboring raw inputs is not formally excluded in the far tail
///   (`|z| ≳ 5.7`), where the true `Φ` increment drops below the `10⁻⁹`
///   output resolution.
/// - Pure, deterministic, and object-free: identical inputs always produce
///   identical outputs; touches no storage or Sui objects.
///
/// #### Aborts
/// - Does not abort for any `SD29x9` input under the committed, validated
///   coefficients. The implementation carries internal integrity asserts
///   (`EInternalNegSubUnderflow` here, plus `cdf::EInternalNumNegative` /
///   `cdf::EInternalDenNonPositive` in the evaluator) as defense-in-depth
///   against a corrupted regenerated coefficient table; these cannot fire for
///   the shipped coefficients.
///
/// #### Examples
///
/// ```move
/// let z = sd29x9::wrap(1_000_000_000, true); // -1.0
/// let p = z.cdf(); // 0.158655254
/// ```
public fun cdf(z: SD29x9): SD29x9 {
    let Components { mag, neg } = decompose(z.unwrap());
    let phi = cdf_nonneg_raw(mag as u128);
    let raw = if (neg) {
        // Defense-in-depth: the AAA fit's `Φ(z) ≥ 0.5` mathematical
        // contract is what makes `common::scale!() - phi` safe here.
        assert!(phi >= half_raw(), EInternalNegSubUnderflow);
        common::scale!() - phi
    } else {
        phi
    };
    wrap(raw, false)
}

/// Standard-normal probability density function `φ(z)`.
///
/// Returns the density `φ(z) = e^(-z^2/2) / sqrt(2*pi) ∈ [0, φ(0)]` as a
/// non-negative `SD29x9`, where the peak is `φ(0) = 0.398942280`. `φ` is even,
/// so the magnitude `|z|` is taken first and the unsigned evaluator
/// `pdf_nonneg_raw` is applied to it - there is no reflection or sign-flip. The
/// evaluator computes an AAA-rational approximation `N(|z|) / D(|z|)` at WAD
/// scale via Horner's method on a sign-magnitude `u256` accumulator, rounding
/// the ratio back to `SD29x9` (`10^9`) in a single nearest-rounding step.
///
/// #### Parameters
/// - `z`: Input value.
///
/// #### Returns
/// - The density `φ(z)` as a non-negative `SD29x9` in `[0, 0.398942280]`.
///
/// #### Behavior
/// - Even: `pdf(z) == pdf(z.negate())` for every input except `sd29x9::min()`,
///   whose negation is not representable.
/// - Monotone non-increasing in `|z|`; the peak `φ(0) = 0.398942280` is returned
///   exactly.
/// - Saturates exactly to `0` for `|z| ≥ 6.5`. At that bound `φ` is already
///   `~2.7 × 10⁻¹⁰`, below the output's `10⁻⁹` resolution.
/// - Max absolute error `≤ 5 × 10⁻⁹` (5 ULP at the `SD29x9` scale). Empirical
///   worst-case from the committed coefficients is `~6 × 10⁻¹⁰`.
/// - Pure, deterministic, and object-free: identical inputs always produce
///   identical outputs; touches no storage or Sui objects.
///
/// #### Aborts
/// - Does not abort for any `SD29x9` input under the committed, validated
///   coefficients. The evaluator carries internal integrity asserts
///   (`pdf::EInternalNumNegative` / `pdf::EInternalDenNonPositive`) as
///   defense-in-depth against a corrupted regenerated coefficient table; these
///   cannot fire for the shipped coefficients.
///
/// #### Examples
///
/// ```move
/// let z = sd29x9::wrap(1_000_000_000, true); // -1.0
/// let d = z.pdf(); // 0.241970725
/// ```
public fun pdf(z: SD29x9): SD29x9 {
    let Components { mag, .. } = decompose(z.unwrap());
    wrap(pdf_nonneg_raw(mag as u128), false)
}

/// Checks whether two `SD29x9` values are bitwise equal.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - `true` if both values have identical underlying bits, otherwise `false`.
public fun eq(x: SD29x9, y: SD29x9): bool {
    x.unwrap() == y.unwrap()
}

/// Rounds toward negative infinity to the nearest integer multiple of `1e9`.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - `x` rounded down (floor) at integer precision.
///
/// #### Aborts
/// - `EOverflow` if the rounded negative result magnitude exceeds the representable `SD29x9` range.
public fun floor(x: SD29x9): SD29x9 {
    let Components { neg, mag } = decompose(x.unwrap());
    let scale = common::scale_u256!();
    let fractional = mag % scale;
    if (fractional == 0) {
        return x
    };
    let int_part = mag / scale;
    let result = if (!neg) {
        Components { mag: int_part * scale, neg: false }
    } else {
        Components { mag: (int_part + 1) * scale, neg: true }
    };
    result.wrap_components()
}

/// Compares whether `x` is greater than `y`.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - `true` if `x > y`, otherwise `false`.
public fun gt(x: SD29x9, y: SD29x9): bool {
    greater_than_bits(x.unwrap(), y.unwrap())
}

/// Compares whether `x` is greater than or equal to `y`.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - `true` if `x >= y`, otherwise `false`.
public fun gte(x: SD29x9, y: SD29x9): bool {
    !x.lt(y)
}

/// Checks whether a value is exactly zero.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - `true` if `x` is zero, otherwise `false`.
public fun is_zero(x: SD29x9): bool {
    x.unwrap() == 0
}

/// Checks whether a value is strictly less than zero (sign bit set).
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - `true` if `x < 0`, otherwise `false`.
public fun is_negative(x: SD29x9): bool {
    (x.unwrap() & common::sign_bit!()) != 0
}

/// Computes the natural logarithm of an `SD29x9` value.
///
/// Derived from `log2` via `ln(x) = log2(x) * ln(2)`. Rounded toward zero;
/// see `log2` for full rounding semantics on signed results.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - `ln(x)`, rounded toward zero.
///
/// #### Aborts
/// - `ELogUndefined` if `x` is zero or negative.
public fun ln(x: SD29x9): SD29x9 {
    let Components { neg, mag } = decompose(x.unwrap());
    assert!(!neg && mag > 0, ELogUndefined);
    let (log_neg, log_mag_internal) = common::raw_log2(mag as u128);
    let result_mag = common::apply_log2_factor(log_mag_internal, common::ln2_e18!());
    wrap_components(Components { neg: log_neg, mag: result_mag as u256 })
}

/// Computes the base-10 logarithm of an `SD29x9` value.
///
/// Exact when `x` is an integer power of ten, including sub-unit powers
/// `10^-k` (`k` in `1..=9`). Otherwise derived from `log2` via
/// `log10(x) = log2(x) * log10(2)` and rounded toward zero; see `log2`
/// for full rounding semantics on signed results.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - `log10(x)`, rounded toward zero (exact at integer powers of ten).
///
/// #### Aborts
/// - `ELogUndefined` if `x` is zero or negative.
public fun log10(x: SD29x9): SD29x9 {
    let Components { neg, mag } = decompose(x.unwrap());
    assert!(!neg && mag > 0, ELogUndefined);
    // Applied on the decomposed magnitude before the sign branch so sub-unit
    // `10^-k` inputs (raw magnitudes below `SCALE`) also resolve exactly.
    if (u256::is_power_of_ten(mag)) {
        // Subtract `9 = log10(SCALE)` to strip the embedded scale; `j < 9`
        // means a sub-unit input (`10^-k`), producing a negative result.
        let j = u256::log10(mag, rounding::down());
        let (is_neg, result_abs) = if (j >= 9) {
            (false, ((j - 9) as u256) * common::scale_u256!())
        } else {
            (true, ((9 - j) as u256) * common::scale_u256!())
        };
        return wrap_components(Components { neg: is_neg, mag: result_abs })
    };
    let (log_neg, log_mag_internal) = common::raw_log2(mag as u128);
    let result_mag = common::apply_log2_factor(log_mag_internal, common::log10_2_e18!());
    wrap_components(Components { neg: log_neg, mag: result_mag as u256 })
}

/// Computes the base-2 logarithm of an `SD29x9` value.
///
/// The result is rounded toward zero, matching the convention used by
/// `mul_trunc`, `div_trunc`, and `pow` in this module. For positive results
/// (inputs `>= 1`) this coincides with rounding down and sits at most 2
/// ulps below the true value (see `raw_log2` for the kernel's precision
/// bound). For negative results (inputs in `(0, 1)`) the signed result
/// usually sits closer to zero than the true value, but in narrow edge
/// cases where the kernel's small upward magnitude bias crosses an integer
/// boundary it may instead be 1 ulp (unit in the last place) further from
/// zero.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - `log2(x)`, rounded toward zero.
///
/// #### Aborts
/// - `ELogUndefined` if `x` is zero or negative.
public fun log2(x: SD29x9): SD29x9 {
    let Components { neg, mag } = decompose(x.unwrap());
    assert!(!neg && mag > 0, ELogUndefined);
    let (log_neg, log_mag_internal) = common::raw_log2(mag as u128);
    let log_mag = log_mag_internal / common::scale!();
    wrap_components(Components { neg: log_neg, mag: log_mag as u256 })
}

/// Compares whether `x` is less than `y`.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - `true` if `x < y`, otherwise `false`.
public fun lt(x: SD29x9, y: SD29x9): bool {
    greater_than_bits(y.unwrap(), x.unwrap())
}

/// Compares whether `x` is less than or equal to `y`.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - `true` if `x <= y`, otherwise `false`.
public fun lte(x: SD29x9, y: SD29x9): bool {
    !x.gt(y)
}

/// Computes the truncating remainder of dividing one `SD29x9` value by another.
///
/// This function follows remainder semantics, not Euclidean modulo semantics. The magnitude is
/// computed as `abs(x) % abs(y)`, and the sign of the result follows the dividend `x`. In
/// particular, a negative dividend can produce a negative non-zero remainder, while the sign of
/// `y` does not affect the result apart from the zero-divisor check.
///
/// #### Parameters
/// - `x`: Dividend.
/// - `y`: Divisor.
///
/// #### Returns
/// - The truncating remainder of `x` divided by `y`.
/// - Returns `0` when `x` is an exact multiple of `y`.
///
/// #### Aborts
/// - `EDivideByZero` if `y` is zero.
public fun rem(x: SD29x9, y: SD29x9): SD29x9 {
    let y_bits = y.unwrap();
    assert!(y_bits != 0, EDivideByZero);
    let y = decompose(y_bits);
    let x = decompose(x.unwrap());
    let remainder = x.mag % y.mag;
    wrap_components(Components { neg: x.neg, mag: remainder })
}

/// Computes the Euclidean remainder of dividing one `SD29x9` value by another.
///
/// The result is always non-negative and satisfies `0 <= result < abs(y)`. When the
/// truncating remainder is negative, `abs(y)` is added to produce the Euclidean result.
///
/// #### Parameters
/// - `x`: Dividend.
/// - `y`: Divisor.
///
/// #### Returns
/// - The Euclidean remainder of `x` divided by `y`, always non-negative.
/// - Returns `0` when `x` is an exact multiple of `y`.
///
/// #### Aborts
/// - `EDivideByZero` if `y` is zero.
public fun mod(x: SD29x9, y: SD29x9): SD29x9 {
    let y_bits = y.unwrap();
    assert!(y_bits != 0, EDivideByZero);
    let y = decompose(y_bits);
    let x = decompose(x.unwrap());
    let remainder = x.mag % y.mag;
    let mag = if (x.neg && remainder > 0) {
        y.mag - remainder
    } else {
        remainder
    };
    wrap_components(Components { neg: false, mag })
}

/// Multiplies two `SD29x9` values with fixed-point scaling.
///
/// This function rounds toward zero when the exact product cannot be represented with 9 decimals.
/// Equivalent to `mul_trunc`.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The product `x * y`, rounded toward zero.
///
/// #### Aborts
/// - `EOverflow` if the resulting magnitude exceeds the representable `SD29x9` range.
public fun mul(x: SD29x9, y: SD29x9): SD29x9 {
    x.mul_trunc(y)
}

/// Multiplies two `SD29x9` values with fixed-point scaling and truncation toward zero.
///
/// This function rounds toward zero when the exact product cannot be represented with 9 decimals.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The product `x * y`, rounded toward zero.
///
/// #### Aborts
/// - `EOverflow` if the resulting magnitude exceeds the representable `SD29x9` range.
public fun mul_trunc(x: SD29x9, y: SD29x9): SD29x9 {
    let x = decompose(x.unwrap());
    let y = decompose(y.unwrap());
    let neg = x.neg != y.neg;
    let prod = x.mag * y.mag;
    let mag = prod / common::scale_u256!();
    wrap_components(Components { neg, mag })
}

/// Multiplies two `SD29x9` values with fixed-point scaling and rounds away from zero.
///
/// This function rounds away from zero when the exact product cannot be represented with 9
/// decimals.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Examples
/// - `1.000000001 * 1.000000001` returns `1.000000003`.
/// - `-1.000000001 * 1.000000001` returns `-1.000000003`.
///
/// #### Returns
/// - The product `x * y`, rounded away from zero when inexact.
///
/// #### Aborts
/// - `EOverflow` if the rounded magnitude exceeds the representable `SD29x9` range.
public fun mul_away(x: SD29x9, y: SD29x9): SD29x9 {
    let x = decompose(x.unwrap());
    let y = decompose(y.unwrap());
    let neg = x.neg != y.neg;
    let mag = common::div_away_u256(x.mag * y.mag, common::scale_u256!());
    wrap_components(Components { neg, mag })
}

/// Divides `x` by `y` with fixed-point scaling.
///
/// This function rounds toward zero when the exact quotient cannot be represented with 9 decimals.
/// Equivalent to `div_trunc`.
///
/// #### Parameters
/// - `x`: Dividend.
/// - `y`: Divisor.
///
/// #### Returns
/// - The quotient `x / y`, rounded toward zero.
///
/// #### Aborts
/// - `EDivideByZero` if `y` is zero.
/// - `EOverflow` if the resulting magnitude exceeds the representable `SD29x9` range.
public fun div(x: SD29x9, y: SD29x9): SD29x9 {
    x.div_trunc(y)
}

/// Divides `x` by `y` with fixed-point scaling and truncation toward zero.
///
/// This function rounds toward zero when the exact quotient cannot be represented with 9 decimals.
///
/// #### Parameters
/// - `x`: Dividend.
/// - `y`: Divisor.
///
/// #### Returns
/// - The quotient `x / y`, rounded toward zero.
///
/// #### Aborts
/// - `EDivideByZero` if `y` is zero.
/// - `EOverflow` if the resulting magnitude exceeds the representable `SD29x9` range.
public fun div_trunc(x: SD29x9, y: SD29x9): SD29x9 {
    let y_bits = y.unwrap();
    assert!(y_bits != 0, EDivideByZero);
    let y = decompose(y_bits);
    let x = decompose(x.unwrap());
    let neg = x.neg != y.neg;
    let numerator = x.mag * common::scale_u256!();
    let mag = numerator / y.mag;
    wrap_components(Components { neg, mag })
}

/// Divides `x` by `y` with fixed-point scaling and rounds away from zero.
///
/// This function rounds away from zero when the exact quotient cannot be represented with 9
/// decimals.
///
/// #### Parameters
/// - `x`: Dividend.
/// - `y`: Divisor.
///
/// #### Examples
/// - `1.0 / 3.0` returns `0.333333334`.
/// - `-1.0 / 3.0` returns `-0.333333334`.
///
/// #### Returns
/// - The quotient `x / y`, rounded away from zero when inexact.
///
/// #### Aborts
/// - `EDivideByZero` if `y` is zero.
/// - `EOverflow` if the rounded magnitude exceeds the representable `SD29x9` range.
public fun div_away(x: SD29x9, y: SD29x9): SD29x9 {
    let y_bits = y.unwrap();
    assert!(y_bits != 0, EDivideByZero);
    let y = decompose(y_bits);
    let x = decompose(x.unwrap());
    let neg = x.neg != y.neg;
    let numerator = x.mag * common::scale_u256!();
    let mag = common::div_away_u256(numerator, y.mag);
    wrap_components(Components { neg, mag })
}

/// Raises `x` to a power of `exp`.
///
/// This helper uses binary exponentiation with fixed-point
/// multiplication. Each intermediate multiply or square applies
/// fixed-point truncation via division by `common::scale_u256!()`.
///
/// As a consequence, `pow` is approximate for most fractional values: rounding error compounds as
/// `exp` grows, results are biased toward zero, and for `0 < abs(x) < 1` intermediate values can
/// reach zero before the final mathematically scaled result would.
///
/// Because truncation is applied at intermediate steps, the result generally matches neither the
/// exact real-valued power rounded once at the end nor the result of left-to-right repeated
/// multiplication. In particular, fixed-point multiplication is not associative under truncation,
/// so the grouping of operations used by binary exponentiation affects the final value.
///
/// #### Parameters
/// - `x`: Base value.
/// - `exp`: Exponent.
///
/// #### Returns
/// - An approximation of `x^exp` computed using binary exponentiation and fixed-point truncation.
///
/// #### Aborts
/// - `EOverflow` if the resulting magnitude exceeds the representable `SD29x9` range.
public fun pow(x: SD29x9, exp: u8): SD29x9 {
    if (exp == 0) {
        return one()
    };
    if (exp == 1) {
        return x
    };
    let Components { neg, mag } = decompose(x.unwrap());
    let res_neg = neg && (exp % 2 != 0);
    let scale = common::scale_u256!();
    let max_mag = common::min_sd29x9_value!() as u256;
    let mut res_mag = scale;
    let mut base_mag = mag;
    let mut exp = exp;

    while (exp != 0) {
        if ((exp & 1) == 1) {
            res_mag = res_mag * base_mag / scale;
            assert!(res_mag < max_mag || (res_neg && res_mag == max_mag), EOverflow);
        };
        exp = exp >> 1;
        if (exp != 0) {
            base_mag = base_mag * base_mag / scale;
            assert!(base_mag <= max_mag, EOverflow);
        };
    };

    let result = Components { neg: res_neg, mag: res_mag };
    result.wrap_components()
}

/// Computes the square root of a `SD29x9` value.
///
/// The result is the largest `SD29x9` value `r` such that `r * r <= x`. In other words, the
/// result is truncated (rounded down) to the nearest representable `SD29x9` value.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - The non-negative square root of `x`, rounded down to the nearest representable `SD29x9`
///   value.
///
/// #### Aborts
/// - `ENegativeSqrt` if `x` is negative.
public fun sqrt(x: SD29x9): SD29x9 {
    let Components { neg, mag } = decompose(x.unwrap());
    assert!(!neg, ENegativeSqrt);
    // Multiply by SCALE to preserve 9 decimal places of precision through the square root:
    // sqrt(mag / SCALE) = sqrt(mag * SCALE) / SCALE
    let result = u256::sqrt(mag * common::scale_u256!(), rounding::down());
    wrap_components(Components { neg: false, mag: result })
}

/// Returns the arithmetic negation of `x`.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - `-x`.
///
/// #### Aborts
/// - `EOverflow` if `x` is the minimum representable value (`-2^127`), because `+2^127` is not representable.
public fun negate(x: SD29x9): SD29x9 {
    let value = decompose(x.unwrap());
    value.negate_components().wrap_components()
}

/// Checks whether two `SD29x9` values are not equal.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - `true` if `x != y`, otherwise `false`.
public fun neq(x: SD29x9, y: SD29x9): bool {
    !x.eq(y)
}

/// Subtracts `y` from `x`.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The difference `x - y`.
///
/// #### Aborts
/// - `EOverflow` if the resulting magnitude exceeds the representable `SD29x9` range.
public fun sub(x: SD29x9, y: SD29x9): SD29x9 {
    let negated_y = decompose(y.unwrap()).negate_components();
    let result = decompose(x.unwrap()).add_components(negated_y);
    result.wrap_components()
}

/// Performs the unchecked addition of two `SD29x9` values.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The wrapping sum of the raw bit patterns modulo `2^128`.
public fun unchecked_add(x: SD29x9, y: SD29x9): SD29x9 {
    from_bits(wrapping_add_bits(x.unwrap(), y.unwrap()))
}

/// Performs the unchecked subtraction on two `SD29x9` values.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The wrapping difference of the raw bit patterns modulo `2^128`.
public fun unchecked_sub(x: SD29x9, y: SD29x9): SD29x9 {
    from_bits(wrapping_sub_bits(x.unwrap(), y.unwrap()))
}

// === Private Functions ===

fun decompose(bits: u128): Components {
    if ((bits & common::sign_bit!()) != 0) {
        Components { neg: true, mag: two_complement(bits) as u256 }
    } else {
        Components { neg: false, mag: bits as u256 }
    }
}

fun negate_components(value: Components): Components {
    if (value.mag == 0) {
        Components { neg: false, mag: 0 }
    } else {
        Components { neg: !value.neg, mag: value.mag }
    }
}

fun add_components(x: Components, y: Components): Components {
    if (x.neg == y.neg) {
        Components { neg: x.neg, mag: x.mag + y.mag }
    } else if (x.mag >= y.mag) {
        Components { neg: x.neg, mag: x.mag - y.mag }
    } else {
        Components { neg: y.neg, mag: y.mag - x.mag }
    }
}

fun wrap_components(value: Components): SD29x9 {
    if (value.mag == 0) {
        return zero()
    };
    let max_mag = common::min_sd29x9_value!() as u256;
    if (value.neg && value.mag == max_mag) {
        min()
    } else {
        assert!(value.mag < max_mag, EOverflow);
        wrap(value.mag as u128, value.neg)
    }
}

fun wrapping_add_bits(a: u128, b: u128): u128 {
    let sum = (a as u256) + (b as u256);
    (sum & (std::u128::max_value!() as u256)) as u128
}

fun wrapping_sub_bits(a: u128, b: u128): u128 {
    wrapping_add_bits(a, two_complement(b))
}

fun greater_than_bits(x_bits: u128, y_bits: u128): bool {
    if (x_bits == y_bits) {
        return false
    };
    let x = decompose(x_bits);
    let y = decompose(y_bits);

    if (x.neg != y.neg) {
        !x.neg
    } else if (!x.neg) {
        x.mag > y.mag
    } else {
        x.mag < y.mag
    }
}

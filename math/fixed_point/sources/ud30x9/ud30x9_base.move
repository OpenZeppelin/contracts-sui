/// Base utility functions for the `UD30x9` fixed-point type.
module openzeppelin_fp_math::ud30x9_base;

use openzeppelin_fp_math::cdf::cdf_nonneg_raw;
use openzeppelin_fp_math::common;
use openzeppelin_fp_math::pdf::pdf_nonneg_raw;
use openzeppelin_fp_math::sd29x9::{Self, SD29x9};
use openzeppelin_fp_math::ud30x9::{UD30x9, wrap, zero, one};
use openzeppelin_math::rounding;
use openzeppelin_math::u128;
use openzeppelin_math::u256;

// === Errors ===

/// Value overflows `UD30x9` (must be less than 2^128)
#[error(code = 0)]
const EOverflow: vector<u8> = "Value overflows UD30x9 (must be less than 2^128)";

/// Arithmetic underflow: the result would be negative, which is unrepresentable in `UD30x9`
#[error(code = 1)]
const EUnderflow: vector<u8> = "Value underflows UD30x9 (result would be negative)";

/// Divisor must be non-zero
#[error(code = 2)]
const EDivideByZero: vector<u8> = "Divisor must be non-zero";

/// Value cannot be converted to `SD29x9`
#[error(code = 3)]
const ECannotBeConvertedToSD29x9: vector<u8> = "Value cannot be converted to SD29x9";

/// Shift size is out of range (must be less than 128)
#[error(code = 4)]
const EInvalidShiftSize: vector<u8> = "Shift size is out of range (must be less than 128)";

/// Logarithm is undefined: input must be non-zero
#[error(code = 5)]
const ELogUndefined: vector<u8> = "Logarithm is undefined: input must be non-zero";

/// Logarithm result would be negative and is unrepresentable in `UD30x9`
#[error(code = 6)]
const ELogResultUnrepresentable: vector<u8> =
    "Logarithm result would be negative and is unrepresentable in UD30x9";

// === Public Functions ===

// === Conversion ===

/// Converts a `UD30x9` value to a `SD29x9` value.
///
/// #### Parameters
/// - `x`: Input `UD30x9` value.
///
/// #### Returns
/// - The `SD29x9` representation of `x`.
///
/// #### Aborts
/// - `ECannotBeConvertedToSD29x9` if `x` is greater than max positive `SD29x9` value.
public fun into_SD29x9(x: UD30x9): SD29x9 {
    let value = x.unwrap();
    assert!(value <= common::max_sd29x9_magnitude!(), ECannotBeConvertedToSD29x9);
    sd29x9::wrap(value, false)
}

/// Tries to convert a `UD30x9` value to a `SD29x9` value.
///
/// #### Parameters
/// - `x`: Input `UD30x9` value.
///
/// #### Returns
/// - The `SD29x9` representation of `x` if `x` is less than or equal to max positive `SD29x9` value, otherwise `none`.
public fun try_into_SD29x9(x: UD30x9): Option<SD29x9> {
    let value = x.unwrap();
    if (value > common::max_sd29x9_magnitude!()) {
        option::none()
    } else {
        option::some(sd29x9::wrap(value, false))
    }
}

/// Adds two `UD30x9` values.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The sum `x + y`.
///
/// #### Aborts
/// - `EOverflow` if the sum exceeds the representable `UD30x9` range.
public fun add(x: UD30x9, y: UD30x9): UD30x9 {
    let (x, y) = (x.unwrap() as u256, y.unwrap() as u256);
    wrap_u256(x + y)
}

/// Performs a bitwise AND between raw `UD30x9` bits and a `u128` mask.
///
/// #### Parameters
/// - `x`: Input value.
/// - `bits`: Bit mask applied to `x`'s underlying bits.
///
/// #### Returns
/// - The result of bitwise AND operation.
public fun and(x: UD30x9, bits: u128): UD30x9 {
    wrap(x.unwrap() & bits)
}

/// Performs a bitwise AND between two `UD30x9` raw bit patterns.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The result of bitwise AND operation.
public fun and2(x: UD30x9, y: UD30x9): UD30x9 {
    wrap(x.unwrap() & y.unwrap())
}

/// Returns the absolute value of a `UD30x9`.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - `x` unchanged, since `UD30x9` is unsigned.
public fun abs(x: UD30x9): UD30x9 {
    x
}

/// Standard-normal cumulative distribution function `Φ(z)` on non-negative `z`.
///
/// Returns the probability `Φ(z) ∈ [0.5, 1]` represented as `UD30x9`. Since
/// `UD30x9` inputs are inherently non-negative, the output is always at least
/// `0.5`. The implementation evaluates an AAA-rational approximation
/// `N(z) / D(z)` at WAD scale via Horner's method on a sign-magnitude `u256`
/// accumulator; the final ratio is cast back to `UD30x9` (`10^9`) in a single
/// nearest-rounding step.
///
/// #### Parameters
/// - `z`: Non-negative input.
///
/// #### Returns
/// - `Φ(z) ∈ [0.5, 1]` at `UD30x9` scale.
///
/// #### Behavior
/// - Saturates exactly to `1.0` for `z ≥ 6.3`. At that bound `Φ` is already
///   within `~10⁻¹⁰` of `1`, well below the output's `10⁻⁹` resolution.
/// - `Φ(0)` is exactly `0.5`.
/// - Max absolute error `≤ 5 × 10⁻⁹` (5 ULP at the `UD30x9` scale). Empirical
///   worst-case from the committed coefficients is `~7 × 10⁻¹⁰`.
/// - Monotone non-decreasing across the dense offline validation grid
///   (enforced by the codegen CI gate). A 1-ULP local inversion between
///   neighboring raw inputs is not formally excluded in the far tail
///   (`z ≳ 5.7`), where the true `Φ` increment drops below the `10⁻⁹`
///   output resolution.
/// - Pure, deterministic, and object-free: identical inputs always produce
///   identical outputs; touches no storage or Sui objects.
///
/// #### Aborts
/// - Does not abort for any `UD30x9` input under the committed, validated
///   coefficients. The evaluator carries internal integrity asserts
///   (`cdf::EInternalNumNegative` / `cdf::EInternalDenNonPositive`) as
///   defense-in-depth against a corrupted regenerated coefficient table; these
///   cannot fire for the shipped coefficients.
///
/// #### Examples
///
/// ```move
/// let z = ud30x9::wrap(1_000_000_000); // 1.0
/// let p = z.cdf(); // 0.841344746
/// ```
public fun cdf(z: UD30x9): UD30x9 {
    wrap(cdf_nonneg_raw(z.unwrap()))
}

/// Standard-normal probability density function `φ(z)` on non-negative `z`.
///
/// Returns the density `φ(z) = e^(-z^2/2) / sqrt(2*pi) ∈ [0, φ(0)]` represented
/// as `UD30x9`, where the peak is `φ(0) = 0.398942280`. The implementation
/// evaluates an AAA-rational approximation `N(z) / D(z)` at WAD scale via
/// Horner's method on a sign-magnitude `u256` accumulator; the final ratio is
/// cast back to `UD30x9` (`10^9`) in a single nearest-rounding step.
///
/// #### Parameters
/// - `z`: Non-negative input.
///
/// #### Returns
/// - `φ(z) ∈ [0, 0.398942280]` at `UD30x9` scale.
///
/// #### Behavior
/// - Monotone non-increasing in `z`; the peak `φ(0) = 0.398942280` is returned
///   exactly.
/// - Saturates exactly to `0` for `z ≥ 6.5`. At that bound `φ` is already
///   `~2.7 × 10⁻¹⁰`, below the output's `10⁻⁹` resolution.
/// - Max absolute error `≤ 5 × 10⁻⁹` (5 ULP at the `UD30x9` scale). Empirical
///   worst-case from the committed coefficients is `~6 × 10⁻¹⁰`.
/// - Pure, deterministic, and object-free: identical inputs always produce
///   identical outputs; touches no storage or Sui objects.
///
/// #### Aborts
/// - Does not abort for any `UD30x9` input under the committed, validated
///   coefficients. The evaluator carries internal integrity asserts
///   (`pdf::EInternalNumNegative` / `pdf::EInternalDenNonPositive`) as
///   defense-in-depth against a corrupted regenerated coefficient table; these
///   cannot fire for the shipped coefficients.
///
/// #### Examples
///
/// ```move
/// let z = ud30x9::wrap(1_000_000_000); // 1.0
/// let d = z.pdf(); // 0.241970725
/// ```
public fun pdf(z: UD30x9): UD30x9 {
    wrap(pdf_nonneg_raw(z.unwrap()))
}

/// Rounds toward positive infinity to the next integer (if fractional), otherwise unchanged.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - `x` rounded up (ceiling) at integer precision.
///
/// #### Aborts
/// - `EOverflow` if the rounded result exceeds the representable `UD30x9` range.
public fun ceil(x: UD30x9): UD30x9 {
    let value = x.unwrap() as u256;
    let scale = common::scale_u256!();
    let fractional = value % scale;
    if (fractional == 0) {
        x
    } else {
        let int_part = value - fractional;
        let new_value = int_part + scale;
        wrap_u256(new_value)
    }
}

/// Checks whether two `UD30x9` values are equal.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - `true` if `x == y`, otherwise `false`.
public fun eq(x: UD30x9, y: UD30x9): bool {
    x.unwrap() == y.unwrap()
}

/// Rounds down to the nearest integer multiple of `1e9`.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - `x` rounded down (floor) at integer precision.
public fun floor(x: UD30x9): UD30x9 {
    let value = x.unwrap();
    let fractional = value % common::scale!();
    if (fractional == 0) {
        x
    } else {
        wrap(value - fractional)
    }
}

/// Compares whether `x` is greater than `y`.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - `true` if `x > y`, otherwise `false`.
public fun gt(x: UD30x9, y: UD30x9): bool {
    x.unwrap() > y.unwrap()
}

/// Compares whether `x` is greater than or equal to `y`.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - `true` if `x >= y`, otherwise `false`.
public fun gte(x: UD30x9, y: UD30x9): bool {
    x.unwrap() >= y.unwrap()
}

/// Checks whether a value is exactly zero.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - `true` if `x` is zero, otherwise `false`.
public fun is_zero(x: UD30x9): bool {
    x.unwrap() == 0
}

/// Performs a logical left shift on the underlying 128-bit representation of a `UD30x9` value.
///
/// #### Parameters
/// - `x`: Input value.
/// - `bits`: Number of bit positions to shift left.
///
/// #### Returns
/// - The result of shifting the `x`'s raw bits left by `bits`.
///
/// #### Aborts
/// - `EInvalidShiftSize` if `bits >= 128`.
/// - `EOverflow` if the result overflows `u128`.
public fun lshift(x: UD30x9, bits: u8): UD30x9 {
    assert!(bits < 128, EInvalidShiftSize);
    let raw = x.unwrap();
    assert!(raw <= std::u128::max_value!() >> bits, EOverflow);
    wrap(raw << bits)
}

/// Performs an unchecked left shift on the underlying 128-bit representation of a `UD30x9`
/// value, truncating high bits that overflow past the 128-bit boundary and returning zero
/// when `bits >= 128`.
///
/// A checked version of this function is available via `lshift`, which aborts on invalid
/// shift sizes and overflow.
///
/// #### Parameters
/// - `x`: Input value.
/// - `bits`: Number of bit positions to shift left.
///
/// #### Returns
/// - Zero if `bits >= 128` (all bits shifted out).
/// - Otherwise, the result of shifting the `x`'s raw bits left by `bits`.
public fun unchecked_lshift(x: UD30x9, bits: u8): UD30x9 {
    if (bits >= 128) {
        return zero()
    };
    wrap(x.unwrap() << bits)
}

/// Computes the natural logarithm of a `UD30x9` value.
///
/// Derived from `log2` via the identity `ln(x) = log2(x) * ln(2)`. Both the
/// `log2` kernel and the base-conversion step round toward zero, so the
/// result may sit up to 2 ulps below the true value; see `raw_log2` for the
/// kernel's precision bound.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - `ln(x)`, rounded down to the nearest representable `UD30x9` value.
///
/// #### Aborts
/// - `ELogUndefined` if `x` is zero.
/// - `ELogResultUnrepresentable` if `x` is in `(0, 1)` (the result would be negative
///   and cannot be represented in `UD30x9` - use `SD29x9` instead).
public fun ln(x: UD30x9): UD30x9 {
    let raw = x.unwrap();
    assert!(raw > 0, ELogUndefined);
    assert!(raw >= common::scale!(), ELogResultUnrepresentable);
    // The `raw >= scale` precondition guarantees `raw_log2` returns a
    // non-negative sign, so the discarded sign flag is provably `false`.
    let (_, mag) = common::raw_log2(raw);
    wrap(common::apply_log2_factor(mag, common::ln2_e18!()))
}

/// Computes the base-10 logarithm of a `UD30x9` value.
///
/// Exact when `x` is an integer power of ten (`10^k`, `k >= 0`): the
/// dedicated power-of-ten branch returns `k * SCALE`, so `log10(10)` is
/// exactly `one()`. Other inputs are derived from `log2` via the identity
/// `log10(x) = log2(x) * log10(2)` and rounded down.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - `log10(x)`, rounded down to the nearest representable `UD30x9` value
///   (exact at integer powers of ten).
///
/// #### Aborts
/// - `ELogUndefined` if `x` is zero.
/// - `ELogResultUnrepresentable` if `x` is in `(0, 1)` (the result would be negative
///   and cannot be represented in `UD30x9` - use `SD29x9` instead).
public fun log10(x: UD30x9): UD30x9 {
    let raw = x.unwrap();
    assert!(raw > 0, ELogUndefined);
    assert!(raw >= common::scale!(), ELogResultUnrepresentable);
    if (u128::is_power_of_ten(raw)) {
        // Subtract `9 = log10(SCALE)` to strip the embedded scale.
        let j = u128::log10(raw, rounding::down());
        return wrap(((j - 9) as u128) * common::scale!())
    };
    // The `raw >= scale` precondition guarantees `raw_log2` returns a
    // non-negative sign, so the discarded sign flag is provably `false`.
    let (_, mag) = common::raw_log2(raw);
    wrap(common::apply_log2_factor(mag, common::log10_2_e18!()))
}

/// Computes the base-2 logarithm of a `UD30x9` value.
///
/// The result is rounded down and sits at most 2 ulps below the true
/// `log2(x)`; see `raw_log2` for the kernel's precision bound. For inputs
/// in `[1, 2)` the result is exact.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - `log2(x)`, at most 2 ulps below the true value.
///
/// #### Aborts
/// - `ELogUndefined` if `x` is zero.
/// - `ELogResultUnrepresentable` if `x` is in `(0, 1)` (the result would be negative
///   and cannot be represented in `UD30x9` - use `SD29x9` instead).
public fun log2(x: UD30x9): UD30x9 {
    let raw = x.unwrap();
    assert!(raw > 0, ELogUndefined);
    assert!(raw >= common::scale!(), ELogResultUnrepresentable);
    // The `raw >= scale` precondition guarantees `raw_log2` returns a
    // non-negative sign, so the discarded sign flag is provably `false`.
    let (_, mag) = common::raw_log2(raw);
    wrap(mag / common::scale!())
}

/// Compares whether `x` is less than `y`.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - `true` if `x < y`, otherwise `false`.
public fun lt(x: UD30x9, y: UD30x9): bool {
    x.unwrap() < y.unwrap()
}

/// Compares whether `x` is less than or equal to `y`.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - `true` if `x <= y`, otherwise `false`.
public fun lte(x: UD30x9, y: UD30x9): bool {
    x.unwrap() <= y.unwrap()
}

/// Computes the remainder of dividing one `UD30x9` value by another.
///
/// #### Parameters
/// - `x`: Dividend.
/// - `y`: Divisor.
///
/// #### Returns
/// - The remainder of `x` divided by `y`.
///
/// #### Aborts
/// - `EDivideByZero` if `y` is zero.
public fun mod(x: UD30x9, y: UD30x9): UD30x9 {
    let (x, y) = (x.unwrap(), y.unwrap());
    assert!(y != 0, EDivideByZero);
    wrap(x % y)
}

/// Multiplies two `UD30x9` values with fixed-point scaling.
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
/// - `EOverflow` if the resulting value exceeds the representable `UD30x9` range.
public fun mul(x: UD30x9, y: UD30x9): UD30x9 {
    x.mul_trunc(y)
}

/// Multiplies two `UD30x9` values with fixed-point scaling and truncation toward zero.
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
/// - `EOverflow` if the resulting value exceeds the representable `UD30x9` range.
public fun mul_trunc(x: UD30x9, y: UD30x9): UD30x9 {
    let (x, y) = (x.unwrap() as u256, y.unwrap() as u256);
    wrap_u256(x * y / common::scale_u256!())
}

/// Multiplies two `UD30x9` values with fixed-point scaling and rounds away from zero.
///
/// This function rounds away from zero when the exact product cannot be represented with 9
/// decimals.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The product `x * y`, rounded away from zero when inexact.
///
/// #### Aborts
/// - `EOverflow` if the rounded result exceeds the representable `UD30x9` range.
public fun mul_away(x: UD30x9, y: UD30x9): UD30x9 {
    let (x, y) = (x.unwrap() as u256, y.unwrap() as u256);
    wrap_u256(common::div_away_u256(x * y, common::scale_u256!()))
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
/// - `EOverflow` if the resulting value exceeds the representable `UD30x9` range.
public fun div(x: UD30x9, y: UD30x9): UD30x9 {
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
/// - `EOverflow` if the resulting value exceeds the representable `UD30x9` range.
public fun div_trunc(x: UD30x9, y: UD30x9): UD30x9 {
    let (x, y) = (x.unwrap() as u256, y.unwrap() as u256);
    assert!(y != 0, EDivideByZero);
    let numerator = x * common::scale_u256!();
    wrap_u256(numerator / y)
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
///
/// #### Returns
/// - The quotient `x / y`, rounded away from zero when inexact.
///
/// #### Aborts
/// - `EDivideByZero` if `y` is zero.
/// - `EOverflow` if the rounded result exceeds the representable `UD30x9` range.
public fun div_away(x: UD30x9, y: UD30x9): UD30x9 {
    let (x, y) = (x.unwrap() as u256, y.unwrap() as u256);
    assert!(y != 0, EDivideByZero);
    let numerator = x * common::scale_u256!();
    wrap_u256(common::div_away_u256(numerator, y))
}

/// Raises `x` to a power of `exp`.
///
/// This helper uses binary exponentiation with fixed-point multiplication. Each intermediate
/// multiply or square applies fixed-point truncation via division by `common::scale_u256!()`.
///
/// As a consequence, `pow` is approximate for most fractional values: rounding error compounds as
/// `exp` grows, results are biased toward zero, and for `0 < x < 1` intermediate values can reach
/// zero before the final mathematically scaled result would.
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
/// - `EOverflow` if the resulting value exceeds the representable `UD30x9` range.
public fun pow(x: UD30x9, exp: u8): UD30x9 {
    if (exp == 0) {
        return one()
    };
    if (exp == 1) {
        return x
    };

    let scale = common::scale_u256!();
    let max_value = std::u128::max_value!() as u256;
    let mut base = x.unwrap() as u256;
    let mut result = scale;
    let mut exp = exp;

    while (exp != 0) {
        if ((exp & 1) == 1) {
            result = result * base / scale;
            assert!(result <= max_value, EOverflow);
        };
        exp = exp >> 1;
        if (exp != 0) {
            base = base * base / scale;
            assert!(base <= max_value, EOverflow);
        };
    };

    wrap_u256(result)
}

/// Computes the square root of a `UD30x9` value.
///
/// The result is the largest `UD30x9` value `r` such that `r * r <= x`. In other words, the
/// result is truncated (rounded down) to the nearest representable `UD30x9` value.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - The square root of `x`, rounded down to the nearest representable `UD30x9` value.
public fun sqrt(x: UD30x9): UD30x9 {
    let raw = x.unwrap() as u256;
    // Multiply by SCALE to preserve 9 decimal places of precision through the square root:
    // sqrt(raw / SCALE) = sqrt(raw * SCALE) / SCALE
    let result = u256::sqrt(raw * common::scale_u256!(), rounding::down());
    wrap(result as u128)
}

/// Checks whether two `UD30x9` values are not equal.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - `true` if `x != y`, otherwise `false`.
public fun neq(x: UD30x9, y: UD30x9): bool {
    x.unwrap() != y.unwrap()
}

/// Performs a bitwise NOT on the raw `UD30x9` bits.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - The result of bitwise NOT operation.
public fun not(x: UD30x9): UD30x9 {
    wrap(x.unwrap() ^ std::u128::max_value!())
}

/// Performs a bitwise OR between two `UD30x9` raw bit patterns.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The result of bitwise OR operation.
public fun or(x: UD30x9, y: UD30x9): UD30x9 {
    wrap(x.unwrap() | y.unwrap())
}

/// Performs a logical right shift on the underlying 128-bit representation of a `UD30x9` value.
///
/// #### Parameters
/// - `x`: Input value.
/// - `bits`: Number of bit positions to shift right.
///
/// #### Returns
/// - The result of shifting the `x`'s raw bits right by `bits`.
///
/// #### Aborts
/// - `EInvalidShiftSize` if `bits >= 128`.
public fun rshift(x: UD30x9, bits: u8): UD30x9 {
    assert!(bits < 128, EInvalidShiftSize);
    wrap(x.unwrap() >> bits)
}

/// Performs an unchecked right shift on the underlying 128-bit representation of a `UD30x9`
/// value, filling vacated high bits with zeros and returning zero when `bits >= 128`.
///
/// A checked version of this function is available via `rshift`, which aborts on invalid
/// shift sizes.
///
/// #### Parameters
/// - `x`: Input value.
/// - `bits`: Number of bit positions to shift right.
///
/// #### Returns
/// - Zero if `bits >= 128`.
/// - Otherwise, the result of shifting the `x`'s raw bits right by `bits`.
public fun unchecked_rshift(x: UD30x9, bits: u8): UD30x9 {
    if (bits >= 128) {
        return zero()
    };
    wrap(x.unwrap() >> bits)
}

/// Subtracts `y` from `x`.
///
/// #### Parameters
/// - `x`: First operand (minuend).
/// - `y`: Second operand (subtrahend).
///
/// #### Returns
/// - The difference `x - y`.
///
/// #### Aborts
/// - `EUnderflow` if `y > x`.
public fun sub(x: UD30x9, y: UD30x9): UD30x9 {
    let (x, y) = (x.unwrap(), y.unwrap());
    assert!(x >= y, EUnderflow);
    wrap(x - y)
}

/// Performs unchecked addition of two `UD30x9` values.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The wrapping sum `x + y` modulo `2^128`.
public fun unchecked_add(x: UD30x9, y: UD30x9): UD30x9 {
    let (x, y) = (x.unwrap() as u256, y.unwrap() as u256);
    let sum = x + y;
    let u128_max = std::u128::max_value!() as u256;

    // Keep only the low 128 bits, safe to cast down to u128.
    let wrapped = (sum & u128_max) as u128;
    wrap(wrapped)
}

/// Performs unchecked subtraction of two `UD30x9` values.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The wrapping difference `x - y` modulo `2^128`.
public fun unchecked_sub(x: UD30x9, y: UD30x9): UD30x9 {
    let (x, y) = (x.unwrap() as u256, y.unwrap() as u256);
    let u128_max = std::u128::max_value!() as u256;

    // Effectively wraps subtraction like in modular arithmetic.
    // The result is (a + (2^128) - b).
    let diff = x + (u128_max + 1) - y;

    // Wrap the result back into the u128 range by taking the low 128 bits.
    let wrapped = (diff & u128_max) as u128;
    wrap(wrapped)
}

/// Performs a bitwise XOR between two `UD30x9` raw bit patterns.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The result of bitwise XOR operation.
public fun xor(x: UD30x9, y: UD30x9): UD30x9 {
    wrap(x.unwrap() ^ y.unwrap())
}

// === Private Functions ===

fun wrap_u256(value: u256): UD30x9 {
    assert!(value <= std::u128::max_value!() as u256, EOverflow);
    wrap(value as u128)
}

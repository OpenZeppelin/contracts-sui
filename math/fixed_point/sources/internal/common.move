/// Shared helpers for fixed-point package-wide constants and conversions.
///
/// The public `ud30x9` and `sd29x9` modules intentionally expose low-level
/// `wrap`/`unwrap` APIs over raw scaled representations. Conversion helpers
/// live separately and reuse the constants in this module to keep scale-aware
/// bounds, sign handling, and terminology consistent across the package.
module openzeppelin_fp_math::common;

use openzeppelin_math::rounding;
use openzeppelin_math::u128;

// === Errors ===

/// Logarithm of zero is undefined.
#[error(code = 0)]
const ELogOfZero: vector<u8> = "Logarithm of zero is undefined";

// === Package Functions ===

/// Returns the raw fixed-point scale shared by `UD30x9` and `SD29x9`.
///
/// #### Returns
/// - The `10^9` scale factor used to encode one whole unit.
public(package) macro fun scale(): u128 {
    1_000_000_000 // 10^9
}

/// Returns the raw fixed-point scale as `u256`.
///
/// #### Returns
/// - The `10^9` scale factor promoted to `u256`.
public(package) macro fun scale_u256(): u256 {
    1_000_000_000u256 // 10^9
}

/// Returns the sign bit used by `SD29x9`.
///
/// #### Returns
/// - The `1 << 127` bit mask.
public(package) macro fun sign_bit(): u128 {
    1u128 << 127
}

/// Returns the maximum positive raw magnitude representable by `SD29x9`.
///
/// #### Returns
/// - `2^127 - 1`.
public(package) macro fun max_sd29x9_magnitude(): u128 {
    0x7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF // 2^127 - 1
}

/// Returns the most-negative raw value representable by `SD29x9`.
///
/// #### Returns
/// - The two's-complement encoding of `-2^127`.
public(package) macro fun min_sd29x9_value(): u128 {
    0x8000_0000_0000_0000_0000_0000_0000_0000 // -2^127 in two's complement
}

/// Returns the largest whole unsigned integer that can be converted into
/// `UD30x9` without overflowing after scaling by `10^9`.
///
/// #### Returns
/// - `floor(u128::MAX / 10^9)`.
public(package) macro fun max_ud30x9_whole(): u128 {
    std::u128::max_value!() / scale!()
}

/// Returns the largest whole-magnitude integer that can be converted into
/// `SD29x9` without overflowing after scaling by `10^9`.
///
/// This bound applies to both positive and negative whole numbers. Because
/// `SD29x9` stores values in signed two's-complement form, negative whole
/// conversions accept a magnitude plus a sign flag instead of a native signed
/// integer input.
///
/// #### Returns
/// - `floor((2^127 - 1) / 10^9)`.
public(package) macro fun max_sd29x9_whole(): u128 {
    max_sd29x9_magnitude!() / scale!()
}

/// Divides `numerator` by `denominator` and rounds up when the division is inexact.
///
/// #### Parameters
/// - `numerator`: Dividend.
/// - `denominator`: Divisor. Must be non-zero.
///
/// #### Returns
/// - `numerator / denominator` when exact, otherwise that quotient plus one.
public(package) fun div_away_u256(numerator: u256, denominator: u256): u256 {
    let quotient = numerator / denominator;
    if (quotient * denominator == numerator) {
        quotient
    } else {
        quotient + 1
    }
}

/// `ln(2)` represented at scale `10^18`, rounded down.
///
/// #### Returns
/// - `floor(ln(2) * 10^18) = 693_147_180_559_945_309`.
public(package) macro fun ln2_e18(): u128 {
    693_147_180_559_945_309
}

/// `log10(2)` represented at scale `10^18`, rounded down.
///
/// #### Returns
/// - `floor(log10(2) * 10^18) = 301_029_995_663_981_195`.
public(package) macro fun log10_2_e18(): u128 {
    301_029_995_663_981_195
}

/// Internal precision used by the fixed-point logarithm kernel: `10^18`
/// (~`2^60`), an order of magnitude finer than the user-facing `10^9` scale.
///
/// The 18-decimal internal scale gives the squaring loop enough headroom for
/// inputs near `1.0`: a 9-decimal variant would not resolve the fractional
/// bits the loop sets when `y` starts close to `1`. The overall kernel
/// precision bound is documented on `raw_log2`.
const INTERNAL_LOG_SCALE: u128 = 1_000_000_000_000_000_000; // 10^18

/// Scale-correction denominator for `apply_log2_factor`: two scale-`10^18`
/// factors yield a scale-`10^36` product; dividing by `10^27` lands the result
/// at the user-facing scale `10^9`.
const LOG_FACTOR_DENOM_E27: u128 = 1_000_000_000_000_000_000_000_000_000; // 10^27

/// Combines a `raw_log2` magnitude with a base-conversion factor and returns
/// the result at the user-facing `10^9` scale.
///
/// Used by `ln` (factor = `ln2_e18!()`) and `log10` (factor = `log10_2_e18!()`)
/// on both `UD30x9` and `SD29x9` to derive their result from a single `log2`
/// kernel call. Rounds toward zero.
///
/// #### Parameters
/// - `log2_mag_e18`: Output magnitude from `raw_log2`, at scale `10^18`.
/// - `factor_e18`: Base-conversion factor at scale `10^18`.
///
/// #### Returns
/// - The magnitude at scale `10^9`, ready to wrap into `UD30x9` or `SD29x9`
///   raw form.
public(package) fun apply_log2_factor(log2_mag_e18: u128, factor_e18: u128): u128 {
    // `log2_mag_e18 < 2^67` and `factor_e18 < 2^60`, so the product reaches up
    // to ~2^127 — right at the `u128` boundary. `u128::mul_div` widens the
    // product to `u256` internally before dividing, so the intermediate value
    // never overflows; the final quotient (after `/ 10^27`) safely fits back
    // in `u128`.
    u128::mul_div(log2_mag_e18, factor_e18, LOG_FACTOR_DENOM_E27, rounding::down()).destroy_some()
}

/// Computes the base-2 logarithm of `x_raw / 10^9` in high precision.
///
/// Returns the result as a sign flag plus an unsigned magnitude scaled by
/// `10^18`. The caller assembles the final `UD30x9` or `SD29x9` value.
///
/// The algorithm normalizes the input to `y in [10^9, 2 * 10^9)` (tracking the
/// signed integer part `n`), lifts `y` to scale `10^18`, then iteratively
/// squares it: each time the square crosses `2 * 10^18`, the corresponding
/// fractional bit of `log2(y)` is set.
///
/// #### Parameters
/// - `x_raw`: Raw `UD30x9` representation of a strictly positive real number.
///
/// #### Returns
/// - `(neg, magnitude)` where `neg` indicates whether `log2(x_raw / 10^9)` is
///   negative and `magnitude` is its absolute value scaled by `10^18`.
///
/// #### Aborts
/// - `ELogOfZero` if `x_raw` is zero.
///
/// #### Precision
/// The magnitude is at most 2 user-facing ulps below the true value,
/// monotone-down. The dominant loss is the `x_raw >> n` truncation in the
/// `x_raw >= scale` branch (with `n = floor(log2(x_raw / 10^9))`), which
/// discards up to `n` low-order bits — so the deficit grows with `n` and
/// reaches the 2-ulp ceiling at `x_raw = u128::MAX`. The `x_raw < scale`
/// branch performs a lossless left shift and stays in the sub-ulp regime.
public(package) fun raw_log2(x_raw: u128): (bool, u128) {
    assert!(x_raw > 0, ELogOfZero);

    let scale: u128 = scale!();
    let internal: u128 = INTERNAL_LOG_SCALE;

    // Normalize so the real value is in `[1, 2)`, tracking the signed integer
    // part of `log2`.
    let (neg, n_abs, y_at_scale): (bool, u8, u128) = if (x_raw >= scale) {
        let n = u128::log2(x_raw / scale, rounding::down());
        (false, n, x_raw >> n)
    } else {
        // For sub-1 inputs the msb gap can under-estimate the shift by one
        // when the leading bit of `x_raw` lies above `2^msb(scale)` yet
        // `x_raw` itself is still below `scale`; the explicit `< scale` check
        // repairs that without enumerating cases.
        let mut shift = u128::msb(scale) - u128::msb(x_raw);
        let mut shifted = x_raw << shift;
        if (shifted < scale) {
            shift = shift + 1;
            shifted = shifted << 1;
        };
        (true, shift, shifted)
    };

    // Lift from scale `10^9` to scale `10^18` for the iteration. The loop
    // preserves the invariant `y < 2 * internal` (initially `y_at_scale * scale
    // < 2 * 10^18`; restored each iteration by the `y >> 1` halving below).
    // Hence `y * y < (2 * internal)^2 < 2^122` always fits in `u128`.
    let mut y: u128 = y_at_scale * scale;
    let internal_x2: u128 = 2 * internal;

    let mut frac: u128 = 0;
    let mut delta: u128 = internal / 2;
    while (delta > 0) {
        y = y * y / internal;
        if (y >= internal_x2) {
            frac = frac + delta;
            y = y >> 1;
        };
        delta = delta >> 1;
    };

    // `log2(x_real) = +/- n_abs + frac / 10^18`. For negative results the
    // fractional part lives below the integer step, so it subtracts from the
    // magnitude rather than adding to it.
    let n_x_internal: u128 = (n_abs as u128) * internal;
    let magnitude: u128 = if (neg) n_x_internal - frac else n_x_internal + frac;
    (neg, magnitude)
}

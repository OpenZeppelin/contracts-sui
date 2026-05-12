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

/// Internal precision used by the fixed-point logarithm kernel: `10^18`
/// (~`2^60`), an order of magnitude finer than the user-facing `10^9` scale.
///
/// Error analysis: in the squaring loop, error in `y` grows ~2× per iteration
/// (since `y_new = y_old^2 / internal`), but a wrong bit at iteration `i`
/// only perturbs `frac` by `internal / 2^(i+1)` — exponentially decaying, so
/// late-iteration errors contribute little. Empirically the total `frac`
/// error stays under `~10^3` at scale `10^18` (verified by `raw_log2_tests`),
/// well below one user-facing ulp (`10^9`).
///
/// A 9-decimal variant of the same algorithm fails this analysis for inputs
/// near `1.0` where the true magnitude is just a few ulps: the early-iteration
/// error budget swamps the answer. Empirically `raw_log2(SCALE - 1)` at
/// 9-decimal returns magnitude `13` while the true magnitude is `~1.443`.
/// 18-decimal preserves precision in that regime.
///
/// #### Returns
/// - `10^18` as `u256`.
public(package) macro fun internal_log_scale(): u256 {
    1_000_000_000_000_000_000u256 // 10^18
}

/// Combined denominator (`internal_log_scale * scale = 10^27`) used by `ln` /
/// `log10`. A magnitude at scale `10^18` multiplied by a constant at scale
/// `10^18` lives at scale `10^36`; dividing by `10^27` lands the result at
/// scale `10^9`, which is the `UD30x9` raw representation.
///
/// #### Returns
/// - `10^27` as `u256`.
public(package) macro fun internal_times_scale(): u256 {
    1_000_000_000_000_000_000_000_000_000u256 // 10^27
}

/// `ln(2)` represented at scale `10^18`, rounded down.
///
/// #### Returns
/// - `floor(ln(2) * 10^18) = 693_147_180_559_945_309`.
public(package) macro fun ln2_e18(): u256 {
    693_147_180_559_945_309u256
}

/// `log10(2)` represented at scale `10^18`, rounded down.
///
/// #### Returns
/// - `floor(log10(2) * 10^18) = 301_029_995_663_981_195`.
public(package) macro fun log10_2_e18(): u256 {
    301_029_995_663_981_195u256
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
public(package) fun raw_log2(x_raw: u128): (bool, u256) {
    assert!(x_raw > 0, ELogOfZero);

    let scale: u128 = scale!();
    let internal: u128 = 1_000_000_000_000_000_000; // 10^18

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

    // Lift from scale `10^9` to scale `10^18` for the iteration. After lift
    // `y < 2 * 10^18 < 2^61`, so `y * y < 2^122` fits in `u128`.
    let mut y: u128 = y_at_scale * scale;
    let two_internal: u128 = 2 * internal;

    let mut frac: u128 = 0;
    let mut delta: u128 = internal / 2;
    while (delta > 0) {
        y = y * y / internal;
        if (y >= two_internal) {
            frac = frac + delta;
            y = y >> 1;
        };
        delta = delta >> 1;
    };

    // `log2(x_real) = +/- n_abs + frac / 10^18`. For negative results the
    // fractional part lives below the integer step, so it subtracts from the
    // magnitude rather than adding to it.
    let n_internal: u128 = (n_abs as u128) * internal;
    let magnitude: u128 = if (neg) n_internal - frac else n_internal + frac;
    (neg, magnitude as u256)
}

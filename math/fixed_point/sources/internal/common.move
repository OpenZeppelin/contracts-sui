/// Shared helpers for fixed-point package-wide constants and conversions.
///
/// The public `ud30x9` and `sd29x9` modules intentionally expose low-level
/// `wrap`/`unwrap` APIs over raw scaled representations. Conversion helpers
/// live separately and reuse the constants in this module to keep scale-aware
/// bounds, sign handling, and terminology consistent across the package.
module openzeppelin_fp_math::common;

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

/// Returns the square root of a number. If the number is not a perfect square, the value is rounded
/// towards zero.
///
/// This method is based on Newton's method for computing square roots. The algorithm is restricted to only
/// using integer operations.
///
/// #### Parameters
/// - `a`: Input value.
///
/// #### Returns
/// - `floor(sqrt(a))`.
public(package) fun sqrt_floor(a: u256): u256 {
    // Take care of easy edge cases: sqrt(0) = 0 and sqrt(1) = 1
    if (a <= 1) {
        return a
    };
    let mut aa = a;
    let mut xn = 1;

    // In this function, we use Newton's method to get a root of `f(x) := x² - a`. It involves building a
    // sequence x_n that converges toward sqrt(a). For each iteration x_n, we also define the error between
    // the current value as `ε_n = | x_n - sqrt(a) |`.
    //
    // For our first estimation, we consider `e` the smallest power of 2 which is bigger than the square root
    // of the target. (i.e. `2**(e-1) ≤ sqrt(a) < 2**e`). We know that `e ≤ 128` because `(2¹²⁸)² = 2²⁵⁶` is
    // bigger than any uint256.
    //
    // By noticing that
    // `2**(e-1) ≤ sqrt(a) < 2**e → (2**(e-1))² ≤ a < (2**e)² → 2**(2*e-2) ≤ a < 2**(2*e)`
    // we can deduce that `e - 1` is `log2(a) / 2`. We can thus compute `x_n = 2**(e-1)` using a method similar
    // to the msb function.
    if (aa >= (1 << 128)) {
        aa = aa >> 128;
        xn = xn << 64;
    };
    if (aa >= (1 << 64)) {
        aa = aa >> 64;
        xn = xn << 32;
    };
    if (aa >= (1 << 32)) {
        aa = aa >> 32;
        xn = xn << 16;
    };
    if (aa >= (1 << 16)) {
        aa = aa >> 16;
        xn = xn << 8;
    };
    if (aa >= (1 << 8)) {
        aa = aa >> 8;
        xn = xn << 4;
    };
    if (aa >= (1 << 4)) {
        aa = aa >> 4;
        xn = xn << 2;
    };
    if (aa >= (1 << 2)) {
        xn = xn << 1;
    };

    // We now have x_n such that `x_n = 2**(e-1) ≤ sqrt(a) < 2**e = 2 * x_n`. This implies ε_n ≤ 2**(e-1).
    //
    // We can refine our estimation by noticing that the middle of that interval minimizes the error.
    // If we move x_n to equal 2**(e-1) + 2**(e-2), then we reduce the error to ε_n ≤ 2**(e-2).
    // This is going to be our x_0 (and ε_0).
    xn = (3 * xn) >> 1; // ε_0 := | x_0 - sqrt(a) | ≤ 2**(e-2)

    // From here, Newton's method give us:
    // x_{n+1} = (x_n + a / x_n) / 2
    //
    // One should note that:
    // x_{n+1}² - a = ((x_n + a / x_n) / 2)² - a
    //              = ((x_n² + a) / (2 * x_n))² - a
    //              = (x_n⁴ + 2 * a * x_n² + a²) / (4 * x_n²) - a
    //              = (x_n⁴ + 2 * a * x_n² + a² - 4 * a * x_n²) / (4 * x_n²)
    //              = (x_n⁴ - 2 * a * x_n² + a²) / (4 * x_n²)
    //              = (x_n² - a)² / (2 * x_n)²
    //              = ((x_n² - a) / (2 * x_n))²
    //              ≥ 0
    // Which proves that for all n ≥ 1, sqrt(a) ≤ x_n
    //
    // This gives us the proof of quadratic convergence of the sequence:
    // ε_{n+1} = | x_{n+1} - sqrt(a) |
    //         = | (x_n + a / x_n) / 2 - sqrt(a) |
    //         = | (x_n² + a - 2*x_n*sqrt(a)) / (2 * x_n) |
    //         = | (x_n - sqrt(a))² / (2 * x_n) |
    //         = | ε_n² / (2 * x_n) |
    //         = ε_n² / | (2 * x_n) |
    //
    // For the first iteration, we have a special case where x_0 is known:
    // ε_1 = ε_0² / | (2 * x_0) |
    //     ≤ (2**(e-2))² / (2 * (2**(e-1) + 2**(e-2)))
    //     ≤ 2**(2*e-4) / (3 * 2**(e-1))
    //     ≤ 2**(e-3) / 3
    //     ≤ 2**(e-3-log2(3))
    //     ≤ 2**(e-4.5)
    //
    // For the following iterations, we use the fact that, 2**(e-1) ≤ sqrt(a) ≤ x_n:
    // ε_{n+1} = ε_n² / | (2 * x_n) |
    //         ≤ (2**(e-k))² / (2 * 2**(e-1))
    //         ≤ 2**(2*e-2*k) / 2**e
    //         ≤ 2**(e-2*k)
    xn = (xn + a / xn) >> 1; // ε_1 := | x_1 - sqrt(a) | ≤ 2**(e-4.5)  -- special case, see above
    xn = (xn + a / xn) >> 1; // ε_2 := | x_2 - sqrt(a) | ≤ 2**(e-9)    -- general case with k = 4.5
    xn = (xn + a / xn) >> 1; // ε_3 := | x_3 - sqrt(a) | ≤ 2**(e-18)   -- general case with k = 9
    xn = (xn + a / xn) >> 1; // ε_4 := | x_4 - sqrt(a) | ≤ 2**(e-36)   -- general case with k = 18
    xn = (xn + a / xn) >> 1; // ε_5 := | x_5 - sqrt(a) | ≤ 2**(e-72)   -- general case with k = 36
    xn = (xn + a / xn) >> 1; // ε_6 := | x_6 - sqrt(a) | ≤ 2**(e-144)  -- general case with k = 72

    // Because e ≤ 128 (as discussed during the first estimation phase), we now have reached a precision
    // ε_6 ≤ 2**(e-144) < 1. Given we're operating on integers, then we can ensure that xn is now either
    // sqrt(a) or sqrt(a) + 1.
    if (xn > a / xn) {
        xn - 1
    } else {
        xn
    }
}

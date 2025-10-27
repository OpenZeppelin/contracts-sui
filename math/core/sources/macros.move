//! This module provides a 512-bit unsigned integer type that is intended to be used as an
//! intermediary step for u256 operations that may overflow, rather than being used directly
//! like other integer types. It enables safe handling of intermediate calculations that exceed
//! u256 bounds before being reduced back to u256.

module openzeppelin_math::macros;

use openzeppelin_math::rounding::{Self, RoundingMode};
use openzeppelin_math::u512;

#[error(code = 0)]
const EDivideByZero: vector<u8> = b"Divisor must be non-zero";

/// Multiply `a` and `b`, divide by `denominator`, and round according to `rounding_mode`.
///
/// This macro provides a uniform API for `mul_div` across all unsigned integer widths. It normalises
/// the inputs to `u256`, chooses the most efficient helper, and returns the rounded quotient alongside
/// an overflow flag. Narrower wrapper modules downcast the result after ensuring it fits. Undefined
/// divisions (e.g. denominator = 0) abort with descriptive error codes.
///
/// #### Generics
/// - `$Int`: Any unsigned integer type (`u8`, `u16`, `u32`, `u64`, `u128`, or `u256`).
///
/// #### Parameters
/// - `$a`, `$b`: Unsigned factors.
/// - `$denominator`: Unsigned divisor.
/// - `$rounding_mode`: Rounding strategy.
///
/// #### Returns
/// `(overflow, result)` where `overflow` is `true` when the rounded quotient exceeds `u256::MAX` and
/// `result` carries the rounded value when no overflow occurred.
///
/// #### Aborts
/// Propagates the same error codes as the underlying helpers (`EDivideByZero`).
public(package) macro fun mul_div<$Int>(
    $a: $Int,
    $b: $Int,
    $denominator: $Int,
    $rounding_mode: RoundingMode,
): (bool, u256) {
    let a_u256 = ($a as u256);
    let b_u256 = ($b as u256);
    let denominator_u256 = ($denominator as u256);
    let rounding_mode = $rounding_mode;

    mul_div_inner(a_u256, b_u256, denominator_u256, rounding_mode)
}

/// === Helper functions ===

/// Multiply two `u256` values, divide by `denominator`, and round the result without widening.
///
/// This helper assumes both operands fit within `u128`, which allows us to perform the entire
/// computation in native `u256` space. That keeps the code fast and avoids allocating the full
/// 512-bit intermediate representation. Rounding is applied according to `rounding_mode`.
///
/// #### Parameters
/// - `a`, `b`: Unsigned factors whose product stays below 2^256.
/// - `denominator`: Unsigned divisor, must be non-zero.
/// - `rounding_mode`: Rounding strategy drawn from `rounding::RoundingMode`.
///
/// #### Returns
/// The rounded quotient as a `u256`.
///
/// #### Aborts
/// - `EDivideByZero` if `denominator` is zero.
public(package) fun mul_div_u256_fast(
    a: u256,
    b: u256,
    denominator: u256,
    rounding_mode: RoundingMode,
): u256 {
    assert!(denominator != 0, EDivideByZero);

    let numerator = a * b;
    let mut quotient = numerator / denominator;
    let remainder = numerator % denominator;

    if (remainder != 0) {
        let should_round_up = if (rounding_mode == rounding::up()) {
            true
        } else if (rounding_mode == rounding::nearest()) {
            remainder >= denominator - remainder
        } else {
            false
        };

        if (should_round_up) {
            quotient = quotient + 1;
        }
    };

    quotient
}

/// Multiply two `u256` values with full 512-bit precision before dividing and rounding.
///
/// This variant handles the general case where `a * b` may exceed 2^256. It widens the product to
/// a 512-bit value, performs an exact division, and then applies rounding. If the true quotient does
/// not fit back into 256 bits or rounding would push it past the maximum value, the helper returns
/// `(true, _)` to signal overflow.
///
/// #### Parameters
/// - `a`, `b`: Unsigned factors up to 2^256 - 1.
/// - `denominator`: Unsigned divisor, must be non-zero.
/// - `rounding_mode`: Rounding strategy drawn from `rounding::RoundingMode`.
///
/// #### Returns
/// `(overflow, result)` where `overflow` indicates whether the exact (or rounded) quotient exceeds
/// the `u256` range. `result` is only meaningful when `overflow` is `false`.
///
/// #### Aborts
/// - `EDivideByZero` if `denominator` is zero.
public(package) fun mul_div_u256_wide(
    a: u256,
    b: u256,
    denominator: u256,
    rounding_mode: RoundingMode,
): (bool, u256) {
    assert!(denominator != 0, EDivideByZero);

    let numerator = u512::mul_u256(a, b);
    let (overflow, mut quotient, remainder) = u512::div_rem_u256(numerator, denominator);
    if (overflow) {
        return (true, 0)
    };

    if (remainder != 0) {
        let should_round_up = if (rounding_mode == rounding::up()) {
            true
        } else if (rounding_mode == rounding::nearest()) {
            remainder >= denominator - remainder
        } else {
            false
        };

        if (should_round_up) {
            if (quotient == std::u256::max_value!()) {
                return (true, 0)
            };
            quotient = quotient + 1;
        }
    };

    (false, quotient)
}

/// Internal helper for `mul_div` that selects the most efficient implementation based on the input size.
/// Returns `(overflow, quotient)` mirroring the macro implementation.
public(package) fun mul_div_inner(
    a: u256,
    b: u256,
    denominator: u256,
    rounding_mode: RoundingMode,
): (bool, u256) {
    let max_small = std::u128::max_value!() as u256;
    if (a > max_small || b > max_small) {
        mul_div_u256_wide(a, b, denominator, rounding_mode)
    } else {
        let quotient = mul_div_u256_fast(a, b, denominator, rounding_mode);
        (false, quotient)
    }
}

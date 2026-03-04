/// Functions for arithmetic on 128-bit unsigned integers.
///
/// This module provides wrappers around the shared `macros` helpers specialised to `u128`.
/// They expose a consistent API surface (e.g. `mul_div`, `mul_shr`, `inv_mod`) while
/// handling width-specific concerns such as downcasting and bit-width limits.
module openzeppelin_math::u128;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::RoundingMode;

const BIT_WIDTH: u8 = 128;

/// Compute the arithmetic mean of two `u128` values with configurable rounding.
///
/// #### Parameters
/// - `a`: First operand.
/// - `b`: Second operand.
/// - `rounding_mode`: Rounding strategy.
///
/// #### Returns
/// - The rounded arithmetic mean of `a` and `b`.
public fun average(a: u128, b: u128, rounding_mode: RoundingMode): u128 {
    macros::average!(a, b, rounding_mode)
}

/// Shift the value left by the given number of bits.
///
/// Attempts to left shift `value` by `shift` while preserving all significant bits.
/// If the operation would truncate non-zero bits, returns `None` instead of silently
/// losing information.
///
/// #### Parameters
/// - `value`: The input value to shift.
/// - `shift`: Number of bits to shift left.
///
/// #### Returns
/// - `option::some(shifted)` when the shift is valid and lossless.
/// - `option::none()` if the shift would consume non-zero bits.
public fun checked_shl(value: u128, shift: u8): Option<u128> {
    if (value == 0) {
        option::some(0)
    } else if (shift >= BIT_WIDTH) {
        option::none()
    } else {
        macros::checked_shl!(value, shift)
    }
}

/// Shift the value right by the given number of bits.
///
/// Attempts to right shift `value` by `shift` while preserving all significant bits.
/// If the operation would truncate non-zero bits, returns `None` instead of silently
/// losing information.
///
/// #### Parameters
/// - `value`: The input value to shift.
/// - `shift`: Number of bits to shift right.
///
/// #### Returns
/// - `option::some(shifted)` when the shift is valid and lossless.
/// - `option::none()` if the shift would consume non-zero bits.
public fun checked_shr(value: u128, shift: u8): Option<u128> {
    if (value == 0) {
        option::some(0)
    } else if (shift >= BIT_WIDTH) {
        option::none()
    } else {
        macros::checked_shr!(value, shift)
    }
}

/// Multiply `a` and `b`, divide by `denominator`, and round according to `rounding_mode`.
///
/// #### Parameters
/// - `a`: First factor.
/// - `b`: Second factor.
/// - `denominator`: Divisor.
/// - `rounding_mode`: Rounding strategy.
///
/// #### Returns
/// - `option::some(result)` when the rounded quotient fits in `u128`.
/// - `option::none()` when the rounded quotient cannot be represented as `u128`.
///
/// #### Aborts
/// - Aborts if `denominator` is zero.
public fun mul_div(a: u128, b: u128, denominator: u128, rounding_mode: RoundingMode): Option<u128> {
    let (_, result) = macros::mul_div!(a, b, denominator, rounding_mode);
    result.try_as_u128()
}

/// Multiply `a` and `b`, shift the product right by `shift`, and round according to `rounding_mode`.
///
/// #### Parameters
/// - `a`: First factor.
/// - `b`: Second factor.
/// - `shift`: Number of bits to shift right.
/// - `rounding_mode`: Rounding strategy.
///
/// #### Returns
/// - `option::some(result)` when the rounded value fits in `u128`.
/// - `option::none()` when the rounded value cannot be represented as `u128`.
public fun mul_shr(a: u128, b: u128, shift: u8, rounding_mode: RoundingMode): Option<u128> {
    let (_, result) = macros::mul_shr!(a, b, shift, rounding_mode);
    result.try_as_u128()
}

/// Count the number of leading zero bits in `value`.
///
/// #### Parameters
/// - `value`: Input value.
///
/// #### Returns
/// - Number of leading zero bits.
public fun clz(value: u128): u8 {
    macros::clz!(value, BIT_WIDTH as u16) as u8
}

/// Return the position of the most significant bit in the value.
///
/// #### Parameters
/// - `value`: Input value.
///
/// #### Returns
/// - Zero-based index of the most significant bit.
/// - Returns `0` if `value` is `0`.
public fun msb(value: u128): u8 {
    macros::msb!(value, BIT_WIDTH as u16)
}

/// Compute the log in base 2 of a positive value with configurable rounding.
///
/// #### Parameters
/// - `value`: Input value.
/// - `rounding_mode`: Rounding strategy.
///
/// #### Returns
/// - Base-2 logarithm rounded according to `rounding_mode`.
/// - Returns `0` if `value` is `0`.
public fun log2(value: u128, rounding_mode: RoundingMode): u8 {
    macros::log2!(value, BIT_WIDTH as u16, rounding_mode) as u8
}

/// Compute the log in base 256 of a positive value with configurable rounding.
///
/// #### Parameters
/// - `value`: Input value.
/// - `rounding_mode`: Rounding strategy.
///
/// #### Returns
/// - Base-256 logarithm rounded according to `rounding_mode`.
/// - Returns `0` if `value` is `0`.
public fun log256(value: u128, rounding_mode: RoundingMode): u8 {
    macros::log256!(value, BIT_WIDTH as u16, rounding_mode)
}

/// Compute the log in base 10 of a positive value with configurable rounding.
///
/// #### Parameters
/// - `value`: Input value.
/// - `rounding_mode`: Rounding strategy.
///
/// #### Returns
/// - Base-10 logarithm rounded according to `rounding_mode`.
/// - Returns `0` if `value` is `0`.
public fun log10(value: u128, rounding_mode: RoundingMode): u8 {
    macros::log10!(value, rounding_mode)
}

/// Compute the square root of a value with configurable rounding.
///
/// #### Parameters
/// - `value`: Input value.
/// - `rounding_mode`: Rounding strategy.
///
/// #### Returns
/// - Square root rounded according to `rounding_mode`.
/// - Returns `0` if `value` is `0`.
public fun sqrt(value: u128, rounding_mode: RoundingMode): u128 {
    macros::sqrt!(value, rounding_mode)
}

/// Compute the modular multiplicative inverse of `value` in `Z / modulus`.
///
/// #### Parameters
/// - `value`: Value to invert.
/// - `modulus`: Modulus for arithmetic.
///
/// #### Returns
/// - `option::some(inverse)` when `value` and `modulus` are co-prime.
/// - `option::none()` when `value` and `modulus` are not co-prime, or when `modulus` is 1.
///
/// #### Aborts
/// - Aborts if `modulus` is zero.
public fun inv_mod(value: u128, modulus: u128): Option<u128> {
    macros::inv_mod!(value, modulus)
}

/// Multiply `a` and `b` modulo `modulus`.
///
/// #### Parameters
/// - `a`: First factor.
/// - `b`: Second factor.
/// - `modulus`: Modulus for arithmetic.
///
/// #### Returns
/// - `(a * b) mod modulus`.
///
/// #### Aborts
/// - Aborts if `modulus` is zero.
public fun mul_mod(a: u128, b: u128, modulus: u128): u128 {
    macros::mul_mod!(a, b, modulus)
}

/// Returns true if the value is a power of ten (1, 10, 100, ...)
///
/// Uses a lookup table with binary search for efficiency.
/// For u128, valid powers of ten range from 10^0 to 10^38.
public fun is_power_of_ten(n: u128): bool {
    // Powers of 10 from 10^0 to 10^38 for u128
    let powers = vector[
        1u128,
        10u128,
        100u128,
        1000u128,
        10000u128,
        100000u128,
        1000000u128,
        10000000u128,
        100000000u128,
        1000000000u128,
        10000000000u128,
        100000000000u128,
        1000000000000u128,
        10000000000000u128,
        100000000000000u128,
        1000000000000000u128,
        10000000000000000u128,
        100000000000000000u128,
        1000000000000000000u128,
        10000000000000000000u128,
        100000000000000000000u128,
        1000000000000000000000u128,
        10000000000000000000000u128,
        100000000000000000000000u128,
        1000000000000000000000000u128,
        10000000000000000000000000u128,
        100000000000000000000000000u128,
        1000000000000000000000000000u128,
        10000000000000000000000000000u128,
        100000000000000000000000000000u128,
        1000000000000000000000000000000u128,
        10000000000000000000000000000000u128,
        100000000000000000000000000000000u128,
        1000000000000000000000000000000000u128,
        10000000000000000000000000000000000u128,
        100000000000000000000000000000000000u128,
        1000000000000000000000000000000000000u128,
        10000000000000000000000000000000000000u128,
        100000000000000000000000000000000000000u128,
    ];

    macros::binary_search!(powers, n)
}

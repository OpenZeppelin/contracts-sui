/// Functions for arithmetic on 16-bit unsigned integers.
///
/// This module provides wrappers around the shared `macros` helpers specialised to `u16`.
/// They expose a consistent API surface (e.g. `mul_div`, `mul_shr`, `inv_mod`) while
/// handling width-specific concerns such as downcasting and bit-width limits.
module openzeppelin_math::u16;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::RoundingMode;

const BIT_WIDTH: u8 = 16;

/// Compute the arithmetic mean of two `u16` values with configurable rounding.
///
/// #### Parameters
/// - `a`: First operand.
/// - `b`: Second operand.
/// - `rounding_mode`: Rounding strategy.
///
/// #### Returns
/// - The rounded arithmetic mean of `a` and `b`.
public fun average(a: u16, b: u16, rounding_mode: RoundingMode): u16 {
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
public fun checked_shl(value: u16, shift: u8): Option<u16> {
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
public fun checked_shr(value: u16, shift: u8): Option<u16> {
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
/// - `option::some(result)` when the rounded quotient fits in `u16`.
/// - `option::none()` when the rounded quotient cannot be represented as `u16`.
///
/// #### Aborts
/// - Aborts if `denominator` is zero.
public fun mul_div(a: u16, b: u16, denominator: u16, rounding_mode: RoundingMode): Option<u16> {
    let (_, result) = macros::mul_div!(a, b, denominator, rounding_mode);
    result.try_as_u16()
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
/// - `option::some(result)` when the rounded value fits in `u16`.
/// - `option::none()` when the rounded value cannot be represented as `u16`.
public fun mul_shr(a: u16, b: u16, shift: u8, rounding_mode: RoundingMode): Option<u16> {
    let (_, result) = macros::mul_shr!(a, b, shift, rounding_mode);
    result.try_as_u16()
}

/// Count the number of leading zero bits in `value`.
///
/// #### Parameters
/// - `value`: Input value.
///
/// #### Returns
/// - Number of leading zero bits.
public fun clz(value: u16): u8 {
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
public fun msb(value: u16): u8 {
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
public fun log2(value: u16, rounding_mode: RoundingMode): u8 {
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
public fun log256(value: u16, rounding_mode: RoundingMode): u8 {
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
public fun log10(value: u16, rounding_mode: RoundingMode): u8 {
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
public fun sqrt(value: u16, rounding_mode: RoundingMode): u16 {
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
public fun inv_mod(value: u16, modulus: u16): Option<u16> {
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
public fun mul_mod(a: u16, b: u16, modulus: u16): u16 {
    macros::mul_mod!(a, b, modulus)
}

/// Returns `true` if `n` is a power of ten.
///
/// For `u16`, valid powers of ten are: 1, 10, 100, 1000, 10000.
///
/// #### Parameters
/// - `n`: Input value.
///
/// #### Returns
/// - `true` if `n` is a power of ten within the `u16` range, otherwise `false`.
public fun is_power_of_ten(n: u16): bool {
    n == 1 || n == 10 || n == 100 || n == 1000 || n == 10000
}

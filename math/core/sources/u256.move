/// Functions for arithmetic on 256-bit unsigned integers.
///
/// This module provides wrappers around the shared `macros` helpers specialised to `u256`.
/// They expose a consistent API surface (e.g. `mul_div`, `mul_shr`, `inv_mod`) while
/// handling width-specific concerns such as downcasting and bit-width limits.
module openzeppelin_math::u256;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::RoundingMode;

/// Bit width for `u256`.
///
/// Stored as `u16` because 256 cannot be represented as `u8`.
const BIT_WIDTH: u16 = 256;

/// Compute the arithmetic mean of two `u256` values with configurable rounding.
///
/// #### Parameters
/// - `a`: First operand.
/// - `b`: Second operand.
/// - `rounding_mode`: Rounding strategy.
///
/// #### Returns
/// - The rounded arithmetic mean of `a` and `b`.
public fun average(a: u256, b: u256, rounding_mode: RoundingMode): u256 {
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
public fun checked_shl(value: u256, shift: u8): Option<u256> {
    if (value == 0) {
        option::some(0)
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
public fun checked_shr(value: u256, shift: u8): Option<u256> {
    if (value == 0) {
        option::some(0)
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
/// - `option::some(result)` when the rounded quotient fits in `u256`.
/// - `option::none()` when the rounded quotient cannot be represented as `u256`.
///
/// #### Aborts
/// - Aborts if `denominator` is zero.
public fun mul_div(a: u256, b: u256, denominator: u256, rounding_mode: RoundingMode): Option<u256> {
    let (overflow, result) = macros::mul_div!(a, b, denominator, rounding_mode);
    if (overflow) {
        option::none()
    } else {
        option::some(result)
    }
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
/// - `option::some(result)` when the rounded value fits in `u256`.
/// - `option::none()` when the rounded value cannot be represented as `u256`.
public fun mul_shr(a: u256, b: u256, shift: u8, rounding_mode: RoundingMode): Option<u256> {
    let (overflow, result) = macros::mul_shr!(a, b, shift, rounding_mode);
    if (overflow) {
        option::none()
    } else {
        option::some(result)
    }
}

/// Count the number of leading zero bits in the value.
///
/// #### Parameters
/// - `value`: Input value.
///
/// #### Returns
/// - Number of leading zero bits as `u16`.
/// - `u16` is used because the maximum result for `u256` is 256.
public fun clz(value: u256): u16 {
    macros::clz!(value, BIT_WIDTH)
}

/// Return the position of the most significant bit in the value.
///
/// #### Parameters
/// - `value`: Input value.
///
/// #### Returns
/// - Zero-based index of the most significant bit.
/// - Returns `0` if `value` is `0`.
public fun msb(value: u256): u8 {
    macros::msb!(value, BIT_WIDTH)
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
/// - Returns `u16` because the rounded result can be 256.
public fun log2(value: u256, rounding_mode: RoundingMode): u16 {
    macros::log2!(value, BIT_WIDTH, rounding_mode)
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
public fun log256(value: u256, rounding_mode: RoundingMode): u8 {
    macros::log256!(value, BIT_WIDTH, rounding_mode)
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
public fun log10(value: u256, rounding_mode: RoundingMode): u8 {
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
public fun sqrt(value: u256, rounding_mode: RoundingMode): u256 {
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
public fun inv_mod(value: u256, modulus: u256): Option<u256> {
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
public fun mul_mod(a: u256, b: u256, modulus: u256): u256 {
    macros::mul_mod!(a, b, modulus)
}

/// Returns `true` if `n` is a power of ten.
///
/// Uses a lookup table with binary search for efficiency.
/// For `u256`, valid powers of ten range from 10^0 to 10^76.
///
/// #### Parameters
/// - `n`: Input value.
///
/// #### Returns
/// - `true` if `n` is a power of ten within the `u256` range, otherwise `false`.
public fun is_power_of_ten(n: u256): bool {
    // Powers of 10 from 10^0 to 10^76 for u256
    let powers = vector[
        1u256,
        10u256,
        100u256,
        1000u256,
        10000u256,
        100000u256,
        1000000u256,
        10000000u256,
        100000000u256,
        1000000000u256,
        10000000000u256,
        100000000000u256,
        1000000000000u256,
        10000000000000u256,
        100000000000000u256,
        1000000000000000u256,
        10000000000000000u256,
        100000000000000000u256,
        1000000000000000000u256,
        10000000000000000000u256,
        100000000000000000000u256,
        1000000000000000000000u256,
        10000000000000000000000u256,
        100000000000000000000000u256,
        1000000000000000000000000u256,
        10000000000000000000000000u256,
        100000000000000000000000000u256,
        1000000000000000000000000000u256,
        10000000000000000000000000000u256,
        100000000000000000000000000000u256,
        1000000000000000000000000000000u256,
        10000000000000000000000000000000u256,
        100000000000000000000000000000000u256,
        1000000000000000000000000000000000u256,
        10000000000000000000000000000000000u256,
        100000000000000000000000000000000000u256,
        1000000000000000000000000000000000000u256,
        10000000000000000000000000000000000000u256,
        100000000000000000000000000000000000000u256,
        1000000000000000000000000000000000000000u256,
        10000000000000000000000000000000000000000u256,
        100000000000000000000000000000000000000000u256,
        1000000000000000000000000000000000000000000u256,
        10000000000000000000000000000000000000000000u256,
        100000000000000000000000000000000000000000000u256,
        1000000000000000000000000000000000000000000000u256,
        10000000000000000000000000000000000000000000000u256,
        100000000000000000000000000000000000000000000000u256,
        1000000000000000000000000000000000000000000000000u256,
        10000000000000000000000000000000000000000000000000u256,
        100000000000000000000000000000000000000000000000000u256,
        1000000000000000000000000000000000000000000000000000u256,
        10000000000000000000000000000000000000000000000000000u256,
        100000000000000000000000000000000000000000000000000000u256,
        1000000000000000000000000000000000000000000000000000000u256,
        10000000000000000000000000000000000000000000000000000000u256,
        100000000000000000000000000000000000000000000000000000000u256,
        1000000000000000000000000000000000000000000000000000000000u256,
        10000000000000000000000000000000000000000000000000000000000u256,
        100000000000000000000000000000000000000000000000000000000000u256,
        1000000000000000000000000000000000000000000000000000000000000u256,
        10000000000000000000000000000000000000000000000000000000000000u256,
        100000000000000000000000000000000000000000000000000000000000000u256,
        1000000000000000000000000000000000000000000000000000000000000000u256,
        10000000000000000000000000000000000000000000000000000000000000000u256,
        100000000000000000000000000000000000000000000000000000000000000000u256,
        1000000000000000000000000000000000000000000000000000000000000000000u256,
        10000000000000000000000000000000000000000000000000000000000000000000u256,
        100000000000000000000000000000000000000000000000000000000000000000000u256,
        1000000000000000000000000000000000000000000000000000000000000000000000u256,
        10000000000000000000000000000000000000000000000000000000000000000000000u256,
        100000000000000000000000000000000000000000000000000000000000000000000000u256,
        1000000000000000000000000000000000000000000000000000000000000000000000000u256,
        10000000000000000000000000000000000000000000000000000000000000000000000000u256,
        100000000000000000000000000000000000000000000000000000000000000000000000000u256,
        1000000000000000000000000000000000000000000000000000000000000000000000000000u256,
        10000000000000000000000000000000000000000000000000000000000000000000000000000u256,
    ];

    macros::binary_search!(powers, n)
}

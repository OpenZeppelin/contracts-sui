module openzeppelin_math::u256;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::RoundingMode;

const BIT_WIDTH: u16 = 256;

/// Compute the arithmetic mean of two `u256` values with configurable rounding.
public fun average(a: u256, b: u256, rounding_mode: RoundingMode): u256 {
    macros::average!(a, b, rounding_mode)
}

/// Shift the value left by the given number of bits.
///
/// Returns `None` for the following cases:
/// - the shift consumes a non-zero bit when shifting left.
public fun checked_shl(value: u256, shift: u8): Option<u256> {
    if (value == 0) {
        option::some(0)
    } else {
        macros::checked_shl!(value, shift)
    }
}

/// Shift the value right by the given number of bits.
///
/// Returns `None` for the following cases:
/// - the shift consumes a non-zero bit when shifting right.
public fun checked_shr(value: u256, shift: u8): Option<u256> {
    if (value == 0) {
        option::some(0)
    } else {
        macros::checked_shr!(value, shift)
    }
}

/// Multiply `a` and `b`, divide by `denominator`, and round according to `rounding_mode`.
///
/// Returns `None` for the following cases:
/// - the rounded quotient cannot be represented as `u256`
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
/// Returns `None` for the following cases:
/// - the rounded quotient cannot be represented as `u256`
public fun mul_shr(a: u256, b: u256, shift: u8, rounding_mode: RoundingMode): Option<u256> {
    let (overflow, result) = macros::mul_shr!(a, b, shift, rounding_mode);
    if (overflow) {
        option::none()
    } else {
        option::some(result)
    }
}

/// Count the number of leading zero bits in the value.
public fun clz(value: u256): u16 {
    macros::clz!(value, BIT_WIDTH)
}

/// Return the position of the most significant bit in the value.
///
/// Returns 0 if given 0.
public fun msb(value: u256): u8 {
    macros::msb!(value, BIT_WIDTH)
}

/// Compute the log in base 2 of a positive value with configurable rounding.
///
/// Returns 0 if given 0.
public fun log2(value: u256, rounding_mode: RoundingMode): u16 {
    macros::log2!(value, BIT_WIDTH, rounding_mode)
}

/// Compute the log in base 256 of a positive value with configurable rounding.
///
/// Returns 0 if given 0.
public fun log256(value: u256, rounding_mode: RoundingMode): u8 {
    macros::log256!(value, BIT_WIDTH, rounding_mode)
}

/// Compute the log in base 10 of a positive value with configurable rounding.
///
/// Returns 0 if given 0.
public fun log10(value: u256, rounding_mode: RoundingMode): u8 {
    macros::log10!(value, rounding_mode)
}

/// Compute the square root of a value with configurable rounding.
///
/// Returns 0 if given 0.
public fun sqrt(value: u256, rounding_mode: RoundingMode): u256 {
    macros::sqrt!(value, rounding_mode)
}

/// Compute the modular multiplicative inverse of `value` in `Z / modulus`.
///
/// Returns the element `x` that satisfies `value * x ≡ 1 (mod modulus)` when it exists. Returns
/// `None` if `value` and `modulus` are not co-prime and aborts when `modulus` is zero.
public fun inv_mod(value: u256, modulus: u256): Option<u256> {
    macros::inv_mod!(value, modulus)
}

/// Multiply `a` and `b` modulo `modulus`. Aborts if `modulus` is zero.
public fun mul_mod(a: u256, b: u256, modulus: u256): u256 {
    macros::mul_mod!(a, b, modulus)
}

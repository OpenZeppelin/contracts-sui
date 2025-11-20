module openzeppelin_math::u128;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::RoundingMode;

#[error(code = 0)]
const EPow10ExponentTooLarge: vector<u8> = b"Power of 10 exponent is too large to fit in u128";

/// The bit width of the `u128` type (128 bits).
const BIT_WIDTH: u8 = 128;

/// Maximum exponent for `pow_10` that fits in `u128`.
///
/// Determined by the constraint: 10^MAX_POW_10_EXPONENT <= u128::MAX < 10^(MAX_POW_10_EXPONENT+1)
/// 10^38 = 100000000000000000000000000000000000000 ✓, 10^39 > `std::u128::max_value!()` ✗
const MAX_POW_10_EXPONENT: u8 = 38;

/// Compute the arithmetic mean of two `u128` values with configurable rounding.
public fun average(a: u128, b: u128, rounding_mode: RoundingMode): u128 {
    macros::average!(a, b, rounding_mode)
}

/// Shift the value left by the given number of bits.
///
/// Returns `None` for the following cases:
/// - the shift consumes a non-zero bit when shifting left.
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
/// Returns `None` for the following cases:
/// - the shift consumes a non-zero bit when shifting right.
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
/// Returns `(overflow, result)` where `overflow` signals that the rounded quotient cannot be
/// represented as `u128`.
public fun mul_div(a: u128, b: u128, denominator: u128, rounding_mode: RoundingMode): (bool, u128) {
    let (_, result) = macros::mul_div!(a, b, denominator, rounding_mode);

    // Check if the result fits in u128
    if (result > (std::u128::max_value!() as u256)) {
        (true, 0)
    } else {
        (false, result as u128)
    }
}

/// Multiply `a` and `b`, shift the product right by `shift`, and round according to `rounding_mode`.
///
/// Returns None for the following cases:
/// - the rounded quotient cannot be represented as `u128`
public fun mul_shr(a: u128, b: u128, shift: u8, rounding_mode: RoundingMode): Option<u128> {
    let (_, result) = macros::mul_shr!(a, b, shift, rounding_mode);
    result.try_as_u128()
}

/// Count the number of leading zero bits in the value.
public fun clz(value: u128): u8 {
    macros::clz!(value, BIT_WIDTH as u16) as u8
}

/// Return the position of the most significant bit in the value.
///
/// Returns 0 if given 0.
public fun msb(value: u128): u8 {
    macros::msb!(value, BIT_WIDTH as u16)
}

/// Compute the log in base 2 of a positive value with configurable rounding.
///
/// Returns 0 if given 0.
public fun log2(value: u128, rounding_mode: RoundingMode): u8 {
    macros::log2!(value, BIT_WIDTH as u16, rounding_mode) as u8
}

/// Compute the log in base 256 of a positive value with configurable rounding.
///
/// Returns 0 if given 0.
public fun log256(value: u128, rounding_mode: RoundingMode): u8 {
    macros::log256!(value, BIT_WIDTH as u16, rounding_mode)
}

/// Compute 10^exp as `u128`.
///
/// # Aborts
///
/// Aborts with `EPow10ExponentTooLarge` if `exp` > `MAX_POW_10_EXPONENT`.
public fun pow_10(exp: u8): u128 {
    assert!(exp <= MAX_POW_10_EXPONENT, EPow10ExponentTooLarge);
    macros::pow_10!(exp)
}

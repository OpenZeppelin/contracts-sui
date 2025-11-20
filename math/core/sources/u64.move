module openzeppelin_math::u64;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::RoundingMode;

#[error(code = 0)]
const EPow10ExponentTooLarge: vector<u8> = b"Power of 10 exponent is too large to fit in u64";

/// The bit width of the `u64` type (64 bits).
const BIT_WIDTH: u8 = 64;

/// Maximum exponent for `pow_10` that fits in `u64`.
///
/// Determined by the constraint: 10^MAX_POW_10_EXPONENT <= u64::MAX < 10^(MAX_POW_10_EXPONENT+1)
/// 10^19 = 10000000000000000000 ✓, 10^20 = 100000000000000000000 > `std::u64::max_value!()` ✗
const MAX_POW_10_EXPONENT: u8 = 19;

/// Compute the arithmetic mean of two `u64` values with configurable rounding.
public fun average(a: u64, b: u64, rounding_mode: RoundingMode): u64 {
    macros::average!(a, b, rounding_mode)
}

/// Shift the value left by the given number of bits.
///
/// Returns `None` for the following cases:
/// - the shift consumes a non-zero bit when shifting left.
public fun checked_shl(value: u64, shift: u8): Option<u64> {
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
public fun checked_shr(value: u64, shift: u8): Option<u64> {
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
/// represented as `u64`.
public fun mul_div(a: u64, b: u64, denominator: u64, rounding_mode: RoundingMode): (bool, u64) {
    let (_, result) = macros::mul_div!(a, b, denominator, rounding_mode);

    // Check if the result fits in u64
    if (result > (std::u64::max_value!() as u256)) {
        (true, 0)
    } else {
        (false, result as u64)
    }
}

/// Multiply `a` and `b`, shift the product right by `shift`, and round according to `rounding_mode`.
///
/// Returns None for the following cases:
/// - the rounded quotient cannot be represented as `u64`
public fun mul_shr(a: u64, b: u64, shift: u8, rounding_mode: RoundingMode): Option<u64> {
    let (_, result) = macros::mul_shr!(a, b, shift, rounding_mode);
    result.try_as_u64()
}

/// Count the number of leading zero bits in the value.
public fun clz(value: u64): u8 {
    macros::clz!(value, BIT_WIDTH as u16) as u8
}

/// Return the position of the most significant bit in the value.
///
/// Returns 0 if given 0.
public fun msb(value: u64): u8 {
    macros::msb!(value, BIT_WIDTH as u16)
}

/// Compute the log in base 2 of a positive value with configurable rounding.
///
/// Returns 0 if given 0.
public fun log2(value: u64, rounding_mode: RoundingMode): u8 {
    macros::log2!(value, BIT_WIDTH as u16, rounding_mode) as u8
}

/// Compute the log in base 256 of a positive value with configurable rounding.
///
/// Returns 0 if given 0.
public fun log256(value: u64, rounding_mode: RoundingMode): u8 {
    macros::log256!(value, BIT_WIDTH as u16, rounding_mode)
}

/// Compute 10^exp as `u64`.
///
/// # Aborts
///
/// Aborts with `EPow10ExponentTooLarge` if `exp` > `MAX_POW_10_EXPONENT`.
public fun pow_10(exp: u8): u64 {
    assert!(exp <= MAX_POW_10_EXPONENT, EPow10ExponentTooLarge);
    macros::pow_10!(exp)
}

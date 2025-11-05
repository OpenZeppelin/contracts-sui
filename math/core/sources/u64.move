module openzeppelin_math::u64;

use openzeppelin_math::macros;
use openzeppelin_math::rounding::RoundingMode;

const BIT_WIDTH: u8 = 64;

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

/// Count the number of leading zero bits in the value.
public fun clz(value: u64): u8 {
    macros::clz!(value, BIT_WIDTH as u16) as u8
}

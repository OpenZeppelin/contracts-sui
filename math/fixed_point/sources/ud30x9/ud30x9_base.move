/// Base utility functions for the `UD30x9` fixed-point type.
module openzeppelin_fp_math::ud30x9_base;

use openzeppelin_fp_math::common;
use openzeppelin_fp_math::sd29x9::{Self, SD29x9};
use openzeppelin_fp_math::ud30x9::{UD30x9, wrap, one};

// === Errors ===

#[error(code = 0)]
const EOverflow: vector<u8> = "Value overflows UD30x9 (must fit in 2^128 unsigned range)";

/// Arithmetic underflow: the result would be negative, which is unrepresentable in `UD30x9`
#[error(code = 1)]
const EUnderflow: vector<u8> = "Value underflows UD30x9 (result would be negative)";

/// Divisor cannot be zero
#[error(code = 2)]
const EDivisionByZero: vector<u8> = "Divisor cannot be zero";

/// Value cannot be converted to `SD29x9`
#[error(code = 3)]
const ECannotBeConvertedToSD29x9: vector<u8> = "Value cannot be converted to SD29x9";

// === Conversion ===

/// Converts a `UD30x9` value to a `SD29x9` value.
///
/// #### Parameters
/// - `x`: Input `UD30x9` value.
///
/// #### Returns
/// - The `SD29x9` representation of `x`.
///
/// #### Aborts
/// - Aborts if `x` is greater than max positive `SD29x9` value.
public fun into_SD29x9(x: UD30x9): SD29x9 {
    let value = x.unwrap();
    assert!(value <= common::max_sd29x9_magnitude!(), ECannotBeConvertedToSD29x9);
    sd29x9::wrap(value, false)
}

/// Tries to convert a `UD30x9` value to a `SD29x9` value.
///
/// #### Parameters
/// - `x`: Input `UD30x9` value.
///
/// #### Returns
/// - The `SD29x9` representation of `x` if `x` is less than or equal to max positive `SD29x9` value, otherwise `none`.
public fun try_into_SD29x9(x: UD30x9): Option<SD29x9> {
    let value = x.unwrap();
    if (value > common::max_sd29x9_magnitude!()) {
        option::none()
    } else {
        option::some(sd29x9::wrap(value, false))
    }
}

// === Public Functions ===

/// Adds two `UD30x9` values.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The sum `x + y`.
///
/// #### Aborts
/// - Aborts if the sum exceeds the representable `UD30x9` range.
public fun add(x: UD30x9, y: UD30x9): UD30x9 {
    let (x, y) = (x.unwrap() as u256, y.unwrap() as u256);
    wrap_u256(x + y)
}

/// Performs a bitwise AND between raw `UD30x9` bits and a `u128` mask.
///
/// #### Parameters
/// - `x`: Input value.
/// - `bits`: Bit mask applied to `x`'s underlying bits.
///
/// #### Returns
/// - The result of bitwise AND operation.
public fun and(x: UD30x9, bits: u128): UD30x9 {
    wrap(x.unwrap() & bits)
}

/// Performs a bitwise AND between two `UD30x9` raw bit patterns.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The result of bitwise AND operation.
public fun and2(x: UD30x9, y: UD30x9): UD30x9 {
    wrap(x.unwrap() & y.unwrap())
}

/// Returns the absolute value of a `UD30x9`.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - `x` unchanged, since `UD30x9` is unsigned.
public fun abs(x: UD30x9): UD30x9 {
    x
}

/// Rounds toward positive infinity to the next integer (if fractional), otherwise unchanged.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - `x` rounded up (ceiling) at integer precision.
///
/// #### Aborts
/// - Aborts if the rounded result exceeds the representable `UD30x9` range.
public fun ceil(x: UD30x9): UD30x9 {
    let value = x.unwrap() as u256;
    let scale = common::scale_u256!();
    let fractional = value % scale;
    if (fractional == 0) {
        x
    } else {
        let int_part = value - fractional;
        let new_value = int_part + scale;
        wrap_u256(new_value)
    }
}

/// Checks whether two `UD30x9` values are equal.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - `true` if `x == y`, otherwise `false`.
public fun eq(x: UD30x9, y: UD30x9): bool {
    x.unwrap() == y.unwrap()
}

/// Rounds down to the nearest integer multiple of `1e9`.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - `x` rounded down (floor) at integer precision.
public fun floor(x: UD30x9): UD30x9 {
    let value = x.unwrap();
    let fractional = value % common::scale!();
    if (fractional == 0) {
        x
    } else {
        wrap(value - fractional)
    }
}

/// Compares whether `x` is greater than `y`.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - `true` if `x > y`, otherwise `false`.
public fun gt(x: UD30x9, y: UD30x9): bool {
    x.unwrap() > y.unwrap()
}

/// Compares whether `x` is greater than or equal to `y`.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - `true` if `x >= y`, otherwise `false`.
public fun gte(x: UD30x9, y: UD30x9): bool {
    x.unwrap() >= y.unwrap()
}

/// Checks whether a value is exactly zero.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - `true` if `x` is zero, otherwise `false`.
public fun is_zero(x: UD30x9): bool {
    x.unwrap() == 0
}

/// Performs a logical left shift on the underlying 128-bit representation of a `UD30x9` value.
/// The high bits are dropped if they overflow past the 128-bit boundary.
///
/// #### Parameters
/// - `x`: Input value.
/// - `bits`: Number of bit positions to shift left.
///
/// #### Returns
/// - Zero if `bits >= 128` (all bits shifted out).
/// - Otherwise, the result of shifting the `x`'s raw bits left by `bits`.
public fun lshift(x: UD30x9, bits: u8): UD30x9 {
    if (bits >= 128) {
        return wrap(0)
    };
    wrap(x.unwrap() << bits)
}

/// Compares whether `x` is less than `y`.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - `true` if `x < y`, otherwise `false`.
public fun lt(x: UD30x9, y: UD30x9): bool {
    x.unwrap() < y.unwrap()
}

/// Compares whether `x` is less than or equal to `y`.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - `true` if `x <= y`, otherwise `false`.
public fun lte(x: UD30x9, y: UD30x9): bool {
    x.unwrap() <= y.unwrap()
}

/// Computes the remainder of dividing one `UD30x9` value by another.
///
/// #### Parameters
/// - `x`: Dividend.
/// - `y`: Divisor.
///
/// #### Returns
/// - The remainder of `x` divided by `y`.
///
/// #### Aborts
/// - Aborts if `y` is zero.
public fun mod(x: UD30x9, y: UD30x9): UD30x9 {
    let (x, y) = (x.unwrap(), y.unwrap());
    assert!(y != 0, EDivisionByZero);
    wrap(x % y)
}

/// Multiplies two `UD30x9` values with fixed-point scaling.
///
/// This function rounds toward zero when the exact product cannot be represented with 9 decimals.
/// Equivalent to `mul_trunc`.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The product `x * y`, rounded toward zero.
///
/// #### Aborts
/// - Aborts if the resulting value exceeds the representable `UD30x9` range.
public fun mul(x: UD30x9, y: UD30x9): UD30x9 {
    mul_trunc(x, y)
}

/// Multiplies two `UD30x9` values with fixed-point scaling and truncation toward zero.
///
/// This function rounds toward zero when the exact product cannot be represented with 9 decimals.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The product `x * y`, rounded toward zero.
///
/// #### Aborts
/// - Aborts if the resulting value exceeds the representable `UD30x9` range.
public fun mul_trunc(x: UD30x9, y: UD30x9): UD30x9 {
    let (x, y) = (x.unwrap() as u256, y.unwrap() as u256);
    wrap_u256(x * y / common::scale_u256!())
}

/// Multiplies two `UD30x9` values with fixed-point scaling and rounds away from zero.
///
/// This function rounds away from zero when the exact product cannot be represented with 9
/// decimals.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The product `x * y`, rounded away from zero when inexact.
///
/// #### Aborts
/// - Aborts if the rounded result exceeds the representable `UD30x9` range.
public fun mul_away(x: UD30x9, y: UD30x9): UD30x9 {
    let (x, y) = (x.unwrap() as u256, y.unwrap() as u256);
    wrap_u256(common::div_away_u256(x * y, common::scale_u256!()))
}

/// Divides `x` by `y` with fixed-point scaling.
///
/// This function rounds toward zero when the exact quotient cannot be represented with 9 decimals.
/// Equivalent to `div_trunc`.
///
/// #### Parameters
/// - `x`: Dividend.
/// - `y`: Divisor.
///
/// #### Returns
/// - The quotient `x / y`, rounded toward zero.
///
/// #### Aborts
/// - Aborts if `y` is zero.
/// - Aborts if the resulting value exceeds the representable `UD30x9` range.
public fun div(x: UD30x9, y: UD30x9): UD30x9 {
    div_trunc(x, y)
}

/// Divides `x` by `y` with fixed-point scaling and truncation toward zero.
///
/// This function rounds toward zero when the exact quotient cannot be represented with 9 decimals.
///
/// #### Parameters
/// - `x`: Dividend.
/// - `y`: Divisor.
///
/// #### Returns
/// - The quotient `x / y`, rounded toward zero.
///
/// #### Aborts
/// - Aborts if `y` is zero.
/// - Aborts if the resulting value exceeds the representable `UD30x9` range.
public fun div_trunc(x: UD30x9, y: UD30x9): UD30x9 {
    let (x, y) = (x.unwrap() as u256, y.unwrap() as u256);
    assert!(y != 0, EDivisionByZero);
    let numerator = x * common::scale_u256!();
    wrap_u256(numerator / y)
}

/// Divides `x` by `y` with fixed-point scaling and rounds away from zero.
///
/// This function rounds away from zero when the exact quotient cannot be represented with 9
/// decimals.
///
/// #### Parameters
/// - `x`: Dividend.
/// - `y`: Divisor.
///
/// #### Examples
/// - `1.0 / 3.0` returns `0.333333334`.
///
/// #### Returns
/// - The quotient `x / y`, rounded away from zero when inexact.
///
/// #### Aborts
/// - Aborts if `y` is zero.
/// - Aborts if the rounded result exceeds the representable `UD30x9` range.
public fun div_away(x: UD30x9, y: UD30x9): UD30x9 {
    let (x, y) = (x.unwrap() as u256, y.unwrap() as u256);
    assert!(y != 0, EDivisionByZero);
    let numerator = x * common::scale_u256!();
    wrap_u256(common::div_away_u256(numerator, y))
}

/// Raises `x` to a power of `exp`.
///
/// This helper uses binary exponentiation with fixed-point multiplication. Each intermediate
/// multiply or square applies fixed-point truncation via division by `common::scale_u256!()`.
///
/// As a consequence, `pow` is approximate for most fractional values: rounding error compounds as
/// `exp` grows, results are biased toward zero, and for `0 < x < 1` intermediate values can reach
/// zero before the final mathematically scaled result would.
///
/// Because truncation is applied at intermediate steps, the result generally matches neither the
/// exact real-valued power rounded once at the end nor the result of left-to-right repeated
/// multiplication. In particular, fixed-point multiplication is not associative under truncation,
/// so the grouping of operations used by binary exponentiation affects the final value.
///
/// #### Parameters
/// - `x`: Base value.
/// - `exp`: Exponent.
///
/// #### Returns
/// - An approximation of `x^exp` computed using binary exponentiation and fixed-point truncation.
///
/// #### Aborts
/// - Aborts if the resulting value exceeds the representable `UD30x9` range.
public fun pow(x: UD30x9, exp: u8): UD30x9 {
    if (exp == 0) {
        return one()
    };
    if (exp == 1) {
        return x
    };

    let scale = common::scale_u256!();
    let max_value = std::u128::max_value!() as u256;
    let mut base = x.unwrap() as u256;
    let mut result = scale;
    let mut exp = exp;

    while (exp != 0) {
        if ((exp & 1) == 1) {
            result = result * base / scale;
            assert!(result <= max_value, EOverflow);
        };
        exp = exp >> 1;
        if (exp != 0) {
            base = base * base / scale;
            assert!(base <= max_value, EOverflow);
        };
    };

    wrap_u256(result)
}

/// Checks whether two `UD30x9` values are not equal.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - `true` if `x != y`, otherwise `false`.
public fun neq(x: UD30x9, y: UD30x9): bool {
    x.unwrap() != y.unwrap()
}

/// Performs a bitwise NOT on the raw `UD30x9` bits.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - The result of bitwise NOT operation.
public fun not(x: UD30x9): UD30x9 {
    wrap(x.unwrap() ^ std::u128::max_value!())
}

/// Performs a bitwise OR between two `UD30x9` raw bit patterns.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The result of bitwise OR operation.
public fun or(x: UD30x9, y: UD30x9): UD30x9 {
    wrap(x.unwrap() | y.unwrap())
}

/// Performs a logical right shift on the underlying 128-bit representation of a `UD30x9` value.
/// Vacated high bits are filled with zeros.
///
/// #### Parameters
/// - `x`: Input value.
/// - `bits`: Number of bit positions to shift right.
///
/// #### Returns
/// - Zero if `bits >= 128`.
/// - Otherwise, the result of shifting the `x`'s raw bits right by `bits`.
public fun rshift(x: UD30x9, bits: u8): UD30x9 {
    if (bits >= 128) {
        return wrap(0)
    };
    wrap(x.unwrap() >> bits)
}

/// Subtracts `y` from `x`.
///
/// #### Parameters
/// - `x`: First operand (minuend).
/// - `y`: Second operand (subtrahend).
///
/// #### Returns
/// - The difference `x - y`.
///
/// #### Aborts
/// - Aborts if `y > x`.
public fun sub(x: UD30x9, y: UD30x9): UD30x9 {
    let (x, y) = (x.unwrap(), y.unwrap());
    assert!(x >= y, EUnderflow);
    wrap(x - y)
}

/// Performs unchecked addition of two `UD30x9` values.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The wrapping sum `x + y` modulo `2^128`.
public fun unchecked_add(x: UD30x9, y: UD30x9): UD30x9 {
    let (x, y) = (x.unwrap() as u256, y.unwrap() as u256);
    let sum = x + y;
    let u128_max = std::u128::max_value!() as u256;

    // Keep only the low 128 bits, safe to cast down to u128.
    let wrapped = (sum & u128_max) as u128;
    wrap(wrapped)
}

/// Performs unchecked subtraction of two `UD30x9` values.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The wrapping difference `x - y` modulo `2^128`.
public fun unchecked_sub(x: UD30x9, y: UD30x9): UD30x9 {
    let (x, y) = (x.unwrap() as u256, y.unwrap() as u256);
    let u128_max = std::u128::max_value!() as u256;

    // Effectively wraps subtraction like in modular arithmetic.
    // The result is (a + (2^128) - b).
    let diff = x + (u128_max + 1) - y;

    // Wrap the result back into the u128 range by taking the low 128 bits.
    let wrapped = (diff & u128_max) as u128;
    wrap(wrapped)
}

/// Performs a bitwise XOR between two `UD30x9` raw bit patterns.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The result of bitwise XOR operation.
public fun xor(x: UD30x9, y: UD30x9): UD30x9 {
    wrap(x.unwrap() ^ y.unwrap())
}

// === Internal Functions ===

fun wrap_u256(value: u256): UD30x9 {
    assert!(value <= std::u128::max_value!() as u256, EOverflow);
    wrap(value as u128)
}

/// Base utility functions for the `SD29x9` fixed-point type.
///
/// Tailored to the signed `SD29x9` representation (two's complement stored in `u128` with 9 decimal places).
module openzeppelin_fp_math::sd29x9_base;

use openzeppelin_fp_math::common;
use openzeppelin_fp_math::sd29x9::{SD29x9, from_bits, zero, min, one, two_complement, wrap};
use openzeppelin_fp_math::ud30x9::{Self, UD30x9};

// === Errors ===

/// Value overflows `SD29x9` (must fit in 2^127 signed range)
#[error(code = 0)]
const EOverflow: vector<u8> = "Value overflows SD29x9 (must fit in 2^127 signed range)";

/// Value cannot be converted to `UD30x9`
#[error(code = 1)]
const ECannotBeConvertedToUD30x9: vector<u8> = "Value cannot be converted to UD30x9";

// === Conversion ===

/// Converts a `SD29x9` value to a `UD30x9` value.
///
/// #### Parameters
/// - `x`: Input `SD29x9` value.
///
/// #### Returns
/// - The `UD30x9` representation of `x`.
///
/// #### Aborts
/// - Aborts if `x` is negative.
public fun into_UD30x9(x: SD29x9): UD30x9 {
    let Components { neg, mag } = decompose(x.unwrap());
    assert!(!neg, ECannotBeConvertedToUD30x9);
    ud30x9::wrap(mag as u128)
}

/// Tries to convert a `SD29x9` value to a `UD30x9` value.
///
/// #### Parameters
/// - `x`: Input `SD29x9` value.
///
/// #### Returns
/// - The `UD30x9` representation of `x` if `x` is non-negative, otherwise `none`.
public fun try_into_UD30x9(x: SD29x9): Option<UD30x9> {
    let Components { neg, mag } = decompose(x.unwrap());
    if (neg) {
        option::none()
    } else {
        option::some(ud30x9::wrap(mag as u128))
    }
}

// === Public Functions ===

/// Returns the absolute value of a `SD29x9`.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - The non-negative value of `x`.
///
/// #### Aborts
/// - Aborts if `x` is the minimum representable value (`-2^127`), because `+2^127` is not representable.
public fun abs(x: SD29x9): SD29x9 {
    let mut components = decompose(x.unwrap());
    components.neg = false;
    wrap_components(components)
}

/// Adds two `SD29x9` values.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The sum `x + y`.
///
/// #### Aborts
/// - Aborts if the resulting magnitude exceeds the representable `SD29x9` range.
public fun add(x: SD29x9, y: SD29x9): SD29x9 {
    let result = add_components(decompose(x.unwrap()), decompose(y.unwrap()));
    wrap_components(result)
}

/// Performs a bitwise AND between raw `SD29x9` bits and a `u128` mask.
///
/// #### Parameters
/// - `x`: Input value.
/// - `bits`: Bit mask applied to `x`'s underlying bits.
///
/// #### Returns
/// - The result of bitwise AND operation.
public fun and(x: SD29x9, bits: u128): SD29x9 {
    from_bits(x.unwrap() & bits)
}

/// Performs a bitwise AND between two `SD29x9` raw bit patterns.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The result of bitwise AND operation.
public fun and2(x: SD29x9, y: SD29x9): SD29x9 {
    from_bits(x.unwrap() & y.unwrap())
}

/// Rounds toward positive infinity to the nearest integer multiple of `1e9`.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - `x` rounded up (ceiling) at integer precision.
///
/// #### Aborts
/// - Aborts if the rounded positive result exceeds the representable `SD29x9` range.
public fun ceil(x: SD29x9): SD29x9 {
    let Components { neg, mag } = decompose(x.unwrap());
    let scale = common::scale_u256();
    let fractional = mag % scale;
    if (fractional == 0) {
        return x
    };
    let int_part = mag / scale;
    let result = if (!neg) {
        Components { mag: (int_part + 1) * scale, neg: false }
    } else {
        Components { mag: int_part * scale, neg: true }
    };
    wrap_components(result)
}

/// Checks whether two `SD29x9` values are bitwise equal.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - `true` if both values have identical underlying bits, otherwise `false`.
public fun eq(x: SD29x9, y: SD29x9): bool {
    x.unwrap() == y.unwrap()
}

/// Rounds toward negative infinity to the nearest integer multiple of `1e9`.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - `x` rounded down (floor) at integer precision.
///
/// #### Aborts
/// - Aborts if the rounded negative result magnitude exceeds the representable `SD29x9` range.
public fun floor(x: SD29x9): SD29x9 {
    let Components { neg, mag } = decompose(x.unwrap());
    let scale = common::scale_u256();
    let fractional = mag % scale;
    if (fractional == 0) {
        return x
    };
    let int_part = mag / scale;
    let result = if (!neg) {
        Components { mag: int_part * scale, neg: false }
    } else {
        Components { mag: (int_part + 1) * scale, neg: true }
    };
    wrap_components(result)
}

/// Compares whether `x` is greater than `y`.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - `true` if `x > y`, otherwise `false`.
public fun gt(x: SD29x9, y: SD29x9): bool {
    greater_than_bits(x.unwrap(), y.unwrap())
}

/// Compares whether `x` is greater than or equal to `y`.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - `true` if `x >= y`, otherwise `false`.
public fun gte(x: SD29x9, y: SD29x9): bool {
    !lt(x, y)
}

/// Checks whether a value is exactly zero.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - `true` if `x` is zero, otherwise `false`.
public fun is_zero(x: SD29x9): bool {
    x.unwrap() == 0
}

/// Performs a logical left shift on the underlying 128-bit representation.
/// Doesn't preserve the sign and can move 1s into the sign bit.
///
/// #### Parameters
/// - `x`: Input value.
/// - `bits`: Number of bit positions to shift left.
///
/// #### Returns
/// - Zero if `bits >= 128` (all bits cleared).
/// - Otherwise, shifts the raw bits left by `bits` and masks to 128 bits.
public fun lshift(x: SD29x9, bits: u8): SD29x9 {
    if (bits >= 128) {
        return zero()
    };
    from_bits((x.unwrap() << bits) & std::u128::max_value!())
}

/// Compares whether `x` is less than `y`.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - `true` if `x < y`, otherwise `false`.
public fun lt(x: SD29x9, y: SD29x9): bool {
    greater_than_bits(y.unwrap(), x.unwrap())
}

/// Compares whether `x` is less than or equal to `y`.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - `true` if `x <= y`, otherwise `false`.
public fun lte(x: SD29x9, y: SD29x9): bool {
    !gt(x, y)
}

/// Computes the truncating remainder of dividing one `SD29x9` value by another.
///
/// This helper follows remainder semantics, not Euclidean modulo semantics. The magnitude is
/// computed as `abs(x) % abs(y)`, and the sign of the result follows the dividend `x`. In
/// particular, a negative dividend can produce a negative non-zero remainder, while the sign of
/// `y` does not affect the result apart from the zero-divisor check.
///
/// #### Parameters
/// - `x`: Dividend.
/// - `y`: Divisor.
///
/// #### Returns
/// - The truncating remainder of `x` divided by `y`.
/// - Returns `0` when `x` is an exact multiple of `y`.
///
/// #### Aborts
/// - Aborts if `y` is zero.
public fun mod(x: SD29x9, y: SD29x9): SD29x9 {
    let x = decompose(x.unwrap());
    let y = decompose(y.unwrap());
    let remainder = x.mag % y.mag;
    wrap_components(Components { neg: x.neg, mag: remainder })
}

/// Multiplies two `SD29x9` values with fixed-point scaling.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The product `x * y`.
///
/// #### Aborts
/// - Aborts if the resulting magnitude exceeds the representable `SD29x9` range.
public fun mul(x: SD29x9, y: SD29x9): SD29x9 {
    let x = decompose(x.unwrap());
    let y = decompose(y.unwrap());
    let neg = x.neg != y.neg;
    let prod = x.mag * y.mag;
    let mag = prod / common::scale_u256();
    wrap_components(Components { neg, mag })
}

/// Divides `x` by `y` with fixed-point scaling.
///
/// #### Parameters
/// - `x`: Dividend.
/// - `y`: Divisor.
///
/// #### Returns
/// - The division result `x / y`.
///
/// #### Aborts
/// - Aborts if `y` is zero.
/// - Aborts if the resulting magnitude exceeds the representable `SD29x9` range.
public fun div(x: SD29x9, y: SD29x9): SD29x9 {
    let x = decompose(x.unwrap());
    let y = decompose(y.unwrap());
    let neg = x.neg != y.neg;
    let numerator = x.mag * common::scale_u256();
    let mag = numerator / y.mag;
    wrap_components(Components { neg, mag })
}

/// Raises `x` to a power of `exp`.
///
/// This helper uses repeated fixed-point multiplication with truncation after each step. It updates
/// the magnitude via `res_mag = (res_mag * mag) / SCALE`, while the sign is derived separately from
/// the sign of `x` and the parity of `exp`. As a result, the signed output follows truncation
/// toward zero rather than `floor` for negative values, and this step is applied `exp - 1` times
/// rather than computing the exact power and rounding once at the end.
///
/// As a consequence, `pow` is approximate for most fractional values: rounding error compounds as
/// `exp` grows, results are biased toward zero, and for `0 < abs(x) < 1` intermediate values can
/// reach zero before the final mathematically scaled result would.
///
/// #### Parameters
/// - `x`: Base value.
/// - `exp`: Exponent.
///
/// #### Returns
/// - An approximation of `x^exp` using the same stepwise truncation semantics as repeated
///   fixed-point multiplication.
///
/// #### Aborts
/// - Aborts if the resulting magnitude exceeds the representable `SD29x9` range.
public fun pow(x: SD29x9, exp: u8): SD29x9 {
    if (exp == 0) {
        return one()
    };
    if (exp == 1) {
        return x
    };
    let Components { neg, mag } = decompose(x.unwrap());
    let res_neg = neg && (exp % 2 != 0);
    let mut res_mag = mag;
    let scale = common::scale_u256();
    let max_mag = common::min_sd29x9_value() as u256;
    let times = exp - 1;
    times.do!(|_| {
        res_mag = res_mag * mag / scale;
        assert!(res_mag <= max_mag, EOverflow);
    });
    let result = Components { neg: res_neg, mag: res_mag };
    wrap_components(result)
}

/// Returns the arithmetic negation of `x`.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - `-x`.
///
/// #### Aborts
/// - Aborts if `x` is the minimum representable value (`-2^127`), because `+2^127` is not representable.
public fun negate(x: SD29x9): SD29x9 {
    let value = decompose(x.unwrap());
    wrap_components(negate_components(value))
}

/// Checks whether two `SD29x9` values are not equal.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - `true` if `x != y`, otherwise `false`.
public fun neq(x: SD29x9, y: SD29x9): bool {
    !eq(x, y)
}

/// Performs a bitwise NOT on the raw `SD29x9` bits.
///
/// #### Parameters
/// - `x`: Input value.
///
/// #### Returns
/// - The result of bitwise NOT operation.
public fun not(x: SD29x9): SD29x9 {
    from_bits(x.unwrap() ^ std::u128::max_value!())
}

/// Performs a bitwise OR between two `SD29x9` raw bit patterns.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The result of bitwise OR operation.
public fun or(x: SD29x9, y: SD29x9): SD29x9 {
    from_bits(x.unwrap() | y.unwrap())
}

/// Performs an arithmetic right shift on the underlying 128-bit representation.
/// Preserves the sign by sign-extending negative values.
///
/// #### Parameters
/// - `x`: Input value.
/// - `bits`: Number of bit positions to shift right.
///
/// #### Returns
/// - `x` unchanged if `bits == 0`.
/// - All 1s for negative values and zero for non-negative values if `bits >= 128`.
/// - Otherwise, the result of an arithmetic right shift:
///   - For non-negative values, this is a logical right shift.
///   - For negative values, the shifted value is sign-extended with 1s.
public fun rshift(x: SD29x9, bits: u8): SD29x9 {
    if (bits == 0) {
        return x
    } else if (bits >= 128) {
        return if ((x.unwrap() & common::sign_bit()) != 0) {
            from_bits(std::u128::max_value!())
        } else {
            zero()
        }
    };

    let raw = x.unwrap();
    if ((raw & common::sign_bit()) == 0) {
        from_bits(raw >> bits)
    } else {
        let shifted = raw >> bits;
        let mask = std::u128::max_value!() << (128 - bits);
        from_bits(shifted | mask)
    }
}

/// Subtracts `y` from `x`.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The difference `x - y`.
///
/// #### Aborts
/// - Aborts if the resulting magnitude exceeds the representable `SD29x9` range.
public fun sub(x: SD29x9, y: SD29x9): SD29x9 {
    let negated_y = negate_components(decompose(y.unwrap()));
    let result = add_components(decompose(x.unwrap()), negated_y);
    wrap_components(result)
}

/// Performs the unchecked addition of two `SD29x9` values.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The result of raw bits addition.
public fun unchecked_add(x: SD29x9, y: SD29x9): SD29x9 {
    from_bits(wrapping_add_bits(x.unwrap(), y.unwrap()))
}

/// Performs the unchecked subtraction on two `SD29x9` values.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The result of raw bits subtraction.
public fun unchecked_sub(x: SD29x9, y: SD29x9): SD29x9 {
    from_bits(wrapping_sub_bits(x.unwrap(), y.unwrap()))
}

/// Performs a bitwise XOR between two `SD29x9` raw bit patterns.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Returns
/// - The result of bitwise XOR operation.
public fun xor(x: SD29x9, y: SD29x9): SD29x9 {
    from_bits(x.unwrap() ^ y.unwrap())
}

// === Internal helpers ===

public struct Components has copy, drop {
    neg: bool,
    mag: u256,
}

fun decompose(bits: u128): Components {
    if ((bits & common::sign_bit()) != 0) {
        Components { neg: true, mag: two_complement(bits) as u256 }
    } else {
        Components { neg: false, mag: bits as u256 }
    }
}

fun negate_components(value: Components): Components {
    if (value.mag == 0) {
        Components { neg: false, mag: 0 }
    } else {
        Components { neg: !value.neg, mag: value.mag }
    }
}

fun add_components(x: Components, y: Components): Components {
    if (x.neg == y.neg) {
        Components { neg: x.neg, mag: x.mag + y.mag }
    } else if (x.mag >= y.mag) {
        Components { neg: x.neg, mag: x.mag - y.mag }
    } else {
        Components { neg: y.neg, mag: y.mag - x.mag }
    }
}

fun wrap_components(value: Components): SD29x9 {
    if (value.mag == 0) {
        return zero()
    };
    let min_negative = common::min_sd29x9_value() as u256;
    if (value.neg && value.mag == min_negative) {
        min()
    } else {
        assert!(value.mag < min_negative, EOverflow);
        wrap(value.mag as u128, value.neg)
    }
}

fun wrapping_add_bits(a: u128, b: u128): u128 {
    let sum = (a as u256) + (b as u256);
    (sum & (std::u128::max_value!() as u256)) as u128
}

fun wrapping_sub_bits(a: u128, b: u128): u128 {
    wrapping_add_bits(a, two_complement(b))
}

fun greater_than_bits(x_bits: u128, y_bits: u128): bool {
    if (x_bits == y_bits) {
        return false
    };
    let x = decompose(x_bits);
    let y = decompose(y_bits);

    if (x.neg != y.neg) {
        !x.neg
    } else if (!x.neg) {
        x.mag > y.mag
    } else {
        x.mag < y.mag
    }
}

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

/// Divisor must be non-zero
#[error(code = 2)]
const EDivisionByZero: vector<u8> = "Divisor must be non-zero";

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
    let scale = common::scale_u256!();
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
    let scale = common::scale_u256!();
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
/// This function follows remainder semantics, not Euclidean modulo semantics. The magnitude is
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
public fun rem(x: SD29x9, y: SD29x9): SD29x9 {
    let y_bits = y.unwrap();
    assert!(y_bits != 0, EDivisionByZero);
    let y = decompose(y_bits);
    let x = decompose(x.unwrap());
    let remainder = x.mag % y.mag;
    wrap_components(Components { neg: x.neg, mag: remainder })
}

/// Computes the Euclidean remainder of dividing one `SD29x9` value by another.
///
/// The result is always non-negative and satisfies `0 <= result < abs(y)`. When the
/// truncating remainder is negative, `abs(y)` is added to produce the Euclidean result.
///
/// #### Parameters
/// - `x`: Dividend.
/// - `y`: Divisor.
///
/// #### Returns
/// - The Euclidean remainder of `x` divided by `y`, always non-negative.
/// - Returns `0` when `x` is an exact multiple of `y`.
///
/// #### Aborts
/// - Aborts if `y` is zero.
public fun mod(x: SD29x9, y: SD29x9): SD29x9 {
    let y_bits = y.unwrap();
    assert!(y_bits != 0, EDivisionByZero);
    let y = decompose(y_bits);
    let x = decompose(x.unwrap());
    let remainder = x.mag % y.mag;
    let mag = if (x.neg && remainder > 0) {
        y.mag - remainder
    } else {
        remainder
    };
    wrap_components(Components { neg: false, mag })
}

/// Multiplies two `SD29x9` values with fixed-point scaling.
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
/// - Aborts if the resulting magnitude exceeds the representable `SD29x9` range.
public fun mul(x: SD29x9, y: SD29x9): SD29x9 {
    mul_trunc(x, y)
}

/// Multiplies two `SD29x9` values with fixed-point scaling and truncation toward zero.
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
/// - Aborts if the resulting magnitude exceeds the representable `SD29x9` range.
public fun mul_trunc(x: SD29x9, y: SD29x9): SD29x9 {
    let x = decompose(x.unwrap());
    let y = decompose(y.unwrap());
    let neg = x.neg != y.neg;
    let prod = x.mag * y.mag;
    let mag = prod / common::scale_u256!();
    wrap_components(Components { neg, mag })
}

/// Multiplies two `SD29x9` values with fixed-point scaling and rounds away from zero.
///
/// This function rounds away from zero when the exact product cannot be represented with 9
/// decimals.
///
/// #### Parameters
/// - `x`: First operand.
/// - `y`: Second operand.
///
/// #### Examples
/// - `1.000000001 * 1.000000001` returns `1.000000003`.
/// - `-1.000000001 * 1.000000001` returns `-1.000000003`.
///
/// #### Returns
/// - The product `x * y`, rounded away from zero when inexact.
///
/// #### Aborts
/// - Aborts if the rounded magnitude exceeds the representable `SD29x9` range.
public fun mul_away(x: SD29x9, y: SD29x9): SD29x9 {
    let x = decompose(x.unwrap());
    let y = decompose(y.unwrap());
    let neg = x.neg != y.neg;
    let mag = common::div_away_u256(x.mag * y.mag, common::scale_u256!());
    wrap_components(Components { neg, mag })
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
/// - Aborts if the resulting magnitude exceeds the representable `SD29x9` range.
public fun div(x: SD29x9, y: SD29x9): SD29x9 {
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
/// - Aborts if the resulting magnitude exceeds the representable `SD29x9` range.
public fun div_trunc(x: SD29x9, y: SD29x9): SD29x9 {
    let y_bits = y.unwrap();
    assert!(y_bits != 0, EDivisionByZero);
    let y = decompose(y_bits);
    let x = decompose(x.unwrap());
    let neg = x.neg != y.neg;
    let numerator = x.mag * common::scale_u256!();
    let mag = numerator / y.mag;
    wrap_components(Components { neg, mag })
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
/// - `-1.0 / 3.0` returns `-0.333333334`.
///
/// #### Returns
/// - The quotient `x / y`, rounded away from zero when inexact.
///
/// #### Aborts
/// - Aborts if `y` is zero.
/// - Aborts if the rounded magnitude exceeds the representable `SD29x9` range.
public fun div_away(x: SD29x9, y: SD29x9): SD29x9 {
    let y_bits = y.unwrap();
    assert!(y_bits != 0, EDivisionByZero);
    let y = decompose(y_bits);
    let x = decompose(x.unwrap());
    let neg = x.neg != y.neg;
    let numerator = x.mag * common::scale_u256!();
    let mag = common::div_away_u256(numerator, y.mag);
    wrap_components(Components { neg, mag })
}

/// Raises `x` to a power of `exp`.
///
/// This helper uses binary exponentiation with fixed-point
/// multiplication. Each intermediate multiply or square applies
/// fixed-point truncation via division by `common::scale_u256!()`.
///
/// As a consequence, `pow` is approximate for most fractional values: rounding error compounds as
/// `exp` grows, results are biased toward zero, and for `0 < abs(x) < 1` intermediate values can
/// reach zero before the final mathematically scaled result would.
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
    let scale = common::scale_u256!();
    let max_mag = common::min_sd29x9_value!() as u256;
    let mut res_mag = scale;
    let mut base_mag = mag;
    let mut exp = exp;

    while (exp != 0) {
        if ((exp & 1) == 1) {
            res_mag = res_mag * base_mag / scale;
            assert!(res_mag < max_mag || (res_neg && res_mag == max_mag), EOverflow);
        };
        exp = exp >> 1;
        if (exp != 0) {
            base_mag = base_mag * base_mag / scale;
            assert!(base_mag <= max_mag, EOverflow);
        };
    };

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
/// - The wrapping sum of the raw bit patterns modulo `2^128`.
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
/// - The wrapping difference of the raw bit patterns modulo `2^128`.
public fun unchecked_sub(x: SD29x9, y: SD29x9): SD29x9 {
    from_bits(wrapping_sub_bits(x.unwrap(), y.unwrap()))
}

// === Internal helpers ===

public struct Components has copy, drop {
    neg: bool,
    mag: u256,
}

fun decompose(bits: u128): Components {
    if ((bits & common::sign_bit!()) != 0) {
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
    let max_mag = common::min_sd29x9_value!() as u256;
    if (value.neg && value.mag == max_mag) {
        min()
    } else {
        assert!(value.mag < max_mag, EOverflow);
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

/// # `SD29x9` Base Functions
///
/// Base utilities tailored to the signed `SD29x9`
/// representation (two's complement stored in `u128` with 9 decimal places).
module openzeppelin_fp_math::sd29x9_base;

use openzeppelin_fp_math::sd29x9::{SD29x9, from_bits, zero, min, one, two_complement, wrap};

// === Constants ===

const U128_MAX_VALUE: u128 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF; // 2^128 - 1
const MIN_NEGATIVE_VALUE: u128 = 0x8000_0000_0000_0000_0000_0000_0000_0000; // -2^127 in two's complement
const SIGN_BIT: u128 = 1u128 << 127;
const SCALE: u128 = 1_000_000_000; // 10^9
const SCALE_U256: u256 = SCALE as u256; // 10^9

// === Errors ===

/// Value overflows SD29x9 (must fit in 2^127 signed range)
#[error(code = 0)]
const EOverflow: vector<u8> = b"Value overflows SD29x9 (must fit in 2^127 signed range)";

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
    let fractional = mag % SCALE;
    if (fractional == 0) {
        return x
    };
    let int_part = mag / SCALE;
    let result = if (!neg) {
        Components { mag: (int_part + 1) * SCALE, neg: false }
    } else {
        Components { mag: int_part * SCALE, neg: true }
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
    let fractional = mag % SCALE;
    if (fractional == 0) {
        return x
    };
    let int_part = mag / SCALE;
    let result = if (!neg) {
        Components { mag: int_part * SCALE, neg: false }
    } else {
        Components { mag: (int_part + 1) * SCALE, neg: true }
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
    from_bits((x.unwrap() << bits) & U128_MAX_VALUE)
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

/// Computes the remainder of dividing one `SD29x9` value by another.
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
    let prod = (x.mag as u256) * (y.mag as u256);
    let mag = (prod / SCALE_U256) as u128;
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
    let numerator = (x.mag as u256) * SCALE_U256;
    let mag = numerator / (y.mag as u256);
    wrap_components(Components { neg, mag: mag as u128 })
}

/// Raises `x` to a power of `exp`.
///
/// #### Parameters
/// - `x`: Base value.
/// - `exp`: Exponent.
///
/// #### Returns
/// - The `exp` power of `x`.
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
    let components = decompose(x.unwrap());
    let base = components.mag as u256;
    let neg = components.neg && (exp % 2 != 0);
    let mut mag = base;
    let times = exp - 1;
    times.do!(|_| mag = mag * base / SCALE_U256);
    let result = Components { neg, mag: mag as u128 };
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
    from_bits(x.unwrap() ^ U128_MAX_VALUE)
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
        return if ((x.unwrap() & SIGN_BIT) != 0) {
            from_bits(U128_MAX_VALUE)
        } else {
            zero()
        }
    };

    let raw = x.unwrap();
    if ((raw & SIGN_BIT) == 0) {
        from_bits(raw >> bits)
    } else {
        let shifted = raw >> bits;
        let mask = U128_MAX_VALUE << (128 - bits);
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
    mag: u128,
}

fun decompose(bits: u128): Components {
    if ((bits & SIGN_BIT) != 0) {
        Components { neg: true, mag: two_complement(bits) }
    } else {
        Components { neg: false, mag: bits }
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
        zero()
    } else if (value.neg && value.mag == MIN_NEGATIVE_VALUE) {
        min()
    } else {
        wrap(value.mag, value.neg)
    }
}

fun wrapping_add_bits(a: u128, b: u128): u128 {
    let sum = (a as u256) + (b as u256);
    (sum & (U128_MAX_VALUE as u256)) as u128
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

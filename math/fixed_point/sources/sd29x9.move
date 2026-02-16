/// # SD29x9 Fixed-Point Type
///
/// This module defines the `SD29x9` decimal fixed-point type, which represents
/// signed real numbers using a 2-complement `u128` scaled by `10^9`.
///
/// ## Why SD29x9
/// - Matches Sui’s native coin decimals (9), making conversions from token
///   amounts straightforward and less error-prone.
/// - Uses a decimal scale that is intuitive for humans, UIs, and offchain
///   systems, avoiding binary fixed-point surprises.
/// - Fits efficiently in `u128`, keeping storage and arithmetic lightweight
///   compared to `u256`-based decimal types.
/// - Useful wherever signed fixed-point arithmetic is needed for things like balance adjustments,
///   deltas, or calculations involving both increases and decreases. Allows precise tracking of
///   values that might dip below zero, unlike unsigned types.
module openzeppelin_fp_math::sd29x9;

/// The `SD29x9` decimal fixed-point type.
public struct SD29x9(u128) has copy, drop, store;

// === Constants ===

const U128_MAX_VALUE: u128 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF; // 2^128 - 1
const MAX_POSITIVE_VALUE: u128 = 0x7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF; // 2^127 - 1
const MIN_NEGATIVE_VALUE: u128 = 0x8000_0000_0000_0000_0000_0000_0000_0000; // -2^127 in two's complement
const SIGN_BIT: u128 = 1u128 << 127;
const SCALE: u128 = 1_000_000_000; // 10^9

// === Errors ===

/// Value cannot be safely cast to `SD29x9` after apply
#[error(code = 0)]
const EOverflow: vector<u8> = b"Value overflows SD29x9 (must fit in 2^127 signed range)";

// === Casting ===

/// Unwraps a `SD29x9` value into a raw `u128` value.
public fun unwrap(x: SD29x9): u128 {
    x.0
}

/// Converts an unsigned 128-bit integer (`u128`) into an `SD29x9` value type,
/// given the intended sign.
///
/// The input `x` must be a pure magnitude and must not already include a sign bit.
/// If `is_negative` is `true`, the value is converted to its two's complement
/// form to represent a negative SD29x9.
///
/// Aborts if `x` exceeds the SD29x9 magnitude bounds for a signed 128-bit integer.
///
/// NOTE: This function can't be used to obtain the minimum value, use `min()` instead.
public fun wrap(x: u128, is_negative: bool): SD29x9 {
    if (x == 0) {
        zero()
    } else if (x > MAX_POSITIVE_VALUE) {
        // The value is too large to be represented as a positive SD29x9
        abort EOverflow
    } else if (is_negative) {
        // The conversion to two's complement cannot overflow: zero is handled separately
        // before any bit manipulation, and otherwise the range is restricted to values
        // up to `2^127-1` (the maximum positive signed value). As a result, there is
        // always room to represent the negative result within 128 bits, and the process
        // is unambiguous and safe.
        from_bits(two_complement(x))
    } else {
        from_bits(x)
    }
}

// === Public Functions ===

/// Returns the absolute value of a SD29x9.
public fun abs(x: SD29x9): SD29x9 {
    let mut components = decompose(x.unwrap());
    components.neg = false;
    wrap_components(components)
}

/// Implements the checked addition operation (+) for the SD29x9 type.
public fun add(x: SD29x9, y: SD29x9): SD29x9 {
    let result = add_components(decompose(x.unwrap()), decompose(y.unwrap()));
    wrap_components(result)
}

/// Implements the AND (&) bitwise operation for SD29x9 type with u128 bits.
public fun and(x: SD29x9, bits: u128): SD29x9 {
    from_bits(x.unwrap() & bits)
}

/// Implements the AND (&) bitwise operation for SD29x9 type with another SD29x9.
public fun and2(x: SD29x9, y: SD29x9): SD29x9 {
    from_bits(x.unwrap() & y.unwrap())
}

/// Rounds up a SD29x9 to the nearest integer (towards positive infinity).
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

/// Implements the equal operation (==) for SD29x9 type.
public fun eq(x: SD29x9, y: SD29x9): bool {
    x.unwrap() == y.unwrap()
}

/// Rounds down a SD29x9 to the nearest integer (towards negative infinity).
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

/// Implements the greater than operation (>) for SD29x9 type.
public fun gt(x: SD29x9, y: SD29x9): bool {
    greater_than_bits(x.unwrap(), y.unwrap())
}

/// Implements the greater than or equal to operation (>=) for SD29x9 type.
public fun gte(x: SD29x9, y: SD29x9): bool {
    !lt(x, y)
}

/// Implements a zero comparison check function for SD29x9 type.
public fun is_zero(x: SD29x9): bool {
    x.unwrap() == 0
}

/// Implements the left shift operation (<<) for SD29x9 type.
///
/// This shift is performed on the raw two's-complement bits.
/// - If `bits >= 128`, returns zero (all bits cleared).
/// - Otherwise, shifts the raw bits left by `bits` and masks to 128 bits.
/// - This is a logical left shift; it does not preserve the sign and can
///   move 1s into the sign bit.
public fun lshift(x: SD29x9, bits: u8): SD29x9 {
    if (bits >= 128) {
        return zero()
    };
    from_bits((x.unwrap() << bits) & U128_MAX_VALUE)
}

/// Implements the lower than operation (<) for SD29x9 type.
public fun lt(x: SD29x9, y: SD29x9): bool {
    greater_than_bits(y.unwrap(), x.unwrap())
}

/// Implements the lower than or equal to operation (<=) for SD29x9 type.
public fun lte(x: SD29x9, y: SD29x9): bool {
    !gt(x, y)
}

/// Returns the representation of -2^127 in SD29x9
public fun min(): SD29x9 {
    from_bits(MIN_NEGATIVE_VALUE)
}

/// Returns the representation of 2^127 - 1 in SD29x9
public fun max(): SD29x9 {
    from_bits(MAX_POSITIVE_VALUE)
}

/// Implements the checked modulo operation (%) for SD29x9 type.
public fun mod(x: SD29x9, y: SD29x9): SD29x9 {
    let x_components = decompose(x.unwrap());
    let y_components = decompose(y.unwrap());
    let remainder = x_components.mag % y_components.mag;
    wrap_components(Components { neg: x_components.neg, mag: remainder })
}

/// Implements the not equal operation (!=) for SD29x9 type.
public fun neq(x: SD29x9, y: SD29x9): bool {
    !eq(x, y)
}

/// Implements the NOT (~) bitwise operation for SD29x9 type.
public fun not(x: SD29x9): SD29x9 {
    from_bits(x.unwrap() ^ U128_MAX_VALUE)
}

/// Implements the OR (|) bitwise operation for SD29x9 type.
public fun or(x: SD29x9, y: SD29x9): SD29x9 {
    from_bits(x.unwrap() | y.unwrap())
}

/// Implements the right shift operation (>>) for SD29x9 type.
///
/// This shift is performed on the raw two's-complement bits and preserves sign.
/// - If `bits == 0`, returns the original value unchanged.
/// - If `bits >= 128`, returns all 1s for negative values and zero for non-negative values.
/// - Otherwise, performs an arithmetic right shift:
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

/// Implements the checked subtraction operation (-) for SD29x9 type.
public fun sub(x: SD29x9, y: SD29x9): SD29x9 {
    let negated_y = negate_components(decompose(y.unwrap()));
    let result = add_components(decompose(x.unwrap()), negated_y);
    wrap_components(result)
}

/// Implements the unchecked addition operation (+) for SD29x9 type.
public fun unchecked_add(x: SD29x9, y: SD29x9): SD29x9 {
    from_bits(wrapping_add_bits(x.unwrap(), y.unwrap()))
}

/// Implements the unchecked subtraction operation (-) for SD29x9 type.
public fun unchecked_sub(x: SD29x9, y: SD29x9): SD29x9 {
    from_bits(wrapping_sub_bits(x.unwrap(), y.unwrap()))
}

/// Implements the XOR (^) bitwise operation for SD29x9 type.
public fun xor(x: SD29x9, y: SD29x9): SD29x9 {
    from_bits(x.unwrap() ^ y.unwrap())
}

/// Returns a `SD29x9` value of zero.
public fun zero(): SD29x9 {
    from_bits(0)
}

// === Internal helpers ===

public struct Components has copy, drop {
    neg: bool,
    mag: u128,
}

public(package) fun from_bits(bits: u128): SD29x9 {
    SD29x9(bits)
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
    let x_components = decompose(x_bits);
    let y_components = decompose(y_bits);

    if (x_components.neg != y_components.neg) {
        !x_components.neg
    } else if (!x_components.neg) {
        x_components.mag > y_components.mag
    } else {
        x_components.mag < y_components.mag
    }
}

fun two_complement(x: u128): u128 {
    let bitwise_not = x ^ U128_MAX_VALUE;
    bitwise_not + 1
}

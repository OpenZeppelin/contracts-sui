/// # SD29x9 Base Functions
///
/// Base utilities tailored to the signed SD29x9
/// representation (two's complement stored in `u128` with 9 decimal places).
module openzeppelin_fp_math::sd29x9_base;

use openzeppelin_fp_math::sd29x9::{Self, SD29x9, from_bits, zero, one, two_complement};

const U128_MAX_VALUE: u128 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF; // 2^128 - 1
const SIGN_BIT: u128 = 1u128 << 127;
const SCALE: u128 = 1_000_000_000; // 10^9
const SCALE_U256: u256 = SCALE as u256; // 10^9

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

/// Implements the checked modulo operation (%) for SD29x9 type.
public fun mod(x: SD29x9, y: SD29x9): SD29x9 {
    let x = decompose(x.unwrap());
    let y = decompose(y.unwrap());
    let remainder = x.mag % y.mag;
    wrap_components(Components { neg: x.neg, mag: remainder })
}

/// Implements the checked multiplication operation (*) for SD29x9 type.
public fun mul(x: SD29x9, y: SD29x9): SD29x9 {
    let x = decompose(x.unwrap());
    let y = decompose(y.unwrap());
    let neg = x.neg != y.neg;
    let prod = (x.mag as u256) * (y.mag as u256);
    let mag = (prod / SCALE_U256) as u128;
    wrap_components(Components { neg, mag })
}

/// Implements the checked division operation (/) for SD29x9 type.
public fun div(x: SD29x9, y: SD29x9): SD29x9 {
    let x = decompose(x.unwrap());
    let y = decompose(y.unwrap());
    let quotient = x.mag / y.mag;
    let neg = x.neg != y.neg;
    wrap_components(Components { neg, mag: quotient })
}

/// Implements the checked exponentiation operation (^) for SD29x9 type.
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

/// Implements the checked exponentiation operation (^) for SD29x9 type.
public fun pow_alt(x: SD29x9, exp: u8): SD29x9 {
    if (exp == 0) {
        return one()
    };
    if (exp == 1) {
        return x
    };
    let mut result = x;
    let times = exp - 1;
    times.do!(|_| result = result.mul(x));
    result
}

/// Implements unary negation operation (-x) for SD29x9 type.
public fun negate(x: SD29x9): SD29x9 {
    let value = decompose(x.unwrap());
    wrap_components(negate_components(value))
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
    let Components { neg, mag } = value;
    sd29x9::wrap(mag, neg)
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

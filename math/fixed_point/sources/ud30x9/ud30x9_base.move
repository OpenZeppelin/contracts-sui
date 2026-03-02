/// # `UD30x9` Base Functions
///
/// This module provides base utility functions for working with the `UD30x9` fixed-point type.
module openzeppelin_fp_math::ud30x9_base;

use openzeppelin_fp_math::ud30x9::{UD30x9, wrap, one};

// === Constants ===

const U128_MAX_VALUE: u128 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF; // 2^128 - 1
const SCALE: u128 = 1_000_000_000; // 10^9
const SCALE_U256: u256 = SCALE as u256; // 10^9

// === Errors ===

#[error(code = 0)]
const EOverflow: vector<u8> = b"Value overflows UD30x9 (must fit in 2^128 unsigned range)";

// === Public Functions ===

/// Implements the checked addition operation (+) for the `UD30x9` type.
public fun add(x: UD30x9, y: UD30x9): UD30x9 {
    let (x, y) = (x.unwrap() as u256, y.unwrap() as u256);
    wrap_u256(x + y)
}

/// Implements the AND (&) bitwise operation for `UD30x9` type with `u128` bits.
public fun and(x: UD30x9, bits: u128): UD30x9 {
    wrap(x.unwrap() & bits)
}

/// Implements the AND (&) bitwise operation for `UD30x9` type with another `UD30x9`.
public fun and2(x: UD30x9, y: UD30x9): UD30x9 {
    wrap(x.unwrap() & y.unwrap())
}

/// Returns the absolute value of a `UD30x9`. For unsigned types, this is always the value itself.
public fun abs(x: UD30x9): UD30x9 {
    x
}

/// Rounds up a `UD30x9` to the nearest integer (towards positive infinity).
public fun ceil(x: UD30x9): UD30x9 {
    let value = x.unwrap() as u256;
    let fractional = value % SCALE_U256;
    if (fractional == 0) {
        x
    } else {
        let int_part = value - fractional;
        let new_value = int_part + SCALE_U256;
        wrap_u256(new_value)
    }
}

/// Implements the equal operation (==) for `UD30x9` type.
public fun eq(x: UD30x9, y: UD30x9): bool {
    x.unwrap() == y.unwrap()
}

/// Rounds down a `UD30x9` to the nearest integer (towards zero).
public fun floor(x: UD30x9): UD30x9 {
    let value = x.unwrap();
    let fractional = value % SCALE;
    if (fractional == 0) {
        x
    } else {
        wrap(value - fractional)
    }
}

/// Implements the greater than operation (>) for `UD30x9` type.
public fun gt(x: UD30x9, y: UD30x9): bool {
    x.unwrap() > y.unwrap()
}

/// Implements the greater than or equal to operation (>=) for `UD30x9` type.
public fun gte(x: UD30x9, y: UD30x9): bool {
    x.unwrap() >= y.unwrap()
}

/// Implements a zero comparison check function for `UD30x9` type.
public fun is_zero(x: UD30x9): bool {
    x.unwrap() == 0
}

/// Implements the left shift operation (<<) for `UD30x9` type.
public fun lshift(x: UD30x9, bits: u8): UD30x9 {
    wrap(x.unwrap() << bits)
}

/// Implements the lower than operation (<) for `UD30x9` type.
public fun lt(x: UD30x9, y: UD30x9): bool {
    x.unwrap() < y.unwrap()
}

/// Implements the lower than or equal to operation (<=) for `UD30x9` type.
public fun lte(x: UD30x9, y: UD30x9): bool {
    x.unwrap() <= y.unwrap()
}

/// Implements the checked modulo operation (%) for `UD30x9` type.
public fun mod(x: UD30x9, y: UD30x9): UD30x9 {
    let (x, y) = (x.unwrap() as u256, y.unwrap() as u256);
    wrap_u256(x % y)
}

/// Implements the checked multiplication operation (*) for `UD30x9` type.
public fun mul(x: UD30x9, y: UD30x9): UD30x9 {
    let (x, y) = (x.unwrap() as u256, y.unwrap() as u256);
    let product = x * y / SCALE_U256;
    wrap_u256(product)
}

/// Implements the checked division operation (/) for `UD30x9` type.
public fun div(x: UD30x9, y: UD30x9): UD30x9 {
    let (x, y) = (x.unwrap() as u256, y.unwrap() as u256);
    let numerator = x * SCALE_U256;
    wrap_u256(numerator / y)
}

/// Implements the checked exponentiation operation (^) for `UD30x9` type.
public fun pow(x: UD30x9, exp: u8): UD30x9 {
    if (exp == 0) {
        return one()
    };
    if (exp == 1) {
        return x
    };
    let base = x.unwrap() as u256;
    let mut result = base;
    let times = exp - 1;
    times.do!(|_| result = result * base / SCALE_U256);

    wrap_u256(result)
}

/// Implements the checked exponentiation operation (^) for `UD30x9` type.
public fun pow_alt(x: UD30x9, exp: u8): UD30x9 {
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

/// Implements the not equal operation (!=) for `UD30x9` type.
public fun neq(x: UD30x9, y: UD30x9): bool {
    x.unwrap() != y.unwrap()
}

/// Implements the NOT (~) bitwise operation for `UD30x9` type.
public fun not(x: UD30x9): UD30x9 {
    wrap(x.unwrap() ^ U128_MAX_VALUE)
}

/// Implements the OR (|) bitwise operation for `UD30x9` type.
public fun or(x: UD30x9, y: UD30x9): UD30x9 {
    wrap(x.unwrap() | y.unwrap())
}

/// Implements the right shift operation (>>) for `UD30x9` type.
public fun rshift(x: UD30x9, bits: u8): UD30x9 {
    wrap(x.unwrap() >> bits)
}

/// Implements the checked subtraction operation (-) for `UD30x9` type.
public fun sub(x: UD30x9, y: UD30x9): UD30x9 {
    let (x, y) = (x.unwrap(), y.unwrap());
    assert!(x >= y, EOverflow);
    wrap(x - y)
}

/// Implements the unchecked addition operation (+) for `UD30x9` type.
public fun unchecked_add(x: UD30x9, y: UD30x9): UD30x9 {
    let (x, y) = (x.unwrap() as u256, y.unwrap() as u256);
    let sum = x + y;
    let u128_max = U128_MAX_VALUE as u256;

    // Keep only the low 128 bits, safe to cast down to u128.
    let wrapped = (sum & u128_max) as u128;
    wrap(wrapped)
}

/// Implements the unchecked subtraction operation (-) for `UD30x9` type.
public fun unchecked_sub(x: UD30x9, y: UD30x9): UD30x9 {
    let (x, y) = (x.unwrap() as u256, y.unwrap() as u256);
    let u128_max = U128_MAX_VALUE as u256;

    // Effectively wraps subtraction like in modular arithmetic.
    // The result is (a + (2^128) - b).
    let diff = x + (u128_max + 1) - y;

    // Wrap the result back into the u128 range by taking the low 128 bits.
    let wrapped = (diff & u128_max) as u128;
    wrap(wrapped)
}

/// Implements the XOR (^) bitwise operation for `UD30x9` type.
public fun xor(x: UD30x9, y: UD30x9): UD30x9 {
    wrap(x.unwrap() ^ y.unwrap())
}

// === Internal Functions ===

fun wrap_u256(value: u256): UD30x9 {
    assert!(value <= U128_MAX_VALUE as u256, EOverflow);
    wrap(value as u128)
}

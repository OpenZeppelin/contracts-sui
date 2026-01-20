/// # UD30x9 Base Functions
///
/// This module provides base utility functions for working with the UD30x9 fixed-point type.
module openzeppelin_fp_math::ud30x9_base;

use openzeppelin_fp_math::ud30x9::{UD30x9, wrap};

// === Constants ===

const MAX_VALUE: u128 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF; // 2^128 - 1
const SCALE: u128 = 1_000_000_000; // 10^9

// === Public Functions ===

/// Implements the checked addition operation (+) for the UD30x9 type.
public fun add(x: UD30x9, y: UD30x9): UD30x9 {
    wrap(x.unwrap() + y.unwrap())
}

/// Implements the AND (&) bitwise operation for UD30x9 type with u128 bits.
public fun and(x: UD30x9, bits: u128): UD30x9 {
    wrap(x.unwrap() & bits)
}

/// Implements the AND (&) bitwise operation for UD30x9 type with another UD30x9.
public fun and2(x: UD30x9, y: UD30x9): UD30x9 {
    wrap(x.unwrap() & y.unwrap())
}

/// Returns the absolute value of a UD30x9. For unsigned types, this is always the value itself.
public fun abs(x: UD30x9): UD30x9 {
    x
}

/// Rounds up a UD30x9 to the nearest integer (towards positive infinity).
public fun ceil(x: UD30x9): UD30x9 {
    let value = x.unwrap();
    let fractional = value % SCALE;

    if (fractional == 0) {
        x
    } else {
        let int_part = value - fractional;
        wrap(int_part + SCALE)
    }
}

/// Implements the equal operation (==) for UD30x9 type.
public fun eq(x: UD30x9, y: UD30x9): bool {
    x.unwrap() == y.unwrap()
}

/// Rounds down a UD30x9 to the nearest integer (towards zero).
public fun floor(x: UD30x9): UD30x9 {
    let value = x.unwrap();
    let fractional = value % SCALE;

    if (fractional == 0) {
        x
    } else {
        wrap(value - fractional)
    }
}

/// Implements the greater than operation (>) for UD30x9 type.
public fun gt(x: UD30x9, y: UD30x9): bool {
    x.unwrap() > y.unwrap()
}

/// Implements the greater than or equal to operation (>=) for UD30x9 type.
public fun gte(x: UD30x9, y: UD30x9): bool {
    x.unwrap() >= y.unwrap()
}

/// Implements a zero comparison check function for UD30x9 type.
public fun is_zero(x: UD30x9): bool {
    x.unwrap() == 0
}

/// Implements the left shift operation (<<) for UD30x9 type.
public fun lshift(x: UD30x9, bits: u8): UD30x9 {
    wrap(x.unwrap() << bits)
}

/// Implements the lower than operation (<) for UD30x9 type.
public fun lt(x: UD30x9, y: UD30x9): bool {
    x.unwrap() < y.unwrap()
}

/// Implements the lower than or equal to operation (<=) for UD30x9 type.
public fun lte(x: UD30x9, y: UD30x9): bool {
    x.unwrap() <= y.unwrap()
}

/// Implements the checked modulo operation (%) for UD30x9 type.
public fun mod(x: UD30x9, y: UD30x9): UD30x9 {
    wrap(x.unwrap() % y.unwrap())
}

/// Implements the not equal operation (!=) for UD30x9 type.
public fun neq(x: UD30x9, y: UD30x9): bool {
    x.unwrap() != y.unwrap()
}

/// Implements the NOT (~) bitwise operation for UD30x9 type.
public fun not(x: UD30x9): UD30x9 {
    wrap(x.unwrap() ^ MAX_VALUE)
}

/// Implements the OR (|) bitwise operation for UD30x9 type.
public fun or(x: UD30x9, y: UD30x9): UD30x9 {
    wrap(x.unwrap() | y.unwrap())
}

/// Implements the right shift operation (>>) for UD30x9 type.
public fun rshift(x: UD30x9, bits: u8): UD30x9 {
    wrap(x.unwrap() >> bits)
}

/// Implements the checked subtraction operation (-) for UD30x9 type.
public fun sub(x: UD30x9, y: UD30x9): UD30x9 {
    wrap(x.unwrap() - y.unwrap())
}

/// Implements the unchecked addition operation (+) for UD30x9 type.
public fun unchecked_add(x: UD30x9, y: UD30x9): UD30x9 {
    let sum: u256 = (x.unwrap() as u256) + (y.unwrap() as u256);

    // Keep only the low 128 bits.
    let wrapped: u256 = sum & (MAX_VALUE as u256);
    wrap(wrapped as u128)
}

/// Implements the unchecked subtraction operation (-) for UD30x9 type.
public fun unchecked_sub(x: UD30x9, y: UD30x9): UD30x9 {
    let a = x.unwrap();
    let b = y.unwrap();
    let u128_max = MAX_VALUE as u256;

    // Effectively wraps subtraction like in modular arithmetic.
    // The result is (a + (2^128) - b).
    let diff: u256 = (a as u256) + (u128_max + 1) - (b as u256);

    // Wrap the result back into the u128 range by taking the low 128 bits.
    let wrapped: u256 = diff & u128_max;
    wrap(wrapped as u128)
}

/// Implements the XOR (^) bitwise operation for UD30x9 type.
public fun xor(x: UD30x9, y: UD30x9): UD30x9 {
    wrap(x.unwrap() ^ y.unwrap())
}

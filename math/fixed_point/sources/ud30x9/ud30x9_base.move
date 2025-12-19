/// # UD30x9 Base Functions
///
/// This module provides base utility functions for working with the UD30x9 fixed-point type.
module openzeppelin_fp_math::ud30x9_base;

use openzeppelin_fp_math::ud30x9::{UD30x9, unwrap, wrap};

// === Constants ===

const MAX_VALUE: u128 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;

// === Public Functions ===

/// Implements the checked addition operation (+) for the UD30x9 type.
public fun add(x: UD30x9, y: UD30x9): UD30x9 {
    wrap(unwrap(x) + unwrap(y))
}

/// Implements the AND (&) bitwise operation for UD30x9 type with u128 bits.
public fun and(x: UD30x9, bits: u128): UD30x9 {
    wrap(unwrap(x) & bits)
}

/// Implements the AND (&) bitwise operation for UD30x9 type with another UD30x9.
public fun and2(x: UD30x9, y: UD30x9): UD30x9 {
    wrap(unwrap(x) & unwrap(y))
}

/// Implements the equal operation (==) for UD30x9 type.
public fun eq(x: UD30x9, y: UD30x9): bool {
    unwrap(x) == unwrap(y)
}

/// Implements the greater than operation (>) for UD30x9 type.
public fun gt(x: UD30x9, y: UD30x9): bool {
    unwrap(x) > unwrap(y)
}

/// Implements the greater than or equal to operation (>=) for UD30x9 type.
public fun gte(x: UD30x9, y: UD30x9): bool {
    unwrap(x) >= unwrap(y)
}

/// Implements a zero comparison check function for UD30x9 type.
public fun is_zero(x: UD30x9): bool {
    unwrap(x) == 0
}

/// Implements the left shift operation (<<) for UD30x9 type.
public fun lshift(x: UD30x9, bits: u8): UD30x9 {
    wrap(unwrap(x) << bits)
}

/// Implements the lower than operation (<) for UD30x9 type.
public fun lt(x: UD30x9, y: UD30x9): bool {
    unwrap(x) < unwrap(y)
}

/// Implements the lower than or equal to operation (<=) for UD30x9 type.
public fun lte(x: UD30x9, y: UD30x9): bool {
    unwrap(x) <= unwrap(y)
}

/// Implements the checked modulo operation (%) for UD30x9 type.
public fun mod_(x: UD30x9, y: UD30x9): UD30x9 {
    wrap(unwrap(x) % unwrap(y))
}

/// Implements the not equal operation (!=) for UD30x9 type.
public fun neq(x: UD30x9, y: UD30x9): bool {
    unwrap(x) != unwrap(y)
}

/// Implements the NOT (~) bitwise operation for UD30x9 type.
public fun not(x: UD30x9): UD30x9 {
    wrap(unwrap(x) ^ MAX_VALUE)
}

/// Implements the OR (|) bitwise operation for UD30x9 type.
public fun or(x: UD30x9, y: UD30x9): UD30x9 {
    wrap(unwrap(x) | unwrap(y))
}

/// Implements the right shift operation (>>) for UD30x9 type.
public fun rshift(x: UD30x9, bits: u8): UD30x9 {
    wrap(unwrap(x) >> bits)
}

/// Implements the checked subtraction operation (-) for UD30x9 type.
public fun sub(x: UD30x9, y: UD30x9): UD30x9 {
    wrap(unwrap(x) - unwrap(y))
}

/// Implements the unchecked addition operation (+) for UD30x9 type.
public fun unchecked_add(x: UD30x9, y: UD30x9): UD30x9 {
    let sum: u256 = (unwrap(x) as u256) + (unwrap(y) as u256);

    // Keep only the low 128 bits.
    let wrapped: u256 = sum & (MAX_VALUE as u256);
    wrap(wrapped as u128)
}

/// Implements the unchecked subtraction operation (-) for UD30x9 type.
public fun unchecked_sub(x: UD30x9, y: UD30x9): UD30x9 {
    let a = unwrap(x);
    let b = unwrap(y);
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
    wrap(unwrap(x) ^ unwrap(y))
}

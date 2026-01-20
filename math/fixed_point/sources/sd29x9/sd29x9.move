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

const MAX_POSITIVE_VALUE: u128 = 0x7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF; // 2^127 - 1
const MIN_NEGATIVE_VALUE: u128 = 0x8000_0000_0000_0000_0000_0000_0000_0000; // -2^127 in two's complement
const U128_MAX_VALUE: u128 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF; // 2^128 - 1

// === Errors ===

/// Value cannot be safely cast to `SD29x9` after apply
#[error(code = 0)]
const EOverflow: vector<u8> = b"Value overflows SD29x9 (must fit in 2^127 signed range)";

// === Functions ===

public use fun openzeppelin_fp_math::sd29x9_base::abs as SD29x9.abs;
public use fun openzeppelin_fp_math::sd29x9_base::add as SD29x9.add;
public use fun openzeppelin_fp_math::sd29x9_base::and as SD29x9.and;
public use fun openzeppelin_fp_math::sd29x9_base::and2 as SD29x9.and2;
public use fun openzeppelin_fp_math::sd29x9_base::ceil as SD29x9.ceil;
public use fun openzeppelin_fp_math::sd29x9_base::eq as SD29x9.eq;
public use fun openzeppelin_fp_math::sd29x9_base::floor as SD29x9.floor;
public use fun openzeppelin_fp_math::sd29x9_base::gt as SD29x9.gt;
public use fun openzeppelin_fp_math::sd29x9_base::gte as SD29x9.gte;
public use fun openzeppelin_fp_math::sd29x9_base::is_zero as SD29x9.is_zero;
public use fun openzeppelin_fp_math::sd29x9_base::lshift as SD29x9.lshift;
public use fun openzeppelin_fp_math::sd29x9_base::lt as SD29x9.lt;
public use fun openzeppelin_fp_math::sd29x9_base::lte as SD29x9.lte;
public use fun openzeppelin_fp_math::sd29x9_base::mod as SD29x9.mod;
public use fun openzeppelin_fp_math::sd29x9_base::neq as SD29x9.neq;
public use fun openzeppelin_fp_math::sd29x9_base::not as SD29x9.not;
public use fun openzeppelin_fp_math::sd29x9_base::or as SD29x9.or;
public use fun openzeppelin_fp_math::sd29x9_base::rshift as SD29x9.rshift;
public use fun openzeppelin_fp_math::sd29x9_base::sub as SD29x9.sub;
public use fun openzeppelin_fp_math::sd29x9_base::unchecked_add as SD29x9.unchecked_add;
public use fun openzeppelin_fp_math::sd29x9_base::unchecked_sub as SD29x9.unchecked_sub;
public use fun openzeppelin_fp_math::sd29x9_base::xor as SD29x9.xor;

/// Returns a `SD29x9` value of zero.
public fun zero(): SD29x9 {
    SD29x9(0)
}

/// Returns the representation of -2^127 in SD29x9
public fun min(): SD29x9 {
    SD29x9(MIN_NEGATIVE_VALUE)
}

/// Returns the representation of 2^127 - 1 in SD29x9
public fun max(): SD29x9 {
    SD29x9(MAX_POSITIVE_VALUE)
}

// === Casting helpers ===

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
        SD29x9(two_complement(x))
    } else {
        SD29x9(x)
    }
}

/// Unwraps a `SD29x9` value into a `u128`.
public fun unwrap(x: SD29x9): u128 {
    x.0
}

// ==== Internal Functions ====

public(package) fun two_complement(x: u128): u128 {
    let bitwise_not = x ^ U128_MAX_VALUE;
    bitwise_not + 1
}

public(package) fun from_bits(bits: u128): SD29x9 {
    SD29x9(bits)
}

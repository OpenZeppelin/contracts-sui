module openzeppelin_math::macros;

use openzeppelin_math::common;
use openzeppelin_math::rounding::{Self, RoundingMode};
use openzeppelin_math::u512;

#[error(code = 0)]
const EDivideByZero: vector<u8> = b"Divisor must be non-zero";
#[error(code = 1)]
const EZeroModulus: vector<u8> = b"Modulus must be non-zero.";

/// Compute the arithmetic mean of two unsigned integers with configurable rounding.
///
/// The helper works across all unsigned widths by normalising the operands to `u256`. It avoids
/// overflow by anchoring on the smaller input, halving the difference with `mul_div_inner`, and
/// then shifting back into the caller's width.
public(package) macro fun average<$Int>($a: $Int, $b: $Int, $rounding_mode: RoundingMode): $Int {
    let a_u256 = ($a as u256);
    let b_u256 = ($b as u256);
    let rounding_mode = $rounding_mode;

    // Short circuit to avoid unnecessary computation.
    if (a_u256 == b_u256) {
        return a_u256 as $Int
    };

    let mut lower = a_u256;
    let mut upper = b_u256;
    if (lower > upper) {
        lower = b_u256;
        upper = a_u256;
    };

    let delta = upper - lower;
    // Use the fast path as delta * 1 is guaranteed to fit in u256
    let (_, half) = mul_div_u256_fast(delta, 1, 2, rounding_mode);
    let average = lower + half;

    average as $Int
}

/// Attempt to left shift `$value` by `$shift` bits while ensuring no truncated bits are lost.
///
/// The helper inspects the upper `$shift` bits and only performs the shift when all of them are
/// zero, avoiding silent precision loss. It mirrors the signatures of the width-specific wrappers,
/// returning `option::none()` when the operation would drop information. The macro does **not**
/// enforce that `$shift` is below the bit-width of `$Int`; callers must guarantee that condition to
/// avoid the Move runtime abort that occurs when shifting by an excessive amount.
///
/// #### Generics
/// - `$Int`: Any unsigned integer type (`u8`, `u16`, `u32`, `u64`, `u128`, or `u256`).
///
/// #### Parameters
/// - `$value`: Unsigned integer subject to the shift.
/// - `$shift`: Number of bits to shift to the left. Must be less than the bit-width of `$Int`.
///
/// #### Returns
/// `option::some(result)` with the shifted value when the high bits are all zero, otherwise
/// `option::none()`.
///
/// #### Aborts
/// Does not emit custom errors, but will inherit the Move abort that occurs when `$shift` is greater
/// than or equal to the bit-width of `$Int`.
public(package) macro fun checked_shl<$Int>($value: $Int, $shift: u8): Option<$Int> {
    if ($shift == 0) {
        return option::some($value)
    };
    // Masking should be more efficient but it requires to know the bit
    // size of $Int and we favor simplicity in this case.
    let shifted = $value << $shift;
    let shifted_back = shifted >> $shift;
    if (shifted_back != $value) {
        return option::none()
    };
    option::some(shifted)
}

/// Attempt to right shift `$value` by `$shift` bits while ensuring no truncated bits are lost.
///
/// The helper inspects the lower `$shift` bits and only performs the shift when all of them are
/// zero, avoiding silent precision loss. It mirrors the signatures of the width-specific wrappers,
/// returning `option::none()` when the operation would drop information. The macro does **not**
/// enforce that `$shift` is below the bit-width of `$Int`; callers must guarantee that condition to
/// avoid the Move runtime abort that occurs when shifting by an excessive amount.
///
/// #### Generics
/// - `$Int`: Any unsigned integer type (`u8`, `u16`, `u32`, `u64`, `u128`, or `u256`).
///
/// #### Parameters
/// - `$value`: Unsigned integer subject to the shift.
/// - `$shift`: Number of bits to shift to the right. Must be less than the bit-width of `$Int`.
///
/// #### Returns
/// `option::some(result)` with the shifted value when the low bits are all zero, otherwise
/// `option::none()`.
///
/// #### Aborts
/// Does not emit custom errors, but will inherit the Move abort that occurs when `$shift` is greater
/// than or equal to the bit-width of `$Int`.
public(package) macro fun checked_shr<$Int>($value: $Int, $shift: u8): Option<$Int> {
    let mask = (1_u256 << $shift) - 1;
    let shifted = $value & (mask as $Int);
    if (shifted != 0) {
        return option::none()
    };
    option::some($value >> $shift)
}

/// Multiply `a` and `b`, divide by `denominator`, and round according to `rounding_mode`.
///
/// This macro provides a uniform API for `mul_div` across all unsigned integer widths. It normalises
/// the inputs to `u256`, chooses the most efficient helper, and returns the rounded quotient alongside
/// an overflow flag. Narrower wrapper modules downcast the result after ensuring it fits. Undefined
/// divisions (e.g. denominator = 0) abort with descriptive error codes.
///
/// #### Generics
/// - `$Int`: Any unsigned integer type (`u8`, `u16`, `u32`, `u64`, `u128`, or `u256`).
///
/// #### Parameters
/// - `$a`, `$b`: Unsigned factors.
/// - `$denominator`: Unsigned divisor.
/// - `$rounding_mode`: Rounding strategy.
///
/// #### Returns
/// `(overflow, result)` where `overflow` is `true` when the rounded quotient exceeds `u256::MAX` and
/// `result` carries the rounded value when no overflow occurred.
///
/// #### Aborts
/// Propagates the same error codes as the underlying helpers (`EDivideByZero`).
public(package) macro fun mul_div<$Int>(
    $a: $Int,
    $b: $Int,
    $denominator: $Int,
    $rounding_mode: RoundingMode,
): (bool, u256) {
    let a_u256 = ($a as u256);
    let b_u256 = ($b as u256);
    let denominator_u256 = ($denominator as u256);
    let rounding_mode = $rounding_mode;

    mul_div_inner(a_u256, b_u256, denominator_u256, rounding_mode)
}

/// Multiply `a` and `b`, shift the product right by `shift`, and round according to `rounding_mode`.
///
/// This macro mirrors the ergonomics of `mul_div`, promoting the operands to `u256` and delegating to
/// a shared helper that performs the computation using the most efficient implementation available.
/// It starts from the floor of `(a * b) / 2^shift`, then applies the requested rounding mode. The
/// overflow flag reports when the rounded value no longer fits in the `u256` range (i.e. significant
/// bits remain above the lowest 256 bits after the shift).
///
/// #### Generics
/// - `$Int`: Any unsigned integer type (`u8`, `u16`, `u32`, `u64`, `u128`, or `u256`).
///
/// #### Parameters
/// - `$a`, `$b`: Unsigned factors.
/// - `$shift`: Number of bits to shift to the right. Must be less than 256.
/// - `$rounding_mode`: Rounding strategy drawn from `rounding::RoundingMode`.
///
/// #### Returns
/// `(overflow, result)` where `overflow` reports that the rounded value cannot fit in 256 bits and
/// `result` contains the rounded quotient when no overflow occurs.
///
/// #### Aborts
/// Does not emit custom errors, but will inherit the Move abort that occurs when `$shift` is 256 or
/// greater.
public(package) macro fun mul_shr<$Int>(
    $a: $Int,
    $b: $Int,
    $shift: u8,
    $rounding_mode: RoundingMode,
): (bool, u256) {
    let a_u256 = ($a as u256);
    let b_u256 = ($b as u256);
    let shift = $shift;
    let rounding_mode = $rounding_mode;

    mul_shr_inner(a_u256, b_u256, shift, rounding_mode)
}

/// Count the number of leading zero bits in an unsigned integer.
///
/// Uses an iterative binary search to efficiently locate the most significant set bit by repeatedly
/// halving the search range. The algorithm normalizes the input to `u256` and right-shifts by
/// progressively smaller powers of two (`bit_width/2`, `bit_width/4`, ..., `1`). When a shift
/// produces zero, the high bit must lie in the lower half, so we increment the leading-zero count
/// and examine the original (unshifted) portion. Otherwise, we focus on the shifted (upper) portion.
/// For a value of zero, the helper returns the full bit width.
///
/// #### Generics
/// - `$Int`: Any unsigned integer type (`u8`, `u16`, `u32`, `u64`, `u128`, or `u256`).
///
/// #### Parameters
/// - `$value`: The unsigned integer to count leading zeros for.
/// - `$bit_width`: The bit width of the type (8, 16, 32, 64, 128, or 256).
///
/// #### Returns
/// The number of leading zero bits as a `u16`. Returns `$bit_width` if `$value` is 0.
public(package) macro fun clz<$Int>($value: $Int, $bit_width: u16): u16 {
    common::clz($value as u256, $bit_width)
}

/// Compute the modular multiplicative inverse of `$value` in `Z / modulus`.
///
/// The helper relies on the extended Euclidean algorithm which works for any modulus as long as
/// `$value` and `$modulus` are co-prime. If the inverse does not exist, the function returns
/// `option::none()`.
///
/// #### Parameters
/// - `$value`: Unsigned integer whose inverse is being computed.
/// - `$modulus`: Modulus for the arithmetic; must be non-zero.
///
/// #### Returns
/// `option::some(inverse)` when the inverse exists (`value * inverse ≡ 1 (mod modulus)`),
/// otherwise `option::none()`.
public(package) macro fun inv_mod<$Int>($value: $Int, $modulus: $Int): Option<$Int> {
    let value_u256 = ($value as u256);
    let modulus_u256 = ($modulus as u256);
    let result = inv_mod_extended_impl(value_u256, modulus_u256);
    option::map!(result, |v| v as $Int)
}

/// Multiply `$a` and `$b` modulo `$modulus`.
///
/// Uses the shared internal helper that automatically chooses between the fast `u256` path and
/// the wide `u512` implementation. The modulus must be non-zero.
///
/// #### Parameters
/// - `$a`, `$b`: Unsigned operands.
/// - `$modulus`: Modulus for the arithmetic; must be non-zero.
///
/// #### Returns
/// The product reduced modulo `$modulus`.
public(package) macro fun mul_mod<$Int>($a: $Int, $b: $Int, $modulus: $Int): $Int {
    let a_u256 = ($a as u256);
    let b_u256 = ($b as u256);
    let modulus_u256 = ($modulus as u256);
    mul_mod_impl(a_u256, b_u256, modulus_u256) as $Int
}

/// Return the position of the most significant bit (MSB) in an unsigned integer.
///
/// This macro provides a uniform API for finding the MSB position across all unsigned integer widths.
/// It normalizes the input to `u256` and delegates to the internal helper. The MSB position is the
/// zero-based index of the highest set bit. For a zero input, the function returns 0 by convention.
///
/// #### Generics
/// - `$Int`: Any unsigned integer type (`u8`, `u16`, `u32`, `u64`, `u128`, or `u256`).
///
/// #### Parameters
/// - `$value`: The unsigned integer to analyze.
/// - `$bit_width`: The bit width of the type (8, 16, 32, 64, 128, or 256).
///
/// #### Returns
/// The zero-based position of the most significant bit as a `u8`.
/// Returns `0` if `$value` is 0.
public(package) macro fun msb<$Int>($value: $Int, $bit_width: u16): u8 {
    common::msb($value as u256, $bit_width)
}

/// Compute the log in base 2 of a positive value with configurable rounding.
///
/// The algorithm first computes floor(log2(value)) using count-leading-zeros, then applies the
/// requested rounding mode. Powers of 2 return exact results without additional rounding.
///
/// #### Generics
/// - `$Int`: Any unsigned integer type (`u8`, `u16`, `u32`, `u64`, `u128`, or `u256`).
///
/// #### Parameters
/// - `$value`: The unsigned integer to compute the logarithm for.
/// - `$bit_width`: The bit width of the type (8, 16, 32, 64, 128, or 256).
/// - `$rounding_mode`: Rounding strategy drawn from `rounding::RoundingMode`.
///
/// #### Returns
/// The base-2 logarithm as a `u16`, rounded according to the specified mode.
/// Returns `0` if `$value` is 0.
public(package) macro fun log2<$Int>(
    $value: $Int,
    $bit_width: u16,
    $rounding_mode: RoundingMode,
): u16 {
    let (value, bit_width, rounding_mode) = ($value as u256, $bit_width, $rounding_mode);
    if (value == 0) {
        return 0
    };
    let floor_log = common::msb(value, bit_width) as u16;

    if (rounding_mode == rounding::down()) {
        floor_log
    } else if (value == 1 << (floor_log as u8)) {
        // Exact power of 2
        floor_log
    } else if (rounding_mode == rounding::up()) {
        floor_log + 1
    } else {
        round_log2_to_nearest(value, floor_log)
    }
}

/// Compute the log in base 256 of a positive value with configurable rounding.
///
/// Since log₂₅₆(x) = log₂(x) / 8, the algorithm computes log₂(x) first, then divides by 8.
/// Powers of 2 return exact results without additional rounding.
///
/// #### Generics
/// - `$Int`: Any unsigned integer type (`u8`, `u16`, `u32`, `u64`, `u128`, or `u256`).
///
/// #### Parameters
/// - `$value`: The unsigned integer to compute the logarithm for.
/// - `$bit_width`: The bit width of the type (8, 16, 32, 64, 128, or 256).
/// - `$rounding_mode`: Rounding strategy drawn from `rounding::RoundingMode`.
///
/// #### Returns
/// The base-256 logarithm as a `u8`, rounded according to the specified mode.
/// Returns `0` if `$value` is 0.
public(package) macro fun log256<$Int>(
    $value: $Int,
    $bit_width: u16,
    $rounding_mode: RoundingMode,
): u8 {
    let (value, bit_width, rounding_mode) = ($value as u256, $bit_width, $rounding_mode);
    if (value == 0) {
        return 0
    };
    let floor_log2 = common::msb(value, bit_width);
    let floor_log256 = floor_log2 / 8;

    if (rounding_mode == rounding::down()) {
        floor_log256
    } else if (floor_log2 % 8 == 0 && value == 1 << (floor_log2 as u8)) {
        // Exact power of 256
        floor_log256
    } else if (rounding_mode == rounding::up()) {
        floor_log256 + 1
    } else {
        round_log256_to_nearest(value, floor_log256)
    }
}

/// Compute the log in base 10 of a positive value with configurable rounding.
///
/// The algorithm first computes floor(log10(value)), then applies the requested
/// rounding mode. Powers of 10 return exact results without additional rounding.
///
/// #### Generics
/// - `$Int`: Any unsigned integer type (`u8`, `u16`, `u32`, `u64`, `u128`, or `u256`).
///
/// #### Parameters
/// - `$value`: The unsigned integer to compute the logarithm for.
/// - `$rounding_mode`: Rounding strategy drawn from `rounding::RoundingMode`.
///
/// #### Returns
/// The base-10 logarithm as a `u8`, rounded according to the specified mode.
/// Returns `0` if `$value` is 0.
public(package) macro fun log10<$Int>($value: $Int, $rounding_mode: RoundingMode): u8 {
    let (value, rounding_mode) = ($value as u256, $rounding_mode);
    if (value == 0) {
        return 0
    };
    let floor_result = log10_floor(value);
    if (rounding_mode == rounding::down()) {
        floor_result
    } else if (value == std::u256::pow(10, floor_result)) {
        // Exact power of 10
        floor_result
    } else if (rounding_mode == rounding::up()) {
        floor_result + 1
    } else {
        round_log10_to_nearest(value, floor_result)
    }
}

const MAX_LOG_10: u8 = 77;
const TEN_POW_2: u256 = 100;
const TEN_POW_4: u256 = TEN_POW_2 * TEN_POW_2;
const TEN_POW_8: u256 = TEN_POW_4 * TEN_POW_4;
const TEN_POW_16: u256 = TEN_POW_8 * TEN_POW_8;
const TEN_POW_32: u256 = TEN_POW_16 * TEN_POW_16;
const TEN_POW_64: u256 = TEN_POW_32 * TEN_POW_32;

/// Compute floor(log10(value)) using binary search over powers of 10.
///
/// This helper uses precomputed constants (`TEN_POW_2`, `TEN_POW_4`, etc.) to efficiently
/// determine the magnitude of the input value. The algorithm repeatedly divides by higher
/// powers of 10 (64, 32, 16, 8, 4, 2, 1) to narrow down the floor logarithm.
///
/// #### Parameters
/// - `value`: The input value as a `u256`.
///
/// #### Returns
/// The floor of log10(value) as a `u8`. For `value = 0`, returns `0` by convention.
public(package) fun log10_floor(value: u256): u8 {
    let mut value = value;
    let mut result = 0;
    if (value >= TEN_POW_64) {
        value = value / TEN_POW_64;
        result = result + 64;
    };
    if (value >= TEN_POW_32) {
        value = value / TEN_POW_32;
        result = result + 32;
    };
    if (value >= TEN_POW_16) {
        value = value / TEN_POW_16;
        result = result + 16;
    };
    if (value >= TEN_POW_8) {
        value = value / TEN_POW_8;
        result = result + 8;
    };
    if (value >= TEN_POW_4) {
        value = value / TEN_POW_4;
        result = result + 4;
    };
    if (value >= TEN_POW_2) {
        value = value / TEN_POW_2;
        result = result + 2;
    };
    if (value >= 10) {
        result = result + 1;
    };
    result
}

/// === Helper functions ===

/// Internal helper for `mul_div` that selects the most efficient implementation based on the input size.
/// Returns `(overflow, quotient)` mirroring the macro implementation.
public(package) fun mul_div_inner(
    a: u256,
    b: u256,
    denominator: u256,
    rounding_mode: RoundingMode,
): (bool, u256) {
    let max_small = std::u128::max_value!() as u256;
    if (a > max_small || b > max_small) {
        mul_div_u256_wide(a, b, denominator, rounding_mode)
    } else {
        mul_div_u256_fast(a, b, denominator, rounding_mode)
    }
}

/// Multiply two `u256` values, divide by `denominator`, and round the result without widening.
///
/// This helper assumes both operands fit within `u128`, which allows us to perform the entire
/// computation in native `u256` space. That keeps the code fast and avoids allocating the full
/// 512-bit intermediate representation. Rounding is applied according to `rounding_mode`.
///
/// #### Parameters
/// - `a`, `b`: Unsigned factors whose product stays below 2^256.
/// - `denominator`: Unsigned divisor, must be non-zero.
/// - `rounding_mode`: Rounding strategy drawn from `rounding::RoundingMode`.
///
/// #### Returns
/// The rounded quotient as a `u256`.
///
/// #### Aborts
/// - `EDivideByZero` if `denominator` is zero.
public(package) fun mul_div_u256_fast(
    a: u256,
    b: u256,
    denominator: u256,
    rounding_mode: RoundingMode,
): (bool, u256) {
    assert!(denominator != 0, EDivideByZero);

    let numerator = a * b;
    let mut quotient = numerator / denominator;
    let remainder = numerator % denominator;

    if (remainder != 0) {
        // Overflow is not possible here because the numerator (a * b) is bounded by (2^128-1)^2 < u256::MAX.
        // Even after rounding up, the result fits in u256.
        (_, quotient) = round_division_result(quotient, denominator, remainder, rounding_mode);
    };

    (false, quotient)
}

/// Multiply two `u256` values with full 512-bit precision before dividing and rounding.
///
/// This variant handles the general case where `a * b` may exceed 2^256. It widens the product to
/// a 512-bit value, performs an exact division, and then applies rounding. If the true quotient does
/// not fit back into 256 bits or rounding would push it past the maximum value, the helper returns
/// `(true, _)` to signal overflow.
///
/// #### Parameters
/// - `a`, `b`: Unsigned factors up to 2^256 - 1.
/// - `denominator`: Unsigned divisor, must be non-zero.
/// - `rounding_mode`: Rounding strategy drawn from `rounding::RoundingMode`.
///
/// #### Returns
/// `(overflow, result)` where `overflow` indicates whether the exact (or rounded) quotient exceeds
/// the `u256` range. `result` is only meaningful when `overflow` is `false`.
///
/// #### Aborts
/// - `EDivideByZero` if `denominator` is zero.
public(package) fun mul_div_u256_wide(
    a: u256,
    b: u256,
    denominator: u256,
    rounding_mode: RoundingMode,
): (bool, u256) {
    assert!(denominator != 0, EDivideByZero);

    let numerator = u512::mul_u256(a, b);
    let (overflow, quotient, remainder) = u512::div_rem_u256(
        numerator,
        denominator,
    );
    if (overflow) {
        (true, 0)
    } else if (remainder == 0) {
        (false, quotient)
    } else {
        round_division_result(quotient, denominator, remainder, rounding_mode)
    }
}

/// Internal helper for `mul_shr` that selects the most efficient implementation based on the input size.
/// Returns `(overflow, quotient)` mirroring the macro implementation.
public(package) fun mul_shr_inner(
    a: u256,
    b: u256,
    shift: u8,
    rounding_mode: RoundingMode,
): (bool, u256) {
    let max_small = std::u128::max_value!() as u256;
    if (a > max_small || b > max_small) {
        mul_shr_u256_wide(a, b, shift, rounding_mode)
    } else {
        mul_shr_u256_fast(a, b, shift, rounding_mode)
    }
}

/// Multiplies two `u256` values whose product fits within 256 bits, shifts the result right by the specified amount,
/// and applies rounding according to the given mode. Optimized for cases where overflow is not possible.
///
/// #### Parameters
/// - `a`, `b`:  Unsigned factors whose product stays below 2^256.
/// - `shift`: Number of bits to shift right (0–255).
/// - `rounding_mode`: Rounding strategy drawn from `rounding::RoundingMode`.
///
/// #### Returns
/// `(overflow, result)` where `overflow` is `false` and `result` is the shifted and rounded value.
public(package) fun mul_shr_u256_fast(
    a: u256,
    b: u256,
    shift: u8,
    rounding_mode: RoundingMode,
): (bool, u256) {
    let numerator = a * b;

    if (shift == 0) {
        return (false, numerator)
    };

    let mut result = numerator >> shift;
    let denominator = 1u256 << shift;
    let mask = denominator - 1;
    let remainder = numerator & mask;

    if (remainder != 0) {
        // Overflow is not possible here because the numerator (a * b) is bounded by (2^128-1)^2 < u256::MAX.
        // Even after rounding up, the result fits in u256.
        (_, result) = round_division_result(result, denominator, remainder, rounding_mode);
    };

    (false, result)
}

/// Multiplies two `u256` values with full precision, shifts the result right by the specified amount,
/// and applies rounding according to the given mode. Handles the general case where the product may
/// exceed 256 bits.
///
/// #### Parameters
/// - `a`, `b`: Unsigned factors whose product may exceed 2^256.
/// - `shift`: Number of bits to shift right (0–255).
/// - `rounding_mode`: Rounding strategy drawn from `rounding::RoundingMode`.
///
/// #### Returns
/// `(overflow, result)` where `overflow` indicates whether the shifted value cannot fit in 256 bits
/// and `result` contains the shifted and rounded value when no overflow occurred.
public(package) fun mul_shr_u256_wide(
    a: u256,
    b: u256,
    shift: u8,
    rounding_mode: RoundingMode,
): (bool, u256) {
    let product = u512::mul_u256(a, b);
    let hi = product.hi();
    let lo = product.lo();

    if (shift == 0) {
        if (hi != 0) {
            return (true, 0)
        };
        return (false, lo)
    };

    let overflow = (hi >> shift) != 0;
    if (overflow) {
        return (true, 0)
    };

    let complement_shift = (256 - (shift as u16)) as u8;
    let lower = lo >> shift;
    let carry = hi << complement_shift;
    let mut result = lower | carry;

    let mask = (1 << shift) - 1;
    let remainder = lo & mask;
    if (remainder != 0) {
        let denominator = 1u256 << shift;
        let (overflow, rounded) = round_division_result(
            result,
            denominator,
            remainder,
            rounding_mode,
        );
        if (overflow) {
            return (true, 0)
        };
        result = rounded;
    };

    (false, result)
}

/// Compute the square root of an unsigned integer with configurable rounding.
///
/// This macro provides a uniform API for `sqrt` across all unsigned integer widths. It normalises
/// the input to `u256`, calculates the integer square root, and applies the requested rounding mode.
/// The algorithm uses a binary search to find the floor of the square root, then determines whether
/// to round up based on the rounding mode.
///
/// #### Generics
/// - `$Int`: Any unsigned integer type (`u8`, `u16`, `u32`, `u64`, `u128`, or `u256`).
///
/// #### Parameters
/// - `$value`: The unsigned integer to calculate the square root of.
/// - `$rounding_mode`: Rounding strategy drawn from `rounding::RoundingMode`.
///
/// #### Returns
/// The square root of `$value` rounded according to `$rounding_mode`, cast back to `$Int`.
public(package) macro fun sqrt<$Int>($value: $Int, $rounding_mode: RoundingMode): $Int {
    let (value, rounding_mode) = ($value as u256, $rounding_mode);
    let floor_res = common::sqrt_floor(value);
    round_sqrt_result(value, floor_res, rounding_mode) as $Int
}

/// Determine whether rounding up is required after dividing and apply it to `result`.
/// Returns `(overflow, result)` where `overflow` is `true` if the rounded value cannot be represented as `u256`.
public(package) fun round_division_result(
    result: u256,
    denominator: u256,
    remainder: u256,
    rounding_mode: RoundingMode,
): (bool, u256) {
    let should_round_up = if (rounding_mode == rounding::up()) {
        true
    } else if (rounding_mode == rounding::nearest()) {
        remainder >= denominator - remainder
    } else {
        false
    };

    if (!should_round_up) {
        (false, result)
    } else if (result == std::u256::max_value!()) {
        (true, 0)
    } else {
        (false, result + 1)
    }
}

/// Nearest-integer rounding for log2 without floats.
///
/// #### Parameters
/// - `value`: The value being tested (already cast to u256).
/// - `floor_log`: The floor of log2(value), i.e., log2(value)⌋.
///
/// Given `floor_log = ⌊log2(x)⌋`, we decide whether to round up to `floor_log + 1`
/// or keep `floor_log` by comparing `x` to the midpoint of the interval
/// `[2^floor_log, 2^(floor_log+1))`. That midpoint is `2^(floor_log + 1/2) = 2^floor_log · √2`.
/// Uses fast path when the compared values fit in u256, otherwise u512 arithmetic.
///
/// To avoid √2 and floating point, we square both sides:
///   - `x ≥ 2^floor_log · √2`
///   - `x² ≥ 2^(2·floor_log + 1)`
///
/// We implement this with an integer threshold test:
/// `threshold_exp = 2 * floor_log + 1`, then:
///   - if `x² ≥ 2^threshold_exp` → round up (`floor_log + 1`)
///   - else                      → round down (`floor_log`)
///
/// Tie-break: equality goes up (`≥`), i.e., “round half up”.
///
/// #### Returns
/// `true` if the value should round up, `false` otherwise.
public(package) fun round_log2_to_nearest(value: u256, floor_log: u16): u16 {
    let threshold_exp = 2 * floor_log + 1;
    let max_small = std::u128::max_value!() as u256;
    let fast_path = threshold_exp < 256 && value <= max_small;
    let should_round_up = if (fast_path) {
        // Fast path: both value² and exponent fit in u256
        let value_squared = value * value;
        let threshold = 1 << (threshold_exp as u8);
        value_squared >= threshold
    } else {
        // Slow path: use u512 for values where value² > u256::MAX or exponent >= 2^256
        let value_squared = u512::mul_u256(value, value);
        let threshold = if (threshold_exp >= 256) {
            let shift = (threshold_exp - 256) as u8;
            u512::new(1 << shift, 0)
        } else {
            u512::from_u256(1 << (threshold_exp as u8))
        };
        value_squared.ge(&threshold)
    };
    if (should_round_up) { floor_log + 1 } else { floor_log }
}

/// Nearest-integer rounding for log256 without floats.
///
/// #### Parameters
/// - `value`: The value being tested (already cast to u256).
/// - `floor_log`: The floor of log256(value), i.e., ⌊log256(value)⌋.
///
/// Given `floor_log = ⌊log256(x)⌋`, we decide whether to round up to `floor_log + 1`
/// or keep `floor_log` by comparing `x` to the midpoint of the interval
/// `[256^floor_log, 256^(floor_log+1))`. Using `256 = 2^8`, this midpoint is
/// `256^(floor_log + 1/2) = 2^(8·floor_log + 4)`.
///
/// We implement this with a direct integer threshold test:
/// `threshold_exp = 8 * floor_log + 4`, then:
///   - if `x ≥ 2^threshold_exp` → round up (`floor_log + 1`)
///   - else                     → round down (`floor_log`)
///
/// Tie-break: equality goes up (`≥`), i.e., “round half up”.
///
/// #### Returns
/// `true` if the value should round up, `false` otherwise.
public(package) fun round_log256_to_nearest(value: u256, floor_log: u8): u8 {
    // For u256 values, floor_log ∈ [0, 31], so `threshold_exp = 8 * floor_log + 4 ≤ 252`
    // and the power-of-two threshold fits safely in u256.
    let threshold_exp = 8 * floor_log + 4;
    let threshold = 1 << threshold_exp;
    if (value >= threshold) { floor_log + 1 } else { floor_log }
}

/// Apply nearest-integer rounding to log10 without floats.
///
/// #### Parameters
/// - `value`: The value being tested (already cast to u256).
/// - `floor_log`: The floor of log10(value), i.e., ⌊log10(value)⌋.
///
/// Given `floor_log = ⌊log10(x)⌋`, we decide whether to round up to `floor_log + 1`
/// or keep `floor_log` by comparing `x` to the midpoint of the interval
/// `[10^floor_log, 10^(floor_log+1))`. This midpoint is `10^(floor_log + 0.5) = √(10) · 10^floor_log`.
///
/// To avoid computing square roots, we square both sides of the comparison:
/// - Round up if: `x ≥ 10^(floor_log + 0.5)`
/// - Equivalent to: `x² ≥ 10^(2·floor_log + 1)`
///
/// This transforms the problem into an integer comparison that preserves the rounding decision.
///
/// The implementation uses two paths:
/// - **Fast path** (u256 arithmetic): When both `value²` and `10^(2·floor_log + 1)` fit in u256.
///   This occurs when `floor_log ≤ 38` (ensuring `10^77` fits) and `value ≤ 2^128 - 1`
///   (ensuring `value²` fits).
/// - **Slow path** (u512 arithmetic): For larger values where intermediate computations would
///   overflow u256, we use 512-bit arithmetic.
///
/// Tie-break: equality goes up (`≥`), i.e., "round half up".
///
/// #### Returns
/// The rounded log10 value: either `floor_log` or `floor_log + 1`.
public(package) fun round_log10_to_nearest(value: u256, floor_log: u8): u8 {
    // Boundary check: log10(u256::MAX) ≈ 77.06, so floor_log ≤ 77.
    // If floor_log ≥ 77, it's already at the maximum possible log10 value with nearest rounding.
    if (floor_log >= MAX_LOG_10) {
        return floor_log
    };
    // Nearest-integer rounding for log10: check if value² ≥ 10^(2*floor_log + 1)
    // Given floor_log = ⌊log10(x)⌋, we compare x to the midpoint 10^(floor_log + 0.5).
    // To avoid √10, we square both sides: x² ≥ 10^(2*floor_log + 1)

    // Fast path condition:
    // - floor_log ≤ 38 ensures threshold_exp = 2*38 + 1 = 77, and 10^77 is the largest
    //   power of 10 that fits in u256 (10^77 < 2^256 < 10^78).
    // - value ≤ u128::MAX ensures value² fits in u256, since (2^128 - 1)² < 2^256.
    let is_fast_path = floor_log <= 38 && value <= std::u128::max_value!() as u256;
    let should_round_up = if (is_fast_path) {
        // Fast path: compute entirely in u256 space
        let value_squared = value * value;
        let threshold_exp = 2 * floor_log + 1;
        let threshold = std::u256::pow(10, threshold_exp);
        value_squared >= threshold
    } else {
        // Slow path: use u512 arithmetic for large values
        let value_squared = u512::mul_u256(value, value);
        // Compute 10^(2*floor_log + 1) = 10 · 10^floor_log · 10^floor_log
        // Factor as (10 · 10^floor_log) · 10^floor_log to minimize u256 operations
        let floor_log_pow10 = std::u256::pow(10, floor_log);
        let threshold = u512::mul_u256(10 * floor_log_pow10, floor_log_pow10);
        value_squared.ge(&threshold)
    };
    if (should_round_up) {
        floor_log + 1
    } else {
        floor_log
    }
}

/// Apply rounding mode to the floor result of a square root calculation.
///
/// For nearest rounding, compares the distance from `value` to `floor²` versus the distance
/// to `ceil²` where `ceil = floor + 1`.
///
/// Given:
/// - `distance_to_floor = value - floor²`
/// - `distance_to_ceil = (floor + 1)² - value = floor² + 2·floor + 1 - value`
///
/// We want to round down if `distance_to_floor < distance_to_ceil`, which expands to:
/// ```
/// value - floor² < floor² + 2·floor + 1 - value
/// 2·value < 2·floor² + 2·floor + 1
/// 2·(value - floor²) < 2·floor + 1
/// ```
///
/// Since we're working with integers, dividing both sides by 2 gives us:
/// `value - floor² <= floor`
///
/// Considering that `sqrt(u256::MAX)` < `2^128`, all arithmetic operations in the function
/// are guaranteed to not overflow or underflow.
///
/// #### Parameters
/// - `value`: The original value whose square root was calculated.
/// - `floor_result`: The floor of the square root.
/// - `rounding_mode`: Rounding strategy drawn from `rounding::RoundingMode`.
///
/// #### Returns
/// The square root rounded according to the specified mode.
public(package) fun round_sqrt_result(
    value: u256,
    floor_result: u256,
    rounding_mode: RoundingMode,
): u256 {
    if (rounding_mode == rounding::down()) {
        return floor_result
    };

    let floor_squared = floor_result * floor_result;
    if (floor_squared == value) {
        // Perfect square, no rounding needed
        floor_result
    } else if (rounding_mode == rounding::up()) {
        floor_result + 1
    } else if (value - floor_squared <= floor_result) {
        floor_result
    } else {
        floor_result + 1
    }
}

/// === Internal helpers for modular arithmetic ===

/// Extended Euclidean algorithm that powers `inv_mod!`.
///
/// Keeps track of Bézout coefficients `x` and `y` such that
/// `value * x + modulus * y = gcd(value, modulus)`. When the gcd is 1, `x` is the inverse
/// modulo `modulus`.
///
/// #### Parameters
/// - `value`: Operand whose inverse is desired.
/// - `modulus`: Modulus, must be non-zero.
///
/// #### Returns
/// `option::some(inverse)` when `value` and `modulus` are co-prime, otherwise `option::none()`.
public(package) fun inv_mod_extended_impl(value: u256, modulus: u256): Option<u256> {
    // Guard against invalid modulus values up front.
    assert!(modulus != 0, EZeroModulus);
    if (modulus == 1) {
        return option::none()
    };

    // Normalise the value into the modulus range; zero implies no inverse exists.
    let reduced = value % modulus;
    if (reduced == 0) {
        return option::none()
    };

    // Initialise Bézout state:
    //   r/new_r carry the running gcd through repeated remainder steps.
    //   t/new_t track the coefficient for `value`.
    let mut r = modulus;
    let mut new_r = reduced;
    let mut t: u256 = 0;
    let mut new_t: u256 = 1;

    while (new_r != 0) {
        let quotient = r / new_r;

        // Update the coefficient for `value`, keeping it within `[0, modulus)`.
        let tmp_t = new_t;
        let product = mul_mod_impl(quotient, new_t, modulus);
        new_t = mod_sub_impl(t, product, modulus);
        t = tmp_t;

        // Standard Euclidean step: shift (r, new_r) to (new_r, remainder).
        let tmp_r = new_r;
        new_r = r - quotient * new_r;
        r = tmp_r;
    };

    // If gcd != 1 there is no inverse; otherwise `t` is the modular inverse.
    if (r != 1) option::none() else option::some(t)
}

/// Compute `(a - b) mod modulus` without signed arithmetic.
public(package) fun mod_sub_impl(a: u256, b: u256, modulus: u256): u256 {
    if (a >= b) {
        a - b
    } else {
        modulus - (b - a)
    }
}

/// Compute `(a * b) mod modulus` with a 128-bit fast path.
///
/// Falls back to the wide (`u512`) helper when the operands exceed 128 bits so overflow cannot
/// occur.
public(package) fun mul_mod_impl(a: u256, b: u256, modulus: u256): u256 {
    assert!(modulus != 0, EZeroModulus);
    if (a == 0 || b == 0) {
        return 0
    };

    let max_small = std::u128::max_value!() as u256;
    if (a > max_small || b > max_small) {
        let product = u512::mul_u256(a, b);
        let (_, _, remainder) = u512::div_rem_u256(product, modulus);
        remainder
    } else {
        ((a * b) % modulus)
    }
}

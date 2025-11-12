module openzeppelin_math::macros;

use openzeppelin_math::rounding::{Self, RoundingMode};
use openzeppelin_math::u512;

#[error(code = 0)]
const EDivideByZero: vector<u8> = b"Divisor must be non-zero";

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
    let value = $value;
    let bit_width = $bit_width;
    if (value == 0 as $Int) {
        return bit_width
    };

    // Binary search optimized for any bit width
    let mut res = 0;
    let mut val = (value as u256);
    let mut shift = (bit_width / 2) as u8;
    while (shift > 0) {
        let shifted = val >> shift;
        if (shifted == 0) {
            res = res + (shift as u16);
        } else {
            val = shifted;
        };
        shift = shift / 2;
    };

    res
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
    let (value, bit_width, rounding_mode) = ($value, $bit_width, $rounding_mode);
    if (value == 0 as $Int) {
        return 0
    };
    let zeros = clz!(value, bit_width);
    let floor_log = bit_width - 1 - zeros;
    if (rounding_mode == rounding::down()) {
        return floor_log
    };
    let power_of_two = (1 as $Int) << (floor_log as u8);
    if (value == power_of_two) {
        return floor_log
    };
    if (rounding_mode == rounding::up()) {
        return floor_log + 1
    };
    // Nearest: decide whether to round up or down based on midpoint (2^n × √2)
    let threshold_exp = 2 * floor_log + 1;
    if (log_should_round_up(value as u256, threshold_exp)) {
        floor_log + 1
    } else {
        floor_log
    }
}

/// Compute the log in base 256 of a positive value with configurable rounding.
///
/// Since log₂₅₆(x) = log₂(x) / 8, the algorithm computes log₂(x) first, then divides by 8.
/// For nearest rounding, uses the same exact algebraic test as log2.
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
/// The base-256 logarithm as a `u16`, rounded according to the specified mode.
/// Returns `0` if `$value` is 0.
public(package) macro fun log256<$Int>(
    $value: $Int,
    $bit_width: u16,
    $rounding_mode: RoundingMode,
): u8 {
    let (value, bit_width, rounding_mode) = ($value, $bit_width, $rounding_mode);
    if (value == 0 as $Int) {
        return 0
    };
    let zeros = clz!(value, bit_width);
    let floor_log2 = bit_width - 1 - zeros;
    let floor_log256 = (floor_log2 / 8) as u8;

    if (rounding_mode == rounding::down()) {
        return floor_log256
    };

    // Check if value is exactly a power of 256 (i.e., log2 is multiple of 8)
    if (floor_log2 % 8 == 0) {
        let power_of_256 = (1 as $Int) << (floor_log2 as u8);
        if (value == power_of_256) {
            return floor_log256
        };
    };

    if (rounding_mode == rounding::up()) {
        return floor_log256 + 1
    };

    // Nearest: check if value >= 256^k × √256, where √256 = 16 = 2^4
    // Using algebraic test: value² >= 2^(16k+8)
    let threshold_exp = 16 * (floor_log256 as u16) + 8;
    if (log_should_round_up(value as u256, threshold_exp)) {
        floor_log256 + 1
    } else {
        floor_log256
    }
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

/// Determine if a value should round up based on an algebraic threshold test.
///
/// Tests whether `value² >= 2^threshold_exp` to decide rounding without approximation.
/// Uses fast path when both operands fit in u256, otherwise u512 arithmetic.
///
/// #### Parameters
/// - `value`: The value being tested (already cast to u256).
/// - `threshold_exp`: The threshold exponent for comparison.
///
/// #### Returns
/// `true` if the value should round up, `false` otherwise.
public(package) fun log_should_round_up(value: u256, threshold_exp: u16): bool {
    let max_small = std::u128::max_value!() as u256;
    let fast_path = threshold_exp < 256 && value <= max_small;

    if (fast_path) {
        // Fast path: both value² and threshold fit in u256
        let value_squared = value * value;
        let threshold = 1 << (threshold_exp as u8);
        value_squared >= threshold
    } else {
        // Slow path: use u512 for values where value² > u256::MAX or threshold >= 2^256
        let value_squared = u512::mul_u256(value, value);
        let threshold = if (threshold_exp >= 256) {
            let shift = (threshold_exp - 256) as u8;
            u512::new(1u256 << shift, 0)
        } else {
            u512::from_u256(1 << (threshold_exp as u8))
        };
        value_squared.ge(&threshold)
    }
}

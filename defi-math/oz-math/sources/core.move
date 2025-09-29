module oz_math::core;

use oz_math::u512;

/// Base offset applied to all errors emitted by this module.
const ERROR_OFFSET: u64 = 1_000;
/// Error code returned when the denominator passed to `mul_div` is zero.
const EDivideByZero: u64 = ERROR_OFFSET + 0;
/// Error code returned when the result does not fit in the requested integer type.
const EArithmeticOverflow: u64 = ERROR_OFFSET + 1;

/// Enumerates the supported rounding strategies for `mul_div`.
/// - Down: Always round the truncated result down towards zero.
/// - Up: Always round the truncated result up (ceiling).
/// - Nearest: Round to the closest integer, breaking ties by rounding up.
public enum RoundingMode has copy, drop {
    Down,
    Up,
    Nearest,
}

/// Helper returning the enum value for downward rounding.
public fun rounding_down(): RoundingMode { RoundingMode::Down }

/// Helper returning the enum value for upward rounding.
public fun rounding_up(): RoundingMode { RoundingMode::Up }

/// Helper returning the enum value for nearest rounding (ties round up).
public fun rounding_nearest(): RoundingMode { RoundingMode::Nearest }

/// Fast-path for `mul_div` when both operands fit in `u128`, avoiding the wide 512-bit helpers.
fun mul_div_u256_small(
    a: u256,
    b: u256,
    denominator: u256,
    rounding_mode: RoundingMode,
): u256 {
    assert!(denominator != 0, EDivideByZero);

    let numerator = a * b;
    let mut quotient = numerator / denominator;
    let remainder = numerator % denominator;

    if (remainder != 0) {
        let should_round_up = if (rounding_mode == RoundingMode::Up) {
            true
        } else if (rounding_mode == RoundingMode::Nearest) {
            remainder >= denominator - remainder
        } else {
            false
        };

        if (should_round_up) {
            quotient = quotient + 1;
        }
    };

    quotient
}

/// Shared implementation for `mul_div_u256` that leverages the 512-bit helper utilities to perform
/// the multiplication and division without losing precision.
fun mul_div_u256_internal(
    a: u256,
    b: u256,
    denominator: u256,
    rounding_mode: RoundingMode,
): u256 {
    assert!(denominator != 0, EDivideByZero);

    let numerator = u512::mul_u256(a, b);
    let (overflow, mut quotient, remainder) = u512::div_rem_u256(numerator, denominator);
    assert!(!overflow, EArithmeticOverflow);

    if (remainder != 0) {
        let should_round_up = if (rounding_mode == RoundingMode::Up) {
            true
        } else if (rounding_mode == RoundingMode::Nearest) {
            remainder >= denominator - remainder
        } else {
            false
        };

        if (should_round_up) {
            assert!(quotient < std::u256::max_value!(), EArithmeticOverflow);
            quotient = quotient + 1;
        }
    };

    quotient
}

/// Multiply `a` and `b`, divide by `denominator`, and round according to `rounding_mode`.
///
/// The macro evaluates everything in `u256`, returning the rounded result as a `u256`.  Narrower
/// wrappers convert the value back to their respective integer widths after checking that the
/// result fits. The operation aborts if the division is undefined.
///
/// The macro accepts any unsigned integer type (`u8` through `u256`). Choose the input type with
/// the macro's type argument, e.g. `mul_div!<u64>(x, y, denominator, rounding_down())`. For raw
/// `u256` operands prefer the `mul_div_u256` helper, which applies additional safeguards.
public macro fun mul_div<$Int>(
    $a: $Int,
    $b: $Int,
    $denominator: $Int,
    $rounding_mode: RoundingMode,
): u256 {
    let a_u256 = ($a as u256);
    let b_u256 = ($b as u256);
    let denominator_u256 = ($denominator as u256);
    let rounding_mode = $rounding_mode;

    let max_small = std::u128::max_value!() as u256;
    if (a_u256 > max_small || b_u256 > max_small) {
        mul_div_u256_internal(a_u256, b_u256, denominator_u256, rounding_mode)
    } else {
        mul_div_u256_small(a_u256, b_u256, denominator_u256, rounding_mode)
    }
}

/// Convenience wrappers that forward to `mul_div!` with explicit integer types. These functions
/// allow value-based type inference at the call site while still leveraging the macro's shared
/// implementation.

public fun mul_div_u8(a: u8, b: u8, denominator: u8, rounding_mode: RoundingMode): u8 {
    let result = mul_div!<u8>(a, b, denominator, rounding_mode);
    let max = std::u8::max_value!() as u256;
    assert!(result <= max, EArithmeticOverflow);
    (result as u8)
}

public fun mul_div_u16(a: u16, b: u16, denominator: u16, rounding_mode: RoundingMode): u16 {
    let result = mul_div!<u16>(a, b, denominator, rounding_mode);
    let max = std::u16::max_value!() as u256;
    assert!(result <= max, EArithmeticOverflow);
    (result as u16)
}

public fun mul_div_u32(a: u32, b: u32, denominator: u32, rounding_mode: RoundingMode): u32 {
    let result = mul_div!<u32>(a, b, denominator, rounding_mode);
    let max = std::u32::max_value!() as u256;
    assert!(result <= max, EArithmeticOverflow);
    (result as u32)
}

public fun mul_div_u64(a: u64, b: u64, denominator: u64, rounding_mode: RoundingMode): u64 {
    let result = mul_div!<u64>(a, b, denominator, rounding_mode);
    let max = std::u64::max_value!() as u256;
    assert!(result <= max, EArithmeticOverflow);
    (result as u64)
}

public fun mul_div_u128(a: u128, b: u128, denominator: u128, rounding_mode: RoundingMode): u128 {
    let result = mul_div!<u128>(a, b, denominator, rounding_mode);
    let max = std::u128::max_value!() as u256;
    assert!(result <= max, EArithmeticOverflow);
    (result as u128)
}

public fun mul_div_u256(a: u256, b: u256, denominator: u256, rounding_mode: RoundingMode): u256 {
    mul_div_u256_internal(a, b, denominator, rounding_mode)
}

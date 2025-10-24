module openzeppelin_math::macros;

use openzeppelin_math::rounding::{Self, RoundingMode};
use openzeppelin_math::u512;

#[error(code = 0)]
const EDivideByZero: vector<u8> = b"Divisor must be non-zero";
#[error(code = 1)]
const EArithmeticOverflow: vector<u8> = b"Result does not fit in the u256 type";

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
): u256 {
    assert!(denominator != 0, EDivideByZero);

    let numerator = a * b;
    let mut quotient = numerator / denominator;
    let remainder = numerator % denominator;

    if (remainder != 0) {
        let should_round_up = if (rounding_mode == rounding::up()) {
            true
        } else if (rounding_mode == rounding::nearest()) {
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

/// Multiply two `u256` values with full 512-bit precision before dividing and rounding.
///
/// This variant handles the general case where `a * b` may exceed 2^256. It widens the product to
/// a 512-bit value, performs an exact division, and then applies rounding. If the true quotient does
/// not fit back into 256 bits an overflow is reported via `EArithmeticOverflow`.
///
/// #### Parameters
/// - `a`, `b`: Unsigned factors up to 2^256 - 1.
/// - `denominator`: Unsigned divisor, must be non-zero.
/// - `rounding_mode`: Rounding strategy drawn from `rounding::RoundingMode`.
///
/// #### Returns
/// The rounded quotient as a `u256`.
///
/// #### Aborts
/// - `EDivideByZero` if `denominator` is zero.
/// - `EArithmeticOverflow` if the quotient cannot be represented in 256 bits after rounding.
public(package) fun mul_div_u256_wide(
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
        let should_round_up = if (rounding_mode == rounding::up()) {
            true
        } else if (rounding_mode == rounding::nearest()) {
            remainder >= denominator - remainder
        } else {
            false
        };

        if (should_round_up) {
            // This will overflow only if the quotient is already at the maximum value.
            // This case is extremely unlikely and it would be handled by the move overflow check automatically.
            quotient = quotient + 1;
        }
    };

    quotient
}

/// Multiply `a` and `b`, divide by `denominator`, and round according to `rounding_mode`.
///
/// This macro provides a uniform API for `mul_div` across all unsigned integer widths. It normalises
/// the inputs to `u256`, chooses the most efficient helper, and returns the rounded quotient as a
/// `u256`. Narrower wrapper modules downcast the result after ensuring it fits. Undefined divisions
/// (e.g. denominator = 0) abort with descriptive error codes.
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
/// Rounded quotient as a `u256`.
///
/// #### Aborts
/// Propagates the same error codes as the underlying helpers (`EDivideByZero`, `EArithmeticOverflow`).
public(package) macro fun mul_div<$Int>(
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
        mul_div_u256_wide(a_u256, b_u256, denominator_u256, rounding_mode)
    } else {
        mul_div_u256_fast(a_u256, b_u256, denominator_u256, rounding_mode)
    }
}

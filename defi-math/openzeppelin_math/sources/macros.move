module openzeppelin_math::macros;

use openzeppelin_math::rounding::{Self, RoundingMode};
use openzeppelin_math::u512;

#[error(code = 0)]
const EDivideByZero: vector<u8> = b"Divisor must be non-zero";
#[error(code = 1)]
const EArithmeticOverflow: vector<u8> = b"Result does not fit in the u256 type";

/// Fast-path for `mul_div` when both operands fit in `u128`, avoiding the wide 512-bit helpers.
public(package) fun mul_div_u256_no_overflow(
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

/// Shared implementation for `mul_div_u256` that leverages the 512-bit helper utilities to perform
/// the multiplication and division without losing precision.
public(package) fun mul_div_u256_with_overflow(
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
        mul_div_u256_with_overflow(a_u256, b_u256, denominator_u256, rounding_mode)
    } else {
        mul_div_u256_no_overflow(a_u256, b_u256, denominator_u256, rounding_mode)
    }
}

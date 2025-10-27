module openzeppelin_math::u256_tests;

use openzeppelin_math::macros;
use openzeppelin_math::rounding;
use openzeppelin_math::u256;
use std::unit_test::assert_eq;

// === mul_div ===

// At the top level, the wrapper should mirror the macro’s behaviour.
#[test]
fun mul_div_rounding_modes() {
    let (down_overflow, down) = u256::mul_div(70, 10, 4, rounding::down());
    assert_eq!(down_overflow, false);
    assert_eq!(down, 175);

    let (up_overflow, up) = u256::mul_div(5, 3, 4, rounding::up());
    assert_eq!(up_overflow, false);
    assert_eq!(up, 4);

    let (nearest_overflow, nearest) = u256::mul_div(7, 10, 4, rounding::nearest());
    assert_eq!(nearest_overflow, false);
    assert_eq!(nearest, 18);
}

// Verify the wrapper delegates to the wide path when required.
#[test]
fun mul_div_handles_wide_operands() {
    let large = (std::u128::max_value!() as u256) + 1;
    let (overflow, result) = u256::mul_div(large, large, 7, rounding::down());
    assert_eq!(overflow, false);
    let (wide_overflow, expected) = macros::mul_div_u256_wide(large, large, 7, rounding::down());
    assert_eq!(wide_overflow, false);
    assert_eq!(result, expected);
}

// Division-by-zero guard enforced at the macro layer.
#[test, expected_failure(abort_code = macros::EDivideByZero)]
fun mul_div_rejects_zero_denominator() {
    u256::mul_div(1, 1, 0, rounding::down());
}

// Even u256 should flag when the macro’s output overflows 256 bits.
#[test]
fun mul_div_detects_overflow() {
    let max = std::u256::max_value!();
    let (overflow, result) = u256::mul_div(max, max, 1, rounding::down());
    assert_eq!(overflow, true);
    assert_eq!(result, 0);
}

// === checked_shr ===

#[test]
fun checked_shr_returns_some() {
    // Shift a high limb filled with zeros: 1 << 200 >> 200 == 1.
    let value = 1u256 << 200;
    let result = u256::checked_shr(value, 200);
    assert_eq!(result, option::some(1));
}

#[test]
fun checked_shr_handles_top_bit() {
    // The very top bit (1 << 255) can move to the least-significant position.
    let value = 1u256 << 255;
    let result = u256::checked_shr(value, 255);
    assert_eq!(result, option::some(1));
}

#[test]
fun checked_shr_detects_set_bits() {
    // LSB set — shifting by one would drop it.
    let result = u256::checked_shr(5, 1);
    assert_eq!(result, option::none());
}

#[test]
fun checked_shr_detects_large_shift_loss() {
    // Shifting by width-1 is valid if the value has enough trailing zeros
    let value = 1u256 << 255;
    let result = u256::checked_shr(value, 255);
    assert_eq!(result, option::some(1));
}

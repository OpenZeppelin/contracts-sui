module openzeppelin_math::u256_tests;

use openzeppelin_math::macros;
use openzeppelin_math::rounding;
use openzeppelin_math::u256;
use std::unit_test::assert_eq;

// === average ===

#[test]
fun average_rounding_modes() {
    let down = u256::average(4, 7, rounding::down());
    assert_eq!(down, 5);

    let up = u256::average(4, 7, rounding::up());
    assert_eq!(up, 6);

    let nearest = u256::average(1, 2, rounding::nearest());
    assert_eq!(nearest, 2);
}

#[test]
fun average_is_commutative() {
    let left = u256::average(std::u256::max_value!(), 0, rounding::nearest());
    let right = u256::average(0, std::u256::max_value!(), rounding::nearest());
    assert_eq!(left, right);
}

// === checked_shl ===

#[test]
fun checked_shl_returns_some() {
    // Shift to the top bit while staying within range.
    let value = 1u256;
    let result = u256::checked_shl(value, 255);
    assert_eq!(result, option::some(1u256 << 255));
}

#[test]
fun checked_shl_zero_input_returns_zero() {
    assert_eq!(u256::checked_shl(0, 120), option::some(0));
}

#[test]
fun checked_shl_returns_same_for_zero_shift() {
    // Shifting by zero should return the same value.
    let value = 1u256 << 255;
    let result = u256::checked_shl(value, 0);
    assert_eq!(result, option::some(value));
}

#[test]
fun checked_shl_detects_high_bits() {
    // Highest bit already set — shifting again should fail.
    let result = u256::checked_shl(1u256 << 255, 1);
    assert_eq!(result, option::none());
}

#[test]
fun checked_shl_rejects_large_shift() {
    // Disallow shifting when the value would overflow after a large shift.
    let result = u256::checked_shl(2, 255);
    assert_eq!(result, option::none());
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
fun checked_shr_zero_input_returns_zero() {
    assert_eq!(u256::checked_shr(0, 120), option::some(0));
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
    // Reject when shifting by 255 would drop non-zero bits.
    let value = 3u256 << 254;
    let result = u256::checked_shr(value, 255);
    assert_eq!(result, option::none());
}

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

    let (nearest_overflow, nearest) = u256::mul_div(
        7,
        10,
        4,
        rounding::nearest(),
    );
    assert_eq!(nearest_overflow, false);
    assert_eq!(nearest, 18);
}

// Verify the wrapper delegates to the wide path when required.
#[test]
fun mul_div_handles_wide_operands() {
    let large = (std::u128::max_value!() as u256) + 1;
    let (overflow, result) = u256::mul_div(
        large,
        large,
        7,
        rounding::down(),
    );
    assert_eq!(overflow, false);
    let (wide_overflow, expected) = macros::mul_div_u256_wide(
        large,
        large,
        7,
        rounding::down(),
    );
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
    let (overflow, result) = u256::mul_div(
        max,
        max,
        1,
        rounding::down(),
    );
    assert_eq!(overflow, true);
    assert_eq!(result, 0);
}

// === mul_shr ===

#[test]
fun mul_shr_returns_some_when_in_range() {
    let result = u256::mul_shr(6, 4, 1, rounding::down());
    assert_eq!(result, option::some(12));
}

#[test]
fun mul_shr_respects_rounding_modes() {
    // 5*3 = 15; 15 >> 1 = 7.5
    let down = u256::mul_shr(5, 3, 1, rounding::down());
    assert_eq!(down, option::some(7));

    let up = u256::mul_shr(5, 3, 1, rounding::up());
    assert_eq!(up, option::some(8));

    let nearest = u256::mul_shr(5, 3, 1, rounding::nearest());
    assert_eq!(nearest, option::some(8));

    // 7*4 = 28; 28 >> 2 = 7.0
    let exact = u256::mul_shr(7, 4, 2, rounding::nearest());
    assert_eq!(exact, option::some(7));

    // 13*3 = 39; 39 >> 2 = 9.75
    let down2 = u256::mul_shr(13, 3, 2, rounding::down());
    assert_eq!(down2, option::some(9));

    let up2 = u256::mul_shr(13, 3, 2, rounding::up());
    assert_eq!(up2, option::some(10));

    let nearest2 = u256::mul_shr(13, 3, 2, rounding::nearest());
    assert_eq!(nearest2, option::some(10));

    // 7*3 = 21; 21 >> 2 = 5.25
    let down3 = u256::mul_shr(7, 3, 2, rounding::down());
    assert_eq!(down3, option::some(5));

    let up3 = u256::mul_shr(7, 3, 2, rounding::up());
    assert_eq!(up3, option::some(6));

    let nearest3 = u256::mul_shr(7, 3, 2, rounding::nearest());
    assert_eq!(nearest3, option::some(5));
}

#[test]
fun mul_shr_handles_large_operands() {
    let large = std::u256::max_value!();
    let result = u256::mul_shr(large, 16, 4, rounding::down());
    assert_eq!(result, option::some(large));
}

#[test]
fun mul_shr_detects_overflow() {
    let overflow = u256::mul_shr(
        std::u256::max_value!(),
        std::u256::max_value!(),
        0,
        rounding::down(),
    );
    assert_eq!(overflow, option::none());
}

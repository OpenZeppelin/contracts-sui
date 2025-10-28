module openzeppelin_math::u64_tests;

use openzeppelin_math::macros;
use openzeppelin_math::rounding;
use openzeppelin_math::u64;
use std::unit_test::assert_eq;

// === mul_div ===

// Larger inputs continue to follow the same rounding contract.
#[test]
fun mul_div_rounding_modes() {
    let (down_overflow, down) = u64::mul_div(70, 10, 4, rounding::down());
    assert_eq!(down_overflow, false);
    assert_eq!(down, 175);

    let (up_overflow, up) = u64::mul_div(5, 3, 4, rounding::up());
    assert_eq!(up_overflow, false);
    assert_eq!(up, 4);

    let (nearest_overflow, nearest) = u64::mul_div(7, 10, 4, rounding::nearest());
    assert_eq!(nearest_overflow, false);
    assert_eq!(nearest, 18);
}

// Perfect division should remain unaffected by rounding mode choice.
#[test]
fun mul_div_exact_division() {
    let (overflow, exact) = u64::mul_div(8_000, 2, 4, rounding::up());
    assert_eq!(overflow, false);
    assert_eq!(exact, 4_000);
}

// Guard against missing macro errors during integration.
#[test, expected_failure(abort_code = macros::EDivideByZero)]
fun mul_div_rejects_zero_denominator() {
    u64::mul_div(1, 1, 0, rounding::down());
}

// Downstream overflow is still surfaced via the overflow flag.
#[test]
fun mul_div_detects_overflow() {
    let (overflow, result) = u64::mul_div(std::u64::max_value!(), 2, 1, rounding::down());
    assert_eq!(overflow, true);
    assert_eq!(result, 0);
}

// === checked_shr ===

#[test]
fun checked_shr_returns_some() {
    // 1 << 32 leaves a clean trailing zero region to drop.
    let value = 1u64 << 32;
    let result = u64::checked_shr(value, 32);
    assert_eq!(result, option::some(1));
}

#[test]
fun checked_shr_detects_set_bits() {
    // LSB is set, shifting by one would remove it.
    let result = u64::checked_shr(5, 1);
    assert_eq!(result, option::none());
}

#[test]
fun checked_shr_rejects_large_shift() {
    // Disallow shifting by the full width to avoid runtime aborts.
    let result = u64::checked_shr(1, 64);
    assert_eq!(result, option::none());
}

// === checked_shl ===

#[test]
fun checked_shl_returns_some() {
    // Shift into the highest bit safely.
    let result = u64::checked_shl(1, 63);
    assert_eq!(result, option::some(1 << 63));
}

#[test]
fun checked_shl_returns_same_for_zero_shift() {
    // Shifting by zero should return the same value.
    let value = 1 << 63;
    let result = u64::checked_shl(value, 0);
    assert_eq!(result, option::some(value));
}

#[test]
fun checked_shl_detects_high_bits() {
    // Top bit already set — shifting would overflow.
    let result = u64::checked_shl(1 << 63, 1);
    assert_eq!(result, option::none());
}

#[test]
fun checked_shl_rejects_large_shift() {
    // Guard against the width-sized shift.
    let result = u64::checked_shl(1, 64);
    assert_eq!(result, option::none());
}

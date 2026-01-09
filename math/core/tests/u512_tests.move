#[test_only]
module openzeppelin_math::u512_tests;

use openzeppelin_math::u512::{Self, U512};
use std::unit_test::assert_eq;

#[test]
fun constructors_and_accessors() {
    // `new` should store exactly the values we pass in.
    let value = u512::new(5, 7);
    assert_eq!(u512::hi(&value), 5);
    assert_eq!(u512::lo(&value), 7);

    // `zero` returns the additive identity.
    let zero = u512::zero();
    assert_eq!(u512::hi(&zero), 0);
    assert_eq!(u512::lo(&zero), 0);

    // `from_u256` lifts into the low limb and clears the high one.
    let lifted = u512::from_u256(42);
    assert_eq!(u512::hi(&lifted), 0);
    assert_eq!(u512::lo(&lifted), 42);
}

#[test]
fun sub_u256_without_borrow_keeps_high_limb() {
    let original = u512::new(3, 50);
    let subtrahend = 7u256;

    let result = u512::sub_u256_for_testing(original, subtrahend);
    assert_eq!(u512::hi(&result), 3);
    assert_eq!(u512::lo(&result), 43);

    let rebuild = add_u512(result, u512::from_u256(subtrahend));
    assert_u512_eq(rebuild, original);
}

#[test]
fun sub_u256_with_borrow_reduces_high_limb() {
    let original = u512::new(9, 4);
    let original_hi = u512::hi(&original);
    let original_lo = u512::lo(&original);
    let subtrahend = 10u256;

    let result = u512::sub_u256_for_testing(original, subtrahend);
    assert_eq!(u512::hi(&result), original_hi - 1);
    let complement = (std::u256::max_value!() - subtrahend) + 1;
    let expected = u512::new(original_hi - 1, original_lo + complement);
    assert_u512_eq(result, expected);
}

#[test, expected_failure(abort_code = u512::EUnderflow)]
fun sub_u256_rejects_borrow_without_high_limb() {
    let original = u512::new(0, 1);
    let _unused = u512::sub_u256_for_testing(original, 2u256);
}

#[test]
fun mul_u256_handles_small_operands() {
    // Simple multiplication stays entirely in the low limb.
    let result = u512::mul_u256(2, 3);
    assert_eq!(u512::hi(&result), 0);
    assert_eq!(u512::lo(&result), 6);
}

#[test]
fun mul_u256_handles_max_operands() {
    // Multiplying the largest possible operands should produce hi = (2^256 - 2) and lo = 1.
    let max = std::u256::max_value!();
    let result = u512::mul_u256(max, max);
    assert_eq!(u512::hi(&result), max - 1);
    assert_eq!(u512::lo(&result), 1);
}

#[test]
fun mul_u256_combines_high_bits_correctly() {
    // Squaring a value made only of high bits should land entirely in the high limb afterwards.
    let operand = 1u256 << 200;
    let result = u512::mul_u256(operand, operand);
    assert_eq!(u512::hi(&result), (1u256 << 144));
    assert_eq!(u512::lo(&result), 0);
}

#[test]
fun mul_u256_carries_across_diagonals() {
    // When both extreme bits are set, cross terms force carries across the diagonal sums.
    let high_bit = 1u256 << 255;
    let operand = high_bit + 1;
    let result = u512::mul_u256(operand, operand);
    assert_eq!(u512::hi(&result), ((1u256 << 254) + 1));
    assert_eq!(u512::lo(&result), 1);
}

#[test]
fun div_rem_exact_no_overflow() {
    // Exact division should produce a zero remainder and no overflow.
    let numerator = u512::new(0, 84);
    let divisor = 7;
    let (overflow, quotient, remainder) = u512::div_rem_u256(
        numerator,
        divisor,
    );
    assert_eq!(overflow, false);
    assert_eq!(remainder, 0);
    // Verify quotient * divisor + remainder reconstructs the starting numerator.
    let rebuild = add_u512(
        u512::mul_u256(quotient, divisor),
        u512::from_u256(remainder),
    );
    assert_u512_eq(rebuild, numerator);
}

#[test]
fun div_rem_with_remainder() {
    // Non-zero remainder stays below the divisor while still rebuilding the numerator.
    let numerator = u512::new(0, 100);
    let divisor = 7;
    let (overflow, quotient, remainder) = u512::div_rem_u256(
        numerator,
        divisor,
    );
    assert_eq!(overflow, false);
    assert_eq!(remainder, 2);
    let rebuild = add_u512(
        u512::mul_u256(quotient, divisor),
        u512::from_u256(remainder),
    );
    assert_u512_eq(rebuild, numerator);
}

#[test]
fun div_rem_handles_high_limb_without_overflow() {
    // Dividing a value with both limbs populated exercises the borrow path inside subtraction.
    let numerator = u512::new(2, 123);
    let divisor = 3;
    let (overflow, quotient, remainder) = u512::div_rem_u256(
        numerator,
        divisor,
    );
    assert_eq!(overflow, false);
    assert!(remainder < divisor);

    // As before, rebuild the numerator to ensure no precision loss.
    let product = u512::mul_u256(quotient, divisor);
    let rebuild = add_u512(product, u512::from_u256(remainder));
    assert_u512_eq(rebuild, numerator);
}

#[test]
fun div_rem_flags_overflow_when_quotient_exceeds_u256() {
    // Any quotient that would spill beyond 256 bits must flip the overflow flag.
    let numerator = u512::new(1, 0);
    let (overflow, quotient, remainder) = u512::div_rem_u256(numerator, 1);
    assert_eq!(overflow, true);
    assert_eq!(quotient, 0);
    assert_eq!(remainder, 0);
}

#[test]
fun div_rem_large_operands_trigger_overflow_flag() {
    // Dividing 2^512 - 1 by (2^256 - 1) should overflow because the true quotient is 2^256 + 1.
    let max = std::u256::max_value!();
    let numerator = u512::new(max, max);
    let (overflow, quotient, remainder) = u512::div_rem_u256(numerator, max);
    assert_eq!(overflow, true);
    assert_eq!(quotient, 0);
    assert_eq!(remainder, 0);
}

#[test, expected_failure(abort_code = u512::EDivideByZero)]
fun div_rem_rejects_zero_divisor() {
    // Division by zero should trap immediately.
    let (_overflow, _quotient, _remainder) = u512::div_rem_u256(
        u512::zero(),
        0,
    );
}

/// === Helpers ===

/// Simple helper to compare two `U512` values.
fun assert_u512_eq(left: U512, right: U512) {
    assert_eq!(u512::hi(&left), u512::hi(&right));
    assert_eq!(u512::lo(&left), u512::lo(&right));
}

/// Adds two `U512` values (small helper for test expectations).
fun add_u512(a: U512, b: U512): U512 {
    // Core addition happens on the low limb; track wraparound to detect the carry.
    let a_lo = u512::lo(&a);
    let b_lo = u512::lo(&b);
    let lo_sum = a_lo + b_lo;
    let carry = if (lo_sum < a_lo) 1u256 else 0u256;
    // High limb gets the incoming carry plus both high words.
    let hi_sum = u512::hi(&a) + u512::hi(&b) + carry;
    u512::new(hi_sum, lo_sum)
}

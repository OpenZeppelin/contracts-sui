module openzeppelin_math::core_tests;

use openzeppelin_math::macros;
use openzeppelin_math::rounding;
use openzeppelin_math::u128;
use openzeppelin_math::u256;
use openzeppelin_math::u32;
use openzeppelin_math::u64;
use openzeppelin_math::u8;

#[test]
fun mul_div_applies_rounding_modes() {
    // Check how the rounding modes alter the result of 7 * 10 / 4.
    let down = u64::mul_div(7, 10, 4, rounding::down());
    assert!(down == 17);

    let up = u64::mul_div(7, 10, 4, rounding::up());
    assert!(up == 18);

    let nearest = u64::mul_div(7, 10, 4, rounding::nearest());
    assert!(nearest == 18);

    let exact = u64::mul_div(8, 10, 4, rounding::down());
    assert!(exact == 20);
}

#[test]
fun mul_div_supports_multiple_widths() {
    // Confirm the wrappers downcast correctly after doing large 128- and 256-bit products.
    let value_128 =
        u128::mul_div(1_000_000_000_000u128, 3u128, 2u128, rounding::down());
    assert!(value_128 == 1_500_000_000_000u128);

    let value_256 = u256::mul_div(
        1_234_567_890_123_456_789u256,
        10u256,
        3u256,
        rounding::nearest(),
    );
    assert!(value_256 == 4_115_226_300_411_522_630u256);
}

#[test, expected_failure(abort_code = macros::EDivideByZero)]
fun mul_div_rejects_zero_denominator() {
    // 1 * 2 / 0 should trap before any rounding happens.
    let _ = u32::mul_div(1, 2, 0, rounding::down());
}

#[test, expected_failure(abort_code = u8::EArithmeticOverflow)]
fun mul_div_detects_overflow() {
    // 20 * 20 / 1 exceeds u8::MAX and must surface the overflow code path.
    let _ = u8::mul_div(20, 20, 1, rounding::down());
}

#[test]
fun mul_div_big_u256_in_multiplication() {
    // max(u256) * 2 followed by division by 3 stays within range once we normalise by gcd factors.
    let max = std::u256::max_value!();
    let _ = u256::mul_div(max, 2u256, 3u256, rounding::down());
}

module oz_math::core_tests;

use oz_math::core;

#[test]
fun mul_div_applies_rounding_modes() {
    // Check how the rounding modes alter the result of 7 * 10 / 4.
    let down = core::mul_div_u64(7, 10, 4, core::rounding_down());
    assert!(down == 17);

    let up = core::mul_div_u64(7, 10, 4, core::rounding_up());
    assert!(up == 18);

    let nearest = core::mul_div_u64(7, 10, 4, core::rounding_nearest());
    assert!(nearest == 18);

    let exact = core::mul_div_u64(8, 10, 4, core::rounding_down());
    assert!(exact == 20);
}

#[test]
fun mul_div_supports_multiple_widths() {
    // Confirm the wrappers downcast correctly after doing large 128- and 256-bit products.
    let value_128 = core::mul_div_u128(1_000_000_000_000u128, 3u128, 2u128, core::rounding_down());
    assert!(value_128 == 1_500_000_000_000u128);

    let value_256 = core::mul_div_u256(
        1_234_567_890_123_456_789u256,
        10u256,
        3u256,
        core::rounding_nearest(),
    );
    assert!(value_256 == 4_115_226_300_411_522_630u256);
}

#[test, expected_failure(abort_code = core::EDivideByZero)]
fun mul_div_rejects_zero_denominator() {
    // 1 * 2 / 0 should trap before any rounding happens.
    let _ = core::mul_div_u32(1, 2, 0, core::rounding_down());
}

#[test, expected_failure(abort_code = core::EArithmeticOverflow)]
fun mul_div_detects_overflow() {
    // 20 * 20 / 1 exceeds u8::MAX and must surface the overflow code path.
    let _ = core::mul_div_u8(20, 20, 1, core::rounding_down());
}

#[test]
fun mul_div_big_u256_in_multiplication() {
    // max(u256) * 2 followed by division by 3 stays within range once we normalise by gcd factors.
    let max = std::u256::max_value!();
    let _ = core::mul_div_u256(max, 2u256, 3u256, core::rounding_down());
}

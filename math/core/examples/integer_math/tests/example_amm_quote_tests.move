module openzeppelin_math::example_amm_quote_tests;

use openzeppelin_math::example_amm_quote as amm;
use std::unit_test::assert_eq;

// Output is rounded down and the fee is rounded up, so a fee strictly shrinks the output.
#[test]
fun quote_rounds_output_down_and_fee_up() {
    // No fee: out = floor(10_000 * 1_000 / 11_000) = 909.
    assert_eq!(amm::quote_swap_out(10_000, 10_000, 1_000, 0), 909);
    // 1% fee nets 990 in, so out = floor(10_000 * 990 / 10_990) = 900.
    assert_eq!(amm::quote_swap_out(10_000, 10_000, 1_000, 100), 900);
}

// A small pool quote with the output rounded down.
#[test]
fun small_pool_quote_is_exact() {
    // floor(1_000 * 100 / 1_100) = 90.
    assert_eq!(amm::quote_swap_out(1_000, 1_000, 100, 0), 90);
}

// Rounding the fee up changes the result: 0.3% of 100 is 0.3, charged as 1 not 0.
#[test]
fun fee_rounds_up_so_the_pool_keeps_the_dust() {
    assert_eq!(amm::protocol_fee(100, 30), 1);
    // An exact fee is unaffected by the rounding mode: 1% of 1_000 = 10.
    assert_eq!(amm::protocol_fee(1_000, 100), 10);
}

// Initial LP shares are floor(sqrt(x * y)); the product is formed in u128 to avoid overflow.
#[test]
fun initial_shares_are_the_geometric_mean() {
    assert_eq!(amm::initial_lp_shares(1_000_000, 4_000_000), 2_000_000);
    // Non-perfect square truncates: floor(sqrt(6)) = 2.
    assert_eq!(amm::initial_lp_shares(2, 3), 2);
}

// A Q32.32 factor scales an amount and the fractional part is truncated.
#[test]
fun q32_factor_scales_and_truncates() {
    let one_and_a_half = 3u64 << 31; // 1.5 in Q32.32
    assert_eq!(amm::apply_factor_q32(100, one_and_a_half), 150);
    let one_half = 1u64 << 31; // 0.5 in Q32.32
    // 101 * 0.5 = 50.5, truncated to 50.
    assert_eq!(amm::apply_factor_q32(101, one_half), 50);
}

// `average` rounds the midpoint to nearest; `log10` gives a reserve's decimal magnitude.
#[test]
fun midpoint_and_magnitude() {
    assert_eq!(amm::midpoint_reserve(100, 200), 150);
    // 15.5 rounds to nearest -> 16.
    assert_eq!(amm::midpoint_reserve(10, 21), 16);
    assert_eq!(amm::reserve_magnitude(999), 2);
    assert_eq!(amm::reserve_magnitude(1_000), 3);
}

// The same mul_div API one width up, returning none on overflow instead of aborting.
#[test]
fun wide_rescale_uses_the_same_api() {
    assert_eq!(amm::scale_u256(1_000, 3, 2), option::some(1_500u256));
    // 2^200 * 2^200 = 2^400 exceeds u256, so the result is none.
    let huge = 1u256 << 200;
    assert!(amm::scale_u256(huge, huge, 1).is_none());
}

// A zero input amount is rejected.
#[test, expected_failure(abort_code = amm::EZeroInput)]
fun zero_input_is_rejected() {
    amm::quote_swap_out(1_000, 1_000, 0, 0);
    abort
}

// A pool with an empty reserve is rejected.
#[test, expected_failure(abort_code = amm::EEmptyReserves)]
fun empty_pool_is_rejected() {
    amm::quote_swap_out(0, 1_000, 100, 0);
    abort
}

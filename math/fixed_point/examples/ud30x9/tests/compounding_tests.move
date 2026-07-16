module openzeppelin_fp_math::example_compounding_tests;

use openzeppelin_fp_math::example_compounding::{
    balance_after,
    interest_after,
    growth_multiplier,
    compounded_factor,
    per_period_multiplier,
};
use openzeppelin_fp_math::ud30x9;
use openzeppelin_fp_math::ud30x9_base;
use openzeppelin_fp_math::ud30x9_convert;
use std::unit_test::assert_eq;

/// `UD30x9` scale: `1.0` is `1_000_000_000` raw.
const SCALE: u128 = 1_000_000_000;

// Happy path: 100 coins at 10% per period, compounded 3 times.
// 100 * 1.1^3 = 100 * 1.331 = 133.1 -> truncates to 133.
#[test]
fun compounds_100_at_10_percent_over_3_periods() {
    assert_eq!(balance_after(100, 1, 10, 3), 133);
    // Interest is the balance minus the principal: 133 - 100.
    assert_eq!(interest_after(100, 1, 10, 3), 33);
}

// The fixed-point steps are exact for these small rates, so we can pin the raw
// `UD30x9` bit patterns, not just the truncated coin output.
#[test]
fun raw_fixed_point_values_are_exact() {
    // 1 + 1/10 = 1.1 exactly.
    assert_eq!(growth_multiplier(1, 10).unwrap(), 1_100_000_000);
    // 1.1^3 = 1.331 exactly.
    assert_eq!(compounded_factor(1, 10, 3).unwrap(), 1_331_000_000);
    // 1.05^2 = 1.1025 exactly.
    assert_eq!(compounded_factor(1, 20, 2).unwrap(), 1_102_500_000);
}

// A larger principal at 5% per period over 2 periods.
// 1000 * 1.05^2 = 1000 * 1.1025 = 1102.5 -> truncates to 1102.
#[test]
fun compounds_1000_at_5_percent_over_2_periods() {
    assert_eq!(balance_after(1000, 1, 20, 2), 1102);
    assert_eq!(interest_after(1000, 1, 20, 2), 102);
}

// `pow(0)` yields the multiplicative identity, so a zero-period term returns the
// principal untouched and accrues no interest.
#[test]
fun zero_periods_returns_principal() {
    assert_eq!(compounded_factor(1, 10, 0).unwrap(), SCALE);
    assert_eq!(balance_after(500, 1, 10, 0), 500);
    assert_eq!(interest_after(500, 1, 10, 0), 0);
}

// A zero numerator is a zero rate: the multiplier is exactly 1.0, so the balance
// never grows regardless of how many periods elapse.
#[test]
fun zero_rate_never_grows() {
    assert_eq!(growth_multiplier(0, 10).unwrap(), SCALE);
    assert_eq!(balance_after(777, 0, 10, 5), 777);
    assert_eq!(interest_after(777, 0, 10, 5), 0);
}

// `sqrt` recovers the per-period multiplier from a two-period growth factor.
// 1.1 grew over two periods is 1.21; sqrt(1.21) = 1.1 exactly.
#[test]
fun per_period_multiplier_is_geometric_mean() {
    let two_period = compounded_factor(1, 10, 2); // 1.21
    assert_eq!(two_period.unwrap(), 1_210_000_000);

    let per_period = per_period_multiplier(two_period);
    assert_eq!(per_period.unwrap(), 1_100_000_000); // 1.1

    // It round-trips: the recovered multiplier matches the original 1.1.
    assert_eq!(per_period.eq(growth_multiplier(1, 10)), true);
}

// The truncating conversion shaves the fractional coin units: a 0.5 fractional
// payout rounds down to whole coins.
#[test]
fun truncation_drops_fractional_coin_units() {
    // 10 * 1.05 = 10.5 -> truncates to 10.
    assert_eq!(balance_after(10, 1, 20, 1), 10);
    // Same multiplier, larger principal preserves the half: 1000 * 1.05 = 1050.
    assert_eq!(balance_after(1000, 1, 20, 1), 1050);
}

// A zero denominator constructs the rate as `one().div(from_u64(0))`, and
// `from_u64(0)` is `ud30x9::zero()`, so the division aborts with the library's
// divide-by-zero error.
#[test, expected_failure(abort_code = ud30x9_base::EDivideByZero)]
fun zero_denominator_aborts() {
    // Sanity-check the precondition the abort relies on, then trigger it.
    assert_eq!(ud30x9_convert::from_u64(0).eq(ud30x9::zero()), true);
    balance_after(100, 1, 0, 3);
    abort
}

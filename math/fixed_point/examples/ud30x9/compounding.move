/// A fixed-rate compound-interest / APY calculator built on `ud30x9`.
///
/// This is the on-chain math a fixed-term savings product, a bond coupon
/// schedule, or a "stake N tokens, earn R per period" vault needs: given a
/// `principal` in coin units, a periodic rate, and a number of compounding
/// periods, compute the balance after compounding:
///
/// ```text
/// balance_after = principal * (1 + rate)^periods
/// ```
///
/// The whole point of reaching for `ud30x9` (unsigned decimal fixed point,
/// scaled by `10^9`) is the fractional rate. A `u64` coin amount cannot
/// represent "1.1x growth"; `ud30x9` can, and its `10^9` scale lines up exactly
/// with Sui's native 9-decimal coins, so converting token amounts in and out is
/// a single scale step rather than a hand-rolled rescale.
///
/// ### How the rate is constructed
///
/// A periodic rate like 10% is not handed to us pre-scaled; we build it as a
/// fraction of one. `ud30x9_convert::from_u64(n)` yields `n.0`, so
/// `one().div(from_u64(10))` is `1.0 / 10.0 = 0.1`, and
/// `one().add(rate)` is the growth multiplier `1.1`. Expressing the rate as
/// `numerator / denominator` (rather than asking the caller to pre-scale a raw
/// fixed-point value) keeps the integration honest: the caller passes plain
/// integers and the module owns every scale conversion.
///
/// Raising the multiplier with `pow(periods)` and multiplying by the
/// scaled principal gives the compounded balance; `to_u64_trunc` truncates back
/// to whole coin units for payout. For the small integer rates and horizons a
/// savings product actually uses (e.g. `1.1^3`), every step here lands on an
/// exact `ud30x9` value, so those results are exact, not approximations. Rates
/// that are not exactly representable at the `10^9` scale (say `1/3`) are still
/// computed deterministically, but `div` rounds them and `pow` compounds that
/// rounding - only the exactly-representable cases shown here are exact.
///
/// ### What each operation demonstrates
///
/// - `add` / `div`: assemble the growth multiplier `1 + num/den` from integers.
/// - `pow`: compound over `periods` via binary exponentiation.
/// - `mul`: apply the multiplier to the scaled principal.
/// - `sqrt`: recover the per-period multiplier from a two-period growth factor
///   (`sqrt(1 + apy) = 1 + half_period_rate`), the kind of geometric "half
///   horizon" conversion a UI shows next to a headline APY.
/// - `to_u64_trunc` / `from_u64`: bridge between coin units and fixed point.
///
/// Every function here is pure compute: no objects, no capabilities, no
/// `TxContext`. A vault or savings module would call these to size a payout,
/// then move the actual `Coin`/`Balance` itself.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways
/// the `ud30x9` fixed-point primitive can be integrated. It is not
/// production-ready and must not be deployed as-is.
module openzeppelin_fp_math::example_compounding;

use openzeppelin_fp_math::ud30x9::{Self, UD30x9};
use openzeppelin_fp_math::ud30x9_convert;

// === Public Functions ===

/// Compounded balance after `periods` of growth at a fixed periodic rate,
/// expressed as the fraction `rate_num / rate_den` (so `1 / 10` is 10%).
///
/// Computes `principal * (1 + rate_num/rate_den)^periods` and truncates the
/// result back to whole coin units. With `periods = 0` the multiplier is `1`
/// and the principal is returned unchanged; with `rate_num = 0` the rate is
/// zero and the balance never grows.
///
/// #### Parameters
/// - `principal`: Starting balance in whole coin units (9-decimal coin amount).
/// - `rate_num`: Numerator of the periodic rate.
/// - `rate_den`: Denominator of the periodic rate; must be non-zero.
/// - `periods`: Number of compounding periods.
///
/// #### Returns
/// - The compounded balance, truncated to whole coin units.
///
/// #### Aborts
/// - `ud30x9_base::EDivideByZero` if `rate_den` is zero.
/// - `ud30x9_base::EOverflow` if the compounded multiplier or balance exceeds
///   the representable `UD30x9` range.
/// - `ud30x9_convert::EIntegerOverflow` if the compounded balance exceeds
///   `u64::MAX` before truncation to whole coin units.
public fun balance_after(principal: u64, rate_num: u64, rate_den: u64, periods: u8): u64 {
    let multiplier = growth_multiplier(rate_num, rate_den);
    let principal_fp = ud30x9_convert::from_u64(principal);
    let result = multiplier.pow(periods).mul(principal_fp);
    result.to_u64_trunc()
}

/// Total interest earned over `periods`: the compounded balance minus the
/// principal, in whole coin units. Convenience wrapper over `balance_after`.
///
/// #### Parameters
/// - `principal`: Starting balance in whole coin units.
/// - `rate_num`: Numerator of the periodic rate.
/// - `rate_den`: Denominator of the periodic rate; must be non-zero.
/// - `periods`: Number of compounding periods.
///
/// #### Returns
/// - The accrued interest in whole coin units.
///
/// #### Aborts
/// - `ud30x9_base::EDivideByZero` if `rate_den` is zero.
/// - `ud30x9_base::EOverflow` on multiplier or balance overflow.
/// - `ud30x9_convert::EIntegerOverflow` if the compounded balance exceeds
///   `u64::MAX` before truncation.
public fun interest_after(principal: u64, rate_num: u64, rate_den: u64, periods: u8): u64 {
    balance_after(principal, rate_num, rate_den, periods) - principal
}

/// The per-period growth multiplier `1 + rate_num/rate_den`, as a raw `UD30x9`.
///
/// Exposed so callers can inspect or reuse the multiplier (e.g. feed it to
/// `compounded_factor`) without recomputing the fraction. `one().div(...)`
/// builds the fractional rate from plain integers; `add` lifts it to a
/// multiplier.
///
/// #### Parameters
/// - `rate_num`: Numerator of the periodic rate.
/// - `rate_den`: Denominator of the periodic rate; must be non-zero.
///
/// #### Returns
/// - The growth multiplier `1 + rate_num/rate_den`.
///
/// #### Aborts
/// - `ud30x9_base::EDivideByZero` if `rate_den` is zero.
public fun growth_multiplier(rate_num: u64, rate_den: u64): UD30x9 {
    let rate = ud30x9_convert::from_u64(rate_num).div(ud30x9_convert::from_u64(rate_den));
    ud30x9::one().add(rate)
}

/// The compounded growth factor `(1 + rate)^periods` as a raw `UD30x9`, before
/// any principal is applied. This is the multiplier a UI shows as "your balance
/// grows N.NNx over the term".
///
/// #### Parameters
/// - `rate_num`: Numerator of the periodic rate.
/// - `rate_den`: Denominator of the periodic rate; must be non-zero.
/// - `periods`: Number of compounding periods.
///
/// #### Returns
/// - The compounded factor `(1 + rate_num/rate_den)^periods`.
///
/// #### Aborts
/// - `ud30x9_base::EDivideByZero` if `rate_den` is zero.
/// - `ud30x9_base::EOverflow` if the factor exceeds the representable range.
public fun compounded_factor(rate_num: u64, rate_den: u64, periods: u8): UD30x9 {
    growth_multiplier(rate_num, rate_den).pow(periods)
}

/// The equivalent per-period multiplier over a two-period horizon, recovered
/// from a full-horizon growth factor via the geometric mean `sqrt(factor)`.
///
/// For a factor that grew over exactly two equal periods, `sqrt` returns the
/// single-period multiplier: e.g. `sqrt(1.21) = 1.1`. This is the standard
/// "annualize / de-annualize" conversion a frontend performs when it has a
/// two-period (say, semiannual-to-annual) factor but wants to quote the
/// single-period rate. `sqrt` rounds down to the nearest representable value.
///
/// #### Parameters
/// - `two_period_factor`: A growth factor accrued over two equal periods.
///
/// #### Returns
/// - The per-period multiplier, i.e. `sqrt(two_period_factor)`.
public fun per_period_multiplier(two_period_factor: UD30x9): UD30x9 {
    two_period_factor.sqrt()
}

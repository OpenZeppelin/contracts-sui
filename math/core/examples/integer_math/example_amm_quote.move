/// A constant-product AMM pricing toolkit built on the width-generic integer API of
/// `openzeppelin_math`.
///
/// Every function here is a pure calculation - the idiomatic shape for a math primitive,
/// since the library owns no state. The point is to show how a real protocol wires the
/// integer helpers into its hot path, and that the *same function names* (`mul_div`,
/// `mul_shr`, `average`, `sqrt`, `log10`) exist on every unsigned width (`u8` .. `u256`),
/// so you reach for a wider type only when the numbers demand it.
///
/// Two ideas recur:
///
/// 1. **Full-precision `mul_div` instead of `a * b / d`.** A naive `(reserve_out *
///    amount_in) / denom` overflows the instant the product exceeds the type, even when
///    the final quotient would have fit. `mul_div` evaluates the product in a wider
///    intermediate and only returns `none` if the *rounded result* itself cannot fit.
/// 2. **Rounding direction is a solvency decision.** The functions pin their rounding
///    mode rather than letting callers choose, because the direction protects the pool:
///     - swap output is rounded DOWN, so the pool never pays out more than the invariant
///       allows and can never under-collateralize;
///     - the protocol fee is rounded UP, so rounding dust accrues to liquidity providers
///       rather than leaking to the swapper.
///
/// `scale_u256` rescales a quantity that already exceeds `u64`, and returns an `Option` so
/// an integrator can branch on overflow instead of aborting - the same `mul_div` contract,
/// one width up.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `openzeppelin_math` integer primitives can be integrated. It is not production-ready
/// and must not be deployed as-is: a real AMM additionally needs slippage protection,
/// reserve/`Balance` custody, and oracle-manipulation resistance.
module openzeppelin_math::example_amm_quote;

use openzeppelin_math::rounding;
use openzeppelin_math::u128;
use openzeppelin_math::u256;
use openzeppelin_math::u64;

// === Errors ===

/// A quote was requested against a pool with a zero reserve.
#[error(code = 0)]
const EEmptyReserves: vector<u8> = "Pool reserves must be non-zero";

/// The input amount of a swap was zero.
#[error(code = 1)]
const EZeroInput: vector<u8> = "Swap input amount must be non-zero";

/// An intermediate result did not fit its integer type.
#[error(code = 2)]
const EOverflow: vector<u8> = "Arithmetic result does not fit the integer type";

// === Constants ===

/// Denominator for fees expressed in basis points (1 bp = 0.01%); a 0.30% fee is `30`.
const BPS: u64 = 10_000;

// === Public Functions ===

/// Constant-product swap quote: the output token amount for `amount_in`, after a fee.
///
/// The fee is taken on the input and rounded UP (protocol-favorable); the output is
/// computed as `reserve_out * net_in / (reserve_in + net_in)` and rounded DOWN
/// (pool-favorable), so the pool can never pay out more than the invariant permits.
///
/// #### Parameters
/// - `reserve_in`: Reserve of the token being sold into the pool.
/// - `reserve_out`: Reserve of the token being bought from the pool.
/// - `amount_in`: Amount of the input token offered.
/// - `fee_bps`: Swap fee in basis points.
///
/// #### Returns
/// - The output token amount, rounded down.
///
/// #### Aborts
/// - `EEmptyReserves` if either reserve is zero.
/// - `EZeroInput` if `amount_in` is zero.
/// - `EOverflow` if an intermediate `mul_div` overflows `u64`.
public fun quote_swap_out(reserve_in: u64, reserve_out: u64, amount_in: u64, fee_bps: u64): u64 {
    assert!(reserve_in > 0 && reserve_out > 0, EEmptyReserves);
    assert!(amount_in > 0, EZeroInput);

    let net_in = amount_in - protocol_fee(amount_in, fee_bps);
    u64::mul_div(reserve_out, net_in, reserve_in + net_in, rounding::down()).destroy_or!(
        abort EOverflow,
    )
}

/// The protocol fee charged on `amount_in`, rounded UP so the pool keeps the dust.
///
/// Rounding up is what makes the fee protocol-favorable: `mul_div(100, 30, 10_000, up)`
/// is `1`, whereas truncating (down) would charge `0` on the same trade.
///
/// #### Parameters
/// - `amount_in`: Amount the fee is charged on.
/// - `fee_bps`: Fee in basis points.
///
/// #### Returns
/// - The fee, rounded up.
///
/// #### Aborts
/// - `EOverflow` if the `mul_div` overflows `u64`.
public fun protocol_fee(amount_in: u64, fee_bps: u64): u64 {
    u64::mul_div(amount_in, fee_bps, BPS, rounding::up()).destroy_or!(abort EOverflow)
}

/// Initial LP shares minted for the first deposit: `floor(sqrt(amount_x * amount_y))`,
/// the geometric mean of the two deposits.
///
/// The product is formed in `u128` so two large `u64` deposits cannot overflow before the
/// square root shrinks the magnitude back; the result always fits `u64`. This is the same
/// `sqrt` available on every width, used here one step up from `u64`.
///
/// #### Parameters
/// - `amount_x`: Deposit of token X.
/// - `amount_y`: Deposit of token Y.
///
/// #### Returns
/// - The initial LP share count.
public fun initial_lp_shares(amount_x: u64, amount_y: u64): u64 {
    let product = (amount_x as u128) * (amount_y as u128);
    u128::sqrt(product, rounding::down()) as u64
}

/// Apply a Q32.32 fixed-point factor (e.g. a price or weight) to an integer amount,
/// truncating the fractional part.
///
/// `mul_shr(amount, factor, 32, down)` computes `amount * factor / 2^32` in a wide
/// intermediate, which is the correct way to multiply by a fixed-point number without
/// overflowing on the `amount * factor` step.
///
/// #### Parameters
/// - `amount`: Integer amount to scale.
/// - `factor_q32`: Multiplier in Q32.32 fixed point (`1.0` is `1 << 32`).
///
/// #### Returns
/// - `amount * factor_q32 / 2^32`, rounded down.
///
/// #### Aborts
/// - `EOverflow` if the result does not fit `u64`.
public fun apply_factor_q32(amount: u64, factor_q32: u64): u64 {
    u64::mul_shr(amount, factor_q32, 32, rounding::down()).destroy_or!(abort EOverflow)
}

/// The arithmetic mean of two reserve snapshots, e.g. for a simple time-averaged reserve.
/// `average` computes `(a + b) / 2` without overflowing on the sum.
///
/// #### Parameters
/// - `a`: First snapshot.
/// - `b`: Second snapshot.
///
/// #### Returns
/// - The mean, rounded to nearest.
public fun midpoint_reserve(a: u64, b: u64): u64 {
    u64::average(a, b, rounding::nearest())
}

/// The decimal magnitude of a reserve: `floor(log10(reserve))`. A reserve in the
/// thousands returns `3`, in the millions `6` - handy for UI tiers or magnitude-based
/// fee schedules.
///
/// #### Parameters
/// - `reserve`: The reserve to measure.
///
/// #### Returns
/// - `floor(log10(reserve))`.
public fun reserve_magnitude(reserve: u64): u8 {
    u64::log10(reserve, rounding::down())
}

/// Rescale a `u256` quantity by the ratio `numerator / denominator`, e.g. normalizing a
/// large reserve to a common precision.
///
/// Uses the same `mul_div` as the `u64` swap, one width up, and returns `none` rather than
/// aborting when the rescaled value overflows `u256` - so a caller can branch on the
/// failure instead of reverting the whole transaction.
///
/// #### Parameters
/// - `amount`: The quantity to rescale.
/// - `numerator`: Ratio numerator.
/// - `denominator`: Ratio denominator.
///
/// #### Returns
/// - `some(amount * numerator / denominator)` rounded down, or `none` on `u256` overflow.
public fun scale_u256(amount: u256, numerator: u256, denominator: u256): Option<u256> {
    u256::mul_div(amount, numerator, denominator, rounding::down())
}

// === View helpers ===

/// The basis-points denominator (`10_000`).
public fun bps_denominator(): u64 {
    BPS
}

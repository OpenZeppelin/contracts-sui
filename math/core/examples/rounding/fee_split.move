/// A solvency-preserving fee/payout splitter built on `openzeppelin_math::rounding`.
///
/// The teaching point is the rounding *decision*, not the arithmetic. Any time a
/// total is divided into a protocol fee and a user payout, the basis-points math
/// (`total * fee_bps / 10_000`) almost never lands on a whole unit. Something has to
/// absorb the fractional remainder, and the choice of *who* absorbs it - and *which*
/// of the two parts you round - is an economic and a safety decision:
///
/// - Round the WRONG side and the two parts can sum to more than the whole, so the
///   contract promises out a unit it does not hold. Over many splits that is a slow
///   insolvency leak.
/// - Round the protocol-favorable side UP and the user-favorable side DOWN and you
///   never create or destroy a unit - but you must be deliberate about it.
///
/// This example demonstrates the convention that makes the split exact every time:
/// **round ONE side with `mul_div`, then derive the OTHER side as the remainder**
/// (`payout = total - fee`). Because the second part is subtraction, not a second
/// rounded division, the two parts provably sum to `total` for *every* input and
/// *every* rounding mode. The rounding mode only decides which side keeps the spare
/// sub-unit; it can never break the `fee + payout == total` invariant.
///
/// The three entry points differ only in the `RoundingMode` they feed to `mul_div`:
///
/// - `split_protocol_favorable` rounds the fee UP (protocol keeps the spare sub-unit).
/// - `split_user_favorable` rounds the fee DOWN (user keeps the spare sub-unit).
/// - `split_nearest` rounds the fee to NEAREST (ties round up), a neutral default.
///
/// `bps_of` exposes the underlying `mul_div` basis-points calculation directly, with
/// the rounding mode left to the caller, for integrators who need the raw fee figure
/// without the paired payout.
///
/// All functions are pure compute (no `TxContext`, no objects): a splitter is a
/// stateless policy you call inside whatever PTB moves the actual `Coin`/`Balance`.
///
/// # Why `mul_div` and not `total * fee_bps / 10_000`
///
/// Writing the product by hand overflows `u64` for large totals (`total * fee_bps`
/// can exceed `2^64` well before either factor does). `mul_div` computes the product
/// in a wider intermediate type, applies the chosen rounding, and returns
/// `option::none()` only if the *rounded quotient* itself cannot fit back into `u64`.
/// This example treats that `none` as a programming error (the fee can never exceed
/// the total once `fee_bps <= 10_000`) and unwraps it; a downstream integrator doing
/// arithmetic on attacker-controlled magnitudes should branch on the `Option` instead.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `rounding` primitive (and `mul_div`'s explicit rounding modes) can be integrated.
/// It is not production-ready and must not be deployed as-is.
module openzeppelin_math::example_fee_split;

use openzeppelin_math::rounding::{Self, RoundingMode};
use openzeppelin_math::u64;

// === Errors ===

/// `fee_bps` exceeded `BPS_DENOMINATOR` (100%). A fee above the total would drive the
/// derived `payout = total - fee` below zero and break the solvency convention, so it
/// is rejected up front rather than silently wrapping.
#[error(code = 0)]
const EInvalidBps: vector<u8> = "fee_bps must not exceed 10000 (100%)";

// === Constants ===

/// Basis-points denominator: 10_000 bps == 100%. One bps is 0.01%.
const BPS_DENOMINATOR: u64 = 10_000;

// === Public Functions ===

/// Split `total` protocol-favorably: round the fee UP, then derive the payout as the
/// remainder. The protocol keeps any spare sub-unit. Use this for the protocol's own
/// fee accrual, where rounding in your favor is the conservative default.
///
/// Returns `(fee, payout)` with the invariant `fee + payout == total` for every input.
///
/// #### Aborts
/// - `EInvalidBps` if `fee_bps > 10_000`.
public fun split_protocol_favorable(total: u64, fee_bps: u64): (u64, u64) {
    split_with(total, fee_bps, rounding::up())
}

/// Split `total` user-favorably: round the fee DOWN, then derive the payout as the
/// remainder. The user keeps any spare sub-unit. Use this when crediting a user and
/// you want to err toward paying them slightly more rather than less.
///
/// Returns `(fee, payout)` with the invariant `fee + payout == total` for every input.
///
/// #### Aborts
/// - `EInvalidBps` if `fee_bps > 10_000`.
public fun split_user_favorable(total: u64, fee_bps: u64): (u64, u64) {
    split_with(total, fee_bps, rounding::down())
}

/// Split `total` with nearest rounding (ties round up) on the fee, then derive the
/// payout as the remainder. A neutral default when neither side should be structurally
/// favored.
///
/// Returns `(fee, payout)` with the invariant `fee + payout == total` for every input.
///
/// #### Aborts
/// - `EInvalidBps` if `fee_bps > 10_000`.
public fun split_nearest(total: u64, fee_bps: u64): (u64, u64) {
    split_with(total, fee_bps, rounding::nearest())
}

/// The raw basis-points fee on `amount` at `bps`, with the rounding mode chosen by the
/// caller: `amount * bps / 10_000` rounded per `rounding_mode`. Exposed for integrators
/// who need only the fee figure (the paired payout helpers above call this internally).
///
/// This is where the explicit-rounding `mul_div` does its work; `rounding::up()`,
/// `rounding::down()`, and `rounding::nearest()` are the only difference between the
/// three split policies.
///
/// #### Aborts
/// - `EInvalidBps` if `bps > 10_000`.
public fun bps_of(amount: u64, bps: u64, rounding_mode: RoundingMode): u64 {
    assert!(bps <= BPS_DENOMINATOR, EInvalidBps);
    // `bps <= 10_000` guarantees the rounded quotient is at most `amount`, which always
    // fits in `u64`, so the `Option` is never `none` here. A caller operating on
    // unbounded magnitudes should branch on the `Option` rather than unwrap.
    u64::mul_div(amount, bps, BPS_DENOMINATOR, rounding_mode).destroy_some()
}

// === Private Functions ===

/// Shared splitter core: round the FEE with `rounding_mode`, then derive the PAYOUT as
/// `total - fee`. Deriving the second part by subtraction (rather than a second rounded
/// division) is what guarantees `fee + payout == total` exactly, regardless of which
/// mode is used. The `EInvalidBps` guard keeps `fee <= total`, so the subtraction never
/// underflows.
fun split_with(total: u64, fee_bps: u64, rounding_mode: RoundingMode): (u64, u64) {
    let fee = bps_of(total, fee_bps, rounding_mode);
    let payout = total - fee;
    (fee, payout)
}

/// A tranched (supply-tiered) pricing curve for `prefunded_sale`: the
/// token-per-payment `rate` steps as the sale fills, so early buyers get a
/// better rate than late ones. A worked example of the witness-gated `Curve`
/// seam that `fixed_rate_curve` - the only shipped curve - is too trivial to
/// demonstrate.
///
/// ### The pricing rule
///
/// The rate is piecewise-constant in *tiers* keyed on cumulative amount raised:
/// while `raised` is below the first breakpoint, purchases price at `rates[0]`;
/// between the first and second breakpoint, at `rates[1]`; and so on, with the
/// final rate extending to the hard cap. A purchase that straddles a breakpoint
/// is priced **per band**: the portion of the payment on each side of the
/// breakpoint is allocated at that band's rate and the results are summed. This
/// is the whole subtlety - a curve that priced the entire payment at the entry
/// rate would misprice a straddling buy.
///
/// Tiers advance on `raised` (not on tokens sold) so the rate keeps
/// `fixed_rate_curve`'s "tokens per payment unit" meaning - which lets tokens be
/// arbitrarily cheap (many per unit) and, more importantly, keeps every
/// allocation an exact integer sum with no division or rounding. Since `raised`
/// rises monotonically as inventory is drawn down, "tier up as the sale fills"
/// and "tier up as supply sells" describe the same schedule.
///
/// ### Why a separate module (the seam)
///
/// Struct fields are module-private, so only this module can construct a
/// `TieredRateCurve` witness, and therefore only this module can mint a
/// `Quote<..>` (via `prefunded_sale::mint_quote`) or an `ActivationTicket`
/// (via `prefunded_sale::mint_activation_ticket`) for a sale parameterized by
/// `TieredRateCurve`. A sale of that type can be driven by no other pricing
/// logic. The public `params` constructor is the seam an external protocol uses
/// to build the config without ever holding the witness.
///
/// ### Why `required_inventory` is the interesting part
///
/// `activation_ticket` must commit, up front, the inventory backing the curve
/// could ever draw: `required_inventory`. For `fixed_rate_curve` that is the
/// trivial `hard_cap * rate`. Here it is the integral of the step-rate over
/// `[0, hard_cap]` - `integrate(0, hard_cap)` below. Because that integral is an
/// *exact additive* sum (allocating `[0, a)` then `[a, hard_cap)` gives the same
/// total as allocating `[0, hard_cap)` in one go), two things hold:
///
/// - The total allocation is **path-independent**: however buyers split their
///   purchases, once `raised == hard_cap` the sale has allocated exactly
///   `required_inventory` tokens. Provisioned to that number, sold-out and
///   hard-cap-reached coincide, just as the core sale documents for an honest
///   curve.
/// - That commitment is the trust boundary made concrete. `prefunded_sale`
///   accepts this curve's `allocation` verbatim and only checks it against
///   `inventory - total_allocated` (`EInsufficientInventory`). A dishonest or
///   buggy curve that allocated more than `integrate(0, hard_cap)` over the sale
///   would strand its own final buyers on that check - the required-inventory
///   commitment is exactly what such a curve would have to respect. See the
///   package's `prefunded_sale_curve_trust_tests` for the core-side view.
///
/// ### Purchase
///
/// The buyer threads `quote + purchase` in the same PTB, just as with
/// `fixed_rate_curve`:
///
/// ```move
/// let quote = tiered_rate_curve::quote(&sale, payment.into_balance());
/// prefunded_sale::purchase(&mut sale, quote, allow, &clock, ctx);
/// ```
///
/// ### Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate how a
/// custom pricing curve integrates with the `prefunded_sale` primitive. It is
/// not production-ready and must not be deployed as-is.
module openzeppelin_sale::example_tiered_rate_curve;

use openzeppelin_sale::prefunded_sale::{PrefundedSale, ActivationTicket, Quote};
use sui::balance::Balance;

// === Errors ===

/// `params` was called with an empty `rates` vector; a curve needs at least one
/// tier.
#[error(code = 0)]
const ENoTiers: vector<u8> = "The curve must have at least one tier";

/// `params` was given `breakpoints` and `rates` of incompatible lengths;
/// `rates` must have exactly one more entry than `breakpoints` (the final rate
/// extends to the hard cap).
#[error(code = 1)]
const ETierShapeMismatch: vector<u8> =
    "There must be exactly one more rate than there are tier breakpoints";

/// `params` was given a tier with `rate == 0`; a zero rate allocates nothing for
/// any payment.
#[error(code = 2)]
const ERateZero: vector<u8> = "Every tier rate must be greater than zero";

/// `params` was given `breakpoints` that are not strictly increasing from a
/// positive first bound; tiers must partition the raise into non-empty bands.
#[error(code = 3)]
const ETierBoundsNotIncreasing: vector<u8> =
    "Tier breakpoints must be strictly increasing and start above zero";

/// The inventory the curve would back over `[0, hard_cap]` exceeds `u64::MAX`, so
/// it cannot be represented or guaranteed.
#[error(code = 4)]
const ERequiredInventoryOverflow: vector<u8> =
    "The required token inventory is too large to represent";

/// The allocation this curve prices for a payment exceeds `u64::MAX`, so it
/// cannot be represented.
#[error(code = 5)]
const EAllocationOverflow: vector<u8> = "The token allocation would be too large to represent";

// === Structs ===

/// Witness type for this curve. Field-less with `drop` only; its constructor is
/// module-private, so no other module can mint a `Quote`/`ActivationTicket` for a
/// `PrefundedSale<TieredRateCurve, ..>`.
public struct TieredRateCurve has drop {}

/// Tiered-rate parameters, stored on the sale via `prefunded_sale`'s
/// `curve_params` field.
///
/// `rates[i]` is the sale-tokens-per-payment-unit rate of tier `i`. `breakpoints`
/// holds the cumulative-`raised` thresholds between adjacent tiers, so
/// `rates.length() == breakpoints.length() + 1`: tier `0` applies while
/// `raised < breakpoints[0]`, tier `i` while
/// `breakpoints[i - 1] <= raised < breakpoints[i]`, and the last tier from
/// `breakpoints[last]` up to the hard cap.
public struct Params has copy, drop, store {
    /// Strictly-increasing cumulative-`raised` thresholds separating the tiers.
    breakpoints: vector<u64>,
    /// Per-tier token-per-payment rates; one longer than `breakpoints`.
    rates: vector<u64>,
}

// === Public Functions ===

// === Constructors ===

/// Build a validated `Params`. The only way to obtain a `Params` outside this
/// module (its fields are module-private), mirroring `fixed_rate_curve::params`.
///
/// #### Parameters
/// - `breakpoints`: Strictly-increasing cumulative-`raised` thresholds between
///   tiers. Empty for a single-tier (flat) curve.
/// - `rates`: Token-per-payment rate of each tier; must be exactly one longer
///   than `breakpoints`, and every entry must be positive.
///
/// #### Returns
/// - A validated `Params` carrying the tier schedule.
///
/// #### Aborts
/// - `ENoTiers` if `rates` is empty.
/// - `ETierShapeMismatch` if `rates.length() != breakpoints.length() + 1`.
/// - `ERateZero` if any `rate == 0`.
/// - `ETierBoundsNotIncreasing` if `breakpoints` is not strictly increasing from
///   a positive first bound.
public fun params(breakpoints: vector<u64>, rates: vector<u64>): Params {
    assert!(!rates.is_empty(), ENoTiers);
    assert!(rates.length() == breakpoints.length() + 1, ETierShapeMismatch);

    rates.do_ref!(|rate| assert!(*rate > 0, ERateZero));

    let mut prev = 0;
    breakpoints.do_ref!(|bound| {
        assert!(*bound > prev, ETierBoundsNotIncreasing);
        prev = *bound;
    });

    Params { breakpoints, rates }
}

/// Mint the `ActivationTicket<TieredRateCurve>` that `share_and_activate`
/// consumes, committing the inventory backing this curve requires: the token
/// allocation the schedule prices over the whole raise, `integrate(0, hard_cap)`.
///
/// #### Parameters
/// - `sale`: The sale to activate, read for its `hard_cap` and tier schedule.
///
/// #### Returns
/// - An `ActivationTicket<TieredRateCurve>` carrying the required inventory.
///
/// #### Aborts
/// - `ERequiredInventoryOverflow` if the backing over `[0, hard_cap]` would
///   exceed `u64::MAX`.
public fun activation_ticket<
    SaleCoin,
    PaymentCoin,
    VestingWitness: drop,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<
        TieredRateCurve,
        Params,
        SaleCoin,
        PaymentCoin,
        VestingWitness,
        VestingScheduleParams,
    >,
): ActivationTicket<TieredRateCurve> {
    let required_inventory = integrate(&sale.curve_params(), 0, sale.hard_cap());
    assert!(required_inventory <= (std::u64::max_value!() as u128), ERequiredInventoryOverflow);
    sale.mint_activation_ticket(TieredRateCurve {}, required_inventory as u64)
}

// === Quote ===

/// Mint a `Quote<PaymentCoin>` for a buyer's `balance`. The allocation is the
/// step-rate integral over `[raised, raised + balance.value())` - i.e. the
/// payment is priced per tier band it spans, at that band's rate. The `Quote`
/// carries the balance through to `purchase`.
///
/// #### Parameters
/// - `sale`: The sale being purchased from, read for its current `raised` and
///   tier schedule.
/// - `balance`: The buyer's payment, moved into the returned `Quote`.
///
/// #### Returns
/// - A single-use `Quote<PaymentCoin>` bound to `sale`, carrying both `balance`
///   and the computed allocation.
///
/// #### Aborts
/// - `EAllocationOverflow` if the priced allocation would exceed `u64::MAX`.
/// - `prefunded_sale::EZeroPayment` if `balance` has zero value.
/// - `prefunded_sale::EZeroAllocation` if the computed allocation is zero;
///   unreachable here since every rate is positive and a non-zero payment spans
///   at least one band.
public fun quote<
    SaleCoin,
    PaymentCoin,
    VestingWitness: drop,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<
        TieredRateCurve,
        Params,
        SaleCoin,
        PaymentCoin,
        VestingWitness,
        VestingScheduleParams,
    >,
    balance: Balance<PaymentCoin>,
): Quote<PaymentCoin> {
    let allocation = integrate(&sale.curve_params(), sale.raised(), balance.value());
    assert!(allocation <= (std::u64::max_value!() as u128), EAllocationOverflow);
    sale.mint_quote(TieredRateCurve {}, balance, allocation as u64)
}

// === View helpers ===

/// The marginal rate at the sale's current `raised` - the rate the next unit of
/// payment would price at. The tiered analogue of `fixed_rate_curve::rate`.
///
/// #### Parameters
/// - `sale`: The sale to query.
///
/// #### Returns
/// - The token-per-payment rate of the tier containing `raised`.
public fun marginal_rate<
    SaleCoin,
    PaymentCoin,
    VestingWitness: drop,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<
        TieredRateCurve,
        Params,
        SaleCoin,
        PaymentCoin,
        VestingWitness,
        VestingScheduleParams,
    >,
): u64 {
    let params = sale.curve_params();
    params.rates[tier_index(&params, sale.raised())]
}

/// The configured tier breakpoints (cumulative-`raised` thresholds).
public fun breakpoints<
    SaleCoin,
    PaymentCoin,
    VestingWitness: drop,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<
        TieredRateCurve,
        Params,
        SaleCoin,
        PaymentCoin,
        VestingWitness,
        VestingScheduleParams,
    >,
): vector<u64> {
    sale.curve_params().breakpoints
}

/// The configured per-tier rates.
public fun rates<
    SaleCoin,
    PaymentCoin,
    VestingWitness: drop,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<
        TieredRateCurve,
        Params,
        SaleCoin,
        PaymentCoin,
        VestingWitness,
        VestingScheduleParams,
    >,
): vector<u64> {
    sale.curve_params().rates
}

// === Private Functions ===

/// The step-rate allocation for a payment of `paid` made when cumulative raised
/// is `from_raised`: the sum, over every tier band the payment interval
/// `[from_raised, from_raised + paid)` overlaps, of `overlap * rate`.
///
/// Returned as `u128` (callers bounds-check against `u64::MAX` with their own
/// typed error, mirroring `fixed_rate_curve`). No overflow is possible here: the
/// overlaps partition an interval of width `paid <= u64::MAX`, so each
/// `overlap * rate` term is below `2^128`, and their sum is at most
/// `paid * max_rate`, still below `2^128`.
fun integrate(params: &Params, from_raised: u64, paid: u64): u128 {
    let from = from_raised as u128;
    let end = from + (paid as u128);

    let n = params.rates.length();
    let mut lo: u128 = 0;
    let mut alloc: u128 = 0;
    let mut i = 0;
    loop {
        // The last tier extends to the hard cap; clamp its upper edge to `end`.
        let hi = if (i + 1 == n) end
        else (params.breakpoints[i] as u128);

        let seg_lo = if (lo > from) lo else from;
        let seg_hi = if (hi < end) hi else end;
        if (seg_hi > seg_lo) {
            alloc = alloc + (seg_hi - seg_lo) * (params.rates[i] as u128);
        };

        // Once a tier reaches `end`, every higher tier is entirely above the
        // payment interval and contributes nothing.
        if (hi >= end) break;
        lo = hi;
        i = i + 1;
    };
    alloc
}

/// Index of the tier containing `raised`: the number of breakpoints at or below
/// it. `raised == hard_cap` maps to the last tier.
fun tier_index(params: &Params, raised: u64): u64 {
    let mut i = 0;
    let bps = &params.breakpoints;
    while (i < bps.length() && raised >= bps[i]) i = i + 1;
    i
}

/// Fixed-rate pricing curve for `prefunded_sale`: `allocation = paid *
/// rate_numerator / rate_denominator` (widened and floored) for every purchase,
/// for the whole sale.
///
/// The simplest pricing shape and the one most sales use. The rate is a fraction
/// committed at sale construction and never changes, so the activation backing
/// this curve commits to (`required_inventory = hard_cap * rate_numerator /
/// rate_denominator`, via `activation_ticket`) is a tight cover.
///
/// This module declares the `FixedRateCurve` witness and its `Params`, plus
/// the integrator API around them (`params` / `activation_ticket` / `quote`
/// / `rate`). It mirrors `vesting_wallet_linear`'s relationship to
/// `vesting_wallet`: `params` validates and builds the config the integrator
/// hands to `prefunded_sale::create_sale`, `activation_ticket` derives the
/// inventory backing for `share_and_activate`, and `quote` is the only place
/// a `Quote` for a `FixedRateCurve` sale can be minted.
///
/// ### Why a separate module
///
/// Struct fields are module-private, so only this module can construct a
/// `FixedRateCurve` witness, and therefore only this module can mint a
/// `Quote<FixedRateCurve>` (via `prefunded_sale::mint_quote`). A sale parameterized by
/// `FixedRateCurve` can be driven by no other pricing logic. The public
/// `params` constructor is the seam an external protocol can use to build the
/// config without surrendering the witness.
///
/// ### Purchase
///
/// The buyer threads `quote + purchase` in the same PTB. `quote` takes
/// the payment as a `Balance` (the `Quote` carries it through to
/// `purchase`); `purchase` consumes the quote and delivers a `Receipt`
/// to the buyer:
///
/// ```move
/// let quote = fixed_rate_curve::quote(&sale, payment.into_balance());
/// prefunded_sale::purchase(&mut sale, quote, allow, &clock, ctx);
/// ```
module openzeppelin_sale::fixed_rate_curve;

use openzeppelin_math::rounding;
use openzeppelin_math::u64;
use openzeppelin_sale::prefunded_sale::{PrefundedSale, ActivationTicket, Quote};
use sui::balance::Balance;

// === Errors ===

/// `params` was called with `rate_numerator == 0`; a zero numerator allocates
/// nothing for any payment.
#[error(code = 0)]
const ERateZero: vector<u8> = "The exchange rate numerator must be greater than zero";

/// `hard_cap * rate_numerator / rate_denominator` would exceed `u64::MAX`, so the
/// required inventory backing cannot be represented or guaranteed.
#[error(code = 1)]
const ERequiredInventoryOverflow: vector<u8> =
    "The required token inventory is too large to represent";

/// `paid * rate_numerator / rate_denominator` would exceed `u64::MAX`, so the
/// allocation this curve prices cannot be represented.
#[error(code = 2)]
const EAllocationOverflow: vector<u8> = "The token allocation would be too large to represent";

/// `params` was called with `rate_denominator == 0`; the allocation is divided by
/// it.
#[error(code = 3)]
const EDenominatorZero: vector<u8> = "The exchange rate denominator must be greater than zero";

// === Structs ===

/// Witness type for this curve. Field-less with `drop` only; its
/// constructor is module-private, so no other module can mint a
/// `Quote<FixedRateCurve>`.
public struct FixedRateCurve has drop {}

/// Fixed-rate parameters, stored on the sale via `prefunded_sale`'s
/// `curve_params` field.
public struct Params has copy, drop, store {
    /// Numerator of the exchange rate. The allocation for a payment is `paid *
    /// rate_numerator / rate_denominator`, floored - sale tokens (smallest units)
    /// allocated per `rate_denominator` payment-coin smallest units.
    rate_numerator: u64,
    /// Denominator of the exchange rate; non-zero.
    rate_denominator: u64,
}

// === Public Functions ===

// === Constructors ===

/// Build a validated `Params`. The only way to obtain a `Params` outside this
/// module (its field is module-private), so a protocol that drives
/// `prefunded_sale::create_sale` directly can build the config itself.
///
/// The allocation for a payment is `paid * rate_numerator / rate_denominator`,
/// widened to `u128` and floored. Expressing the rate as a fraction lets a sale
/// price a sale token at any ratio to the payment coin, on any decimal pairing:
/// e.g. a 0.30 payment-per-sale-token price on an equal-decimal pair is
/// `params(10, 3)` (a payment of 3 smallest units allocates 10). Division floors,
/// so a payment too small to allocate a whole smallest unit rounds down, and one
/// that floors to zero is rejected by `prefunded_sale::EZeroAllocation`. Rounding
/// down favors the sale's inventory backing, which `activation_ticket` sizes with
/// the same floored arithmetic.
///
/// #### Parameters
/// - `rate_numerator`: Numerator of the sale-token-per-payment rate.
/// - `rate_denominator`: Denominator of the rate.
///
/// #### Returns
/// - A validated `Params` carrying the rate.
///
/// #### Aborts
/// - `ERateZero` if `rate_numerator == 0`.
/// - `EDenominatorZero` if `rate_denominator == 0`.
public fun params(rate_numerator: u64, rate_denominator: u64): Params {
    assert!(rate_numerator > 0, ERateZero);
    assert!(rate_denominator > 0, EDenominatorZero);
    Params { rate_numerator, rate_denominator }
}

/// Mint the `ActivationTicket<FixedRateCurve>` that `share_and_activate` consumes,
/// committing the inventory backing this curve requires: `hard_cap *
/// rate_numerator / rate_denominator` (floored). This is a tight cover: because
/// each purchase's allocation floors, the sum of per-purchase allocations never
/// exceeds this floored total.
///
/// #### Parameters
/// - `sale`: The sale to activate, read for its `hard_cap` and configured rate.
///
/// #### Returns
/// - An `ActivationTicket<FixedRateCurve>` carrying `hard_cap * rate_numerator /
///   rate_denominator` as the required inventory.
///
/// #### Aborts
/// - `ERequiredInventoryOverflow` if `hard_cap * rate_numerator / rate_denominator`
///   would exceed `u64::MAX`.
public fun activation_ticket<
    SaleCoin,
    PaymentCoin,
    VestingWitness: drop,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<
        FixedRateCurve,
        Params,
        SaleCoin,
        PaymentCoin,
        VestingWitness,
        VestingScheduleParams,
    >,
): ActivationTicket<FixedRateCurve> {
    let params = sale.curve_params();
    let required_inventory = u64::mul_div(
        sale.hard_cap(),
        params.rate_numerator,
        params.rate_denominator,
        rounding::down(),
    );
    assert!(required_inventory.is_some(), ERequiredInventoryOverflow);
    sale.mint_activation_ticket(FixedRateCurve {}, required_inventory.destroy_some())
}

// === Quote ===

/// Mint a `Quote<PaymentCoin>` for a buyer's `balance`. This curve computes the
/// allocation as `balance.value() * rate_numerator / rate_denominator`, widened to
/// `u128` and floored, and hands the finished `u64` to
/// `prefunded_sale::mint_quote`. The `Quote` carries the balance through to
/// `purchase`.
///
/// #### Parameters
/// - `sale`: The sale being purchased from, read for its configured rate.
/// - `balance`: The buyer's payment, moved into the returned `Quote`.
///
/// #### Returns
/// - A single-use `Quote<PaymentCoin>` bound to `sale`, carrying both `balance` and
///   the computed allocation.
///
/// #### Aborts
/// - `EAllocationOverflow` if `balance.value() * rate_numerator / rate_denominator`
///   would exceed `u64::MAX`.
/// - `prefunded_sale::EZeroPayment` if `balance` has zero value.
/// - `prefunded_sale::EZeroAllocation` if the floored allocation is zero - a
///   payment too small to allocate one whole sale-token smallest unit at this
///   rate (i.e. `balance.value() * rate_numerator < rate_denominator`).
public fun quote<
    SaleCoin,
    PaymentCoin,
    VestingWitness: drop,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<
        FixedRateCurve,
        Params,
        SaleCoin,
        PaymentCoin,
        VestingWitness,
        VestingScheduleParams,
    >,
    balance: Balance<PaymentCoin>,
): Quote<PaymentCoin> {
    let params = sale.curve_params();
    let required_inventory = u64::mul_div(
        balance.value(),
        params.rate_numerator,
        params.rate_denominator,
        rounding::down(),
    );
    assert!(allocation <= (std::u64::max_value!() as u128), EAllocationOverflow);
    sale.mint_quote(FixedRateCurve {}, balance, allocation as u64)
}

// === View helpers ===

/// The configured fixed rate as `(rate_numerator, rate_denominator)`: the
/// allocation for a payment is `paid * rate_numerator / rate_denominator`.
///
/// #### Parameters
/// - `sale`: The sale to query.
///
/// #### Returns
/// - The configured rate as `(rate_numerator, rate_denominator)`.
public fun rate<
    SaleCoin,
    PaymentCoin,
    VestingWitness: drop,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<
        FixedRateCurve,
        Params,
        SaleCoin,
        PaymentCoin,
        VestingWitness,
        VestingScheduleParams,
    >,
): (u64, u64) {
    let params = sale.curve_params();
    (params.rate_numerator, params.rate_denominator)
}

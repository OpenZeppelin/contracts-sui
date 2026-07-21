/// Fixed-rate pricing curve for `prefunded_sale`: `allocation = paid * rate`
/// for every purchase, for the whole sale.
///
/// The simplest pricing shape and the one most sales use. The rate is
/// committed at sale construction and never changes, so the activation
/// backing this curve commits to (`required_inventory = hard_cap * rate`,
/// via `activation_ticket`) is a tight cover.
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
/// `Quote<FixedRateCurve>` (via `prefunded_sale::mint_quote_unversioned`). A sale
/// parameterized by `FixedRateCurve` can be driven by no other pricing logic. The
/// public `params` constructor is the seam an external protocol can use to build the
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

use openzeppelin_sale::prefunded_sale::{PrefundedSale, ActivationTicket, Quote};
use sui::balance::Balance;

// === Errors ===

/// `params` was called with `rate == 0`; a zero rate allocates nothing for any
/// payment.
#[error(code = 0)]
const ERateZero: vector<u8> = "The exchange rate must be greater than zero";

/// `hard_cap * rate` would exceed `u64::MAX`, so the required inventory backing
/// cannot be represented or guaranteed.
#[error(code = 1)]
const ERequiredInventoryOverflow: vector<u8> =
    "The required token inventory is too large to represent";

/// `paid * rate` would exceed `u64::MAX`, so the allocation this curve prices
/// cannot be represented.
#[error(code = 2)]
const EAllocationOverflow: vector<u8> = "The token allocation would be too large to represent";

// === Structs ===

/// Witness type for this curve. Field-less with `drop` only; its
/// constructor is module-private, so no other module can mint a
/// `Quote<FixedRateCurve>`.
public struct FixedRateCurve has drop {}

/// Fixed-rate parameters, stored on the sale via `prefunded_sale`'s
/// `curve_params` field.
public struct Params has copy, drop, store {
    /// Sale tokens (smallest units) per 1 payment-coin smallest unit.
    rate: u64,
}

// === Public Functions ===

// === Constructors ===

/// Build a validated `Params`. The only way to obtain a `Params` outside this
/// module (its field is module-private), so a protocol that drives
/// `prefunded_sale::create_sale` directly can build the config itself.
///
/// #### Price envelope
///
/// This curve prices every purchase as `allocation = paid * rate` with an integer
/// `rate >= 1`, so the allocation is never smaller than the payment measured in
/// smallest units. In human terms, the price of one sale token denominated in
/// payment coin is `10^(sale_decimals - payment_decimals) / rate`. Two limits
/// follow, and an integrator must configure `rate` around both:
///
/// - Ceiling: `rate` cannot drop below 1, so the price cannot exceed
///   `10^(sale_decimals - payment_decimals)`. For a sale/payment pair with equal
///   decimals that ceiling is exactly 1 payment token per sale token.
/// - Grid: only reciprocal-integer fractions of the ceiling are exact (`1/1`,
///   `1/2`, `1/3`, ... of it). A price off that grid must be approximated by the
///   nearest integer `rate`, which misprices every purchase silently, with no
///   abort and no event.
///
/// Worked example (equal decimals, e.g. a token sold against a same-decimal
/// stablecoin, so the ceiling is 1.00): a 5.00 target is unreachable - it sits
/// above the ceiling, and the nearest configurable prices are 1.00 (`rate = 1`)
/// and 0.50 (`rate = 2`). Below the ceiling, 0.20 is exact (`rate = 5`) but 0.30
/// is not - the nearest are 0.333.. (`rate = 3`) and 0.25 (`rate = 4`).
///
/// An integrator needing an off-grid price on a given decimal pairing should not
/// fork this curve but supply its own: the sale applies the curve-computed
/// `allocation` verbatim (see `prefunded_sale::mint_quote`), so a custom curve
/// can compute the allocation directly - e.g. with a widened division and an
/// explicit rounding mode - and express any price on any decimal pairing, free of
/// this grid.
///
/// #### Parameters
/// - `rate`: Sale tokens (smallest units) allocated per 1 payment-coin smallest
///   unit.
///
/// #### Returns
/// - A validated `Params` carrying `rate`.
///
/// #### Aborts
/// - `ERateZero` if `rate == 0`.
public fun params(rate: u64): Params {
    assert!(rate > 0, ERateZero);
    Params { rate }
}

/// Mint the `ActivationTicket<FixedRateCurve>` that `share_and_activate` consumes,
/// committing the inventory backing this curve requires: `hard_cap * rate`.
///
/// #### Parameters
/// - `sale`: The sale to activate, read for its `hard_cap` and configured `rate`.
///
/// #### Returns
/// - An `ActivationTicket<FixedRateCurve>` carrying `hard_cap * rate` as the required
///   inventory.
///
/// #### Aborts
/// - `ERequiredInventoryOverflow` if `hard_cap * rate` would exceed `u64::MAX`.
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
    let rate = sale.curve_params().rate;
    let required_inventory = (sale.hard_cap() as u128) * (rate as u128);
    assert!(required_inventory <= (std::u64::max_value!() as u128), ERequiredInventoryOverflow);
    sale.mint_activation_ticket(FixedRateCurve {}, required_inventory as u64)
}

// === Quote ===

/// Mint a `Quote<PaymentCoin>` for a buyer's `balance`. This curve computes the
/// allocation as `balance.value() * rate`, u128-widened to detect overflow, and
/// hands the finished `u64` to `prefunded_sale::mint_quote_unversioned`, letting
/// a buyer mint and purchase several quotes in one PTB. The `Quote` carries the
/// balance through to `purchase`.
///
/// #### Parameters
/// - `sale`: The sale being purchased from, read for its configured `rate`.
/// - `balance`: The buyer's payment, moved into the returned `Quote`.
///
/// #### Returns
/// - A single-use `Quote<PaymentCoin>` bound to `sale`, carrying both `balance` and
///   the computed allocation.
///
/// #### Aborts
/// - `EAllocationOverflow` if `balance.value() * rate` would exceed `u64::MAX`.
/// - `prefunded_sale::EZeroPayment` if `balance` has zero value.
/// - `prefunded_sale::EZeroAllocation` if the computed allocation is zero;
///   guarded as unreachable here since `rate > 0` and a non-zero `balance` value
///   yield a positive product.
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
    let rate = sale.curve_params().rate;
    let allocation = (balance.value() as u128) * (rate as u128);
    assert!(allocation <= (std::u64::max_value!() as u128), EAllocationOverflow);
    sale.mint_quote_unversioned(FixedRateCurve {}, balance, allocation as u64)
}

// === View helpers ===

/// The configured fixed rate: sale tokens allocated per 1 payment-coin unit.
///
/// #### Parameters
/// - `sale`: The sale to query.
///
/// #### Returns
/// - The configured rate.
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
): u64 {
    sale.curve_params().rate
}

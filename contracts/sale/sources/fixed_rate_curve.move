/// Fixed-rate pricing curve for `prefunded_sale`: `allocation = paid * rate`
/// for every purchase, for the whole sale.
///
/// The simplest pricing shape and the one most sales use. The rate is
/// committed at sale construction and never changes, so the sale's
/// `max_rate` equals this curve's `rate` and the activation-time inventory
/// backing (`inventory >= hard_cap * max_rate`) is a tight cover.
///
/// This module declares the `FixedRateCurve` witness and its `Params`, plus
/// the integrator API around them (`params` / `create_sale` / `quote` /
/// `rate`). It mirrors `vesting_wallet_linear`'s relationship to
/// `vesting_wallet`: `params` validates and builds the config, `create_sale`
/// is sugar that hands that config to `prefunded_sale::create_sale` (deriving
/// `max_rate` from it so the two cannot drift), and `quote` is the only place
/// a `Quote<FixedRateCurve>` can be minted.
///
/// ### Why a separate module
///
/// Struct fields are module-private, so only this module can construct a
/// `FixedRateCurve` witness, and therefore only this module can mint a
/// `Quote<FixedRateCurve>` (via `sale::mint_quote`). A sale parameterized by
/// `FixedRateCurve` can be driven by no other pricing logic. The public
/// `params` constructor is the seam an external protocol can use to build the
/// config without surrendering the witness.
///
/// ### Purchase
///
/// The buyer threads `quote + purchase` in the same PTB:
///
/// ```move
/// let quote = fixed_rate_curve::quote(&sale, paid);
/// prefunded_sale::purchase(&mut sale, payment, quote, allow, &clock, ctx);
/// ```
module openzeppelin_sale::fixed_rate_curve;

use openzeppelin_sale::prefunded_sale::{Self, PrefundedSale, SaleAdminCap, ActivationTicket, Quote};

// === Errors ===

#[error(code = 0)]
const ERateZero: vector<u8> = "rate must be greater than zero";
#[error(code = 1)]
const EAllocationOverflow: vector<u8> = "paid * rate overflows u64";
#[error(code = 2)]
const ERequiredInventoryOverflow: vector<u8> =
    "Required inventory would overflow u64; cannot guarantee inventory backing";

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

// === Constructors ===

/// Build a validated `Params`. The only way to obtain a `Params` outside
/// this module (its field is module-private), so a protocol that drives
/// `prefunded_sale::create_sale` directly can build the config itself.
///
/// Aborts with `ERateZero` if `rate == 0`.
public fun params(rate: u64): Params {
    assert!(rate > 0, ERateZero);
    Params { rate }
}

public fun mint_activation_ticket<
    SaleCoin,
    PaymentCoin,
    VestingScheduleParams: copy + drop + store,
>(
    sale: &PrefundedSale<FixedRateCurve, Params, SaleCoin, PaymentCoin, VestingScheduleParams>,
): ActivationTicket<FixedRateCurve> {
    let rate = sale.curve_params().rate;
    let required_inventory = (sale.hard_cap() as u128) * (rate as u128);
    assert!(required_inventory <= (std::u64::max_value!() as u128), ERequiredInventoryOverflow);
    sale.mint_activation_ticket(FixedRateCurve {}, required_inventory as u64)
}

// === Quote ===

/// Mint a `Quote<FixedRateCurve>` for a buyer paying `paid` units. The
/// allocation is `paid * rate`, u128-widened to detect overflow.
public fun quote<SaleCoin, PaymentCoin, VestingScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<FixedRateCurve, Params, SaleCoin, PaymentCoin, VestingScheduleParams>,
    paid: u64,
): Quote<FixedRateCurve> {
    let rate = sale.curve_params().rate;
    let alloc = (paid as u128) * (rate as u128);
    assert!(alloc <= (std::u64::max_value!() as u128), EAllocationOverflow);
    sale.mint_quote(FixedRateCurve {}, paid, alloc as u64)
}

// === Views ===

/// The configured fixed rate.
public fun rate<SaleCoin, PaymentCoin, VestingScheduleParams: copy + drop + store>(
    sale: &PrefundedSale<FixedRateCurve, Params, SaleCoin, PaymentCoin, VestingScheduleParams>,
): u64 {
    sale.curve_params().rate
}

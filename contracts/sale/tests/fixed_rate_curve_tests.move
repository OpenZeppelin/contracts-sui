// Fixed-rate curve tests (rate validation, fractional pricing, overflow guards,
// carrier minting).
//
// The curve is the only module that can mint a `Quote`/`ActivationTicket` for a
// `PrefundedSale<FixedRateCurve, ...>` (witness-gated). These tests pin its
// pricing math (`allocation = paid * rate_numerator / rate_denominator`,
// `required_inventory = hard_cap * rate_numerator / rate_denominator`, both
// floored), the flooring-to-zero guard, and the u128 overflow guards.
module openzeppelin_sale::fixed_rate_curve_tests;

use openzeppelin_finance::vesting_wallet_linear::{Linear, Params as VParams};
use openzeppelin_sale::fixed_rate_curve::{Self, FixedRateCurve, Params as FrcParams};
use openzeppelin_sale::prefunded_sale::{Self, PrefundedSale};
use openzeppelin_sale::test_utils::{Self as u, SALE, USDC};
use std::unit_test::{assert_eq, destroy};

const MAX_U64: u64 = 18_446_744_073_709_551_615;

fun new_sale(
    rate_numerator: u64,
    rate_denominator: u64,
    hard_cap: u64,
    ctx: &mut TxContext,
): (
    PrefundedSale<FixedRateCurve, FrcParams, SALE, USDC, Linear, VParams>,
    prefunded_sale::SaleAdminCap<SALE, USDC>,
) {
    prefunded_sale::create_sale<FixedRateCurve, FrcParams, SALE, USDC, Linear, VParams>(
        fixed_rate_curve::params(rate_numerator, rate_denominator),
        hard_cap,
        0,
        1_000,
        5_000,
        ctx,
    )
}

// === params ===

#[test, expected_failure(abort_code = fixed_rate_curve::ERateZero)]
fun params_rejects_zero_numerator() {
    let _ = fixed_rate_curve::params(0, 1); // aborts
}

#[test, expected_failure(abort_code = fixed_rate_curve::EDenominatorZero)]
fun params_rejects_zero_denominator() {
    let _ = fixed_rate_curve::params(1, 0); // aborts
}

// === quote pricing + guards ===

// Integer rate (denominator 1): allocation = paid * numerator.
#[test]
fun quote_allocation_is_paid_times_rate() {
    let mut ctx = tx_context::dummy();
    let (sale, cap) = new_sale(3, 1, 1_000, &mut ctx);

    let q = fixed_rate_curve::quote(&sale, u::pay_balance(100));
    assert_eq!(q.allocation(), 300);
    assert_eq!(q.sale_id(), object::id(&sale));
    assert_eq!(q.payment().value(), 100);

    destroy(q);
    destroy(sale);
    destroy(cap);
}

// Fractional rate: allocation = floor(paid * numerator / denominator). A payment
// of 5 at 10/3 allocates floor(50/3) = 16.
#[test]
fun quote_allocation_is_floored_fraction() {
    let mut ctx = tx_context::dummy();
    let (sale, cap) = new_sale(10, 3, 1_000, &mut ctx);

    let q = fixed_rate_curve::quote(&sale, u::pay_balance(5));
    assert_eq!(q.allocation(), 16); // floor(50 / 3)

    destroy(q);
    destroy(sale);
    destroy(cap);
}

// A rate with numerator < denominator prices a sale token above one payment unit -
// the region the old integer-rate curve could not express. At 1/5, a payment of
// 100 allocates 20 (price of 5.00 payment per sale token on an equal-decimal pair).
#[test]
fun quote_prices_above_the_old_ceiling() {
    let mut ctx = tx_context::dummy();
    let (sale, cap) = new_sale(1, 5, 1_000, &mut ctx);

    let q = fixed_rate_curve::quote(&sale, u::pay_balance(100));
    assert_eq!(q.allocation(), 20); // floor(100 / 5)

    destroy(q);
    destroy(sale);
    destroy(cap);
}

// A payment too small to allocate a whole smallest unit floors to zero and is
// rejected by the sale's non-zero-allocation guard.
#[test, expected_failure(abort_code = prefunded_sale::EZeroAllocation)]
fun quote_flooring_to_zero_aborts() {
    let mut ctx = tx_context::dummy();
    let (sale, _cap) = new_sale(1, 10, 1_000, &mut ctx);
    let _q = fixed_rate_curve::quote(&sale, u::pay_balance(5)); // floor(5 / 10) = 0
    abort
}

// A zero-value payment is rejected at quote time.
#[test, expected_failure(abort_code = prefunded_sale::EZeroPayment)]
fun quote_rejects_zero_payment() {
    let mut ctx = tx_context::dummy();
    let (sale, _cap) = new_sale(3, 1, 1_000, &mut ctx);
    let _q = fixed_rate_curve::quote(&sale, u::pay_balance(0)); // aborts
    abort
}

// allocation = paid * numerator / denominator overflowing u64 aborts with a typed
// error.
#[test, expected_failure(abort_code = fixed_rate_curve::EAllocationOverflow)]
fun quote_allocation_overflow_aborts() {
    let mut ctx = tx_context::dummy();
    let (sale, _cap) = new_sale(MAX_U64, 1, 1_000, &mut ctx);
    let _q = fixed_rate_curve::quote(&sale, u::pay_balance(2)); // 2 * MAX overflows
    abort
}

// Boundary of the overflow guard: an allocation equal to u64::MAX is representable,
// so the guard admits it (no off-by-one). Pins quote / when paid * numerator /
// denominator == u64::MAX / it succeeds.
#[test]
fun quote_allocation_at_u64_max_succeeds() {
    let mut ctx = tx_context::dummy();
    let (sale, cap) = new_sale(MAX_U64, 1, 1_000, &mut ctx);

    let q = fixed_rate_curve::quote(&sale, u::pay_balance(1)); // 1 * MAX / 1 == MAX, fits
    assert_eq!(q.allocation(), MAX_U64);

    destroy(q);
    destroy(sale);
    destroy(cap);
}

// === activation ticket sizing + guard ===

#[test]
fun activation_ticket_requires_hard_cap_times_rate() {
    let mut ctx = tx_context::dummy();
    let (sale, cap) = new_sale(4, 1, 1_000, &mut ctx);
    // required_inventory = 1_000 * 4 / 1 = 4_000; mint succeeds (carrier has no
    // abilities so we just dispose of it).
    let ticket = fixed_rate_curve::activation_ticket(&sale);
    assert_eq!(ticket.required_inventory(), 4_000); // 1_000 * 4 / 1
    destroy(ticket);
    destroy(sale);
    destroy(cap);
}

// required_inventory floors the fraction just like the per-purchase allocation, so
// the backing is a tight cover: hard_cap 100 at 10/3 requires floor(1000/3) = 333.
#[test]
fun activation_ticket_floors_fractional_backing() {
    let mut ctx = tx_context::dummy();
    let (sale, cap) = new_sale(10, 3, 100, &mut ctx);
    let ticket = fixed_rate_curve::activation_ticket(&sale);
    assert_eq!(ticket.required_inventory(), 333); // floor(1000 / 3)
    destroy(ticket);
    destroy(sale);
    destroy(cap);
}

// required_inventory = hard_cap * numerator / denominator overflowing u64 aborts.
#[test, expected_failure(abort_code = fixed_rate_curve::ERequiredInventoryOverflow)]
fun activation_ticket_overflow_aborts() {
    let mut ctx = tx_context::dummy();
    let (sale, _cap) = new_sale(2, 1, MAX_U64, &mut ctx); // MAX * 2 overflows
    let _ticket = fixed_rate_curve::activation_ticket(&sale);
    abort
}

// Boundary of the overflow guard: a required inventory equal to u64::MAX is
// representable, so the guard admits it (no off-by-one). Pins activation_ticket /
// when hard_cap * numerator / denominator == u64::MAX / it succeeds.
#[test]
fun activation_ticket_at_u64_max_succeeds() {
    let mut ctx = tx_context::dummy();
    let (sale, cap) = new_sale(1, 1, MAX_U64, &mut ctx); // MAX * 1 / 1 == MAX, fits
    let ticket = fixed_rate_curve::activation_ticket(&sale);
    assert_eq!(ticket.required_inventory(), MAX_U64);
    destroy(ticket);
    destroy(sale);
    destroy(cap);
}

// === rate view ===

#[test]
fun rate_view_returns_configured_rate() {
    let mut ctx = tx_context::dummy();
    let (sale, cap) = new_sale(7, 2, 1_000, &mut ctx);
    let (numerator, denominator) = fixed_rate_curve::rate(&sale);
    assert_eq!(numerator, 7);
    assert_eq!(denominator, 2);
    destroy(sale);
    destroy(cap);
}

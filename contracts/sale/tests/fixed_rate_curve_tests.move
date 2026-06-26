// Fixed-rate curve tests (rate>0, overflow guards, carrier minting).
//
// The curve is the only module that can mint a `Quote`/`ActivationTicket` for a
// `PrefundedSale<FixedRateCurve, ...>` (witness-gated). These tests pin
// its pricing math (`allocation = paid * rate`, `required_inventory =
// hard_cap * rate`) and the u128 overflow guards on both.
module openzeppelin_sale::fixed_rate_curve_tests;

use openzeppelin_finance::vesting_wallet_linear::Params as VParams;
use openzeppelin_sale::fixed_rate_curve::{Self, FixedRateCurve, Params as FrcParams};
use openzeppelin_sale::prefunded_sale::{Self, PrefundedSale};
use openzeppelin_sale::test_utils::{Self as tu, SALE, USDC};
use std::unit_test::{assert_eq, destroy};

const MAX_U64: u64 = 18_446_744_073_709_551_615;

fun new_sale(
    rate: u64,
    hard_cap: u64,
    ctx: &mut TxContext,
): (
    PrefundedSale<FixedRateCurve, FrcParams, SALE, USDC, VParams>,
    prefunded_sale::SaleAdminCap<SALE, USDC>,
) {
    prefunded_sale::create_sale<FixedRateCurve, FrcParams, SALE, USDC, VParams>(
        fixed_rate_curve::params(rate),
        hard_cap,
        0,
        1_000,
        5_000,
        ctx,
    )
}

// === params ===

#[test, expected_failure(abort_code = fixed_rate_curve::ERateZero)]
fun params_rejects_zero_rate() {
    let _ = fixed_rate_curve::params(0); // aborts
}

// === quote pricing + guards ===

#[test]
fun quote_allocation_is_paid_times_rate() {
    let mut ctx = tx_context::dummy();
    let (sale, cap) = new_sale(3, 1_000, &mut ctx);

    let q = fixed_rate_curve::quote(&sale, tu::pay_balance(100));
    assert_eq!(q.allocation(), 300);
    assert_eq!(q.sale_id(), object::id(&sale));
    assert_eq!(q.payment().value(), 100);

    destroy(q);
    destroy(sale);
    destroy(cap);
}

// A zero-value payment is rejected at quote time.
#[test, expected_failure(abort_code = prefunded_sale::EZeroPayment)]
fun quote_rejects_zero_payment() {
    let mut ctx = tx_context::dummy();
    let (sale, cap) = new_sale(3, 1_000, &mut ctx);
    let q = fixed_rate_curve::quote(&sale, tu::pay_balance(0)); // aborts
    destroy(q);
    destroy(sale);
    destroy(cap);
}

// allocation = paid * rate overflowing u64 aborts with a typed error.
#[test, expected_failure(abort_code = prefunded_sale::EAllocationOverflow)]
fun quote_allocation_overflow_aborts() {
    let mut ctx = tx_context::dummy();
    let (sale, cap) = new_sale(MAX_U64, 1_000, &mut ctx);
    let q = fixed_rate_curve::quote(&sale, tu::pay_balance(2)); // 2 * MAX overflows
    destroy(q);
    destroy(sale);
    destroy(cap);
}

// === activation ticket sizing + guard ===

#[test]
fun activation_ticket_requires_hard_cap_times_rate() {
    let mut ctx = tx_context::dummy();
    let (sale, cap) = new_sale(4, 1_000, &mut ctx);
    // required_inventory = 1_000 * 4 = 4_000; mint succeeds (carrier has no
    // abilities so we just dispose of it).
    let ticket = fixed_rate_curve::activation_ticket(&sale);
    destroy(ticket);
    destroy(sale);
    destroy(cap);
}

// required_inventory = hard_cap * rate overflowing u64 aborts.
#[test, expected_failure(abort_code = fixed_rate_curve::ERequiredInventoryOverflow)]
fun activation_ticket_overflow_aborts() {
    let mut ctx = tx_context::dummy();
    let (sale, cap) = new_sale(2, MAX_U64, &mut ctx); // MAX * 2 overflows
    let ticket = fixed_rate_curve::activation_ticket(&sale);
    destroy(ticket);
    destroy(sale);
    destroy(cap);
}

// === rate view ===

#[test]
fun rate_view_returns_configured_rate() {
    let mut ctx = tx_context::dummy();
    let (sale, cap) = new_sale(7, 1_000, &mut ctx);
    assert_eq!(fixed_rate_curve::rate(&sale), 7);
    destroy(sale);
    destroy(cap);
}

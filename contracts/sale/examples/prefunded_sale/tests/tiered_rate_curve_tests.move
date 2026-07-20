// Tests for the tiered-rate (supply-tiered) curve example.
//
// They pin the three things the seam asks of a custom curve: `params`
// validation, the per-band `quote` pricing (including a purchase that straddles
// a tier boundary), and the `activation_ticket` commitment - plus the flagship
// invariant this curve is meant to demonstrate: because the step-rate integral
// is exactly additive, total allocation is path-independent and "sold out"
// coincides with "hard cap reached" for an honestly-provisioned sale.
//
// Self-contained (like the finance `example_vesting_quadratic` tests): local
// coin markers and inert vesting slots, composing `prefunded_sale` directly.
module openzeppelin_sale::example_tiered_rate_curve_tests;

use openzeppelin_sale::example_tiered_rate_curve::{Self as curve, TieredRateCurve, Params};
use openzeppelin_sale::prefunded_sale::{Self, PrefundedSale, SaleAdminCap};
use openzeppelin_sale::refund_vault;
use std::unit_test::{assert_eq, destroy};
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::test_scenario::{Self as ts, Scenario};

// === Markers ===

/// The sale token.
public struct SALE has drop {}
/// The payment coin.
public struct USDC has drop {}
/// Inert vesting-witness slot (this is a non-vesting sale).
public struct NoVesting has drop {}
/// Inert vesting-schedule slot (never filled).
public struct NoSchedule has copy, drop, store {}

const ADMIN: address = @0xAD;
const BUYER: address = @0xB0B;
const OPENS: u64 = 1_000;
const CLOSES: u64 = 5_000;
const MAX_U64: u64 = 18_446_744_073_709_551_615;

// The canonical two-tier schedule used across the pricing tests: rate 3 while
// `raised < 1_000`, rate 1 above it. With `hard_cap = 2_000` the required
// inventory is 1_000*3 + 1_000*1 = 4_000.

// === params validation ===

#[test, expected_failure(abort_code = curve::ENoTiers)]
fun params_rejects_empty_rates() {
    curve::params(vector[], vector[]);
}

#[test, expected_failure(abort_code = curve::ETierShapeMismatch)]
fun params_rejects_shape_mismatch() {
    // Two rates need exactly one breakpoint; zero breakpoints is a mismatch.
    curve::params(vector[], vector[3, 1]);
}

#[test, expected_failure(abort_code = curve::ERateZero)]
fun params_rejects_zero_rate() {
    curve::params(vector[1_000], vector[3, 0]);
}

#[test, expected_failure(abort_code = curve::ETierBoundsNotIncreasing)]
fun params_rejects_zero_first_bound() {
    curve::params(vector[0, 1_000], vector[3, 2, 1]);
}

#[test, expected_failure(abort_code = curve::ETierBoundsNotIncreasing)]
fun params_rejects_non_increasing_bounds() {
    curve::params(vector[1_000, 1_000], vector[3, 2, 1]);
}

// === quote pricing ===

// A payment that stays inside the first tier prices flat at that tier's rate.
#[test]
fun quote_within_a_single_tier() {
    let mut ctx = tx_context::dummy();
    let (sale, cap) = new_sale(vector[1_000], vector[3, 1], 2_000, &mut ctx);

    let q = curve::quote(&sale, pay(500));
    assert_eq!(q.allocation(), 1_500); // 500 * 3

    destroy(q);
    destroy(sale);
    destroy(cap);
}

// A payment made at `raised == 0` that crosses the breakpoint is priced per
// band: the first 1_000 at rate 3, the remaining 500 at rate 1. A curve that
// priced the whole payment at the entry rate would return 4_500 instead.
#[test]
fun quote_straddling_a_tier_boundary_splits_per_band() {
    let mut ctx = tx_context::dummy();
    let (sale, cap) = new_sale(vector[1_000], vector[3, 1], 2_000, &mut ctx);

    let q = curve::quote(&sale, pay(1_500));
    assert_eq!(q.allocation(), 3_500); // 1_000*3 + 500*1

    destroy(q);
    destroy(sale);
    destroy(cap);
}

// The allocation is the integral over `[raised, raised + paid)`, so it depends on
// the sale's *current* `raised`: once earlier buys have crossed the breakpoint,
// a later payment prices entirely in the higher tier.
#[test]
fun quote_reads_current_raised() {
    let mut scenario = ts::begin(ADMIN);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(OPENS);

    create_and_activate(&mut scenario, &clk, vector[1_000], vector[3, 1], 2_000, 4_000);
    scenario.next_tx(BUYER);
    let mut sale = take_sale(&scenario);

    // Marginal rate starts in tier 0.
    assert_eq!(curve::marginal_rate(&sale), 3);

    // Push `raised` to exactly the breakpoint.
    buy(&mut sale, 1_000, &clk, scenario.ctx());
    assert_eq!(sale.raised(), 1_000);
    assert_eq!(sale.total_allocated(), 3_000);

    // Now the curve prices in tier 1: 500 payment -> 500 tokens, not 1_500.
    assert_eq!(curve::marginal_rate(&sale), 1);
    let q = curve::quote(&sale, pay(500));
    assert_eq!(q.allocation(), 500);
    destroy(q);

    return_sale(sale);
    destroy(clk);
    scenario.end();
}

// === activation commitment ===

// The ticket commits `integrate(0, hard_cap) = 4_000`. Activating with exactly
// that inventory succeeds.
#[test]
fun activates_with_exactly_required_inventory() {
    let mut scenario = ts::begin(ADMIN);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(OPENS);

    create_and_activate(&mut scenario, &clk, vector[1_000], vector[3, 1], 2_000, 4_000);
    scenario.next_tx(ADMIN);

    // The shared sale exists and is live.
    let sale = take_sale(&scenario);
    assert_eq!(sale.inventory_total(), 4_000);
    return_sale(sale);

    destroy(clk);
    scenario.end();
}

// One token short of the commitment, activation aborts on the core-side backing
// check.
#[test, expected_failure(abort_code = prefunded_sale::EInsufficientInventoryAtActivate)]
fun activation_underprovisioned_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(OPENS);

    create_and_activate(&mut scenario, &clk, vector[1_000], vector[3, 1], 2_000, 3_999);
    abort
}

// `integrate(0, hard_cap)` overflowing u64 aborts with a typed error.
#[test, expected_failure(abort_code = curve::ERequiredInventoryOverflow)]
fun activation_ticket_overflow_aborts() {
    let mut ctx = tx_context::dummy();
    // Single tier at MAX rate, hard_cap 2 -> 2 * MAX overflows.
    let (sale, _cap) = new_sale(vector[], vector[MAX_U64], 2, &mut ctx);
    let _ticket = curve::activation_ticket(&sale);
    abort
}

// `quote` allocation overflowing u64 aborts with a typed error.
#[test, expected_failure(abort_code = curve::EAllocationOverflow)]
fun quote_allocation_overflow_aborts() {
    let mut ctx = tx_context::dummy();
    let (sale, _cap) = new_sale(vector[], vector[MAX_U64], MAX_U64, &mut ctx);
    let _q = curve::quote(&sale, pay(2)); // 2 * MAX overflows
    abort
}

// === the flagship invariant ===

// Total allocation is path-independent, and an honestly-provisioned sale sells
// out exactly when the hard cap is reached: three purchases summing to the hard
// cap allocate exactly the committed inventory, leaving nothing unallocated -
// regardless of how the payment was chunked across the breakpoint.
#[test]
fun sellout_coincides_with_hard_cap() {
    let mut scenario = ts::begin(ADMIN);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(OPENS);

    create_and_activate(&mut scenario, &clk, vector[1_000], vector[3, 1], 2_000, 4_000);
    scenario.next_tx(BUYER);
    let mut sale = take_sale(&scenario);

    buy(&mut sale, 500, &clk, scenario.ctx()); // tier 0:        1_500 tokens
    buy(&mut sale, 500, &clk, scenario.ctx()); // tier 0:        1_500 tokens
    buy(&mut sale, 1_000, &clk, scenario.ctx()); // tier 1:      1_000 tokens

    assert_eq!(sale.raised(), 2_000); // == hard_cap
    assert_eq!(sale.total_allocated(), 4_000); // == required_inventory
    assert_eq!(sale.inventory_remaining(), 0); // sold out, no dust left over

    return_sale(sale);
    destroy(clk);
    scenario.end();
}

// === Helpers ===

fun pay(amount: u64): Balance<USDC> {
    balance::create_for_testing<USDC>(amount)
}

fun new_sale(
    breakpoints: vector<u64>,
    rates: vector<u64>,
    hard_cap: u64,
    ctx: &mut TxContext,
): (
    PrefundedSale<TieredRateCurve, Params, SALE, USDC, NoVesting, NoSchedule>,
    SaleAdminCap<SALE, USDC>,
) {
    prefunded_sale::create_sale<TieredRateCurve, Params, SALE, USDC, NoVesting, NoSchedule>(
        curve::params(breakpoints, rates),
        hard_cap,
        0,
        OPENS,
        CLOSES,
        ctx,
    )
}

// Create, fund, pair a fresh vault, and activate a tiered sale in one tx; leaves
// the sale and vault shared and the admin cap with `ADMIN`.
fun create_and_activate(
    scenario: &mut Scenario,
    clk: &Clock,
    breakpoints: vector<u64>,
    rates: vector<u64>,
    hard_cap: u64,
    inventory: u64,
) {
    let ctx = scenario.ctx();
    let (mut sale, cap) = new_sale(breakpoints, rates, hard_cap, ctx);
    sale.deposit(balance::create_for_testing<SALE>(inventory));
    let (vault, vault_cap) = refund_vault::new<USDC>(ctx);
    sale.pair_refund_vault(&vault, vault_cap);
    let ticket = curve::activation_ticket(&sale);
    sale.share_and_activate(vault, ticket, clk);
    transfer::public_transfer(cap, ADMIN);
}

fun take_sale(
    scenario: &Scenario,
): PrefundedSale<TieredRateCurve, Params, SALE, USDC, NoVesting, NoSchedule> {
    ts::take_shared<PrefundedSale<TieredRateCurve, Params, SALE, USDC, NoVesting, NoSchedule>>(
        scenario,
    )
}

fun return_sale(sale: PrefundedSale<TieredRateCurve, Params, SALE, USDC, NoVesting, NoSchedule>) {
    ts::return_shared(sale);
}

fun buy(
    sale: &mut PrefundedSale<TieredRateCurve, Params, SALE, USDC, NoVesting, NoSchedule>,
    paid: u64,
    clk: &Clock,
    ctx: &mut TxContext,
) {
    let q = curve::quote(sale, pay(paid));
    sale.purchase(q, option::none(), clk, ctx);
}

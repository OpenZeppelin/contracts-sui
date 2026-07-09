// Curve-trust-boundary tests for `prefunded_sale`.
//
// The curve-trust boundary is an INTENTIONAL design decision: the sale accepts
// the curve's `allocation` (from the quote) and `required_inventory` (from the
// activation ticket) verbatim - there is no `max_rate` field and no independent
// rate bound. The only protections are the inventory bound and the u128
// overflow guards. These tests use a test-only `BadCurve` witness - the
// only way to exercise a dishonest curve and to reach EInsufficientInventory,
// which an honest, tightly-provisioned `FixedRateCurve` sale can never trip.
module openzeppelin_sale::prefunded_sale_curve_trust_tests;

use openzeppelin_sale::prefunded_sale::{Self, PrefundedSale};
use openzeppelin_sale::refund_vault;
use openzeppelin_sale::test_utils::{Self as u, SALE, USDC};
use std::unit_test::{assert_eq, destroy};
use sui::clock::Clock;
use sui::test_scenario::{Self as ts, Scenario};

// A dishonest/arbitrary curve declared inside the test module, so the test can
// construct its witness and mint quotes/tickets with attacker-chosen values.
// CurveParams and VestingScheduleParams are immaterial here, so both are `u64`.
public struct BadCurve has drop {}

// === Test-Only Helpers ===

// Create + activate a BadCurve sale, minting the activation ticket with an
// arbitrary `required_inventory` (the sale trusts it).
fun activate_bad(
    test: &mut Scenario,
    clk: &Clock,
    hard_cap: u64,
    inventory: u64,
    required_inventory: u64,
) {
    let ctx = test.ctx();
    let (mut sale, cap) = prefunded_sale::create_sale<BadCurve, u64, SALE, USDC, BadCurve, u64>(
        0,
        hard_cap,
        0,
        u::opens(),
        u::closes(),
        ctx,
    );
    sale.deposit(u::sale_balance(inventory));
    let (vault, vault_cap) = refund_vault::new<USDC>(ctx);
    sale.pair_refund_vault(&vault, vault_cap);
    let ticket = prefunded_sale::mint_activation_ticket<BadCurve, u64, SALE, USDC, BadCurve, u64>(
        &sale,
        BadCurve {},
        required_inventory,
    );
    sale.share_and_activate(vault, ticket, clk);
    transfer::public_transfer(cap, u::admin());
}

fun take_bad_sale(test: &Scenario): PrefundedSale<BadCurve, u64, SALE, USDC, BadCurve, u64> {
    ts::take_shared<PrefundedSale<BadCurve, u64, SALE, USDC, BadCurve, u64>>(test)
}

// === The sale trusts the curve's required_inventory ===

// A dishonest curve can under-size `required_inventory`, activating a sale whose
// real inventory (10) is far below `hard_cap` (1_000). The sale performs no
// independent backing check - this is the documented, intentional trust.
#[test]
fun activation_trusts_undersized_required_inventory() {
    let (mut test, clk) = u::setup();
    activate_bad(&mut test, &clk, 1_000, 10, 10);

    test.next_tx(u::admin());
    let sale = take_bad_sale(&test);
    assert_eq!(sale.phase().is_active(), true);
    assert_eq!(sale.inventory_total(), 10); // < hard_cap, yet active
    ts::return_shared(sale);

    destroy(clk);
    test.end();
}

// === Residual trust + the inventory bound is the real protection ===

// A dishonest curve over-allocates beyond the unallocated inventory; the sale's
// own inventory bound rejects it (the one independent check that survives the
// curve-trust boundary).
#[test, expected_failure(abort_code = prefunded_sale::EInsufficientInventory)]
fun overallocating_quote_beyond_inventory_aborts() {
    let (mut test, clk) = u::setup();
    activate_bad(&mut test, &clk, 1_000, 10, 10); // only 10 inventory

    test.next_tx(u::buyer());
    let mut sale = take_bad_sale(&test);
    // paid 1, rate 100 -> allocation 100 > unallocated 10.
    let quote = prefunded_sale::mint_quote<BadCurve, u64, SALE, USDC, BadCurve, u64>(
        &sale,
        BadCurve {},
        u::pay_balance(1),
        100,
    );
    sale.purchase(quote, option::none(), &clk, test.ctx()); // aborts: EInsufficientInventory
    ts::return_shared(sale);
    destroy(clk);
    test.end();
}

// Within the inventory ceiling, an over-allocating curve IS accepted: inventory
// drains far faster than `raised` approaches `hard_cap` (sold-out before
// hard-cap). This pins the residual trust - the sale does not re-derive price.
#[test]
fun overallocating_quote_within_inventory_is_accepted() {
    let (mut test, clk) = u::setup();
    activate_bad(&mut test, &clk, 1_000, 1_000, 1_000);

    test.next_tx(u::buyer());
    let mut sale = take_bad_sale(&test);
    // paid 1, rate 500 -> allocation 500; raised only advances by 1.
    let quote = prefunded_sale::mint_quote<BadCurve, u64, SALE, USDC, BadCurve, u64>(
        &sale,
        BadCurve {},
        u::pay_balance(1),
        500,
    );
    sale.purchase(quote, option::none(), &clk, test.ctx());
    assert_eq!(sale.raised(), 1);
    assert_eq!(sale.total_allocated(), 500); // 500 inventory consumed for 1 paid
    ts::return_shared(sale);

    destroy(clk);
    test.end();
}

// === raised overflow guard ===

// ERaisedOverflow fires before the hard-cap check when `raised + paid` would exceed
// u64::MAX. Reached with a BadCurve so allocation stays 0 (rate 0) and never trips the
// inventory bound: a first buy of u64::MAX pushes raised to u64::MAX (== hard_cap), then
// any further non-zero payment overflows.
#[test, expected_failure(abort_code = prefunded_sale::ERaisedOverflow)]
fun purchase_raised_overflow_aborts() {
    let (mut test, clk) = u::setup();
    let max = 18_446_744_073_709_551_615;
    activate_bad(&mut test, &clk, max, 10, 10); // hard_cap = u64::MAX, tiny inventory

    test.next_tx(u::buyer());
    let mut sale = take_bad_sale(&test);
    // First buy: paid = u64::MAX, rate 0 -> allocation 0; raised becomes u64::MAX.
    let q1 = prefunded_sale::mint_quote<BadCurve, u64, SALE, USDC, BadCurve, u64>(
        &sale,
        BadCurve {},
        u::pay_balance(max),
        0,
    );
    sale.purchase(q1, option::none(), &clk, test.ctx());
    // Second buy: paid = 1 -> u64::MAX - 1 >= u64::MAX is false -> ERaisedOverflow.
    let q2 = prefunded_sale::mint_quote<BadCurve, u64, SALE, USDC, BadCurve, u64>(
        &sale,
        BadCurve {},
        u::pay_balance(1),
        0,
    );
    sale.purchase(q2, option::none(), &clk, test.ctx()); // aborts: ERaisedOverflow
    ts::return_shared(sale);
    destroy(clk);
    test.end();
}

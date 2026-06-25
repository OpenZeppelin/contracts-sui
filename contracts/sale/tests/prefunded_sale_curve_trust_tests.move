// Curve-trust-boundary tests for `prefunded_sale` (INV-23, INV-21).
//
// INV-23 is an INTENTIONAL design decision: the sale accepts the curve's
// `allocation` (from the quote) and `required_inventory` (from the activation
// ticket) verbatim — there is no `max_rate` field and no independent rate
// bound. The only protections are the inventory bound (INV-21) and the u128
// overflow guards (INV-14). These tests use a test-only `BadCurve` witness — the
// only way to exercise a dishonest curve and to reach EInsufficientInventory,
// which an honest, tightly-provisioned `FixedRateCurve` sale can never trip.
module openzeppelin_sale::prefunded_sale_curve_trust_tests;

use openzeppelin_sale::prefunded_sale::{Self, PrefundedSale};
use openzeppelin_sale::refund_vault;
use openzeppelin_sale::test_utils::{Self as tu, SALE, USDC};
use std::unit_test::{assert_eq, destroy};
use sui::clock::{Self, Clock};
use sui::test_scenario::{Self as ts, Scenario};

// A dishonest/arbitrary curve declared inside the test module, so the test can
// construct its witness and mint quotes/tickets with attacker-chosen values.
// CurveParams and VestingScheduleParams are immaterial here, so both are `u64`.
public struct BadCurve has drop {}

// === Test-Only Helpers ===

fun setup(): (Scenario, Clock) {
    let mut test = ts::begin(tu::admin());
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(tu::opens());
    (test, clk)
}

// Create + activate a BadCurve sale, minting the activation ticket with an
// arbitrary `required_inventory` (the sale trusts it — INV-23).
fun activate_bad(
    test: &mut Scenario,
    clk: &Clock,
    hard_cap: u64,
    inventory: u64,
    required_inventory: u64,
) {
    let ctx = test.ctx();
    let (mut sale, cap) = prefunded_sale::create_sale<BadCurve, u64, SALE, USDC, u64>(
        0,
        hard_cap,
        0,
        tu::opens(),
        tu::closes(),
        ctx,
    );
    sale.deposit(tu::sale_balance(inventory));
    let (vault, vault_cap) = refund_vault::new<USDC>(ctx);
    sale.pair_refund_vault(&vault, vault_cap);
    let ticket = prefunded_sale::mint_activation_ticket<BadCurve, u64, SALE, USDC, u64>(
        &sale,
        BadCurve {},
        required_inventory,
    );
    sale.share_and_activate(ticket, clk);
    refund_vault::share(vault);
    transfer::public_transfer(cap, tu::admin());
}

fun take_bad_sale(test: &Scenario): PrefundedSale<BadCurve, u64, SALE, USDC, u64> {
    ts::take_shared<PrefundedSale<BadCurve, u64, SALE, USDC, u64>>(test)
}

// === INV-23: the sale trusts the curve's required_inventory ===

// A dishonest curve can under-size `required_inventory`, activating a sale whose
// real inventory (10) is far below `hard_cap` (1_000). The sale performs no
// independent backing check — this is the documented, intentional trust.
#[test]
fun activation_trusts_undersized_required_inventory() {
    let (mut test, clk) = setup();
    activate_bad(&mut test, &clk, 1_000, 10, 10);

    test.next_tx(tu::admin());
    let sale = take_bad_sale(&test);
    assert_eq!(sale.phase().is_active(), true);
    assert_eq!(sale.inventory_total(), 10); // < hard_cap, yet active
    ts::return_shared(sale);

    destroy(clk);
    test.end();
}

// === INV-23 residual + INV-21: the inventory bound is the real protection ===

// A dishonest curve over-allocates beyond the unallocated inventory; the sale's
// own INV-21 bound rejects it (the one independent check that survives INV-23).
#[test, expected_failure(abort_code = prefunded_sale::EInsufficientInventory)]
fun overallocating_quote_beyond_inventory_aborts() {
    let (mut test, clk) = setup();
    activate_bad(&mut test, &clk, 1_000, 10, 10); // only 10 inventory

    test.next_tx(tu::buyer());
    let mut sale = take_bad_sale(&test);
    // paid 1, rate 100 -> allocation 100 > unallocated 10.
    let quote = prefunded_sale::mint_quote<BadCurve, u64, SALE, USDC, u64>(
        &sale,
        BadCurve {},
        tu::pay_balance(1),
        100,
    );
    sale.purchase(quote, option::none(), &clk, test.ctx()); // aborts: EInsufficientInventory
    ts::return_shared(sale);
    destroy(clk);
    test.end();
}

// Within the inventory ceiling, an over-allocating curve IS accepted: inventory
// drains far faster than `raised` approaches `hard_cap` (sold-out before
// hard-cap). This pins the INV-23 residual — the sale does not re-derive price.
#[test]
fun overallocating_quote_within_inventory_is_accepted() {
    let (mut test, clk) = setup();
    activate_bad(&mut test, &clk, 1_000, 1_000, 1_000);

    test.next_tx(tu::buyer());
    let mut sale = take_bad_sale(&test);
    // paid 1, rate 500 -> allocation 500; raised only advances by 1.
    let quote = prefunded_sale::mint_quote<BadCurve, u64, SALE, USDC, u64>(
        &sale,
        BadCurve {},
        tu::pay_balance(1),
        500,
    );
    sale.purchase(quote, option::none(), &clk, test.ctx());
    assert_eq!(sale.raised(), 1);
    assert_eq!(sale.total_allocated(), 500); // 500 inventory consumed for 1 paid
    ts::return_shared(sale);

    destroy(clk);
    test.end();
}

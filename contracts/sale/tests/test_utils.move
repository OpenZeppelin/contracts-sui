// Shared test scaffolding for the prefunded_sale unit suite.
//
// Holds the test coin markers, common constants (exposed via accessor fns,
// since consts are module-private in Move), the canonical sale type, and the
// high-traffic setup helpers (`create_and_activate`, `buy`, `take_sale`, ...)
// so each thematic test file stays focused on the behavior it pins rather than
// on the boilerplate of threading a sale through Init -> Active.
//
// All sales in the suite are parameterized on `FixedRateCurve` (the only curve
// that can mint quotes/tickets for them) and use `vesting_wallet_linear::Params`
// as the `VestingScheduleParams` slot. Vesting and non-vesting sales therefore
// share one concrete type; the difference is only whether the schedule Option is
// filled via `set_vesting_schedule_params`.
module openzeppelin_sale::test_utils;

use openzeppelin_finance::vesting_wallet_linear::Params as VParams;
use openzeppelin_sale::fixed_rate_curve::{Self, FixedRateCurve, Params as FrcParams};
use openzeppelin_sale::prefunded_sale::{Self, PrefundedSale, SaleAdminCap};
use openzeppelin_sale::refund_vault::{Self, RefundVault};
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::test_scenario::{Self as ts, Scenario};

// === Test coin markers ===

/// The sale token (distributed at claim).
public struct SALE has drop {}
/// The payment coin (collected as proceeds / refunded from the vault).
public struct USDC has drop {}

// === Common constants (exposed via fns) ===

const ADMIN: address = @0xAD;
const BUYER: address = @0xB0B;
const BUYER2: address = @0xB0B2;
const OPENS: u64 = 1_000;
const CLOSES: u64 = 5_000;

public fun admin(): address { ADMIN }

public fun buyer(): address { BUYER }

public fun buyer2(): address { BUYER2 }

public fun opens(): u64 { OPENS }

public fun closes(): u64 { CLOSES }

// === Setup helpers ===
//
// Move 2024 has no type aliases, so the five-parameter sale type
// `PrefundedSale<FixedRateCurve, FrcParams, SALE, USDC, VParams>` is spelled out
// in the helper signatures below. Thematic test files call the helpers and get
// the concrete type back without having to name it.

/// Begin a scenario at `ADMIN` with a clock parked inside the sale window.
public fun setup(): (Scenario, Clock) {
    let mut test = ts::begin(ADMIN);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(OPENS);
    (test, clk)
}

/// Mint sale inventory as a raw `Balance<SALE>` (what `deposit` consumes).
public fun sale_balance(amount: u64): Balance<SALE> {
    balance::create_for_testing<SALE>(amount)
}

/// Mint a payment `Balance<USDC>` (what a quote consumes).
public fun pay_balance(amount: u64): Balance<USDC> {
    balance::create_for_testing<USDC>(amount)
}

/// Create a sale, deposit `inventory`, pair a fresh empty vault, and activate
/// it in a single transaction. Leaves the sale and the vault shared and sends
/// the `SaleAdminCap` to `ADMIN`. Times default to `[OPENS, CLOSES]`.
public fun create_and_activate(
    test: &mut Scenario,
    clk: &Clock,
    rate: u64,
    hard_cap: u64,
    soft_cap: u64,
    inventory: u64,
) {
    create_and_activate_full(test, clk, rate, hard_cap, soft_cap, OPENS, CLOSES, inventory, false)
}

/// As `create_and_activate` but with explicit window bounds and an allowlist
/// toggle. When `with_allowlist` is true the issued `AllowlistAdmin` is sent to
/// `ADMIN` for the test to take and drive.
public fun create_and_activate_full(
    test: &mut Scenario,
    clk: &Clock,
    rate: u64,
    hard_cap: u64,
    soft_cap: u64,
    opens_at_ms: u64,
    closes_at_ms: u64,
    inventory: u64,
    with_allowlist: bool,
) {
    let ctx = test.ctx();
    let (mut sale, cap) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        VParams,
    >(
        fixed_rate_curve::params(rate),
        hard_cap,
        soft_cap,
        opens_at_ms,
        closes_at_ms,
        ctx,
    );
    sale.deposit(sale_balance(inventory));
    if (with_allowlist) {
        let allow_admin = sale.enable_allowlist(ctx);
        transfer::public_transfer(allow_admin, ADMIN);
    };
    let (vault, vault_cap) = refund_vault::new<USDC>(ctx);
    sale.pair_refund_vault(&vault, vault_cap);
    let ticket = fixed_rate_curve::activation_ticket(&sale);
    sale.share_and_activate(ticket, clk);
    refund_vault::share(vault);
    transfer::public_transfer(cap, ADMIN);
}

/// Take the (single) shared sale.
public fun take_sale(test: &Scenario): PrefundedSale<FixedRateCurve, FrcParams, SALE, USDC, VParams> {
    ts::take_shared<PrefundedSale<FixedRateCurve, FrcParams, SALE, USDC, VParams>>(test)
}

/// Return the shared sale.
public fun return_sale(sale: PrefundedSale<FixedRateCurve, FrcParams, SALE, USDC, VParams>) {
    ts::return_shared(sale);
}

/// Take the (single) shared refund vault.
public fun take_vault(test: &Scenario): RefundVault<USDC> {
    ts::take_shared<RefundVault<USDC>>(test)
}

/// Return the shared refund vault.
public fun return_vault(vault: RefundVault<USDC>) {
    ts::return_shared(vault);
}

/// Take the admin cap from `ADMIN`'s inventory.
public fun take_cap(test: &Scenario): SaleAdminCap<SALE, USDC> {
    test.take_from_address<SaleAdminCap<SALE, USDC>>(ADMIN)
}

/// Return the admin cap to `ADMIN`.
public fun return_cap(cap: SaleAdminCap<SALE, USDC>) {
    ts::return_to_address(ADMIN, cap);
}

/// Purchase `paid` units of payment from `sale` with no allowlist entry.
/// The receipt is delivered to `ctx.sender()`.
public fun buy(
    sale: &mut PrefundedSale<FixedRateCurve, FrcParams, SALE, USDC, VParams>,
    paid: u64,
    clk: &Clock,
    ctx: &mut TxContext,
) {
    let quote = fixed_rate_curve::quote(sale, pay_balance(paid));
    sale.purchase(quote, option::none(), clk, ctx);
}

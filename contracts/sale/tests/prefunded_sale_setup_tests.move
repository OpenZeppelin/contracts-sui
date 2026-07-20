// Init-phase setup + activation tests for `prefunded_sale`.
//
// Covers construction guards, the Init-only / one-shot setup mutators, vault
// pairing preconditions, and the activation gate. Allowlist coupling lives in
// `allowlist_tests`; purchase/lifecycle live in their own files.
module openzeppelin_sale::prefunded_sale_setup_tests;

use openzeppelin_finance::vesting_wallet_linear::{Self, Linear, Params as VParams};
use openzeppelin_sale::fixed_rate_curve::{Self, FixedRateCurve, Params as FrcParams};
use openzeppelin_sale::prefunded_sale::{Self, PrefundedSale};
use openzeppelin_sale::refund_vault;
use openzeppelin_sale::test_utils::{Self as u, SALE, USDC};
use std::unit_test::{assert_eq, destroy};
use sui::clock;
use sui::event;
use sui::test_scenario as ts;

// === create_sale: construction guards ===

// A zero hard cap is rejected - every sale must have a bounded raise.
#[test, expected_failure(abort_code = prefunded_sale::EHardCapZero)]
fun create_sale_rejects_zero_hard_cap() {
    let mut ctx = tx_context::dummy();
    let (_sale, _cap) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(
        fixed_rate_curve::params(1, 1),
        0,
        0,
        1_000,
        5_000,
        &mut ctx,
    );
    abort
}

// soft_cap must not exceed hard_cap.
#[test, expected_failure(abort_code = prefunded_sale::EInvalidCapsOrdering)]
fun create_sale_rejects_soft_cap_above_hard() {
    let mut ctx = tx_context::dummy();
    let (_sale, _cap) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(
        fixed_rate_curve::params(1, 1),
        100,
        101,
        1_000,
        5_000,
        &mut ctx,
    );
    abort
}

// opens_at_ms must be strictly less than closes_at_ms.
#[test, expected_failure(abort_code = prefunded_sale::EInvalidTimeRange)]
fun create_sale_rejects_inverted_time_range() {
    let mut ctx = tx_context::dummy();
    let (_sale, _cap) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(
        fixed_rate_curve::params(1, 1),
        100,
        0,
        5_000,
        5_000,
        &mut ctx,
    );
    abort
}

// Happy path: a well-formed sale starts in Init with zeroed accounting and the
// cap bound to the sale id.
#[test]
fun create_sale_initializes_in_init_phase() {
    let mut ctx = tx_context::dummy();
    let (sale, cap) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(
        fixed_rate_curve::params(2, 1),
        1_000,
        500,
        1_000,
        5_000,
        &mut ctx,
    );

    assert!(sale.phase().is_init());
    assert_eq!(sale.hard_cap(), 1_000);
    assert_eq!(sale.soft_cap(), 500);
    assert_eq!(sale.raised(), 0);
    assert_eq!(sale.inventory_total(), 0);
    assert_eq!(sale.total_allocated(), 0);
    assert!(!sale.requires_allowlist());
    assert!(sale.vesting_schedule_params().is_none());
    assert_eq!(cap.cap_sale_id(), object::id(&sale));

    let created = event::events_by_type<prefunded_sale::SaleCreated<FrcParams, SALE, USDC>>();
    assert_eq!(created.length(), 1);
    assert_eq!(
        created[0],
        prefunded_sale::test_new_sale_created<FrcParams, SALE, USDC>(
            object::id(&sale),
            1_000,
            500,
            1_000,
            5_000,
            fixed_rate_curve::params(2, 1),
        ),
    );

    destroy(sale);
    destroy(cap);
}

// === deposit ===

// Inventory accumulates across multiple deposits during Init.
#[test]
fun deposit_accumulates_inventory() {
    let mut ctx = tx_context::dummy();
    let (mut sale, cap) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(
        fixed_rate_curve::params(1, 1),
        1_000,
        0,
        1_000,
        5_000,
        &mut ctx,
    );

    sale.deposit(u::sale_balance(300));
    sale.deposit(u::sale_balance(700));
    assert_eq!(sale.inventory_total(), 1_000);
    assert_eq!(sale.inventory_remaining(), 1_000);

    // Each deposit emits InventoryDeposited carrying the added amount and the running total.
    let deposits = event::events_by_type<prefunded_sale::InventoryDeposited<SALE, USDC>>();
    assert_eq!(deposits.length(), 2);
    assert_eq!(
        deposits[0],
        prefunded_sale::test_new_inventory_deposited<SALE, USDC>(object::id(&sale), 300, 300),
    );
    assert_eq!(
        deposits[1],
        prefunded_sale::test_new_inventory_deposited<SALE, USDC>(object::id(&sale), 700, 1_000),
    );

    destroy(sale);
    destroy(cap);
}

// deposit is Init-only: it aborts once the sale is Active.
#[test, expected_failure(abort_code = prefunded_sale::ENotInit)]
fun deposit_after_activate_aborts() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    sale.deposit(u::sale_balance(1)); // aborts: ENotInit
    abort
}

// === set_per_buyer_cap ===

// A zero per-buyer cap is rejected (it would block every purchase).
#[test, expected_failure(abort_code = prefunded_sale::EPerBuyerCapZero)]
fun set_per_buyer_cap_rejects_zero() {
    let mut ctx = tx_context::dummy();
    let (mut sale, _cap) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(
        fixed_rate_curve::params(1, 1),
        1_000,
        0,
        1_000,
        5_000,
        &mut ctx,
    );
    sale.set_per_buyer_cap(0, &mut ctx);
    abort
}

// set_per_buyer_cap is one-shot.
#[test, expected_failure(abort_code = prefunded_sale::EPerBuyerCapAlreadySet)]
fun set_per_buyer_cap_twice_aborts() {
    let mut ctx = tx_context::dummy();
    let (mut sale, _cap) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(
        fixed_rate_curve::params(1, 1),
        1_000,
        0,
        1_000,
        5_000,
        &mut ctx,
    );
    sale.set_per_buyer_cap(100, &mut ctx);
    sale.set_per_buyer_cap(200, &mut ctx); // aborts
    abort
}

// set_per_buyer_cap is Init-only: it aborts once the sale is Active.
#[test, expected_failure(abort_code = prefunded_sale::ENotInit)]
fun set_per_buyer_cap_after_activate_aborts() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    sale.set_per_buyer_cap(100, test.ctx()); // aborts: ENotInit
    abort
}

// === set_vesting_schedule_params ===

// Setting a schedule fills the Option; one-shot guard rejects a second call.
#[test]
fun set_vesting_schedule_params_fills_option() {
    let mut ctx = tx_context::dummy();
    let (mut sale, cap) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(
        fixed_rate_curve::params(1, 1),
        1_000,
        0,
        1_000,
        5_000,
        &mut ctx,
    );
    sale.set_vesting_schedule_params(vesting_wallet_linear::params(0, 0, 1_000, 4));
    assert!(sale.vesting_schedule_params().is_some());

    let set = event::events_by_type<
        prefunded_sale::VestingScheduleParamsSet<SALE, USDC, VParams>,
    >();
    assert_eq!(set.length(), 1);
    assert_eq!(
        set[0],
        prefunded_sale::test_new_vesting_schedule_params_set<SALE, USDC, VParams>(
            object::id(&sale),
            vesting_wallet_linear::params(0, 0, 1_000, 4),
        ),
    );

    destroy(sale);
    destroy(cap);
}

#[test, expected_failure(abort_code = prefunded_sale::EVestingScheduleAlreadySet)]
fun set_vesting_schedule_params_twice_aborts() {
    let mut ctx = tx_context::dummy();
    let (mut sale, _cap) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(
        fixed_rate_curve::params(1, 1),
        1_000,
        0,
        1_000,
        5_000,
        &mut ctx,
    );
    sale.set_vesting_schedule_params(vesting_wallet_linear::params(0, 0, 1_000, 4));
    sale.set_vesting_schedule_params(vesting_wallet_linear::params(0, 0, 1_000, 8)); // aborts
    abort
}

// set_vesting_schedule_params is Init-only: it aborts once the sale is Active.
#[test, expected_failure(abort_code = prefunded_sale::ENotInit)]
fun set_vesting_schedule_params_after_activate_aborts() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    sale.set_vesting_schedule_params(vesting_wallet_linear::params(0, 0, 1_000, 4)); // aborts: ENotInit
    abort
}

// === pair_refund_vault ===

// A vault carrying pre-existing funds cannot be paired (funds would strand).
#[test, expected_failure(abort_code = prefunded_sale::EVaultNotEmpty)]
fun pair_rejects_nonempty_vault() {
    let mut test = ts::begin(u::admin());
    let ctx = test.ctx();
    let (mut sale, _cap) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(
        fixed_rate_curve::params(1, 1),
        1_000,
        0,
        1_000,
        5_000,
        ctx,
    );
    let (mut vault, vault_cap) = refund_vault::new<USDC>(ctx);
    vault.deposit(&vault_cap, u::pay_balance(1)); // taint the vault
    sale.pair_refund_vault(&vault, vault_cap); // aborts: EVaultNotEmpty
    abort
}

// A cap that does not match the provided vault is rejected.
#[test, expected_failure(abort_code = prefunded_sale::EWrongVault)]
fun pair_rejects_mismatched_cap() {
    let mut test = ts::begin(u::admin());
    let ctx = test.ctx();
    let (mut sale, _cap) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(
        fixed_rate_curve::params(1, 1),
        1_000,
        0,
        1_000,
        5_000,
        ctx,
    );
    let (vault, _vault_cap) = refund_vault::new<USDC>(ctx);
    let (_other_vault, other_cap) = refund_vault::new<USDC>(ctx);
    sale.pair_refund_vault(&vault, other_cap); // cap is for other_vault -> EWrongVault
    abort
}

// A vault not in Active state cannot be paired.
#[test, expected_failure(abort_code = prefunded_sale::EVaultNotActive)]
fun pair_rejects_inactive_vault() {
    let mut test = ts::begin(u::admin());
    let ctx = test.ctx();
    let (mut sale, _cap) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(
        fixed_rate_curve::params(1, 1),
        1_000,
        0,
        1_000,
        5_000,
        ctx,
    );
    let (mut vault, vault_cap) = refund_vault::new<USDC>(ctx);
    vault.flip_to_refunding(&vault_cap); // no longer Active
    sale.pair_refund_vault(&vault, vault_cap); // aborts: EVaultNotActive
    abort
}

// Pairing twice aborts (one-shot).
#[test, expected_failure(abort_code = prefunded_sale::EVaultAlreadyPaired)]
fun pair_twice_aborts() {
    let mut test = ts::begin(u::admin());
    let ctx = test.ctx();
    let (mut sale, _cap) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(
        fixed_rate_curve::params(1, 1),
        1_000,
        0,
        1_000,
        5_000,
        ctx,
    );
    let (vault1, vault_cap1) = refund_vault::new<USDC>(ctx);
    let (vault2, vault_cap2) = refund_vault::new<USDC>(ctx);
    sale.pair_refund_vault(&vault1, vault_cap1);
    sale.pair_refund_vault(&vault2, vault_cap2); // aborts
    abort
}

// pair_refund_vault is Init-only: it aborts once the sale is Active.
#[test, expected_failure(abort_code = prefunded_sale::ENotInit)]
fun pair_refund_vault_after_activate_aborts() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let (vault, vault_cap) = refund_vault::new<USDC>(test.ctx());
    sale.pair_refund_vault(&vault, vault_cap); // aborts: ENotInit
    abort
}

// === enable_allowlist ===

// enable_allowlist is one-shot: a second call aborts.
#[test, expected_failure(abort_code = prefunded_sale::EAllowlistAlreadyEnabled)]
fun enable_allowlist_twice_aborts() {
    let mut test = ts::begin(u::admin());
    let ctx = test.ctx();
    let (mut sale, _cap) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(
        fixed_rate_curve::params(1, 1),
        1_000,
        0,
        1_000,
        5_000,
        ctx,
    );
    let _admin1 = sale.enable_allowlist(ctx);
    assert!(sale.requires_allowlist());
    let _admin2 = sale.enable_allowlist(ctx); // aborts: EAllowlistAlreadyEnabled
    abort
}

// enable_allowlist is Init-only: it aborts once the sale is Active.
#[test, expected_failure(abort_code = prefunded_sale::ENotInit)]
fun enable_allowlist_after_activate_aborts() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 1, 1_000, 0, 1_000);

    test.next_tx(u::admin());
    let mut sale = u::take_sale(&test);
    let _admin = sale.enable_allowlist(test.ctx()); // aborts: ENotInit
    abort
}

// === share_and_activate ===

// Activation requires a paired vault.
#[test, expected_failure(abort_code = prefunded_sale::EVaultRequiredForActivate)]
fun activate_without_vault_aborts() {
    let mut test = ts::begin(u::admin());
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(u::opens());
    let ctx = test.ctx();
    let (mut sale, _cap) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(
        fixed_rate_curve::params(1, 1),
        1_000,
        0,
        1_000,
        5_000,
        ctx,
    );
    sale.deposit(u::sale_balance(1_000));
    // A vault exists but was never paired, so the cap is absent.
    let (vault, _vault_cap) = refund_vault::new<USDC>(ctx);
    let ticket = fixed_rate_curve::activation_ticket(&sale);
    sale.share_and_activate(vault, ticket, &clk); // aborts: no vault paired
    abort
}

// Activation rejects a vault that is not the one paired with the sale: the sale pairs
// vault A but activation is handed a different vault B.
#[test, expected_failure(abort_code = prefunded_sale::EWrongVault)]
fun activate_with_wrong_vault_aborts() {
    let mut test = ts::begin(u::admin());
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(u::opens());
    let ctx = test.ctx();
    let (mut sale, _cap) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(
        fixed_rate_curve::params(1, 1),
        1_000,
        0,
        1_000,
        5_000,
        ctx,
    );
    sale.deposit(u::sale_balance(1_000));
    let (vault_a, vault_cap_a) = refund_vault::new<USDC>(ctx);
    sale.pair_refund_vault(&vault_a, vault_cap_a); // pairs A
    let (vault_b, _vault_cap_b) = refund_vault::new<USDC>(ctx); // a different vault
    let ticket = fixed_rate_curve::activation_ticket(&sale);
    sale.share_and_activate(vault_b, ticket, &clk); // aborts: EWrongVault (B != A)
    abort
}

// Activation rejects inventory below `hard_cap * rate_numerator / rate_denominator`.
#[test, expected_failure(abort_code = prefunded_sale::EInsufficientInventoryAtActivate)]
fun activate_insufficient_inventory_aborts() {
    let mut test = ts::begin(u::admin());
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(u::opens());
    let ctx = test.ctx();
    let (mut sale, _cap) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(
        fixed_rate_curve::params(2, 1), // requires hard_cap * 2 = 2_000
        1_000,
        0,
        1_000,
        5_000,
        ctx,
    );
    sale.deposit(u::sale_balance(1_999)); // one short
    let (vault, vault_cap) = refund_vault::new<USDC>(ctx);
    sale.pair_refund_vault(&vault, vault_cap);
    let ticket = fixed_rate_curve::activation_ticket(&sale);
    sale.share_and_activate(vault, ticket, &clk); // aborts
    abort
}

// Boundary: inventory exactly equal to `hard_cap * rate_numerator / rate_denominator` activates.
#[test]
fun activate_at_exact_required_inventory_ok() {
    let (mut test, clk) = u::setup();
    u::create_and_activate(&mut test, &clk, 2, 1_000, 0, 2_000);

    test.next_tx(u::admin());
    let sale = u::take_sale(&test);
    assert!(sale.phase().is_active());
    assert_eq!(sale.inventory_total(), 2_000);
    u::return_sale(sale);

    destroy(clk);
    test.end();
}

// Activation after the window has closed is rejected.
#[test, expected_failure(abort_code = prefunded_sale::EActivationAfterClose)]
fun activate_after_close_aborts() {
    let mut test = ts::begin(u::admin());
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(5_001); // past closes_at_ms
    let ctx = test.ctx();
    let (mut sale, _cap) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(
        fixed_rate_curve::params(1, 1),
        1_000,
        0,
        1_000,
        5_000,
        ctx,
    );
    sale.deposit(u::sale_balance(1_000));
    let (vault, vault_cap) = refund_vault::new<USDC>(ctx);
    sale.pair_refund_vault(&vault, vault_cap);
    let ticket = fixed_rate_curve::activation_ticket(&sale);
    sale.share_and_activate(vault, ticket, &clk); // aborts
    abort
}

// A ticket minted for a different sale is rejected. Code uses
// ETicketSaleMismatch (code 62) - the invariants doc still names the old
// EReceiptSaleMismatch; corrected since commit 547c315.
#[test, expected_failure(abort_code = prefunded_sale::ETicketSaleMismatch)]
fun activate_with_foreign_ticket_aborts() {
    let mut test = ts::begin(u::admin());
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(u::opens());
    let ctx = test.ctx();

    // Sale A - the one we try to activate.
    let (mut sale_a, _cap_a) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(
        fixed_rate_curve::params(1, 1),
        1_000,
        0,
        1_000,
        5_000,
        ctx,
    );
    sale_a.deposit(u::sale_balance(1_000));
    let (vault_a, vault_cap_a) = refund_vault::new<USDC>(ctx);
    sale_a.pair_refund_vault(&vault_a, vault_cap_a);

    // Sale B - same type; its ticket pins B's id, not A's.
    let (sale_b, _cap_b) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(
        fixed_rate_curve::params(1, 1),
        1_000,
        0,
        1_000,
        5_000,
        ctx,
    );
    let foreign_ticket = fixed_rate_curve::activation_ticket(&sale_b);

    sale_a.share_and_activate(vault_a, foreign_ticket, &clk); // aborts: ETicketSaleMismatch
    abort
}

// === Setup event emission (happy paths) ===

// set_per_buyer_cap happy path: there is no state getter for the cap, so the
// PerBuyerCapSet event is the observable that the setter ran with the right value.
#[test]
fun set_per_buyer_cap_emits_event() {
    let mut ctx = tx_context::dummy();
    let (mut sale, cap) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(
        fixed_rate_curve::params(1, 1),
        1_000,
        0,
        1_000,
        5_000,
        &mut ctx,
    );
    sale.set_per_buyer_cap(250, &mut ctx);
    let events = event::events_by_type<prefunded_sale::PerBuyerCapSet<SALE, USDC>>();
    assert_eq!(events.length(), 1);
    assert_eq!(
        events[0],
        prefunded_sale::test_new_per_buyer_cap_set<SALE, USDC>(object::id(&sale), 250),
    );
    destroy(sale);
    destroy(cap);
}

// enable_allowlist happy path: flips requires_allowlist and emits AllowlistEnabled
// carrying the id of the issued admin.
#[test]
fun enable_allowlist_emits_event() {
    let mut ctx = tx_context::dummy();
    let (mut sale, cap) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(
        fixed_rate_curve::params(1, 1),
        1_000,
        0,
        1_000,
        5_000,
        &mut ctx,
    );
    let admin = sale.enable_allowlist(&mut ctx);
    assert!(sale.requires_allowlist());
    let events = event::events_by_type<prefunded_sale::AllowlistEnabled<SALE, USDC>>();
    assert_eq!(events.length(), 1);
    assert_eq!(
        events[0],
        prefunded_sale::test_new_allowlist_enabled<SALE, USDC>(
            object::id(&sale),
            object::id(&admin),
        ),
    );
    destroy(sale);
    destroy(cap);
    destroy(admin);
}

// share_and_activate happy path, built inline so pairing + activation emit into this
// tx: RefundVaultPaired (from pair_refund_vault) and SaleActivated (activated_at_ms is
// the clock value, pre-open activation at OPENS).
#[test]
fun share_and_activate_emits_pairing_and_activation_events() {
    let mut test = ts::begin(u::admin());
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(u::opens());
    let ctx = test.ctx();
    let (mut sale, cap) = prefunded_sale::create_sale<
        FixedRateCurve,
        FrcParams,
        SALE,
        USDC,
        Linear,
        VParams,
    >(
        fixed_rate_curve::params(1, 1),
        1_000,
        0,
        1_000,
        5_000,
        ctx,
    );
    sale.deposit(u::sale_balance(1_000));
    let (vault, vault_cap) = refund_vault::new<USDC>(ctx);
    let vault_id = object::id(&vault);
    sale.pair_refund_vault(&vault, vault_cap);
    let sale_id = object::id(&sale);
    let ticket = fixed_rate_curve::activation_ticket(&sale);
    sale.share_and_activate(vault, ticket, &clk);

    let paired = event::events_by_type<prefunded_sale::RefundVaultPaired<SALE, USDC>>();
    assert_eq!(paired.length(), 1);
    assert_eq!(
        paired[0],
        prefunded_sale::test_new_refund_vault_paired<SALE, USDC>(sale_id, vault_id),
    );
    let activated = event::events_by_type<prefunded_sale::SaleActivated<SALE, USDC>>();
    assert_eq!(activated.length(), 1);
    assert_eq!(
        activated[0],
        prefunded_sale::test_new_sale_activated<SALE, USDC>(sale_id, u::opens()),
    );

    destroy(cap);
    destroy(clk);
    test.end();
}

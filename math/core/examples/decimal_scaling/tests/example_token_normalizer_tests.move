module openzeppelin_math::example_token_normalizer_tests;

use openzeppelin_math::example_token_normalizer::{Self as ledger, MultiAssetLedger, LedgerAdminCap};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario as ts;

const ADMIN: address = @0xA;

// Decimal conventions of the two supported assets and the internal basis. Kept here so
// the tests pin exact scaled values rather than re-deriving them from the module.
const STABLE_DECIMALS: u8 = 6;
const NATIVE_DECIMALS: u8 = 9;

// 2.5 stablecoin units at 6 decimals.
const STABLE_DEPOSIT: u64 = 2_500_000;
// 4.0 native-coin units at 9 decimals.
const NATIVE_DEPOSIT: u64 = 4_000_000_000;

// The two deposits re-expressed on the 18-decimal basis (upcasting is exact).
const STABLE_NORMALIZED: u256 = 2_500_000_000_000_000_000; // 2.5e18
const NATIVE_NORMALIZED: u256 = 4_000_000_000_000_000_000; // 4.0e18
const TOTAL_NORMALIZED: u256 = 6_500_000_000_000_000_000; // 6.5e18

// Open a shared, empty ledger and hand the admin cap to ADMIN.
fun create_ledger(scenario: &mut ts::Scenario) {
    let cap = ledger::new(scenario.ctx());
    transfer::public_transfer(cap, ADMIN);
}

// Upcasting a native amount onto the basis preserves value exactly when scaling up:
// no economic value is lost folding 6- or 9-decimal amounts into the 18-decimal basis.
#[test]
fun upcast_preserves_value_when_scaling_up() {
    // 2.5 stablecoin (6 dec) -> 18 dec is exactly 2.5e18.
    assert_eq!(ledger::to_normalized(STABLE_DEPOSIT, STABLE_DECIMALS), STABLE_NORMALIZED);
    // 4.0 native (9 dec) -> 18 dec is exactly 4.0e18.
    assert_eq!(ledger::to_normalized(NATIVE_DEPOSIT, NATIVE_DECIMALS), NATIVE_NORMALIZED);
}

// The headline flow: deposit two assets with different decimals, sum them on the common
// basis inside the ledger, then convert the unified total back to each native unit.
#[test]
fun deposits_sum_on_basis_then_convert_back() {
    let mut scenario = ts::begin(ADMIN);
    create_ledger(&mut scenario);
    scenario.next_tx(ADMIN);

    let mut ledger_obj = scenario.take_shared<MultiAssetLedger>();
    let cap = scenario.take_from_sender<LedgerAdminCap>();

    // Two heterogeneous deposits land on the same 18-decimal basis.
    ledger_obj.deposit_stable(&cap, STABLE_DEPOSIT);
    ledger_obj.deposit_native(&cap, NATIVE_DEPOSIT);

    // The unified balance is the exact sum on the basis: 2.5e18 + 4.0e18 = 6.5e18.
    assert_eq!(ledger_obj.normalized_balance(), TOTAL_NORMALIZED);

    // Projecting the total back down to each native convention (truncating any dust;
    // here the values are clean so nothing is dropped).
    assert_eq!(ledger_obj.stable_balance(), 6_500_000); // 6.5 at 6 decimals
    assert_eq!(ledger_obj.native_balance(), 6_500_000_000); // 6.5 at 9 decimals

    destroy(cap);
    ts::return_shared(ledger_obj);
    scenario.end();
}

// A full round-trip (native -> basis -> native) returns the original native amount for
// values that are clean at the target precision: upcast then downcast is the identity.
#[test]
fun round_trip_equals_original() {
    let mut scenario = ts::begin(ADMIN);
    create_ledger(&mut scenario);
    scenario.next_tx(ADMIN);

    let mut ledger_obj = scenario.take_shared<MultiAssetLedger>();
    let cap = scenario.take_from_sender<LedgerAdminCap>();

    // Deposit the stablecoin amount, then withdraw the very value it normalized to.
    ledger_obj.deposit_stable(&cap, STABLE_DEPOSIT);
    let paid = ledger_obj.payout_stable(&cap, STABLE_NORMALIZED);

    // native -> basis -> native is the identity for this clean value.
    assert_eq!(paid, STABLE_DEPOSIT);
    // The whole deposit was withdrawn, so the ledger is empty again.
    assert_eq!(ledger_obj.normalized_balance(), 0);

    destroy(cap);
    ts::return_shared(ledger_obj);
    scenario.end();
}

// Downcasting from the 18-decimal basis to a coarser native precision TRUNCATES toward
// zero. A payout carrying sub-unit dust below the target's precision drops that dust,
// and the dropped value stays in the ledger (deducted on the basis, not minted away).
#[test]
fun downcast_truncates_sub_unit_dust() {
    let mut scenario = ts::begin(ADMIN);
    create_ledger(&mut scenario);
    scenario.next_tx(ADMIN);

    let mut ledger_obj = scenario.take_shared<MultiAssetLedger>();
    let cap = scenario.take_from_sender<LedgerAdminCap>();

    // Deposit 2.5 stablecoin (2.5e18 on the basis).
    ledger_obj.deposit_stable(&cap, STABLE_DEPOSIT);

    // Ask for 1.999999999999 of value on the basis (1_999_999_999_999 raw at 18 dec).
    // Downcast to 6 decimals: 1_999_999_999_999 / 1e12 = 1 (NOT 2 - truncates).
    let dusty = 1_999_999_999_999;
    let paid = ledger_obj.payout_stable(&cap, dusty);
    assert_eq!(paid, 1); // only 0.000001 stablecoin paid; the rest is dust

    // The full dusty value was still deducted on the basis, so 2.5e18 - 1.999...e12
    // remains. The truncated dust is retained in the ledger, never paid out.
    assert_eq!(ledger_obj.normalized_balance(), STABLE_NORMALIZED - dusty);

    destroy(cap);
    ts::return_shared(ledger_obj);
    scenario.end();
}

// A payout for more value than the ledger holds aborts `EInsufficientBalance` and moves
// nothing.
#[test, expected_failure(abort_code = ledger::EInsufficientBalance)]
fun payout_over_balance_aborts() {
    let mut scenario = ts::begin(ADMIN);
    create_ledger(&mut scenario);
    scenario.next_tx(ADMIN);

    let mut ledger_obj = scenario.take_shared<MultiAssetLedger>();
    let cap = scenario.take_from_sender<LedgerAdminCap>();

    ledger_obj.deposit_stable(&cap, STABLE_DEPOSIT);
    // Ask for one basis unit more than the ledger holds.
    let _ = ledger_obj.payout_stable(&cap, STABLE_NORMALIZED + 1);

    abort
}

// An admin cap minted for one ledger cannot deposit into a different ledger.
#[test, expected_failure(abort_code = ledger::EWrongLedger)]
fun foreign_cap_cannot_deposit() {
    let mut scenario = ts::begin(ADMIN);

    // Two independent ledgers; the cap from the second is taken below.
    create_ledger(&mut scenario);
    scenario.next_tx(ADMIN);
    let id_a = ts::most_recent_id_shared<MultiAssetLedger>().destroy_some();

    create_ledger(&mut scenario);
    scenario.next_tx(ADMIN);

    let mut ledger_a = ts::take_shared_by_id<MultiAssetLedger>(&scenario, id_a);
    // The sender holds two caps; the most recent one belongs to ledger B.
    let cap_b = scenario.take_from_sender<LedgerAdminCap>();

    ledger_a.deposit_stable(&cap_b, STABLE_DEPOSIT);

    abort
}

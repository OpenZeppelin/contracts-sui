module openzeppelin_math::example_token_normalizer_tests;

use openzeppelin_math::decimal_scaling;
use openzeppelin_math::example_token_normalizer::{
    Self as ledger,
    BridgedTokenLedger,
    LedgerAdminCap,
};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario as ts;

const ADMIN: address = @0xA;

// Decimal conventions of the token's two forms and the internal basis. Kept here so the
// tests pin exact scaled values rather than re-deriving them from the module.
const CANONICAL_DECIMALS: u8 = 6;
const WRAPPED_DECIMALS: u8 = 9;

// 2.5 of the token in its canonical 6-decimal form.
const CANONICAL_DEPOSIT: u64 = 2_500_000;
// 4.0 of the token in its bridged 9-decimal form.
const WRAPPED_DEPOSIT: u64 = 4_000_000_000;

// The two deposits re-expressed on the 18-decimal basis (upcasting is exact).
const CANONICAL_NORMALIZED: u256 = 2_500_000_000_000_000_000; // 2.5e18
const WRAPPED_NORMALIZED: u256 = 4_000_000_000_000_000_000; // 4.0e18
const TOTAL_NORMALIZED: u256 = 6_500_000_000_000_000_000; // 6.5e18

// Open a shared, empty ledger and hand the admin cap to ADMIN.
fun create_ledger(scenario: &mut ts::Scenario) {
    let cap = ledger::new(scenario.ctx());
    transfer::public_transfer(cap, ADMIN);
}

// Upcasting onto the basis preserves value exactly when scaling up: no value is lost
// folding the 6- or 9-decimal forms into the 18-decimal basis.
#[test]
fun upcast_preserves_value_when_scaling_up() {
    // 2.5 canonical (6 dec) -> 18 dec is exactly 2.5e18.
    assert_eq!(ledger::to_normalized(CANONICAL_DEPOSIT, CANONICAL_DECIMALS), CANONICAL_NORMALIZED);
    // 4.0 wrapped (9 dec) -> 18 dec is exactly 4.0e18.
    assert_eq!(ledger::to_normalized(WRAPPED_DEPOSIT, WRAPPED_DECIMALS), WRAPPED_NORMALIZED);
}

// The headline flow: deposit the same token in both decimal forms, sum them on the common
// basis inside the ledger, then convert the unified total back to each native convention.
#[test]
fun deposits_sum_on_basis_then_convert_back() {
    let mut scenario = ts::begin(ADMIN);
    create_ledger(&mut scenario);
    scenario.next_tx(ADMIN);

    let mut ledger_obj = scenario.take_shared<BridgedTokenLedger>();
    let cap = scenario.take_from_sender<LedgerAdminCap>();

    // Both forms of the same token land on the same 18-decimal basis.
    ledger_obj.deposit_canonical(&cap, CANONICAL_DEPOSIT);
    ledger_obj.deposit_wrapped(&cap, WRAPPED_DEPOSIT);

    // The unified balance is the exact sum on the basis: 2.5e18 + 4.0e18 = 6.5e18 of the
    // token. Summing is valid because both deposits are the same asset.
    assert_eq!(ledger_obj.normalized_balance(), TOTAL_NORMALIZED);

    // Projecting the total back down to each native convention (truncating any dust; here
    // the values are clean so nothing is dropped).
    assert_eq!(ledger_obj.canonical_balance(), 6_500_000); // 6.5 at 6 decimals
    assert_eq!(ledger_obj.wrapped_balance(), 6_500_000_000); // 6.5 at 9 decimals

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

    let mut ledger_obj = scenario.take_shared<BridgedTokenLedger>();
    let cap = scenario.take_from_sender<LedgerAdminCap>();

    // Deposit the canonical amount, then withdraw the very value it normalized to.
    ledger_obj.deposit_canonical(&cap, CANONICAL_DEPOSIT);
    let paid = ledger_obj.payout_canonical(&cap, CANONICAL_NORMALIZED);

    // native -> basis -> native is the identity for this clean value.
    assert_eq!(paid, CANONICAL_DEPOSIT);
    // The whole deposit was withdrawn, so the ledger is empty again.
    assert_eq!(ledger_obj.normalized_balance(), 0);

    destroy(cap);
    ts::return_shared(ledger_obj);
    scenario.end();
}

// Downcasting from the 18-decimal basis to a coarser native precision TRUNCATES toward
// zero. A payout carrying sub-unit dust below the target's precision drops that dust from
// the payout, and the dust stays in the ledger (only the amount actually paid is deducted).
#[test]
fun downcast_truncates_sub_unit_dust() {
    let mut scenario = ts::begin(ADMIN);
    create_ledger(&mut scenario);
    scenario.next_tx(ADMIN);

    let mut ledger_obj = scenario.take_shared<BridgedTokenLedger>();
    let cap = scenario.take_from_sender<LedgerAdminCap>();

    // Deposit 2.5 of the token (2.5e18 on the basis).
    ledger_obj.deposit_canonical(&cap, CANONICAL_DEPOSIT);

    // Ask for 1.999999999999 of value on the basis (1_999_999_999_999 raw at 18 dec).
    // Downcast to 6 decimals: 1_999_999_999_999 / 1e12 = 1 (NOT 2 - truncates).
    let dusty = 1_999_999_999_999;
    let paid = ledger_obj.payout_canonical(&cap, dusty);
    assert_eq!(paid, 1); // only 0.000001 paid; the rest is dust

    // Only the basis-equivalent of the 1 unit actually paid (1e12) is deducted; the sub-unit
    // dust requested above that stays in the ledger for a later withdrawal, not forfeited.
    assert_eq!(ledger_obj.normalized_balance(), CANONICAL_NORMALIZED - 1_000_000_000_000);

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

    let mut ledger_obj = scenario.take_shared<BridgedTokenLedger>();
    let cap = scenario.take_from_sender<LedgerAdminCap>();

    ledger_obj.deposit_canonical(&cap, CANONICAL_DEPOSIT);
    // Ask for one basis unit more than the ledger holds.
    let _ = ledger_obj.payout_canonical(&cap, CANONICAL_NORMALIZED + 1);

    abort
}

// An admin cap minted for one ledger cannot deposit into a different ledger.
#[test, expected_failure(abort_code = ledger::EWrongLedger)]
fun foreign_cap_cannot_deposit() {
    let mut scenario = ts::begin(ADMIN);

    // Two independent ledgers; the cap from the second is taken below.
    create_ledger(&mut scenario);
    scenario.next_tx(ADMIN);
    let id_a = ts::most_recent_id_shared<BridgedTokenLedger>().destroy_some();

    create_ledger(&mut scenario);
    scenario.next_tx(ADMIN);

    let mut ledger_a = ts::take_shared_by_id<BridgedTokenLedger>(&scenario, id_a);
    // The sender holds two caps; the most recent one belongs to ledger B.
    let cap_b = scenario.take_from_sender<LedgerAdminCap>();

    ledger_a.deposit_canonical(&cap_b, CANONICAL_DEPOSIT);

    abort
}

// The basis can hold more value than fits a u64 once projected back down: depositing two
// near-u64::MAX canonical amounts keeps `normalized_balance` valid on the u256 basis, but
// `canonical_balance` then overflows the downcast back to u64.
#[test, expected_failure(abort_code = decimal_scaling::ESafeDowncastOverflowedInt)]
fun canonical_balance_overflow_aborts() {
    let mut scenario = ts::begin(ADMIN);
    create_ledger(&mut scenario);
    scenario.next_tx(ADMIN);

    let mut ledger_obj = scenario.take_shared<BridgedTokenLedger>();
    let cap = scenario.take_from_sender<LedgerAdminCap>();

    let huge = std::u64::max_value!();
    ledger_obj.deposit_canonical(&cap, huge);
    ledger_obj.deposit_canonical(&cap, huge);
    // The unified balance is fine on the u256 basis (2 * u64::MAX * 10^12)...
    assert!(ledger_obj.normalized_balance() > (huge as u256));
    // ...but projecting it back to a u64 at canonical precision overflows.
    ledger_obj.canonical_balance();

    abort
}

#[test_only]
module openzeppelin_finance::vesting_wallet_tests;

use openzeppelin_finance::vesting_wallet::{
    Self,
    VestingWallet,
    Created,
    Deposited,
    Released,
    Destroyed
};
use std::unit_test::{assert_eq, destroy};
use sui::coin::{Self, Coin};
use sui::event;
use sui::test_scenario::{Self, Scenario};

// A throwaway curve used to exercise the curve-agnostic primitive directly: it
// lets the tests mint a `VestedAmount` with an arbitrary `amount`, so the
// wallet-level accounting invariants can be driven without going through a real
// curve's math. `linear_schedule_tests` covers the schedule-shape invariants.
public struct TestCurve has drop {}

public struct TestParams has copy, drop, store { tag: u64 }

/// Phantom coin marker for the vested asset.
public struct USDC has drop {}

const BENEFICIARY: address = @0xB0B;
const PARAMS_TAG: u64 = 7;

// === Test helpers ===

fun new_wallet(
    beneficiary: address,
    ctx: &mut TxContext,
): VestingWallet<TestCurve, TestParams, USDC> {
    vesting_wallet::new<TestCurve, TestParams, USDC>(
        TestParams { tag: PARAMS_TAG },
        beneficiary,
        ctx,
    )
}

fun mint(amount: u64, ctx: &mut TxContext): Coin<USDC> {
    coin::mint_for_testing<USDC>(amount, ctx)
}

// === Construction & topology ===

// A fresh wallet starts with zero balance, the beneficiary set at construction,
// and an assigned id, and emits exactly one `Created` with the documented fields.
#[test]
fun new_initializes_fields_and_emits_created() {
    let mut scenario = test_scenario::begin(@0x1);

    let wallet = new_wallet(BENEFICIARY, scenario.ctx());

    assert_eq!(wallet.balance(), 0);
    assert_eq!(wallet.released(), 0);
    assert_eq!(wallet.beneficiary(), BENEFICIARY);
    assert_eq!(wallet.schedule_params(), TestParams { tag: PARAMS_TAG });

    let created = event::events_by_type<Created<TestCurve, TestParams, USDC>>();
    assert_eq!(created.length(), 1);
    assert_eq!(
        created[0],
        vesting_wallet::test_new_created<TestCurve, TestParams, USDC>(
            object::id(&wallet),
            BENEFICIARY,
            TestParams { tag: PARAMS_TAG },
        ),
    );

    destroy(wallet);
    scenario.end();
}

// `key + store` lets the consumer move the wallet into owned mode via
// `public_transfer`. (The shared topology is covered by
// `linear_schedule_tests::create_and_share_*`.)
#[test]
fun new_supports_owned_topology() {
    let mut scenario = test_scenario::begin(@0x1);

    let wallet = new_wallet(BENEFICIARY, scenario.ctx());
    transfer::public_transfer(wallet, @0xA11CE);

    scenario.next_tx(@0xA11CE);
    let wallet = scenario.take_from_sender<VestingWallet<TestCurve, TestParams, USDC>>();
    assert_eq!(wallet.beneficiary(), BENEFICIARY);

    destroy(wallet);
    scenario.end();
}

// === Deposit ===

// A deposit increases the balance, emits `Deposited`, conserves value (none
// created/destroyed), and is permissionless - the funding sender is unrelated to
// the beneficiary.
#[test]
fun deposit_increases_balance_emits_and_is_permissionless() {
    let mut scenario = test_scenario::begin(@0xCAFE);

    let mut wallet = new_wallet(BENEFICIARY, scenario.ctx());
    let wallet_id = object::id(&wallet);
    wallet.deposit(mint(1000, scenario.ctx()));

    assert_eq!(wallet.balance(), 1000);
    assert_eq!(wallet.released(), 0);
    // ledger conservation: balance + released == Σ(deposits)
    assert_eq!(wallet.balance() + wallet.released(), 1000);

    let deposited = event::events_by_type<Deposited<TestCurve, USDC>>();
    assert_eq!(deposited.length(), 1);
    assert_eq!(deposited[0], vesting_wallet::test_new_deposited<TestCurve, USDC>(wallet_id, 1000));

    destroy(wallet);
    scenario.end();
}

// Only receipts addressed to this wallet are claimable; doing so emits a single
// `Deposited` (no separate `Received` event) and conserves funds.
#[test]
fun receive_and_deposit_claims_addressed_coin() {
    let mut scenario = test_scenario::begin(@0x1);

    // Create and share the wallet so it has a stable address others can fund.
    let wallet = new_wallet(BENEFICIARY, scenario.ctx());
    let wallet_id = object::id(&wallet);
    let wallet_addr = object::id_address(&wallet);
    transfer::public_share_object(wallet);

    // An upstream emitter sends a coin to the wallet's object address.
    scenario.next_tx(@0x1);
    let coin = mint(1000, scenario.ctx());
    let coin_id = object::id(&coin);
    transfer::public_transfer(coin, wallet_addr);

    // The wallet claims it through the standard deposit path.
    scenario.next_tx(@0x1);
    let mut wallet = scenario.take_shared<VestingWallet<TestCurve, TestParams, USDC>>();
    let receiving = test_scenario::receiving_ticket_by_id<Coin<USDC>>(coin_id);
    wallet.receive_and_deposit(receiving);

    assert_eq!(wallet.balance(), 1000);
    let deposited = event::events_by_type<Deposited<TestCurve, USDC>>();
    assert_eq!(deposited.length(), 1);
    assert_eq!(deposited[0], vesting_wallet::test_new_deposited<TestCurve, USDC>(wallet_id, 1000));

    test_scenario::return_shared(wallet);
    scenario.end();
}

// A deposit that would push the lifetime total `balance + released` past u64::MAX is
// rejected up front with `EOverflow` - the wallet's u64 accounting cannot represent a
// larger total. The funds already held stay releasable rather than the deposit
// bricking the curve, and the direct depositor keeps their coin (the tx rolls back).
#[test, expected_failure(abort_code = vesting_wallet::EOverflow)]
fun deposit_rejects_overflowing_total() {
    let mut ctx = tx_context::dummy();
    let max = std::u64::max_value!();

    let mut wallet = new_wallet(BENEFICIARY, &mut ctx);
    wallet.deposit(mint(max, &mut ctx)); // balance = max, released = 0

    // Release 1 so released > 0 while balance + released stays == max.
    let vested = wallet.mint_vested_amount(TestCurve {}, 1);
    wallet.release(&vested, &mut ctx); // released = 1, balance = max - 1

    // balance + released == max already, so any further deposit overflows.
    wallet.deposit(mint(1, &mut ctx));
    abort
}

// `receive_and_deposit` funnels through `deposit`, so the same overflow guard fires:
// claiming a coin addressed to the wallet that would push `balance + released` past
// u64::MAX aborts with `EOverflow`. (In production the already-transferred coin is
// then stranded at the wallet's address - see the function's docs; here the abort
// just rolls the claim back.)
#[test, expected_failure(abort_code = vesting_wallet::EOverflow)]
fun receive_and_deposit_rejects_overflowing_total() {
    let mut scenario = test_scenario::begin(@0x1);
    let max = std::u64::max_value!();

    // Fund to max, release 1 so balance + released == max, then share the wallet.
    let mut wallet = new_wallet(BENEFICIARY, scenario.ctx());
    wallet.deposit(mint(max, scenario.ctx()));
    let vested = wallet.mint_vested_amount(TestCurve {}, 1);
    wallet.release(&vested, scenario.ctx()); // released = 1, balance = max - 1
    let wallet_addr = object::id_address(&wallet);
    transfer::public_share_object(wallet);

    // An upstream emitter sends a coin to the wallet's object address.
    scenario.next_tx(@0x1);
    let coin = mint(1, scenario.ctx());
    let coin_id = object::id(&coin);
    transfer::public_transfer(coin, wallet_addr);

    // Claiming it would push balance + released to max + 1 -> EOverflow via `deposit`.
    scenario.next_tx(@0x1);
    let mut wallet = scenario.take_shared<VestingWallet<TestCurve, TestParams, USDC>>();
    let receiving = test_scenario::receiving_ticket_by_id<Coin<USDC>>(coin_id);
    wallet.receive_and_deposit(receiving);
    abort
}

// === Minting & wallet binding ===

// The declaring module can mint; `amount` reads by reference and the witness is
// simply dropped (no forced consumption); and the mint is redeemable against the
// wallet it was stamped for.
#[test]
fun mint_stamps_wallet_id_and_amount_reads_without_consuming() {
    let mut ctx = tx_context::dummy();

    let wallet = new_wallet(BENEFICIARY, &mut ctx);
    let vested = wallet.mint_vested_amount(TestCurve {}, 123);

    // Read twice - `amount` borrows, it does not consume.
    assert_eq!(vested.amount(), 123);
    assert_eq!(vested.amount(), 123);
    // Stamp matches this wallet, so `releasable` accepts it.
    assert_eq!(wallet.releasable(&vested), 123);

    destroy(wallet);
}

// A `VestedAmount` minted against wallet A cannot be released against a
// different wallet B of the same type.
#[test, expected_failure(abort_code = vesting_wallet::EWalletMismatch)]
fun release_rejects_vested_from_other_wallet() {
    let mut ctx = tx_context::dummy();

    let wallet_a = new_wallet(BENEFICIARY, &mut ctx);
    let mut wallet_b = new_wallet(BENEFICIARY, &mut ctx);
    let vested_a = wallet_a.mint_vested_amount(TestCurve {}, 100);

    wallet_b.release(&vested_a, &mut ctx);
    abort
}

// The same binding is enforced on the read-only `releasable` view.
#[test, expected_failure(abort_code = vesting_wallet::EWalletMismatch)]
fun releasable_rejects_vested_from_other_wallet() {
    let mut ctx = tx_context::dummy();

    let wallet_a = new_wallet(BENEFICIARY, &mut ctx);
    let wallet_b = new_wallet(BENEFICIARY, &mut ctx);
    let vested_a = wallet_a.mint_vested_amount(TestCurve {}, 100);

    wallet_b.releasable(&vested_a);
    abort
}

// === Release accounting ===

// `release` emits `Released` with the right fields, updates the ledger so
// `released == vested.amount`, conserves value, and pays the fixed beneficiary.
#[test]
fun release_pays_releasable_to_beneficiary() {
    let mut scenario = test_scenario::begin(@0x1);

    let mut wallet = new_wallet(BENEFICIARY, scenario.ctx());
    let wallet_id = object::id(&wallet);
    wallet.deposit(mint(1000, scenario.ctx()));

    let vested = wallet.mint_vested_amount(TestCurve {}, 400);
    wallet.release(&vested, scenario.ctx());

    assert_eq!(wallet.released(), 400);
    assert_eq!(wallet.balance(), 600);

    let released = event::events_by_type<Released<TestCurve, USDC>>();
    assert_eq!(released.length(), 1);
    assert_eq!(
        released[0],
        vesting_wallet::test_new_released<TestCurve, USDC>(wallet_id, BENEFICIARY, 400),
    );

    destroy(wallet);

    // The beneficiary owns exactly the released coin.
    scenario.next_tx(BENEFICIARY);
    let coin = scenario.take_from_sender<Coin<USDC>>();
    assert_eq!(coin.value(), 400);

    destroy(coin);
    scenario.end();
}

// A release with nothing newly vested is a no-op - no state change, no
// `Released` event, no abort.
#[test]
fun release_is_noop_when_nothing_releasable() {
    let mut scenario = test_scenario::begin(@0x1);

    let mut wallet = new_wallet(BENEFICIARY, scenario.ctx());
    wallet.deposit(mint(1000, scenario.ctx()));

    let vested = wallet.mint_vested_amount(TestCurve {}, 0);
    wallet.release(&vested, scenario.ctx());

    assert_eq!(wallet.released(), 0);
    assert_eq!(wallet.balance(), 1000);
    assert_eq!(event::events_by_type<Released<TestCurve, USDC>>().length(), 0);

    destroy(wallet);
    scenario.end();
}

// After releasing at a given cumulative total, re-minting at the
// same total releases nothing more.
#[test]
fun release_again_at_same_total_is_noop() {
    let mut ctx = tx_context::dummy();

    let mut wallet = new_wallet(BENEFICIARY, &mut ctx);
    wallet.deposit(mint(1000, &mut ctx));

    let vested = wallet.mint_vested_amount(TestCurve {}, 500);
    wallet.release(&vested, &mut ctx);
    assert_eq!(wallet.released(), 500);
    assert_eq!(wallet.balance(), 500);

    let again = wallet.mint_vested_amount(TestCurve {}, 500);
    assert_eq!(wallet.releasable(&again), 0);
    wallet.release(&again, &mut ctx);
    assert_eq!(wallet.released(), 500);
    assert_eq!(wallet.balance(), 500);

    destroy(wallet);
}

// `released` is monotonically non-decreasing across rising totals, and the ledger
// stays conserved.
#[test]
fun release_is_monotone_across_increasing_totals() {
    let mut ctx = tx_context::dummy();

    let mut wallet = new_wallet(BENEFICIARY, &mut ctx);
    wallet.deposit(mint(1000, &mut ctx));

    let first = wallet.mint_vested_amount(TestCurve {}, 100);
    wallet.release(&first, &mut ctx);
    let after_first = wallet.released();
    assert_eq!(after_first, 100);

    let second = wallet.mint_vested_amount(TestCurve {}, 300);
    wallet.release(&second, &mut ctx);
    assert_eq!(wallet.released(), 300);

    // monotone and conserved
    assert!(wallet.released() >= after_first);
    assert_eq!(wallet.balance() + wallet.released(), 1000);

    destroy(wallet);
}

// A curve that regresses below `released` aborts `release` before
// any state change.
#[test, expected_failure(abort_code = vesting_wallet::EVestedBelowReleased)]
fun release_rejects_vested_below_released() {
    let mut ctx = tx_context::dummy();

    let mut wallet = new_wallet(BENEFICIARY, &mut ctx);
    wallet.deposit(mint(1000, &mut ctx));

    let high = wallet.mint_vested_amount(TestCurve {}, 200);
    wallet.release(&high, &mut ctx);

    let regressed = wallet.mint_vested_amount(TestCurve {}, 100);
    wallet.release(&regressed, &mut ctx);
    abort
}

// The same guard fires on the `releasable` view.
#[test, expected_failure(abort_code = vesting_wallet::EVestedBelowReleased)]
fun releasable_rejects_vested_below_released() {
    let mut ctx = tx_context::dummy();

    let mut wallet = new_wallet(BENEFICIARY, &mut ctx);
    wallet.deposit(mint(1000, &mut ctx));

    let high = wallet.mint_vested_amount(TestCurve {}, 200);
    wallet.release(&high, &mut ctx);

    let regressed = wallet.mint_vested_amount(TestCurve {}, 100);
    wallet.releasable(&regressed);
    abort
}

// A curve that attests more than `balance + released`
// aborts `release` at the framework `balance.split` - no payout, no `Released` event,
// atomic rollback. (Framework abort, so no library-typed code to match on.)
#[test, expected_failure]
fun release_aborts_when_vested_exceeds_total() {
    let mut ctx = tx_context::dummy();

    let mut wallet = new_wallet(BENEFICIARY, &mut ctx);
    wallet.deposit(mint(100, &mut ctx));

    // Attest more than balance + released (= 100). `release` clears the wallet_id and
    // `>= released` guards, then `balance.split(200)` aborts before any coin is minted.
    let vested = wallet.mint_vested_amount(TestCurve {}, 200);
    wallet.release(&vested, &mut ctx);
    abort
}

// === Teardown ===

// `destroy_empty` is witness-gated, consumes the wallet by value and returns `P`,
// accepts an empty balance, emits `Destroyed`, and loses no value.
#[test]
fun destroy_empty_returns_params_and_emits() {
    let mut scenario = test_scenario::begin(@0x1);

    let wallet = new_wallet(BENEFICIARY, scenario.ctx());
    let wallet_id = object::id(&wallet);

    let params = wallet.destroy_empty(TestCurve {});
    assert_eq!(params, TestParams { tag: PARAMS_TAG });

    let destroyed = event::events_by_type<Destroyed<TestCurve, USDC>>();
    assert_eq!(destroyed.length(), 1);
    assert_eq!(
        destroyed[0],
        vesting_wallet::test_new_destroyed<TestCurve, USDC>(wallet_id, BENEFICIARY, 0),
    );

    scenario.end();
}

// Destroying a wallet that still holds a balance aborts.
#[test, expected_failure(abort_code = vesting_wallet::ENotEmpty)]
fun destroy_empty_rejects_nonempty_balance() {
    let mut ctx = tx_context::dummy();

    let mut wallet = new_wallet(BENEFICIARY, &mut ctx);
    wallet.deposit(mint(1, &mut ctx));

    wallet.destroy_empty(TestCurve {});
    abort
}

// === State immutability ===

// The beneficiary, schedule params, and id are all fixed across
// an arbitrary sequence of mutating calls.
#[test]
fun beneficiary_params_and_id_are_immutable() {
    let mut ctx = tx_context::dummy();

    let mut wallet = new_wallet(BENEFICIARY, &mut ctx);
    let id_at_creation = object::id(&wallet);

    wallet.deposit(mint(1000, &mut ctx));
    let vested = wallet.mint_vested_amount(TestCurve {}, 300);
    wallet.release(&vested, &mut ctx);

    assert_eq!(wallet.beneficiary(), BENEFICIARY);
    assert_eq!(wallet.schedule_params(), TestParams { tag: PARAMS_TAG });
    assert_eq!(object::id(&wallet), id_at_creation);

    destroy(wallet);
}

// Released coins belong to the beneficiary and no later wallet operation
// can reduce them - there is no clawback path.
#[test]
fun released_coins_stay_with_beneficiary() {
    let mut scenario = test_scenario::begin(@0x1);

    let mut wallet = new_wallet(BENEFICIARY, scenario.ctx());
    wallet.deposit(mint(1000, scenario.ctx()));

    let first = wallet.mint_vested_amount(TestCurve {}, 400);
    wallet.release(&first, scenario.ctx());

    // Further wallet activity in a later transaction.
    scenario.next_tx(@0x1);
    let second = wallet.mint_vested_amount(TestCurve {}, 900);
    wallet.release(&second, scenario.ctx());
    assert_eq!(wallet.released(), 900);
    destroy(wallet);

    // Both released coins are intact in the beneficiary's inventory; their total is
    // exactly what was released, never reduced.
    scenario.next_tx(BENEFICIARY);
    let coin_a = scenario.take_from_sender<Coin<USDC>>();
    let coin_b = scenario.take_from_sender<Coin<USDC>>();
    assert_eq!(coin_a.value() + coin_b.value(), 900);

    destroy(coin_a);
    destroy(coin_b);
    scenario.end();
}

// The beneficiary may be any 32-byte address, including a Move object's
// address.
#[test]
fun beneficiary_can_be_object_address() {
    let mut scenario = test_scenario::begin(@0x1);

    // Use another wallet's address as a stand-in object address.
    let placeholder = new_wallet(@0x1, scenario.ctx());
    let object_addr = object::id_address(&placeholder);

    let mut wallet = new_wallet(object_addr, scenario.ctx());
    wallet.deposit(mint(1000, scenario.ctx()));
    let vested = wallet.mint_vested_amount(TestCurve {}, 1000);
    wallet.release(&vested, scenario.ctx());

    destroy(wallet);
    destroy(placeholder);

    // The released coin landed in the object's address inventory.
    scenario.next_tx(@0x1);
    let coin = scenario.take_from_address<Coin<USDC>>(object_addr);
    assert_eq!(coin.value(), 1000);

    destroy(coin);
    scenario.end();
}

// In owned mode, handing the wallet object to a new holder does
// not redirect cashflow - releases still pay the construction-time beneficiary.
#[test]
fun owned_handoff_does_not_redirect_cashflow() {
    let alice = @0xA11CE;
    let bob = @0xB0B0;
    let mut scenario = test_scenario::begin(alice);

    // Alice is the beneficiary; the wallet is funded then handed to Bob.
    let mut wallet = new_wallet(alice, scenario.ctx());
    wallet.deposit(mint(1000, scenario.ctx()));
    transfer::public_transfer(wallet, bob);

    // Bob holds the wallet and pokes release.
    scenario.next_tx(bob);
    let mut wallet = scenario.take_from_sender<VestingWallet<TestCurve, TestParams, USDC>>();
    let vested = wallet.mint_vested_amount(TestCurve {}, 400);
    wallet.release(&vested, scenario.ctx());
    destroy(wallet);

    // Alice - not Bob - received the funds.
    scenario.next_tx(alice);
    let coin = scenario.take_from_sender<Coin<USDC>>();
    assert_eq!(coin.value(), 400);

    destroy(coin);
    scenario.end();
}

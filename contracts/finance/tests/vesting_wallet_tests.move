module openzeppelin_finance::vesting_wallet_tests;

use openzeppelin_finance::vesting_wallet::{
    Self,
    VestingWallet,
    VestedAmount,
    Created,
    Deposited,
    Released,
    Destroyed
};
use std::unit_test::{assert_eq, destroy};
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;
use sui::test_scenario;

// A throwaway curve used to exercise the curve-agnostic primitive directly: it
// lets the tests mint a `VestedAmount` with an arbitrary `amount`, so the
// wallet-level accounting invariants can be driven without going through a real
// curve's math. `vesting_wallet_linear_tests` covers the schedule-shape invariants.
public struct TestCurve has drop {}

public struct TestParams has copy, drop, store { tag: u64 }

/// Phantom coin marker for the vested asset.
public struct USDC has drop {}

/// A minimal curve-agnostic third-party wrapper, as documented in `VestedAmount`'s
/// "Why minting and spending are separated" note: it nests the wallet, exposes only
/// an immutable `&inner` (so any curve module can mint a `VestedAmount` against it),
/// keeps `&mut inner` private, and re-exposes `release` as its own function that
/// delegates to the nested wallet. It never hands out `&mut inner`.
public struct Wrapper has key, store {
    id: UID,
    inner: VestingWallet<TestCurve, TestParams, USDC>,
}

const BENEFICIARY: address = @0xB0B;
const PARAMS_TAG: u64 = 7;

// === Test-Only Helpers ===

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

fun mint(amount: u64): Balance<USDC> {
    balance::create_for_testing<USDC>(amount)
}

fun wrap(inner: VestingWallet<TestCurve, TestParams, USDC>, ctx: &mut TxContext): Wrapper {
    Wrapper { id: object::new(ctx), inner }
}

/// Immutable view onto the nested wallet - the only access the wrapper exposes for
/// curve modules to mint a `VestedAmount`.
fun inner(wrapper: &Wrapper): &VestingWallet<TestCurve, TestParams, USDC> {
    &wrapper.inner
}

/// The wrapper's own `release`: takes a `&VestedAmount` (no witness) and delegates to
/// the private `&mut inner`.
fun release(wrapper: &mut Wrapper, vested: &VestedAmount<TestCurve>) {
    wrapper.inner.release(vested);
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
// `vesting_wallet_linear_tests::create_and_share_*`.)
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
    wallet.deposit(mint(1000));

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
    let coin = coin::mint_for_testing<USDC>(1000, scenario.ctx());
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

// A deposit of a zero-value coin is a no-op: balance and ledger are untouched and
// no `Deposited` event is emitted (mirroring a release that pays out nothing).
#[test]
fun deposit_zero_value_coin_is_noop() {
    let mut scenario = test_scenario::begin(@0xCAFE);

    let mut wallet = new_wallet(BENEFICIARY, scenario.ctx());
    wallet.deposit(mint(0));

    assert_eq!(wallet.balance(), 0);
    assert_eq!(wallet.released(), 0);
    assert_eq!(event::events_by_type<Deposited<TestCurve, USDC>>().length(), 0);

    destroy(wallet);
    scenario.end();
}

// The documented owned-mode fast path: the wallet lives in a holder's inventory
// (never shared), an upstream emitter sends a coin to its object address, and the
// holder claims it with `receive_and_deposit` from their own transaction.
#[test]
fun receive_and_deposit_claims_addressed_coin_owned() {
    let holder = @0xA11CE;
    let mut scenario = test_scenario::begin(@0x1);

    // Hand the wallet to a holder as an owned object (no share).
    let wallet = new_wallet(BENEFICIARY, scenario.ctx());
    let wallet_id = object::id(&wallet);
    let wallet_addr = object::id_address(&wallet);
    transfer::public_transfer(wallet, holder);

    // An upstream emitter sends a coin to the wallet's object address.
    scenario.next_tx(@0x1);
    let coin = coin::mint_for_testing<USDC>(1000, scenario.ctx());
    let coin_id = object::id(&coin);
    transfer::public_transfer(coin, wallet_addr);

    // The holder takes their owned wallet and claims the coin through the deposit path.
    scenario.next_tx(holder);
    let mut wallet = scenario.take_from_sender<VestingWallet<TestCurve, TestParams, USDC>>();
    let receiving = test_scenario::receiving_ticket_by_id<Coin<USDC>>(coin_id);
    wallet.receive_and_deposit(receiving);

    assert_eq!(wallet.balance(), 1000);
    let deposited = event::events_by_type<Deposited<TestCurve, USDC>>();
    assert_eq!(deposited.length(), 1);
    assert_eq!(deposited[0], vesting_wallet::test_new_deposited<TestCurve, USDC>(wallet_id, 1000));

    destroy(wallet);
    scenario.end();
}

// A deposit that would push the lifetime total `balance + released` past u64::MAX is
// rejected up front with `EOverflow` - the wallet's u64 accounting cannot represent a
// larger total. The funds already held stay releasable rather than the deposit
// bricking the curve, and the direct depositor keeps their coin (the tx rolls back).
#[test, expected_failure(abort_code = vesting_wallet::EBalanceOverflow)]
fun deposit_rejects_overflowing_total() {
    let mut ctx = tx_context::dummy();
    let max = std::u64::max_value!();

    let mut wallet = new_wallet(BENEFICIARY, &mut ctx);
    wallet.deposit(mint(max)); // balance = max, released = 0

    // Release 1 so released > 0 while balance + released stays == max.
    let vested = wallet.mint_vested_amount(TestCurve {}, 1);
    wallet.release(&vested); // released = 1, balance = max - 1

    // balance + released == max already, so any further deposit overflows.
    wallet.deposit(mint(1));
    abort
}

// `receive_and_deposit` funnels through `deposit`, so the same overflow guard fires:
// claiming a coin addressed to the wallet that would push `balance + released` past
// u64::MAX aborts with `EOverflow`. (In production the already-transferred coin is
// then stranded at the wallet's address - see the function's docs; here the abort
// just rolls the claim back.)
#[test, expected_failure(abort_code = vesting_wallet::EBalanceOverflow)]
fun receive_and_deposit_rejects_overflowing_total() {
    let mut scenario = test_scenario::begin(@0x1);
    let max = std::u64::max_value!();

    // Fund to max, release 1 so balance + released == max, then share the wallet.
    let mut wallet = new_wallet(BENEFICIARY, scenario.ctx());
    wallet.deposit(mint(max));
    let vested = wallet.mint_vested_amount(TestCurve {}, 1);
    wallet.release(&vested); // released = 1, balance = max - 1
    let wallet_addr = object::id_address(&wallet);
    transfer::public_share_object(wallet);

    // An upstream emitter sends a coin to the wallet's object address.
    scenario.next_tx(@0x1);
    let coin = coin::mint_for_testing<USDC>(1, scenario.ctx());
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

    wallet_b.release(&vested_a);
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
    wallet.deposit(mint(1000));

    let vested = wallet.mint_vested_amount(TestCurve {}, 400);
    wallet.release(&vested);

    assert_eq!(wallet.released(), 400);
    assert_eq!(wallet.balance(), 600);

    let released = event::events_by_type<Released<TestCurve, USDC>>();
    assert_eq!(released.length(), 1);
    assert_eq!(
        released[0],
        vesting_wallet::test_new_released<TestCurve, USDC>(wallet_id, BENEFICIARY, 400),
    );

    destroy(wallet);
    scenario.end();
}

// A release with nothing newly vested is a no-op - no state change, no
// `Released` event, no abort.
#[test]
fun release_is_noop_when_nothing_releasable() {
    let mut scenario = test_scenario::begin(@0x1);

    let mut wallet = new_wallet(BENEFICIARY, scenario.ctx());
    wallet.deposit(mint(1000));

    let vested = wallet.mint_vested_amount(TestCurve {}, 0);
    wallet.release(&vested);

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
    wallet.deposit(mint(1000));

    let vested = wallet.mint_vested_amount(TestCurve {}, 500);
    wallet.release(&vested);
    assert_eq!(wallet.released(), 500);
    assert_eq!(wallet.balance(), 500);

    let again = wallet.mint_vested_amount(TestCurve {}, 500);
    assert_eq!(wallet.releasable(&again), 0);
    wallet.release(&again);
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
    wallet.deposit(mint(1000));

    let first = wallet.mint_vested_amount(TestCurve {}, 100);
    wallet.release(&first);
    let after_first = wallet.released();
    assert_eq!(after_first, 100);

    let second = wallet.mint_vested_amount(TestCurve {}, 300);
    wallet.release(&second);
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
    wallet.deposit(mint(1000));

    let high = wallet.mint_vested_amount(TestCurve {}, 200);
    wallet.release(&high);

    let regressed = wallet.mint_vested_amount(TestCurve {}, 100);
    wallet.release(&regressed);
    abort
}

// The same guard fires on the `releasable` view.
#[test, expected_failure(abort_code = vesting_wallet::EVestedBelowReleased)]
fun releasable_rejects_vested_below_released() {
    let mut ctx = tx_context::dummy();

    let mut wallet = new_wallet(BENEFICIARY, &mut ctx);
    wallet.deposit(mint(1000));

    let high = wallet.mint_vested_amount(TestCurve {}, 200);
    wallet.release(&high);

    let regressed = wallet.mint_vested_amount(TestCurve {}, 100);
    wallet.releasable(&regressed);
    abort
}

// A curve that attests more than `balance + released`
// aborts `release` with the library-typed `EInsufficientBalance` - no payout, no
// `Released` event, atomic rollback. The local guard fires before the framework
// `balance.split`, so consumers see the typed error rather than a generic abort.
#[test, expected_failure(abort_code = vesting_wallet::EInsufficientBalance)]
fun release_aborts_when_vested_exceeds_total() {
    let mut ctx = tx_context::dummy();

    let mut wallet = new_wallet(BENEFICIARY, &mut ctx);
    wallet.deposit(mint(100));

    // Attest more than balance + released (= 100). `release` clears the wallet_id and
    // `>= released` guards, then `EInsufficientBalance` aborts before any coin is minted.
    let vested = wallet.mint_vested_amount(TestCurve {}, 200);
    wallet.release(&vested);
    abort
}

// The local balance guard fires even after prior releases: once funds are partially
// drained, a curve attesting more than the *remaining* balance (`balance + released`)
// aborts with `EInsufficientBalance` rather than the framework split.
#[test, expected_failure(abort_code = vesting_wallet::EInsufficientBalance)]
fun release_aborts_when_releasable_exceeds_remaining_balance() {
    let mut ctx = tx_context::dummy();

    let mut wallet = new_wallet(BENEFICIARY, &mut ctx);
    wallet.deposit(mint(100));

    // Drain part of the balance: released = 60, balance = 40.
    let first = wallet.mint_vested_amount(TestCurve {}, 60);
    wallet.release(&first);

    // Attest 150 > balance + released (= 100); releasable = 90 > balance (= 40).
    let second = wallet.mint_vested_amount(TestCurve {}, 150);
    wallet.release(&second);
    abort
}

// A release that exactly drains the balance (releasable == balance) is allowed - the
// guard uses `<=`, so the boundary case succeeds rather than tripping the abort.
#[test]
fun release_allows_draining_exact_balance() {
    let mut ctx = tx_context::dummy();

    let mut wallet = new_wallet(BENEFICIARY, &mut ctx);
    wallet.deposit(mint(100));

    let vested = wallet.mint_vested_amount(TestCurve {}, 100);
    wallet.release(&vested);

    assert_eq!(wallet.released(), 100);
    assert_eq!(wallet.balance(), 0);

    destroy(wallet);
}

// === Teardown ===

// `destroy_empty` is permissionless, consumes the wallet by value and returns a
// `DestroyReceipt`, accepts an empty balance, emits `Destroyed`, and loses no value.
#[test]
fun destroy_empty_returns_params_and_emits() {
    let mut scenario = test_scenario::begin(@0x1);

    let wallet = new_wallet(BENEFICIARY, scenario.ctx());
    let wallet_id = object::id(&wallet);

    // TODO: use `destroy_empty` with a real `AccumulatorRoot` once
    // `accumulator::create_for_testing` ships in the published Sui mainnet framework.
    let receipt = wallet.destroy_empty_for_testing();
    assert_eq!(vesting_wallet::test_receipt_beneficiary(&receipt), BENEFICIARY);
    assert_eq!(vesting_wallet::test_receipt_params(&receipt), TestParams { tag: PARAMS_TAG });

    let destroyed = event::events_by_type<Destroyed<TestCurve, USDC>>();
    assert_eq!(destroyed.length(), 1);
    assert_eq!(
        destroyed[0],
        vesting_wallet::test_new_destroyed<TestCurve, USDC>(wallet_id, BENEFICIARY, 0),
    );

    destroy(receipt);
    scenario.end();
}

// Destroying a wallet that still holds a balance aborts.
#[test, expected_failure(abort_code = vesting_wallet::ENotEmpty)]
fun destroy_empty_rejects_nonempty_balance() {
    let mut ctx = tx_context::dummy();

    let mut wallet = new_wallet(BENEFICIARY, &mut ctx);
    wallet.deposit(mint(1));

    let _receipt = wallet.destroy_empty_for_testing();
    abort
}

// `destroy_empty` rejects a wallet whose object address still holds settled funds that
// have not been swept into the on-book balance (the `sweep_settled` source).
//
// TODO: un-ignore (uncomment and add `#[test, expected_failure(...)]`) once
// `accumulator::create_for_testing` ships in the published Sui mainnet framework. It also
// needs the imports `use sui::accumulator::{Self, AccumulatorRoot};` and
// `use sui::test_scenario::Scenario;`, plus the `seed_root` helper below. The unit VM may
// also need to actually settle the funds parked at the address for the gate to fire.
//
// fun seed_root(scenario: &mut Scenario, resume: address) {
//     scenario.next_tx(@0x0);
//     accumulator::create_for_testing(scenario.ctx());
//     scenario.next_tx(resume);
// }
//
// #[test, expected_failure(abort_code = vesting_wallet::EUnsweptFunds)]
// fun destroy_empty_rejects_unswept_settled_funds() {
//     let mut scenario = test_scenario::begin(@0x1);
//     seed_root(&mut scenario, @0x1);
//
//     let wallet = new_wallet(BENEFICIARY, scenario.ctx());
//     // Park settled funds at the wallet's object address without sweeping them in.
//     balance::send_funds(mint(1), object::id(&wallet).to_address());
//     scenario.next_tx(@0x1);
//
//     let root = scenario.take_shared<AccumulatorRoot>();
//     let _receipt = wallet.destroy_empty(&root);
//     abort
// }

// === State immutability ===

// The beneficiary, schedule params, and id are all fixed across
// an arbitrary sequence of mutating calls.
#[test]
fun beneficiary_params_and_id_are_immutable() {
    let mut ctx = tx_context::dummy();

    let mut wallet = new_wallet(BENEFICIARY, &mut ctx);
    let id_at_creation = object::id(&wallet);

    wallet.deposit(mint(1000));
    let vested = wallet.mint_vested_amount(TestCurve {}, 300);
    wallet.release(&vested);

    assert_eq!(wallet.beneficiary(), BENEFICIARY);
    assert_eq!(wallet.schedule_params(), TestParams { tag: PARAMS_TAG });
    assert_eq!(object::id(&wallet), id_at_creation);

    destroy(wallet);
}

// Released funds belong to the beneficiary and no later wallet operation
// can reduce them - there is no clawback path. The two payouts to the
// beneficiary are attested by their `Released` events, which together sum to
// exactly what was released.
#[test]
fun released_coins_stay_with_beneficiary() {
    let mut scenario = test_scenario::begin(@0x1);

    let mut wallet = new_wallet(BENEFICIARY, scenario.ctx());
    let wallet_id = object::id(&wallet);
    wallet.deposit(mint(1000));

    // First payout to the beneficiary: 400.
    let first = wallet.mint_vested_amount(TestCurve {}, 400);
    wallet.release(&first);
    let released = event::events_by_type<Released<TestCurve, USDC>>();
    assert_eq!(released.length(), 1);
    assert_eq!(
        released[0],
        vesting_wallet::test_new_released<TestCurve, USDC>(wallet_id, BENEFICIARY, 400),
    );

    // Further wallet activity in a later transaction pays the newly-vested
    // remainder (900 - 400 = 500); the earlier 400 is never reduced.
    scenario.next_tx(@0x1);
    let second = wallet.mint_vested_amount(TestCurve {}, 900);
    wallet.release(&second);
    assert_eq!(wallet.released(), 900);

    let released = event::events_by_type<Released<TestCurve, USDC>>();
    assert_eq!(released.length(), 1);
    assert_eq!(
        released[0],
        vesting_wallet::test_new_released<TestCurve, USDC>(wallet_id, BENEFICIARY, 500),
    );

    destroy(wallet);
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
    let wallet_id = object::id(&wallet);
    wallet.deposit(mint(1000));
    let vested = wallet.mint_vested_amount(TestCurve {}, 1000);
    wallet.release(&vested);

    destroy(wallet);
    destroy(placeholder);

    // The payout was directed at the object's address.
    let released = event::events_by_type<Released<TestCurve, USDC>>();
    assert_eq!(released.length(), 1);
    assert_eq!(
        released[0],
        vesting_wallet::test_new_released<TestCurve, USDC>(wallet_id, object_addr, 1000),
    );

    scenario.end();
}

// === Third-party wrapper ===

// The documented wrapper use case, driven directly: a curve-agnostic wrapper nests
// the wallet, mints a `VestedAmount` against the immutable `&inner` (the only access
// it exposes), and releases through its own `release` that delegates to the private
// `&mut inner`. An unrelated sender drives it, the funds flow to the construction-time
// beneficiary, and the wrapper never exposes `&mut inner`.
#[test]
fun release_through_third_party_wrapper() {
    let mut scenario = test_scenario::begin(@0xCAFE); // unrelated sender drives the wrapper

    let mut wallet = new_wallet(BENEFICIARY, scenario.ctx());
    let wallet_id = object::id(&wallet);
    wallet.deposit(mint(1000));
    let mut wrapper = wrap(wallet, scenario.ctx());

    // Curve-agnostic flow: mint against `&inner`, release through the wrapper.
    let vested = wrapper.inner().mint_vested_amount(TestCurve {}, 400);
    wrapper.release(&vested);

    assert_eq!(wrapper.inner().released(), 400);
    assert_eq!(wrapper.inner().balance(), 600);

    destroy(wrapper);

    // The payout went to the construction-time beneficiary, not the driver.
    let released = event::events_by_type<Released<TestCurve, USDC>>();
    assert_eq!(released.length(), 1);
    assert_eq!(
        released[0],
        vesting_wallet::test_new_released<TestCurve, USDC>(wallet_id, BENEFICIARY, 400),
    );

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
    let wallet_id = object::id(&wallet);
    wallet.deposit(mint(1000));
    transfer::public_transfer(wallet, bob);

    // Bob holds the wallet and pokes release.
    scenario.next_tx(bob);
    let mut wallet = scenario.take_from_sender<VestingWallet<TestCurve, TestParams, USDC>>();
    let vested = wallet.mint_vested_amount(TestCurve {}, 400);
    wallet.release(&vested);
    destroy(wallet);

    // Alice - not Bob - received the funds.
    let released = event::events_by_type<Released<TestCurve, USDC>>();
    assert_eq!(released.length(), 1);
    assert_eq!(
        released[0],
        vesting_wallet::test_new_released<TestCurve, USDC>(wallet_id, alice, 400),
    );

    scenario.end();
}

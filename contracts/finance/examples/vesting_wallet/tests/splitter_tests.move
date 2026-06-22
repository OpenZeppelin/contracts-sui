module openzeppelin_finance::example_splitter_tests;

use openzeppelin_finance::example_splitter::{Self, Beneficiary};
use openzeppelin_finance::vesting_wallet::VestingWallet;
use openzeppelin_finance::vesting_wallet_linear::{Self as linear, Linear, Params};
use std::unit_test::{assert_eq, destroy};
use sui::coin::{Self, Coin};
use sui::test_scenario as ts;

/// Phantom coin marker for the vested asset.
public struct USDC has drop {}

const EMPLOYER: address = @0xE;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const CAROL: address = @0xCA401;

const START_MS: u64 = 1_000;
const DURATION_MS: u64 = 4_000;
const TOTAL: u64 = 1_000_000;

// Happy path: a vesting wallet pays a `Beneficiary` splitter, which fans each payout
// out to three receivers by their 50/30/20 weights.
#[test]
fun release_to_splitter_fans_out_by_weight() {
    let mut scenario = ts::begin(EMPLOYER);
    let mut clock = sui::clock::create_for_testing(scenario.ctx());

    // Stand up the splitter; its address becomes the wallet's beneficiary.
    let splitter_addr = example_splitter::new(
        vector[ALICE, BOB, CAROL],
        vector[50, 30, 20],
        scenario.ctx(),
    );
    // Vest to the splitter object, not a person.
    linear::create_and_share<USDC>(splitter_addr, START_MS, 0, 1, DURATION_MS, scenario.ctx());

    scenario.next_tx(EMPLOYER);
    let mut wallet = scenario.take_shared<VestingWallet<Linear, Params, USDC>>();
    wallet.deposit(coin::mint_for_testing<USDC>(TOTAL, scenario.ctx()));

    // Release the full total at the end of the schedule; it lands at the splitter.
    clock.set_for_testing(START_MS + DURATION_MS);
    linear::release(&mut wallet, &clock, scenario.ctx());
    ts::return_shared(wallet);

    // Anyone fans the parked payout out to the three receivers.
    scenario.next_tx(EMPLOYER);
    let mut splitter = scenario.take_shared<Beneficiary>();
    let payout = ts::most_recent_receiving_ticket<Coin<USDC>>(&object::id(&splitter));
    splitter.disperse<USDC>(payout, scenario.ctx());
    ts::return_shared(splitter);

    // 50/30/20 of the total, conserving every unit.
    scenario.next_tx(EMPLOYER);
    let to_alice = scenario.take_from_address<Coin<USDC>>(ALICE);
    let to_bob = scenario.take_from_address<Coin<USDC>>(BOB);
    let to_carol = scenario.take_from_address<Coin<USDC>>(CAROL);
    assert_eq!(to_alice.value(), TOTAL * 50 / 100);
    assert_eq!(to_bob.value(), TOTAL * 30 / 100);
    assert_eq!(to_carol.value(), TOTAL * 20 / 100);
    assert_eq!(to_alice.value() + to_bob.value() + to_carol.value(), TOTAL);

    destroy(to_alice);
    destroy(to_bob);
    destroy(to_carol);
    sui::clock::destroy_for_testing(clock);
    scenario.end();
}

// Conservation under rounding: with weights that don't divide the payout evenly, the
// floored shares plus the last receiver's remainder still sum to the exact total, and
// the last receiver absorbs the dust.
#[test]
fun rounding_dust_goes_to_last_receiver() {
    let mut scenario = ts::begin(EMPLOYER);

    // 1/3 each of 100: floor gives 33, 33, and the last receiver takes 34.
    let splitter_addr = example_splitter::new(
        vector[ALICE, BOB, CAROL],
        vector[1, 1, 1],
        scenario.ctx(),
    );

    scenario.next_tx(EMPLOYER);
    let mut splitter = scenario.take_shared<Beneficiary>();
    transfer::public_transfer(coin::mint_for_testing<USDC>(100, scenario.ctx()), splitter_addr);

    scenario.next_tx(EMPLOYER);
    let payout = ts::most_recent_receiving_ticket<Coin<USDC>>(&object::id(&splitter));
    splitter.disperse<USDC>(payout, scenario.ctx());
    ts::return_shared(splitter);

    scenario.next_tx(EMPLOYER);
    let to_alice = scenario.take_from_address<Coin<USDC>>(ALICE);
    let to_bob = scenario.take_from_address<Coin<USDC>>(BOB);
    let to_carol = scenario.take_from_address<Coin<USDC>>(CAROL);
    assert_eq!(to_alice.value(), 33);
    assert_eq!(to_bob.value(), 33);
    assert_eq!(to_carol.value(), 34); // absorbs the +1 dust
    assert_eq!(to_alice.value() + to_bob.value() + to_carol.value(), 100);

    destroy(to_alice);
    destroy(to_bob);
    destroy(to_carol);
    scenario.end();
}

// A single receiver takes the whole payout: the loop runs zero iterations and the lone
// receiver absorbs the full coin as the "last" one.
#[test]
fun single_receiver_takes_everything() {
    let mut scenario = ts::begin(EMPLOYER);

    let splitter_addr = example_splitter::new(vector[ALICE], vector[7], scenario.ctx());

    scenario.next_tx(EMPLOYER);
    let mut splitter = scenario.take_shared<Beneficiary>();
    transfer::public_transfer(coin::mint_for_testing<USDC>(100, scenario.ctx()), splitter_addr);

    scenario.next_tx(EMPLOYER);
    let payout = ts::most_recent_receiving_ticket<Coin<USDC>>(&object::id(&splitter));
    splitter.disperse<USDC>(payout, scenario.ctx());
    ts::return_shared(splitter);

    scenario.next_tx(EMPLOYER);
    let to_alice = scenario.take_from_address<Coin<USDC>>(ALICE);
    assert_eq!(to_alice.value(), 100);

    destroy(to_alice);
    scenario.end();
}

// The view helpers echo the config fixed at creation.
#[test]
fun view_helpers_expose_config() {
    let mut scenario = ts::begin(EMPLOYER);

    example_splitter::new(vector[ALICE, BOB, CAROL], vector[50, 30, 20], scenario.ctx());

    scenario.next_tx(EMPLOYER);
    let splitter = scenario.take_shared<Beneficiary>();
    assert_eq!(splitter.receivers(), vector[ALICE, BOB, CAROL]);
    assert_eq!(splitter.weights(), vector[50, 30, 20]);
    assert_eq!(splitter.total_weight(), 100);

    ts::return_shared(splitter);
    scenario.end();
}

// `new` rejects mismatched receivers/weights lengths.
#[test, expected_failure(abort_code = example_splitter::EBadConfig)]
fun new_rejects_length_mismatch() {
    let mut scenario = ts::begin(EMPLOYER);
    example_splitter::new(vector[ALICE, BOB], vector[50], scenario.ctx());
    abort
}

// `new` rejects empty config vectors.
#[test, expected_failure(abort_code = example_splitter::EBadConfig)]
fun new_rejects_empty_config() {
    let mut scenario = ts::begin(EMPLOYER);
    example_splitter::new(vector[], vector[], scenario.ctx());
    abort
}

// `new` rejects a zero weight.
#[test, expected_failure(abort_code = example_splitter::EZeroWeight)]
fun new_rejects_zero_weight() {
    let mut scenario = ts::begin(EMPLOYER);
    example_splitter::new(vector[ALICE, BOB], vector[50, 0], scenario.ctx());
    abort
}

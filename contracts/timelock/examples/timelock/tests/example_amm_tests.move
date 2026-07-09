// Scenario walkthroughs for the single-timelock, AccessControl-gated AMM.
//
// Bare `abort` follows each known-aborting call in the `expected_failure` tests: it is
// unreachable and only satisfies the checker on bindings left unconsumed before the abort.
module openzeppelin_timelock::example_amm_tests;

use openzeppelin_access::access_control::AccessControl;
use openzeppelin_timelock::example_amm::{
    Self,
    Pool,
    EXAMPLE_AMM,
    ProposerRole,
    ExecutorRole,
    CancellerRole,
    TimelockAdminRole,
    FeeChangeAction
};
use openzeppelin_timelock::timelock::{Self, Timelock};
use std::unit_test::assert_eq;
use sui::clock;
use sui::event;
use sui::test_scenario::{Self, Scenario};

const PUBLISHER: address = @0xA;
const ALICE: address = @0xB; // proposer
const BOB: address = @0xC; // executor
const ADMIN: address = @0xD; // timelock admin

const DAY_MS: u64 = 24 * 60 * 60 * 1_000;

fun deploy(): Scenario {
    let mut scenario = test_scenario::begin(PUBLISHER);
    example_amm::init_for_testing(scenario.ctx());
    scenario.next_tx(PUBLISHER);
    scenario
}

// === Happy path: a fee change goes through the full delay cycle ===
#[test]
fun fee_change_happy() {
    let mut scenario = deploy();

    let mut ac = scenario.take_shared<AccessControl<EXAMPLE_AMM>>();
    ac.grant_role<_, ProposerRole>(ALICE, scenario.ctx());
    ac.grant_role<_, ExecutorRole>(BOB, scenario.ctx());
    test_scenario::return_shared(ac);

    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);

    // ALICE (proposer): schedule fee 30 -> 42 (passed by value, stored on-chain).
    scenario.next_tx(ALICE);
    let mut timelock = scenario.take_shared<Timelock>();
    let pool = scenario.take_shared<Pool>();
    let ac = scenario.take_shared<AccessControl<EXAMPLE_AMM>>();
    let proposer = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id = example_amm::schedule_fee_change(
        &mut timelock,
        &pool,
        &proposer,
        42,
        vector[],
        b"fee",
        DAY_MS,
        &clk,
        scenario.ctx(),
    );
    test_scenario::return_shared(timelock);
    test_scenario::return_shared(pool);
    test_scenario::return_shared(ac);

    clk.set_for_testing(DAY_MS);

    // BOB (executor): execute by id -> consume -> apply.
    scenario.next_tx(BOB);
    let mut timelock = scenario.take_shared<Timelock>();
    let mut pool = scenario.take_shared<Pool>();
    let ac = scenario.take_shared<AccessControl<EXAMPLE_AMM>>();
    let executor = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    example_amm::execute_fee_change(&mut timelock, &mut pool, &executor, id, &clk, scenario.ctx());

    assert_eq!(example_amm::pool_fee_bps(&pool), 42);
    let changed = event::events_by_type<example_amm::FeeChanged>();
    assert_eq!(changed.length(), 1);
    assert_eq!(changed[0], example_amm::new_fee_changed(id, 30, 42));

    test_scenario::return_shared(timelock);
    test_scenario::return_shared(pool);
    test_scenario::return_shared(ac);
    clock::destroy_for_testing(clk);
    scenario.end();
}

// === The canonical-id binding stops a fake-timelock delay bypass ===
//
// An actor with the executor role builds their OWN zero-delay timelock of the same role
// types and tries to route it through execute_fee_change to apply a fee to the real pool
// with no delay. The pool's `OperationCap` binding rejects it - with no consumer assert.
#[test, expected_failure(abort_code = timelock::EWrongTimelock)]
fun fake_timelock_rejected() {
    let mut scenario = deploy();

    let mut ac = scenario.take_shared<AccessControl<EXAMPLE_AMM>>();
    ac.grant_role<_, ExecutorRole>(BOB, scenario.ctx());
    test_scenario::return_shared(ac);

    let clk = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(BOB);
    let mut fake_tl = timelock::new<ProposerRole, ExecutorRole, CancellerRole, TimelockAdminRole>(
        0,
        1000,
        scenario.ctx(),
    );
    let mut pool = scenario.take_shared<Pool>();
    let ac = scenario.take_shared<AccessControl<EXAMPLE_AMM>>();
    let executor = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    example_amm::execute_fee_change(
        &mut fake_tl,
        &mut pool,
        &executor,
        b"anyid",
        &clk,
        scenario.ctx(),
    );
    abort
}

// === Wrong role cannot schedule (library-direct) ===
#[test, expected_failure(abort_code = timelock::EWrongRole)]
fun wrong_role_cannot_schedule() {
    let mut scenario = deploy();

    let mut ac = scenario.take_shared<AccessControl<EXAMPLE_AMM>>();
    ac.grant_role<_, ExecutorRole>(BOB, scenario.ctx());
    test_scenario::return_shared(ac);

    let clk = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(BOB);
    let mut timelock = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<EXAMPLE_AMM>>();
    let executor = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    // Executor role used where proposer is required.
    let _id = timelock.schedule<ExecutorRole, FeeChangeAction, u16>(
        &executor,
        42,
        vector[],
        b"fee",
        DAY_MS,
        &clk,
        scenario.ctx(),
    );
    abort
}

// === Execute before the delay elapses ===
#[test, expected_failure(abort_code = timelock::EDelayNotElapsed)]
fun execute_before_ready() {
    let mut scenario = deploy();

    let mut ac = scenario.take_shared<AccessControl<EXAMPLE_AMM>>();
    ac.grant_role<_, ProposerRole>(ALICE, scenario.ctx());
    ac.grant_role<_, ExecutorRole>(ALICE, scenario.ctx());
    test_scenario::return_shared(ac);

    let clk = clock::create_for_testing(scenario.ctx()); // stays at 0

    scenario.next_tx(ALICE);
    let mut timelock = scenario.take_shared<Timelock>();
    let mut pool = scenario.take_shared<Pool>();
    let ac = scenario.take_shared<AccessControl<EXAMPLE_AMM>>();
    let proposer = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id = example_amm::schedule_fee_change(
        &mut timelock,
        &pool,
        &proposer,
        42,
        vector[],
        b"fee",
        DAY_MS,
        &clk,
        scenario.ctx(),
    );
    let executor = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    example_amm::execute_fee_change(&mut timelock, &mut pool, &executor, id, &clk, scenario.ctx());
    abort
}

// === Predecessor ordering: B (predecessor A) cannot execute before A is done ===
#[test, expected_failure(abort_code = timelock::EPredecessorNotDone)]
fun predecessor_blocks_until_done() {
    let mut scenario = deploy();

    let mut ac = scenario.take_shared<AccessControl<EXAMPLE_AMM>>();
    ac.grant_role<_, ProposerRole>(ALICE, scenario.ctx());
    ac.grant_role<_, ExecutorRole>(BOB, scenario.ctx());
    test_scenario::return_shared(ac);

    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);

    scenario.next_tx(ALICE);
    let mut timelock = scenario.take_shared<Timelock>();
    let pool = scenario.take_shared<Pool>();
    let ac = scenario.take_shared<AccessControl<EXAMPLE_AMM>>();
    let proposer = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id_a = example_amm::schedule_fee_change(
        &mut timelock,
        &pool,
        &proposer,
        42,
        vector[],
        b"a",
        DAY_MS,
        &clk,
        scenario.ctx(),
    );
    let id_b = example_amm::schedule_fee_change(
        &mut timelock,
        &pool,
        &proposer,
        50,
        id_a,
        b"b",
        DAY_MS,
        &clk,
        scenario.ctx(),
    );
    test_scenario::return_shared(timelock);
    test_scenario::return_shared(pool);
    test_scenario::return_shared(ac);

    clk.set_for_testing(DAY_MS);

    scenario.next_tx(BOB);
    let mut timelock = scenario.take_shared<Timelock>();
    let mut pool = scenario.take_shared<Pool>();
    let ac = scenario.take_shared<AccessControl<EXAMPLE_AMM>>();
    let executor = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    // Execute B (predecessor = A) before A.
    example_amm::execute_fee_change(
        &mut timelock,
        &mut pool,
        &executor,
        id_b,
        &clk,
        scenario.ctx(),
    );
    abort
}

// === Predecessor ordering: A then B, each effect applied in order ===
#[test]
fun predecessor_ordering_happy() {
    let mut scenario = deploy();

    let mut ac = scenario.take_shared<AccessControl<EXAMPLE_AMM>>();
    ac.grant_role<_, ProposerRole>(ALICE, scenario.ctx());
    ac.grant_role<_, ExecutorRole>(BOB, scenario.ctx());
    test_scenario::return_shared(ac);

    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);

    scenario.next_tx(ALICE);
    let mut timelock = scenario.take_shared<Timelock>();
    let pool = scenario.take_shared<Pool>();
    let ac = scenario.take_shared<AccessControl<EXAMPLE_AMM>>();
    let proposer = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id_a = example_amm::schedule_fee_change(
        &mut timelock,
        &pool,
        &proposer,
        42,
        vector[],
        b"a",
        DAY_MS,
        &clk,
        scenario.ctx(),
    );
    let id_b = example_amm::schedule_fee_change(
        &mut timelock,
        &pool,
        &proposer,
        50,
        id_a,
        b"b",
        DAY_MS,
        &clk,
        scenario.ctx(),
    );
    test_scenario::return_shared(timelock);
    test_scenario::return_shared(pool);
    test_scenario::return_shared(ac);

    clk.set_for_testing(DAY_MS);

    scenario.next_tx(BOB);
    let mut timelock = scenario.take_shared<Timelock>();
    let mut pool = scenario.take_shared<Pool>();
    let ac = scenario.take_shared<AccessControl<EXAMPLE_AMM>>();
    let executor_a = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    example_amm::execute_fee_change(
        &mut timelock,
        &mut pool,
        &executor_a,
        id_a,
        &clk,
        scenario.ctx(),
    );
    assert_eq!(example_amm::pool_fee_bps(&pool), 42);
    let executor_b = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    example_amm::execute_fee_change(
        &mut timelock,
        &mut pool,
        &executor_b,
        id_b,
        &clk,
        scenario.ctx(),
    );
    assert_eq!(example_amm::pool_fee_bps(&pool), 50);

    test_scenario::return_shared(timelock);
    test_scenario::return_shared(pool);
    test_scenario::return_shared(ac);
    clock::destroy_for_testing(clk);
    scenario.end();
}

// === Cancel a pending fee change ===
#[test]
fun cancel_fee_change() {
    let mut scenario = deploy();

    let mut ac = scenario.take_shared<AccessControl<EXAMPLE_AMM>>();
    ac.grant_role<_, ProposerRole>(ALICE, scenario.ctx());
    ac.grant_role<_, CancellerRole>(ALICE, scenario.ctx());
    test_scenario::return_shared(ac);

    let clk = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let mut timelock = scenario.take_shared<Timelock>();
    let pool = scenario.take_shared<Pool>();
    let ac = scenario.take_shared<AccessControl<EXAMPLE_AMM>>();
    let proposer = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id = example_amm::schedule_fee_change(
        &mut timelock,
        &pool,
        &proposer,
        42,
        vector[],
        b"fee",
        DAY_MS,
        &clk,
        scenario.ctx(),
    );
    assert!(timelock.is_operation(id));
    let canceller = ac.new_auth<_, CancellerRole>(scenario.ctx());
    example_amm::cancel_fee_change(&mut timelock, &pool, &canceller, id, scenario.ctx());
    assert!(!timelock.is_operation(id));

    test_scenario::return_shared(timelock);
    test_scenario::return_shared(pool);
    test_scenario::return_shared(ac);
    clock::destroy_for_testing(clk);
    scenario.end();
}

// === Self-administered delay change (TimelockAdminRole) ===
#[test]
fun self_admin_delay_change() {
    let mut scenario = deploy();

    let mut ac = scenario.take_shared<AccessControl<EXAMPLE_AMM>>();
    ac.grant_role<_, TimelockAdminRole>(ADMIN, scenario.ctx());
    test_scenario::return_shared(ac);

    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);

    scenario.next_tx(ADMIN);
    let mut timelock = scenario.take_shared<Timelock>();
    let pool = scenario.take_shared<Pool>();
    let ac = scenario.take_shared<AccessControl<EXAMPLE_AMM>>();
    let admin = ac.new_auth<_, TimelockAdminRole>(scenario.ctx());
    // The pool exposes its bound timelock id (used by the explicit-bind self-admin path).
    assert_eq!(example_amm::pool_timelock_id(&pool), object::id(&timelock));
    let id = example_amm::schedule_delay_change(
        &mut timelock,
        &pool,
        &admin,
        2 * DAY_MS,
        b"d",
        DAY_MS,
        &clk,
        scenario.ctx(),
    );
    test_scenario::return_shared(timelock);
    test_scenario::return_shared(pool);
    test_scenario::return_shared(ac);

    clk.set_for_testing(DAY_MS);

    scenario.next_tx(ADMIN);
    let mut timelock = scenario.take_shared<Timelock>();
    let pool = scenario.take_shared<Pool>();
    let ac = scenario.take_shared<AccessControl<EXAMPLE_AMM>>();
    let admin = ac.new_auth<_, TimelockAdminRole>(scenario.ctx());
    example_amm::execute_delay_change(&mut timelock, &pool, &admin, id, &clk, scenario.ctx());
    assert_eq!(timelock.min_delay_ms(), 2 * DAY_MS);
    test_scenario::return_shared(timelock);
    test_scenario::return_shared(pool);
    test_scenario::return_shared(ac);

    clock::destroy_for_testing(clk);
    scenario.end();
}

// === The consumer's own explicit-bind guard (self-admin path) ===
//
// The self-admin config path can't use an OperationCap, so the example keeps a hand-written
// object::id assert (example_amm::EWrongTimelock). A foreign timelock routed through it aborts
// with the CONSUMER's error (code 0) - distinct from the library's timelock::EWrongTimelock,
// which guards the cap-bound op flow.
#[test, expected_failure(abort_code = example_amm::EWrongTimelock)]
fun self_admin_rejects_foreign_timelock() {
    let mut scenario = deploy();

    let mut ac = scenario.take_shared<AccessControl<EXAMPLE_AMM>>();
    ac.grant_role<_, TimelockAdminRole>(ADMIN, scenario.ctx());
    test_scenario::return_shared(ac);

    let clk = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    let mut fake_tl = timelock::new<ProposerRole, ExecutorRole, CancellerRole, TimelockAdminRole>(
        0,
        1000,
        scenario.ctx(),
    );
    let pool = scenario.take_shared<Pool>();
    let ac = scenario.take_shared<AccessControl<EXAMPLE_AMM>>();
    let admin = ac.new_auth<_, TimelockAdminRole>(scenario.ctx());
    // schedule_delay_change asserts object::id(fake_tl) == pool.timelock_id first -> abort.
    let _id = example_amm::schedule_delay_change(
        &mut fake_tl,
        &pool,
        &admin,
        2 * DAY_MS,
        b"d",
        0,
        &clk,
        scenario.ctx(),
    );
    abort
}

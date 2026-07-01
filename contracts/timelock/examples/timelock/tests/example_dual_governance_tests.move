// Scenario walkthroughs for the dual-timelock governance example (main + emergency).
//
// Bare `abort` follows each known-aborting call in the `expected_failure` tests: it is
// unreachable and only satisfies the checker on bindings left unconsumed before the abort.
module openzeppelin_timelock::example_dual_governance_tests;

use openzeppelin_access::access_control::AccessControl;
use openzeppelin_timelock::example_dual_governance::{
    Self,
    Pool,
    EXAMPLE_DUAL_GOVERNANCE,
    ProposerRole,
    ExecutorRole,
    EmergencyRole
};
use openzeppelin_timelock::timelock::{Self, Timelock};
use std::unit_test::assert_eq;
use sui::clock;
use sui::test_scenario::{Self, Scenario};

const PUBLISHER: address = @0xA;
const ALICE: address = @0xB; // main proposer
const BOB: address = @0xC; // main executor
const CAROL: address = @0xD; // emergency committee

const HOUR_MS: u64 = 60 * 60 * 1_000;
const DAY_MS: u64 = 24 * HOUR_MS;

fun deploy(): Scenario {
    let mut scenario = test_scenario::begin(PUBLISHER);
    example_dual_governance::init_for_testing(scenario.ctx());
    scenario.next_tx(PUBLISHER);
    scenario
}

// === Routine governance and emergency response run on separate timelocks ===
#[test]
fun dual_routine_and_emergency() {
    let mut scenario = deploy();

    let mut ac = scenario.take_shared<AccessControl<EXAMPLE_DUAL_GOVERNANCE>>();
    ac.grant_role<_, ProposerRole>(ALICE, scenario.ctx());
    ac.grant_role<_, ExecutorRole>(BOB, scenario.ctx());
    ac.grant_role<_, EmergencyRole>(CAROL, scenario.ctx());
    test_scenario::return_shared(ac);

    scenario.next_tx(PUBLISHER);
    let pool = scenario.take_shared<Pool>();
    let main_id = example_dual_governance::main_timelock_id(&pool);
    let emergency_id = example_dual_governance::emergency_timelock_id(&pool);
    test_scenario::return_shared(pool);

    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);

    // ALICE: schedule routine fee change on MAIN.
    scenario.next_tx(ALICE);
    let mut main_tl = test_scenario::take_shared_by_id<Timelock>(&scenario, main_id);
    let pool = scenario.take_shared<Pool>();
    let ac = scenario.take_shared<AccessControl<EXAMPLE_DUAL_GOVERNANCE>>();
    let proposer = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let fee_id = example_dual_governance::schedule_fee_change(
        &mut main_tl,
        &pool,
        &proposer,
        42,
        b"fee",
        DAY_MS,
        &clk,
        scenario.ctx(),
    );
    test_scenario::return_shared(main_tl);
    test_scenario::return_shared(pool);
    test_scenario::return_shared(ac);

    // CAROL: schedule emergency pause on EMERGENCY.
    scenario.next_tx(CAROL);
    let mut emergency_tl = test_scenario::take_shared_by_id<Timelock>(&scenario, emergency_id);
    let pool = scenario.take_shared<Pool>();
    let ac = scenario.take_shared<AccessControl<EXAMPLE_DUAL_GOVERNANCE>>();
    let emergency = ac.new_auth<_, EmergencyRole>(scenario.ctx());
    let pause_id = example_dual_governance::schedule_emergency_pause(
        &mut emergency_tl,
        &pool,
        &emergency,
        true,
        b"pause",
        HOUR_MS,
        &clk,
        scenario.ctx(),
    );
    test_scenario::return_shared(emergency_tl);
    test_scenario::return_shared(pool);
    test_scenario::return_shared(ac);

    clk.set_for_testing(DAY_MS);

    // BOB: execute routine fee change on MAIN.
    scenario.next_tx(BOB);
    let mut main_tl = test_scenario::take_shared_by_id<Timelock>(&scenario, main_id);
    let mut pool = scenario.take_shared<Pool>();
    let ac = scenario.take_shared<AccessControl<EXAMPLE_DUAL_GOVERNANCE>>();
    let executor = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    example_dual_governance::execute_fee_change(
        &mut main_tl,
        &mut pool,
        &executor,
        fee_id,
        &clk,
        scenario.ctx(),
    );
    assert_eq!(example_dual_governance::pool_fee_bps(&pool), 42);
    test_scenario::return_shared(main_tl);
    test_scenario::return_shared(pool);
    test_scenario::return_shared(ac);

    // CAROL: execute emergency pause on EMERGENCY.
    scenario.next_tx(CAROL);
    let mut emergency_tl = test_scenario::take_shared_by_id<Timelock>(&scenario, emergency_id);
    let mut pool = scenario.take_shared<Pool>();
    let ac = scenario.take_shared<AccessControl<EXAMPLE_DUAL_GOVERNANCE>>();
    let emergency = ac.new_auth<_, EmergencyRole>(scenario.ctx());
    example_dual_governance::execute_emergency_pause(
        &mut emergency_tl,
        &mut pool,
        &emergency,
        pause_id,
        &clk,
        scenario.ctx(),
    );
    assert!(example_dual_governance::pool_paused(&pool));
    test_scenario::return_shared(emergency_tl);
    test_scenario::return_shared(pool);
    test_scenario::return_shared(ac);

    clock::destroy_for_testing(clk);
    scenario.end();
}

// === A main-class action cannot be routed through the emergency timelock ===
#[test, expected_failure(abort_code = timelock::EWrongTimelock)]
fun misroute_fee_through_emergency() {
    let mut scenario = deploy();

    let mut ac = scenario.take_shared<AccessControl<EXAMPLE_DUAL_GOVERNANCE>>();
    ac.grant_role<_, ProposerRole>(ALICE, scenario.ctx());
    test_scenario::return_shared(ac);

    scenario.next_tx(PUBLISHER);
    let pool = scenario.take_shared<Pool>();
    let emergency_id = example_dual_governance::emergency_timelock_id(&pool);
    test_scenario::return_shared(pool);

    let clk = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let mut emergency_tl = test_scenario::take_shared_by_id<Timelock>(&scenario, emergency_id);
    let pool = scenario.take_shared<Pool>();
    let ac = scenario.take_shared<AccessControl<EXAMPLE_DUAL_GOVERNANCE>>();
    let proposer = ac.new_auth<_, ProposerRole>(scenario.ctx());
    // fee_cap is bound to MAIN; passing the EMERGENCY timelock aborts inside the library.
    let _id = example_dual_governance::schedule_fee_change(
        &mut emergency_tl,
        &pool,
        &proposer,
        42,
        b"fee",
        DAY_MS,
        &clk,
        scenario.ctx(),
    );
    abort
}

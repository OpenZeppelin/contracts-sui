// Bare `abort` sentinels appear after each known-aborting call in the
// `expected_failure` tests - deliberate and unreachable, only there to satisfy
// the type/resource checker on bindings left unconsumed before the abort.
module openzeppelin_timelock::timelock_tests;

use openzeppelin_access::access_control::{Self, AccessControl};
use openzeppelin_timelock::timelock::{Self, Timelock};
use std::type_name::with_original_ids;
use std::unit_test::{assert_eq, destroy};
use sui::bcs;
use sui::clock;
use sui::event;
use sui::hash;
use sui::test_scenario::{Self, Scenario};

// === Test fixtures ===

public struct TIMELOCK_TESTS has drop {}

public struct ProposerRole {}
public struct ExecutorRole {}
public struct CancellerRole {}
public struct AdminRole {}

/// Consumer operation witness (the `Action`), drop-only, module-private construction.
public struct TestAction has drop {}

/// A second witness sharing `TestAction`'s `Params` type, to prove an op scheduled for one
/// `Action` cannot be executed as another (`EWrongAction`).
public struct OtherAction has drop {}

const DEPLOYER: address = @0xA;

// === Setup helpers ===

#[test_only]
fun setup(min_delay_ms: u64, grace_period_ms: u64): Scenario {
    let mut scenario = test_scenario::begin(DEPLOYER);
    {
        let mut ac = access_control::new<TIMELOCK_TESTS>(TIMELOCK_TESTS {}, 0, scenario.ctx());
        ac.grant_role<_, ProposerRole>(DEPLOYER, scenario.ctx());
        ac.grant_role<_, ExecutorRole>(DEPLOYER, scenario.ctx());
        ac.grant_role<_, CancellerRole>(DEPLOYER, scenario.ctx());
        ac.grant_role<_, AdminRole>(DEPLOYER, scenario.ctx());
        transfer::public_share_object(ac);
        timelock::new_shared<ProposerRole, ExecutorRole, CancellerRole, AdminRole>(
            min_delay_ms,
            grace_period_ms,
            scenario.ctx(),
        );
    };
    scenario.next_tx(DEPLOYER);
    scenario
}

/// keccak256(bcs(value)) - the on-chain payload digest for a `u64` param.
#[test_only]
fun digest_of(value: u64): vector<u8> {
    hash::keccak256(&bcs::to_bytes(&value))
}

// === Construction ===

#[test]
fun new_emits_event_and_sets_config() {
    let mut scenario = test_scenario::begin(DEPLOYER);
    let id = timelock::new_shared<ProposerRole, ExecutorRole, CancellerRole, AdminRole>(
        1000,
        5000,
        scenario.ctx(),
    );

    let created = event::events_by_type<timelock::TimelockCreated>();
    assert_eq!(created.length(), 1);
    let expected = timelock::test_new_timelock_created(
        id,
        1000,
        5000,
        with_original_ids<ProposerRole>(),
        with_original_ids<ExecutorRole>(),
        with_original_ids<CancellerRole>(),
        with_original_ids<AdminRole>(),
    );
    assert_eq!(created[0], expected);

    scenario.next_tx(DEPLOYER);
    let tl = scenario.take_shared<Timelock>();
    assert_eq!(tl.min_delay_ms(), 1000);
    assert_eq!(tl.grace_period_ms(), 5000);
    assert_eq!(tl.proposer_role(), with_original_ids<ProposerRole>());
    assert_eq!(tl.executor_role(), with_original_ids<ExecutorRole>());
    assert_eq!(tl.canceller_role(), with_original_ids<CancellerRole>());
    assert_eq!(tl.admin_role(), with_original_ids<AdminRole>());
    assert!(!tl.is_open_executor());
    assert!(!tl.is_operation_done(b"ghost")); // unset id -> false (early return)
    test_scenario::return_shared(tl);
    scenario.end();
}

#[test, expected_failure(abort_code = timelock::EInvalidConfig)]
fun new_rejects_zero_grace() {
    let mut scenario = test_scenario::begin(DEPLOYER);
    let _tl = timelock::new<ProposerRole, ExecutorRole, CancellerRole, AdminRole>(
        0,
        0,
        scenario.ctx(),
    );
    abort
}

#[test, expected_failure(abort_code = timelock::EInvalidConfig)]
fun new_rejects_excessive_grace() {
    let mut scenario = test_scenario::begin(DEPLOYER);
    let _tl = timelock::new<ProposerRole, ExecutorRole, CancellerRole, AdminRole>(
        0,
        timelock::max_delay_ms() + 1,
        scenario.ctx(),
    );
    abort
}

#[test, expected_failure(abort_code = timelock::EInvalidConfig)]
fun new_rejects_excessive_min_delay() {
    let mut scenario = test_scenario::begin(DEPLOYER);
    let _tl = timelock::new<ProposerRole, ExecutorRole, CancellerRole, AdminRole>(
        timelock::max_delay_ms() + 1,
        1000,
        scenario.ctx(),
    );
    abort
}

#[test]
fun min_delay_zero_allows_instant_op() {
    let mut scenario = setup(0, 1000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);

    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"s",
        0,
        &clk,
        scenario.ctx(),
    );
    assert!(tl.is_operation_ready(id, &clk));
    let e_auth = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    let ticket = tl.execute<ExecutorRole, TestAction, u64>(&e_auth, id, &clk, scenario.ctx());
    let (rid, params) = tl.consume(ticket, TestAction {});
    assert_eq!(rid, id);
    assert_eq!(params, 42);
    assert!(tl.is_operation_done(id));

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(tl);
    test_scenario::return_shared(ac);
    scenario.end();
}

// === Happy path ===

#[test]
fun schedule_execute_consume_happy() {
    let mut scenario = setup(1000, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);

    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"salt",
        1000,
        &clk,
        scenario.ctx(),
    );

    // Scheduled event (carries the action TypeName + payload digest).
    let scheduled = event::events_by_type<timelock::OperationScheduled>();
    assert_eq!(scheduled.length(), 1);
    let expected_scheduled = timelock::test_new_operation_scheduled(
        id,
        with_original_ids<TestAction>(),
        digest_of(42),
        vector[],
        b"salt",
        1000,
        11000,
        DEPLOYER,
    );
    assert_eq!(scheduled[0], expected_scheduled);

    // The scheduled params are readable on-chain during the delay.
    assert_eq!(*tl.operation_params<u64>(id), 42);

    assert!(tl.is_operation_pending(id, &clk));
    assert!(!tl.is_operation_ready(id, &clk));
    clk.set_for_testing(1000);
    assert!(tl.is_operation_ready(id, &clk));

    let e_auth = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    let ticket = tl.execute<ExecutorRole, TestAction, u64>(&e_auth, id, &clk, scenario.ctx());
    let (rid, params) = tl.consume(ticket, TestAction {});
    assert_eq!(rid, id);
    assert_eq!(params, 42);
    assert!(tl.is_operation_done(id));

    let executed = event::events_by_type<timelock::OperationExecuted>();
    assert_eq!(executed.length(), 1);
    assert_eq!(
        executed[0],
        timelock::test_new_operation_executed(id, with_original_ids<TestAction>(), DEPLOYER),
    );

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(tl);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun cancel_happy() {
    let mut scenario = setup(1000, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);

    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"salt",
        1000,
        &clk,
        scenario.ctx(),
    );
    assert!(tl.is_operation(id));

    let c_auth = ac.new_auth<_, CancellerRole>(scenario.ctx());
    tl.cancel<CancellerRole, u64>(&c_auth, id, scenario.ctx());
    assert!(!tl.is_operation(id));

    let cancelled = event::events_by_type<timelock::OperationCancelled>();
    assert_eq!(cancelled.length(), 1);
    assert_eq!(
        cancelled[0],
        timelock::test_new_operation_cancelled(id, with_original_ids<TestAction>(), DEPLOYER),
    );

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(tl);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun cancel_succeeds_after_expiry() {
    let mut scenario = setup(0, 100);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);

    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"salt",
        50,
        &clk,
        scenario.ctx(),
    );
    // Past the grace window: no longer pending, but still resident and cancellable.
    clk.set_for_testing(150);
    assert!(tl.is_operation_expired(id, &clk));
    assert!(!tl.is_operation_pending(id, &clk));

    let c_auth = ac.new_auth<_, CancellerRole>(scenario.ctx());
    tl.cancel<CancellerRole, u64>(&c_auth, id, scenario.ctx());
    assert!(!tl.is_operation(id));

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(tl);
    test_scenario::return_shared(ac);
    scenario.end();
}

// === Role gating ===

#[test, expected_failure(abort_code = timelock::EWrongRole)]
fun schedule_rejects_wrong_role() {
    let mut scenario = setup(0, 1000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    let wrong = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    let _id = tl.schedule<ExecutorRole, TestAction, u64>(
        &wrong,
        42,
        vector[],
        b"s",
        0,
        &clk,
        scenario.ctx(),
    );
    abort
}

#[test, expected_failure(abort_code = timelock::EWrongRole)]
fun execute_rejects_wrong_role() {
    let mut scenario = setup(0, 1000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    let wrong = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let _ticket = tl.execute<ProposerRole, TestAction, u64>(&wrong, b"anyid", &clk, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = timelock::EWrongRole)]
fun cancel_rejects_wrong_role() {
    let mut scenario = setup(0, 1000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let wrong = ac.new_auth<_, ProposerRole>(scenario.ctx());
    tl.cancel<ProposerRole, u64>(&wrong, b"anyid", scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = timelock::EWrongRole)]
fun self_admin_rejects_non_admin() {
    let mut scenario = setup(0, 1000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    let wrong = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let _id = tl.schedule_update_min_delay<ProposerRole>(
        &wrong,
        5000,
        vector[],
        b"s",
        0,
        &clk,
        scenario.ctx(),
    );
    abort
}

// === Delay / window ===

#[test, expected_failure(abort_code = timelock::EDelayTooShort)]
fun schedule_rejects_short_delay() {
    let mut scenario = setup(1000, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let _id = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"s",
        999,
        &clk,
        scenario.ctx(),
    );
    abort
}

// EScheduleOverflow: a delay so large that `now + delay_ms` overflows aborts with a named
// error rather than the generic VM arithmetic abort (mirrors rate_limiter #349).
#[test, expected_failure(abort_code = timelock::EScheduleOverflow)]
fun schedule_rejects_overflow_delay() {
    let mut scenario = setup(0, 1000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(1); // now = 1, so now + u64::MAX overflows
    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let _id = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"s",
        std::u64::max_value!(),
        &clk,
        scenario.ctx(),
    );
    abort
}

#[test, expected_failure(abort_code = timelock::EDelayNotElapsed)]
fun execute_rejects_before_ready() {
    let mut scenario = setup(0, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"s",
        500,
        &clk,
        scenario.ctx(),
    );
    clk.set_for_testing(499);
    let e_auth = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    let _ticket = tl.execute<ExecutorRole, TestAction, u64>(&e_auth, id, &clk, scenario.ctx());
    abort
}

#[test]
fun execute_at_exact_ready_succeeds() {
    let mut scenario = setup(0, 100);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"s",
        50,
        &clk,
        scenario.ctx(),
    );
    clk.set_for_testing(50); // == ready_at
    assert!(tl.is_operation_ready(id, &clk));
    let e_auth = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    let ticket = tl.execute<ExecutorRole, TestAction, u64>(&e_auth, id, &clk, scenario.ctx());
    let (_, _) = tl.consume(ticket, TestAction {});
    assert!(tl.is_operation_done(id));
    clock::destroy_for_testing(clk);
    test_scenario::return_shared(tl);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test, expected_failure(abort_code = timelock::EOperationExpired)]
fun execute_rejects_when_expired() {
    let mut scenario = setup(0, 100);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"s",
        0,
        &clk,
        scenario.ctx(),
    );
    clk.set_for_testing(200); // ready_at=0, expires_at=100
    let e_auth = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    let _ticket = tl.execute<ExecutorRole, TestAction, u64>(&e_auth, id, &clk, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = timelock::EOperationExpired)]
fun execute_at_exact_expiry_rejects() {
    let mut scenario = setup(0, 100);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"s",
        0,
        &clk,
        scenario.ctx(),
    );
    clk.set_for_testing(100); // == expires_at
    let e_auth = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    let _ticket = tl.execute<ExecutorRole, TestAction, u64>(&e_auth, id, &clk, scenario.ctx());
    abort
}

// === Lifecycle ===

#[test, expected_failure(abort_code = timelock::EOperationAlreadyExists)]
fun schedule_rejects_duplicate() {
    let mut scenario = setup(0, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let _id1 = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"s",
        0,
        &clk,
        scenario.ctx(),
    );
    let _id2 = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"s",
        0,
        &clk,
        scenario.ctx(),
    );
    abort
}

#[test, expected_failure(abort_code = timelock::EOperationAlreadyDone)]
fun execute_rejects_redo() {
    let mut scenario = setup(0, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"s",
        0,
        &clk,
        scenario.ctx(),
    );
    let e_auth = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    let ticket = tl.execute<ExecutorRole, TestAction, u64>(&e_auth, id, &clk, scenario.ctx());
    let (_, _) = tl.consume(ticket, TestAction {});
    let e_auth2 = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    let _ticket2 = tl.execute<ExecutorRole, TestAction, u64>(&e_auth2, id, &clk, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = timelock::EOperationUnset)]
fun execute_rejects_unknown() {
    let mut scenario = setup(0, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    let e_auth = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    let _ticket = tl.execute<ExecutorRole, TestAction, u64>(&e_auth, b"nope", &clk, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = timelock::EOperationUnset)]
fun cancel_rejects_unknown() {
    let mut scenario = setup(0, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let c_auth = ac.new_auth<_, CancellerRole>(scenario.ctx());
    tl.cancel<CancellerRole, u64>(&c_auth, b"nope", scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = timelock::EOperationAlreadyDone)]
fun cancel_rejects_done() {
    let mut scenario = setup(0, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"s",
        0,
        &clk,
        scenario.ctx(),
    );
    let e_auth = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    let ticket = tl.execute<ExecutorRole, TestAction, u64>(&e_auth, id, &clk, scenario.ctx());
    let (_, _) = tl.consume(ticket, TestAction {});
    let c_auth = ac.new_auth<_, CancellerRole>(scenario.ctx());
    tl.cancel<CancellerRole, u64>(&c_auth, id, scenario.ctx());
    abort
}

// === consume gate ===

#[test, expected_failure(abort_code = timelock::EWrongTimelock)]
fun consume_rejects_wrong_timelock() {
    let mut scenario = setup(0, 10000);
    let mut tl_a = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    let tl_b = timelock::new<ProposerRole, ExecutorRole, CancellerRole, AdminRole>(
        0,
        10000,
        scenario.ctx(),
    );

    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id = tl_a.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"s",
        0,
        &clk,
        scenario.ctx(),
    );
    let e_auth = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    let ticket = tl_a.execute<ExecutorRole, TestAction, u64>(&e_auth, id, &clk, scenario.ctx());
    // Redeem A's ticket against B.
    let (_, _) = tl_b.consume(ticket, TestAction {});
    abort
}

// === Params type binding on the raw path (EWrongParams) ===
//
// On the raw `&Auth` path the caller writes `Params` explicitly. A wrong type used to
// abort with a cryptic `sui::dynamic_field` mismatch; now it aborts with a named
// `EWrongParams`. (On the `*_with` cap path this is impossible - `Params` is inferred.)

#[test, expected_failure(abort_code = timelock::EWrongParams)]
fun execute_rejects_wrong_params() {
    let mut scenario = setup(0, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    // Scheduled with Params = u64 ...
    let id = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"s",
        0,
        &clk,
        scenario.ctx(),
    );
    let e_auth = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    // ... executed with the WRONG Params type (bool).
    let _ticket = tl.execute<ExecutorRole, TestAction, bool>(&e_auth, id, &clk, scenario.ctx());
    abort
}

// An op scheduled for one `Action` cannot be executed as a different `Action`, even when
// the `Params` type matches - the `Action` is bound at schedule and re-checked at execute.
#[test, expected_failure(abort_code = timelock::EWrongAction)]
fun execute_rejects_wrong_action() {
    let mut scenario = setup(0, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    // Scheduled as TestAction (Params = u64).
    let id = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"s",
        0,
        &clk,
        scenario.ctx(),
    );
    let e_auth = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    // Executed as OtherAction with the SAME Params (u64) -> EWrongAction (not EWrongParams).
    let _ticket = tl.execute<ExecutorRole, OtherAction, u64>(&e_auth, id, &clk, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = timelock::EWrongParams)]
fun cancel_rejects_wrong_params() {
    let mut scenario = setup(0, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"s",
        0,
        &clk,
        scenario.ctx(),
    );
    let c_auth = ac.new_auth<_, CancellerRole>(scenario.ctx());
    // Cancelled with the WRONG Params type (bool).
    tl.cancel<CancellerRole, bool>(&c_auth, id, scenario.ctx());
    abort
}

// === Predecessor ===

#[test]
fun predecessor_success() {
    let mut scenario = setup(0, 100000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);

    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id_a = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"a",
        0,
        &clk,
        scenario.ctx(),
    );
    let id_b = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        50,
        id_a,
        b"b",
        0,
        &clk,
        scenario.ctx(),
    );

    let e_auth = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    let ticket_a = tl.execute<ExecutorRole, TestAction, u64>(&e_auth, id_a, &clk, scenario.ctx());
    let (_, _) = tl.consume(ticket_a, TestAction {});
    let e_auth2 = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    let ticket_b = tl.execute<ExecutorRole, TestAction, u64>(&e_auth2, id_b, &clk, scenario.ctx());
    let (_, _) = tl.consume(ticket_b, TestAction {});
    assert!(tl.is_operation_done(id_b));

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(tl);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test, expected_failure(abort_code = timelock::EPredecessorNotDone)]
fun predecessor_blocks_until_done() {
    let mut scenario = setup(0, 100000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id_a = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"a",
        0,
        &clk,
        scenario.ctx(),
    );
    let id_b = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        50,
        id_a,
        b"b",
        0,
        &clk,
        scenario.ctx(),
    );
    let e_auth = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    let _ticket_b = tl.execute<ExecutorRole, TestAction, u64>(&e_auth, id_b, &clk, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = timelock::EPredecessorUnset)]
fun predecessor_unset() {
    let mut scenario = setup(0, 100000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    // A well-formed (32-byte) but nonexistent predecessor: passes the schedule-time length
    // check, then fails at execute with EPredecessorUnset.
    let id = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        hash::keccak256(&b"ghost"),
        b"b",
        0,
        &clk,
        scenario.ctx(),
    );
    let e_auth = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    let _ticket = tl.execute<ExecutorRole, TestAction, u64>(&e_auth, id, &clk, scenario.ctx());
    abort
}

// A non-empty, non-32-byte predecessor is rejected at schedule (fail fast) rather than
// becoming a silently un-executable op.
#[test, expected_failure(abort_code = timelock::EInvalidPredecessor)]
fun schedule_rejects_malformed_predecessor() {
    let mut scenario = setup(0, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let _id = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        b"not-32-bytes",
        b"s",
        0,
        &clk,
        scenario.ctx(),
    );
    abort
}

// === Open executor ===

#[test, expected_failure(abort_code = timelock::EOpenExecutorDisabled)]
fun execute_open_rejects_when_disabled() {
    let mut scenario = setup(0, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"s",
        0,
        &clk,
        scenario.ctx(),
    );
    let _ticket = tl.execute_open<TestAction, u64>(id, &clk, scenario.ctx());
    abort
}

#[test]
fun execute_open_succeeds_when_enabled() {
    let mut scenario = setup(0, 100000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);

    let a_auth = ac.new_auth<_, AdminRole>(scenario.ctx());
    let cid = tl.schedule_set_open_executor<AdminRole>(
        &a_auth,
        true,
        vector[],
        b"o",
        0,
        &clk,
        scenario.ctx(),
    );
    let a_auth2 = ac.new_auth<_, AdminRole>(scenario.ctx());
    tl.execute_set_open_executor<AdminRole>(&a_auth2, cid, &clk, scenario.ctx());
    assert!(tl.is_open_executor());

    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"s",
        0,
        &clk,
        scenario.ctx(),
    );
    let ticket = tl.execute_open<TestAction, u64>(id, &clk, scenario.ctx());
    let (_, _) = tl.consume(ticket, TestAction {});
    assert!(tl.is_operation_done(id));

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(tl);
    test_scenario::return_shared(ac);
    scenario.end();
}

// === Self-administration ===

#[test]
fun update_min_delay_succeeds() {
    let mut scenario = setup(1000, 100000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);

    let a_auth = ac.new_auth<_, AdminRole>(scenario.ctx());
    let id = tl.schedule_update_min_delay<AdminRole>(
        &a_auth,
        5000,
        vector[],
        b"s",
        1000,
        &clk,
        scenario.ctx(),
    );
    clk.set_for_testing(1000);
    let a_auth2 = ac.new_auth<_, AdminRole>(scenario.ctx());
    tl.execute_update_min_delay<AdminRole>(&a_auth2, id, &clk, scenario.ctx());

    assert_eq!(tl.min_delay_ms(), 5000);
    let changed = event::events_by_type<timelock::MinDelayChanged>();
    assert_eq!(changed.length(), 1);
    assert_eq!(changed[0], timelock::test_new_min_delay_changed(1000, 5000));

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(tl);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun update_grace_period_succeeds() {
    let mut scenario = setup(0, 100000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());

    let a_auth = ac.new_auth<_, AdminRole>(scenario.ctx());
    let id = tl.schedule_update_grace_period<AdminRole>(
        &a_auth,
        7000,
        vector[],
        b"g",
        0,
        &clk,
        scenario.ctx(),
    );
    let a_auth2 = ac.new_auth<_, AdminRole>(scenario.ctx());
    tl.execute_update_grace_period<AdminRole>(&a_auth2, id, &clk, scenario.ctx());

    assert_eq!(tl.grace_period_ms(), 7000);
    let changed = event::events_by_type<timelock::GracePeriodChanged>();
    assert_eq!(changed.length(), 1);
    assert_eq!(changed[0], timelock::test_new_grace_period_changed(100000, 7000));

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(tl);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun set_open_executor_emits_event() {
    let mut scenario = setup(0, 100000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());

    let a_auth = ac.new_auth<_, AdminRole>(scenario.ctx());
    let id = tl.schedule_set_open_executor<AdminRole>(
        &a_auth,
        true,
        vector[],
        b"o",
        0,
        &clk,
        scenario.ctx(),
    );
    let a_auth2 = ac.new_auth<_, AdminRole>(scenario.ctx());
    tl.execute_set_open_executor<AdminRole>(&a_auth2, id, &clk, scenario.ctx());

    assert!(tl.is_open_executor());
    let changed = event::events_by_type<timelock::OpenExecutorChanged>();
    assert_eq!(changed.length(), 1);
    assert_eq!(changed[0], timelock::test_new_open_executor_changed(false, true));

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(tl);
    test_scenario::return_shared(ac);
    scenario.end();
}

// No-op config updates (the op carries the already-configured value) complete
// normally - op Done, OperationExecuted emitted - but the config-change event is
// suppressed: those events record actual changes only.
#[test]
fun update_min_delay_noop_emits_no_event() {
    let mut scenario = setup(1000, 100000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);

    let a_auth = ac.new_auth<_, AdminRole>(scenario.ctx());
    let id = tl.schedule_update_min_delay<AdminRole>(
        &a_auth,
        1000, // already the configured min_delay_ms
        vector[],
        b"s",
        1000,
        &clk,
        scenario.ctx(),
    );
    clk.set_for_testing(1000);
    let a_auth2 = ac.new_auth<_, AdminRole>(scenario.ctx());
    tl.execute_update_min_delay<AdminRole>(&a_auth2, id, &clk, scenario.ctx());

    assert_eq!(tl.min_delay_ms(), 1000);
    assert!(tl.is_operation_done(id));
    assert_eq!(event::events_by_type<timelock::OperationExecuted>().length(), 1);
    assert_eq!(event::events_by_type<timelock::MinDelayChanged>().length(), 0);

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(tl);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun update_grace_period_noop_emits_no_event() {
    let mut scenario = setup(0, 100000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());

    let a_auth = ac.new_auth<_, AdminRole>(scenario.ctx());
    let id = tl.schedule_update_grace_period<AdminRole>(
        &a_auth,
        100000, // already the configured grace_period_ms
        vector[],
        b"g",
        0,
        &clk,
        scenario.ctx(),
    );
    let a_auth2 = ac.new_auth<_, AdminRole>(scenario.ctx());
    tl.execute_update_grace_period<AdminRole>(&a_auth2, id, &clk, scenario.ctx());

    assert_eq!(tl.grace_period_ms(), 100000);
    assert!(tl.is_operation_done(id));
    assert_eq!(event::events_by_type<timelock::OperationExecuted>().length(), 1);
    assert_eq!(event::events_by_type<timelock::GracePeriodChanged>().length(), 0);

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(tl);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun set_open_executor_noop_emits_no_event() {
    let mut scenario = setup(0, 100000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());

    let a_auth = ac.new_auth<_, AdminRole>(scenario.ctx());
    let id = tl.schedule_set_open_executor<AdminRole>(
        &a_auth,
        false, // open_executor already starts false
        vector[],
        b"o",
        0,
        &clk,
        scenario.ctx(),
    );
    let a_auth2 = ac.new_auth<_, AdminRole>(scenario.ctx());
    tl.execute_set_open_executor<AdminRole>(&a_auth2, id, &clk, scenario.ctx());

    assert!(!tl.is_open_executor());
    assert!(tl.is_operation_done(id));
    assert_eq!(event::events_by_type<timelock::OperationExecuted>().length(), 1);
    assert_eq!(event::events_by_type<timelock::OpenExecutorChanged>().length(), 0);

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(tl);
    test_scenario::return_shared(ac);
    scenario.end();
}

// Changing min_delay does not move an in-flight op's locked timing.
#[test]
fun in_flight_op_keeps_timing_after_min_delay_change() {
    let mut scenario = setup(1000, 100000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);

    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id_x = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"x",
        1000,
        &clk,
        scenario.ctx(),
    );

    let a_auth = ac.new_auth<_, AdminRole>(scenario.ctx());
    let cid = tl.schedule_update_min_delay<AdminRole>(
        &a_auth,
        5000,
        vector[],
        b"c",
        1000,
        &clk,
        scenario.ctx(),
    );
    clk.set_for_testing(1000);
    let a_auth2 = ac.new_auth<_, AdminRole>(scenario.ctx());
    tl.execute_update_min_delay<AdminRole>(&a_auth2, cid, &clk, scenario.ctx());
    assert_eq!(tl.min_delay_ms(), 5000);

    // Op X keeps ready_at = 1000 (not pushed to 5000) and is executable now.
    assert!(tl.is_operation_ready(id_x, &clk));
    let e_auth = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    let ticket = tl.execute<ExecutorRole, TestAction, u64>(&e_auth, id_x, &clk, scenario.ctx());
    let (_, _) = tl.consume(ticket, TestAction {});
    assert!(tl.is_operation_done(id_x));

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(tl);
    test_scenario::return_shared(ac);
    scenario.end();
}

// === Re-schedule semantics ===

#[test, expected_failure(abort_code = timelock::EOperationAlreadyExists)]
fun reschedule_same_after_expiry_fails() {
    let mut scenario = setup(0, 100);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let _id = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"s",
        0,
        &clk,
        scenario.ctx(),
    );
    clk.set_for_testing(500); // expired
    let _id2 = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"s",
        0,
        &clk,
        scenario.ctx(),
    );
    abort
}

#[test]
fun reschedule_new_salt_after_expiry_ok() {
    let mut scenario = setup(0, 100);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let _id = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"s1",
        0,
        &clk,
        scenario.ctx(),
    );
    clk.set_for_testing(500);
    let id2 = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"s2",
        0,
        &clk,
        scenario.ctx(),
    );
    assert!(tl.is_operation_ready(id2, &clk));
    let e_auth = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    let ticket = tl.execute<ExecutorRole, TestAction, u64>(&e_auth, id2, &clk, scenario.ctx());
    let (_, _) = tl.consume(ticket, TestAction {});
    assert!(tl.is_operation_done(id2));
    clock::destroy_for_testing(clk);
    test_scenario::return_shared(tl);
    test_scenario::return_shared(ac);
    scenario.end();
}

// === Views: state machine ===

#[test]
fun operation_state_transitions() {
    let mut scenario = setup(0, 100);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);

    assert!(!tl.is_operation(b"ghost"));
    assert_eq!(tl.operation_state(b"ghost", &clk), timelock::test_operation_state_unset());
    // The boolean predicates all read false for an Unset (unknown) id.
    assert!(!tl.is_operation_pending(b"ghost", &clk));
    assert!(!tl.is_operation_ready(b"ghost", &clk));
    assert!(!tl.is_operation_expired(b"ghost", &clk));

    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"s",
        50,
        &clk,
        scenario.ctx(),
    );
    // Waiting (now=0 < ready_at=50).
    assert!(tl.is_operation(id));
    assert!(tl.is_operation_pending(id, &clk));
    assert!(!tl.is_operation_ready(id, &clk));
    assert!(!tl.is_operation_expired(id, &clk));
    assert!(!tl.is_operation_done(id));
    assert_eq!(tl.operation_state(id, &clk), timelock::test_operation_state_waiting(50, 150));
    // Ready.
    clk.set_for_testing(50);
    assert!(tl.is_operation_ready(id, &clk));
    assert!(tl.is_operation_pending(id, &clk));
    assert_eq!(tl.operation_state(id, &clk), timelock::test_operation_state_ready(50, 150));
    // Expired.
    clk.set_for_testing(150);
    assert!(tl.is_operation_expired(id, &clk));
    assert!(!tl.is_operation_pending(id, &clk));
    assert!(!tl.is_operation_ready(id, &clk));
    assert!(!tl.is_operation_done(id));
    assert_eq!(tl.operation_state(id, &clk), timelock::test_operation_state_expired(50, 150));

    // Done - a fresh op executed to completion.
    let id2 = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"s2",
        0,
        &clk,
        scenario.ctx(),
    );
    let e_auth = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    let ticket = tl.execute<ExecutorRole, TestAction, u64>(&e_auth, id2, &clk, scenario.ctx());
    let (_, _) = tl.consume(ticket, TestAction {});
    assert!(tl.is_operation_done(id2));
    assert_eq!(tl.operation_state(id2, &clk), timelock::test_operation_state_done());
    // The pending/ready/expired predicates all read false for a Done op.
    assert!(!tl.is_operation_pending(id2, &clk));
    assert!(!tl.is_operation_ready(id2, &clk));
    assert!(!tl.is_operation_expired(id2, &clk));

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(tl);
    test_scenario::return_shared(ac);
    scenario.end();
}

// === Misc public API ===

#[test]
fun share_makes_timelock_shared() {
    let mut scenario = test_scenario::begin(DEPLOYER);
    let tl = timelock::new<ProposerRole, ExecutorRole, CancellerRole, AdminRole>(
        0,
        1000,
        scenario.ctx(),
    );
    timelock::share(tl);
    scenario.next_tx(DEPLOYER);
    let tl = scenario.take_shared<Timelock>();
    assert_eq!(tl.min_delay_ms(), 0);
    assert_eq!(tl.grace_period_ms(), 1000);
    test_scenario::return_shared(tl);
    scenario.end();
}

#[test]
fun domain_tag_getter_pins_published_value() {
    // Changing the tag re-keys every operation id, so pin the published value.
    assert_eq!(timelock::domain_tag(), b"OZ_Timelock_1_Sui");
}

// Golden vector for the byte-exact preimage encoding documented on `hash_operation`.
// Every input is pinned, so the expected id was recomputed independently off-chain:
//   preimage = "OZ_Timelock_1_Sui"                       raw 17 bytes, no length prefix
//           || 0x4a || "0000..0002::sui::SUI"            action: ULEB128 len (74) + ascii
//           || 0x20 || 0x11 * 32                         payload_digest: len + bytes
//           || 0x00                                      predecessor: empty vector
//           || 0x04 || "salt"                            salt: len + bytes
//           || 0x00 * 31 || 0xaa                         timelock_id: raw 32 bytes
//   id = keccak256(preimage)
#[test]
fun hash_operation_matches_documented_encoding() {
    let id = timelock::hash_operation<sui::sui::SUI>(
        object::id_from_address(@0xAA),
        x"1111111111111111111111111111111111111111111111111111111111111111",
        vector[],
        b"salt",
    );
    assert_eq!(id, x"e18d98c162999a5d9644720daa1771b0cebc3569064fa498adf55d5035bc60e5");
}

#[test]
fun hash_operation_deterministic() {
    let mut scenario = test_scenario::begin(DEPLOYER);
    let tl_id = timelock::new_shared<ProposerRole, ExecutorRole, CancellerRole, AdminRole>(
        0,
        1000,
        scenario.ctx(),
    );
    let digest = digest_of(42);
    let h1 = timelock::hash_operation<TestAction>(tl_id, digest, vector[], b"s");
    let h2 = timelock::hash_operation<TestAction>(tl_id, digest, vector[], b"s");
    let h3 = timelock::hash_operation<TestAction>(tl_id, digest, vector[], b"other");
    assert_eq!(h1, h2);
    assert!(h1 != h3);
    scenario.next_tx(DEPLOYER);
    let tl = scenario.take_shared<Timelock>();
    test_scenario::return_shared(tl);
    scenario.end();
}

// === Capability-bound entries (OperationCap) ===

// Full cycle via the cap path. The `<...>` are written ONCE at new_operation_cap;
// schedule_with / execute_with carry ZERO explicit type args (all inferred from the cap).
#[test]
fun cap_happy_zero_type_args() {
    let mut scenario = setup(0, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);

    let cap = tl.new_operation_cap<TestAction, u64>();
    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id = tl.schedule_with(&cap, &p_auth, 42, vector[], b"s", 0, &clk, scenario.ctx());
    let e_auth = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    let ticket = tl.execute_with(&cap, &e_auth, id, &clk, scenario.ctx());
    let (rid, params) = tl.consume(ticket, TestAction {});
    assert_eq!(rid, id);
    assert_eq!(params, 42);
    assert!(tl.is_operation_done(id));

    destroy(cap);
    clock::destroy_for_testing(clk);
    test_scenario::return_shared(tl);
    test_scenario::return_shared(ac);
    scenario.end();
}

// Structural binding: a cap minted for timelock A rejects timelock B - with NO manual
// object::id assert anywhere in this test or the (would-be) consumer.
#[test, expected_failure(abort_code = timelock::EWrongTimelock)]
fun cap_rejects_foreign_timelock() {
    let mut scenario = setup(0, 10000);
    let tl_a = scenario.take_shared<Timelock>();
    let mut tl_b = timelock::new<ProposerRole, ExecutorRole, CancellerRole, AdminRole>(
        0,
        10000,
        scenario.ctx(),
    );
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());

    let cap = tl_a.new_operation_cap<TestAction, u64>(); // bound to A
    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    // A's cap used against B -> cap.timelock_id (A) != object::id(B) -> EWrongTimelock.
    let _id = tl_b.schedule_with(&cap, &p_auth, 42, vector[], b"s", 0, &clk, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = timelock::EWrongRole)]
fun cap_schedule_rejects_wrong_role() {
    let mut scenario = setup(0, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    let cap = tl.new_operation_cap<TestAction, u64>();
    let wrong = ac.new_auth<_, ExecutorRole>(scenario.ctx()); // executor role for a proposer action
    let _id = tl.schedule_with(&cap, &wrong, 42, vector[], b"s", 0, &clk, scenario.ctx());
    abort
}

#[test]
fun cap_cancel() {
    let mut scenario = setup(0, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    let cap = tl.new_operation_cap<TestAction, u64>();
    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id = tl.schedule_with(&cap, &p_auth, 42, vector[], b"s", 0, &clk, scenario.ctx());
    let c_auth = ac.new_auth<_, CancellerRole>(scenario.ctx());
    tl.cancel_with(&cap, &c_auth, id, scenario.ctx());
    assert!(!tl.is_operation(id));

    destroy(cap);
    clock::destroy_for_testing(clk);
    test_scenario::return_shared(tl);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun cap_execute_open() {
    let mut scenario = setup(0, 100000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    let cap = tl.new_operation_cap<TestAction, u64>();

    // Enable open-executor via self-admin.
    let a_auth = ac.new_auth<_, AdminRole>(scenario.ctx());
    let cid = tl.schedule_set_open_executor<AdminRole>(
        &a_auth,
        true,
        vector[],
        b"o",
        0,
        &clk,
        scenario.ctx(),
    );
    let a_auth2 = ac.new_auth<_, AdminRole>(scenario.ctx());
    tl.execute_set_open_executor<AdminRole>(&a_auth2, cid, &clk, scenario.ctx());

    // Schedule then execute_open_with (cap binds the timelock; no executor auth).
    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id = tl.schedule_with(&cap, &p_auth, 42, vector[], b"s", 0, &clk, scenario.ctx());
    let ticket = tl.execute_open_with(&cap, id, &clk, scenario.ctx());
    let (_rid, params) = tl.consume(ticket, TestAction {});
    assert_eq!(params, 42);
    assert!(tl.is_operation_done(id));

    destroy(cap);
    clock::destroy_for_testing(clk);
    test_scenario::return_shared(tl);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun operation_cap_timelock_id() {
    let scenario = setup(0, 1000);
    let tl = scenario.take_shared<Timelock>();
    let cap = tl.new_operation_cap<TestAction, u64>();
    assert_eq!(cap.operation_cap_timelock_id(), object::id(&tl));
    destroy(cap);
    test_scenario::return_shared(tl);
    scenario.end();
}

#[test]
fun operation_cap_can_be_destroyed() {
    let scenario = setup(0, 1000);
    let tl = scenario.take_shared<Timelock>();
    let cap = tl.new_operation_cap<TestAction, u64>();
    cap.destroy_operation_cap();
    test_scenario::return_shared(tl);
    scenario.end();
}

// === Overflow: second guard (now + delay fits, but + grace overflows) ===

#[test, expected_failure(abort_code = timelock::EScheduleOverflow)]
fun schedule_rejects_overflow_grace() {
    let mut scenario = setup(0, 1000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx()); // now = 0
    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    // ready_at = u64::MAX - 500 (first guard passes); grace 1000 > 500 -> second guard aborts.
    let _id = tl.schedule<ProposerRole, TestAction, u64>(
        &p_auth,
        42,
        vector[],
        b"s",
        std::u64::max_value!() - 500,
        &clk,
        scenario.ctx(),
    );
    abort
}

// === Cap-path abort branches (execute_with / execute_open_with / cancel_with) ===

#[test, expected_failure(abort_code = timelock::EWrongTimelock)]
fun cap_execute_rejects_foreign_timelock() {
    let mut scenario = setup(0, 10000);
    let tl_a = scenario.take_shared<Timelock>();
    let mut tl_b = timelock::new<ProposerRole, ExecutorRole, CancellerRole, AdminRole>(
        0,
        10000,
        scenario.ctx(),
    );
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    let cap = tl_a.new_operation_cap<TestAction, u64>(); // bound to A
    let e_auth = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    // A's cap used against B -> EWrongTimelock.
    let _ticket = tl_b.execute_with(&cap, &e_auth, b"anyid", &clk, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = timelock::EWrongRole)]
fun cap_execute_rejects_wrong_role() {
    let mut scenario = setup(0, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    let cap = tl.new_operation_cap<TestAction, u64>();
    let wrong = ac.new_auth<_, ProposerRole>(scenario.ctx()); // proposer where executor required
    let _ticket = tl.execute_with(&cap, &wrong, b"anyid", &clk, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = timelock::EWrongTimelock)]
fun cap_execute_open_rejects_foreign_timelock() {
    let mut scenario = setup(0, 10000);
    let tl_a = scenario.take_shared<Timelock>();
    let mut tl_b = timelock::new<ProposerRole, ExecutorRole, CancellerRole, AdminRole>(
        0,
        10000,
        scenario.ctx(),
    );
    let clk = clock::create_for_testing(scenario.ctx());
    let cap = tl_a.new_operation_cap<TestAction, u64>();
    // Cap binding checked before the open-executor gate -> EWrongTimelock.
    let _ticket = tl_b.execute_open_with(&cap, b"anyid", &clk, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = timelock::EOpenExecutorDisabled)]
fun cap_execute_open_rejects_when_disabled() {
    let mut scenario = setup(0, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let clk = clock::create_for_testing(scenario.ctx());
    let cap = tl.new_operation_cap<TestAction, u64>();
    // Correct cap (binding passes); open_executor is false by default -> EOpenExecutorDisabled.
    let _ticket = tl.execute_open_with(&cap, b"anyid", &clk, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = timelock::EWrongTimelock)]
fun cap_cancel_rejects_foreign_timelock() {
    let mut scenario = setup(0, 10000);
    let tl_a = scenario.take_shared<Timelock>();
    let mut tl_b = timelock::new<ProposerRole, ExecutorRole, CancellerRole, AdminRole>(
        0,
        10000,
        scenario.ctx(),
    );
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let cap = tl_a.new_operation_cap<TestAction, u64>();
    let c_auth = ac.new_auth<_, CancellerRole>(scenario.ctx());
    tl_b.cancel_with(&cap, &c_auth, b"anyid", scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = timelock::EWrongRole)]
fun cap_cancel_rejects_wrong_role() {
    let mut scenario = setup(0, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let cap = tl.new_operation_cap<TestAction, u64>();
    let wrong = ac.new_auth<_, ProposerRole>(scenario.ctx()); // proposer where canceller required
    tl.cancel_with(&cap, &wrong, b"anyid", scenario.ctx());
    abort
}

// === Self-administration abort branches (role gate + config bounds) ===

// Defense-in-depth: a config op can be staged through the generic `schedule` (marker witness
// types are public), bypassing the schedule-side bound check - but the bound is re-asserted
// at apply time. `grace = 0` would brick the timelock; `min_delay > MAX` is out of bounds.
#[test, expected_failure(abort_code = timelock::EInvalidConfig)]
fun execute_grace_bypass_rejected() {
    let mut scenario = setup(0, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    // Stage grace = 0 via the generic schedule (skips schedule_update_grace_period's check).
    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id = tl.schedule<ProposerRole, timelock::UpdateGracePeriodWitness, u64>(
        &p_auth,
        0,
        vector[],
        b"s",
        0,
        &clk,
        scenario.ctx(),
    );
    // Admin executes -> apply-time bound re-check aborts with EInvalidConfig (not a brick).
    let a_auth = ac.new_auth<_, AdminRole>(scenario.ctx());
    tl.execute_update_grace_period<AdminRole>(&a_auth, id, &clk, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = timelock::EInvalidConfig)]
fun execute_min_delay_bypass_rejected() {
    let mut scenario = setup(0, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    // Stage min_delay > MAX_DELAY_MS via the generic schedule.
    let p_auth = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id = tl.schedule<ProposerRole, timelock::UpdateMinDelayWitness, u64>(
        &p_auth,
        timelock::max_delay_ms() + 1,
        vector[],
        b"s",
        0,
        &clk,
        scenario.ctx(),
    );
    let a_auth = ac.new_auth<_, AdminRole>(scenario.ctx());
    tl.execute_update_min_delay<AdminRole>(&a_auth, id, &clk, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = timelock::EWrongRole)]
fun schedule_update_grace_rejects_non_admin() {
    let mut scenario = setup(0, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    let wrong = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let _id = tl.schedule_update_grace_period<ProposerRole>(
        &wrong,
        5000,
        vector[],
        b"s",
        0,
        &clk,
        scenario.ctx(),
    );
    abort
}

#[test, expected_failure(abort_code = timelock::EWrongRole)]
fun schedule_set_open_executor_rejects_non_admin() {
    let mut scenario = setup(0, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    let wrong = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let _id = tl.schedule_set_open_executor<ProposerRole>(
        &wrong,
        true,
        vector[],
        b"s",
        0,
        &clk,
        scenario.ctx(),
    );
    abort
}

#[test, expected_failure(abort_code = timelock::EWrongRole)]
fun execute_update_min_delay_rejects_non_admin() {
    let mut scenario = setup(0, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    let wrong = ac.new_auth<_, ProposerRole>(scenario.ctx());
    tl.execute_update_min_delay<ProposerRole>(&wrong, b"anyid", &clk, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = timelock::EWrongRole)]
fun execute_update_grace_rejects_non_admin() {
    let mut scenario = setup(0, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    let wrong = ac.new_auth<_, ProposerRole>(scenario.ctx());
    tl.execute_update_grace_period<ProposerRole>(&wrong, b"anyid", &clk, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = timelock::EWrongRole)]
fun execute_set_open_executor_rejects_non_admin() {
    let mut scenario = setup(0, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    let wrong = ac.new_auth<_, ProposerRole>(scenario.ctx());
    tl.execute_set_open_executor<ProposerRole>(&wrong, b"anyid", &clk, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = timelock::EInvalidConfig)]
fun schedule_update_min_delay_rejects_excessive() {
    let mut scenario = setup(0, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    let admin = ac.new_auth<_, AdminRole>(scenario.ctx());
    let _id = tl.schedule_update_min_delay<AdminRole>(
        &admin,
        timelock::max_delay_ms() + 1,
        vector[],
        b"s",
        0,
        &clk,
        scenario.ctx(),
    );
    abort
}

#[test, expected_failure(abort_code = timelock::EInvalidConfig)]
fun schedule_update_grace_rejects_zero() {
    let mut scenario = setup(0, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    let admin = ac.new_auth<_, AdminRole>(scenario.ctx());
    let _id = tl.schedule_update_grace_period<AdminRole>(
        &admin,
        0,
        vector[],
        b"s",
        0,
        &clk,
        scenario.ctx(),
    );
    abort
}

#[test, expected_failure(abort_code = timelock::EInvalidConfig)]
fun schedule_update_grace_rejects_excessive() {
    let mut scenario = setup(0, 10000);
    let mut tl = scenario.take_shared<Timelock>();
    let ac = scenario.take_shared<AccessControl<TIMELOCK_TESTS>>();
    let clk = clock::create_for_testing(scenario.ctx());
    let admin = ac.new_auth<_, AdminRole>(scenario.ctx());
    let _id = tl.schedule_update_grace_period<AdminRole>(
        &admin,
        timelock::max_delay_ms() + 1,
        vector[],
        b"s",
        0,
        &clk,
        scenario.ctx(),
    );
    abort
}

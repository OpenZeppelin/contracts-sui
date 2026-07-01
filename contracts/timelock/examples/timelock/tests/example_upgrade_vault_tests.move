// Scenario walkthroughs for the timelocked-UpgradeCap vault example.
//
// Bare `abort` follows each known-aborting call in the `expected_failure` tests: it is
// unreachable and only satisfies the checker on bindings left unconsumed before the abort.
module openzeppelin_timelock::example_upgrade_vault_tests;

use openzeppelin_access::access_control::AccessControl;
use openzeppelin_timelock::example_upgrade_vault::{
    Self,
    UpgradeVault,
    EXAMPLE_UPGRADE_VAULT,
    ProposerRole,
    ExecutorRole,
    CancellerRole,
    AdminRole
};
use openzeppelin_timelock::timelock::{Self, Timelock};
use std::unit_test::destroy;
use sui::clock;
use sui::package;
use sui::test_scenario::{Self, Scenario};

const PUBLISHER: address = @0xA;
const ALICE: address = @0xB; // proposer
const BOB: address = @0xC; // executor

const DAY_MS: u64 = 24 * 60 * 60 * 1_000;

/// Deploy AccessControl + Timelock, then wrap a (test) package UpgradeCap into a vault
/// bound to that timelock. Returns the scenario positioned at a fresh PUBLISHER tx.
fun deploy(): Scenario {
    let mut scenario = test_scenario::begin(PUBLISHER);
    example_upgrade_vault::init_for_testing(scenario.ctx());

    scenario.next_tx(PUBLISHER);
    let mut ac = scenario.take_shared<AccessControl<EXAMPLE_UPGRADE_VAULT>>();
    ac.grant_role<_, ProposerRole>(ALICE, scenario.ctx());
    ac.grant_role<_, ExecutorRole>(BOB, scenario.ctx());
    test_scenario::return_shared(ac);

    scenario.next_tx(PUBLISHER);
    let timelock = scenario.take_shared<Timelock>();
    let cap = package::test_publish(object::id_from_address(@0xCAFE), scenario.ctx());
    example_upgrade_vault::wrap(cap, &timelock, scenario.ctx());
    test_scenario::return_shared(timelock);

    scenario.next_tx(PUBLISHER);
    scenario
}

// === Happy path: a timelocked upgrade authorization ===
//
// Story: the proposer schedules the (policy, digest); after the delay the executor cranks
// it, which consumes the timelock ticket and authorizes the package upgrade, yielding an
// UpgradeTicket for the PTB's Upgrade command.
#[test]
fun timelocked_upgrade_happy() {
    let mut scenario = deploy();
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);

    // ALICE: schedule the upgrade (policy = compatible, some digest).
    scenario.next_tx(ALICE);
    let mut timelock = scenario.take_shared<Timelock>();
    let vault = scenario.take_shared<UpgradeVault>();
    let ac = scenario.take_shared<AccessControl<EXAMPLE_UPGRADE_VAULT>>();
    let proposer = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id = example_upgrade_vault::schedule_upgrade(
        &mut timelock,
        &vault,
        &proposer,
        0,
        b"test_digest",
        b"salt",
        DAY_MS,
        &clk,
        scenario.ctx(),
    );
    test_scenario::return_shared(timelock);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(ac);

    clk.set_for_testing(DAY_MS);

    // BOB: authorize the scheduled upgrade -> UpgradeTicket.
    scenario.next_tx(BOB);
    let mut timelock = scenario.take_shared<Timelock>();
    let mut vault = scenario.take_shared<UpgradeVault>();
    let ac = scenario.take_shared<AccessControl<EXAMPLE_UPGRADE_VAULT>>();
    let executor = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    let upgrade_ticket = example_upgrade_vault::authorize_scheduled_upgrade(
        &mut timelock,
        &mut vault,
        &executor,
        id,
        &clk,
        scenario.ctx(),
    );

    // The ticket carries the scheduled policy + digest.
    assert!(package::ticket_policy(&upgrade_ticket) == 0);
    assert!(*package::ticket_digest(&upgrade_ticket) == b"test_digest");
    // In a real PTB the Upgrade command consumes this ticket and produces a receipt for
    // commit_upgrade; here we just discard it.
    destroy(upgrade_ticket);

    test_scenario::return_shared(timelock);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(ac);
    clock::destroy_for_testing(clk);
    scenario.end();
}

// === A self-created timelock cannot rush the upgrade ===
#[test, expected_failure(abort_code = timelock::EWrongTimelock)]
fun fake_timelock_rejected() {
    let mut scenario = deploy();
    let clk = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let mut fake_tl = timelock::new<ProposerRole, ExecutorRole, CancellerRole, AdminRole>(
        0,
        1000,
        scenario.ctx(),
    );
    let vault = scenario.take_shared<UpgradeVault>();
    let ac = scenario.take_shared<AccessControl<EXAMPLE_UPGRADE_VAULT>>();
    let proposer = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let _id = example_upgrade_vault::schedule_upgrade(
        &mut fake_tl,
        &vault,
        &proposer,
        0,
        b"d",
        b"s",
        0,
        &clk,
        scenario.ctx(),
    );
    abort
}

// === Authorizing before the delay elapses is rejected ===
#[test, expected_failure(abort_code = timelock::EDelayNotElapsed)]
fun authorize_before_ready() {
    let mut scenario = deploy();
    let clk = clock::create_for_testing(scenario.ctx()); // stays at 0

    scenario.next_tx(ALICE);
    let mut timelock = scenario.take_shared<Timelock>();
    let vault = scenario.take_shared<UpgradeVault>();
    let ac = scenario.take_shared<AccessControl<EXAMPLE_UPGRADE_VAULT>>();
    let proposer = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id = example_upgrade_vault::schedule_upgrade(
        &mut timelock,
        &vault,
        &proposer,
        0,
        b"d",
        b"s",
        DAY_MS,
        &clk,
        scenario.ctx(),
    );
    test_scenario::return_shared(timelock);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(ac);

    // BOB authorizes immediately - before the delay elapses.
    scenario.next_tx(BOB);
    let mut timelock = scenario.take_shared<Timelock>();
    let mut vault = scenario.take_shared<UpgradeVault>();
    let ac = scenario.take_shared<AccessControl<EXAMPLE_UPGRADE_VAULT>>();
    let executor = ac.new_auth<_, ExecutorRole>(scenario.ctx());
    let _t = example_upgrade_vault::authorize_scheduled_upgrade(
        &mut timelock,
        &mut vault,
        &executor,
        id,
        &clk,
        scenario.ctx(),
    );
    abort
}

// === A canceller can drop a pending upgrade before it executes ===
#[test]
fun cancel_upgrade() {
    let mut scenario = deploy();

    // Grant the canceller role.
    scenario.next_tx(PUBLISHER);
    let mut ac = scenario.take_shared<AccessControl<EXAMPLE_UPGRADE_VAULT>>();
    ac.grant_role<_, CancellerRole>(ALICE, scenario.ctx());
    test_scenario::return_shared(ac);

    let clk = clock::create_for_testing(scenario.ctx());

    // ALICE (proposer) schedules an upgrade.
    scenario.next_tx(ALICE);
    let mut timelock = scenario.take_shared<Timelock>();
    let vault = scenario.take_shared<UpgradeVault>();
    let ac = scenario.take_shared<AccessControl<EXAMPLE_UPGRADE_VAULT>>();
    let proposer = ac.new_auth<_, ProposerRole>(scenario.ctx());
    let id = example_upgrade_vault::schedule_upgrade(
        &mut timelock,
        &vault,
        &proposer,
        0,
        b"d",
        b"s",
        DAY_MS,
        &clk,
        scenario.ctx(),
    );
    assert!(timelock.is_operation(id));

    // ALICE (canceller) cancels it before the delay elapses.
    let canceller = ac.new_auth<_, CancellerRole>(scenario.ctx());
    example_upgrade_vault::cancel_upgrade(&mut timelock, &vault, &canceller, id, scenario.ctx());
    assert!(!timelock.is_operation(id));

    test_scenario::return_shared(timelock);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(ac);
    clock::destroy_for_testing(clk);
    scenario.end();
}

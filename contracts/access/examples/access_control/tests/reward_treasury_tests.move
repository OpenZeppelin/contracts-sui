module openzeppelin_access::example_reward_treasury_tests;

use openzeppelin_access::access_control::{Self, AccessControl};
use openzeppelin_access::example_reward_treasury::{
    Self as treasury,
    RewardTreasury,
    DistributorRole,
    GuardianRole,
    PauserRole,
    EXAMPLE_REWARD_TREASURY,
};
use std::unit_test::{assert_eq, destroy};
use sui::coin;
use sui::event;
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};

const ADMIN: address = @0xAD;
const DISTRIBUTOR: address = @0xD1;
const PAUSER: address = @0xBA;
const RANDOM: address = @0xCAFE;

// Comfortably past the example's 7-day root-admin delay.
const PAST_DELAY_MS: u64 = 8 * 24 * 60 * 60 * 1_000;

/// Publish the protocol and advance to a fresh transaction so the shared registry and
/// treasury are takeable.
#[test_only]
fun setup(): Scenario {
    let mut scenario = ts::begin(ADMIN);
    treasury::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);
    scenario
}

// Funding needs no role - any address can top up the pool - while withdrawing is gated by
// an `Auth<DistributorRole>` minted from the registry.
#[test]
fun funding_is_permissionless_and_distributor_can_withdraw() {
    let mut scenario = setup();

    // The root admin grants the distributor role (root administers it by default).
    let mut registry = scenario.take_shared<AccessControl<EXAMPLE_REWARD_TREASURY>>();
    registry.grant_role<_, DistributorRole>(DISTRIBUTOR, scenario.ctx());
    ts::return_shared(registry);

    // A random, unprivileged address funds the pool.
    scenario.next_tx(RANDOM);
    let mut pool = scenario.take_shared<RewardTreasury>();
    pool.fund(coin::mint_for_testing<SUI>(1_000, scenario.ctx()));
    assert_eq!(pool.available(), 1_000);
    ts::return_shared(pool);

    // The distributor mints its auth witness and withdraws against it.
    scenario.next_tx(DISTRIBUTOR);
    let registry = scenario.take_shared<AccessControl<EXAMPLE_REWARD_TREASURY>>();
    let mut pool = scenario.take_shared<RewardTreasury>();

    let auth = registry.new_auth<_, DistributorRole>(scenario.ctx());
    let coins = pool.withdraw(&auth, 300, scenario.ctx());
    assert_eq!(coins.value(), 300);
    assert_eq!(pool.available(), 700);

    // The withdrawal is attributed to the distributor.
    let events = event::events_by_type<treasury::RewardsWithdrawn>();
    assert_eq!(events.length(), 1);
    assert_eq!(events[0], treasury::test_new_rewards_withdrawn(DISTRIBUTOR, 300));

    destroy(coins);
    ts::return_shared(registry);
    ts::return_shared(pool);
    scenario.end();
}

// `set_role_admin` delegated pauser management to the guardian role at publish time, so
// the guardian (here, the admin) can appoint pausers and a pauser can freeze withdrawals.
#[test]
fun guardian_grants_pauser_and_pause_blocks_withdrawal() {
    let mut scenario = setup();

    // The admin holds the guardian role, so it can grant the pauser role even though the
    // root role does not administer `PauserRole` directly.
    let mut registry = scenario.take_shared<AccessControl<EXAMPLE_REWARD_TREASURY>>();
    registry.grant_role<_, PauserRole>(PAUSER, scenario.ctx());
    assert!(registry.has_role<_, PauserRole>(PAUSER));
    ts::return_shared(registry);

    // The pauser freezes the treasury.
    scenario.next_tx(PAUSER);
    let registry = scenario.take_shared<AccessControl<EXAMPLE_REWARD_TREASURY>>();
    let mut pool = scenario.take_shared<RewardTreasury>();
    let auth = registry.new_auth<_, PauserRole>(scenario.ctx());
    pool.set_paused(&auth, true);
    assert!(pool.is_paused());

    ts::return_shared(registry);
    ts::return_shared(pool);
    scenario.end();
}

// A frozen treasury rejects withdrawals on the consumer-side `EPaused` check, before any
// balance is touched.
#[test, expected_failure(abort_code = treasury::EPaused)]
fun withdraw_while_paused_aborts() {
    let mut scenario = setup();

    let mut registry = scenario.take_shared<AccessControl<EXAMPLE_REWARD_TREASURY>>();
    registry.grant_role<_, DistributorRole>(DISTRIBUTOR, scenario.ctx());
    registry.grant_role<_, PauserRole>(PAUSER, scenario.ctx());
    ts::return_shared(registry);

    // The pauser freezes the pool.
    scenario.next_tx(PAUSER);
    let registry = scenario.take_shared<AccessControl<EXAMPLE_REWARD_TREASURY>>();
    let mut pool = scenario.take_shared<RewardTreasury>();
    let pauser_auth = registry.new_auth<_, PauserRole>(scenario.ctx());
    pool.set_paused(&pauser_auth, true);
    ts::return_shared(registry);

    // A legitimate distributor still cannot withdraw while frozen.
    scenario.next_tx(DISTRIBUTOR);
    let registry = scenario.take_shared<AccessControl<EXAMPLE_REWARD_TREASURY>>();
    let dist_auth = registry.new_auth<_, DistributorRole>(scenario.ctx());
    let coins = pool.withdraw(&dist_auth, 1, scenario.ctx());

    destroy(coins);
    abort
}

// Minting `Auth<Role>` is itself the authorization gate: an address that does not hold
// the role cannot obtain the witness.
#[test, expected_failure(abort_code = access_control::EUnauthorized)]
fun new_auth_without_role_aborts() {
    let mut scenario = setup();

    scenario.next_tx(RANDOM);
    let registry = scenario.take_shared<AccessControl<EXAMPLE_REWARD_TREASURY>>();
    let auth = registry.new_auth<_, DistributorRole>(scenario.ctx());

    destroy(auth);
    abort
}

// `PauserRole` is administered by the guardian role, so an account holding neither the
// guardian nor the root role cannot appoint pausers.
#[test, expected_failure(abort_code = access_control::EUnauthorized)]
fun non_guardian_cannot_grant_pauser() {
    let mut scenario = setup();

    scenario.next_tx(RANDOM);
    let mut registry = scenario.take_shared<AccessControl<EXAMPLE_REWARD_TREASURY>>();
    registry.grant_role<_, PauserRole>(PAUSER, scenario.ctx());

    abort
}

// Governance rotation: the root admin schedules a transfer of the root role, the delay
// elapses, the new admin accepts, and then exercises root authority by granting a role.
#[test]
fun timelocked_root_admin_handoff() {
    let new_admin = @0xBEEF;

    let mut scenario = setup();
    let mut clock = sui::clock::create_for_testing(scenario.ctx());

    // The current root admin schedules the handoff.
    let mut registry = scenario.take_shared<AccessControl<EXAMPLE_REWARD_TREASURY>>();
    registry.begin_default_admin_transfer(new_admin, &clock, scenario.ctx());
    assert_eq!(registry.pending_default_admin_new_admin(), option::some(new_admin));
    ts::return_shared(registry);

    // Once the timelock elapses, the incoming admin accepts and becomes the root holder.
    clock.increment_for_testing(PAST_DELAY_MS);
    scenario.next_tx(new_admin);
    let mut registry = scenario.take_shared<AccessControl<EXAMPLE_REWARD_TREASURY>>();
    registry.accept_default_admin_transfer(&clock, scenario.ctx());
    assert_eq!(registry.default_admin(), option::some(new_admin));

    // The new admin now wields root authority: it can grant the distributor role.
    registry.grant_role<_, DistributorRole>(DISTRIBUTOR, scenario.ctx());
    assert!(registry.has_role<_, DistributorRole>(DISTRIBUTOR));

    ts::return_shared(registry);
    destroy(clock);
    scenario.end();
}

// Governance retirement, in the right order: re-parent day-to-day roles away from the
// root FIRST (any role still administered by the root freezes forever once the root is
// renounced), then schedule the renounce, wait out the delay, and finalize. The root ends
// permanently vacant while the self-administered guardian committee keeps managing roles.
#[test]
fun timelocked_root_admin_renounce() {
    let mut scenario = setup();
    let mut clock = sui::clock::create_for_testing(scenario.ctx());

    let mut registry = scenario.take_shared<AccessControl<EXAMPLE_REWARD_TREASURY>>();
    // Retirement prep: guardians administer themselves (a self-sustaining committee), and
    // distributors move under the guardians. Skipping this would leave both roles frozen
    // - members permanent, no grants or revocations - the moment the root goes vacant.
    registry.set_role_admin<_, GuardianRole, GuardianRole>(scenario.ctx());
    registry.set_role_admin<_, DistributorRole, GuardianRole>(scenario.ctx());

    // The root admin schedules the renounce.
    registry.begin_default_admin_renounce(&clock, scenario.ctx());
    assert!(registry.is_pending_default_admin_renounce());
    ts::return_shared(registry);

    // Once the timelock elapses, the admin finalizes and the root role is left vacant.
    clock.increment_for_testing(PAST_DELAY_MS);
    scenario.next_tx(ADMIN);
    let mut registry = scenario.take_shared<AccessControl<EXAMPLE_REWARD_TREASURY>>();
    registry.accept_default_admin_renounce(&clock, scenario.ctx());
    assert_eq!(registry.default_admin(), option::none());

    // The root is gone, but role management stays alive: the admin still holds the
    // guardian role, so it can grant - and, crucially, still revoke - distributors.
    registry.grant_role<_, DistributorRole>(DISTRIBUTOR, scenario.ctx());
    assert!(registry.has_role<_, DistributorRole>(DISTRIBUTOR));
    registry.revoke_role<_, DistributorRole>(DISTRIBUTOR, scenario.ctx());
    assert!(!registry.has_role<_, DistributorRole>(DISTRIBUTOR));

    ts::return_shared(registry);
    destroy(clock);
    scenario.end();
}

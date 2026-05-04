// `abort 0` sentinels appear after each known-aborting call in the
// `expected_failure` tests — they're deliberate, unreachable, and exist only
// to satisfy the type checker on the `ac` / `clk` bindings without rewriting
// every test as a by-value helper. Suppressed module-wide so individual
// tests stay clean.
#[test_only, allow(lint(abort_without_constant))]
module openzeppelin_access::access_control_tests;

use openzeppelin_access::access_control::{Self, AccessControl};
use openzeppelin_access::foreign_role::ForeignRole;
use std::type_name::with_original_ids;
use std::unit_test::assert_eq;
use sui::clock;
use sui::event;
use sui::test_scenario::{Self, Scenario};

// === Test fixtures ===
//
// `ACCESS_CONTROL_TESTS` is the OTW for this module — its name matches the
// module name, so `is_one_time_witness` accepts it as the root role even when
// constructed manually inside a test. `NotAnOtw` deliberately violates the
// OTW name convention to exercise the rejection path. The phantom role
// markers are defined here so they share a home module with the OTW; the
// library's home-module check accepts them. Foreign role rejection uses
// `ForeignRole` from the sibling `foreign_role` module.

public struct ACCESS_CONTROL_TESTS has drop {}

public struct NotAnOtw has drop {}

public struct AdminA {}
public struct AdminB {}
public struct RoleX {}
public struct RoleY {}

// === Setup helpers ===

/// Deploys an `AccessControl` rooted at `ACCESS_CONTROL_TESTS`, shares it,
/// and advances to a fresh transaction so `take_shared` is immediately
/// available.
#[test_only]
#[allow(lint(share_owned))]
fun setup(deployer: address, delay: u64): Scenario {
    let mut scenario = test_scenario::begin(deployer);
    let ac = access_control::new<ACCESS_CONTROL_TESTS>(
        ACCESS_CONTROL_TESTS {},
        delay,
        scenario.ctx(),
    );
    transfer::public_share_object(ac);
    scenario.next_tx(deployer);
    scenario
}

/// Convenience: take the singleton registry from the current transaction.
/// Wraps `test_scenario::take_shared` to keep test bodies tight.
#[test_only]
fun take_ac(scenario: &Scenario): AccessControl<ACCESS_CONTROL_TESTS> {
    scenario.take_shared<AccessControl<ACCESS_CONTROL_TESTS>>()
}

// === Constructor ===

#[test]
#[allow(lint(share_owned))]
fun test_new_with_otw_succeeds() {
    let deployer = @0xA;
    let mut scenario = test_scenario::begin(deployer);
    let ac = access_control::new<ACCESS_CONTROL_TESTS>(
        ACCESS_CONTROL_TESTS {},
        0,
        scenario.ctx(),
    );

    // Sender becomes the root holder.
    assert!(ac.has_role<_, ACCESS_CONTROL_TESTS>(deployer));
    // Protected root TypeName matches the OTW type.
    assert_eq!(ac.protected_root(), with_original_ids<ACCESS_CONTROL_TESTS>());
    // RoleGranted emitted for the root holder. Asserted in the same tx as
    // construction because `events_by_type` is per-transaction.
    let granted = event::events_by_type<access_control::RoleGranted>();
    assert_eq!(granted.length(), 1);
    let expected = access_control::test_new_role_granted(
        with_original_ids<ACCESS_CONTROL_TESTS>(),
        deployer,
        deployer,
    );
    assert_eq!(granted[0], expected);

    transfer::public_share_object(ac);
    scenario.end();
}

#[test, expected_failure(abort_code = access_control::ENotOneTimeWitness)]
fun test_new_rejects_non_otw() {
    let deployer = @0xA;
    let mut scenario = test_scenario::begin(deployer);
    let _ac = access_control::new<NotAnOtw>(NotAnOtw {}, 0, scenario.ctx());
    abort 0
}

#[test, expected_failure(abort_code = access_control::EDelayTooLarge)]
fun test_new_rejects_excessive_delay() {
    let deployer = @0xA;
    let mut scenario = test_scenario::begin(deployer);
    let _ac = access_control::new<ACCESS_CONTROL_TESTS>(
        ACCESS_CONTROL_TESTS {},
        access_control::max_default_admin_delay_ms() + 1,
        scenario.ctx(),
    );
    abort 0
}

#[test]
fun test_new_accepts_max_delay() {
    let deployer = @0xA;
    let max = access_control::max_default_admin_delay_ms();
    let scenario = setup(deployer, max);
    let ac = take_ac(&scenario);
    assert_eq!(ac.default_admin_delay_ms(), max);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_new_accepts_zero_delay() {
    let deployer = @0xA;
    let scenario = setup(deployer, 0);
    let ac = take_ac(&scenario);
    assert_eq!(ac.default_admin_delay_ms(), 0);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_max_default_admin_delay_constant() {
    // 30 days expressed in milliseconds.
    let expected: u64 = 30 * 24 * 60 * 60 * 1_000;
    assert_eq!(access_control::max_default_admin_delay_ms(), expected);
}

// === grant_role ===

#[test]
fun test_grant_role_happy_path() {
    let deployer = @0xA;
    let alice = @0xB;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);

    // Deployer holds the root role (= default admin of every fresh role),
    // so granting AdminA to alice is authorized.
    ac.grant_role<_, AdminA>(alice, scenario.ctx());

    assert!(ac.has_role<_, AdminA>(alice));
    assert!(!ac.has_role<_, AdminA>(deployer));
    // First grant of AdminA lazily creates the entry with admin = root.
    assert_eq!(ac.get_role_admin<_, AdminA>(), with_original_ids<ACCESS_CONTROL_TESTS>());

    // `events_by_type` is per-transaction; the construction event from `setup`
    // lives in the previous tx, so only the grant event shows up here.
    let granted = event::events_by_type<access_control::RoleGranted>();
    assert_eq!(granted.length(), 1);
    let expected = access_control::test_new_role_granted(
        with_original_ids<AdminA>(),
        alice,
        deployer,
    );
    assert_eq!(granted[0], expected);

    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_grant_role_idempotent() {
    let deployer = @0xA;
    let alice = @0xB;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);

    ac.grant_role<_, AdminA>(alice, scenario.ctx());
    let count_after_first = event::events_by_type<access_control::RoleGranted>().length();
    // Second grant to the same account is a no-op — no new event, no abort.
    ac.grant_role<_, AdminA>(alice, scenario.ctx());
    let count_after_second = event::events_by_type<access_control::RoleGranted>().length();
    assert_eq!(count_after_first, count_after_second);

    test_scenario::return_shared(ac);
    scenario.end();
}

#[test, expected_failure(abort_code = access_control::ECannotManageRootRole)]
fun test_grant_role_rejects_root() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    ac.grant_role<_, ACCESS_CONTROL_TESTS>(@0xB, scenario.ctx());
    abort 0
}

#[test, expected_failure(abort_code = access_control::EUnauthorized)]
fun test_grant_role_rejects_non_admin() {
    let deployer = @0xA;
    let alice = @0xB;
    let mut scenario = setup(deployer, 0);
    // alice is not an admin and not the deployer.
    scenario.next_tx(alice);
    let mut ac = take_ac(&scenario);
    ac.grant_role<_, AdminA>(alice, scenario.ctx());
    abort 0
}

#[test, expected_failure(abort_code = access_control::EForeignRole)]
fun test_grant_role_rejects_foreign() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    ac.grant_role<_, ForeignRole>(@0xB, scenario.ctx());
    abort 0
}

// === revoke_role ===

#[test]
fun test_revoke_role_happy_path() {
    let deployer = @0xA;
    let alice = @0xB;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);

    ac.grant_role<_, AdminA>(alice, scenario.ctx());
    assert!(ac.has_role<_, AdminA>(alice));

    ac.revoke_role<_, AdminA>(alice, scenario.ctx());
    assert!(!ac.has_role<_, AdminA>(alice));

    let revoked = event::events_by_type<access_control::RoleRevoked>();
    assert_eq!(revoked.length(), 1);
    let expected = access_control::test_new_role_revoked(
        with_original_ids<AdminA>(),
        alice,
        deployer,
    );
    assert_eq!(revoked[0], expected);

    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_revoke_role_idempotent_non_member() {
    let deployer = @0xA;
    let alice = @0xB;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);

    ac.grant_role<_, AdminA>(alice, scenario.ctx());
    let revoked_count = event::events_by_type<access_control::RoleRevoked>().length();

    // Carol never had the role — revoking is a no-op.
    ac.revoke_role<_, AdminA>(@0xC, scenario.ctx());
    assert_eq!(event::events_by_type<access_control::RoleRevoked>().length(), revoked_count);

    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_revoke_role_idempotent_unknown_role() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);

    // RoleY was never granted, so it has no bag entry. Revoking is a no-op.
    ac.revoke_role<_, RoleY>(@0xB, scenario.ctx());
    assert_eq!(event::events_by_type<access_control::RoleRevoked>().length(), 0);

    test_scenario::return_shared(ac);
    scenario.end();
}

#[test, expected_failure(abort_code = access_control::ECannotManageRootRole)]
fun test_revoke_role_rejects_root() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    ac.revoke_role<_, ACCESS_CONTROL_TESTS>(deployer, scenario.ctx());
    abort 0
}

#[test, expected_failure(abort_code = access_control::EUnauthorized)]
fun test_revoke_role_rejects_non_admin() {
    let deployer = @0xA;
    let alice = @0xB;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    ac.grant_role<_, AdminA>(alice, scenario.ctx());
    test_scenario::return_shared(ac);

    // Switch to a non-admin account and try to revoke.
    scenario.next_tx(@0xC);
    let mut ac = take_ac(&scenario);
    ac.revoke_role<_, AdminA>(alice, scenario.ctx());
    abort 0
}

#[test, expected_failure(abort_code = access_control::EForeignRole)]
fun test_revoke_role_rejects_foreign() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    ac.revoke_role<_, ForeignRole>(@0xB, scenario.ctx());
    abort 0
}

// === renounce_role ===

#[test]
fun test_renounce_role_happy_path() {
    let deployer = @0xA;
    let alice = @0xB;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);

    ac.grant_role<_, AdminA>(alice, scenario.ctx());
    test_scenario::return_shared(ac);

    scenario.next_tx(alice);
    let mut ac = take_ac(&scenario);
    ac.renounce_role<_, AdminA>(alice, scenario.ctx());
    assert!(!ac.has_role<_, AdminA>(alice));

    let revoked = event::events_by_type<access_control::RoleRevoked>();
    let last = revoked[revoked.length() - 1];
    let expected = access_control::test_new_role_revoked(
        with_original_ids<AdminA>(),
        alice,
        alice,
    );
    assert_eq!(last, expected);

    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_renounce_role_root_allowed() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);

    // Renouncing the root role IS allowed (with the documented permanent-
    // lockout warning). The library does not block this path.
    ac.renounce_role<_, ACCESS_CONTROL_TESTS>(deployer, scenario.ctx());
    assert!(!ac.has_role<_, ACCESS_CONTROL_TESTS>(deployer));

    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_renounce_role_idempotent_non_member() {
    let deployer = @0xA;
    let alice = @0xB;
    let mut scenario = setup(deployer, 0);
    scenario.next_tx(alice);
    let mut ac = take_ac(&scenario);

    // alice never held AdminA — renounce is a no-op, no event.
    ac.renounce_role<_, AdminA>(alice, scenario.ctx());
    assert_eq!(event::events_by_type<access_control::RoleRevoked>().length(), 0);

    test_scenario::return_shared(ac);
    scenario.end();
}

// Renounce idempotency: account == sender, role in bag, but the caller is not
// a member — the second early-return path. Distinct from the "role not in bag"
// path covered by the test above.
#[test]
fun test_renounce_role_idempotent_role_in_bag_non_member() {
    let deployer = @0xA;
    let alice = @0xB;
    let carol = @0xC;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);

    // Grant AdminA to alice — the role's bag entry now exists.
    ac.grant_role<_, AdminA>(alice, scenario.ctx());
    test_scenario::return_shared(ac);

    // Carol is not a member of AdminA — exercises the "role in bag, not
    // member" early-return branch.
    scenario.next_tx(carol);
    let mut ac = take_ac(&scenario);
    ac.renounce_role<_, AdminA>(carol, scenario.ctx());
    assert_eq!(event::events_by_type<access_control::RoleRevoked>().length(), 0);

    test_scenario::return_shared(ac);
    scenario.end();
}

#[test, expected_failure(abort_code = access_control::ECannotRenounceForOtherAccount)]
fun test_renounce_role_rejects_other_account() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    // Sender is deployer; trying to renounce on behalf of @0xB must abort.
    ac.renounce_role<_, AdminA>(@0xB, scenario.ctx());
    abort 0
}

#[test, expected_failure(abort_code = access_control::EForeignRole)]
fun test_renounce_role_rejects_foreign() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    ac.renounce_role<_, ForeignRole>(deployer, scenario.ctx());
    abort 0
}

// === set_role_admin ===

#[test]
fun test_set_role_admin_happy_path() {
    let deployer = @0xA;
    let alice = @0xB;
    let bob = @0xC;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);

    // Wire AdminA → admin of RoleX. RoleX has no entry yet; this lazily
    // creates it with admin = AdminA.
    ac.set_role_admin<_, RoleX, AdminA>(scenario.ctx());
    assert_eq!(ac.get_role_admin<_, RoleX>(), with_original_ids<AdminA>());

    // RoleAdminChanged emitted.
    let changed = event::events_by_type<access_control::RoleAdminChanged>();
    assert_eq!(changed.length(), 1);
    let expected = access_control::test_new_role_admin_changed(
        with_original_ids<RoleX>(),
        with_original_ids<ACCESS_CONTROL_TESTS>(),
        with_original_ids<AdminA>(),
    );
    assert_eq!(changed[0], expected);

    // Grant AdminA to alice. alice can now grant RoleX (chain in effect),
    // but the deployer (root) no longer can — RoleX's admin is now AdminA.
    ac.grant_role<_, AdminA>(alice, scenario.ctx());
    test_scenario::return_shared(ac);

    scenario.next_tx(alice);
    let mut ac = take_ac(&scenario);
    ac.grant_role<_, RoleX>(bob, scenario.ctx());
    assert!(ac.has_role<_, RoleX>(bob));

    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_set_role_admin_lazy_create() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);

    // RoleY has never been granted.
    ac.set_role_admin<_, RoleY, AdminB>(scenario.ctx());
    assert_eq!(ac.get_role_admin<_, RoleY>(), with_original_ids<AdminB>());

    test_scenario::return_shared(ac);
    scenario.end();
}

// set_role_admin against a role that already has a bag entry — exercises
// the "update existing admin_role" branch (the lazy-create branch is covered
// by the test above) and asserts the event reports previous = old admin
// rather than empty / fresh-default.
#[test]
fun test_set_role_admin_updates_existing_role() {
    let deployer = @0xA;
    let alice = @0xB;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);

    // First grant of RoleX creates the bag entry with admin = root.
    ac.grant_role<_, RoleX>(alice, scenario.ctx());
    assert_eq!(ac.get_role_admin<_, RoleX>(), with_original_ids<ACCESS_CONTROL_TESTS>());

    // Re-target RoleX's admin to AdminA — exercises the "update existing
    // entry" branch (the lazy-create branch is covered by the test above).
    ac.set_role_admin<_, RoleX, AdminA>(scenario.ctx());

    assert_eq!(ac.get_role_admin<_, RoleX>(), with_original_ids<AdminA>());
    // Existing membership preserved across the admin change.
    assert!(ac.has_role<_, RoleX>(alice));

    // Event reports previous = root (NOT empty), new = AdminA.
    let changed = event::events_by_type<access_control::RoleAdminChanged>();
    assert_eq!(changed.length(), 1);
    let expected = access_control::test_new_role_admin_changed(
        with_original_ids<RoleX>(),
        with_original_ids<ACCESS_CONTROL_TESTS>(),
        with_original_ids<AdminA>(),
    );
    assert_eq!(changed[0], expected);

    test_scenario::return_shared(ac);
    scenario.end();
}

#[test, expected_failure(abort_code = access_control::ECannotManageRootRole)]
fun test_set_role_admin_rejects_root_subject() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    ac.set_role_admin<_, ACCESS_CONTROL_TESTS, AdminA>(scenario.ctx());
    abort 0
}

#[test, expected_failure(abort_code = access_control::EUnauthorized)]
fun test_set_role_admin_rejects_non_admin() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    scenario.next_tx(@0xB);
    let mut ac = take_ac(&scenario);
    ac.set_role_admin<_, RoleX, AdminA>(scenario.ctx());
    abort 0
}

#[test, expected_failure(abort_code = access_control::EForeignRole)]
fun test_set_role_admin_rejects_foreign_role() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    ac.set_role_admin<_, ForeignRole, AdminA>(scenario.ctx());
    abort 0
}

#[test, expected_failure(abort_code = access_control::EForeignRole)]
fun test_set_role_admin_rejects_foreign_admin_role() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    ac.set_role_admin<_, RoleX, ForeignRole>(scenario.ctx());
    abort 0
}

// === Read-only queries ===

#[test]
fun test_has_role_member_returns_true() {
    let deployer = @0xA;
    let alice = @0xB;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    ac.grant_role<_, AdminA>(alice, scenario.ctx());
    assert!(ac.has_role<_, AdminA>(alice));
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_has_role_non_member_returns_false() {
    let deployer = @0xA;
    let alice = @0xB;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    ac.grant_role<_, AdminA>(alice, scenario.ctx());
    assert!(!ac.has_role<_, AdminA>(@0xC));
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_has_role_unknown_role_returns_false() {
    let deployer = @0xA;
    let scenario = setup(deployer, 0);
    let ac = take_ac(&scenario);
    // RoleX has no bag entry at all.
    assert!(!ac.has_role<_, RoleX>(deployer));
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_assert_role_passes_for_member() {
    let deployer = @0xA;
    let scenario = setup(deployer, 0);
    let ac = take_ac(&scenario);
    // Deployer holds root — assert_role on root must not abort.
    ac.assert_role<_, ACCESS_CONTROL_TESTS>(deployer);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test, expected_failure(abort_code = access_control::EUnauthorized)]
fun test_assert_role_aborts_for_non_member() {
    let deployer = @0xA;
    let scenario = setup(deployer, 0);
    let ac = take_ac(&scenario);
    ac.assert_role<_, AdminA>(@0xB);
    abort 0
}

#[test]
fun test_get_role_admin_defaults_to_root() {
    let deployer = @0xA;
    let scenario = setup(deployer, 0);
    let ac = take_ac(&scenario);
    // RoleX has no entry — get_role_admin returns the protected root.
    assert_eq!(ac.get_role_admin<_, RoleX>(), with_original_ids<ACCESS_CONTROL_TESTS>());
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_get_role_admin_after_set() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    ac.set_role_admin<_, RoleX, AdminA>(scenario.ctx());
    assert_eq!(ac.get_role_admin<_, RoleX>(), with_original_ids<AdminA>());
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_protected_root_returns_root_typename() {
    let deployer = @0xA;
    let scenario = setup(deployer, 0);
    let ac = take_ac(&scenario);
    assert_eq!(ac.protected_root(), with_original_ids<ACCESS_CONTROL_TESTS>());
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_default_admin_delay_ms_persisted() {
    let deployer = @0xA;
    let scenario = setup(deployer, 12345);
    let ac = take_ac(&scenario);
    assert_eq!(ac.default_admin_delay_ms(), 12345);
    test_scenario::return_shared(ac);
    scenario.end();
}

// === Auth issuance ===

#[test]
fun test_new_auth_happy_path() {
    let deployer = @0xA;
    let alice = @0xB;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    ac.grant_role<_, AdminA>(alice, scenario.ctx());
    test_scenario::return_shared(ac);

    scenario.next_tx(alice);
    let ac = take_ac(&scenario);
    let auth = ac.new_auth<_, AdminA>(scenario.ctx());
    assert_eq!(access_control::auth_addr(&auth), alice);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test, expected_failure(abort_code = access_control::EUnauthorized)]
fun test_new_auth_aborts_for_non_member() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    scenario.next_tx(@0xB);
    let ac = take_ac(&scenario);
    let _auth = ac.new_auth<_, AdminA>(scenario.ctx());
    abort 0
}

#[test, expected_failure(abort_code = access_control::EForeignRole)]
fun test_new_auth_rejects_foreign() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let ac = take_ac(&scenario);
    let _auth = ac.new_auth<_, ForeignRole>(scenario.ctx());
    abort 0
}

#[test]
fun test_new_auth_for_root_holder() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let ac = take_ac(&scenario);
    let auth = ac.new_auth<_, ACCESS_CONTROL_TESTS>(scenario.ctx());
    assert_eq!(access_control::auth_addr(&auth), deployer);
    test_scenario::return_shared(ac);
    scenario.end();
}

// === begin_default_admin_transfer ===

#[test]
fun test_begin_admin_transfer_happy_path() {
    let deployer = @0xA;
    let new_admin = @0xB;
    let delay = 1000;
    let mut scenario = setup(deployer, delay);
    let mut ac = take_ac(&scenario);

    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    ac.begin_default_admin_transfer(new_admin, &clk, scenario.ctx());

    assert!(ac.has_pending_default_admin_transfer());
    assert_eq!(ac.pending_default_admin_new_admin(), option::some(new_admin));
    assert_eq!(ac.pending_default_admin_execute_after_ms(), option::some(delay));

    let scheduled = event::events_by_type<access_control::DefaultAdminTransferScheduled>();
    assert_eq!(scheduled.length(), 1);
    let expected = access_control::test_new_default_admin_transfer_scheduled(new_admin, delay);
    assert_eq!(scheduled[0], expected);

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test, expected_failure(abort_code = access_control::EUnauthorized)]
fun test_begin_admin_transfer_rejects_non_root() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    scenario.next_tx(@0xB);
    let mut ac = take_ac(&scenario);
    let clk = clock::create_for_testing(scenario.ctx());
    ac.begin_default_admin_transfer(@0xC, &clk, scenario.ctx());
    abort 0
}

#[test]
fun test_begin_admin_transfer_overwrites_pending() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);

    ac.begin_default_admin_transfer(@0xB, &clk, scenario.ctx());
    // Advance clock to differentiate execute_after_ms.
    clk.set_for_testing(50);
    ac.begin_default_admin_transfer(@0xC, &clk, scenario.ctx());

    assert_eq!(ac.pending_default_admin_new_admin(), option::some(@0xC));
    assert_eq!(ac.pending_default_admin_execute_after_ms(), option::some(50));

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

// === accept_default_admin_transfer ===

#[test]
fun test_accept_admin_transfer_happy_path() {
    let deployer = @0xA;
    let new_admin = @0xB;
    let delay = 100;
    let mut scenario = setup(deployer, delay);
    let mut ac = take_ac(&scenario);

    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    ac.begin_default_admin_transfer(new_admin, &clk, scenario.ctx());
    test_scenario::return_shared(ac);

    // Advance time past the delay; pending admin accepts.
    scenario.next_tx(new_admin);
    let mut ac = take_ac(&scenario);
    clk.set_for_testing(delay);
    let granted_before = event::events_by_type<access_control::RoleGranted>().length();
    let revoked_before = event::events_by_type<access_control::RoleRevoked>().length();
    ac.accept_default_admin_transfer(&clk, scenario.ctx());

    // Atomic rotation: old admin lost root, new admin gained it.
    assert!(!ac.has_role<_, ACCESS_CONTROL_TESTS>(deployer));
    assert!(ac.has_role<_, ACCESS_CONTROL_TESTS>(new_admin));
    // Pending state cleared.
    assert!(!ac.has_pending_default_admin_transfer());
    assert!(ac.pending_default_admin_new_admin().is_none());
    assert!(ac.pending_default_admin_execute_after_ms().is_none());
    // Both events emitted in this transaction.
    assert_eq!(event::events_by_type<access_control::RoleGranted>().length(), granted_before + 1);
    assert_eq!(event::events_by_type<access_control::RoleRevoked>().length(), revoked_before + 1);

    // Field-level event payload assertions for the atomic rotation: the pair
    // of events (revoke-old, grant-new) must each carry the right role
    // TypeName and the right addresses.
    let granted = event::events_by_type<access_control::RoleGranted>();
    let last_granted = granted[granted.length() - 1];
    assert_eq!(
        last_granted,
        access_control::test_new_role_granted(
            with_original_ids<ACCESS_CONTROL_TESTS>(),
            new_admin,
            new_admin,
        ),
    );
    let revoked = event::events_by_type<access_control::RoleRevoked>();
    let last_revoked = revoked[revoked.length() - 1];
    assert_eq!(
        last_revoked,
        access_control::test_new_role_revoked(
            with_original_ids<ACCESS_CONTROL_TESTS>(),
            deployer,
            new_admin,
        ),
    );

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test, expected_failure(abort_code = access_control::ENoPendingAdminTransfer)]
fun test_accept_admin_transfer_rejects_no_pending() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    let clk = clock::create_for_testing(scenario.ctx());
    ac.accept_default_admin_transfer(&clk, scenario.ctx());
    abort 0
}

#[test, expected_failure(abort_code = access_control::ENotPendingAdmin)]
fun test_accept_admin_transfer_rejects_wrong_caller() {
    let deployer = @0xA;
    let new_admin = @0xB;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    ac.begin_default_admin_transfer(new_admin, &clk, scenario.ctx());
    test_scenario::return_shared(ac);

    // Carol (not the pending admin) tries to accept.
    scenario.next_tx(@0xC);
    let mut ac = take_ac(&scenario);
    ac.accept_default_admin_transfer(&clk, scenario.ctx());
    abort 0
}

#[test, expected_failure(abort_code = access_control::EDelayNotElapsed)]
fun test_accept_admin_transfer_rejects_too_early() {
    let deployer = @0xA;
    let new_admin = @0xB;
    let delay = 100;
    let mut scenario = setup(deployer, delay);
    let mut ac = take_ac(&scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    ac.begin_default_admin_transfer(new_admin, &clk, scenario.ctx());
    test_scenario::return_shared(ac);

    scenario.next_tx(new_admin);
    let mut ac = take_ac(&scenario);
    clk.set_for_testing(delay - 1);
    ac.accept_default_admin_transfer(&clk, scenario.ctx());
    abort 0
}

#[test]
fun test_accept_admin_transfer_at_exact_delay() {
    let deployer = @0xA;
    let new_admin = @0xB;
    let delay = 50;
    let mut scenario = setup(deployer, delay);
    let mut ac = take_ac(&scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    ac.begin_default_admin_transfer(new_admin, &clk, scenario.ctx());
    test_scenario::return_shared(ac);

    scenario.next_tx(new_admin);
    let mut ac = take_ac(&scenario);
    // Boundary: clock == execute_after_ms. The check is `>=`.
    clk.set_for_testing(delay);
    ac.accept_default_admin_transfer(&clk, scenario.ctx());

    assert!(ac.has_role<_, ACCESS_CONTROL_TESTS>(new_admin));

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

// === cancel_default_admin_transfer ===

#[test]
fun test_cancel_admin_transfer_happy_path() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    let clk = clock::create_for_testing(scenario.ctx());
    ac.begin_default_admin_transfer(@0xB, &clk, scenario.ctx());

    ac.cancel_default_admin_transfer(scenario.ctx());

    assert!(!ac.has_pending_default_admin_transfer());
    assert!(ac.pending_default_admin_new_admin().is_none());
    let cancelled = event::events_by_type<access_control::DefaultAdminTransferCancelled>();
    assert_eq!(cancelled.length(), 1);
    let expected = access_control::test_new_default_admin_transfer_cancelled();
    assert_eq!(cancelled[0], expected);

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test, expected_failure(abort_code = access_control::ENoPendingAdminTransfer)]
fun test_cancel_admin_transfer_rejects_no_pending() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    ac.cancel_default_admin_transfer(scenario.ctx());
    abort 0
}

#[test, expected_failure(abort_code = access_control::EUnauthorized)]
fun test_cancel_admin_transfer_rejects_non_root() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    let clk = clock::create_for_testing(scenario.ctx());
    ac.begin_default_admin_transfer(@0xB, &clk, scenario.ctx());
    test_scenario::return_shared(ac);

    scenario.next_tx(@0xC);
    let mut ac = take_ac(&scenario);
    ac.cancel_default_admin_transfer(scenario.ctx());
    clock::destroy_for_testing(clk);
    abort 0
}

// === Pending-transfer getters with no pending ===

#[test]
fun test_pending_getters_when_no_pending() {
    let deployer = @0xA;
    let scenario = setup(deployer, 0);
    let ac = take_ac(&scenario);
    assert!(!ac.has_pending_default_admin_transfer());
    assert!(ac.pending_default_admin_new_admin().is_none());
    assert!(ac.pending_default_admin_execute_after_ms().is_none());
    test_scenario::return_shared(ac);
    scenario.end();
}

// === Composability: full role hierarchy chain ===

#[test]
fun test_role_hierarchy_chain() {
    let deployer = @0xA;
    let admin_a = @0xB;
    let user = @0xC;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);

    // Root grants AdminA to admin_a.
    ac.grant_role<_, AdminA>(admin_a, scenario.ctx());
    // Root sets RoleX's admin to AdminA.
    ac.set_role_admin<_, RoleX, AdminA>(scenario.ctx());
    test_scenario::return_shared(ac);

    // Now admin_a (not root) can grant RoleX.
    scenario.next_tx(admin_a);
    let mut ac = take_ac(&scenario);
    ac.grant_role<_, RoleX>(user, scenario.ctx());
    assert!(ac.has_role<_, RoleX>(user));

    // user can mint Auth<RoleX>.
    test_scenario::return_shared(ac);
    scenario.next_tx(user);
    let ac = take_ac(&scenario);
    let auth = ac.new_auth<_, RoleX>(scenario.ctx());
    assert_eq!(access_control::auth_addr(&auth), user);

    test_scenario::return_shared(ac);
    scenario.end();
}

// === Edge: pending transfer survives root renounce ===
//
// A root holder schedules a transfer, then renounces their own root. The
// pending transfer is independent of who currently holds root, so the
// scheduled new admin can still accept and become root. This is what makes
// "two-step transfer + renounce" a viable hand-off pattern even when the
// original admin wants to be off-chain immediately after scheduling.

#[test]
fun test_pending_transfer_survives_root_renounce() {
    let deployer = @0xA;
    let new_admin = @0xB;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);

    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    ac.begin_default_admin_transfer(new_admin, &clk, scenario.ctx());
    ac.renounce_role<_, ACCESS_CONTROL_TESTS>(deployer, scenario.ctx());

    // Pending state intact even though no one currently holds root.
    assert!(ac.has_pending_default_admin_transfer());
    assert!(!ac.has_role<_, ACCESS_CONTROL_TESTS>(deployer));
    test_scenario::return_shared(ac);

    // new_admin accepts; protocol recovers from the temporary unmanaged state.
    scenario.next_tx(new_admin);
    let mut ac = take_ac(&scenario);

    // Snapshot event counts in this tx and verify the "no old admin" branch
    // only emits RoleGranted (RoleRevoked is skipped because the root role
    // had zero holders after the renounce).
    let revoked_before = event::events_by_type<access_control::RoleRevoked>().length();
    let granted_before = event::events_by_type<access_control::RoleGranted>().length();
    ac.accept_default_admin_transfer(&clk, scenario.ctx());
    assert!(ac.has_role<_, ACCESS_CONTROL_TESTS>(new_admin));
    assert_eq!(event::events_by_type<access_control::RoleRevoked>().length(), revoked_before);
    assert_eq!(event::events_by_type<access_control::RoleGranted>().length(), granted_before + 1);

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

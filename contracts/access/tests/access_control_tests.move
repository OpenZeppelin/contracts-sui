// `abort 999` sentinels appear after each known-aborting call in the
// `expected_failure` tests - they're deliberate, unreachable, and exist only
// to satisfy the type checker on the `ac` / `clk` bindings without rewriting
// every test as a by-value helper. Suppressed module-wide so individual
// tests stay clean.
// `#[test_only]` is required here, not redundant: this module constructs its
// own OTW (`ACCESS_CONTROL_TESTS {}`) in `setup`. The Sui verifier only allows
// manual OTW construction when the enclosing module/function carries the
// `#[test]`/`#[test_only]` attribute - it keys off the attribute, not the
// `tests/` directory - so dropping it reintroduces the "Invalid one-time
// witness construction" error.
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
// `ACCESS_CONTROL_TESTS` is the OTW for this module - its name matches the
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

    // Sender becomes the default admin.
    assert!(ac.has_role<_, ACCESS_CONTROL_TESTS>(deployer));
    assert_eq!(ac.default_admin(), option::some(deployer));
    // Protected root TypeName matches the OTW type.
    assert_eq!(ac.protected_root(), with_original_ids<ACCESS_CONTROL_TESTS>());
    // RoleGranted emitted for the default admin. Asserted in the same tx as
    // construction because `events_by_type` is per-transaction.
    let granted = event::events_by_type<access_control::RoleGranted<ACCESS_CONTROL_TESTS>>();
    assert_eq!(granted.length(), 1);
    let expected = access_control::test_new_role_granted<ACCESS_CONTROL_TESTS>(
        with_original_ids<ACCESS_CONTROL_TESTS>(),
        deployer,
    );
    assert_eq!(granted[0], expected);

    transfer::public_share_object(ac);
    scenario.end();
}

#[test]
#[allow(lint(share_owned))]
fun test_new_with_admin_sets_explicit_root_holder() {
    let deployer = @0xA;
    let initial_admin = @0xB;
    let mut scenario = test_scenario::begin(deployer);
    let ac = access_control::new_with_admin<ACCESS_CONTROL_TESTS>(
        ACCESS_CONTROL_TESTS {},
        initial_admin,
        0,
        scenario.ctx(),
    );

    assert!(!ac.has_role<_, ACCESS_CONTROL_TESTS>(deployer));
    assert!(ac.has_role<_, ACCESS_CONTROL_TESTS>(initial_admin));
    assert_eq!(ac.default_admin(), option::some(initial_admin));
    assert_eq!(ac.protected_root(), with_original_ids<ACCESS_CONTROL_TESTS>());

    let granted = event::events_by_type<access_control::RoleGranted<ACCESS_CONTROL_TESTS>>();
    assert_eq!(granted.length(), 1);
    let expected = access_control::test_new_role_granted<ACCESS_CONTROL_TESTS>(
        with_original_ids<ACCESS_CONTROL_TESTS>(),
        initial_admin,
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
    abort 999
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
    abort 999
}

#[test, expected_failure(abort_code = access_control::EZeroAddress)]
fun test_new_with_admin_rejects_zero_address() {
    let deployer = @0xA;
    let mut scenario = test_scenario::begin(deployer);
    let _ac = access_control::new_with_admin<ACCESS_CONTROL_TESTS>(
        ACCESS_CONTROL_TESTS {},
        @0x0,
        0,
        scenario.ctx(),
    );
    abort 999
}

#[test]
fun test_new_accepts_max_delay() {
    let deployer = @0xA;
    let max = access_control::max_default_admin_delay_ms();
    let mut scenario = setup(deployer, max);
    let ac = take_ac(&scenario);
    let clk = clock::create_for_testing(scenario.ctx());
    assert_eq!(ac.default_admin_delay_ms(&clk), max);
    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_new_accepts_zero_delay() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let ac = take_ac(&scenario);
    let clk = clock::create_for_testing(scenario.ctx());
    assert_eq!(ac.default_admin_delay_ms(&clk), 0);
    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_max_default_admin_delay_constant() {
    // 60 days (~ 2 calendar months) expressed in milliseconds.
    let expected: u64 = 60 * 24 * 60 * 60 * 1_000;
    assert_eq!(access_control::max_default_admin_delay_ms(), expected);
}

#[test]
fun test_max_delay_increase_wait_constant() {
    // 48 hours expressed in milliseconds.
    let expected: u64 = 48 * 60 * 60 * 1_000;
    assert_eq!(access_control::max_delay_increase_wait_ms(), expected);
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
    let granted = event::events_by_type<access_control::RoleGranted<ACCESS_CONTROL_TESTS>>();
    assert_eq!(granted.length(), 1);
    let expected = access_control::test_new_role_granted<ACCESS_CONTROL_TESTS>(
        with_original_ids<AdminA>(),
        alice,
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
    let count_after_first = event::events_by_type<
        access_control::RoleGranted<ACCESS_CONTROL_TESTS>,
    >().length();
    // Second grant to the same account is a no-op - no new event, no abort.
    ac.grant_role<_, AdminA>(alice, scenario.ctx());
    let count_after_second = event::events_by_type<
        access_control::RoleGranted<ACCESS_CONTROL_TESTS>,
    >().length();
    assert_eq!(count_after_first, count_after_second);

    test_scenario::return_shared(ac);
    scenario.end();
}

// Non-root roles have no membership cap (unlike root, which is stored as a
// single `Option<address>` holder). Pin that two distinct accounts can
// simultaneously hold the same non-root role.
#[test]
fun test_grant_role_multiple_holders() {
    let deployer = @0xA;
    let alice = @0xB;
    let bob = @0xC;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);

    ac.grant_role<_, AdminA>(alice, scenario.ctx());
    ac.grant_role<_, AdminA>(bob, scenario.ctx());

    assert!(ac.has_role<_, AdminA>(alice));
    assert!(ac.has_role<_, AdminA>(bob));

    test_scenario::return_shared(ac);
    scenario.end();
}

#[test, expected_failure(abort_code = access_control::ECannotManageRootRole)]
fun test_grant_role_rejects_root() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    ac.grant_role<_, ACCESS_CONTROL_TESTS>(@0xB, scenario.ctx());
    abort 999
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
    abort 999
}

#[test, expected_failure(abort_code = access_control::EForeignRole)]
fun test_grant_role_rejects_foreign() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    ac.grant_role<_, ForeignRole>(@0xB, scenario.ctx());
    abort 999
}

#[test, expected_failure(abort_code = access_control::EZeroAddress)]
fun test_grant_role_rejects_zero_address() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    ac.grant_role<_, AdminA>(@0x0, scenario.ctx());
    abort 999
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

    let revoked = event::events_by_type<access_control::RoleRevoked<ACCESS_CONTROL_TESTS>>();
    assert_eq!(revoked.length(), 1);
    let expected = access_control::test_new_role_revoked<ACCESS_CONTROL_TESTS>(
        with_original_ids<AdminA>(),
        alice,
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
    let revoked_count = event::events_by_type<
        access_control::RoleRevoked<ACCESS_CONTROL_TESTS>,
    >().length();

    // Carol never had the role - revoking is a no-op.
    ac.revoke_role<_, AdminA>(@0xC, scenario.ctx());
    assert_eq!(
        event::events_by_type<access_control::RoleRevoked<ACCESS_CONTROL_TESTS>>().length(),
        revoked_count,
    );

    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_revoke_role_idempotent_unknown_role() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);

    // RoleY was never granted, so it has no role entry. Revoking is a no-op.
    ac.revoke_role<_, RoleY>(@0xB, scenario.ctx());
    assert_eq!(
        event::events_by_type<access_control::RoleRevoked<ACCESS_CONTROL_TESTS>>().length(),
        0,
    );

    test_scenario::return_shared(ac);
    scenario.end();
}

#[test, expected_failure(abort_code = access_control::ECannotManageRootRole)]
fun test_revoke_role_rejects_root() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    ac.revoke_role<_, ACCESS_CONTROL_TESTS>(deployer, scenario.ctx());
    abort 999
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
    abort 999
}

#[test, expected_failure(abort_code = access_control::EForeignRole)]
fun test_revoke_role_rejects_foreign() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    ac.revoke_role<_, ForeignRole>(@0xB, scenario.ctx());
    abort 999
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
    ac.renounce_role<_, AdminA>(scenario.ctx());
    assert!(!ac.has_role<_, AdminA>(alice));

    let revoked = event::events_by_type<access_control::RoleRevoked<ACCESS_CONTROL_TESTS>>();
    let last = revoked[revoked.length() - 1];
    let expected = access_control::test_new_role_revoked<ACCESS_CONTROL_TESTS>(
        with_original_ids<AdminA>(),
        alice,
    );
    assert_eq!(last, expected);

    test_scenario::return_shared(ac);
    scenario.end();
}

// Direct `renounce_role` on the root role is blocked - the only way to
// relinquish the root role is the timelocked `begin_default_admin_renounce`
// + `accept_default_admin_renounce` flow. Without this block, a stray
// renounce call could leave the registry permanently unmanaged with no
// cancel window.
#[test, expected_failure(abort_code = access_control::ECannotManageRootRole)]
fun test_renounce_role_rejects_root() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    ac.renounce_role<_, ACCESS_CONTROL_TESTS>(scenario.ctx());
    abort 999
}

#[test]
fun test_renounce_role_idempotent_non_member() {
    let deployer = @0xA;
    let alice = @0xB;
    let mut scenario = setup(deployer, 0);
    scenario.next_tx(alice);
    let mut ac = take_ac(&scenario);

    // alice never held AdminA - renounce is a no-op, no event.
    ac.renounce_role<_, AdminA>(scenario.ctx());
    assert_eq!(
        event::events_by_type<access_control::RoleRevoked<ACCESS_CONTROL_TESTS>>().length(),
        0,
    );

    test_scenario::return_shared(ac);
    scenario.end();
}

// Renounce idempotency: role entry exists, but the caller is not a member -
// the second early-return path. Distinct from the "no role entry" path covered
// by the test above.
#[test]
fun test_renounce_role_idempotent_existing_role_non_member() {
    let deployer = @0xA;
    let alice = @0xB;
    let carol = @0xC;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);

    // Grant AdminA to alice - the role entry now exists.
    ac.grant_role<_, AdminA>(alice, scenario.ctx());
    test_scenario::return_shared(ac);

    // Carol is not a member of AdminA - exercises the "role entry exists, not
    // member" early-return branch.
    scenario.next_tx(carol);
    let mut ac = take_ac(&scenario);
    ac.renounce_role<_, AdminA>(scenario.ctx());
    assert_eq!(
        event::events_by_type<access_control::RoleRevoked<ACCESS_CONTROL_TESTS>>().length(),
        0,
    );

    test_scenario::return_shared(ac);
    scenario.end();
}

#[test, expected_failure(abort_code = access_control::EForeignRole)]
fun test_renounce_role_rejects_foreign() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    ac.renounce_role<_, ForeignRole>(scenario.ctx());
    abort 999
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
    let changed = event::events_by_type<access_control::RoleAdminChanged<ACCESS_CONTROL_TESTS>>();
    assert_eq!(changed.length(), 1);
    let expected = access_control::test_new_role_admin_changed<ACCESS_CONTROL_TESTS>(
        with_original_ids<RoleX>(),
        with_original_ids<ACCESS_CONTROL_TESTS>(),
        with_original_ids<AdminA>(),
    );
    assert_eq!(changed[0], expected);

    // Grant AdminA to alice. alice can now grant RoleX (chain in effect),
    // but the deployer (root) no longer can - RoleX's admin is now AdminA.
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

// set_role_admin against a role that already has an entry - exercises
// the "update existing admin_role" branch (the lazy-create branch is covered
// by the test above) and asserts the event reports previous = old admin
// rather than empty / fresh-default.
#[test]
fun test_set_role_admin_updates_existing_role() {
    let deployer = @0xA;
    let alice = @0xB;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);

    // First grant of RoleX creates the role entry with admin = root.
    ac.grant_role<_, RoleX>(alice, scenario.ctx());
    assert_eq!(ac.get_role_admin<_, RoleX>(), with_original_ids<ACCESS_CONTROL_TESTS>());

    // Re-target RoleX's admin to AdminA - exercises the "update existing
    // entry" branch (the lazy-create branch is covered by the test above).
    ac.set_role_admin<_, RoleX, AdminA>(scenario.ctx());

    assert_eq!(ac.get_role_admin<_, RoleX>(), with_original_ids<AdminA>());
    // Existing membership preserved across the admin change.
    assert!(ac.has_role<_, RoleX>(alice));

    // Event reports previous = root (NOT empty), new = AdminA.
    let changed = event::events_by_type<access_control::RoleAdminChanged<ACCESS_CONTROL_TESTS>>();
    assert_eq!(changed.length(), 1);
    let expected = access_control::test_new_role_admin_changed<ACCESS_CONTROL_TESTS>(
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
    abort 999
}

#[test, expected_failure(abort_code = access_control::EUnauthorized)]
fun test_set_role_admin_rejects_non_admin() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    scenario.next_tx(@0xB);
    let mut ac = take_ac(&scenario);
    ac.set_role_admin<_, RoleX, AdminA>(scenario.ctx());
    abort 999
}

// Companion to `test_set_role_admin_rejects_non_admin`. The original test
// covers the lazy-create branch where `previous_admin_role` defaults to root.
// This one covers the update-existing branch: after the first call records
// AdminA as RoleX's admin, the deployer (who holds root but not AdminA) must
// be rejected on the *second* call. Required coverage after the two branches
// of `set_role_admin` were inverted.
#[test, expected_failure(abort_code = access_control::EUnauthorized)]
fun test_set_role_admin_rejects_non_admin_existing_entry() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);

    // First call lazily creates RoleX with admin = AdminA. Deployer holds root
    // (the default admin during lazy-create), so this succeeds.
    ac.set_role_admin<_, RoleX, AdminA>(scenario.ctx());

    // Second call hits the update-existing branch. `previous_admin_role` is
    // now AdminA - deployer holds root but NOT AdminA, so this must abort.
    ac.set_role_admin<_, RoleX, AdminB>(scenario.ctx());
    abort 999
}

#[test, expected_failure(abort_code = access_control::EForeignRole)]
fun test_set_role_admin_rejects_foreign_role() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    ac.set_role_admin<_, ForeignRole, AdminA>(scenario.ctx());
    abort 999
}

#[test, expected_failure(abort_code = access_control::EForeignRole)]
fun test_set_role_admin_rejects_foreign_admin_role() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    ac.set_role_admin<_, RoleX, ForeignRole>(scenario.ctx());
    abort 999
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
    // RoleX has no role entry at all.
    assert!(!ac.has_role<_, RoleX>(deployer));
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_assert_has_role_passes_for_member() {
    let deployer = @0xA;
    let scenario = setup(deployer, 0);
    let ac = take_ac(&scenario);
    // Deployer holds root - assert_has_role on root must not abort.
    ac.assert_has_role<_, ACCESS_CONTROL_TESTS>(deployer);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test, expected_failure(abort_code = access_control::EUnauthorized)]
fun test_assert_has_role_aborts_for_non_member() {
    let deployer = @0xA;
    let scenario = setup(deployer, 0);
    let ac = take_ac(&scenario);
    ac.assert_has_role<_, AdminA>(@0xB);
    abort 999
}

#[test]
fun test_get_role_admin_defaults_to_root() {
    let deployer = @0xA;
    let scenario = setup(deployer, 0);
    let ac = take_ac(&scenario);
    // RoleX has no entry - get_role_admin returns the protected root.
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

#[test, expected_failure(abort_code = access_control::EForeignRole)]
fun test_get_role_admin_rejects_foreign() {
    let deployer = @0xA;
    let scenario = setup(deployer, 0);
    let ac = take_ac(&scenario);
    let _ = ac.get_role_admin<_, ForeignRole>();
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
    let mut scenario = setup(deployer, 12345);
    let ac = take_ac(&scenario);
    let clk = clock::create_for_testing(scenario.ctx());
    assert_eq!(ac.default_admin_delay_ms(&clk), 12345);
    clock::destroy_for_testing(clk);
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
    abort 999
}

#[test, expected_failure(abort_code = access_control::EForeignRole)]
fun test_new_auth_rejects_foreign() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let ac = take_ac(&scenario);
    let _auth = ac.new_auth<_, ForeignRole>(scenario.ctx());
    abort 999
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
    assert_eq!(ac.default_admin(), option::some(deployer));

    let scheduled = event::events_by_type<
        access_control::DefaultAdminTransferScheduled<ACCESS_CONTROL_TESTS>,
    >();
    assert_eq!(scheduled.length(), 1);
    let expected = access_control::test_new_default_admin_transfer_scheduled<ACCESS_CONTROL_TESTS>(
        new_admin,
        delay,
    );
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
    abort 999
}

#[test, expected_failure(abort_code = access_control::EZeroAddress)]
fun test_begin_admin_transfer_rejects_zero_address() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    let clk = clock::create_for_testing(scenario.ctx());
    ac.begin_default_admin_transfer(@0x0, &clk, scenario.ctx());
    abort 999
}

#[test, expected_failure(abort_code = access_control::EDefaultAdminTransferToSelf)]
fun test_begin_admin_transfer_rejects_self() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    let clk = clock::create_for_testing(scenario.ctx());
    ac.begin_default_admin_transfer(deployer, &clk, scenario.ctx());
    abort 999
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

    let cancelled = event::events_by_type<
        access_control::DefaultAdminTransferCancelled<ACCESS_CONTROL_TESTS>,
    >();
    assert_eq!(cancelled.length(), 1);
    let expected = access_control::test_new_default_admin_transfer_cancelled<
        ACCESS_CONTROL_TESTS,
    >();
    assert_eq!(cancelled[0], expected);
    assert_eq!(
        event::events_by_type<
            access_control::DefaultAdminRenounceCancelled<ACCESS_CONTROL_TESTS>,
        >().length(),
        0,
    );

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
    let granted_before = event::events_by_type<
        access_control::RoleGranted<ACCESS_CONTROL_TESTS>,
    >().length();
    let revoked_before = event::events_by_type<
        access_control::RoleRevoked<ACCESS_CONTROL_TESTS>,
    >().length();
    ac.accept_default_admin_transfer(&clk, scenario.ctx());

    // Atomic rotation: old admin lost root, new admin gained it.
    assert!(!ac.has_role<_, ACCESS_CONTROL_TESTS>(deployer));
    assert!(ac.has_role<_, ACCESS_CONTROL_TESTS>(new_admin));
    assert_eq!(ac.default_admin(), option::some(new_admin));
    let auth = ac.new_auth<_, ACCESS_CONTROL_TESTS>(scenario.ctx());
    assert_eq!(access_control::auth_addr(&auth), new_admin);
    // Pending state cleared.
    assert!(!ac.has_pending_default_admin_transfer());
    assert!(ac.pending_default_admin_new_admin().is_none());
    assert!(ac.pending_default_admin_execute_after_ms().is_none());
    // Both events emitted in this transaction.
    assert_eq!(
        event::events_by_type<access_control::RoleGranted<ACCESS_CONTROL_TESTS>>().length(),
        granted_before + 1,
    );
    assert_eq!(
        event::events_by_type<access_control::RoleRevoked<ACCESS_CONTROL_TESTS>>().length(),
        revoked_before + 1,
    );

    // Field-level event payload assertions for the atomic rotation: the pair
    // of events (revoke-old, grant-new) must each carry the right role
    // TypeName and account address.
    let granted = event::events_by_type<access_control::RoleGranted<ACCESS_CONTROL_TESTS>>();
    let last_granted = granted[granted.length() - 1];
    assert_eq!(
        last_granted,
        access_control::test_new_role_granted<ACCESS_CONTROL_TESTS>(
            with_original_ids<ACCESS_CONTROL_TESTS>(),
            new_admin,
        ),
    );
    let revoked = event::events_by_type<access_control::RoleRevoked<ACCESS_CONTROL_TESTS>>();
    let last_revoked = revoked[revoked.length() - 1];
    assert_eq!(
        last_revoked,
        access_control::test_new_role_revoked<ACCESS_CONTROL_TESTS>(
            with_original_ids<ACCESS_CONTROL_TESTS>(),
            deployer,
        ),
    );

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_transferred_admin_can_manage_root_role_administered_roles() {
    let deployer = @0xA;
    let new_admin = @0xB;
    let user = @0xC;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    let clk = clock::create_for_testing(scenario.ctx());

    ac.begin_default_admin_transfer(new_admin, &clk, scenario.ctx());
    test_scenario::return_shared(ac);

    scenario.next_tx(new_admin);
    let mut ac = take_ac(&scenario);
    ac.accept_default_admin_transfer(&clk, scenario.ctx());
    ac.grant_role<_, AdminA>(user, scenario.ctx());

    assert!(ac.has_role<_, AdminA>(user));
    assert_eq!(ac.get_role_admin<_, AdminA>(), with_original_ids<ACCESS_CONTROL_TESTS>());

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test, expected_failure(abort_code = access_control::EUnauthorized)]
fun test_old_admin_cannot_manage_root_role_administered_roles_after_transfer() {
    let deployer = @0xA;
    let new_admin = @0xB;
    let user = @0xC;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    let clk = clock::create_for_testing(scenario.ctx());

    ac.begin_default_admin_transfer(new_admin, &clk, scenario.ctx());
    test_scenario::return_shared(ac);

    scenario.next_tx(new_admin);
    let mut ac = take_ac(&scenario);
    ac.accept_default_admin_transfer(&clk, scenario.ctx());
    test_scenario::return_shared(ac);

    scenario.next_tx(deployer);
    let mut ac = take_ac(&scenario);
    ac.grant_role<_, AdminA>(user, scenario.ctx());
    abort 999
}

#[test, expected_failure(abort_code = access_control::ENoPendingAdminTransfer)]
fun test_accept_admin_transfer_rejects_no_pending() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    let clk = clock::create_for_testing(scenario.ctx());
    ac.accept_default_admin_transfer(&clk, scenario.ctx());
    abort 999
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
    abort 999
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
    abort 999
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
    assert_eq!(ac.default_admin(), option::some(deployer));
    let cancelled = event::events_by_type<
        access_control::DefaultAdminTransferCancelled<ACCESS_CONTROL_TESTS>,
    >();
    assert_eq!(cancelled.length(), 1);
    let expected = access_control::test_new_default_admin_transfer_cancelled<
        ACCESS_CONTROL_TESTS,
    >();
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
    abort 999
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
    abort 999
}

// `cancel_default_admin_transfer` clears either kind of pending action and
// emits the cancellation event matching the pending action kind.
#[test]
fun test_cancel_admin_transfer_clears_pending_renounce() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    let clk = clock::create_for_testing(scenario.ctx());
    ac.begin_default_admin_renounce(&clk, scenario.ctx());

    ac.cancel_default_admin_transfer(scenario.ctx());

    assert!(!ac.has_pending_default_admin_transfer());
    assert!(!ac.is_pending_default_admin_renounce());
    let cancelled = event::events_by_type<
        access_control::DefaultAdminRenounceCancelled<ACCESS_CONTROL_TESTS>,
    >();
    assert_eq!(cancelled.length(), 1);
    let expected = access_control::test_new_default_admin_renounce_cancelled<
        ACCESS_CONTROL_TESTS,
    >();
    assert_eq!(cancelled[0], expected);
    assert_eq!(
        event::events_by_type<
            access_control::DefaultAdminTransferCancelled<ACCESS_CONTROL_TESTS>,
        >().length(),
        0,
    );

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

// State-consistency follow-up to `test_cancel_admin_transfer_happy_path`. After
// cancel, the pending slot must be fully cleared (not in any half-state) such
// that a subsequent `begin_default_admin_transfer` succeeds and produces the
// expected pending state. Without this test, a future regression where cancel
// leaves residual state would only surface much later via the accept path.
#[test]
fun test_cancel_admin_transfer_allows_fresh_begin() {
    let deployer = @0xA;
    let new_admin = @0xB;
    let other_admin = @0xC;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);

    // Begin then cancel.
    ac.begin_default_admin_transfer(new_admin, &clk, scenario.ctx());
    ac.cancel_default_admin_transfer(scenario.ctx());

    // After cancel, a fresh begin works. Advancing the clock differentiates
    // execute_after_ms so we can assert the new pending value end-to-end.
    clk.set_for_testing(50);
    ac.begin_default_admin_transfer(other_admin, &clk, scenario.ctx());

    assert!(ac.has_pending_default_admin_transfer());
    assert_eq!(ac.pending_default_admin_new_admin(), option::some(other_admin));
    assert_eq!(ac.pending_default_admin_execute_after_ms(), option::some(50));

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

// === Pending-transfer getters with no pending ===

#[test]
fun test_pending_getters_when_no_pending() {
    let deployer = @0xA;
    let scenario = setup(deployer, 0);
    let ac = take_ac(&scenario);
    assert!(!ac.has_pending_default_admin_transfer());
    assert!(!ac.is_pending_default_admin_renounce());
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

// Companion to `test_role_hierarchy_chain`: pins that `set_role_admin`
// *transfers* grant authority rather than duplicating it. After RoleX's admin
// is shifted to AdminA, the deployer - who still holds root but not AdminA -
// must no longer be able to grant RoleX. Without this negative assertion, a
// regression where the previous admin retained grant power would slip past the
// happy-path test.
#[test, expected_failure(abort_code = access_control::EUnauthorized)]
fun test_role_hierarchy_chain_root_loses_grant_authority() {
    let deployer = @0xA;
    let admin_a = @0xB;
    let user = @0xC;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);

    // Same setup as the happy path: route RoleX's admin to AdminA.
    ac.grant_role<_, AdminA>(admin_a, scenario.ctx());
    ac.set_role_admin<_, RoleX, AdminA>(scenario.ctx());

    // Deployer still has root, but root is not RoleX's admin anymore.
    ac.grant_role<_, RoleX>(user, scenario.ctx());
    abort 999
}

// === begin_default_admin_renounce ===

#[test]
fun test_begin_admin_renounce_happy_path() {
    let deployer = @0xA;
    let delay = 1000;
    let mut scenario = setup(deployer, delay);
    let mut ac = take_ac(&scenario);

    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    ac.begin_default_admin_renounce(&clk, scenario.ctx());

    assert!(ac.has_pending_default_admin_transfer());
    assert!(ac.is_pending_default_admin_renounce());
    assert_eq!(ac.default_admin(), option::some(deployer));
    // Renounce has no incoming admin - `pending_default_admin_new_admin`
    // returns `none` for both "no pending" and "pending renounce". Use
    // `is_pending_default_admin_renounce` to disambiguate (above).
    assert!(ac.pending_default_admin_new_admin().is_none());
    assert_eq!(ac.pending_default_admin_execute_after_ms(), option::some(delay));

    let scheduled = event::events_by_type<
        access_control::DefaultAdminRenounceScheduled<ACCESS_CONTROL_TESTS>,
    >();
    assert_eq!(scheduled.length(), 1);
    let expected = access_control::test_new_default_admin_renounce_scheduled<ACCESS_CONTROL_TESTS>(
        delay,
    );
    assert_eq!(scheduled[0], expected);

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test, expected_failure(abort_code = access_control::EUnauthorized)]
fun test_renounced_admin_cannot_manage_root_role_administered_roles() {
    let deployer = @0xA;
    let user = @0xB;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    let clk = clock::create_for_testing(scenario.ctx());

    ac.begin_default_admin_renounce(&clk, scenario.ctx());
    ac.accept_default_admin_renounce(&clk, scenario.ctx());
    ac.grant_role<_, AdminA>(user, scenario.ctx());
    abort 999
}

#[test, expected_failure(abort_code = access_control::EUnauthorized)]
fun test_begin_admin_renounce_rejects_non_root() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    scenario.next_tx(@0xB);
    let mut ac = take_ac(&scenario);
    let clk = clock::create_for_testing(scenario.ctx());
    ac.begin_default_admin_renounce(&clk, scenario.ctx());
    abort 999
}

// Scheduling a renounce cancels and overwrites an existing pending transfer
// (and vice versa). The two are mutually exclusive - they share
// `pending_default_admin`.
#[test]
fun test_begin_admin_renounce_overwrites_pending_transfer() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);

    ac.begin_default_admin_transfer(@0xB, &clk, scenario.ctx());
    assert!(!ac.is_pending_default_admin_renounce());

    clk.set_for_testing(50);
    ac.begin_default_admin_renounce(&clk, scenario.ctx());
    assert!(ac.is_pending_default_admin_renounce());
    assert_eq!(ac.pending_default_admin_execute_after_ms(), option::some(50));

    let cancelled = event::events_by_type<
        access_control::DefaultAdminTransferCancelled<ACCESS_CONTROL_TESTS>,
    >();
    assert_eq!(cancelled.length(), 1);
    assert_eq!(
        event::events_by_type<
            access_control::DefaultAdminRenounceCancelled<ACCESS_CONTROL_TESTS>,
        >().length(),
        0,
    );

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_begin_admin_transfer_overwrites_pending_renounce() {
    let deployer = @0xA;
    let new_admin = @0xB;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);

    ac.begin_default_admin_renounce(&clk, scenario.ctx());
    assert!(ac.is_pending_default_admin_renounce());

    clk.set_for_testing(50);
    ac.begin_default_admin_transfer(new_admin, &clk, scenario.ctx());
    assert!(!ac.is_pending_default_admin_renounce());
    assert_eq!(ac.pending_default_admin_new_admin(), option::some(new_admin));

    let cancelled = event::events_by_type<
        access_control::DefaultAdminRenounceCancelled<ACCESS_CONTROL_TESTS>,
    >();
    assert_eq!(cancelled.length(), 1);
    assert_eq!(
        event::events_by_type<
            access_control::DefaultAdminTransferCancelled<ACCESS_CONTROL_TESTS>,
        >().length(),
        0,
    );

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

// Symmetric to the transfer-overwrites-transfer and the cross-kind tests
// above: a second `begin_default_admin_renounce` cancels and overwrites the
// first, re-anchoring `execute_after_ms` to the new clock.
#[test]
fun test_begin_admin_renounce_overwrites_pending_renounce() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);

    ac.begin_default_admin_renounce(&clk, scenario.ctx());
    assert!(ac.is_pending_default_admin_renounce());

    clk.set_for_testing(50);
    ac.begin_default_admin_renounce(&clk, scenario.ctx());

    assert!(ac.is_pending_default_admin_renounce());
    assert_eq!(ac.pending_default_admin_execute_after_ms(), option::some(50));

    let cancelled = event::events_by_type<
        access_control::DefaultAdminRenounceCancelled<ACCESS_CONTROL_TESTS>,
    >();
    assert_eq!(cancelled.length(), 1);
    assert_eq!(
        event::events_by_type<
            access_control::DefaultAdminTransferCancelled<ACCESS_CONTROL_TESTS>,
        >().length(),
        0,
    );

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

// === accept_default_admin_renounce ===

#[test]
fun test_accept_admin_renounce_happy_path() {
    let deployer = @0xA;
    let delay = 100;
    let mut scenario = setup(deployer, delay);
    let mut ac = take_ac(&scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    ac.begin_default_admin_renounce(&clk, scenario.ctx());

    clk.set_for_testing(delay);
    let revoked_before = event::events_by_type<
        access_control::RoleRevoked<ACCESS_CONTROL_TESTS>,
    >().length();
    let granted_before = event::events_by_type<
        access_control::RoleGranted<ACCESS_CONTROL_TESTS>,
    >().length();
    ac.accept_default_admin_renounce(&clk, scenario.ctx());

    // Caller (current default admin) is removed from the root role; pending cleared.
    assert!(!ac.has_role<_, ACCESS_CONTROL_TESTS>(deployer));
    assert!(ac.default_admin().is_none());
    assert!(!ac.has_pending_default_admin_transfer());
    assert!(!ac.is_pending_default_admin_renounce());

    // Exactly one RoleRevoked and zero RoleGranted (no incoming admin).
    assert_eq!(
        event::events_by_type<access_control::RoleRevoked<ACCESS_CONTROL_TESTS>>().length(),
        revoked_before + 1,
    );
    assert_eq!(
        event::events_by_type<access_control::RoleGranted<ACCESS_CONTROL_TESTS>>().length(),
        granted_before,
    );

    let revoked = event::events_by_type<access_control::RoleRevoked<ACCESS_CONTROL_TESTS>>();
    let last = revoked[revoked.length() - 1];
    assert_eq!(
        last,
        access_control::test_new_role_revoked<ACCESS_CONTROL_TESTS>(
            with_original_ids<ACCESS_CONTROL_TESTS>(),
            deployer,
        ),
    );

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test, expected_failure(abort_code = access_control::ENoPendingAdminTransfer)]
fun test_accept_admin_renounce_rejects_no_pending() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    let clk = clock::create_for_testing(scenario.ctx());
    ac.accept_default_admin_renounce(&clk, scenario.ctx());
    abort 999
}

// `accept_default_admin_renounce` rejects when the pending action is a
// transfer (not a renounce) - the caller must use the matching accept path.
#[test, expected_failure(abort_code = access_control::ENotPendingRenounce)]
fun test_accept_admin_renounce_rejects_pending_transfer() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    let clk = clock::create_for_testing(scenario.ctx());
    ac.begin_default_admin_transfer(@0xB, &clk, scenario.ctx());
    ac.accept_default_admin_renounce(&clk, scenario.ctx());
    abort 999
}

// `accept_default_admin_transfer` rejects when the pending action is a
// renounce (not a transfer) - symmetric with the above.
#[test, expected_failure(abort_code = access_control::ENotPendingTransfer)]
fun test_accept_admin_transfer_rejects_pending_renounce() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    let clk = clock::create_for_testing(scenario.ctx());
    ac.begin_default_admin_renounce(&clk, scenario.ctx());
    ac.accept_default_admin_transfer(&clk, scenario.ctx());
    abort 999
}

#[test, expected_failure(abort_code = access_control::EUnauthorized)]
fun test_accept_admin_renounce_rejects_non_root() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    let clk = clock::create_for_testing(scenario.ctx());
    ac.begin_default_admin_renounce(&clk, scenario.ctx());
    test_scenario::return_shared(ac);

    // A non-root caller cannot complete the renounce.
    scenario.next_tx(@0xB);
    let mut ac = take_ac(&scenario);
    ac.accept_default_admin_renounce(&clk, scenario.ctx());
    abort 999
}

#[test, expected_failure(abort_code = access_control::EDelayNotElapsed)]
fun test_accept_admin_renounce_rejects_too_early() {
    let deployer = @0xA;
    let delay = 100;
    let mut scenario = setup(deployer, delay);
    let mut ac = take_ac(&scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    ac.begin_default_admin_renounce(&clk, scenario.ctx());
    clk.set_for_testing(delay - 1);
    ac.accept_default_admin_renounce(&clk, scenario.ctx());
    abort 999
}

#[test]
fun test_accept_admin_renounce_at_exact_delay() {
    let deployer = @0xA;
    let delay = 50;
    let mut scenario = setup(deployer, delay);
    let mut ac = take_ac(&scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    ac.begin_default_admin_renounce(&clk, scenario.ctx());
    clk.set_for_testing(delay);
    ac.accept_default_admin_renounce(&clk, scenario.ctx());
    assert!(!ac.has_role<_, ACCESS_CONTROL_TESTS>(deployer));
    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

// === begin_default_admin_delay_change ===

#[test]
fun test_begin_delay_change_increase_below_cap() {
    // current = 1 hour, new = 2 hours. New is below the 48h cap, so wait
    // formula yields min(2h, 48h) = 2h.
    let deployer = @0xA;
    let one_hour: u64 = 60 * 60 * 1_000;
    let two_hours: u64 = 2 * one_hour;
    let mut scenario = setup(deployer, one_hour);
    let mut ac = take_ac(&scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    ac.begin_default_admin_delay_change(two_hours, &clk, scenario.ctx());

    assert!(ac.has_pending_default_admin_delay_change(&clk));
    assert_eq!(ac.pending_default_admin_delay_change_new_delay_ms(&clk), option::some(two_hours));
    assert_eq!(
        ac.pending_default_admin_delay_change_schedule_after_ms(&clk),
        option::some(two_hours),
    );

    let scheduled = event::events_by_type<
        access_control::DefaultAdminDelayChangeScheduled<ACCESS_CONTROL_TESTS>,
    >();
    assert_eq!(scheduled.length(), 1);
    let expected = access_control::test_new_default_admin_delay_change_scheduled<
        ACCESS_CONTROL_TESTS,
    >(
        two_hours,
        two_hours,
    );
    assert_eq!(scheduled[0], expected);

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_begin_delay_change_increase_above_cap() {
    // current = 1 hour, new = 30 days. New is well above the 48h cap, so
    // wait = min(30d, 48h) = 48h. The cap protects against having to wait
    // an unreasonably long time before a large increase takes effect.
    let deployer = @0xA;
    let one_hour: u64 = 60 * 60 * 1_000;
    let thirty_days: u64 = 30 * 24 * one_hour;
    let cap: u64 = access_control::max_delay_increase_wait_ms();
    let mut scenario = setup(deployer, one_hour);
    let mut ac = take_ac(&scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    ac.begin_default_admin_delay_change(thirty_days, &clk, scenario.ctx());

    assert_eq!(ac.pending_default_admin_delay_change_new_delay_ms(&clk), option::some(thirty_days));
    assert_eq!(ac.pending_default_admin_delay_change_schedule_after_ms(&clk), option::some(cap));

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_begin_delay_change_increase_at_cap_boundary() {
    // current = 1ms, new = exactly the cap. Boundary: new_delay_ms is *not*
    // strictly less than the cap, so the formula picks the cap branch.
    // Both branches yield the same value at the boundary, but exercising it
    // pins the comparison's strictness.
    let deployer = @0xA;
    let cap: u64 = access_control::max_delay_increase_wait_ms();
    let mut scenario = setup(deployer, 1);
    let mut ac = take_ac(&scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    ac.begin_default_admin_delay_change(cap, &clk, scenario.ctx());
    assert_eq!(ac.pending_default_admin_delay_change_schedule_after_ms(&clk), option::some(cap));
    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_begin_delay_change_decrease() {
    // current = 7 days, new = 1 day. Wait = freed time = 7d - 1d = 6 days.
    // The freed-time formula keeps the security promise of the current delay:
    // the admin commits to the change for 6 days before they can schedule
    // new transfers under the shorter delay.
    let deployer = @0xA;
    let one_day: u64 = 24 * 60 * 60 * 1_000;
    let seven_days: u64 = 7 * one_day;
    let mut scenario = setup(deployer, seven_days);
    let mut ac = take_ac(&scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    ac.begin_default_admin_delay_change(one_day, &clk, scenario.ctx());

    assert_eq!(
        ac.pending_default_admin_delay_change_schedule_after_ms(&clk),
        option::some(seven_days - one_day),
    );

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_begin_delay_change_no_change() {
    // current == new: wait = 0. Schedule applies immediately.
    let deployer = @0xA;
    let one_hour: u64 = 60 * 60 * 1_000;
    let mut scenario = setup(deployer, one_hour);
    let mut ac = take_ac(&scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(123);
    ac.begin_default_admin_delay_change(one_hour, &clk, scenario.ctx());
    assert!(!ac.has_pending_default_admin_delay_change(&clk));
    assert!(ac.pending_default_admin_delay_change_new_delay_ms(&clk).is_none());
    assert!(ac.pending_default_admin_delay_change_schedule_after_ms(&clk).is_none());
    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test, expected_failure(abort_code = access_control::EUnauthorized)]
fun test_begin_delay_change_rejects_non_root() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    scenario.next_tx(@0xB);
    let mut ac = take_ac(&scenario);
    let clk = clock::create_for_testing(scenario.ctx());
    ac.begin_default_admin_delay_change(100, &clk, scenario.ctx());
    abort 999
}

#[test, expected_failure(abort_code = access_control::EDelayTooLarge)]
fun test_begin_delay_change_rejects_above_max() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    let clk = clock::create_for_testing(scenario.ctx());
    ac.begin_default_admin_delay_change(
        access_control::max_default_admin_delay_ms() + 1,
        &clk,
        scenario.ctx(),
    );
    abort 999
}

#[test]
fun test_begin_delay_change_at_max_boundary() {
    let deployer = @0xA;
    let max = access_control::max_default_admin_delay_ms();
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    ac.begin_default_admin_delay_change(max, &clk, scenario.ctx());
    assert_eq!(ac.pending_default_admin_delay_change_new_delay_ms(&clk), option::some(max));
    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_begin_delay_change_overwrites_pending() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    ac.begin_default_admin_delay_change(100, &clk, scenario.ctx());

    clk.set_for_testing(50);
    ac.begin_default_admin_delay_change(200, &clk, scenario.ctx());

    assert_eq!(ac.pending_default_admin_delay_change_new_delay_ms(&clk), option::some(200));
    assert_eq!(
        ac.pending_default_admin_delay_change_schedule_after_ms(&clk),
        option::some(50 + 200),
    );

    let cancelled = event::events_by_type<
        access_control::DefaultAdminDelayChangeCancelled<ACCESS_CONTROL_TESTS>,
    >();
    assert_eq!(cancelled.length(), 1);
    let expected = access_control::test_new_default_admin_delay_change_cancelled<
        ACCESS_CONTROL_TESTS,
    >();
    assert_eq!(cancelled[0], expected);

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

// === automatic default admin delay application ===

#[test]
fun test_default_admin_delay_ms_returns_elapsed_pending_delay() {
    let deployer = @0xA;
    let one_hour: u64 = 60 * 60 * 1_000;
    let two_hours: u64 = 2 * one_hour;
    let mut scenario = setup(deployer, one_hour);
    let mut ac = take_ac(&scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    ac.begin_default_admin_delay_change(two_hours, &clk, scenario.ctx());

    clk.set_for_testing(two_hours - 1);
    assert_eq!(ac.default_admin_delay_ms(&clk), one_hour);

    clk.set_for_testing(two_hours);
    assert_eq!(ac.default_admin_delay_ms(&clk), two_hours);
    assert!(!ac.has_pending_default_admin_delay_change(&clk));
    assert!(ac.pending_default_admin_delay_change_new_delay_ms(&clk).is_none());
    assert!(ac.pending_default_admin_delay_change_schedule_after_ms(&clk).is_none());

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_elapsed_delay_change_applies_to_new_transfer() {
    let deployer = @0xA;
    let new_admin = @0xB;
    let one_hour: u64 = 60 * 60 * 1_000;
    let two_hours: u64 = 2 * one_hour;
    let mut scenario = setup(deployer, one_hour);
    let mut ac = take_ac(&scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    ac.begin_default_admin_delay_change(two_hours, &clk, scenario.ctx());

    let now = two_hours;
    clk.set_for_testing(now);
    ac.begin_default_admin_transfer(new_admin, &clk, scenario.ctx());

    assert_eq!(ac.pending_default_admin_execute_after_ms(), option::some(now + two_hours));
    assert_eq!(ac.default_admin_delay_ms(&clk), two_hours);
    assert!(!ac.has_pending_default_admin_delay_change(&clk));

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_elapsed_delay_change_applies_to_new_renounce() {
    let deployer = @0xA;
    let one_hour: u64 = 60 * 60 * 1_000;
    let two_hours: u64 = 2 * one_hour;
    let mut scenario = setup(deployer, one_hour);
    let mut ac = take_ac(&scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    ac.begin_default_admin_delay_change(two_hours, &clk, scenario.ctx());

    let now = two_hours;
    clk.set_for_testing(now);
    ac.begin_default_admin_renounce(&clk, scenario.ctx());

    assert_eq!(ac.pending_default_admin_execute_after_ms(), option::some(now + two_hours));
    assert_eq!(ac.default_admin_delay_ms(&clk), two_hours);
    assert!(!ac.has_pending_default_admin_delay_change(&clk));

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_unelapsed_delay_change_does_not_apply_to_new_transfer() {
    let deployer = @0xA;
    let new_admin = @0xB;
    let one_hour: u64 = 60 * 60 * 1_000;
    let two_hours: u64 = 2 * one_hour;
    let mut scenario = setup(deployer, one_hour);
    let mut ac = take_ac(&scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    ac.begin_default_admin_delay_change(two_hours, &clk, scenario.ctx());

    let now = two_hours - 1;
    clk.set_for_testing(now);
    ac.begin_default_admin_transfer(new_admin, &clk, scenario.ctx());

    assert_eq!(ac.pending_default_admin_execute_after_ms(), option::some(now + one_hour));
    assert_eq!(ac.default_admin_delay_ms(&clk), one_hour);
    assert!(ac.has_pending_default_admin_delay_change(&clk));

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

// === cancel_default_admin_delay_change ===

#[test]
fun test_cancel_delay_change_happy_path() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    let clk = clock::create_for_testing(scenario.ctx());
    ac.begin_default_admin_delay_change(100, &clk, scenario.ctx());

    ac.cancel_default_admin_delay_change(&clk, scenario.ctx());

    assert!(!ac.has_pending_default_admin_delay_change(&clk));
    let cancelled = event::events_by_type<
        access_control::DefaultAdminDelayChangeCancelled<ACCESS_CONTROL_TESTS>,
    >();
    assert_eq!(cancelled.length(), 1);
    let expected = access_control::test_new_default_admin_delay_change_cancelled<
        ACCESS_CONTROL_TESTS,
    >();
    assert_eq!(cancelled[0], expected);

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test, expected_failure(abort_code = access_control::ENoPendingDelayChange)]
fun test_cancel_delay_change_rejects_no_pending() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    let clk = clock::create_for_testing(scenario.ctx());
    ac.cancel_default_admin_delay_change(&clk, scenario.ctx());
    abort 999
}

#[test, expected_failure(abort_code = access_control::EUnauthorized)]
fun test_cancel_delay_change_rejects_non_root() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let mut ac = take_ac(&scenario);
    let clk = clock::create_for_testing(scenario.ctx());
    ac.begin_default_admin_delay_change(100, &clk, scenario.ctx());
    test_scenario::return_shared(ac);

    scenario.next_tx(@0xB);
    let mut ac = take_ac(&scenario);
    ac.cancel_default_admin_delay_change(&clk, scenario.ctx());
    clock::destroy_for_testing(clk);
    abort 999
}

#[test, expected_failure(abort_code = access_control::ENoPendingDelayChange)]
fun test_cancel_delay_change_rejects_elapsed_pending() {
    let deployer = @0xA;
    let one_hour: u64 = 60 * 60 * 1_000;
    let two_hours: u64 = 2 * one_hour;
    let mut scenario = setup(deployer, one_hour);
    let mut ac = take_ac(&scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    ac.begin_default_admin_delay_change(two_hours, &clk, scenario.ctx());

    clk.set_for_testing(two_hours);
    ac.cancel_default_admin_delay_change(&clk, scenario.ctx());
    abort 999
}

// === Pending getters: delay change ===

#[test]
fun test_delay_change_getters_when_no_pending() {
    let deployer = @0xA;
    let mut scenario = setup(deployer, 0);
    let ac = take_ac(&scenario);
    let clk = clock::create_for_testing(scenario.ctx());
    assert!(!ac.has_pending_default_admin_delay_change(&clk));
    assert!(ac.pending_default_admin_delay_change_new_delay_ms(&clk).is_none());
    assert!(ac.pending_default_admin_delay_change_schedule_after_ms(&clk).is_none());
    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

// === In-flight noninterference ===

// A pending admin transfer was scheduled under the old delay. A delay change
// then becomes effective. The pending transfer's `execute_after_ms` must not
// change - in-flight transfers honor the delay they were scheduled under,
// regardless of subsequent delay changes.
#[test]
fun test_delay_change_does_not_affect_pending_transfer() {
    let deployer = @0xA;
    let new_admin = @0xB;
    let one_hour: u64 = 60 * 60 * 1_000;
    let mut scenario = setup(deployer, one_hour);
    let mut ac = take_ac(&scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);

    // Schedule a transfer at delay = 1h. execute_after_ms = 0 + 1h.
    ac.begin_default_admin_transfer(new_admin, &clk, scenario.ctx());
    let pending_execute_at = ac.pending_default_admin_execute_after_ms();
    assert_eq!(pending_execute_at, option::some(one_hour));

    // Schedule a delay decrease to a much smaller value, then let it elapse.
    ac.begin_default_admin_delay_change(1, &clk, scenario.ctx());
    clk.set_for_testing(one_hour); // past the freed-time wait

    // Effective delay updated...
    assert_eq!(ac.default_admin_delay_ms(&clk), 1);
    // ...but the in-flight transfer's execute_after_ms is unchanged.
    assert_eq!(ac.pending_default_admin_execute_after_ms(), pending_execute_at);

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

#[test]
fun test_begin_delay_change_applies_elapsed_pending_before_new_schedule() {
    let deployer = @0xA;
    let one_hour: u64 = 60 * 60 * 1_000;
    let two_hours: u64 = 2 * one_hour;
    let three_hours: u64 = 3 * one_hour;
    let mut scenario = setup(deployer, one_hour);
    let mut ac = take_ac(&scenario);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(0);
    ac.begin_default_admin_delay_change(two_hours, &clk, scenario.ctx());

    // The first change has elapsed. Scheduling a decrease from 2h to 1h must
    // use the 2h effective delay as the current value, so wait = 1h.
    clk.set_for_testing(two_hours);
    let cancelled_before = event::events_by_type<
        access_control::DefaultAdminDelayChangeCancelled<ACCESS_CONTROL_TESTS>,
    >().length();
    ac.begin_default_admin_delay_change(one_hour, &clk, scenario.ctx());

    assert_eq!(ac.default_admin_delay_ms(&clk), two_hours);
    assert_eq!(ac.pending_default_admin_delay_change_new_delay_ms(&clk), option::some(one_hour));
    assert_eq!(
        ac.pending_default_admin_delay_change_schedule_after_ms(&clk),
        option::some(three_hours),
    );
    assert_eq!(
        event::events_by_type<
            access_control::DefaultAdminDelayChangeCancelled<ACCESS_CONTROL_TESTS>,
        >().length(),
        cancelled_before,
    );

    clock::destroy_for_testing(clk);
    test_scenario::return_shared(ac);
    scenario.end();
}

/// Role-based access control for Sui Move protocols.
///
/// ### Structural invariants
///
/// 1. **One AccessControl per module per publish.** `new<RootRole>` only accepts
///    a One-Time Witness as `RootRole`. The Sui VM produces exactly one OTW
///    value of a given type per package publish (passed into the consumer
///    module's `init`), so a module can stand up at most one registry of its
///    own type, ever.
///
/// 2. **Only home-module roles.** Every write path (`grant_role`, `revoke_role`,
///    `renounce_role`, `set_role_admin`, `new_auth`) checks that the role
///    type's home module matches the root role's home module. Foreign role
///    types are rejected at the boundary; they cannot be introduced into the
///    bag. The check uses `type_name::with_original_ids`, which compares the
///    package's *original* publish address — so role types introduced in
///    later upgrades of the same package pass the check too. The home-module
///    rule restricts roles to the same package, not to the same package
///    version.
///
/// Together these guarantees make `Auth<R>` a self-validating capability.
/// `R` can only live in the registry of its home module, that registry is
/// unique per publish, and the only path to mint `Auth<R>` is `new_auth`
/// against that registry. Action functions can take `&Auth<R>` directly with
/// no body checks.
///
/// ### Idiomatic usage
///
/// ```move
/// module my_protocol::my_protocol;
///
/// public struct MY_PROTOCOL has drop {}    // OTW; serves as the root role
/// public struct AdminRole {}               // additional role, same module
/// public struct OperatorRole {}            // additional role, same module
///
/// fun init(otw: MY_PROTOCOL, ctx: &mut TxContext) {
///     let mut registry = access_control::new(otw, 86_400_000, ctx);
///     access_control::grant_role<_, AdminRole>(
///         &mut registry, ctx.sender(), ctx,
///     );
///     access_control::set_role_admin<_, OperatorRole, AdminRole>(
///         &mut registry, ctx,
///     );
///     transfer::public_share_object(registry);
/// }
/// ```
module openzeppelin_access::access_control;

use std::type_name::{TypeName, with_original_ids};
use sui::bag::{Self, Bag};
use sui::clock::Clock;
use sui::event;
use sui::types;
use sui::vec_set::{Self, VecSet};

// === Errors ===

/// Caller does not hold the required role.
#[error(code = 0)]
const EUnauthorized: vector<u8> = "Caller does not have the required role";

/// A write operation was attempted on the protected root role.
#[error(code = 1)]
const ECannotManageRootRole: vector<u8> =
    "Use begin_default_admin_transfer to change the root role holder";

/// `accept_default_admin_transfer` or `cancel_default_admin_transfer` called
/// with no pending transfer.
#[error(code = 2)]
const ENoPendingAdminTransfer: vector<u8> = "No pending default admin transfer";

/// `accept_default_admin_transfer` called by an address other than the pending
/// new admin.
#[error(code = 3)]
const ENotPendingAdmin: vector<u8> = "Caller is not the pending admin";

/// `accept_default_admin_transfer` called before the configured delay has
/// elapsed.
#[error(code = 4)]
const EDelayNotElapsed: vector<u8> = "Admin transfer delay has not elapsed";

/// `renounce_role` called with `account != ctx.sender()`.
#[error(code = 5)]
const ECannotRenounceForOtherAccount: vector<u8> = "Can only renounce role for own account";

/// `new` called with `default_admin_delay_ms` above `MAX_DEFAULT_ADMIN_DELAY_MS`.
#[error(code = 6)]
const EDelayTooLarge: vector<u8> = "Admin delay exceeds the maximum allowed value";

/// `new` called with a value that is not a genuine One-Time Witness.
#[error(code = 7)]
const ENotOneTimeWitness: vector<u8> = "Root role must be a One-Time Witness";

/// A role type from a module other than the root role's home module was used
/// in a write path.
#[error(code = 8)]
const EForeignRole: vector<u8> = "Role type must be defined in the same module as the root role";

// === Constants ===

/// Maximum value for `default_admin_delay_ms` passed to `new()`.
/// Value: 30 days in milliseconds.
const MAX_DEFAULT_ADMIN_DELAY_MS: u64 = 30 * 24 * 60 * 60 * 1_000;

// === Structs ===

/// Self-validating typed proof of role membership.
///
/// `Auth<R>` is minted exclusively by `new_auth` against the unique
/// `AccessControl<RootRole>` whose home module matches `R`'s. Because that
/// registry is singleton-per-publish (Invariant 1) and only home-module roles
/// can ever be registered in it (Invariant 2), every `Auth<R>` that exists was
/// produced by that one registry, against a sender that genuinely held `R`.
/// Consumers can take `&Auth<R>` as authorization without any body checks.
public struct Auth<phantom R> has drop {
    addr: address,
}

/// Central access control registry.
///
/// `RootRole` is the consuming module's One-Time Witness. The phantom parameter
/// pins the registry's identity at the type level so the same-module check in
/// every write path can reject foreign role types statically attached to this
/// registry.
public struct AccessControl<phantom RootRole> has key, store {
    id: UID,
    /// Per-role membership and admin mapping. Keyed by `TypeName`.
    /// Entries are created lazily on first grant or `set_role_admin`.
    roles: Bag,
    /// `TypeName` of the root role (= `RootRole`'s OTW). Direct grant/revoke
    /// on this role is blocked; use the timelocked transfer flow.
    protected_root: TypeName,
    /// Pending root role transfer.
    pending_default_admin: Option<PendingAdminTransfer>,
    /// Minimum delay (ms) for root role transfer. Set at creation; immutable.
    default_admin_delay_ms: u64,
}

/// Per-role state: current members and the role that administers it.
public struct RoleData has store {
    members: VecSet<address>,
    /// Defaults to the root role; changeable via `set_role_admin`.
    admin_role: TypeName,
}

/// Snapshot of a pending root role transfer.
public struct PendingAdminTransfer has drop, store {
    new_admin: address,
    execute_after_ms: u64,
}

// === Events ===
//
// The `role` field on every event is a `TypeName` — it embeds the defining
// package address and module name of the role struct, so events from
// independently-published consumer protocols are distinguishable off-chain.

public struct RoleGranted has copy, drop {
    role: TypeName,
    account: address,
    sender: address,
}

public struct RoleRevoked has copy, drop {
    role: TypeName,
    account: address,
    sender: address,
}

public struct RoleAdminChanged has copy, drop {
    role: TypeName,
    previous_admin_role: TypeName,
    new_admin_role: TypeName,
}

public struct DefaultAdminTransferScheduled has copy, drop {
    new_admin: address,
    execute_after_ms: u64,
}

public struct DefaultAdminTransferCancelled has copy, drop {}

// === Constructor ===

/// Create the singleton `AccessControl` for a module.
///
/// The caller passes their module's One-Time Witness as `otw`. The runtime
/// `is_one_time_witness` check confirms the value is genuine — this is what
/// enforces Invariant 1 (one registry per module per publish). The
/// transaction sender automatically becomes the root role holder.
///
/// The expected call site is the consumer module's `init` function, where
/// the VM has already produced exactly one OTW value.
///
/// #### Aborts
/// - `ENotOneTimeWitness` if `otw` is not a true One-Time Witness.
/// - `EDelayTooLarge` if `default_admin_delay_ms` exceeds `MAX_DEFAULT_ADMIN_DELAY_MS`.
public fun new<RootRole: drop>(
    otw: RootRole,
    default_admin_delay_ms: u64,
    ctx: &mut TxContext,
): AccessControl<RootRole> {
    assert!(types::is_one_time_witness(&otw), ENotOneTimeWitness);
    assert!(default_admin_delay_ms <= MAX_DEFAULT_ADMIN_DELAY_MS, EDelayTooLarge);

    let sender = ctx.sender();
    let root_type = with_original_ids<RootRole>();

    let mut ac = AccessControl<RootRole> {
        id: object::new(ctx),
        roles: bag::new(ctx),
        protected_root: root_type,
        pending_default_admin: option::none(),
        default_admin_delay_ms,
    };

    ac
        .roles
        .add(
            root_type,
            RoleData {
                members: vec_set::singleton(sender),
                // Root role is self-administering.
                admin_role: root_type,
            },
        );

    event::emit(RoleGranted { role: root_type, account: sender, sender });

    ac
}

// === Internal Helpers ===

/// Membership check by `TypeName` — used internally when the admin role is
/// known only as a `TypeName` value, not as a type parameter.
fun has_role_by_name<RootRole>(
    ac: &AccessControl<RootRole>,
    role: TypeName,
    account: address,
): bool {
    if (!ac.roles.contains(role)) return false;
    ac.roles.borrow<_, RoleData>(role).members.contains(&account)
}

/// Returns the admin role `TypeName` of `role`. Defaults to the root role for
/// roles that have no entry yet.
fun get_role_admin_name<RootRole>(ac: &AccessControl<RootRole>, role: TypeName): TypeName {
    if (!ac.roles.contains(role)) return ac.protected_root;
    ac.roles.borrow<_, RoleData>(role).admin_role
}

/// Asserts `R` and `RootRole` come from the same package + module.
///
/// Uses `with_original_ids` so role types introduced in later package
/// upgrades still match — the address compared is the package's original
/// publish ID, which is stable across upgrades. This is the runtime arm
/// of Invariant 2.
fun assert_home_module<RootRole, R>() {
    let root = with_original_ids<RootRole>();
    let role = with_original_ids<R>();
    assert!(
        root.address_string() == role.address_string()
            && root.module_string() == role.module_string(),
        EForeignRole,
    );
}

// === Role Queries ===

/// Returns `true` if `account` is a member of role `R`.
public fun has_role<RootRole, R>(ac: &AccessControl<RootRole>, account: address): bool {
    has_role_by_name(ac, with_original_ids<R>(), account)
}

/// Returns the `TypeName` of the admin role of `R`. Defaults to the root role
/// for roles that have no entry yet.
public fun get_role_admin<RootRole, R>(ac: &AccessControl<RootRole>): TypeName {
    get_role_admin_name(ac, with_original_ids<R>())
}

/// Aborts with `EUnauthorized` if `account` does not hold role `R`.
public fun assert_role<RootRole, R>(ac: &AccessControl<RootRole>, account: address) {
    assert!(has_role<RootRole, R>(ac, account), EUnauthorized);
}

// === Role Management ===

/// Grant role `R` to `account`. Caller must hold the admin role of `R`.
/// `R` must be defined in the same module as `RootRole` (Invariant 2).
/// Blocked on the root role. No-op if `account` already holds `R`.
///
/// #### Aborts
/// - `EForeignRole` if `R`'s home module differs from `RootRole`'s.
/// - `ECannotManageRootRole` if `R` is the root role.
/// - `EUnauthorized` if the caller does not hold the admin role of `R`.
public fun grant_role<RootRole, R>(
    ac: &mut AccessControl<RootRole>,
    account: address,
    ctx: &mut TxContext,
) {
    assert_home_module<RootRole, R>();
    let role_name = with_original_ids<R>();
    assert!(role_name != ac.protected_root, ECannotManageRootRole);
    assert!(has_role_by_name(ac, get_role_admin_name(ac, role_name), ctx.sender()), EUnauthorized);

    if (!ac.roles.contains(role_name)) {
        ac
            .roles
            .add(
                role_name,
                RoleData { members: vec_set::empty(), admin_role: ac.protected_root },
            );
    };

    let role_data = ac.roles.borrow_mut<_, RoleData>(role_name);
    if (role_data.members.contains(&account)) return;

    role_data.members.insert(account);
    event::emit(RoleGranted { role: role_name, account, sender: ctx.sender() });
}

/// Revoke role `R` from `account`. Caller must hold the admin role of `R`.
/// Blocked on the root role. No-op if `account` does not hold `R`.
///
/// #### Aborts
/// - `EForeignRole` if `R`'s home module differs from `RootRole`'s.
/// - `ECannotManageRootRole` if `R` is the root role.
/// - `EUnauthorized` if the caller does not hold the admin role of `R`.
public fun revoke_role<RootRole, R>(
    ac: &mut AccessControl<RootRole>,
    account: address,
    ctx: &mut TxContext,
) {
    assert_home_module<RootRole, R>();
    let role_name = with_original_ids<R>();
    assert!(role_name != ac.protected_root, ECannotManageRootRole);
    assert!(has_role_by_name(ac, get_role_admin_name(ac, role_name), ctx.sender()), EUnauthorized);

    if (!ac.roles.contains(role_name)) return;

    let role_data = ac.roles.borrow_mut<_, RoleData>(role_name);
    if (!role_data.members.contains(&account)) return;

    role_data.members.remove(&account);
    event::emit(RoleRevoked { role: role_name, account, sender: ctx.sender() });
}

/// Voluntarily relinquish role `R`. `account` must equal `ctx.sender()`.
/// Allowed on the root role (with the permanent-lockout warning). No-op if
/// the caller does not hold `R`.
///
/// **Warning:** Renouncing the root role when you are the last holder makes
/// this registry permanently unmanageable.
///
/// #### Aborts
/// - `ECannotRenounceForOtherAccount` if `account != ctx.sender()`.
/// - `EForeignRole` if `R`'s home module differs from `RootRole`'s.
public fun renounce_role<RootRole, R>(
    ac: &mut AccessControl<RootRole>,
    account: address,
    ctx: &mut TxContext,
) {
    assert!(account == ctx.sender(), ECannotRenounceForOtherAccount);
    assert_home_module<RootRole, R>();

    let role_name = with_original_ids<R>();
    if (!ac.roles.contains(role_name)) return;

    let role_data = ac.roles.borrow_mut<_, RoleData>(role_name);
    if (!role_data.members.contains(&account)) return;

    role_data.members.remove(&account);
    event::emit(RoleRevoked { role: role_name, account, sender: ctx.sender() });
}

/// Set the admin role of `Role` to `AdminRole`. Both must be home-module
/// roles. Caller must hold the current admin role of `Role`. Blocked on the
/// root role as the subject.
///
/// #### Aborts
/// - `EForeignRole` if either `Role` or `AdminRole` is foreign.
/// - `ECannotManageRootRole` if `Role` is the root role.
/// - `EUnauthorized` if the caller does not hold the current admin role of `Role`.
public fun set_role_admin<RootRole, Role, AdminRole>(
    ac: &mut AccessControl<RootRole>,
    ctx: &mut TxContext,
) {
    assert_home_module<RootRole, Role>();
    assert_home_module<RootRole, AdminRole>();

    let role_name = with_original_ids<Role>();
    assert!(role_name != ac.protected_root, ECannotManageRootRole);

    let previous_admin_role = get_role_admin_name(ac, role_name);
    assert!(has_role_by_name(ac, previous_admin_role, ctx.sender()), EUnauthorized);

    let new_admin_name = with_original_ids<AdminRole>();

    if (!ac.roles.contains(role_name)) {
        ac
            .roles
            .add(
                role_name,
                RoleData { members: vec_set::empty(), admin_role: new_admin_name },
            );
    } else {
        ac.roles.borrow_mut<_, RoleData>(role_name).admin_role = new_admin_name;
    };

    event::emit(RoleAdminChanged {
        role: role_name,
        previous_admin_role,
        new_admin_role: new_admin_name,
    });
}

// === Root Role Transfer ===

/// Initiate a transfer of the root role to `new_admin`.
///
/// Caller must hold the root role. The transfer cannot be accepted until
/// `default_admin_delay_ms` has elapsed. An existing pending transfer is
/// overwritten — the caller can correct a wrong recipient without cancelling.
public fun begin_default_admin_transfer<RootRole>(
    ac: &mut AccessControl<RootRole>,
    new_admin: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(has_role_by_name(ac, ac.protected_root, ctx.sender()), EUnauthorized);

    let execute_after_ms = clock.timestamp_ms() + ac.default_admin_delay_ms;
    ac.pending_default_admin = option::some(PendingAdminTransfer { new_admin, execute_after_ms });

    event::emit(DefaultAdminTransferScheduled { new_admin, execute_after_ms });
}

/// Accept a pending root role transfer. Caller must be the pending new admin
/// and the configured delay must have elapsed. Atomically revokes from the
/// previous holder and grants to the caller.
public fun accept_default_admin_transfer<RootRole>(
    ac: &mut AccessControl<RootRole>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(ac.pending_default_admin.is_some(), ENoPendingAdminTransfer);

    let PendingAdminTransfer { new_admin, execute_after_ms } = ac.pending_default_admin.extract();

    assert!(new_admin == ctx.sender(), ENotPendingAdmin);
    assert!(clock.timestamp_ms() >= execute_after_ms, EDelayNotElapsed);

    let sender = ctx.sender();
    let root_type = ac.protected_root;

    // Root role has at most one holder; find and revoke atomically.
    let maybe_old_admin = {
        let keys = ac.roles.borrow<_, RoleData>(root_type).members.keys();
        if (keys.is_empty()) option::none() else option::some(keys[0])
    };

    if (maybe_old_admin.is_some()) {
        let old_admin = *maybe_old_admin.borrow();
        ac.roles.borrow_mut<_, RoleData>(root_type).members.remove(&old_admin);
        event::emit(RoleRevoked { role: root_type, account: old_admin, sender });
    };

    ac.roles.borrow_mut<_, RoleData>(root_type).members.insert(new_admin);
    event::emit(RoleGranted { role: root_type, account: new_admin, sender });
}

/// Cancel a pending root role transfer. Caller must hold the root role.
public fun cancel_default_admin_transfer<RootRole>(
    ac: &mut AccessControl<RootRole>,
    ctx: &mut TxContext,
) {
    assert!(ac.pending_default_admin.is_some(), ENoPendingAdminTransfer);
    assert!(has_role_by_name(ac, ac.protected_root, ctx.sender()), EUnauthorized);

    let _ = ac.pending_default_admin.extract();

    event::emit(DefaultAdminTransferCancelled {});
}

// === Auth Issuance ===

/// Mint an `Auth<R>` for the transaction sender.
///
/// `R` must be a home-module role and the sender must currently hold it.
/// Combined with the singleton-registry invariant, this guarantees every
/// `Auth<R>` produced is unforgeable in context: the only registry that can
/// mint it is the unique one rooted at R's module.
///
/// #### Aborts
/// - `EForeignRole` if `R`'s home module differs from `RootRole`'s.
/// - `EUnauthorized` if the sender does not hold `R`.
public fun new_auth<RootRole, R>(ac: &AccessControl<RootRole>, ctx: &mut TxContext): Auth<R> {
    assert_home_module<RootRole, R>();
    assert_role<RootRole, R>(ac, ctx.sender());
    Auth<R> { addr: ctx.sender() }
}

/// The address that was authorized when the `Auth<R>` was issued.
public fun auth_addr<R>(auth: &Auth<R>): address {
    auth.addr
}

// === Getters ===

/// `TypeName` of the protected root role.
public fun protected_root<RootRole>(ac: &AccessControl<RootRole>): TypeName {
    ac.protected_root
}

public fun max_default_admin_delay_ms(): u64 { MAX_DEFAULT_ADMIN_DELAY_MS }

public fun default_admin_delay_ms<RootRole>(ac: &AccessControl<RootRole>): u64 {
    ac.default_admin_delay_ms
}

public fun has_pending_default_admin_transfer<RootRole>(ac: &AccessControl<RootRole>): bool {
    ac.pending_default_admin.is_some()
}

public fun pending_default_admin_new_admin<RootRole>(
    ac: &AccessControl<RootRole>,
): Option<address> {
    if (ac.pending_default_admin.is_none()) return option::none();
    option::some(ac.pending_default_admin.borrow().new_admin)
}

public fun pending_default_admin_execute_after_ms<RootRole>(
    ac: &AccessControl<RootRole>,
): Option<u64> {
    if (ac.pending_default_admin.is_none()) return option::none();
    option::some(ac.pending_default_admin.borrow().execute_after_ms)
}

// === Test-Only Helpers ===

#[test_only]
public fun test_new_role_granted(role: TypeName, account: address, sender: address): RoleGranted {
    RoleGranted { role, account, sender }
}

#[test_only]
public fun test_new_role_revoked(role: TypeName, account: address, sender: address): RoleRevoked {
    RoleRevoked { role, account, sender }
}

#[test_only]
public fun test_new_role_admin_changed(
    role: TypeName,
    previous_admin_role: TypeName,
    new_admin_role: TypeName,
): RoleAdminChanged {
    RoleAdminChanged { role, previous_admin_role, new_admin_role }
}

#[test_only]
public fun test_new_default_admin_transfer_scheduled(
    new_admin: address,
    execute_after_ms: u64,
): DefaultAdminTransferScheduled {
    DefaultAdminTransferScheduled { new_admin, execute_after_ms }
}

#[test_only]
public fun test_new_default_admin_transfer_cancelled(): DefaultAdminTransferCancelled {
    DefaultAdminTransferCancelled {}
}

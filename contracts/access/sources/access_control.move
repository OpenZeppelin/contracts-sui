/// Role-based access control for Sui Move protocols.
///
/// ### Structural invariants
///
/// 1. **One AccessControl per module, initialized at first publish.**
///    `new<RootRole>` only accepts a One-Time Witness as `RootRole`. The Sui VM
///    produces exactly one OTW value of a given type when the package containing
///    that type is first published (passed into the consumer module's `init`),
///    so a module can stand up at most one registry of its own type, ever.
///    Package upgrades do not run `init` for newly-added modules. To add
///    AccessControl to an already-published protocol, publish a new package
///    that initializes its own registry instead of adding a new module to the
///    existing package.
///
/// 2. **Only home-module roles.** Every role-typed entry point — the four
///    mutating functions (`grant_role`, `revoke_role`, `renounce_role`,
///    `set_role_admin`) plus the auth-mint path (`new_auth`) — checks that
///    the role type's home module matches the root role's home module.
///    Foreign role types are rejected at the boundary; they cannot be
///    introduced into the bag. The check uses `type_name::with_original_ids`,
///    which compares the package's *original* publish address — so role
///    types introduced in later upgrades to the same module in the same
///    package pass the check too. The home-module rule restricts roles to the
///    same original package and module, not to the same package version.
///
/// Together these guarantees make `Auth<Role>` a self-validating capability.
/// `Role` can only live in the registry of its home module, that registry is
/// unique for its module, and the only path to mint `Auth<Role>` is `new_auth`
/// against that registry. Action functions can take `&Auth<Role>` directly with
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
///     registry.grant_role<_, AdminRole>(ctx.sender(), ctx);
///     registry.set_role_admin<_, OperatorRole, AdminRole>(ctx);
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

/// A write operation was attempted on the protected root role outside the
/// timelocked transfer or renounce flow.
#[error(code = 1)]
const ECannotManageRootRole: vector<u8> =
    "Root role can only be changed via the delayed transfer or renounce flow";

/// No pending root role transfer or renounce exists in the shared
/// transfer-or-renounce slot.
#[error(code = 2)]
const ENoPendingAdminTransfer: vector<u8> = "No pending default admin transfer or renounce";

/// Caller is not the pending new admin.
#[error(code = 3)]
const ENotPendingAdmin: vector<u8> = "Caller is not the pending admin";

/// Pending action was attempted before its timelock elapsed.
#[error(code = 4)]
const EDelayNotElapsed: vector<u8> = "Pending action's timelock has not elapsed";

/// Role renounce attempted for an account other than the transaction sender.
#[error(code = 5)]
const ECannotRenounceForOtherAccount: vector<u8> = "Can only renounce role for own account";

/// Default admin delay value exceeds the allowed maximum.
#[error(code = 6)]
const EDelayTooLarge: vector<u8> = "Admin delay exceeds the maximum allowed value";

/// Root role value is not a genuine One-Time Witness.
#[error(code = 7)]
const ENotOneTimeWitness: vector<u8> = "Root role must be a One-Time Witness";

/// A role type from a module other than the root role's home module was used
/// in a write path.
#[error(code = 8)]
const EForeignRole: vector<u8> = "Role type must be defined in the same module as the root role";

/// Pending root role action is a renounce, not a transfer.
#[error(code = 9)]
const ENotPendingTransfer: vector<u8> = "Pending action is a renounce, not a transfer";

/// Pending root role action is a transfer, not a renounce.
#[error(code = 10)]
const ENotPendingRenounce: vector<u8> = "Pending action is not a renounce";

/// No pending default admin delay change exists.
#[error(code = 11)]
const ENoPendingDelayChange: vector<u8> = "No pending default admin delay change";

/// Zero address was used as a role holder or root transfer target. The zero
/// address has no signing key, so a role granted to it can never be exercised
/// and a transfer scheduled to it can never be accepted.
#[error(code = 12)]
const EZeroAddress: vector<u8> = "Cannot use the zero address as a role holder or transfer target";

// === Constants ===

/// Upper bound on `default_admin_delay_ms` — the configured timelock for
/// root role transfer / renounce.
///
/// Value: 60 days (≈ 2 calendar months) in milliseconds.
const MAX_DEFAULT_ADMIN_DELAY_MS: u64 = 60 * 24 * 60 * 60 * 1_000;

/// Maximum wait before a scheduled delay *increase* takes effect.
///
/// When the root admin schedules an increase via
/// `begin_default_admin_delay_change`, the new (larger) delay applies after
/// a wait of `min(new_delay_ms, MAX_DELAY_INCREASE_WAIT_MS)`. This cap
/// prevents the wait from being unreasonably long when scheduling a large
/// increase: for example, raising the delay from 1 day to 60 days would
/// otherwise mean waiting the full 60 days before the new delay is in force.
///
/// Decreases follow a different rule — see `begin_default_admin_delay_change`.
///
/// Value: 48 hours in milliseconds.
const MAX_DELAY_INCREASE_WAIT_MS: u64 = 48 * 60 * 60 * 1_000;

// === Structs ===

/// Self-validating typed proof of role membership.
///
/// `Auth<Role>` is minted exclusively by `new_auth` against the unique
/// `AccessControl<RootRole>` whose home module matches `Role`'s. Because that
/// registry is the singleton for that module (Invariant 1) and only home-module roles
/// can ever be registered in it (Invariant 2), every `Auth<Role>` that exists was
/// produced by that one registry, against a sender that genuinely held `Role`.
/// Consumers can take `&Auth<Role>` as authorization without any body checks.
public struct Auth<phantom Role> has drop {
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
    /// `TypeName` of the root role (= `RootRole`'s OTW). Direct
    /// `grant_role` / `revoke_role` / `renounce_role` / `set_role_admin` on
    /// this role is blocked (`ECannotManageRootRole`); use the timelocked
    /// transfer or renounce flow.
    protected_root: TypeName,
    /// Pending change to the root role holder — either a transfer to a
    /// specific new admin or a renounce. See `PendingAdminTransfer`.
    pending_default_admin: Option<PendingAdminTransfer>,
    /// Pending change to `default_admin_delay_ms`. The change becomes
    /// effective only after `accept_default_admin_delay_change` is called
    /// past `schedule_after_ms`; an in-flight `pending_default_admin` is
    /// unaffected (it locks in the delay it was scheduled under).
    pending_default_admin_delay_change: Option<PendingDelayChange>,
    /// Current minimum delay (ms) for root role transfer / renounce.
    /// Mutable through the delayed change flow only.
    default_admin_delay_ms: u64,
}

/// Per-role state: current members and the role that administers it.
public struct RoleData has store {
    members: VecSet<address>,
    /// Defaults to the root role; changeable via `set_role_admin`.
    admin_role: TypeName,
}

/// Snapshot of a pending change to the root role holder.
///
/// `new_admin = some(addr)` represents a pending transfer — `addr` accepts
/// after the delay via `accept_default_admin_transfer`.
///
/// `new_admin = none` represents a pending renounce — the current root holder
/// finalizes after the delay via `accept_default_admin_renounce`. The same
/// pending slot is reused so a transfer and a renounce are mutually
/// exclusive: scheduling either overwrites the other.
public struct PendingAdminTransfer has drop, store {
    new_admin: Option<address>,
    execute_after_ms: u64,
}

/// Snapshot of a pending change to `default_admin_delay_ms`. Becomes
/// effective only after `accept_default_admin_delay_change` runs at or past
/// `schedule_after_ms`.
public struct PendingDelayChange has drop, store {
    new_delay_ms: u64,
    schedule_after_ms: u64,
}

// === Events ===

/// Emitted when a role is granted to an account.
///
/// Role identifiers are `TypeName`s — they embed the defining package address
/// and module name of the role struct, so events from independently-published
/// consumer protocols are distinguishable off-chain.
public struct RoleGranted has copy, drop {
    role: TypeName,
    account: address,
    sender: address,
}

/// Emitted when a role is removed from an account.
///
/// Role identifiers are `TypeName`s — they embed the defining package address
/// and module name of the role struct, so events from independently-published
/// consumer protocols are distinguishable off-chain.
public struct RoleRevoked has copy, drop {
    role: TypeName,
    account: address,
    sender: address,
}

/// Emitted when a role's admin role is reconfigured.
///
/// Role identifiers are `TypeName`s — they embed the defining package address
/// and module name of each role struct, so events from independently-published
/// consumer protocols are distinguishable off-chain.
public struct RoleAdminChanged has copy, drop {
    role: TypeName,
    previous_admin_role: TypeName,
    new_admin_role: TypeName,
}

/// Emitted when a transfer of the root role is scheduled. Distinct from
/// `DefaultAdminRenounceScheduled` so off-chain consumers can tell the two
/// kinds of pending state apart without inspecting payload.
public struct DefaultAdminTransferScheduled has copy, drop {
    new_admin: address,
    execute_after_ms: u64,
}

/// Emitted when a renounce of the root role is scheduled. Distinct from
/// `DefaultAdminTransferScheduled` so off-chain consumers can tell the two
/// kinds of pending state apart without inspecting payload.
public struct DefaultAdminRenounceScheduled has copy, drop {
    execute_after_ms: u64,
}

/// Emitted when a pending root role transfer or renounce is cancelled. Indexers
/// can correlate with the prior `DefaultAdminTransferScheduled` or
/// `DefaultAdminRenounceScheduled` event to know which kind was cancelled.
public struct DefaultAdminTransferCancelled has copy, drop {}

/// Emitted when a change to `default_admin_delay_ms` is scheduled.
public struct DefaultAdminDelayChangeScheduled has copy, drop {
    new_delay_ms: u64,
    schedule_after_ms: u64,
}

/// Emitted when a pending `default_admin_delay_ms` change is cancelled.
public struct DefaultAdminDelayChangeCancelled has copy, drop {}

// === Constructor ===

/// Create the singleton `AccessControl` for a module.
///
/// The caller passes their module's One-Time Witness as `otw`. The runtime
/// `is_one_time_witness` check confirms the value is genuine — this is what
/// enforces Invariant 1 (one registry per module, initialized at first
/// publish). The transaction sender automatically becomes the root role holder.
///
/// The expected call site is the consumer module's `init` function, where
/// the VM has already produced exactly one OTW value. That `init` function is
/// only called on the package's first publish, not when an upgrade adds a new
/// module. Existing published packages that want to adopt AccessControl should
/// publish a new package with its own initializing module instead.
///
/// #### Parameters
/// - `otw`: a VM-issued One-Time Witness of type `RootRole`. Consumed by the call.
/// - `default_admin_delay_ms`: timelock (ms) that applies to root role transfer and renounce. Mutable post-creation via `begin_default_admin_delay_change`.
/// - `ctx`: transaction context.
///
/// #### Returns
/// - The freshly-minted singleton `AccessControl<RootRole>` registry. The caller
/// is responsible for sharing, embedding, or otherwise positioning it.
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
        pending_default_admin_delay_change: option::none(),
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

// === Role Queries ===

/// Whether `account` is a member of role `Role`.
///
/// #### Parameters
/// - `Role` (type): the role to check membership of.
/// - `ac`: the registry to query.
/// - `account`: the address being checked.
///
/// #### Returns
/// - `true` if `account` currently holds `Role`, `false` otherwise. Returns
/// `false` for roles that have never been registered.
public fun has_role<RootRole, Role>(ac: &AccessControl<RootRole>, account: address): bool {
    ac.has_role_by_name(with_original_ids<Role>(), account)
}

/// The `TypeName` of the admin role of `Role`.
///
/// #### Parameters
/// - `Role` (type): the role whose admin role is being looked up.
/// - `ac`: the registry to query.
///
/// #### Returns
/// - The `TypeName` of `Role`'s admin role. Defaults to the root role's
/// `TypeName` for roles that have no entry yet.
public fun get_role_admin<RootRole, Role>(ac: &AccessControl<RootRole>): TypeName {
    ac.get_role_admin_name(with_original_ids<Role>())
}

/// Assert that `account` holds role `Role`. Aborts otherwise.
///
/// #### Parameters
/// - `Role` (type): the role to assert membership of.
/// - `ac`: the registry to query.
/// - `account`: the address being checked.
///
/// #### Aborts
/// - `EUnauthorized` if `account` does not hold role `Role`.
public fun assert_role<RootRole, Role>(ac: &AccessControl<RootRole>, account: address) {
    assert!(ac.has_role<_, Role>(account), EUnauthorized);
}

// === Role Management ===

/// Grant role `Role` to `account`. Caller must hold the admin role of `Role`.
/// `Role` must be defined in the same module as `RootRole` (Invariant 2).
/// No-op if `account` already holds `Role`.
///
/// #### Parameters
/// - `Role` (type): the role to grant.
/// - `ac`: the registry to mutate.
/// - `account`: the address being granted `Role`.
/// - `ctx`: transaction context.
///
/// #### Aborts
/// - `EForeignRole` if `Role`'s home module differs from `RootRole`'s.
/// - `ECannotManageRootRole` if `Role` is the root role.
/// - `EUnauthorized` if the caller does not hold the admin role of `Role`.
/// - `EZeroAddress` if `account` is `@0x0`.
public fun grant_role<RootRole, Role>(
    ac: &mut AccessControl<RootRole>,
    account: address,
    ctx: &mut TxContext,
) {
    assert_home_module<RootRole, Role>();
    assert!(account != @0x0, EZeroAddress);
    let role_name = with_original_ids<Role>();
    assert!(role_name != ac.protected_root, ECannotManageRootRole);
    assert!(ac.has_role_by_name(ac.get_role_admin_name(role_name), ctx.sender()), EUnauthorized);

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

/// Revoke role `Role` from `account`. Caller must hold the admin role of `Role`.
/// No-op if `account` does not hold `Role`.
///
/// #### Parameters
/// - `Role` (type): the role to revoke.
/// - `ac`: the registry to mutate.
/// - `account`: the address losing `Role`.
/// - `ctx`: transaction context.
///
/// #### Aborts
/// - `EForeignRole` if `Role`'s home module differs from `RootRole`'s.
/// - `ECannotManageRootRole` if `Role` is the root role.
/// - `EUnauthorized` if the caller does not hold the admin role of `Role`.
public fun revoke_role<RootRole, Role>(
    ac: &mut AccessControl<RootRole>,
    account: address,
    ctx: &mut TxContext,
) {
    assert_home_module<RootRole, Role>();
    let role_name = with_original_ids<Role>();
    assert!(role_name != ac.protected_root, ECannotManageRootRole);
    assert!(ac.has_role_by_name(ac.get_role_admin_name(role_name), ctx.sender()), EUnauthorized);

    if (!ac.roles.contains(role_name)) return;

    let role_data = ac.roles.borrow_mut<_, RoleData>(role_name);
    if (!role_data.members.contains(&account)) return;

    role_data.members.remove(&account);
    event::emit(RoleRevoked { role: role_name, account, sender: ctx.sender() });
}

/// Voluntarily relinquish role `Role`.
/// No-op if the caller does not hold `Role`. **Blocked on the root role** —
/// use `begin_default_admin_renounce` + `accept_default_admin_renounce`
/// instead, so the protocol gets the configured timelock and a cancel window
/// before the registry becomes unmanaged.
///
/// #### Parameters
/// - `Role` (type): the role to relinquish.
/// - `ac`: the registry to mutate.
/// - `account`: the address relinquishing `Role`.
/// - `ctx`: transaction context.
///
/// #### Aborts
/// - `ECannotRenounceForOtherAccount` if `account != ctx.sender()`.
/// - `EForeignRole` if `Role`'s home module differs from `RootRole`'s.
/// - `ECannotManageRootRole` if `Role` is the root role.
public fun renounce_role<RootRole, Role>(
    ac: &mut AccessControl<RootRole>,
    account: address,
    ctx: &mut TxContext,
) {
    assert!(account == ctx.sender(), ECannotRenounceForOtherAccount);
    assert_home_module<RootRole, Role>();

    let role_name = with_original_ids<Role>();
    assert!(role_name != ac.protected_root, ECannotManageRootRole);

    if (!ac.roles.contains(role_name)) return;

    let role_data = ac.roles.borrow_mut<_, RoleData>(role_name);
    if (!role_data.members.contains(&account)) return;

    role_data.members.remove(&account);
    event::emit(RoleRevoked { role: role_name, account, sender: ctx.sender() });
}

/// Set the admin role of `Role` to `AdminRole`. Caller must hold the current
/// admin role of `Role`.
///
/// #### Parameters
/// - `Role` (type): the role whose admin is being changed.
/// - `AdminRole` (type): the role granted authority over `Role` going forward.
/// - `ac`: the registry to mutate.
/// - `ctx`: transaction context.
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

    let previous_admin_role = ac.get_role_admin_name(role_name);
    assert!(ac.has_role_by_name(previous_admin_role, ctx.sender()), EUnauthorized);

    let new_admin_name = with_original_ids<AdminRole>();

    if (ac.roles.contains(role_name)) {
        ac.roles.borrow_mut<_, RoleData>(role_name).admin_role = new_admin_name;
    } else {
        ac
            .roles
            .add(
                role_name,
                RoleData { members: vec_set::empty(), admin_role: new_admin_name },
            );
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
/// `default_admin_delay_ms` has elapsed. An existing pending transfer or
/// renounce is overwritten — the caller can correct a wrong target (or
/// switch between transfer and renounce) without cancelling first.
///
/// #### Parameters
/// - `ac`: the registry to mutate.
/// - `new_admin`: the address proposed to take over the root role. Will receive the role only after `accept_default_admin_transfer` is called past the timelock.
/// - `clock`: current clock; used to compute `execute_after_ms`.
/// - `ctx`: transaction context.
///
/// #### Aborts
/// - `EUnauthorized` if the caller does not hold the root role.
/// - `EZeroAddress` if `new_admin` is `@0x0`. Use `begin_default_admin_renounce` to lock the registry permanently.
public fun begin_default_admin_transfer<RootRole>(
    ac: &mut AccessControl<RootRole>,
    new_admin: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(ac.has_role_by_name(ac.protected_root, ctx.sender()), EUnauthorized);
    assert!(new_admin != @0x0, EZeroAddress);

    let execute_after_ms = clock.timestamp_ms() + ac.default_admin_delay_ms;
    ac.pending_default_admin =
        option::some(PendingAdminTransfer {
            new_admin: option::some(new_admin),
            execute_after_ms,
        });

    event::emit(DefaultAdminTransferScheduled { new_admin, execute_after_ms });
}

/// Accept a pending root role transfer. Caller must be the pending new admin
/// and the configured delay must have elapsed. Atomically revokes from the
/// previous holder (if one exists) and grants to the caller.
///
/// #### Parameters
/// - `ac`: the registry to mutate.
/// - `clock`: current clock; used to verify the timelock has elapsed.
/// - `ctx`: transaction context.
///
/// #### Aborts
/// - `ENoPendingAdminTransfer` if no pending action exists.
/// - `ENotPendingTransfer` if the pending action is a renounce, not a transfer.
/// - `ENotPendingAdmin` if the caller is not the scheduled new admin.
/// - `EDelayNotElapsed` if the timelock has not elapsed.
public fun accept_default_admin_transfer<RootRole>(
    ac: &mut AccessControl<RootRole>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(ac.pending_default_admin.is_some(), ENoPendingAdminTransfer);

    // Validate against a borrow first so we don't mutate state on a wrong-kind
    // or wrong-caller call.
    let (new_admin, execute_after_ms) = {
        let pending = ac.pending_default_admin.borrow();
        assert!(pending.new_admin.is_some(), ENotPendingTransfer);
        (*pending.new_admin.borrow(), pending.execute_after_ms)
    };
    assert!(new_admin == ctx.sender(), ENotPendingAdmin);
    assert!(clock.timestamp_ms() >= execute_after_ms, EDelayNotElapsed);

    let _ = ac.pending_default_admin.extract();

    let sender = ctx.sender();
    let root_type = ac.protected_root;

    // Root role has at most one holder; find and revoke atomically.
    let keys = ac.roles.borrow<_, RoleData>(root_type).members.keys();
    if (!keys.is_empty()) {
        let old_admin = keys[0];
        ac.roles.borrow_mut<_, RoleData>(root_type).members.remove(&old_admin);
        event::emit(RoleRevoked { role: root_type, account: old_admin, sender });
    };

    ac.roles.borrow_mut<_, RoleData>(root_type).members.insert(new_admin);
    event::emit(RoleGranted { role: root_type, account: new_admin, sender });
}

/// Initiate a renounce of the root role.
///
/// Caller must hold the root role. The renounce cannot be finalized until
/// `default_admin_delay_ms` has elapsed, giving the protocol a cancel window
/// before the registry becomes permanently unmanaged. An existing pending
/// transfer or renounce is overwritten.
///
/// #### Security Warning
///
/// - Once finalized via `accept_default_admin_renounce`, no one holds the root
/// role and the registry can no longer be governed via the transfer flow. Use
/// this only for an intentional, permanent lock-in.
///
/// #### Parameters
/// - `ac`: the registry to mutate.
/// - `clock`: current clock; used to compute `execute_after_ms`.
/// - `ctx`: transaction context.
///
/// #### Aborts
/// - `EUnauthorized` if the caller does not hold the root role.
public fun begin_default_admin_renounce<RootRole>(
    ac: &mut AccessControl<RootRole>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(ac.has_role_by_name(ac.protected_root, ctx.sender()), EUnauthorized);

    let execute_after_ms = clock.timestamp_ms() + ac.default_admin_delay_ms;
    ac.pending_default_admin =
        option::some(PendingAdminTransfer {
            new_admin: option::none(),
            execute_after_ms,
        });

    event::emit(DefaultAdminRenounceScheduled { execute_after_ms });
}

/// Finalize a pending root role renounce. Caller must currently hold the
/// root role and the configured delay must have elapsed. Removes the caller
/// from the root role; emits `RoleRevoked` and clears the pending slot.
///
/// #### Parameters
/// - `ac`: the registry to mutate.
/// - `clock`: current clock; used to verify the timelock has elapsed.
/// - `ctx`: transaction context.
///
/// #### Aborts
/// - `ENoPendingAdminTransfer` if no pending action exists.
/// - `ENotPendingRenounce` if the pending action is a transfer, not a renounce.
/// - `EUnauthorized` if the caller does not hold the root role.
/// - `EDelayNotElapsed` if the timelock has not elapsed.
public fun accept_default_admin_renounce<RootRole>(
    ac: &mut AccessControl<RootRole>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(ac.pending_default_admin.is_some(), ENoPendingAdminTransfer);

    let execute_after_ms = {
        let pending = ac.pending_default_admin.borrow();
        assert!(pending.new_admin.is_none(), ENotPendingRenounce);
        pending.execute_after_ms
    };
    assert!(ac.has_role_by_name(ac.protected_root, ctx.sender()), EUnauthorized);
    assert!(clock.timestamp_ms() >= execute_after_ms, EDelayNotElapsed);

    let _ = ac.pending_default_admin.extract();

    let sender = ctx.sender();
    let root_type = ac.protected_root;

    ac.roles.borrow_mut<_, RoleData>(root_type).members.remove(&sender);
    event::emit(RoleRevoked { role: root_type, account: sender, sender });
}

/// Cancel a pending root role transfer or renounce. Caller must hold the
/// root role. The same function clears either kind; off-chain consumers
/// correlate with the prior schedule event.
///
/// #### Parameters
/// - `ac`: the registry to mutate.
/// - `ctx`: transaction context.
///
/// #### Aborts
/// - `ENoPendingAdminTransfer` if no pending action exists.
/// - `EUnauthorized` if the caller does not hold the root role.
public fun cancel_default_admin_transfer<RootRole>(
    ac: &mut AccessControl<RootRole>,
    ctx: &mut TxContext,
) {
    assert!(ac.pending_default_admin.is_some(), ENoPendingAdminTransfer);
    assert!(ac.has_role_by_name(ac.protected_root, ctx.sender()), EUnauthorized);

    let _ = ac.pending_default_admin.extract();

    event::emit(DefaultAdminTransferCancelled {});
}

// === Default Admin Delay Change ===

/// Schedule a change to `default_admin_delay_ms`.
///
/// How long until the new delay applies depends on whether it's an increase
/// or a decrease:
/// - **Increase** (`new_delay_ms > current`):
///   wait = `min(new_delay_ms, MAX_DELAY_INCREASE_WAIT_MS)`.
///   The cap exists so a large increase doesn't force you to wait the
///   entire new value before it takes effect — see `MAX_DELAY_INCREASE_WAIT_MS`.
/// - **Decrease** (`new_delay_ms < current`):
///   wait = `current - new_delay_ms`.
///   The freed time forces the admin to commit to the change for that
///   period before they can schedule new transfers under the shorter delay,
///   preserving the protection level of the current delay. (In-flight
///   transfers / renounces aren't affected by the change anyway — they use
///   the delay they were scheduled under.)
/// - **No change** (`new_delay_ms == current`): wait = 0.
///
/// Caller must hold the root role. An existing pending delay change is
/// overwritten.
///
/// #### Parameters
/// - `ac`: the registry to mutate.
/// - `new_delay_ms`: the proposed new value of `default_admin_delay_ms`.
/// - `clock`: current clock; used to compute the schedule timestamp.
/// - `ctx`: transaction context.
///
/// #### Aborts
/// - `EUnauthorized` if the caller does not hold the root role.
/// - `EDelayTooLarge` if `new_delay_ms` exceeds `MAX_DEFAULT_ADMIN_DELAY_MS`.
public fun begin_default_admin_delay_change<RootRole>(
    ac: &mut AccessControl<RootRole>,
    new_delay_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(ac.has_role_by_name(ac.protected_root, ctx.sender()), EUnauthorized);
    assert!(new_delay_ms <= MAX_DEFAULT_ADMIN_DELAY_MS, EDelayTooLarge);

    let current = ac.default_admin_delay_ms;
    let wait = if (new_delay_ms > current) {
        new_delay_ms.min(MAX_DELAY_INCREASE_WAIT_MS)
    } else {
        current - new_delay_ms
    };
    let schedule_after_ms = clock.timestamp_ms() + wait;

    ac.pending_default_admin_delay_change =
        option::some(PendingDelayChange {
            new_delay_ms,
            schedule_after_ms,
        });

    event::emit(DefaultAdminDelayChangeScheduled { new_delay_ms, schedule_after_ms });
}

/// Apply a pending delay change once its schedule has elapsed.
///
/// No authorization required — the schedule was committed by the root admin
/// at `begin` time; `accept` is just the state transition. Anyone can call
/// it.
///
/// #### Parameters
/// - `ac`: the registry to mutate.
/// - `clock`: current clock; used to verify the schedule has passed.
/// - `_ctx`: transaction context.
///
/// #### Aborts
/// - `ENoPendingDelayChange` if no pending change exists.
/// - `EDelayNotElapsed` if `schedule_after_ms` has not been reached.
public fun accept_default_admin_delay_change<RootRole>(
    ac: &mut AccessControl<RootRole>,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert!(ac.pending_default_admin_delay_change.is_some(), ENoPendingDelayChange);

    let (new_delay_ms, schedule_after_ms) = {
        let pending = ac.pending_default_admin_delay_change.borrow();
        (pending.new_delay_ms, pending.schedule_after_ms)
    };
    assert!(clock.timestamp_ms() >= schedule_after_ms, EDelayNotElapsed);

    let _ = ac.pending_default_admin_delay_change.extract();
    ac.default_admin_delay_ms = new_delay_ms;
}

/// Cancel a pending delay change. Caller must hold the root role.
///
/// #### Parameters
/// - `ac`: the registry to mutate.
/// - `ctx`: transaction context.
///
/// #### Aborts
/// - `ENoPendingDelayChange` if no pending change exists.
/// - `EUnauthorized` if the caller does not hold the root role.
public fun cancel_default_admin_delay_change<RootRole>(
    ac: &mut AccessControl<RootRole>,
    ctx: &mut TxContext,
) {
    assert!(ac.pending_default_admin_delay_change.is_some(), ENoPendingDelayChange);
    assert!(ac.has_role_by_name(ac.protected_root, ctx.sender()), EUnauthorized);

    let _ = ac.pending_default_admin_delay_change.extract();

    event::emit(DefaultAdminDelayChangeCancelled {});
}

// === Auth Issuance ===

/// Mint an `Auth<Role>` for the transaction sender.
///
/// `Role` must be a home-module role and the sender must currently hold it.
/// Combined with the singleton-registry invariant, this guarantees every
/// `Auth<Role>` produced is unforgeable in context: the only registry that can
/// mint it is the unique one rooted at `Role`'s module.
///
/// #### Parameters
/// - `Role` (type): the role for which to mint an auth witness.
/// - `ac`: the registry to query.
/// - `ctx`: transaction context.
///
/// #### Returns
/// - An `Auth<Role>` capability bound to `ctx.sender()`. Pass it by reference
/// to gated functions in the same PTB.
///
/// #### Aborts
/// - `EForeignRole` if `Role`'s home module differs from `RootRole`'s.
/// - `EUnauthorized` if the sender does not hold `Role`.
public fun new_auth<RootRole, Role>(ac: &AccessControl<RootRole>, ctx: &mut TxContext): Auth<Role> {
    assert_home_module<RootRole, Role>();
    assert_role<RootRole, Role>(ac, ctx.sender());
    Auth<Role> { addr: ctx.sender() }
}

/// The address that was authorized when the `Auth<Role>` was issued.
///
/// #### Parameters
/// - `auth`: the auth witness to read.
///
/// #### Returns
/// - The address that held `Role` at the time `new_auth` minted this witness.
public fun auth_addr<Role>(auth: &Auth<Role>): address {
    auth.addr
}

// === Getters ===

/// `TypeName` of the protected root role.
///
/// #### Parameters
/// - `ac`: the registry to query.
public fun protected_root<RootRole>(ac: &AccessControl<RootRole>): TypeName {
    ac.protected_root
}

/// Upper bound on `default_admin_delay_ms`.
public fun max_default_admin_delay_ms(): u64 { MAX_DEFAULT_ADMIN_DELAY_MS }

/// Currently-configured timelock (ms) for root role transfer / renounce.
///
/// #### Parameters
/// - `ac`: the registry to query.
public fun default_admin_delay_ms<RootRole>(ac: &AccessControl<RootRole>): u64 {
    ac.default_admin_delay_ms
}

/// Whether there is any pending action on the root role — either a
/// transfer or a renounce.
///
/// #### Parameters
/// - `ac`: the registry to query.
public fun has_pending_default_admin_transfer<RootRole>(ac: &AccessControl<RootRole>): bool {
    ac.pending_default_admin.is_some()
}

/// Whether the pending action is specifically a renounce.
///
/// #### Parameters
/// - `ac`: the registry to query.
///
/// #### Returns
/// - `true` only when a renounce is pending. `false` when no pending action
/// exists OR when the pending action is a transfer.
public fun is_pending_default_admin_renounce<RootRole>(ac: &AccessControl<RootRole>): bool {
    if (ac.pending_default_admin.is_none()) return false;
    ac.pending_default_admin.borrow().new_admin.is_none()
}

/// The pending new admin address.
///
/// Use `is_pending_default_admin_renounce` to disambiguate "no pending" from
/// "pending renounce".
///
/// #### Parameters
/// - `ac`: the registry to query.
///
/// #### Returns
/// - `some(addr)` if the pending action is a transfer to `addr`.
/// - `none` if there is no pending action OR if the pending action is a renounce.
public fun pending_default_admin_new_admin<RootRole>(
    ac: &AccessControl<RootRole>,
): Option<address> {
    if (ac.pending_default_admin.is_none()) return option::none();
    let pending = ac.pending_default_admin.borrow();
    if (pending.new_admin.is_none()) return option::none();
    option::some(*pending.new_admin.borrow())
}

/// The timestamp at which the pending action becomes acceptable.
///
/// #### Parameters
/// - `ac`: the registry to query.
///
/// #### Returns
/// - `some(ts)` with the millisecond timestamp the pending action unlocks at.
/// - `none` if there is no pending action.
public fun pending_default_admin_execute_after_ms<RootRole>(
    ac: &AccessControl<RootRole>,
): Option<u64> {
    if (ac.pending_default_admin.is_none()) return option::none();
    option::some(ac.pending_default_admin.borrow().execute_after_ms)
}

// === Default Admin Delay Change Getters ===

/// Maximum wait before a scheduled delay *increase* takes effect.
public fun max_delay_increase_wait_ms(): u64 {
    MAX_DELAY_INCREASE_WAIT_MS
}

/// Whether a delay change is pending.
///
/// #### Parameters
/// - `ac`: the registry to query.
public fun has_pending_default_admin_delay_change<RootRole>(ac: &AccessControl<RootRole>): bool {
    ac.pending_default_admin_delay_change.is_some()
}

/// The proposed new delay value of the pending change.
///
/// #### Parameters
/// - `ac`: the registry to query.
///
/// #### Returns
/// - `some(new_delay_ms)` with the proposed delay if a change is pending.
/// - `none` if there is no pending change.
public fun pending_default_admin_delay_change_new_delay_ms<RootRole>(
    ac: &AccessControl<RootRole>,
): Option<u64> {
    if (ac.pending_default_admin_delay_change.is_none()) return option::none();
    option::some(ac.pending_default_admin_delay_change.borrow().new_delay_ms)
}

/// The timestamp at which the pending delay change becomes acceptable.
///
/// #### Parameters
/// - `ac`: the registry to query.
///
/// #### Returns
/// - `some(ts)` with the millisecond timestamp the pending change unlocks at.
/// - `none` if there is no pending change.
public fun pending_default_admin_delay_change_schedule_after_ms<RootRole>(
    ac: &AccessControl<RootRole>,
): Option<u64> {
    if (ac.pending_default_admin_delay_change.is_none()) return option::none();
    option::some(ac.pending_default_admin_delay_change.borrow().schedule_after_ms)
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

/// Asserts `Role` and `RootRole` come from the same package + module.
///
/// Uses `with_original_ids` so role types introduced in later upgrades to the
/// same module still match — the address compared is the package's original
/// publish ID, which is stable across upgrades. This is the runtime arm of
/// Invariant 2.
fun assert_home_module<RootRole, Role>() {
    let root = with_original_ids<RootRole>();
    let role = with_original_ids<Role>();
    assert!(
        root.address_string() == role.address_string()
            && root.module_string() == role.module_string(),
        EForeignRole,
    );
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

#[test_only]
public fun test_new_default_admin_renounce_scheduled(
    execute_after_ms: u64,
): DefaultAdminRenounceScheduled {
    DefaultAdminRenounceScheduled { execute_after_ms }
}

#[test_only]
public fun test_new_default_admin_delay_change_scheduled(
    new_delay_ms: u64,
    schedule_after_ms: u64,
): DefaultAdminDelayChangeScheduled {
    DefaultAdminDelayChangeScheduled { new_delay_ms, schedule_after_ms }
}

#[test_only]
public fun test_new_default_admin_delay_change_cancelled(): DefaultAdminDelayChangeCancelled {
    DefaultAdminDelayChangeCancelled {}
}

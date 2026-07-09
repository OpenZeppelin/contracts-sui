/// Timelocking a package `UpgradeCap` - the headline real-world use case, where two hot
/// potatoes meet: the timelock's `ExecutionTicket` and Sui's `UpgradeTicket`.
///
/// The flow:
///
/// 1. The publisher creates an `AccessControl` + `Timelock` (`init`), then deposits the
///    package `UpgradeCap` into a shared `UpgradeVault` via `wrap`. `wrap` mints an
///    `OperationCap` against the canonical timelock and stores it in the vault, so every
///    vault entry is bound to that timelock structurally - no hand-written
///    `object::id` assert. The `UpgradeCap` arrives at the publisher only after the first
///    publish, so it is wrapped *after* `init`, not inside it.
/// 2. A proposer `schedule_upgrade`s the `(policy, digest)` of the planned upgrade; they
///    are stored on-chain as the operation's typed params.
/// 3. After the delay, an executor calls `authorize_scheduled_upgrade`: it consumes the
///    timelock ticket (proving the delay elapsed) and only then calls
///    `package::authorize_upgrade`, returning the `UpgradeTicket`. In the same PTB the
///    `Upgrade` command runs and `commit_upgrade` records the receipt.
///
/// The upshot: a package can only be upgraded after a mandatory public delay, giving
/// users a window to exit before a privileged code change takes effect.
///
/// # One-way doors
///
/// Two properties of this design are deliberate and irreversible - integrators copying
/// the pattern should carry them knowingly:
///
/// - **Wrapping the cap is permanent.** `wrap` consumes the `UpgradeCap` into a shared
///   vault with no unwrap and no `make_immutable` path, so every future upgrade goes
///   through the timelock forever - and the package can never be frozen. That permanence
///   is the credible commitment the vault exists to provide. A production variant that
///   wants an end state would add a timelocked `make_immutable` operation.
/// - **Superseded upgrades must be cancelled explicitly.** `commit_upgrade` updates only
///   the stored cap; it never touches the timelock's operation store. An upgrade
///   scheduled earlier survives an intermediate upgrade and, once its delay elapses,
///   remains executable against the updated cap with no fresh delay. When plans change,
///   a canceller must `cancel_upgrade` the stale operation - scheduling a replacement is
///   not enough.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `timelock` primitive can be integrated. It is not production-ready and must not be
/// deployed as-is.
module openzeppelin_timelock::example_upgrade_vault;

use openzeppelin_access::access_control::{Self, Auth};
use openzeppelin_timelock::timelock::{Self, Timelock, OperationCap};
use sui::clock::Clock;
use sui::package::{Self, UpgradeCap, UpgradeTicket, UpgradeReceipt};

// === Constants ===

const DAY_MS: u64 = 24 * 60 * 60 * 1_000;

// === Structs ===

/// One-time witness for the `AccessControl` registry.
public struct EXAMPLE_UPGRADE_VAULT has drop {}

/// Operation witness for upgrade authorizations (`drop`-only, module-private).
public struct UpgradeAction has drop {}

/// Timelocked upgrade parameters, stored on-chain by the timelock as the op's params.
public struct UpgradeParams has drop, store {
    policy: u8,
    digest: vector<u8>,
}

/// Roles, managed in the consumer's `AccessControl`.
public struct ProposerRole {}
public struct ExecutorRole {}
public struct CancellerRole {}
public struct AdminRole {}

/// Holds the package `UpgradeCap` behind the timelock, plus the `OperationCap` that binds
/// upgrade ops to the canonical timelock. Shared; `key`-only.
public struct UpgradeVault has key {
    id: UID,
    op_cap: OperationCap<UpgradeAction, UpgradeParams>,
    cap: UpgradeCap,
}

// === Init ===

fun init(otw: EXAMPLE_UPGRADE_VAULT, ctx: &mut TxContext) {
    let mut ac = access_control::new(otw, 7 * DAY_MS, ctx);
    ac.set_role_admin<_, ProposerRole, EXAMPLE_UPGRADE_VAULT>(ctx);
    ac.set_role_admin<_, ExecutorRole, EXAMPLE_UPGRADE_VAULT>(ctx);
    ac.set_role_admin<_, CancellerRole, EXAMPLE_UPGRADE_VAULT>(ctx);
    ac.set_role_admin<_, AdminRole, EXAMPLE_UPGRADE_VAULT>(ctx);

    timelock::new_shared<ProposerRole, ExecutorRole, CancellerRole, AdminRole>(
        DAY_MS,
        7 * DAY_MS,
        ctx,
    );
    transfer::public_share_object(ac);
}

// === Public Functions ===

/// Deposit the package `UpgradeCap` into a vault bound to `timelock`. Mints the op cap
/// from the canonical (shared) timelock. Called by the publisher after `init`.
///
/// Permissionless by design: it is gated by possession of the `UpgradeCap` (a one-time
/// publisher bootstrap), and the caller chooses which `timelock` the vault binds to.
public fun wrap(cap: UpgradeCap, timelock: &Timelock, ctx: &mut TxContext) {
    let op_cap = timelock.new_operation_cap<UpgradeAction, UpgradeParams>();
    transfer::share_object(UpgradeVault { id: object::new(ctx), op_cap, cap });
}

// === Upgrade pipeline (cap-bound; no manual id assert) ===

/// Proposer schedules an upgrade by committing the `(policy, digest)` (stored typed).
public fun schedule_upgrade(
    timelock: &mut Timelock,
    vault: &UpgradeVault,
    proposer: &Auth<ProposerRole>,
    policy: u8,
    digest: vector<u8>,
    salt: vector<u8>,
    delay_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): vector<u8> {
    let params = UpgradeParams { policy, digest };
    timelock.schedule_with(&vault.op_cap, proposer, params, vector[], salt, delay_ms, clock, ctx)
}

/// Executor cranks the scheduled upgrade: consumes the timelock ticket (delay proven) and
/// authorizes the package upgrade, returning the `UpgradeTicket` for the PTB's `Upgrade`
/// command.
public fun authorize_scheduled_upgrade(
    timelock: &mut Timelock,
    vault: &mut UpgradeVault,
    executor: &Auth<ExecutorRole>,
    id: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
): UpgradeTicket {
    let tl_ticket = timelock.execute_with(&vault.op_cap, executor, id, clock, ctx);
    let (_op_id, params) = timelock.consume(tl_ticket, UpgradeAction {});
    let UpgradeParams { policy, digest } = params;
    package::authorize_upgrade(&mut vault.cap, policy, digest)
}

/// Commit the upgrade after the `Upgrade` command, updating the stored cap.
public fun commit_upgrade(vault: &mut UpgradeVault, receipt: UpgradeReceipt) {
    package::commit_upgrade(&mut vault.cap, receipt)
}

/// Cancel a pending upgrade (`CancellerRole`).
public fun cancel_upgrade(
    timelock: &mut Timelock,
    vault: &UpgradeVault,
    canceller: &Auth<CancellerRole>,
    id: vector<u8>,
    ctx: &mut TxContext,
) {
    timelock.cancel_with(&vault.op_cap, canceller, id, ctx)
}

// === Test-Only Helpers ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(EXAMPLE_UPGRADE_VAULT {}, ctx) }

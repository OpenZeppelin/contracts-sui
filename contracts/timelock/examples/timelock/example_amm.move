/// The canonical timelock integration: a single `Timelock` gating one privileged
/// operation (an AMM fee change), with roles supplied by `access_control`.
///
/// What an integrator should learn from this module:
///
/// - **Bootstrap.** `init` stands up an `AccessControl<EXAMPLE_AMM>` registry and a
///   `Timelock`, mints **one `OperationCap` per operation kind** against that timelock,
///   and stores the cap inside the `Pool` it protects. It uses `timelock::new` + `share`
///   (not `new_shared`) precisely so it can mint the cap from the object before sharing.
///
/// - **The canonical-timelock binding is structural (CPR-5).** The fee-change entries
///   pass `&pool.fee_cap` to the library's `*_with` functions, which assert
///   `object::id(timelock) == cap.timelock_id` internally. There is **no hand-written
///   `object::id` assert** in the op flow - an attacker cannot route a self-created,
///   zero-delay `Timelock` through these entries to skip the delay. Storing the cap once
///   replaces remembering an assert in every function.
///
/// - **Zero type args + typed params.** `schedule_with` / `execute_with` infer
///   `<R, Action, Params>` from `&pool.fee_cap` and the `&Auth<R>`; the new fee is passed
///   by value and comes back typed from `consume`. No BCS, no digest, no explicit `<...>`.
///
/// - **The witness is the linchpin (CPR-1/CPR-2).** `FeeChangeAction` is `drop`-only and
///   is never constructed outside this module, so only this module can `consume` a
///   fee-change ticket.
///
/// - **Config changes bind explicitly.** The self-administered `min_delay` change calls
///   the `Timelock` directly (no `OperationCap` fits a config change), so it keeps an
///   explicit `object::id` assert - showing how to bind the rare calls the cap pattern
///   does not cover.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `timelock` primitive can be integrated. It is not production-ready and must not be
/// deployed as-is.
module openzeppelin_timelock::example_amm;

use openzeppelin_access::access_control::{Self, Auth};
use openzeppelin_timelock::timelock::{Self, Timelock, OperationCap};
use sui::clock::Clock;
use sui::event;

// === Errors ===

/// A self-administered config call was routed through a timelock that is not this
/// pool's canonical one.
#[error(code = 0)]
const EWrongTimelock: vector<u8> = "Action must go through this pool's timelock";

// === Constants ===

const DAY_MS: u64 = 24 * 60 * 60 * 1_000;

// === Structs ===

/// One-time witness: gives the `AccessControl` registry a single home module.
public struct EXAMPLE_AMM has drop {}

/// Operation witness (the `Action`). `drop`-only; never constructed outside this module.
public struct FeeChangeAction has drop {}

/// Roles, managed in the consumer's `AccessControl`. The `Timelock` is generic over them.
public struct ProposerRole {}
public struct ExecutorRole {}
public struct CancellerRole {}
public struct TimelockAdminRole {}

/// The protected object. It stores the `OperationCap` (which binds the fee-change op kind
/// to the canonical timelock) and the timelock id (for the direct self-admin calls).
public struct Pool has key {
    id: UID,
    fee_bps: u16,
    timelock_id: ID,
    fee_cap: OperationCap<FeeChangeAction, u16>,
}

/// Emitted when a scheduled fee change is applied.
public struct FeeChanged has copy, drop {
    op_id: vector<u8>,
    previous_fee_bps: u16,
    new_fee_bps: u16,
}

// === Init ===

fun init(otw: EXAMPLE_AMM, ctx: &mut TxContext) {
    let mut ac = access_control::new(otw, 7 * DAY_MS, ctx);
    ac.set_role_admin<_, ProposerRole, EXAMPLE_AMM>(ctx);
    ac.set_role_admin<_, ExecutorRole, EXAMPLE_AMM>(ctx);
    ac.set_role_admin<_, CancellerRole, EXAMPLE_AMM>(ctx);
    ac.set_role_admin<_, TimelockAdminRole, EXAMPLE_AMM>(ctx);

    // `new` + `share` (not `new_shared`) so we can mint the op cap before sharing.
    let timelock = timelock::new<ProposerRole, ExecutorRole, CancellerRole, TimelockAdminRole>(
        DAY_MS,
        7 * DAY_MS,
        ctx,
    );
    let timelock_id = object::id(&timelock);
    let fee_cap = timelock.new_operation_cap<FeeChangeAction, u16>();
    timelock.share();

    transfer::share_object(Pool { id: object::new(ctx), fee_bps: 30, timelock_id, fee_cap });
    transfer::public_share_object(ac);
}

// === Fee-change pipeline (cap-bound; no manual id assert) ===

/// Step 1 (`ProposerRole`): commit the intended fee. `&pool.fee_cap` binds this to the
/// canonical timelock; `<R, Action, Params>` are all inferred from the cap and the auth.
public fun schedule_fee_change(
    timelock: &mut Timelock,
    pool: &Pool,
    proposer: &Auth<ProposerRole>,
    new_fee_bps: u16,
    predecessor: vector<u8>,
    salt: vector<u8>,
    delay_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): vector<u8> {
    timelock.schedule_with(
        &pool.fee_cap,
        proposer,
        new_fee_bps,
        predecessor,
        salt,
        delay_ms,
        clock,
        ctx,
    )
}

/// Step 2 (`ExecutorRole`), after the delay: execute -> consume -> apply, atomically in
/// one PTB. `consume` hands back the exact fee committed at schedule time.
public fun execute_fee_change(
    timelock: &mut Timelock,
    pool: &mut Pool,
    executor: &Auth<ExecutorRole>,
    id: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let ticket = timelock.execute_with(&pool.fee_cap, executor, id, clock, ctx);
    let (op_id, new_fee_bps) = timelock.consume(ticket, FeeChangeAction {});
    let previous_fee_bps = pool.fee_bps;
    pool.fee_bps = new_fee_bps;
    event::emit(FeeChanged { op_id, previous_fee_bps, new_fee_bps });
}

/// Cancel a pending fee change (`CancellerRole`).
public fun cancel_fee_change(
    timelock: &mut Timelock,
    pool: &Pool,
    canceller: &Auth<CancellerRole>,
    id: vector<u8>,
    ctx: &mut TxContext,
) {
    timelock.cancel_with(&pool.fee_cap, canceller, id, ctx)
}

// === Self-administered config change (direct timelock call; explicit id bind) ===

/// Schedule a change to the timelock's own `min_delay`. No `OperationCap` fits a config
/// change, so this binds the canonical timelock id explicitly.
public fun schedule_delay_change(
    timelock: &mut Timelock,
    pool: &Pool,
    admin: &Auth<TimelockAdminRole>,
    new_min_delay_ms: u64,
    salt: vector<u8>,
    delay_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): vector<u8> {
    assert!(object::id(timelock) == pool.timelock_id, EWrongTimelock);
    timelock.schedule_update_min_delay(
        admin,
        new_min_delay_ms,
        vector[],
        salt,
        delay_ms,
        clock,
        ctx,
    )
}

/// Apply a matured `min_delay` change.
public fun execute_delay_change(
    timelock: &mut Timelock,
    pool: &Pool,
    admin: &Auth<TimelockAdminRole>,
    id: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(object::id(timelock) == pool.timelock_id, EWrongTimelock);
    timelock.execute_update_min_delay(admin, id, clock, ctx)
}

// === View helpers ===

public fun pool_fee_bps(pool: &Pool): u16 { pool.fee_bps }

public fun pool_timelock_id(pool: &Pool): ID { pool.timelock_id }

// === Test-Only Helpers ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(EXAMPLE_AMM {}, ctx) }

#[test_only]
public fun new_fee_changed(op_id: vector<u8>, previous_fee_bps: u16, new_fee_bps: u16): FeeChanged {
    FeeChanged { op_id, previous_fee_bps, new_fee_bps }
}

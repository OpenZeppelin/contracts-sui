/// Two `Timelock`s for two operational classes, each bound by its own `OperationCap`.
///
/// A protocol often wants different delays for different risk profiles:
///
/// - **Main timelock** (24h): routine fee changes (`ProposerRole` / `ExecutorRole`).
/// - **Emergency timelock** (1h): pause / unpause, held by a single committee
///   (`EmergencyRole`).
///
/// Each operation kind gets its own `OperationCap`, minted against its own timelock at
/// `init` and stored on the `Pool`. The caps make routing **structural**: the fee-change
/// entry uses `&pool.fee_cap` (bound to MAIN) and the pause entry uses `&pool.pause_cap`
/// (bound to EMERGENCY), so passing the wrong timelock object aborts inside the library
/// with `EWrongTimelock` - no hand-written routing asserts, and no consumer-defined
/// routing error. Distinct witnesses (`FeeChangeAction` vs `EmergencyPauseAction`) keep
/// the two `consume` paths and their audit trails separate.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `timelock` primitive can be integrated. It is not production-ready and must not be
/// deployed as-is.
module openzeppelin_timelock::example_dual_governance;

use openzeppelin_access::access_control::{Self, Auth};
use openzeppelin_timelock::timelock::{Self, Timelock, OperationCap};
use sui::clock::Clock;
use sui::event;

// === Constants ===

const HOUR_MS: u64 = 60 * 60 * 1_000;
const DAY_MS: u64 = 24 * HOUR_MS;

// === Structs ===

/// One-time witness for the `AccessControl` registry.
public struct EXAMPLE_DUAL_GOVERNANCE has drop {}

/// Operation witnesses, one per class. `drop`-only; never constructed outside this module.
public struct FeeChangeAction has drop {}
public struct EmergencyPauseAction has drop {}

// === Roles ===

public struct ProposerRole {}
public struct ExecutorRole {}
public struct CancellerRole {}
public struct EmergencyRole {}

/// The protected object. Holds one `OperationCap` per op kind (each bound to its own
/// timelock), plus the timelock ids so off-chain callers / tests can fetch the right
/// shared instance.
public struct Pool has key {
    id: UID,
    fee_bps: u16,
    paused: bool,
    main_timelock_id: ID,
    emergency_timelock_id: ID,
    fee_cap: OperationCap<FeeChangeAction, u16>,
    pause_cap: OperationCap<EmergencyPauseAction, bool>,
}

public struct FeeChanged has copy, drop { op_id: vector<u8>, new_fee_bps: u16 }
public struct PauseChanged has copy, drop { op_id: vector<u8>, paused: bool }

// === Init ===

fun init(otw: EXAMPLE_DUAL_GOVERNANCE, ctx: &mut TxContext) {
    let mut ac = access_control::new(otw, 7 * DAY_MS, ctx);
    ac.set_role_admin<_, ProposerRole, EXAMPLE_DUAL_GOVERNANCE>(ctx);
    ac.set_role_admin<_, ExecutorRole, EXAMPLE_DUAL_GOVERNANCE>(ctx);
    ac.set_role_admin<_, CancellerRole, EXAMPLE_DUAL_GOVERNANCE>(ctx);
    ac.set_role_admin<_, EmergencyRole, EXAMPLE_DUAL_GOVERNANCE>(ctx);

    // Main: 24h delay, routine roles (admin slot reuses ProposerRole; self-admin unused here).
    let main_tl = timelock::new<ProposerRole, ExecutorRole, CancellerRole, ProposerRole>(
        DAY_MS,
        7 * DAY_MS,
        ctx,
    );
    let main_timelock_id = object::id(&main_tl);
    let fee_cap = main_tl.new_operation_cap<FeeChangeAction, u16>();
    main_tl.share();

    // Emergency: 1h delay, one committee holds all four role slots (intentional concentration).
    let emergency_tl = timelock::new<EmergencyRole, EmergencyRole, EmergencyRole, EmergencyRole>(
        HOUR_MS,
        DAY_MS,
        ctx,
    );
    let emergency_timelock_id = object::id(&emergency_tl);
    let pause_cap = emergency_tl.new_operation_cap<EmergencyPauseAction, bool>();
    emergency_tl.share();

    transfer::share_object(Pool {
        id: object::new(ctx),
        fee_bps: 30,
        paused: false,
        main_timelock_id,
        emergency_timelock_id,
        fee_cap,
        pause_cap,
    });
    transfer::public_share_object(ac);
}

// === Routine: fee change through the MAIN timelock (bound by fee_cap) ===

public fun schedule_fee_change(
    timelock: &mut Timelock,
    pool: &Pool,
    proposer: &Auth<ProposerRole>,
    new_fee_bps: u16,
    salt: vector<u8>,
    delay_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): vector<u8> {
    timelock.schedule_with(
        &pool.fee_cap,
        proposer,
        new_fee_bps,
        vector[],
        salt,
        delay_ms,
        clock,
        ctx,
    )
}

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
    pool.fee_bps = new_fee_bps;
    event::emit(FeeChanged { op_id, new_fee_bps });
}

// === Emergency: pause / unpause through the EMERGENCY timelock (bound by pause_cap) ===

public fun schedule_emergency_pause(
    timelock: &mut Timelock,
    pool: &Pool,
    emergency: &Auth<EmergencyRole>,
    paused: bool,
    salt: vector<u8>,
    delay_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): vector<u8> {
    timelock.schedule_with(&pool.pause_cap, emergency, paused, vector[], salt, delay_ms, clock, ctx)
}

public fun execute_emergency_pause(
    timelock: &mut Timelock,
    pool: &mut Pool,
    emergency: &Auth<EmergencyRole>,
    id: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let ticket = timelock.execute_with(&pool.pause_cap, emergency, id, clock, ctx);
    let (op_id, paused) = timelock.consume(ticket, EmergencyPauseAction {});
    pool.paused = paused;
    event::emit(PauseChanged { op_id, paused });
}

// === View helpers ===

public fun pool_fee_bps(pool: &Pool): u16 { pool.fee_bps }

public fun pool_paused(pool: &Pool): bool { pool.paused }

public fun main_timelock_id(pool: &Pool): ID { pool.main_timelock_id }

public fun emergency_timelock_id(pool: &Pool): ID { pool.emergency_timelock_id }

// === Test-Only Helpers ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(EXAMPLE_DUAL_GOVERNANCE {}, ctx) }

#[test_only]
public fun new_fee_changed(op_id: vector<u8>, new_fee_bps: u16): FeeChanged {
    FeeChanged { op_id, new_fee_bps }
}

#[test_only]
public fun new_pause_changed(op_id: vector<u8>, paused: bool): PauseChanged {
    PauseChanged { op_id, paused }
}

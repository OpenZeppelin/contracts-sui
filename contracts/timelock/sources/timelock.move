/// Hash-keyed operation timelock with typed, on-chain operation parameters and a
/// typed hot-potato execution ticket - a Sui-native take on OpenZeppelin's
/// `TimelockController`.
///
/// ### Lifecycle of a single operation
///
/// 1. A holder of the proposer role calls `schedule<R, Action, Params>`, passing the
///    actual operation parameters by value. The params are stored on-chain under a
///    dynamic field keyed by the operation id; the id is
///    `keccak256(DOMAIN_TAG || bcs(IdInput { action, payload_digest, predecessor, salt, timelock_id }))`
///    where `payload_digest = keccak256(bcs(params))`. The id is deterministic and
///    reproducible off-chain, so predecessors can be wired before the predecessor op
///    is even scheduled.
/// 2. After the per-op delay elapses and before the grace window closes, a holder of
///    the executor role calls `execute<R, Action, Params>` with the operation id
///    (returned by `schedule`) - or anyone, if `open_executor == true`, via
///    `execute_open`. This marks the op `Done`, removes the stored params, and mints
///    an `ExecutionTicket<Action, Params>` carrying those typed params. It is a
///    no-ability hot potato that must be consumed in the same PTB.
/// 3. The consumer's apply function calls `consume<Action, Params>` with a value of
///    the witness type `Action`; it returns `(op_id, params)`. The consumer applies
///    the typed params directly - no BCS, no digest, no re-supplied payload.
///
/// ### Authorization
///
/// Hard dependency on `openzeppelin_access`. Every gated entry takes `&Auth<R>` and
/// asserts `R` matches a role type bound into the `Timelock` at creation
/// (`proposer_role` / `executor_role` / `canceller_role` / `admin_role`). Role types
/// are immutable; membership is managed in the consumer's `AccessControl`. The
/// timelock defines no roles of its own; it is generic over the consumer's role types.
///
/// `min_delay_ms`, `grace_period_ms`, and `open_executor` are mutated only via the
/// self-administered pipeline (each `schedule_* / execute_*` pair, gated by
/// `admin_role`), so every configuration change is itself timelocked.
///
/// ### Consumer prerequisites (Move cannot enforce these - see invariants ASM-1..)
///
/// - **Bind the canonical Timelock.** The library cannot tell a legitimate `Timelock`
///   from an attacker-created one bound to the same role types. A consumer that takes
///   `&mut Timelock` MUST pin the canonical timelock id (e.g. store it next to the
///   protected resource and `assert!(object::id(tl) == expected)`), otherwise an actor
///   holding the relevant roles can route a self-created zero-delay timelock through
///   the consumer and bypass the delay entirely. (CPR-5.)
/// - **Witness discipline.** `Action` witness types must have only `drop`, one per
///   consume function, and their construction must never leak across the package
///   boundary (no public helper returning an `Action`). (CPR-1..3.)
/// - **Predecessor `Done` is not effect-applied.** Order each `execute -> consume -> apply`
///   triple within a PTB so a dependent op's effect runs after its predecessor's.
module openzeppelin_timelock::timelock;

use openzeppelin_access::access_control::Auth;
use std::type_name::{Self, TypeName};
use sui::bcs;
use sui::clock::Clock;
use sui::dynamic_field as df;
use sui::event;
use sui::hash;
use sui::table::{Self, Table};

// === Errors ===

/// The `&Auth<R>` role type does not match the role bound for this action.
#[error(code = 0)]
const EWrongRole: vector<u8> = "Auth role does not match the bound role for this action";

/// `min_delay_ms` or `grace_period_ms` is outside the permitted bounds.
#[error(code = 1)]
const EInvalidConfig: vector<u8> = "Delay configuration is out of bounds";

/// `schedule` called with `delay_ms` below the configured `min_delay_ms`.
#[error(code = 2)]
const EDelayTooShort: vector<u8> = "Scheduled delay is shorter than min_delay_ms";

/// An operation with this id is already scheduled.
#[error(code = 3)]
const EOperationAlreadyExists: vector<u8> = "Operation with this id already exists";

/// No operation with this id exists in the timelock.
#[error(code = 4)]
const EOperationUnset: vector<u8> = "No operation with this id exists";

/// The operation has already been executed.
#[error(code = 5)]
const EOperationAlreadyDone: vector<u8> = "Operation has already been executed";

/// The operation's delay has not elapsed yet.
#[error(code = 6)]
const EDelayNotElapsed: vector<u8> = "Operation is not yet ready for execution";

/// The operation's grace window has closed; it can no longer be executed.
#[error(code = 7)]
const EOperationExpired: vector<u8> = "Operation has expired";

/// The named predecessor is scheduled but not yet executed.
#[error(code = 8)]
const EPredecessorNotDone: vector<u8> = "Predecessor operation is not yet executed";

/// The named predecessor is not present in the timelock.
#[error(code = 9)]
const EPredecessorUnset: vector<u8> = "Predecessor operation is not in the timelock";

/// An operation cannot be its own predecessor.
#[error(code = 10)]
const EPredecessorIsSelf: vector<u8> = "Operation cannot be its own predecessor";

/// `execute_open` called while open-executor mode is disabled.
#[error(code = 11)]
const EOpenExecutorDisabled: vector<u8> = "Open-executor mode is disabled";

/// The execution ticket does not belong to this timelock.
#[error(code = 12)]
const EWrongTimelock: vector<u8> = "Ticket does not belong to this timelock";

/// Scheduling this operation would overflow the u64 deadline arithmetic (`now + delay_ms`,
/// or that sum `+ grace_period_ms`).
#[error(code = 13)]
const EScheduleOverflow: vector<u8> = "Scheduled deadline (now + delay_ms) would overflow u64";

/// The supplied `Params` type does not match the type the operation was scheduled with.
/// Reachable on either path: the raw `&Auth` path takes `Params` explicitly, and the
/// `*_with` (cap) path pins it via the `OperationCap` - but supplying a cap for a different
/// `(Action, Params)` than the op was scheduled with still mismatches.
#[error(code = 14)]
const EWrongParams: vector<u8> = "Params type does not match the operation's stored params";

// === Constants ===

/// Upper bound on the configured `min_delay_ms` and `grace_period_ms`.
/// Value: 60 days in milliseconds. Does NOT bound the per-call `delay_ms`.
const MAX_DELAY_MS: u64 = 60 * 24 * 60 * 60 * 1_000;

/// Domain separation tag, hashed into every operation id. Locked at publication.
const DOMAIN_TAG: vector<u8> = b"OZ_Timelock_1_Sui";

// === Structs ===

/// The per-protocol timelock registry. Shared object.
///
/// `key`-only (no `store`): the only legal disposition is sharing, so a `Timelock`
/// is always a shared object and can never be wrapped or address-owned (INV-3).
/// Typed operation params are stored as dynamic fields directly on `id`, keyed by
/// the operation id.
public struct Timelock has key {
    id: UID,
    min_delay_ms: u64,
    grace_period_ms: u64,
    /// op id (keccak256, 32 bytes) -> state. Absence of a key means `Unset`.
    timestamps: Table<vector<u8>, OpTimestamp>,
    open_executor: bool,
    proposer_role: TypeName,
    executor_role: TypeName,
    canceller_role: TypeName,
    admin_role: TypeName,
}

/// Stored per-operation state. Timestamps and predecessor are locked at schedule
/// time, so later `min_delay_ms` / `grace_period_ms` changes never move an existing
/// op (INV-25). The typed params live in a separate dynamic field keyed by the same id.
public enum OpTimestamp has drop, store {
    Pending { ready_at_ms: u64, expires_at_ms: u64, predecessor: vector<u8> },
    Done,
}

/// Deferred authorization for one typed operation, carrying the scheduled params.
/// Hot potato - NO abilities, so it must be consumed in the same transaction it is
/// minted (INV-1). Minted only by `execute` / `execute_open`; destroyed only by
/// `consume` (or in-module for self-admin ops).
public struct ExecutionTicket<phantom Action, Params> {
    timelock_id: ID,
    id: vector<u8>,
    params: Params,
}

/// A stored handle that binds an operation kind `(Action, Params)` to ONE `Timelock`
/// instance. Carries NO authority on its own - combine it with `&Auth<R>` for role
/// authorization. Mint one per operation kind at consumer `init` via `new_operation_cap`
/// (against your canonical timelock) and store it inside the object you protect; the
/// `*_with` entries then enforce the canonical-timelock binding for you (CPR-5), so you
/// never hand-write the `object::id` assert. `store`-only: it cannot be copied or
/// dropped, so it lives in your protected object.
public struct OperationCap<phantom Action, phantom Params> has store {
    timelock_id: ID,
}

/// BCS preimage of every operation id (INV-22). Including `timelock_id` makes
/// identical inputs hash differently across Timelock instances (INV-36).
public struct IdInput has copy, drop {
    action: TypeName,
    payload_digest: vector<u8>,
    predecessor: vector<u8>,
    salt: vector<u8>,
    timelock_id: ID,
}

/// Observable operation state, computed from `OpTimestamp` + `Clock`.
public enum OperationState has copy, drop {
    Unset,
    Waiting { ready_at_ms: u64, expires_at_ms: u64 },
    Ready { ready_at_ms: u64, expires_at_ms: u64 },
    Expired { ready_at_ms: u64, expires_at_ms: u64 },
    Done,
}

/// Module-private marker witnesses (the `Action`) for the self-administered pipeline.
/// Only this module can construct them, so only its own execute path can mint/redeem
/// the corresponding `ExecutionTicket<MarkerWitness, _>` (INV-6).
public struct UpdateMinDelayWitness has drop {}
public struct UpdateGracePeriodWitness has drop {}
public struct SetOpenExecutorWitness has drop {}

// === Events ===

public struct TimelockCreated has copy, drop {
    timelock_id: ID,
    min_delay_ms: u64,
    grace_period_ms: u64,
    proposer_role: TypeName,
    executor_role: TypeName,
    canceller_role: TypeName,
    admin_role: TypeName,
}

public struct OperationScheduled has copy, drop {
    id: vector<u8>,
    action: TypeName,
    payload_digest: vector<u8>,
    predecessor: vector<u8>,
    salt: vector<u8>,
    ready_at_ms: u64,
    expires_at_ms: u64,
    proposer: address,
}

public struct OperationExecuted has copy, drop {
    id: vector<u8>,
    action: TypeName,
    executor: address,
}

public struct OperationCancelled has copy, drop {
    id: vector<u8>,
    canceller: address,
}

public struct MinDelayChanged has copy, drop {
    previous_ms: u64,
    new_ms: u64,
}

public struct GracePeriodChanged has copy, drop {
    previous_ms: u64,
    new_ms: u64,
}

public struct OpenExecutorChanged has copy, drop {
    previous: bool,
    new: bool,
}

// === Public Functions ===

// === Construction ===

/// Mint a fresh `Timelock` bound to the four consumer role types. Returns the object
/// by value; the caller must dispose of it via `share` (or use `new_shared`).
///
/// #### Aborts
/// - `EInvalidConfig` if `min_delay_ms > MAX_DELAY_MS`, or `grace_period_ms` is zero
///   or `> MAX_DELAY_MS`.
public fun new<ProposerRole, ExecutorRole, CancellerRole, AdminRole>(
    min_delay_ms: u64,
    grace_period_ms: u64,
    ctx: &mut TxContext,
): Timelock {
    // INV-10: configuration bounds. min_delay may be 0; grace must be > 0.
    assert!(min_delay_ms <= MAX_DELAY_MS, EInvalidConfig);
    assert!(grace_period_ms > 0 && grace_period_ms <= MAX_DELAY_MS, EInvalidConfig);

    let timelock = Timelock {
        id: object::new(ctx),
        min_delay_ms,
        grace_period_ms,
        timestamps: table::new(ctx),
        open_executor: false,
        proposer_role: type_name::with_original_ids<ProposerRole>(),
        executor_role: type_name::with_original_ids<ExecutorRole>(),
        canceller_role: type_name::with_original_ids<CancellerRole>(),
        admin_role: type_name::with_original_ids<AdminRole>(),
    };

    event::emit(TimelockCreated {
        timelock_id: object::id(&timelock),
        min_delay_ms,
        grace_period_ms,
        proposer_role: timelock.proposer_role,
        executor_role: timelock.executor_role,
        canceller_role: timelock.canceller_role,
        admin_role: timelock.admin_role,
    });

    timelock
}

/// Convenience constructor that shares the `Timelock` and returns its `ID`.
public fun new_shared<ProposerRole, ExecutorRole, CancellerRole, AdminRole>(
    min_delay_ms: u64,
    grace_period_ms: u64,
    ctx: &mut TxContext,
): ID {
    let timelock = new<ProposerRole, ExecutorRole, CancellerRole, AdminRole>(
        min_delay_ms,
        grace_period_ms,
        ctx,
    );
    let id = object::id(&timelock);
    transfer::share_object(timelock);
    id
}

/// Share a `Timelock`. The only legal way to dispose of a value returned by `new`.
public fun share(self: Timelock) {
    transfer::share_object(self);
}

// === Hashing ===

/// Pure operation-id derivation from a payload digest. Off-chain tooling computes
/// `payload_digest = keccak256(bcs(params))` and reproduces the id from there.
public fun hash_operation<Action>(
    timelock_id: ID,
    payload_digest: vector<u8>,
    predecessor: vector<u8>,
    salt: vector<u8>,
): vector<u8> {
    let input = IdInput {
        action: type_name::with_original_ids<Action>(),
        payload_digest,
        predecessor,
        salt,
        timelock_id,
    };
    let mut preimage = DOMAIN_TAG;
    preimage.append(bcs::to_bytes(&input));
    hash::keccak256(&preimage)
}

// === Scheduling ===

/// Schedule an operation, storing its typed `params` on-chain. Caller must hold the
/// proposer role. Returns the operation id.
///
/// #### Aborts
/// - `EWrongRole` if `R` is not the bound `proposer_role`.
/// - `EDelayTooShort` if `delay_ms < min_delay_ms`.
/// - `EScheduleOverflow` if `now + delay_ms` (or that sum `+ grace_period_ms`) overflows u64.
/// - `EPredecessorIsSelf` if `predecessor` equals the computed id.
/// - `EOperationAlreadyExists` if the id is already scheduled.
public fun schedule<R, Action, Params: store + drop>(
    self: &mut Timelock,
    _proposer_auth: &Auth<R>,
    params: Params,
    predecessor: vector<u8>,
    salt: vector<u8>,
    delay_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): vector<u8> {
    // INV-8: role-type binding.
    assert!(type_name::with_original_ids<R>() == self.proposer_role, EWrongRole);
    schedule_internal<Action, Params>(self, params, predecessor, salt, delay_ms, clock, ctx)
}

fun schedule_internal<Action, Params: store + drop>(
    self: &mut Timelock,
    params: Params,
    predecessor: vector<u8>,
    salt: vector<u8>,
    delay_ms: u64,
    clock: &Clock,
    ctx: &TxContext,
): vector<u8> {
    // INV-9 / INV-29: delay floor.
    assert!(delay_ms >= self.min_delay_ms, EDelayTooShort);

    // Guard the deadline math against u64 overflow with a documented error. Move aborts
    // on overflow regardless; this names the failure (mirrors rate_limiter's #349).
    let now = clock.timestamp_ms();
    assert!(delay_ms <= std::u64::max_value!() - now, EScheduleOverflow);
    let ready_at_ms = now + delay_ms;
    // INV-25: grace window locked per-op at schedule time.
    assert!(self.grace_period_ms <= std::u64::max_value!() - ready_at_ms, EScheduleOverflow);
    let expires_at_ms = ready_at_ms + self.grace_period_ms;
    let timelock_id = object::id(self);
    let payload_digest = hash::keccak256(&bcs::to_bytes(&params));
    let id = hash_operation<Action>(timelock_id, payload_digest, predecessor, salt);

    // INV-12: predecessor must not be self.
    assert!(predecessor != id, EPredecessorIsSelf);
    // INV-11: id uniqueness.
    assert!(!self.timestamps.contains(id), EOperationAlreadyExists);

    self.timestamps.add(id, OpTimestamp::Pending { ready_at_ms, expires_at_ms, predecessor });
    // Store the typed params under the timelock's UID, keyed by the op id.
    df::add(&mut self.id, id, params);

    event::emit(OperationScheduled {
        id,
        action: type_name::with_original_ids<Action>(),
        payload_digest,
        predecessor,
        salt,
        ready_at_ms,
        expires_at_ms,
        proposer: ctx.sender(),
    });

    id
}

// === Execution ===

/// Execute a ready operation by id. Caller must hold the executor role. Returns a hot
/// potato carrying the scheduled `params`; it must be consumed by `consume` in the
/// same PTB.
///
/// #### Aborts
/// - `EWrongRole` if `R` is not the bound `executor_role`.
/// - `EWrongParams` if `Params` does not match the type the operation was scheduled with.
/// - `EOperationUnset`, `EOperationAlreadyDone`, `EDelayNotElapsed`,
///   `EOperationExpired`, `EPredecessorUnset`, `EPredecessorNotDone`.
public fun execute<R, Action, Params: store + drop>(
    self: &mut Timelock,
    _executor_auth: &Auth<R>,
    id: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
): ExecutionTicket<Action, Params> {
    // INV-8: role-type binding.
    assert!(type_name::with_original_ids<R>() == self.executor_role, EWrongRole);
    execute_internal<Action, Params>(self, id, clock, ctx)
}

/// Execute a ready operation in open-executor mode (no `Auth` required).
///
/// #### Aborts
/// - `EOpenExecutorDisabled` if `open_executor` is false.
/// - Plus the same operation-state aborts as `execute`.
public fun execute_open<Action, Params: store + drop>(
    self: &mut Timelock,
    id: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
): ExecutionTicket<Action, Params> {
    // INV-19: open-executor gate.
    assert!(self.open_executor, EOpenExecutorDisabled);
    execute_internal<Action, Params>(self, id, clock, ctx)
}

fun execute_internal<Action, Params: store + drop>(
    self: &mut Timelock,
    id: vector<u8>,
    clock: &Clock,
    ctx: &TxContext,
): ExecutionTicket<Action, Params> {
    let timelock_id = object::id(self);

    // INV-13: operation must exist.
    assert!(self.timestamps.contains(id), EOperationUnset);

    let now = clock.timestamp_ms();
    // INV-14: must be Pending (not Done); read the locked window + predecessor.
    let (ready_at_ms, expires_at_ms, predecessor) = match (self.timestamps.borrow(id)) {
        OpTimestamp::Done => abort EOperationAlreadyDone,
        OpTimestamp::Pending { ready_at_ms, expires_at_ms, predecessor } => (
            *ready_at_ms,
            *expires_at_ms,
            *predecessor,
        ),
    };
    // INV-15: delay elapsed. INV-16: not expired. Ready window is [ready, expires).
    assert!(now >= ready_at_ms, EDelayNotElapsed);
    assert!(now < expires_at_ms, EOperationExpired);

    // INV-17: predecessor (if any) must be Done.
    if (!predecessor.is_empty()) {
        assert!(self.timestamps.contains(predecessor), EPredecessorUnset);
        let predecessor_done = match (self.timestamps.borrow(predecessor)) {
            OpTimestamp::Done => true,
            OpTimestamp::Pending { .. } => false,
        };
        assert!(predecessor_done, EPredecessorNotDone);
    };

    // Named error if the caller supplied a `Params` type that doesn't match what the op was
    // scheduled with. On the `*_with` (cap) path the type args are pinned by the
    // `OperationCap`, so this only fires if a cap for a different `(Action, Params)` than the
    // op was scheduled with is supplied.
    assert!(df::exists_with_type<vector<u8>, Params>(&self.id, id), EWrongParams);

    // INV-24 / INV-26: mark Done (sticky, at most once) and take the stored params.
    *self.timestamps.borrow_mut(id) = OpTimestamp::Done;
    let params = df::remove<vector<u8>, Params>(&mut self.id, id);

    event::emit(OperationExecuted {
        id,
        action: type_name::with_original_ids<Action>(),
        executor: ctx.sender(),
    });

    // INV-1 / INV-2: mint the typed hot potato carrying the params.
    ExecutionTicket { timelock_id, id, params }
}

// === Ticket consumption ===

/// Redeem an execution ticket, returning `(op_id, params)`. Two gates fire:
/// timelock-binding (INV-20) and witness-by-value (INV-4 - `Action` is consumed, so
/// only a module that can construct `Action` can call this). The params are the exact
/// values committed at schedule time - there is no payload to re-supply or mismatch.
///
/// #### Aborts
/// - `EWrongTimelock` if the ticket was minted by a different `Timelock`.
public fun consume<Action: drop, Params>(
    self: &Timelock,
    ticket: ExecutionTicket<Action, Params>,
    _witness: Action,
): (vector<u8>, Params) {
    let ExecutionTicket { timelock_id, id, params } = ticket;
    // INV-20: ticket belongs to this timelock.
    assert!(timelock_id == object::id(self), EWrongTimelock);
    (id, params)
}

// === Cancellation ===

/// Cancel a scheduled operation by id, dropping its stored params. Caller must hold
/// the canceller role. Allowed on Waiting / Ready / Expired operations; not on `Done`.
/// The operation's `Params` type must be named so the stored params can be cleaned up.
///
/// #### Aborts
/// - `EWrongRole` if `R` is not the bound `canceller_role`.
/// - `EOperationUnset` if no such operation.
/// - `EOperationAlreadyDone` if the operation was already executed.
/// - `EWrongParams` if `Params` does not match the type the operation was scheduled with.
public fun cancel<R, Params: store + drop>(
    self: &mut Timelock,
    _canceller_auth: &Auth<R>,
    id: vector<u8>,
    ctx: &mut TxContext,
) {
    // INV-8: role-type binding.
    assert!(type_name::with_original_ids<R>() == self.canceller_role, EWrongRole);
    cancel_internal<Params>(self, id, ctx)
}

fun cancel_internal<Params: store + drop>(self: &mut Timelock, id: vector<u8>, ctx: &TxContext) {
    // INV-13: operation must exist.
    assert!(self.timestamps.contains(id), EOperationUnset);
    // INV-18: cannot cancel a Done operation.
    let is_done = match (self.timestamps.borrow(id)) {
        OpTimestamp::Done => true,
        OpTimestamp::Pending { .. } => false,
    };
    assert!(!is_done, EOperationAlreadyDone);
    // Named error if `Params` doesn't match the type the op was scheduled with. On the
    // `*_with` (cap) path the type args are pinned by the `OperationCap`, so this only fires
    // if a cap for a different `(Action, Params)` is supplied.
    assert!(df::exists_with_type<vector<u8>, Params>(&self.id, id), EWrongParams);

    // INV-23: Waiting/Ready/Expired -> Unset. Drop the stored params.
    let _ = self.timestamps.remove(id);
    let _params = df::remove<vector<u8>, Params>(&mut self.id, id);

    event::emit(OperationCancelled { id, canceller: ctx.sender() });
}

// === Capability-bound entries (recommended) ===
//
// These mirror schedule / execute / execute_open / cancel but take an `OperationCap`
// that binds the call to one `Timelock` instance. The library asserts the binding
// (CPR-5) so the consumer never writes it, and `Action` / `Params` infer from the cap
// (zero explicit type args at the call site). Role authorization is unchanged (`&Auth<R>`).

/// Mint an `OperationCap` binding `(Action, Params)` to this `Timelock`. Permissionless
/// and authority-free: call it once at consumer `init` against your canonical timelock
/// and store the result in the object you protect.
public fun new_operation_cap<Action, Params>(self: &Timelock): OperationCap<Action, Params> {
    OperationCap { timelock_id: object::id(self) }
}

/// The `Timelock` id an `OperationCap` is bound to.
public fun operation_cap_timelock_id<Action, Params>(cap: &OperationCap<Action, Params>): ID {
    cap.timelock_id
}

/// Like `schedule`, but the `OperationCap` enforces the canonical-timelock binding.
public fun schedule_with<R, Action, Params: store + drop>(
    self: &mut Timelock,
    cap: &OperationCap<Action, Params>,
    _proposer_auth: &Auth<R>,
    params: Params,
    predecessor: vector<u8>,
    salt: vector<u8>,
    delay_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): vector<u8> {
    assert!(cap.timelock_id == object::id(self), EWrongTimelock);
    assert!(type_name::with_original_ids<R>() == self.proposer_role, EWrongRole);
    schedule_internal<Action, Params>(self, params, predecessor, salt, delay_ms, clock, ctx)
}

/// Like `execute`, but the `OperationCap` enforces the canonical-timelock binding.
public fun execute_with<R, Action, Params: store + drop>(
    self: &mut Timelock,
    cap: &OperationCap<Action, Params>,
    _executor_auth: &Auth<R>,
    id: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
): ExecutionTicket<Action, Params> {
    assert!(cap.timelock_id == object::id(self), EWrongTimelock);
    assert!(type_name::with_original_ids<R>() == self.executor_role, EWrongRole);
    execute_internal<Action, Params>(self, id, clock, ctx)
}

/// Like `execute_open`, but the `OperationCap` enforces the canonical-timelock binding.
public fun execute_open_with<Action, Params: store + drop>(
    self: &mut Timelock,
    cap: &OperationCap<Action, Params>,
    id: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
): ExecutionTicket<Action, Params> {
    assert!(cap.timelock_id == object::id(self), EWrongTimelock);
    assert!(self.open_executor, EOpenExecutorDisabled);
    execute_internal<Action, Params>(self, id, clock, ctx)
}

/// Like `cancel`, but the `OperationCap` enforces the canonical-timelock binding.
public fun cancel_with<R, Action, Params: store + drop>(
    self: &mut Timelock,
    cap: &OperationCap<Action, Params>,
    _canceller_auth: &Auth<R>,
    id: vector<u8>,
    ctx: &mut TxContext,
) {
    assert!(cap.timelock_id == object::id(self), EWrongTimelock);
    assert!(type_name::with_original_ids<R>() == self.canceller_role, EWrongRole);
    cancel_internal<Params>(self, id, ctx)
}

// === Self-administered configuration ===

/// Schedule a `min_delay_ms` change (stored as the operation's params). Admin-gated.
public fun schedule_update_min_delay<R>(
    self: &mut Timelock,
    _admin_auth: &Auth<R>,
    new_min_delay_ms: u64,
    predecessor: vector<u8>,
    salt: vector<u8>,
    delay_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): vector<u8> {
    assert!(type_name::with_original_ids<R>() == self.admin_role, EWrongRole);
    assert!(new_min_delay_ms <= MAX_DELAY_MS, EInvalidConfig);
    schedule_internal<UpdateMinDelayWitness, u64>(
        self,
        new_min_delay_ms,
        predecessor,
        salt,
        delay_ms,
        clock,
        ctx,
    )
}

/// Execute a scheduled `min_delay_ms` change by id. Admin-gated. Applies the stored value.
public fun execute_update_min_delay<R>(
    self: &mut Timelock,
    _admin_auth: &Auth<R>,
    id: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(type_name::with_original_ids<R>() == self.admin_role, EWrongRole);
    let ticket = execute_internal<UpdateMinDelayWitness, u64>(self, id, clock, ctx);
    // INV-6: marker witness home - consume the ticket in-module, taking the stored value.
    let ExecutionTicket { timelock_id: _, id: _, params: new_min_delay_ms } = ticket;

    let previous_ms = self.min_delay_ms;
    self.min_delay_ms = new_min_delay_ms;
    event::emit(MinDelayChanged { previous_ms, new_ms: new_min_delay_ms });
}

/// Schedule a `grace_period_ms` change. Admin-gated.
public fun schedule_update_grace_period<R>(
    self: &mut Timelock,
    _admin_auth: &Auth<R>,
    new_grace_period_ms: u64,
    predecessor: vector<u8>,
    salt: vector<u8>,
    delay_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): vector<u8> {
    assert!(type_name::with_original_ids<R>() == self.admin_role, EWrongRole);
    assert!(new_grace_period_ms > 0 && new_grace_period_ms <= MAX_DELAY_MS, EInvalidConfig);
    schedule_internal<UpdateGracePeriodWitness, u64>(
        self,
        new_grace_period_ms,
        predecessor,
        salt,
        delay_ms,
        clock,
        ctx,
    )
}

/// Execute a scheduled `grace_period_ms` change by id. Admin-gated.
public fun execute_update_grace_period<R>(
    self: &mut Timelock,
    _admin_auth: &Auth<R>,
    id: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(type_name::with_original_ids<R>() == self.admin_role, EWrongRole);
    let ticket = execute_internal<UpdateGracePeriodWitness, u64>(self, id, clock, ctx);
    let ExecutionTicket { timelock_id: _, id: _, params: new_grace_period_ms } = ticket;

    let previous_ms = self.grace_period_ms;
    self.grace_period_ms = new_grace_period_ms;
    event::emit(GracePeriodChanged { previous_ms, new_ms: new_grace_period_ms });
}

/// Schedule an `open_executor` toggle. Admin-gated.
public fun schedule_set_open_executor<R>(
    self: &mut Timelock,
    _admin_auth: &Auth<R>,
    value: bool,
    predecessor: vector<u8>,
    salt: vector<u8>,
    delay_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): vector<u8> {
    assert!(type_name::with_original_ids<R>() == self.admin_role, EWrongRole);
    schedule_internal<SetOpenExecutorWitness, bool>(
        self,
        value,
        predecessor,
        salt,
        delay_ms,
        clock,
        ctx,
    )
}

/// Execute a scheduled `open_executor` toggle by id. Admin-gated.
public fun execute_set_open_executor<R>(
    self: &mut Timelock,
    _admin_auth: &Auth<R>,
    id: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(type_name::with_original_ids<R>() == self.admin_role, EWrongRole);
    let ticket = execute_internal<SetOpenExecutorWitness, bool>(self, id, clock, ctx);
    let ExecutionTicket { timelock_id: _, id: _, params: value } = ticket;

    let previous = self.open_executor;
    self.open_executor = value;
    event::emit(OpenExecutorChanged { previous, new: value });
}

// === View helpers ===

public fun min_delay_ms(self: &Timelock): u64 { self.min_delay_ms }

public fun grace_period_ms(self: &Timelock): u64 { self.grace_period_ms }

public fun is_open_executor(self: &Timelock): bool { self.open_executor }

public fun max_delay_ms(): u64 { MAX_DELAY_MS }

public fun proposer_role(self: &Timelock): TypeName { self.proposer_role }

public fun executor_role(self: &Timelock): TypeName { self.executor_role }

public fun canceller_role(self: &Timelock): TypeName { self.canceller_role }

public fun admin_role(self: &Timelock): TypeName { self.admin_role }

public fun is_operation(self: &Timelock, id: vector<u8>): bool {
    self.timestamps.contains(id)
}

public fun is_operation_pending(self: &Timelock, id: vector<u8>, clock: &Clock): bool {
    match (self.op_state(id, clock.timestamp_ms())) {
        OperationState::Waiting { .. } => true,
        OperationState::Ready { .. } => true,
        _ => false,
    }
}

public fun is_operation_ready(self: &Timelock, id: vector<u8>, clock: &Clock): bool {
    match (self.op_state(id, clock.timestamp_ms())) {
        OperationState::Ready { .. } => true,
        _ => false,
    }
}

public fun is_operation_expired(self: &Timelock, id: vector<u8>, clock: &Clock): bool {
    match (self.op_state(id, clock.timestamp_ms())) {
        OperationState::Expired { .. } => true,
        _ => false,
    }
}

public fun is_operation_done(self: &Timelock, id: vector<u8>): bool {
    if (!self.timestamps.contains(id)) return false;
    match (self.timestamps.borrow(id)) {
        OpTimestamp::Done => true,
        OpTimestamp::Pending { .. } => false,
    }
}

public fun operation_state(self: &Timelock, id: vector<u8>, clock: &Clock): OperationState {
    self.op_state(id, clock.timestamp_ms())
}

/// Borrow the typed params of a pending operation (for off-chain inspection / UIs).
/// Aborts if the id has no stored params (Unset or already Done).
public fun operation_params<Params: store>(self: &Timelock, id: vector<u8>): &Params {
    df::borrow<vector<u8>, Params>(&self.id, id)
}

// === Private Functions ===

/// Compute the observable state of an operation at time `now`.
fun op_state(self: &Timelock, id: vector<u8>, now: u64): OperationState {
    if (!self.timestamps.contains(id)) return OperationState::Unset;
    match (self.timestamps.borrow(id)) {
        OpTimestamp::Done => OperationState::Done,
        OpTimestamp::Pending { ready_at_ms, expires_at_ms, predecessor: _ } => {
            let ready_at_ms = *ready_at_ms;
            let expires_at_ms = *expires_at_ms;
            if (now < ready_at_ms) {
                OperationState::Waiting { ready_at_ms, expires_at_ms }
            } else if (now < expires_at_ms) {
                OperationState::Ready { ready_at_ms, expires_at_ms }
            } else {
                OperationState::Expired { ready_at_ms, expires_at_ms }
            }
        },
    }
}

// === Test-Only Helpers ===

#[test_only]
public fun test_new_timelock_created(
    timelock_id: ID,
    min_delay_ms: u64,
    grace_period_ms: u64,
    proposer_role: TypeName,
    executor_role: TypeName,
    canceller_role: TypeName,
    admin_role: TypeName,
): TimelockCreated {
    TimelockCreated {
        timelock_id,
        min_delay_ms,
        grace_period_ms,
        proposer_role,
        executor_role,
        canceller_role,
        admin_role,
    }
}

#[test_only]
public fun test_new_operation_scheduled(
    id: vector<u8>,
    action: TypeName,
    payload_digest: vector<u8>,
    predecessor: vector<u8>,
    salt: vector<u8>,
    ready_at_ms: u64,
    expires_at_ms: u64,
    proposer: address,
): OperationScheduled {
    OperationScheduled {
        id,
        action,
        payload_digest,
        predecessor,
        salt,
        ready_at_ms,
        expires_at_ms,
        proposer,
    }
}

#[test_only]
public fun test_new_operation_executed(
    id: vector<u8>,
    action: TypeName,
    executor: address,
): OperationExecuted {
    OperationExecuted { id, action, executor }
}

#[test_only]
public fun test_new_operation_cancelled(id: vector<u8>, canceller: address): OperationCancelled {
    OperationCancelled { id, canceller }
}

#[test_only]
public fun test_new_min_delay_changed(previous_ms: u64, new_ms: u64): MinDelayChanged {
    MinDelayChanged { previous_ms, new_ms }
}

#[test_only]
public fun test_new_grace_period_changed(previous_ms: u64, new_ms: u64): GracePeriodChanged {
    GracePeriodChanged { previous_ms, new_ms }
}

#[test_only]
public fun test_new_open_executor_changed(previous: bool, new: bool): OpenExecutorChanged {
    OpenExecutorChanged { previous, new }
}

#[test_only]
public fun test_operation_state_unset(): OperationState { OperationState::Unset }

#[test_only]
public fun test_operation_state_waiting(ready_at_ms: u64, expires_at_ms: u64): OperationState {
    OperationState::Waiting { ready_at_ms, expires_at_ms }
}

#[test_only]
public fun test_operation_state_ready(ready_at_ms: u64, expires_at_ms: u64): OperationState {
    OperationState::Ready { ready_at_ms, expires_at_ms }
}

#[test_only]
public fun test_operation_state_expired(ready_at_ms: u64, expires_at_ms: u64): OperationState {
    OperationState::Expired { ready_at_ms, expires_at_ms }
}

#[test_only]
public fun test_operation_state_done(): OperationState { OperationState::Done }

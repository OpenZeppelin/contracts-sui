/// Time-locked wrapper that enforces a configurable delay between scheduling and executing
/// the transfer of an object.
///
/// Works with any `T: key + store` object, but the primary use case is wrapping capabilities
/// (admin caps, treasury caps, etc.) where an immediate, unannounced transfer could be risky.
///
/// Owners wrap the object and must queue a transfer via the scheduling helpers.
/// After scheduling, the owner must wait for the deadline to pass before executing,
/// guaranteeing an on-chain lead time for sensitive transfers.
///
/// Unwrapping follows the same delayed pattern, ensuring the object cannot be reclaimed
/// without respecting the delay period.
module openzeppelin_access::delayed_transfer;

use sui::clock::Clock;
use sui::dynamic_object_field as dof;
use sui::event;

/// Dynamic field key for a wrapped object.
public struct WrappedKey() has copy, drop, store;

/// A transfer or unwrap is already scheduled and must be executed or cancelled first.
#[error(code = 0)]
const ETransferAlreadyScheduled: vector<u8> = "Transfer already scheduled.";
/// No pending transfer/unwrap exists for the wrapper.
#[error(code = 1)]
const ENoPendingTransfer: vector<u8> = "No pending transfer.";
/// The configured delay has not elapsed yet.
#[error(code = 2)]
const EDelayNotElapsed: vector<u8> = "Delay has not elapsed.";
/// A transfer action was attempted when an unwrap was scheduled, or vice versa.
#[error(code = 3)]
const EWrongPendingAction: vector<u8> = "Pending action mismatch.";
/// Borrow return was attempted against a different `DelayedTransferWrapper`.
#[error(code = 4)]
const EWrongDelayedTransferWrapper: vector<u8> = "Wrong delayed transfer wrapper.";
/// Borrow return was attempted with a different wrapped object than the one originally taken.
#[error(code = 5)]
const EWrongDelayedTransferObject: vector<u8> = "Wrong delayed transfer object.";

/// Wrapper object that delays transfers by at least `min_delay_ms` after scheduling.
public struct DelayedTransferWrapper<phantom T: key + store> has key {
    id: UID,
    min_delay_ms: u64,
    pending: Option<PendingTransfer>,
}

/// Snapshot of a scheduled transfer or unwrap, including the execution time.
/// A non-existing recipient means an unwrap is scheduled.
public struct PendingTransfer has drop, store {
    recipient: Option<address>,
    execute_after_ms: u64,
}

/// Hot potato to ensure a wrapped object was returned after being taken using
/// the `borrow_val` call.
public struct Borrow { wrapper_id: ID, object_id: ID }

// === Events ===

/// Emitted whenever an object is wrapped in `DelayedTransferWrapper`.
public struct WrapExecuted<phantom T> has copy, drop {
    wrapper_id: ID,
    object_id: ID,
    owner: address,
}

/// Emitted when a delayed transfer is scheduled.
public struct TransferScheduled<phantom T> has copy, drop {
    wrapper_id: ID,
    current_owner: address,
    new_owner: address,
    execute_after_ms: u64,
}

/// Emitted when an unwrap is scheduled.
public struct UnwrapScheduled<phantom T> has copy, drop {
    wrapper_id: ID,
    current_owner: address,
    execute_after_ms: u64,
}

/// Emitted when a delayed transfer is executed.
public struct OwnershipTransferred<phantom T> has copy, drop {
    wrapper_id: ID,
    previous_owner: address,
    new_owner: address,
}

/// Emitted when a scheduled transfer or unwrap is cancelled.
public struct PendingTransferCancelled<phantom T> has copy, drop {
    wrapper_id: ID,
}

/// Emitted when a scheduled unwrap is executed.
public struct UnwrapExecuted<phantom T> has copy, drop {
    wrapper_id: ID,
    object_id: ID,
    owner: address,
}

// === Wrap / unwrap / borrow ===

/// Wrap an object in a delayed transfer wrapper with the desired minimum delay. The object is
/// tucked under a dynamic field so its ID remains discoverable.
public fun wrap<T: key + store>(
    obj: T,
    min_delay_ms: u64,
    ctx: &mut TxContext,
): DelayedTransferWrapper<T> {
    let mut wrapper = DelayedTransferWrapper {
        id: object::new(ctx),
        min_delay_ms,
        pending: option::none(),
    };
    event::emit(WrapExecuted<T> {
        wrapper_id: object::id(&wrapper),
        object_id: object::id(&obj),
        owner: ctx.sender(),
    });
    dof::add(&mut wrapper.id, WrappedKey(), obj);
    wrapper
}

/// Borrow the wrapped object immutably—useful for inspection without touching the schedule.
public fun borrow<T: key + store>(self: &DelayedTransferWrapper<T>): &T {
    dof::borrow(&self.id, WrappedKey())
}

/// Borrow the wrapped object mutably when internal state needs to be tweaked without editing the
/// pending schedule.
public fun borrow_mut<T: key + store>(self: &mut DelayedTransferWrapper<T>): &mut T {
    dof::borrow_mut(&mut self.id, WrappedKey())
}

/// Take the wrapped object from the `DelayedTransferWrapper` with a guarantee that it will be returned.
public fun borrow_val<T: key + store>(self: &mut DelayedTransferWrapper<T>): (T, Borrow) {
    let obj = dof::remove(&mut self.id, WrappedKey());
    let object_id = object::id(&obj);
    (obj, Borrow { wrapper_id: object::id(self), object_id })
}

/// Return the borrowed object to the `DelayedTransferWrapper`. This method cannot be avoided
/// if `borrow_val` is used.
public fun return_val<T: key + store>(
    self: &mut DelayedTransferWrapper<T>,
    obj: T,
    borrow: Borrow,
) {
    let Borrow { wrapper_id, object_id } = borrow;

    assert!(object::id(self) == wrapper_id, EWrongDelayedTransferWrapper);
    assert!(object::id(&obj) == object_id, EWrongDelayedTransferObject);

    dof::add(&mut self.id, WrappedKey(), obj);
}

// === Scheduling / delay management ===

/// Schedule a new transfer to `new_owner`. Stores recipient + deadline; caller later invokes
/// `execute_transfer` after `min_delay_ms` has passed.
public fun schedule_transfer<T: key + store>(
    self: &mut DelayedTransferWrapper<T>,
    new_owner: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(self.pending.is_none(), ETransferAlreadyScheduled);
    let execute_after = clock.timestamp_ms() + self.min_delay_ms;
    option::fill(
        &mut self.pending,
        PendingTransfer {
            recipient: option::some(new_owner),
            execute_after_ms: execute_after,
        },
    );
    event::emit(TransferScheduled<T> {
        wrapper_id: object::id(self),
        current_owner: ctx.sender(),
        new_owner,
        execute_after_ms: execute_after,
    });
}

/// Schedule an unwrap (self-recovery). After the delay, call `unwrap` to retrieve the object and
/// delete the wrapper.
public fun schedule_unwrap<T: key + store>(
    self: &mut DelayedTransferWrapper<T>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(self.pending.is_none(), ETransferAlreadyScheduled);
    let execute_after = clock.timestamp_ms() + self.min_delay_ms;
    option::fill(
        &mut self.pending,
        PendingTransfer {
            recipient: option::none(),
            execute_after_ms: execute_after,
        },
    );
    event::emit(UnwrapScheduled<T> {
        wrapper_id: object::id(self),
        current_owner: ctx.sender(),
        execute_after_ms: execute_after,
    });
}

// === Execution / cancellation ===

/// Execute the pending transfer once the configured delay has elapsed, consuming the wrapper and
/// emitting an `OwnershipTransferred` event.
public fun execute_transfer<T: key + store>(
    mut self: DelayedTransferWrapper<T>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let pending = self.pending.extract_or!(abort ENoPendingTransfer);
    let PendingTransfer { mut recipient, execute_after_ms } = pending;
    let recipient = recipient.extract_or!(abort EWrongPendingAction);

    let now = clock.timestamp_ms();
    assert!(now >= execute_after_ms, EDelayNotElapsed);
    event::emit(OwnershipTransferred<T> {
        wrapper_id: object::id(&self),
        previous_owner: ctx.sender(),
        new_owner: recipient,
    });
    transfer::transfer(self, recipient);
}

/// Complete a previously scheduled unwrap after the delay—return the object and delete the wrapper
/// so the owner regains full control.
public fun unwrap<T: key + store>(
    mut self: DelayedTransferWrapper<T>,
    clock: &Clock,
    ctx: &mut TxContext,
): T {
    let pending = self.pending.extract_or!(abort ENoPendingTransfer);

    let PendingTransfer { recipient, execute_after_ms } = pending;
    assert!(recipient.is_none(), EWrongPendingAction);

    let now = clock.timestamp_ms();
    assert!(now >= execute_after_ms, EDelayNotElapsed);

    let DelayedTransferWrapper { id: mut wrapper_id, .. } = self;
    let obj = dof::remove(&mut wrapper_id, WrappedKey());

    event::emit(UnwrapExecuted<T> {
        wrapper_id: wrapper_id.uid_to_inner(),
        object_id: object::id(&obj),
        owner: ctx.sender(),
    });

    wrapper_id.delete();
    obj
}

/// Cancel the currently scheduled transfer or unwrap operation.
///
/// Aborts with `ENoPendingTransfer` when no operation is currently scheduled.
public fun cancel_schedule<T: key + store>(self: &mut DelayedTransferWrapper<T>) {
    let PendingTransfer { .. } = self.pending.extract_or!(abort ENoPendingTransfer);
    event::emit(PendingTransferCancelled<T> { wrapper_id: object::id(self) });
}

#[test_only]
public fun test_new_wrap_executed<T>(
    wrapper_id: ID,
    object_id: ID,
    owner: address,
): WrapExecuted<T> {
    WrapExecuted { wrapper_id, object_id, owner }
}

#[test_only]
public fun test_new_pending_transfer_cancelled<T>(wrapper_id: ID): PendingTransferCancelled<T> {
    PendingTransferCancelled { wrapper_id }
}

#[test_only]
public fun test_new_unwrap_executed<T>(wrapper_id: ID, object_id: ID, owner: address): UnwrapExecuted<T> {
    UnwrapExecuted { wrapper_id, object_id, owner }
}

/// Time-locked wrapper that enforces a configurable delay between scheduling and executing
/// the transfer of a capability/object.
///
/// Owners wrap the capability and must queue a transfer via the scheduling helpers.
/// After scheduling, the owner must wait for the deadline to pass before executing,
/// guaranteeing an on-chain lead time for sensitive capability moves.
///
/// Unwrapping follows the same delayed pattern, ensuring the capability cannot be reclaimed
/// without respecting the delay period.
module openzeppelin_access::delayed_transfer;

use sui::clock::Clock;
use sui::dynamic_object_field as dof;
use sui::event;

/// Dynamic field key for a wrapped object.
public struct WrappedKey() has copy, drop, store;

#[error(code = 0)]
const ETransferAlreadyScheduled: vector<u8> = b"Transfer already scheduled.";
#[error(code = 1)]
const ENoPendingTransfer: vector<u8> = b"No pending transfer.";
#[error(code = 2)]
const EDelayNotElapsed: vector<u8> = b"Delay has not elapsed.";
#[error(code = 3)]
const EWrongPendingAction: vector<u8> = b"Pending action mismatch.";
#[error(code = 4)]
const EWrongDelayedTransferWrapper: vector<u8> = b"Wrong delayed transfer wrapper.";
#[error(code = 5)]
const EWrongDelayedTransferObject: vector<u8> = b"Wrong delayed transfer object.";

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

/// Emitted when a delayed transfer is scheduled.
public struct TransferScheduled has copy, drop {
    wrapper_id: ID,
    current_owner: address,
    new_owner: address,
    execute_after_ms: u64,
}

/// Emitted when an unwrap is scheduled.
public struct UnwrapScheduled has copy, drop {
    wrapper_id: ID,
    current_owner: address,
    execute_after_ms: u64,
}

/// Emitted when a delayed transfer is executed.
public struct OwnershipTransferred has copy, drop {
    wrapper_id: ID,
    previous_owner: address,
    new_owner: address,
}

// === Wrap / unwrap / borrow ===

/// Wrap a capability/object in a delayed transfer wrapper with the desired minimum delay. The
/// capability is tucked under a dynamic field so its object ID remains discoverable.
public fun wrap<T: key + store>(
    cap: T,
    min_delay_ms: u64,
    ctx: &mut TxContext,
): DelayedTransferWrapper<T> {
    let mut wrapper = DelayedTransferWrapper {
        id: object::new(ctx),
        min_delay_ms,
        pending: option::none(),
    };
    dof::add(&mut wrapper.id, WrappedKey(), cap);
    wrapper
}

/// Borrow the wrapped capability immutably—useful for inspection without touching the schedule.
public fun borrow<T: key + store>(self: &DelayedTransferWrapper<T>): &T {
    dof::borrow(&self.id, WrappedKey())
}

/// Borrow the wrapped capability mutably when internal state needs to be tweaked without editing
/// the pending schedule.
public fun borrow_mut<T: key + store>(self: &mut DelayedTransferWrapper<T>): &mut T {
    dof::borrow_mut(&mut self.id, WrappedKey())
}

/// Take the wrapped capability from the `DelayedTransferWrapper` with a guarantee that it will be returned.
public fun borrow_val<T: key + store>(self: &mut DelayedTransferWrapper<T>): (T, Borrow) {
    let cap = dof::remove(&mut self.id, WrappedKey());
    let object_id = object::id(&cap);
    (cap, Borrow { wrapper_id: object::id(self), object_id })
}

/// Return the borrowed capability to the `DelayedTransferWrapper`. This method cannot be avoided
/// if `borrow_val` is used.
public fun return_val<T: key + store>(
    self: &mut DelayedTransferWrapper<T>,
    capability: T,
    borrow: Borrow,
) {
    let Borrow { wrapper_id, object_id } = borrow;

    assert!(object::id(self) == wrapper_id, EWrongDelayedTransferWrapper);
    assert!(object::id(&capability) == object_id, EWrongDelayedTransferObject);

    dof::add(&mut self.id, WrappedKey(), capability);
}

// === Scheduling / delay management ===

/// Schedule a new transfer to `new_owner`. Stores recipient + deadline; caller later invokes
/// `execute_transfer` after `min_delay_ms` has passed.
public fun schedule_transfer<T: key + store>(
    self: &mut DelayedTransferWrapper<T>,
    new_owner: address,
    clock: &Clock,
    current_owner: address,
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
    let wrapper_id = object::id(self);
    event::emit(TransferScheduled {
        wrapper_id,
        current_owner,
        new_owner,
        execute_after_ms: execute_after,
    });
}

/// Schedule an unwrap (self-recovery). After the delay, call `unwrap` to retrieve the capability
/// and delete the wrapper.
public fun schedule_unwrap<T: key + store>(
    self: &mut DelayedTransferWrapper<T>,
    clock: &Clock,
    current_owner: address,
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
    event::emit(UnwrapScheduled {
        wrapper_id: object::id(self),
        current_owner,
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
    event::emit(OwnershipTransferred {
        wrapper_id: object::id(&self),
        previous_owner: ctx.sender(),
        new_owner: recipient,
    });
    transfer::transfer(self, recipient);
}

/// Complete a previously scheduled unwrap after the delay—return the capability and delete the
/// wrapper so the owner regains full control.
public fun unwrap<T: key + store>(
    mut self: DelayedTransferWrapper<T>,
    clock: &Clock,
    ctx: &mut TxContext,
): T {
    let pending = self.pending.extract_or!(abort ENoPendingTransfer);

    let PendingTransfer { recipient, execute_after_ms } = pending;
    assert!(recipient.is_none(), EWrongPendingAction);

    // The recipient must be none for an unwrap.
    recipient.destroy_none();

    let now = clock.timestamp_ms();
    assert!(now >= execute_after_ms, EDelayNotElapsed);

    event::emit(OwnershipTransferred {
        wrapper_id: object::id(&self),
        previous_owner: ctx.sender(),
        new_owner: ctx.sender(),
    });

    let DelayedTransferWrapper { id: mut wrapper_id, .. } = self;
    let cap = dof::remove(&mut wrapper_id, WrappedKey());
    wrapper_id.delete();
    cap
}

/// Cancel the currently scheduled transfer or unwrap operation, if any.
public fun cancel_schedule<T: key + store>(self: &mut DelayedTransferWrapper<T>) {
    let PendingTransfer { .. } = self.pending.extract_or!(abort ENoPendingTransfer);
}

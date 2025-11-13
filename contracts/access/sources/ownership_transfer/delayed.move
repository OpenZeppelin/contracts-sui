/// Time-locked wrapper that enforces a configurable delay between scheduling and executing
/// the transfer of a capability.
///
/// Owners wrap the capability and must queue a transfer via the scheduling helpers.
/// After scheduling, the owner must wait for the deadline to pass before executing,
/// guaranteeing an on-chain lead time for sensitive capability moves.
///
/// Unwrapping follows the same delayed pattern, ensuring the capability cannot be reclaimed
/// without respecting the delay period.
module openzeppelin_access::delayed_transfer;

use sui::clock;
use sui::dynamic_object_field as dof;
use sui::event;

const WRAPPED_FIELD: vector<u8> = b"wrapped";

#[error(code = 0)]
const ETransferAlreadyScheduled: vector<u8> = b"Transfer already scheduled.";
#[error(code = 1)]
const ENoPendingTransfer: vector<u8> = b"No pending transfer.";
#[error(code = 2)]
const EDelayNotElapsed: vector<u8> = b"Delay has not elapsed.";
#[error(code = 3)]
const EWrongPendingAction: vector<u8> = b"Pending action mismatch.";

/// Wrapper object that delays transfers by at least `min_delay_ms` after scheduling.
public struct DelayedTransferWrapper<phantom T: key + store> has key {
    id: UID,
    min_delay_ms: u64,
    pending: option::Option<PendingTransfer>,
}

/// Snapshot of a scheduled transfer or unwrap, including the execution time.
/// A non-existing recipient means an unwrap is scheduled.
public struct PendingTransfer has drop, store {
    recipient: option::Option<address>,
    execute_after_ms: u64,
}

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
    dof::add(&mut wrapper.id, WRAPPED_FIELD, cap);
    wrapper
}

/// Borrow the wrapped capability immutably—useful for inspection without touching the schedule.
public fun borrow<T: key + store>(wrapper: &DelayedTransferWrapper<T>): &T {
    dof::borrow(&wrapper.id, WRAPPED_FIELD)
}

/// Borrow the wrapped capability mutably when internal state needs to be tweaked without editing
/// the pending schedule.
public fun borrow_mut<T: key + store>(wrapper: &mut DelayedTransferWrapper<T>): &mut T {
    dof::borrow_mut(&mut wrapper.id, WRAPPED_FIELD)
}

// === Scheduling / delay management ===

/// Schedule a new transfer to `new_owner`. Stores recipient + deadline; caller later invokes
/// `execute_transfer` after `min_delay_ms` has passed.
public fun schedule_transfer<T: key + store>(
    wrapper: &mut DelayedTransferWrapper<T>,
    new_owner: address,
    clock: &clock::Clock,
    current_owner: address,
) {
    assert!(option::is_none(&wrapper.pending), ETransferAlreadyScheduled);
    let execute_after = clock::timestamp_ms(clock) + wrapper.min_delay_ms;
    option::fill(
        &mut wrapper.pending,
        PendingTransfer {
            recipient: option::some(new_owner),
            execute_after_ms: execute_after,
        },
    );
    let wrapper_id = object::id(wrapper);
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
    wrapper: &mut DelayedTransferWrapper<T>,
    clock: &clock::Clock,
    current_owner: address,
) {
    assert!(option::is_none(&wrapper.pending), ETransferAlreadyScheduled);
    let execute_after = clock::timestamp_ms(clock) + wrapper.min_delay_ms;
    option::fill(
        &mut wrapper.pending,
        PendingTransfer {
            recipient: option::none(),
            execute_after_ms: execute_after,
        },
    );
    event::emit(UnwrapScheduled {
        wrapper_id: object::id(wrapper),
        current_owner,
        execute_after_ms: execute_after,
    });
}

// === Execution / cancellation ===

/// Execute the pending transfer once the configured delay has elapsed, consuming the wrapper and
/// emitting an `OwnershipTransferred` event.
public fun execute_transfer<T: key + store>(
    mut wrapper: DelayedTransferWrapper<T>,
    clock: &clock::Clock,
    ctx: &mut TxContext,
) {
    let pending = if (option::is_some(&wrapper.pending)) {
        option::extract(&mut wrapper.pending)
    } else {
        abort ENoPendingTransfer
    };
    let PendingTransfer { mut recipient, execute_after_ms } = pending;
    let recipient = if (option::is_some(&recipient)) {
        option::extract(&mut recipient)
    } else {
        abort EWrongPendingAction
    };
    let now = clock::timestamp_ms(clock);
    assert!(now >= execute_after_ms, EDelayNotElapsed);
    event::emit(OwnershipTransferred {
        wrapper_id: object::id(&wrapper),
        previous_owner: ctx.sender(),
        new_owner: recipient,
    });
    transfer::transfer(wrapper, recipient);
}

/// Complete a previously scheduled unwrap after the delay—return the capability and delete the
/// wrapper so the owner regains full control.
public fun unwrap<T: key + store>(
    mut wrapper: DelayedTransferWrapper<T>,
    clock: &clock::Clock,
    ctx: &mut TxContext,
): T {
    let pending = if (option::is_some(&wrapper.pending)) {
        option::extract(&mut wrapper.pending)
    } else {
        abort ENoPendingTransfer
    };

    let PendingTransfer { recipient, execute_after_ms } = pending;
    assert!(option::is_none(&recipient), EWrongPendingAction);

    // The recipient must be none for an unwrap.
    option::destroy_none(recipient);

    let now = clock::timestamp_ms(clock);
    assert!(now >= execute_after_ms, EDelayNotElapsed);

    event::emit(OwnershipTransferred {
        wrapper_id: object::id(&wrapper),
        previous_owner: ctx.sender(),
        new_owner: ctx.sender(),
    });

    let DelayedTransferWrapper { id: mut wrapper_id, min_delay_ms: _, pending: _ } = wrapper;
    let cap = dof::remove(&mut wrapper_id, WRAPPED_FIELD);
    object::delete(wrapper_id);
    cap
}

/// Cancel the currently scheduled transfer or unwrap operation, if any.
public fun cancel<T: key + store>(wrapper: &mut DelayedTransferWrapper<T>) {
    if (option::is_some(&wrapper.pending)) {
        let PendingTransfer { recipient: _, execute_after_ms: _ } = option::extract(
            &mut wrapper.pending,
        );
    } else {
        abort ENoPendingTransfer
    }
}

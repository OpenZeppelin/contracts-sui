/// Two-step wrapper that keeps a capability or object accessible behind a wrapper, while enforcing
/// a request -> approval flow for transfers.
///
/// Callers first `wrap` their capability. Prospective owners then issue `request_ownership`, and
/// the current owner finalises the handoff with `transfer`. A direct `unwrap` path is provided for
/// situations where the owner wants to reclaim the underlying capability locally.
///
/// This deliberate two-step process helps avoid mistakenly transferring the capability or object to
/// the wrong recipient, a mistake which could result in the cap being irreversibly locked away due
/// to human error.
///
/// By requiring explicit request and approval of each transfer, the flow provides an important safety
/// net against accidental misdirection.
module openzeppelin_access::two_step_transfer;

use sui::dynamic_object_field as dof;
use sui::event;

public struct WrappedKey() has copy, drop, store;

/// Transfer request does not correspond to the provided wrapper
#[error(code = 1)]
const EInvalidTransferRequest: vector<u8> = b"Transfer request does not match wrapper.";
#[error(code = 2)]
const EWrongTwoStepTransferWrapper: vector<u8> = b"Wrong two step transfer wrapper.";
#[error(code = 3)]
const EWrongTwoStepTransferObject: vector<u8> = b"Wrong two step transfer object.";

/// Wrapper object that owns the underlying capability, stored as a dynamic object field.
///
/// The wrapper intentionally omits the `store` ability so only this module can transfer it via
/// `transfer::transfer`.
public struct TwoStepTransferWrapper<phantom T: key + store> has key {
    id: UID,
}

/// Capability handed to the current owner when a prospective owner requests control of the wrapper.
public struct OwnershipTransferRequest<phantom T> has key {
    id: UID,
    wrapper_id: ID,
    new_owner: address,
}

/// Hot potato to ensure a wrapped object was returned after being taken using
/// the `borrow_val` call.
public struct Borrow { wrapper_id: ID, object_id: ID }

// === Events ===

/// Emitted whenever an ownership request is created.
public struct OwnershipRequested has copy, drop {
    wrapper_id: ID,
    current_owner: address,
    requester: address,
}

/// Emitted whenever the wrapper changes hands.
public struct OwnershipTransferred has copy, drop {
    wrapper_id: ID,
    previous_owner: address,
    new_owner: address,
}

// === Wrap / unwrap / borrow ===

/// Wrap a capability/object inside a new two step transfer wrapper, storing it under a dynamic
/// field so the underlying ID can still be discovered by off-chain indexers.
public fun wrap<T: key + store>(cap: T, ctx: &mut TxContext): TwoStepTransferWrapper<T> {
    let mut wrapper = TwoStepTransferWrapper { id: object::new(ctx) };
    dof::add(&mut wrapper.id, WrappedKey(), cap);
    wrapper
}

/// Borrow the wrapped capability immutably—useful for read-only inspection without touching the
/// transfer flow.
public fun borrow<T: key + store>(self: &TwoStepTransferWrapper<T>): &T {
    dof::borrow(&self.id, WrappedKey())
}

/// Borrow the wrapped capability mutably when maintenance needs to happen without changing the
/// ownership state.
public fun borrow_mut<T: key + store>(self: &mut TwoStepTransferWrapper<T>): &mut T {
    dof::borrow_mut(&mut self.id, WrappedKey())
}

/// Take the wrapped capability from the `TwoStepTransferWrapper` with a guarantee that it will be returned.
public fun borrow_val<T: key + store>(self: &mut TwoStepTransferWrapper<T>): (T, Borrow) {
    let cap = dof::remove(&mut self.id, WrappedKey());
    let object_id = object::id(&cap);
    (cap, Borrow { wrapper_id: object::id(self), object_id })
}

/// Return the borrowed capability to the `TwoStepTransferWrapper`. This method cannot be avoided
/// if `borrow_val` is used.
public fun return_val<T: key + store>(
    self: &mut TwoStepTransferWrapper<T>,
    capability: T,
    borrow: Borrow,
) {
    let Borrow { wrapper_id, object_id } = borrow;

    assert!(object::id(self) == wrapper_id, EWrongTwoStepTransferWrapper);
    assert!(object::id(&capability) == object_id, EWrongTwoStepTransferObject);

    dof::add(&mut self.id, WrappedKey(), capability);
}

/// Permanently unwrap the capability, deleting the wrapper. Only the current owner can call this,
/// and it bypasses the request flow, effectively “owning” the capability again.
public fun unwrap<T: key + store>(self: TwoStepTransferWrapper<T>): T {
    let TwoStepTransferWrapper { id: mut wrapper_id } = self;
    let cap = dof::remove(&mut wrapper_id, WrappedKey());
    wrapper_id.delete();
    cap
}

// === Transfer flow ===

/// Create an ownership request for the wrapper and send it to the current owner. The caller becomes
/// the prospective owner and must wait for the current owner to call `transfer`.
public fun request<T: key + store>(wrapper_id: ID, current_owner: address, ctx: &mut TxContext) {
    let request = OwnershipTransferRequest<T> {
        id: object::new(ctx),
        wrapper_id,
        new_owner: ctx.sender(),
    };
    event::emit(OwnershipRequested {
        wrapper_id,
        current_owner,
        requester: ctx.sender(),
    });
    transfer::transfer(request, current_owner);
}

/// Approve a request that was previously issued through `request_ownership`, move the wrapper to
/// the requester, and emit an `OwnershipTransferred` event for observability.
public fun transfer<T: key + store>(
    self: TwoStepTransferWrapper<T>,
    request: OwnershipTransferRequest<T>,
    ctx: &mut TxContext,
) {
    assert!(object::id(&self) == request.wrapper_id, EInvalidTransferRequest);
    let OwnershipTransferRequest { id, new_owner, .. } = request;
    id.delete();

    event::emit(OwnershipTransferred {
        wrapper_id: object::id(&self),
        previous_owner: ctx.sender(),
        new_owner,
    });
    transfer::transfer(self, new_owner);
}

/// Reject an ownership request by deleting it—useful when the owner wants to deny or revoke a
/// pending request without moving the wrapper.
public fun reject<T>(request: OwnershipTransferRequest<T>) {
    let OwnershipTransferRequest { id, .. } = request;
    id.delete();
}

#[test_only]
public fun test_new_request<T: key + store>(
    wrapper_id: ID,
    new_owner: address,
    ctx: &mut TxContext,
): OwnershipTransferRequest<T> {
    OwnershipTransferRequest { id: object::new(ctx), wrapper_id, new_owner }
}

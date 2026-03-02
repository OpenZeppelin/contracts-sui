/// Two-step wrapper that keeps an object accessible behind a wrapper, while enforcing an
/// initiate_transfer -> accept_transfer flow for transfers.
///
/// Works with any `T: key + store` object, but the primary use case is wrapping capabilities
/// (admin caps, treasury caps, etc.) where a misdirected transfer could be irreversible.
///
/// Callers first `wrap` their object. The current owner initiates a transfer via
/// `initiate_transfer`, which creates a shared `PendingOwnershipTransfer` and sends the wrapper
/// to it via TTO. The prospective owner finalises the handoff with `accept_transfer`, while the
/// current owner can `cancel_transfer` to reclaim the wrapper. A direct `unwrap` path is provided
/// for situations where the owner wants to reclaim the underlying object locally.
///
/// This deliberate two-step process helps avoid mistakenly transferring the object to the wrong
/// recipient, a mistake which could result in it being irreversibly locked away due to human error.
///
/// By requiring explicit initiation and acceptance of each transfer, the flow provides an important
/// safety net against accidental misdirection.
module openzeppelin_access::two_step_transfer;

use sui::dynamic_object_field as dof;
use sui::event;
use sui::transfer::Receiving;

public struct WrappedKey() has copy, drop, store;

#[error(code = 0)]
const ENotOwner: vector<u8> = "Caller is not the current owner.";
/// Transfer request does not correspond to the provided wrapper
#[error(code = 1)]
const EInvalidTransferRequest: vector<u8> = "Transfer request does not match wrapper.";
#[error(code = 2)]
const EWrongTwoStepTransferWrapper: vector<u8> = "Wrong two step transfer wrapper.";
#[error(code = 3)]
const EWrongTwoStepTransferObject: vector<u8> = "Wrong two step transfer object.";
#[error(code = 4)]
const ENotNewOwner: vector<u8> = "Caller is not the prospective owner.";

/// Wrapper that owns the underlying object, stored as a dynamic object field.
///
/// The wrapper intentionally omits the `store` ability so only this module can transfer it via
/// `transfer::transfer`.
public struct TwoStepTransferWrapper<phantom T: key + store> has key {
    id: UID,
}

/// Shared object created when the current owner initiates a transfer. The wrapper is held by the
/// request via TTO so both parties can interact with it.
public struct PendingOwnershipTransfer<phantom T> has key {
    id: UID,
    wrapper_id: ID,
    from: address,
    new_owner: address,
}

/// Hot potato used to ensure a wrapped object was returned after being taken using `borrow_val`.
public struct Borrow { wrapper_id: ID, object_id: ID }

/// Hot potato used to ensure a wrapper was returned to its request after `request_borrow_val`.
public struct RequestBorrow { wrapper_id: ID }

// === Events ===

/// Emitted whenever an object is wrapped in `TwoStepTransferWrapper`.
public struct WrapExecuted<phantom T> has copy, drop {
    wrapper_id: ID,
    object_id: ID,
    owner: address,
}

/// Emitted whenever an object is unwrapped.
public struct UnwrapExecuted<phantom T> has copy, drop {
    wrapper_id: ID,
    object_id: ID,
    owner: address,
}

/// Emitted whenever an ownership transfer is initiated.
public struct TransferInitiated<phantom T> has copy, drop {
    wrapper_id: ID,
    current_owner: address,
    new_owner: address,
}

/// Emitted whenever the wrapper changes hands.
public struct TransferAccepted<phantom T> has copy, drop {
    wrapper_id: ID,
    previous_owner: address,
    new_owner: address,
}

/// Emitted whenever an ownership transfer is cancelled.
public struct TransferCancelled<phantom T> has copy, drop {
    request_id: ID,
}

// === Wrap / unwrap / borrow ===

/// Wrap an object inside a new two step transfer wrapper, storing it under a dynamic field so the
/// underlying ID can still be discovered by off-chain indexers.
public fun wrap<T: key + store>(obj: T, ctx: &mut TxContext): TwoStepTransferWrapper<T> {
    let mut wrapper = TwoStepTransferWrapper { id: object::new(ctx) };
    event::emit(WrapExecuted<T> {
        wrapper_id: object::id(&wrapper),
        object_id: object::id(&obj),
        owner: ctx.sender(),
    });
    dof::add(&mut wrapper.id, WrappedKey(), obj);
    wrapper
}

/// Borrow the wrapped object immutably—useful for read-only inspection without touching the
/// transfer flow.
public fun borrow<T: key + store>(self: &TwoStepTransferWrapper<T>): &T {
    dof::borrow(&self.id, WrappedKey())
}

/// Borrow the wrapped object mutably when maintenance needs to happen without changing the
/// ownership state.
public fun borrow_mut<T: key + store>(self: &mut TwoStepTransferWrapper<T>): &mut T {
    dof::borrow_mut(&mut self.id, WrappedKey())
}

/// Take the wrapped object from the `TwoStepTransferWrapper` with a guarantee that it will be returned.
public fun borrow_val<T: key + store>(self: &mut TwoStepTransferWrapper<T>): (T, Borrow) {
    let obj = dof::remove(&mut self.id, WrappedKey());
    let object_id = object::id(&obj);
    (obj, Borrow { wrapper_id: object::id(self), object_id })
}

/// Return the borrowed object to the `TwoStepTransferWrapper`. This method cannot be avoided
/// if `borrow_val` is used.
public fun return_val<T: key + store>(
    self: &mut TwoStepTransferWrapper<T>,
    obj: T,
    borrow: Borrow,
) {
    let Borrow { wrapper_id, object_id } = borrow;

    assert!(object::id(self) == wrapper_id, EWrongTwoStepTransferWrapper);
    assert!(object::id(&obj) == object_id, EWrongTwoStepTransferObject);

    dof::add(&mut self.id, WrappedKey(), obj);
}

/// Permanently unwrap the object, deleting the wrapper. Only the current owner can call this,
/// and it bypasses the request flow, effectively recovering direct ownership.
public fun unwrap<T: key + store>(self: TwoStepTransferWrapper<T>, ctx: &mut TxContext): T {
    let TwoStepTransferWrapper { id: mut wrapper_id } = self;
    let obj = dof::remove(&mut wrapper_id, WrappedKey());
    event::emit(UnwrapExecuted<T> {
        wrapper_id: wrapper_id.uid_to_inner(),
        object_id: object::id(&obj),
        owner: ctx.sender(),
    });
    wrapper_id.delete();
    obj
}

// === Transfer flow ===

/// Initiate an ownership transfer by creating a shared request and sending the wrapper to it via
/// TTO. The caller is the current owner and `new_owner` becomes the prospective owner.
public fun initiate_transfer<T: key + store>(
    self: TwoStepTransferWrapper<T>,
    new_owner: address,
    ctx: &mut TxContext,
) {
    let wrapper_id = object::id(&self);
    let from = ctx.sender();
    let request = PendingOwnershipTransfer<T> {
        id: object::new(ctx),
        wrapper_id,
        from,
        new_owner,
    };
    let request_address = object::id_address(&request);
    event::emit(TransferInitiated<T> {
        wrapper_id,
        current_owner: from,
        new_owner: new_owner,
    });
    transfer::share_object(request);
    transfer::transfer(self, request_address);
}

/// Accept a request that was previously initiated through `initiate_transfer`, move the wrapper to
/// the prospective owner, and emit a `TransferAccepted` event for observability.
public fun accept_transfer<T: key + store>(
    request: PendingOwnershipTransfer<T>,
    wrapper_ticket: Receiving<TwoStepTransferWrapper<T>>,
    ctx: &mut TxContext,
) {
    assert!(ctx.sender() == request.new_owner, ENotNewOwner);
    let PendingOwnershipTransfer { id: mut request_id, wrapper_id, from, new_owner } = request;
    let wrapper = transfer::receive(&mut request_id, wrapper_ticket);
    assert!(object::id(&wrapper) == wrapper_id, EInvalidTransferRequest);
    request_id.delete();

    event::emit(TransferAccepted<T> {
        wrapper_id,
        previous_owner: from,
        new_owner,
    });
    transfer::transfer(wrapper, new_owner);
}

/// Cancel an ownership request, reclaiming the wrapper and deleting the request.
public fun cancel_transfer<T: key + store>(
    request: PendingOwnershipTransfer<T>,
    wrapper_ticket: Receiving<TwoStepTransferWrapper<T>>,
    ctx: &mut TxContext,
) {
    assert!(ctx.sender() == request.from, ENotOwner);
    let PendingOwnershipTransfer { id: mut request_id, wrapper_id, from, .. } = request;
    let request_id_inner = request_id.uid_to_inner();
    let wrapper = transfer::receive(&mut request_id, wrapper_ticket);
    assert!(object::id(&wrapper) == wrapper_id, EInvalidTransferRequest);
    event::emit(TransferCancelled<T> {
        request_id: request_id_inner,
    });
    request_id.delete();
    transfer::transfer(wrapper, from);
}

// === Borrow through request (during pending transfer) ===

/// Receive the wrapper from the shared request via TTO so the current owner can access the
/// wrapped object. The returned `RequestBorrow` hot potato must be consumed by
/// `request_return_val`.
public fun request_borrow_val<T: key + store>(
    request: &mut PendingOwnershipTransfer<T>,
    wrapper_ticket: Receiving<TwoStepTransferWrapper<T>>,
    ctx: &mut TxContext,
): (TwoStepTransferWrapper<T>, RequestBorrow) {
    assert!(ctx.sender() == request.from, ENotOwner);
    let wrapper = transfer::receive(&mut request.id, wrapper_ticket);
    assert!(object::id(&wrapper) == request.wrapper_id, EInvalidTransferRequest);
    let wrapper_id = object::id(&wrapper);

    (wrapper, RequestBorrow { wrapper_id })
}

/// Return the wrapper to the request after `request_borrow_val`.
public fun request_return_val<T: key + store>(
    request: &PendingOwnershipTransfer<T>,
    wrapper: TwoStepTransferWrapper<T>,
    borrow: RequestBorrow,
) {
    let RequestBorrow { wrapper_id } = borrow;
    assert!(object::id(&wrapper) == wrapper_id, EInvalidTransferRequest);
    assert!(wrapper_id == request.wrapper_id, EInvalidTransferRequest);

    transfer::transfer(wrapper, object::id_address(request));
}

#[test_only]
public fun test_new_request<T: key + store>(
    wrapper_id: ID,
    from: address,
    new_owner: address,
    ctx: &mut TxContext,
): PendingOwnershipTransfer<T> {
    PendingOwnershipTransfer { id: object::new(ctx), wrapper_id, from, new_owner }
}

#[test_only]
public fun test_transfer_wrapper<T: key + store>(
    wrapper: TwoStepTransferWrapper<T>,
    recipient: address,
) {
    transfer::transfer(wrapper, recipient);
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
public fun test_new_unwrap_executed<T>(
    wrapper_id: ID,
    object_id: ID,
    owner: address,
): UnwrapExecuted<T> {
    UnwrapExecuted { wrapper_id, object_id, owner }
}

#[test_only]
public fun test_new_transfer_initiated<T>(
    wrapper_id: ID,
    current_owner: address,
    new_owner: address,
): TransferInitiated<T> {
    TransferInitiated { wrapper_id, current_owner, new_owner }
}

#[test_only]
public fun test_new_transfer_accepted<T>(
    wrapper_id: ID,
    previous_owner: address,
    new_owner: address,
): TransferAccepted<T> {
    TransferAccepted { wrapper_id, previous_owner, new_owner }
}

#[test_only]
public fun test_new_transfer_cancelled<T>(request_id: ID): TransferCancelled<T> {
    TransferCancelled { request_id }
}

#[test_only]
public fun test_destroy_request<T>(request: PendingOwnershipTransfer<T>) {
    let PendingOwnershipTransfer { id, .. } = request;
    id.delete();
}

//! Module/Package-level single ownership primitives for Sui packages.
//!
//! This module provides single ownership control for Sui packages through the `OwnerCap<OTW>` capability.
//! The capability is created during package initialization using a one-time witness (`OTW`) and
//! gates access to privileged entry points.
//!
//! Two ownership transfer policies are supported:
//! - `TransferPolicy::Immediate`: Enables direct ownership transfers via `transfer_ownership`
//! - `TransferPolicy::TwoStep`: Requires a two-phase handoff where:
//!   1. The prospective owner requests ownership through `request_ownership`
//!   2. The current owner approves via `transfer_requested_ownership` or rejects via
//!      `reject_ownership_request`
//!
//! The `OwnershipInitializer` helper allows configuring the transfer policy before finalizing
//! ownership. For convenience, `new_owner` and `new_two_step_owner` wrap the common initialization
//! patterns.
//!
//! All ownership transfers emit `OwnershipTransferred` events to enable tracking of administrative
//! changes.
module openzeppelin_access::ownable;

use sui::event;

/// Invalid transfer policy
#[error(code = 0)]
const EInvalidTransferPolicy: vector<u8> = b"Invalid transfer policy.";
/// Request is for the wrong capability
#[error(code = 1)]
const EInvalidTransferRequest: vector<u8> = b"Invalid ownership transfer for request.";

/// A capability that allows the owner of the smart contract (package) to perform certain actions.
/// The OTW phantom type is used to enforce that there isonly one owner per module.
public struct OwnerCap<phantom OTW> has key {
    id: UID,
    transfer_policy: TransferPolicy,
}

/// The policy for transferring ownership.
/// - Immediate: The owner can transfer ownership to a new address immediately.
/// - TwoStep: The owner can transfer ownership to a new address in two steps (requires new owner to accept ownership).
public enum TransferPolicy has drop, store {
    Immediate,
    TwoStep,
}

// Hot potato wrapper to enforce setting the transfer policy after "new_owner" is executed.
// Destroyed in the `finalize` call
public struct OwnershipInitializer<phantom OTW> {
    owner_cap: OwnerCap<OTW>,
}

/// A capability required to transfer ownership to a new address with a two step transfer policy.
/// This capability can only be created by the pending owner through the `request_ownership` function
/// and it is destroyed when the ownership is transferred to the new owner through the `transfer_requested_ownership` function.
public struct OwnershipRequestCap has key {
    id: UID,
    cap_id: ID,
    new_owner: address,
}

// === Events ===

/// Emitted when the ownership is transferred to `new_owner`.
///
/// #### Parameters
/// - `cap_id`: The ID of the owner capability object
/// - `previous_owner`: The address of the previous owner
/// - `new_owner`: The address of the new owner
public struct OwnershipTransferred has copy, drop {
    cap_id: ID,
    previous_owner: address,
    new_owner: address,
}

// === Functions ===

/// Builds an ownership initializer for a package using a one-time witness.
/// This function should be called during package initialization to set up the initial owner.
///
/// #### Parameters
/// - `otw`: One-time witness type that proves this is being called during package initialization.
/// - `ctx`: Transaction context for creating the capability object.
///
/// #### Aborts
/// - If `otw` is not a valid one-time witness type
public fun build_ownership<T: drop>(otw: &T, ctx: &mut TxContext): OwnershipInitializer<T> {
    assert!(sui::types::is_one_time_witness(otw));

    let owner_cap = OwnerCap<T> {
        id: object::new(ctx),
        transfer_policy: TransferPolicy::Immediate,
    };

    OwnershipInitializer {
        owner_cap,
    }
}

/// Transfers the owner capability to a new address.
/// This allows changing ownership of the package to a different address.
///
/// #### Parameters
/// - `cap`: The owner capability object
/// - `new_owner`: Address that will receive ownership
/// - `ctx`: Transaction context to access the caller
///
/// #### Aborts
/// - If the transfer policy is not immediate
public fun transfer_ownership<T>(cap: OwnerCap<T>, new_owner: address, ctx: &mut TxContext) {
    assert!(is_immediate_transfer_policy(&cap), EInvalidTransferPolicy);
    internal_transfer_ownership(cap, new_owner, ctx);
}

/// Transfers ownership to the requested address.
///
/// #### Parameters
/// - `cap`: The owner capability object
/// - `request`: The ownership request given by the pending owner
/// - `ctx`: Transaction context to access the caller
///
/// #### Aborts
/// - If the transfer policy is not two step
public fun transfer_requested_ownership<T>(
    cap: OwnerCap<T>,
    request: OwnershipRequestCap,
    ctx: &mut TxContext,
) {
    assert!(is_two_step_transfer_policy(&cap), EInvalidTransferPolicy);

    let OwnershipRequestCap { id, cap_id, new_owner } = request;

    // Check that the request is for the correct capability
    assert!(object::uid_as_inner(&cap.id) == cap_id, EInvalidTransferRequest);

    // Delete the request
    id.delete();

    // Transfer the ownership
    internal_transfer_ownership(cap, new_owner, ctx);
}

/// Internal function to transfer ownership to a new address.
/// This function is used to transfer ownership to a new address without checking the transfer policy.
fun internal_transfer_ownership<T>(cap: OwnerCap<T>, new_owner: address, ctx: &TxContext) {
    // Only the current owner can access this function through the OwnerCap
    let current_owner = ctx.sender();
    event::emit(OwnershipTransferred {
        cap_id: object::id(&cap),
        previous_owner: current_owner,
        new_owner,
    });
    transfer::transfer(cap, new_owner);
}

/// Requests ownership of the capability.
///
/// #### Parameters
/// - `cap_id`: The ID of the capability object
/// - `current_owner`: The address of the current owner
/// - `ctx`: Transaction context to access the caller
public fun request_ownership(cap_id: ID, current_owner: address, ctx: &mut TxContext) {
    let ownership_request = OwnershipRequestCap {
        id: object::new(ctx),
        cap_id,
        new_owner: ctx.sender(),
    };
    transfer::transfer(ownership_request, current_owner);
}

/// Renounces ownership by deleting the capability.
///
/// NOTE: This permanently removes the owner capability from circulation effectively making the package
/// functions protected by it permanently inaccessible.
///
/// #### Parameters
/// - `cap`: The owner capability object to renounce
public fun renounce_ownership<T>(cap: OwnerCap<T>) {
    let OwnerCap { id, transfer_policy: _ } = cap;
    id.delete();
}

/// Rejects the ownership request by deleting the capability.
///
/// #### Parameters
/// - `request`: The ownership request to reject
public fun reject_ownership_request(request: OwnershipRequestCap) {
    let OwnershipRequestCap { id, cap_id: _, new_owner: _ } = request;
    id.delete();
}

/// Sets the transfer policy to two step.
///
/// #### Parameters
/// - `builder`: The ownership initializer hot potato wrapper
public fun set_two_step_transfer<T>(builder: &mut OwnershipInitializer<T>) {
    builder.owner_cap.transfer_policy = TransferPolicy::TwoStep;
}

/// Finalizes the ownership initialization by transferring the ownership to ctx.sender()
/// and destroying the ownership initializer.
///
/// #### Parameters
/// - `builder`: The ownership initializer hot potato wrapper
public fun finalize<T>(builder: OwnershipInitializer<T>, ctx: &mut TxContext) {
    let OwnershipInitializer { owner_cap } = builder;
    internal_transfer_ownership(owner_cap, ctx.sender(), ctx);
}

/// Creates a new owner capability with an immediate transfer policy for a package using a one-time witness.
/// This function should be used during package initialization to set up the initial owner.
///
/// #### Parameters
/// - `otw`: One-time witness type that proves this is being called during package initialization.
/// - `ctx`: Transaction context for creating the capability object.
public fun new_owner<T: drop>(otw: &T, ctx: &mut TxContext) {
    let builder = build_ownership(otw, ctx);
    builder.finalize(ctx);
}

/// Creates a new owner capability with a two step transfer policy for a package using a one-time witness.
/// This function should be used during package initialization to set up the initial owner.
///
/// #### Parameters
/// - `otw`: One-time witness type that proves this is being called during package initialization.
/// - `ctx`: Transaction context for creating the capability object.
public fun new_two_step_owner<T: drop>(otw: &T, ctx: &mut TxContext) {
    let mut builder = build_ownership(otw, ctx);
    builder.set_two_step_transfer();
    builder.finalize(ctx);
}

/// Returns true if the transfer policy is immediate.
public fun is_immediate_transfer_policy<T>(owner_cap: &OwnerCap<T>): bool {
    &owner_cap.transfer_policy == TransferPolicy::Immediate
}

/// Returns true if the transfer policy is two step.
public fun is_two_step_transfer_policy<T>(owner_cap: &OwnerCap<T>): bool {
    &owner_cap.transfer_policy == TransferPolicy::TwoStep
}

#[test_only]
public fun create_immediate_owner_cap_for_testing<T>(ctx: &mut TxContext): OwnerCap<T> {
    OwnerCap {
        id: object::new(ctx),
        transfer_policy: TransferPolicy::Immediate,
    }
}

#[test_only]
public fun last_transfer_event_fields_for_testing(): (ID, address, address) {
    let events = event::events_by_type<OwnershipTransferred>();
    let len = std::vector::length(&events);
    assert!(len > 0);
    let latest = *std::vector::borrow(&events, len - 1);
    (latest.cap_id, latest.previous_owner, latest.new_owner)
}

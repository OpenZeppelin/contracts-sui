module openzeppelin_access::ownable;

/// Invalid transfer policy
#[error(code = 0)]
const EInvalidTransferPolicy: vector<u8> = b"Invalid transfer policy.";

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

/// Creates a new owner capability for a package using a one-time witness.
/// This function should be called during package initialization to set up the initial owner.
///
/// #### Parameters
/// - `otw`: One-time witness type that proves this is being called during package initialization.
/// - `owner`: Address that will receive the owner capability.
/// - `ctx`: Transaction context for creating the capability object.
///
/// #### Aborts
/// - If `otw` is not a valid one-time witness type
public fun new_owner<T: drop>(otw: T, ctx: &mut TxContext): OwnershipInitializer<T> {
    assert!(sui::types::is_one_time_witness(&otw));

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
public fun transfer_ownership<T>(cap: OwnerCap<T>, new_owner: address) {
    assert!(is_immediate_transfer_policy(&cap), EInvalidTransferPolicy);
    transfer::transfer(cap, new_owner);
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

/// Sets the transfer policy to two step.
///
/// #### Parameters
/// - `builder`: The ownership initializer hot potato wrapper
public fun set_two_step_transfer<T>(builder: &mut OwnershipInitializer<T>) {
    builder.owner_cap.transfer_policy = TransferPolicy::TwoStep;
}

/// Finalizes the ownership initialization by transferring the ownership to the new owner
/// and destroying the ownership initializer.
///
/// #### Parameters
/// - `builder`: The ownership initializer hot potato wrapper
/// - `initial_owner`: The initial owner address
public fun finalize<T>(builder: OwnershipInitializer<T>, initial_owner: address) {
    let OwnershipInitializer { owner_cap } = builder;
    owner_cap.transfer_ownership(initial_owner);
}

//
// Helpers
//

/// Returns true if the transfer policy is immediate.
public fun is_immediate_transfer_policy<T>(owner_cap: &OwnerCap<T>): bool {
    &owner_cap.transfer_policy == TransferPolicy::Immediate
}

/// Returns true if the transfer policy is two step.
public fun is_two_step_transfer_policy<T>(owner_cap: &OwnerCap<T>): bool {
    &owner_cap.transfer_policy == TransferPolicy::TwoStep
}

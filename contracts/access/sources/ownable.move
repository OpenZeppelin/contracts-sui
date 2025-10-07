module openzeppelin_access::ownable;

/// A capability that allows the owner of the smart contract (package) to perform certain actions.
/// The OTW phantom type is used to enforce that there isonly one owner per module.
public struct OwnerCap<phantom OTW> has key {
    id: UID,
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
public fun new_owner<T: drop>(otw: T, owner: address, ctx: &mut TxContext) {
    assert!(sui::types::is_one_time_witness(&otw));

    let owner_cap = OwnerCap<T> {
        id: object::new(ctx),
    };
    owner_cap.transfer_ownership(owner);
}

/// Transfers the owner capability to a new address.
/// This allows changing ownership of the package to a different address.
///
/// #### Parameters
/// - `cap`: The owner capability object
/// - `new_owner`: Address that will receive ownership
public fun transfer_ownership<T>(cap: OwnerCap<T>, new_owner: address) {
    transfer::transfer(cap, new_owner);
}

/// Renounces ownership by transferring the capability to the zero address.
///
/// NOTE: This permanently removes the owner capability from circulation effectively making the package
/// functions protected by it permanently inaccessible.
///
/// #### Parameters
/// - `cap`: The owner capability object to renounce
public fun renounce_ownership<T>(cap: OwnerCap<T>) {
    transfer::transfer(cap, @0x0);
}

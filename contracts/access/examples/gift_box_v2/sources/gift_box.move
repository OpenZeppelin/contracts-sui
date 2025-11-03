//! Gift box example secured by `OwnerCap` from `openzeppelin_access::ownable`
//! in two-step transfer policy.
//!
//! The `init` function creates the module's owner capability, switches it to the
//! two-step transfer policy, and finalizes ownership so the deployer holds the
//! capability.
//!
//! Under this policy, a prospective owner must:
//! 1. Call `ownable::request_ownership` to create and transfer an `OwnershipRequestCap`
//!    to the current owner
//! 2. Then, the current owner completes the handoff by calling `ownable::transfer_requested_ownership`
//!
//! This ensures the `OwnerCap` never moves without explicit approval from both parties,
//! preventing accidental loss of access control by transferring to an invalid address.
//!
//! IMPORTANT: While anyone can request ownership of the `OwnerCap`, only the current
//! owner can complete the handoff by calling `ownable::transfer_requested_ownership`.
//! The current owner can reject ownership requests by calling `ownable::reject_ownership_request`.
module gift_box_v2_example::gift_box_v2 {
    use openzeppelin_access::ownable::{Self, OwnerCap};
    use std::string::String;

    /// One-Time Witness
    public struct GIFT_BOX_V2 has drop {}

    fun init(otw: GIFT_BOX_V2, ctx: &mut TxContext) {
        ownable::new_two_step_owner(&otw, ctx);
    }

    public struct Gift has key, store {
        id: UID,
        note: String,
    }

    /// Sends a gift to a recipient.
    ///
    /// NOTE: Only the owner of this module is allowed to send a gift through the owner capability.
    public fun send_gift(
        _: &OwnerCap<GIFT_BOX_V2>,
        note: String,
        to: address,
        ctx: &mut TxContext,
    ) {
        let new_gift = Gift {
            id: object::new(ctx),
            note,
        };

        // Transfer the gift to the recipient
        transfer::transfer(new_gift, to);
    }
}

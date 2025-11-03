//! Gift box example secured by `OwnerCap` from `openzeppelin_access::ownable`
//! in immediate transfer policy.
//!
//! The `init` function creates the module's owner capability with an immediate
//! transfer policy and finalizes ownership so the deployer holds the capability.
//!
//! Under this policy, ownership can be transferred directly by calling
//! `ownable::transfer_ownership`. The transfer happens immediately without requiring
//! approval from the recipient.
//!
//! IMPORTANT: Care must be taken when transferring ownership to ensure the recipient
//! address is valid and able to receive the capability. Once transferred, the previous
//! owner immediately loses access to owner-restricted functions.
module gift_box_v1_example::gift_box_v1;

use openzeppelin_access::ownable::{Self, OwnerCap};
use std::string::String;

/// One-Time Witness
public struct GIFT_BOX_V1 has drop {}

fun init(otw: GIFT_BOX_V1, ctx: &mut TxContext) {
    ownable::new_owner(&otw, ctx);
}

public struct Gift has key, store {
    id: UID,
    note: String,
}

/// Sends a gift to a recipient.
///
/// NOTE: Only the owner of this module is allowed to send a gift through the owner capability.
public fun send_gift(_: &OwnerCap<GIFT_BOX_V1>, note: String, to: address, ctx: &mut TxContext) {
    let new_gift = Gift {
        id: object::new(ctx),
        note,
    };

    // Transfer the gift to the recipient
    transfer::transfer(new_gift, to);
}

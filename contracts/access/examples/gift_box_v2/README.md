## Example overview

### Gift Box V2

This module demonstrates securing a gift box with `OwnerCap` under the two-step ownership transfer policy provided by `openzeppelin_access::ownable`. During initialization, `init` mints the capability, switches it to the two-step policy, and finalizes ownership so the publisher controls the module.

Under this policy, ownership only changes hands after both participants act:

1. The prospective owner calls `ownable::request_ownership` to mint an `OwnershipRequestCap` and passes it to the current owner.
2. The current owner completes the handoff by calling `ownable::transfer_requested_ownership`, or rejects the request through `ownable::reject_ownership_request`.

This handshake prevents the capability from moving to an unintended address without explicit consent, reducing the risk of losing access to privilege-restricted entry points.

> **Important:** Anyone can create a request, but only the current owner can approve it. Always verify ownership requests before approving them.

### PTB quickstart

Instructions for a programmable transaction walkthrough are coming soon. In the meantime, you can inspect the Move module in [`sources/gift_box.move`](./sources/gift_box.move) and follow the request/approve flow manually with the Sui CLI.

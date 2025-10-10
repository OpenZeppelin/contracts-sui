# Access Package

The OpenZeppelin Access package aims to provide a comprehensive suite of access control mechanisms for Sui smart contracts. While currently focused on single-owner administration through the `ownable` module, the package is designed to expand with additional access patterns like role-based access control (RBAC) and other governance models in future releases.

## Available Modules

### ownable

The `ownable` module implements single-owner administration for Sui packages through capability objects. During initialization, a module uses a one-time witness to mint an `OwnerCap<OTW>` object, which gates privileged entry points to the current owner. Ownership can later be reassigned while every transfer emits an `OwnershipTransferred` event for on-chain auditing.

#### Transfer policies

- **Immediate** – the current owner hands the capability directly to a new address through `transfer_ownership`.
- **Two-step** – the prospective owner first creates an `OwnershipRequestCap` with `request_ownership`; the current owner must explicitly approve via `transfer_requested_ownership` or reject with `reject_ownership_request`. This handshake prevents accidental transfers to unexpected addresses.

The `OwnershipInitializer` helper lets modules choose a policy before finalizing ownership. Convenience wrappers `new_owner` and `new_two_step_owner` cover the common initialization paths.

#### Supporting APIs

- `build_ownership`/`finalize` construct and settle the `OwnerCap`.
- `renounce_ownership` deletes the capability, permanently locking protected entry points.
- `request_ownership` and `reject_ownership_request` manage two-step handoffs.

## Examples

Concrete walkthroughs live under `examples/`:

- `examples/gift_box_v1` – immediate-transfer handoff.
- `examples/gift_box_v2` – two-step ownership requests.

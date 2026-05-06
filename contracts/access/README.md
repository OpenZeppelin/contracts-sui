# OpenZeppelin Access for Sui

Role-based authorization and controlled ownership-transfer primitives for Sui Move protocols.

The `openzeppelin_access` package helps protocols protect privileged functions, shared state, admin capabilities, treasury capabilities, and governance-controlled operations.

## Install

```toml
[dependencies]
openzeppelin_access = { r.mvr = "@openzeppelin-move/access" }
```

## Modules

| Module | Use it when |
| --- | --- |
| [`access_control`](https://docs.openzeppelin.com/contracts-sui/1.x/access-control) | Authority is spread across multiple roles or actors, especially for shared protocol state and privileged functions. |
| [`two_step_transfer`](https://docs.openzeppelin.com/contracts-sui/1.x/two-step-transfer) | A single-owned privileged object can transfer immediately, but the recipient should explicitly accept first. |
| [`delayed_transfer`](https://docs.openzeppelin.com/contracts-sui/1.x/delayed-transfer) | A single-owned privileged object should not transfer or unwrap until a visible delay has elapsed. |

## Role-Based Access Control

Use `access_control` when your package needs operational roles such as admins, treasurers, guardians, pausers, keepers, or governance executors.

The registry is rooted in your module's One-Time Witness (OTW). Roles must be defined in the same module as that OTW, and `Auth<Role>` values can be minted in PTBs as typed authorization proofs.

```move
use openzeppelin_access::access_control::{Self, AccessControl, Auth};
```

Start with the [Role Based Access Control guide](https://docs.openzeppelin.com/contracts-sui/1.x/guides/access-control) for a full implementation walkthrough with publishing, upgrades, and PTBs.

Relevant docs:

- [RBAC package page](https://docs.openzeppelin.com/contracts-sui/1.x/access-control)
- [Implement a module with RBAC](https://docs.openzeppelin.com/contracts-sui/1.x/guides/access-control#implementing-a-new-module)
- [Upgrade an existing package](https://docs.openzeppelin.com/contracts-sui/1.x/guides/access-control#upgrading-an-existing-package)
- [Root role operations](https://docs.openzeppelin.com/contracts-sui/1.x/guides/access-control#root-role-operations)
- [`access_control` API reference](https://docs.openzeppelin.com/contracts-sui/1.x/api/access#access_control)

## Controlled Object Transfers

Use the transfer modules for single-owned privileged objects, especially capability objects.

### Two-step transfer

`two_step_transfer` wraps an object and requires the intended recipient to accept before ownership moves.

```move
use openzeppelin_access::two_step_transfer;
```

Docs:

- [Two-Step Transfer guide](https://docs.openzeppelin.com/contracts-sui/1.x/two-step-transfer)
- [`two_step_transfer` API reference](https://docs.openzeppelin.com/contracts-sui/1.x/api/access#two_step_transfer)

### Delayed transfer

`delayed_transfer` wraps an object and enforces a minimum delay before transfer or unwrap execution.

```move
use openzeppelin_access::delayed_transfer;
```

Docs:

- [Delayed Transfer guide](https://docs.openzeppelin.com/contracts-sui/1.x/delayed-transfer)
- [`delayed_transfer` API reference](https://docs.openzeppelin.com/contracts-sui/1.x/api/access#delayed_transfer)

## Security Notes

- `access_control` root-role changes use delayed flows. Do not try to grant, revoke, or renounce the root role with ordinary role-management calls.
- Role grants and root transfers reject `@0x0`. Use the delayed root-renounce flow when the goal is to intentionally lock a registry.
- `two_step_transfer` records `ctx.sender()` as cancel authority. Avoid using it directly in shared-object executor flows unless signer identity is intentionally the cancel authority.
- `delayed_transfer` recipients should be wallet addresses, not object IDs, unless your protocol explicitly supports recovery from transfer-to-object custody.

## Learn More

- [Access package overview](https://docs.openzeppelin.com/contracts-sui/1.x/access)
- [Access API reference](https://docs.openzeppelin.com/contracts-sui/1.x/api/access)
- [OpenZeppelin Contracts for Sui](https://docs.openzeppelin.com/contracts-sui)

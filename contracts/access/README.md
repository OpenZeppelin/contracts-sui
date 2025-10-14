# Access Package

Opinionated access control primitives for Sui smart contracts.

---

## Module Snapshot

| Module | Summary |
|--------|---------|
| `ownable` | Single-owner capability handler that guards per-module/per-package privileged entry points. |

---

## `ownable` at a Glance

1. **Initialization**
   - During module initialization, call `new_owner` (immediate policy) or `new_two_step_owner` (two-step policy) with the one-time witness.
   - These helpers mint an `OwnerCap<OTW>` and transfer it to `ctx.sender()`.
2. **Transfer Policies**
   - **Immediate:** `transfer_ownership` moves the capability directly to a new address. Every transfer emits `OwnershipTransferred`.
   - **Two-step:** The prospective owner calls `request_ownership` to create an `OwnershipRequestCap`. The current owner must explicitly accept (`transfer_requested_ownership`) or reject (`reject_ownership_request`), keeping accidental handoffs in check.
3. **Additional APIs**
   - `build_ownership` / `finalize` — low-level hooks that power the helpers.
   - `request_ownership` / `reject_ownership_request` — manage pending handoffs.
   - `renounce_ownership` — deletes the capability, permanently locking restricted entry points.

---

## Learn by Example

Hands-on walkthroughs live in the [`examples/`](examples/) folder:

| Example | Pattern | Highlights |
|---------|---------|------------|
| [`gift_box_v1`](examples/gift_box_v1/) | Immediate transfer | Owner capability moves in a single transaction. |
| [`gift_box_v2`](examples/gift_box_v2/) | Two-step transfer | Request + approval flow using `OwnershipRequestCap`. |

Each example pairs a Move module with PTB scripts that you can run end-to-end; see the README inside each folder for a full quickstart.

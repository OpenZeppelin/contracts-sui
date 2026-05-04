# Access Package

Authorization primitives for Sui Move libraries, standards, and protocols: role-based access control plus transfer policies for safely handing objects to new owners.

Transfer-policy modules accept any `T: key + store` object, but the primary use case is wrapping **capabilities** — admin caps, treasury caps, and similar authority tokens — where a misdirected transfer could be irreversible. The access-control module gates protocol functions by typed role witnesses without per-call ID pinning.

---

## Module Snapshot

| Module | Summary |
|--------|---------|
| `access_control` | Role-based access control with self-validating `Auth<R>` capabilities, OTW-pinned singleton registry, and timelocked root role transfer. |
| `two_step_transfer` | Wraps an object behind an initiate_transfer/accept_transfer flow to avoid accidental handoffs. |
| `delayed_transfer` | Enforces a minimum delay between scheduling and executing transfers or unwrapping. |

---

## `access_control` at a Glance

The library guarantees two structural invariants: (1) **one registry per module per publish** (enforced by requiring a One-Time Witness in `new<RootRole>`); (2) **only home-module roles** (every write path checks that the role type's defining module matches the root role's, using `with_original_ids` so role types added in package upgrades are accepted). Together these make `Auth<R>` a self-validating capability — action functions take `&Auth<R>` directly with no body checks.

1. **Deploy**
   - In your module's `init`, call `access_control::new<MY_OTW>(otw, default_admin_delay_ms, ctx)` to mint the singleton `AccessControl<MY_OTW>`. The publishing transaction's sender automatically becomes the root role holder. Share or embed the registry as your protocol requires.
2. **Wire roles**
   - Define phantom marker types in the same module as your OTW (e.g. `public struct AdminRole {}`, `public struct OperatorRole {}`).
   - Build the admin hierarchy with `set_role_admin<RootRole, Role, AdminRole>` — every fresh role's admin defaults to the root role; rewire as needed.
   - Use `grant_role<RootRole, R>`, `revoke_role<RootRole, R>`, and `renounce_role<RootRole, R>` to manage membership. Granting / revoking is gated by holding `R`'s admin role; renounce is self-only.
3. **Issue capabilities**
   - `new_auth<RootRole, R>(&registry, ctx)` mints `Auth<R>` for `ctx.sender()` if they currently hold `R`.
   - Pass `&Auth<R>` to gated business actions in the same PTB. Because the registry is singleton-per-publish and only home-module roles can ever be registered in it, any `Auth<R>` in scope is unforgeable in context — no body checks needed.
4. **Rotate or relinquish root**
   - `begin_default_admin_transfer(&mut registry, new_admin, &clock, ctx)` schedules a transfer from the current root holder.
   - After `default_admin_delay_ms` elapses, the pending admin calls `accept_default_admin_transfer(&mut registry, &clock, ctx)`. The rotation is atomic: the old admin is revoked and the new admin is granted in one transaction.
   - The current root holder can call `cancel_default_admin_transfer(&mut registry, ctx)` to back out at any time before acceptance.
   - Renouncing the root role when you are the last holder makes the registry permanently unmanageable — used deliberately as a final lock-in step.

---

## `two_step_transfer` at a Glance

1. **Wrap**
   - Call `wrap<T>` to place an object under a `TwoStepTransferWrapper<T>`. The wrapper owns the object via a dynamic object field.
2. **Borrow**
   - Use `borrow`, `borrow_mut`, or `borrow_val`/`return_val` to read or temporarily mutate the wrapped object without changing ownership.
   - While a transfer is pending, the current owner can use `request_borrow_val`/`request_return_val` to temporarily access the wrapper and its inner object through the shared request.
3. **Transfer**
   - The current owner calls `initiate_transfer` to emit `TransferInitiated`, create a shared `PendingOwnershipTransfer`, and TTO the wrapper to it.
   - The prospective owner calls `accept_transfer` with the request + receiving ticket to accept, or the current owner calls `cancel_transfer` to reclaim the wrapper.
4. **Unwrap**
   - Owners can reclaim the underlying object immediately via `unwrap`, destroying the wrapper.

---

## `delayed_transfer` at a Glance

1. **Wrap**
   - `wrap<T>(obj, min_delay_ms, recipient, ctx)` creates a `DelayedTransferWrapper<T>`, stores the object under it, and transfers the wrapper to `recipient`.
2. **Borrow**
   - Access the wrapped object through `borrow`, `borrow_mut`, or the `borrow_val` / `return_val` pair for temporary moves.
3. **Schedule**
   - Call `schedule_transfer` with a recipient and clock to emit `TransferScheduled`. The wrapper records the current owner from `ctx.sender()`.
   - Call `schedule_unwrap` to plan a delayed unwrap; the wrapper emits `UnwrapScheduled`.
4. **Execute or Cancel**
   - After `clock.timestamp_ms() >= execute_after_ms`, call `execute_transfer` to emit `OwnershipTransferred` and move the wrapper to the scheduled recipient.
   - For scheduled unwraps, call `unwrap` to emit `UnwrapExecuted`, delete the wrapper, and recover the underlying object.
   - Use `cancel_schedule` to cancel a pending transfer or unwrap before execution.

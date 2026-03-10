# Access Package

Transfer policies for safely handing objects to new owners.

Both modules accept any `T: key + store` object, but the primary use case is wrapping **capabilities** — admin caps, treasury caps, and similar authority tokens — where a misdirected transfer could be irreversible.

---

## Module Snapshot

| Module | Summary |
|--------|---------|
| `two_step_transfer` | Wraps an object behind an initiate_transfer/accept_transfer flow to avoid accidental handoffs. |
| `delayed_transfer` | Enforces a minimum delay between scheduling and executing transfers or unwrapping. |

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

# Access Package

Transfer policies for safely handing capabilities to new owners.

---

## Module Snapshot

| Module | Summary |
|--------|---------|
| `two_step_transfer` | Wraps a capability behind an initiate_transfer/accept_transfer flow to avoid accidental handoffs. |
| `delayed_transfer` | Enforces a minimum delay between scheduling and executing transfers or unwrapping. |

---

## `two_step_transfer` at a Glance

1. **Wrap**
   - Call `wrap<T>` to move a capability under a `TwoStepTransferWrapper<T>`. The wrapper owns the capability via a dynamic object field.
2. **Borrow**
   - Use `borrow`, `borrow_mut`, or `borrow_val`/`return_val` to read or temporarily mutate the capability without changing ownership.
   - While a transfer is pending, the current owner can use `request_borrow_val`/`request_return_val` to temporarily access the wrapper and its capability through the shared request.
3. **Transfer**
   - The current owner calls `initiate_transfer` to emit `TransferInitiated`, create a shared `OwnershipTransferRequest`, and TTO the wrapper to it.
   - The prospective owner calls `accept_transfer` with the request + receiving ticket to accept, or the current owner calls `cancel_transfer` to reclaim the wrapper.
4. **Unwrap**
   - Owners can reclaim the underlying capability immediately via `unwrap`, destroying the wrapper.

---

## `delayed_transfer` at a Glance

1. **Wrap**
   - `wrap<T>(cap, min_delay_ms, ctx)` produces a `DelayedTransferWrapper<T>` that stores the capability and minimum delay.
2. **Borrow**
   - Access the capability through `borrow`, `borrow_mut`, or the `borrow_val` / `return_val` pair for temporary moves.
3. **Schedule**
   - Call `schedule_transfer` with a recipient, clock, and owner to emit `TransferScheduled`. The wrapper tracks the scheduled action.
   - Call `schedule_unwrap` to plan a delayed unwrap; the wrapper emits `UnwrapScheduled`.
4. **Execute or Cancel**
   - After `clock.timestamp_ms() >= execute_after_ms`, call `execute_transfer` or `unwrap` to emit `OwnershipTransferred`, consume the wrapper, and deliver the capability.
   - Use `cancel_schedule` to drop a pending action prior to execution.

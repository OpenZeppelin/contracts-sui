# `openzeppelin_utils`

Embeddable primitives for Sui smart contract development.

## Module Snapshot

| Module | Summary |
|--------|---------|
| `rate_limiter` | Three rate-limiting strategies behind one enum: token bucket, fixed window, and cooldown. |

---

## `rate_limiter` at a Glance

`RateLimiter` is a `store + drop` value the integrator embeds as a field inside their own object.

Three strategies share the same API:

- **Bucket** ([Wikipedia](https://en.wikipedia.org/wiki/Token_bucket)) — a bucket holds up to `capacity` tokens and refills at a steady rate. Each consume drains tokens; an empty bucket denies the call. Permits short bursts up to `capacity` on top of a sustained average rate, which is what most APIs and on-chain throughput controls actually want.
- **Fixed window** — time is partitioned into back-to-back windows of `window_ms`, anchored at limiter creation. Each window allows up to `capacity` units and resets to full `capacity` at the boundary. Cheap and easy to reason about; the known trade-off is that a caller can spend the full quota at the end of one window and the full quota at the start of the next, yielding a `2 * capacity` burst across the boundary. Pick it when the quota is the contract (e.g. "100 mints per hour") and the boundary burst is acceptable.
- **Cooldown** — after `capacity` units are drawn down, the limiter is gated for `cooldown_ms` before any further consumption is allowed; once the gate elapses, the full `capacity` is available again. Equivalent to a "recharge after use" pattern (think action cooldowns in games, or "wait 60s before retrying").

| Variant | When to pick it |
|---------|-----------------|
| `Bucket` | Smooth, sustained throughput with bursts up to `capacity`. |
| `FixedWindow` | Hard per-window quotas (e.g. "100 per hour"). |
| `Cooldown` | Burst-then-pause patterns (e.g. "1 minute cooldown after each batch"). |

### Lifecycle

1. **Construct** - call `new_bucket`, `new_fixed_window`, or `new_cooldown` and store the result as a field on your object.
2. **Consume** - on hot paths, call `consume_or_abort` or `try_consume`. Both project accrual / window rollover / cooldown release before the consume; the projection is committed on success and discarded on failure (state is untouched when `try_consume` returns `false` or `consume_or_abort` aborts).
3. **Inspect** - `available` returns the consumable amount right now, projecting pending accrual / rollover / release on read. The result is correct regardless of whether the most recent `try_consume` succeeded.
4. **Reconfigure** - call the variant-matching `reconfigure_*` to rewrite limits in place. Switching strategies requires building a fresh limiter and overwriting the field.

### Usage

Pick the constructor that matches your policy; the consume and inspect calls are identical for all three variants.

```move
use openzeppelin_utils::rate_limiter::{Self, RateLimiter};
use sui::clock::Clock;

// Bucket — smooth throughput with bursts; refills 100 units every 6 s, cap 1 000.
let limiter: RateLimiter = rate_limiter::new_bucket(1_000, 100, 6_000, 1_000, clock);

// Fixed window — hard per-hour quota of 100 units, starting full.
let limiter: RateLimiter = rate_limiter::new_fixed_window(100, 3_600_000, 100, clock);

// Cooldown — up to 1 000 units per batch, then a 60 s gate before the next batch.
let limiter: RateLimiter = rate_limiter::new_cooldown(1_000, 60_000, 1_000);

// Identical hot-path API regardless of variant:
let units = limiter.available(clock);   // how many units are consumable right now
limiter.consume_or_abort(amount, clock); // deduct or abort with ERateLimited
```

A typical integration embeds `RateLimiter` as an object field:

```move
module my_protocol::vault;

use openzeppelin_utils::rate_limiter::{Self, RateLimiter};
use sui::clock::Clock;

public struct Vault has key {
    id: UID,
    withdraw_limiter: RateLimiter,
    // ...
}

public fun new(clock: &Clock, ctx: &mut TxContext): Vault {
    let withdraw_limiter = rate_limiter::new_bucket(1_000, 100, 6_000, 1_000, clock);
    Vault { id: object::new(ctx), withdraw_limiter }
}

public fun withdraw(self: &mut Vault, amount: u64, clock: &Clock) {
    self.withdraw_limiter.consume_or_abort(amount, clock);
    // ... actual withdrawal ...
}
```

### Operator Notes

- Configs require positive values. For `Bucket`, internal accrual stays overflow-safe regardless of `capacity` and `refill_amount` magnitudes - no upper bounds need to be enforced beyond standard `u64` arithmetic.
- `initial_available` may be `0` for `Bucket` (starts empty, must wait for the first refill) and `FixedWindow` (starts with no quota in the first window). For `Cooldown`, `initial_available` must be `> 0`: the cooldown gate only arms once a batch has been drained by an actual consume, so there is no semantically valid "start gated" state. To force callers to wait before the first batch, gate construction of the enclosing object, not the limiter's initial balance.
- For `Cooldown`, the gate deadline is computed as `now + cooldown_ms`. Operators must pick `cooldown_ms` such that this addition cannot overflow over the limiter's lifetime; any policy-meaningful value (seconds to years, expressed in ms) satisfies this trivially.
- `try_consume` and `consume_or_abort` abort on `amount == 0`. A zero-unit consume is a programmer error, not a rate-limit decision - behavior is uniform across variants.
- A failed `try_consume` (return `false`) is observably a no-op: no anchor advance, no balance change, no gate re-arm. This holds across all three variants. Integrators may probe the limiter with `try_consume(amount, _)` without skewing its internal state — including across a subsequent `reconfigure_*` call, which projects under the old config based on the unchanged stored anchor.
- Reconfiguration applies pending accrual under the *old* config first, then re-anchors the variant's timing (refill counter / window start / cooldown deadline) to `now` and installs the new config. Future accrual, window rollover, or cooldown release runs entirely under the new configuration starting from the reconfigure call - sub-interval remainders and in-flight cooldown gates from the old config do not carry over. `available` is clamped down to the new capacity.

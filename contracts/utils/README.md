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

| Variant | Semantics | When to pick it |
|---------|-----------|-----------------|
| `Bucket` | Tokens accrue continuously: `refill_amount` every `refill_interval_ms`, capped at `capacity`. | Smooth, sustained throughput with bursts up to `capacity`. |
| `FixedWindow` | Up to `capacity` per `[k * window_ms, (k+1) * window_ms)` window anchored at creation. | Hard per-window quotas (e.g. "100 per hour"). |
| `Cooldown` | Up to `capacity` units (drawn down by per-call `amount`), then a `cooldown_ms` gate before the next batch. | Burst-then-pause patterns (e.g. "1 minute cooldown after each batch"). |

### Lifecycle

1. **Construct** - call `new_bucket`, `new_fixed_window`, or `new_cooldown` and store the result as a field on your object.
2. **Consume** - on hot paths, call `consume_or_abort` or `try_consume`. Both apply accrual / window rollover / cooldown release before the consume.
3. **Inspect** - `available` returns the consumable amount right now, after applying accrual.
4. **Reconfigure** - call the variant-matching `reconfigure_*` to rewrite limits in place. Switching strategies requires building a fresh limiter and overwriting the field.

### Usage

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
    // Cap at 1_000 tokens, refilling 100 every 6 s, starting full.
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
- For `Cooldown`, the gate deadline is computed as `now + cooldown_ms`. Operators must pick `cooldown_ms` such that this addition cannot overflow over the limiter's lifetime; any policy-meaningful value (seconds to years, expressed in ms) satisfies this trivially.
- `try_consume` and `consume_or_abort` abort on `amount == 0`. A zero-unit consume is a programmer error, not a rate-limit decision - behavior is uniform across variants.
- Reconfiguration applies pending accrual under the *old* config first, then installs the new one and clamps `available` down to the new capacity. For `Cooldown` specifically, an in-flight gate is preserved - the new `cooldown_ms` does not retroactively shift a deadline that is already armed.

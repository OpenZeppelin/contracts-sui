# `openzeppelin_utils`

Embeddable primitives for Sui smart contract development.

## Module Snapshot

| Module | Summary |
|--------|---------|
| `rate_limiter` | Three rate-limiting strategies behind one enum: token bucket, fixed window, and cooldown. |

---

## `Rate Limiter` at a Glance

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
4. **Reconstruct** - this module deliberately does not provide in-place `reconfigure_*` functions. To change configuration or runtime state, read the current state via the getters, build a fresh `RateLimiter` with the desired field values, and overwrite the field. Every reconfigure policy - preserve anchor, project then re-anchor, full reset, proportional carry, freeze in-flight gate, etc. - is expressible in caller code.

### Usage

Pick the constructor that matches your policy; the consume and inspect calls are identical for all three variants.

```move
use openzeppelin_utils::rate_limiter::{Self, RateLimiter};
use sui::clock::Clock;

// Bucket — smooth throughput with bursts; cap 1 000, refills 100 units every 6 s, starting full.
let limiter: RateLimiter = rate_limiter::new_bucket(1_000, 100, 6_000, clock.timestamp_ms(), 1_000, clock);

// Fixed window — hard per-hour quota of 100 units, starting full at the current time.
let limiter: RateLimiter = rate_limiter::new_fixed_window(100, 3_600_000, clock.timestamp_ms(), 100, clock);

// Cooldown — up to 1 000 units per batch, then a 60 s gate before the next batch.
let limiter: RateLimiter = rate_limiter::new_cooldown(1_000, 60_000, 0, 1_000, clock);

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
    let withdraw_limiter = rate_limiter::new_bucket(1_000, 100, 6_000, clock.timestamp_ms(), 1_000, clock);
    Vault { id: object::new(ctx), withdraw_limiter }
}

public fun withdraw(self: &mut Vault, amount: u64, clock: &Clock) {
    self.withdraw_limiter.consume_or_abort(amount, clock);
    // ... actual withdrawal ...
}
```

### Examples

> [!Warning]
> These are **unaudited illustrations** of how the primitive can be integrated, not production-ready code.

Complete, compiling integrations live in [`examples/rate_limiter/`](https://github.com/OpenZeppelin/contracts-sui/tree/main/contracts/utils/examples/rate_limiter):

- [`faucet`](https://github.com/OpenZeppelin/contracts-sui/tree/main/contracts/utils/examples/rate_limiter/faucet.move) - two limiters of different variants composed across two objects: a per-holder token bucket layered on top of a global fixed window shared by all claimers.
- [`staking_vault`](https://github.com/OpenZeppelin/contracts-sui/tree/main/contracts/utils/examples/rate_limiter/staking_vault.move) - a cooldown used as a one-shot timelock: unstaking arms a gate that releases after an unbonding delay, so the claim aborts until the delay has elapsed.
- [`mage_duel`](https://github.com/OpenZeppelin/contracts-sui/tree/main/contracts/utils/examples/rate_limiter/mage_duel.move) - rate limiting can be used outside of DeFi; this example showcases many limiters of mixed variants packed into one type: a mage holds buckets for health and mana plus per-spell cooldowns, with `copy` limiters carried inside `store` structs.

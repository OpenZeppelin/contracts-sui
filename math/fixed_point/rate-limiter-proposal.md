Tracking issue: https://github.com/OpenZeppelin/contracts-sui/issues/136

The idea behind this research is to improve the existing DeepBook’s [rate limiter module](https://github.com/MystenLabs/deepbookv3/blob/6b05be72bdf74e0adafd3770bdc2e7e4d6a6e42b/packages/deepbook_margin/sources/rate_limiter.move).

This document is for internal review and approval by our dev team, before potentially being expanded into a client-facing proposal.

The goal is to align on:

- the first-release scope;
- the recommended architecture;
- the objects and fields we should standardize on;
- the API shape we want integrators to use;
- the practical examples we want to support well.

Questions that guided the research:

1. **What are developers in other ecosystems using to achieve rate limiting?**
2. **What would a “flexible” implementation of a rate limiter module look like?**

## Proposal Summary

We should build a small rate limiting library with these modules:

1. `rate_limit::token_bucket`
2. `rate_limit::fixed_window`
3. `rate_limit::cooldown`

We should make `token_bucket` the default documented choice.

We should use this object model:

- `Policy<Tag>` for immutable limiter configuration;
- `Registry<Tag>` for one-time deterministic claim of per-scope state;
- `State<Tag>` for live mutable accounting.

We should not make these first-release primitives:

- exact `sliding_window`;
- tokenized quota / credits;
- queue-based throttling.

<aside>
💡

### Why `Tag` is necessary

`Tag` is needed to create type-level separation between independent limiter domains.

Practical benefits:

- prevents accidental mixing of policies/states from unrelated integrations;
- lets one protocol use multiple independent limiter families safely (for example, `WithdrawTag`, `LiquidationTag`, `OracleUpdateTag`);
- improves auditability by making domain boundaries explicit at compile time.

Without `Tag`, all policies/states of the same strategy shape would be easier to confuse at integration boundaries.

</aside>

## Why This Is the Right Shape

### 1. Sui makes object placement as important as the algorithm

On Sui, a mathematically good limiter can still be the wrong design if every transaction has to mutate the same shared object.

That means the first design question is not only *which algorithm do we use?* It is also *where does the mutable state live?* and *does that create a bottleneck?*

### 2. Per-scope state is the safest default for a reusable library

Many real integrations are naturally scoped by:

- address;
- position object;
- vault;
- market;
- oracle feed;
- game character.

Those should not all be forced through one shared map.

A general-purpose library should make the high-parallelism path easy by default.

### 3. We need to prevent duplicate-state and recreate-to-reset bypasses

A per-user or per-object limiter is not safe if callers can create a fresh state object every time they want more quota.

Using a `Registry<Tag>` with `sui::derived_object` gives us a canonical one-time claim for each scope key.

That is what makes per-scope state safe enough for production use.

### 4. The hot path should mutate only the state object

Configuration changes are rare. Consumption is frequent.

So the architecture should reflect that:

- `Policy<Tag>` is mostly read-only;
- `Registry<Tag>` is only for first `State` claim;
- `State<Tag>` is the object touched on normal usage.

That keeps steady-state transactions simple and avoids unnecessary shared-object coordination.

### 5. Integrators need an API that is hard to misuse

The primary API should be `consume_or_abort(...)`.

- “consume” is abstract enough to cover any type of action that works with amounts: withdrawals, claims, deposits…

Read helpers should exist, but they should be clearly advisory.

## Recommended First-Release Scope

### Included

- `token_bucket` for burst-tolerant average-rate enforcement
- `fixed_window` for simple coarse limits
- `cooldown` for minimum delay between actions

### Excluded

- **Sliding window** is storage-heavy and not a good default for on-chain hot paths.
- **Queue-based throttling** is a scheduling subsystem, not a generic allow-or-reject limiter.
- **Quota tokens** are a different rights model. They are useful, but they change the product and security model materially.

### Additional implementation after first release

- **Rolling window**: approximates a true sliding window using current and previous window usage. It computes effective usage by weighting overlap from the previous window, reducing boundary-burst effects versus fixed window.
    - can be added after first release.

## Core Architecture

Each limiter strategy should follow the same structure:

- `Policy<Tag>`
- `Registry<Tag>`
- `State<Tag>`
- read helpers
- enforcing mutators
- optional migration helpers

### `Policy<Tag>`

Purpose:

- stores the limiter configuration;
- is usually immutable at runtime;
- gives each state object a specific policy to bind to.

Why immutable is the right default:

- it avoids shared mutable config in the hot path;
- policy changes become explicit and auditable;
- old states do not silently change behavior underneath integrators.

If a protocol wants new parameters, the safest default is:

1. create a new `Policy<Tag>` object;
2. update the protocol to use it;
3. migrate old states only if needed.

When a `Policy` is updated, deprecated `Policy` abuse can be prevented in a couple of ways:

1. Enforce that a new `Policy` can only be created if the old `Policy` is destroyed
2. Enforce that a new `Policy` can only be created if the old `Policy.enabled`  is set to false in the same transaction.

### `Registry<Tag>`

Purpose:

- creates one canonical state per scope using `sui::derived_object::claim`;
- prevents duplicate-state bypass;
- separates one-time claim from steady-state usage.

Why we need it:

Without a registry-like claim mechanism, we usually end up with one of two bad patterns:

- anyone can create fresh state and reset themselves;
- we keep a large mutable shared map of every scope.

Both are poor defaults for Sui.

### `State<Tag>`

Purpose:

- stores the live accounting for one scope;
- is the object mutated by normal consume operations;
- binds usage to a policy and a scope.

Why this is the hot-path object:

- it keeps updates O(1);
- it avoids re-touching registry state after initialization;
- it matches Sui's parallelism model better.

## Scope Model

The library should support scopes, not identities.

Recommended scope kinds:

- `GLOBAL`
- `ADDRESS`
- `OBJECT`
- `BYTES`

Examples:

- `GLOBAL`: total outflow limit for one vault
- `ADDRESS`: one rate limit per user address
- `OBJECT`: one rate limit per position object or oracle feed object
- `BYTES`: protocol-defined custom buckets

<aside>
💡

A per-address limit is not Sybil resistance. It is a rate limit on a chosen scope.

</aside>

## Common Design Rules

These rules should apply across strategy modules.

### Rule 1: State must pin to a policy

Every `State<Tag>` should store `policy_id: ID`.

Why:

- prevents mixing a state object with the wrong policy;
- makes migrations explicit;
- gives a clear invariant for every consume path.

Without this field, behavior is less auditable because observers can no longer tell which exact policy config a state was evaluated under.

### Rule 2: Scope metadata should be visible in state

Each `State<Tag>` should include:

- `scope_kind: u8`
- `scope_key_hash: vector<u8>`

Why:

- helps off-chain indexing and debugging;
- makes the state auditable;
- gives integrators an easy sanity check when inspecting objects.

This metadata is for observability and validation. It is not the authorization mechanism by itself.

### Rule 3: Use `u64` externally and `u128` internally where needed

Why:

- Sui asset amounts are usually `u64`;
- integrator-facing APIs stay simple;
- refill and weighted-window arithmetic can safely use `u128` intermediates.

### Rule 4: Creation must initialize from the current clock

Time anchors such as `last_refill_ms` or `window_start_ms` should be initialized from the current clock value, not from zero.

Why:

- zero-based initialization can create incorrect first-use behavior;
- the state should begin from a real observed timestamp.

### Rule 5: The primary API should be enforce-and-mutate

The recommended primary entrypoint is `consume_or_abort(...)`.

Why:

- safer integration path;
- better default than check-then-act;
- easier to reason about during audits.

## Object Layouts

## `registry.move`

```
public struct Registry<phantom Tag> has key, store {
    id: UID,
    policy_id: ID,
}
```

### Field justification

- `id: UID`
    - defines the registry's identity;
    - serves as the namespace used for derived-object claims.
- `policy_id: ID`
    - binds the registry to one policy family;
    - prevents claims against the wrong policy.

This object should be used primarily during first-touch state creation, not on every consume path.

## `token_bucket.move`

This can be the default strategy we document first.

Token bucket keeps a spendable balance that refills over time at a configured rate. Each action consumes from current balance, allowing bursts up to `capacity` while enforcing a long-term average rate.

### Why token bucket is the default

It gives the best first-release balance of:

- O(1) storage;
- O(1) updates;
- burst tolerance;
- understandable behavior;
- flexibility across DeFi, gaming, and infrastructure use cases.

### Proposed objects

```
public struct Policy<phantom Tag> has key, store {
    id: UID,
    version: u16,
    capacity: u64,
    refill_numerator: u64,
    refill_denominator_ms: u64,
    initial_tokens: u64,
    enabled: bool,
}

public struct State<phantom Tag> has key, store {
    id: UID,
    policy_id: ID,
    scope_kind: u8,
    scope_key_hash: vector<u8>,
    available: u64,
    last_refill_ms: u64,
    fractional_remainder: u64,
}
```

### Field justification

### `Policy<Tag>`

- `id: UID`
    - identifies this exact policy object.
- `version: u16`
    - supports migrations, audits, and tooling;
    - gives us an explicit config version without over-engineering the object.
- `capacity: u64`
    - defines the maximum burst size;
    - is the core parameter that limits instant usage.
- `refill_numerator: u64`
    - stores the numerator of the refill rate.
- `refill_denominator_ms: u64`
    - stores the denominator in milliseconds.
- `initial_tokens: u64`
    - makes first-state budget explicit;
    - lets integrators choose between full, partial, or zero initial allowance.
- `enabled: bool`
    - gives an operational kill switch;
    - avoids deleting objects during incident response.

<aside>
💡

Why use `refill_numerator / refill_denominator_ms` instead of one integer rate:

- many practical rates are fractional at millisecond precision;
- integer tokens-per-ms is too coarse;
- rational refill avoids silently rounding low refill rates down to zero.
</aside>

**Alternative design that excludes `enabled` - let the protected asset/protocol enforce pausability before calling the limiter.**

- keeps the rate limiter focused on quota/timing logic only;
- avoids mixing emergency protocol controls with limiter state design;
- lets protocols reuse their existing pause/governance mechanisms;
- preserves a stricter immutable-policy model if desired.

### `State<Tag>`

- `id: UID`
    - identifies this scope-specific accounting object.
- `policy_id: ID`
    - pins the state to one policy;
    - prevents accidental state/policy mismatch.
- `scope_kind: u8`
    - describes whether the scope is global, address, object, or custom bytes.
- `scope_key_hash: vector<u8>`
    - stores an encoded or hashed scope representation for auditability and indexing.
- `available: u64`
    - tracks the currently spendable quota.
- `last_refill_ms: u64`
    - marks the last time refill was applied.
- `fractional_remainder: u64`
    - preserves partial refill precision between transactions;
    - prevents slow refill rates from being lost forever due to rounding.

### Refill behavior

The refill logic should use a single internal helper built around this model:

```
accrual = elapsed_ms * refill_numerator + fractional_remainder
whole = accrual / refill_denominator_ms
fractional_remainder = accrual % refill_denominator_ms
available = min(capacity, available + whole)
```

<aside>
💡

Important rule: if `available` reaches `capacity`, clear the remainder instead of letting hidden refill keep accumulating beyond the cap.

</aside>

## `fixed_window.move`

Fixed window tracks total usage inside one discrete time window. When the window rolls over, usage resets and a fresh window starts (e.g. bank ATM).

### When to use it

Use fixed window for:

- coarse request-count limits;
- anti-spam protection;
- simple daily or hourly caps;
- low-sensitivity administrative pacing.

### Proposed objects

```
public struct Policy<phantom Tag> has key, store {
    id: UID,
    version: u16,
    window_ms: u64,
    limit: u64,
    enabled: bool,
}

public struct State<phantom Tag> has key, store {
    id: UID,
    policy_id: ID,
    scope_kind: u8,
    scope_key_hash: vector<u8>,
    window_start_ms: u64,
    used: u64,
}
```

### Field justification

- `window_ms: u64`
    - defines the accounting interval.
- `limit: u64`
    - defines the total amount allowed inside one window.
- `window_start_ms: u64`
    - anchors the active window.
- `used: u64`
    - tracks total usage in the active window.

Why keep it in v1:

- it is simple;
- many integrators still need a coarse limiter;
- it is easy to explain and audit.

## `cooldown.move`

Cooldown enforces a minimum delay between successful actions for the same scope. Each success updates `last_action_ms`, and the next action must wait until `now >= last_action_ms + cooldown_ms`.

### When to use it

Use cooldown when the requirement is simply: *this scope must wait N milliseconds between successful actions*.

### Proposed objects

```
public struct Policy<phantom Tag> has key, store {
    id: UID,
    version: u16,
    cooldown_ms: u64,
    enabled: bool,
}

public struct State<phantom Tag> has key, store {
    id: UID,
    policy_id: ID,
    scope_kind: u8,
    scope_key_hash: vector<u8>,
    last_action_ms: u64,
}
```

### Field justification

- `cooldown_ms: u64`
    - stores the minimum required delay.
- `last_action_ms: u64`
    - stores when the last successful action occurred.

Why keep it in v1 even though it is mathematically simple:

- integrators still need a safe standard implementation;
- the real value is standardized state binding, scope handling, and API consistency.

### Read helpers

```
public fun available<Tag>(policy: &Policy<Tag>, state: &State<Tag>, clock: &Clock): u64
public fun refill_preview<Tag>(policy: &Policy<Tag>, state: &State<Tag>, clock: &Clock): u64
```

Use these for:

- UI preview;
- analytics;
- simulation;
- non-authoritative checks.

### Enforcing helper

```
public fun consume_or_abort<Tag>(policy: &Policy<Tag>, state: &mut State<Tag>, amount: u64, clock: &Clock)
```

Why this should be primary:

- it performs the authoritative check and state update together;
- it is harder to misuse than a two-step API;
- it makes audits simpler.

### Claim helpers

```
public fun create_policy<Tag>(...): Policy<Tag>
public fun create_registry<Tag>(policy: &Policy<Tag>, ctx: &mut TxContext): Registry<Tag>
public fun claim_for_address<Tag>(registry: &mut Registry<Tag>, policy: &Policy<Tag>, owner: address, clock: &Clock, ctx: &mut TxContext): State<Tag>
public fun claim_for_object<Tag>(registry: &mut Registry<Tag>, policy: &Policy<Tag>, object_id: ID, clock: &Clock, ctx: &mut TxContext): State<Tag>
public fun create_global_state<Tag>(policy: &Policy<Tag>, clock: &Clock, ctx: &mut TxContext): State<Tag>
```

Why we need explicit claim helpers:

- makes the lifecycle easy to understand;
- prevents each integrator from inventing its own state-claim pattern;
- gives us one standard way to enforce uniqueness.

### Important invariants

Every strategy should enforce at least these invariants:

- `state.policy_id == object::id(policy)` on consume paths;
- creation initializes time anchors from the current clock;
- initial budget is explicit;
- the library does not expose a casual `State` reset helper.

## Practical Examples

### Example 1: DeFi withdrawal guard

### Goal

Protect a vault from fast outflows while also stopping one user from consuming all shared capacity.

### Recommended composition

- one shared global token bucket per vault;
- one address-scoped token bucket per user;
- optional per-transaction hard cap enforced by the vault itself.

### Why this is the right design

- the global bucket protects protocol-level outflow pacing;
- the per-user bucket improves fairness;
- the per-tx cap is simpler as normal vault logic, not as a separate limiter primitive.

### Example flow

```
public fun withdraw(
    vault: &mut Vault,
    global_policy: &token_bucket::Policy<VaultWithdrawTag>,
    global_state: &mut token_bucket::State<VaultWithdrawTag>,
    user_policy: &token_bucket::Policy<UserWithdrawTag>,
    user_state: &mut token_bucket::State<UserWithdrawTag>,
    amount: u64,
    clock: &Clock,
) {
    token_bucket::consume_or_abort(global_policy, global_state, amount, clock);
    token_bucket::consume_or_abort(user_policy, user_state, amount, clock);
    vault::withdraw_unchecked(vault, amount);
}
```

Why this composition works well on Sui:

- it is atomic;
- if either limiter aborts, nothing is partially consumed;
- it is easy to extend with additional guardrails.

### Example 2: Per-position withdraw limiter

### Goal

Limit withdrawals per lending position or vault position object, not per wallet address.

### Why this matters

If the economic unit is the position object, `OBJECT` scope is a better fit than `ADDRESS` scope.

This avoids forcing multiple positions controlled by one address into the same quota bucket when that is not the desired product behavior.

### Example flow

```
public fun claim_position_limiter(
    registry: &mut registry::Registry<PositionTag>,
    policy: &token_bucket::Policy<PositionTag>,
    position_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
): token_bucket::State<PositionTag> {
    registry::claim_for_object(registry, policy, position_id, clock, ctx)
}
```

```
public fun withdraw_from_position(
    position: &mut Position,
    policy: &token_bucket::Policy<PositionTag>,
    state: &mut token_bucket::State<PositionTag>,
    amount: u64,
    clock: &Clock,
) {
    token_bucket::consume_or_abort(policy, state, amount, clock);
    position::withdraw_unchecked(position, amount);
}
```

### Example 3: Oracle update cooldown

### Goal

Prevent one oracle feed object from being updated too frequently.

### Recommended design

- use `cooldown`;
- scope by oracle feed object ID.

### Why cooldown is a good fit

This is not a budget problem. It is a minimum-delay problem.

That makes cooldown simpler and more correct than forcing the use case into a bucket model.

### Example flow

```
public fun update_feed(
    feed: &mut Feed,
    policy: &cooldown::Policy<FeedTag>,
    state: &mut cooldown::State<FeedTag>,
    clock: &Clock,
) {
    cooldown::consume_or_abort(policy, state, 1, clock);
    oracle::apply_update(feed);
}
```

The point of the example is not the literal signature. The point is that the feed object is the scope, and the limiter state is separate from protocol logic.

### Example 4: Game action throttle

### Goal

Throttle actions per character or avatar instead of per wallet.

### Recommended design

- use `cooldown` for actions with strict spacing;
- use `token_bucket` for actions that allow short bursts.

### Why object scope is better than address scope here

A player may legitimately control multiple characters. If the product thinks in terms of characters, the limiter should also think in terms of characters.

### Example flow

```
public fun use_skill(
    character: &mut Character,
    policy: &cooldown::Policy<CharacterSkillTag>,
    state: &mut cooldown::State<CharacterSkillTag>,
    clock: &Clock,
) {
    cooldown::consume_or_abort(policy, state, 1, clock);
    game::use_skill_unchecked(character);
}
```

## What We Are Deliberately Not Doing

## Not adding exact sliding window

Reason:

- it needs an action log or more complex sub-window state;
- it is expensive relative to its value as a default primitive;
- we should only add it later if we have a clearly justified production use case.

## Not treating quota tokens as a normal limiter strategy

Reason:

- transferable quota is not the same as non-transferable rate limiting;
- it changes fairness, delegation, and abuse properties;
- it should be treated as a separate product direction.

## Not building queue-based throttling into the core library

Reason:

- queues require application-specific rules around settlement, fairness, batching, and cancellation;
- that is a higher-level subsystem, not a generic limiter primitive.

## Future scope: cooldown plus execution window

An additional pattern to consider after v1 is a two-phase flow:

1. request action;
2. wait mandatory cooldown;
3. action becomes executable only within a bounded window;
4. if the window expires, request must be recreated.

Example: [Aave’s Umbrella](https://aave.com/help/umbrella/unstake), where unstaking includes a 20-day wait, then 2-day execution window.

This is not just a basic cooldown field; it is a higher-level state machine (`requested -> matured -> expired/executed`) and should be treated as future-scope module/application logic rather than core cooldown v1 behavior.
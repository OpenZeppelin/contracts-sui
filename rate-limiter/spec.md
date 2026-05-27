#### 1. Problem (short)

- What is being solved/improved?
    - Protocols on Sui repeatedly reimplement rate limiting (withdrawal throttles, daily caps, action cooldowns, mana/stamina) ad-hoc. Each implementation carries its own bugs around accrual math, configuration updates, and scope uniqueness. We want one small, audited primitive covering the three common strategies (token bucket, fixed window, cooldown) that can be embedded inside any integrator object without forcing a framework on them.
- Who is the target user (regular user / protocol / developer)?
    - Protocol developers integrating rate limits into Sui packages (vaults, bridges, games, RWA redemption flows, governance). Not end users — end users never touch the library types directly.

#### 2. Existing solutions

- What already exists in Sui?
    - [Deepbook margin `rate_limiter.move`](https://github.com/MystenLabs/deepbookv3/blob/fc77fb207169be2e79ca9c24aae4ae46431fad1b/packages/deepbook_margin/sources/rate_limiter.move) — a token bucket struct embedded in Deepbook's margin pool. Scoped to one protocol, not a reusable library.
    - Protocol-internal ad-hoc limiters scattered across published packages, typically as fields on the protocol's own object.
    - No general-purpose rate-limiter library in `sui-framework` or `MoveStdlib`.
- What does it do well / poorly?
    - **Well:** Deepbook's embedded approach is cheap, simple to audit, and matches Sui's ownership model.
    - **Poorly:** Every integrator re-derives the same bucket math and boundary-handling. No shared implementation of fixed window or cooldown. No tested reconfiguration semantics (what happens to in-flight tokens when capacity shrinks).
- Which constraints come from Sui’s model (ownership, shared objects, upgrades, etc.)?
    - Shared library-owned objects (registries, policies with `key`) force every integrator to index and track external object IDs per environment — a significant DevX and indexing burden.
    - Dynamic object fields (DOFs) are ~2× the storage cost of dynamic fields and should be avoided for bounded state.
    - Integrators already own their product objects; scope uniqueness can ride on that ownership rather than requiring a library-side registry.

#### 3. Integration surface

- What does the integrator add on their end?
    - a `RateLimiter` field inside their own `key` object (owned or shared). Optionally a version counter for staged migration, or a `Table<K, RateLimiter>` for per-user/per-object limits.
- What comes from the library?
    - a single `RateLimiter` enum type (`store + drop`, no `key`, no UID), constructors (`new_bucket`, `new_fixed_window`, `new_cooldown`), hot-path functions (`consume_or_abort`, `try_consume`, `available`), and getters for snapshotting state (`capacity`, `refill_amount`, `refill_interval_ms`, `last_refill_ms`, `window_ms`, `window_start_ms`, `cooldown_ms`, `cooldown_end_ms`). There are deliberately **no** in-place reconfigure functions: reconfiguration is done by reading current state via the getters, constructing a fresh `RateLimiter`, and overwriting the field.
- What objects/capabilities are required, and which entities hold them?
    - none from the library. The library produces no shared objects, no admin caps, no registries. Admin gating, ownership checks, and migration cadence are integrator-owned concerns.
- How does the system get configured?
    - at construction time via the `new_*` constructor. At runtime the integrator reconfigures by reading current state through the getters (e.g. `available`, `capacity`, `last_refill_ms`, `window_start_ms`, `cooldown_end_ms` — the anchor getters project pending accrual/rollover so they pair coherently with `available`), computing the desired new field values, constructing a fresh `RateLimiter`, and overwriting the field from its own admin flow. The library validates structural invariants on construction; the choice of reconfiguration *semantics* (preserve anchor, project then re-anchor, full reset, proportional carry, freeze in-flight gate, ...) is entirely the integrator's.
- Ownership boundaries
    - Library owns: enum variant layout and accrual/window/cooldown math.
    - Integrator owns: which object carries the limiter, who can reconfigure, how configuration changes propagate to downstream state (immediate vs. staged/versioned).
- Link to design artifact
    - 
- Consumer-side integration sketch (high level — types and flow, not full code)
    
    ```rust
    public struct Vault has key {
        id: UID,
        admin: address,
        limiter: RateLimiter,   // <-- the only library type the integrator sees
        balance: Balance<SUI>,
    }
    
    public fun withdraw(self: &mut Vault, amount: u64, clock: &Clock, ctx: &mut TxContext): Coin<SUI> {
        self.limiter.consume_or_abort(amount, clock);       // rate-limit check
        coin::from_balance(self.balance.split(amount), ctx) // protocol action
    }
    ```
    

#### 4. Minimal end-to-end examples (required)

- Link to example repo/module(s)
    - [`library_scope/`](https://github.com/0xNeshi/rate-limiter-proposal/blob/master/library_scope/) — the `RateLimiter` library itself, with the full unit-test suite under [`library_scope/tests/`](https://github.com/0xNeshi/rate-limiter-proposal/blob/master/library_scope/tests/).
    - [`integrator_scope/sources/vault.move`](https://github.com/0xNeshi/rate-limiter-proposal/blob/master/integrator_scope/sources/vault.move) — shared vault with one embedded limiter for all withdrawals; `update_policy` rebuilds the limiter by reading `available` and constructing a fresh bucket.
    - [`integrator_scope/sources/mage_game.move`](https://github.com/0xNeshi/rate-limiter-proposal/blob/master/integrator_scope/sources/mage_game.move) — per-mage embedded limiter with versioned staged migration; `update_mage_policy` rebuilds each mage's limiter under the new config.
    - README also sketches two extension patterns: per-user `Table<address, RateLimiter>` and a time-scaled auto-updating super-policy wrapper.
- Happy path example
    - [`integrator_scope/tests/vault_tests.move::vault_users_share_one_global_bucket`](https://github.com/0xNeshi/rate-limiter-proposal/blob/master/integrator_scope/tests/vault_tests.move) — two users share one embedded bucket; second user sees reduced headroom after the first withdraws.
    - [`integrator_scope/tests/mage_game_tests.move::mages_have_independent_mana_and_regenerate_over_time`](https://github.com/0xNeshi/rate-limiter-proposal/blob/master/integrator_scope/tests/mage_game_tests.move) — two mages have independent limiters; both refill correctly after time advances.
- Failing case example
    - [`integrator_scope/tests/vault_tests.move::vault_second_user_fails_after_global_capacity_is_consumed`](https://github.com/0xNeshi/rate-limiter-proposal/blob/master/integrator_scope/tests/vault_tests.move) — second withdraw aborts with `rate_limiter::ERateLimited`.
    - [`integrator_scope/tests/mage_game_tests.move::mage_must_upgrade_to_latest_policy_before_casting`](https://github.com/0xNeshi/rate-limiter-proposal/blob/master/integrator_scope/tests/mage_game_tests.move) — a mage that skipped migration aborts with `mage_game::EStaleMagePolicy`.
    - [`library_scope/tests/rate_limiter_tests.move::refill_amount_on_non_bucket_aborts`](https://github.com/0xNeshi/rate-limiter-proposal/blob/master/library_scope/tests/rate_limiter_tests.move) — variant-specific getters reject cross-variant access with `EWrongVariant`.

#### 5. Invariants summary

Embeddable rate-limiting primitive (`store + drop`) with three variants - `Bucket`, `FixedWindow`, `Cooldown` - sharing one API. Authorization is delegated entirely to whoever holds `&mut` to the embedded field. The module exposes no in-place reconfigure: changing a limiter's configuration or runtime state is done by reading current state through the getters, constructing a fresh `RateLimiter`, and overwriting the field. The library validates structural invariants on construction; the choice of reconfiguration *semantics* is the integrator's.

- Link to invariants artifact
    
    [Rate Limiter - Invariants](https://www.notion.so/Rate-Limiter-Invariants-359cbd1278608093be53e729d2e96547?pvs=21)
    
    - the invariants below are enforced by the library and covered by the unit tests in [`library_scope/tests/rate_limiter_tests.move`](<repo>/library_scope/tests/rate_limiter_tests.move) plus the integration-level tests in [`integrator_scope/tests/`](<repo>/integrator_scope/tests/).
- Critical invariants (type-level, runtime, economic) — 3–5 max
    1. **No key, no UID, no shared library objects.** `RateLimiter` has abilities `store + drop` only; uniqueness is always provided by the integrator's enclosing object.
    2. **Bounded accrual.** The single `available` counter never exceeds `capacity` in any variant; refill (Bucket), window rollover (FixedWindow), and cooldown release (Cooldown) only credit when the clock has advanced, and intervals that elapse while the bucket sits at capacity are discarded rather than re-credited as fresh headroom.
    3. **Variant fixed at construction.** A `RateLimiter` is exactly one of `Bucket | FixedWindow | Cooldown`; no `&mut` operation changes the variant. Variant-specific getters abort with `EWrongVariant` when called on the wrong variant. Switching variant requires constructing a fresh value and overwriting the field.
    4. **Construction validates structure, not policy.** Constructors reject zero or contradictory configs (`EZeroCapacity`, `EZeroRefillAmount`, `EZeroRefillInterval`, `EZeroWindow`, `EZeroCooldown`, `EInitialAboveCapacity`, `EBucketAnchorInFuture`, `EWindowAnchorInFuture`, `ECooldownArmedWithTokens`). Reconfiguration semantics are the integrator's, expressed via getters + construct-fresh.
    5. **Zero-amount is a programmer error.** `try_consume` aborts with `EInvalidAmount` when `amount == 0`, uniformly across all variants. `Cooldown` counts each consume by `amount`, drawing `available` down; up to `capacity` units may be spent per batch before the gate arms for `cooldown_ms`.

#### 6. Why this is better (the delta)

- Improvements over existing solutions
    - **One type instead of three objects.** Replaces `Policy + Registry + State` with a single `RateLimiter` enum that lives inside the integrator's own struct.
    - **No registry to index.** Front ends and indexers do not need to track per-environment library object IDs.
    - **No policy-ID assertion footgun.** There is no separate policy object to spoof, so the common Sui "lack-of-check" pattern is designed out.
    - **Cheaper storage.** No `key` ability, no UID, no dynamic object fields. The limiter is plain fields on an existing object.
    - **Three strategies, one API.** `Bucket`, `FixedWindow`, and `Cooldown` all expose the same `consume_or_abort` / `try_consume` / `available` surface.
    - **State is fully inspectable.** Getters project pending accrual / window rollover so that any reconfigure policy is expressible as read-getters → construct-fresh → overwrite, with no bespoke library migration API and no hidden clamp semantics to reason about.
- Tradeoffs introduced
    - **Variant fixed at construction.** Switching a limiter from `Bucket` to `FixedWindow` requires overwriting the whole field — intentional, to keep the type small and the math unambiguous.
    - **Enum pays for the widest variant.** `Bucket` has 5 × u64 of payload; `FixedWindow` and `Cooldown` need 4. Still cheaper than an object-per-instance model.
    - **No library-side admin model.** All admin gating, versioning, and cross-user migration lives in the integrator. The library is intentionally unopinionated here.
    - **No reconfigure helper.** The library exposes no `reconfigure_*`; integrators read the getters and reconstruct. This keeps the surface minimal and the semantics explicit, at the cost of a few lines of integrator glue per reconfigure.
- What it does NOT solve
    - Global-to-per-user migration of already-created limiters; integrators do that via their own flow (e.g., the `Table<address, RateLimiter>` lazy-mint pattern in the README).
    - Cross-module rate limiting where one limiter is shared between packages — still an integrator concern (put the limiter inside one shared object that both packages depend on).
    - Any form of observability/events; emitting `Consumed` / `Reconfigured` events is left to the integrator.
    - Automatic time-scaled policies. The README shows a ~50-line super-policy wrapper pattern; making it a library feature would couple the primitive to one scaling model.

#### 7. Review readiness

- [x]  Problem is written down
- [x]  Research documented
- [x]  Design artifact exists with ownership model decision
- [x]  Invariants listed
- [x]  Integration surface is clear (consumer sketch compiles conceptually)
- [x]  Examples compile
- [x]  Examples include happy + failing cases
- [x]  Delta is explicit (why this is better, what it doesn’t solve)
- [x]  Open questions listed

#### Open questions / follow-ups

- ~~Should `Cooldown` support multi-unit semantics ("N uses then enforce cooldown")?~~ **Resolved:** implemented. `Cooldown` now counts each consume by `amount` and allows up to `capacity` units per batch before arming the gate.
- Should the library emit a `Consumed` event directly from `consume_or_abort` / `try_consume`, or stay strictly silent and leave events to integrators? Direct emission gives uniform observability but fixes the event ABI and charges every caller for gas they may not want; library-owned events also can't carry integrator context (which user, which object) without wrapping, which is the typical reason integrators end up emitting their own anyway.
- ~~Should `new_bucket` default to "start full" or "start empty"?~~ **Resolved:** there is no default. `new_bucket` takes an explicit `initial_available` (and `last_refill_ms` anchor), so the caller always chooses the starting balance and refill phase; the separate `new_bucket_with_tokens` constructor was folded away.
- As mentioned above, enum's payload is equal to the widest variant (Bucket). There's potentially a minor gas overhead for enum matching in functions. Alternative to this is separate rate limiter type structs in separate modules, but the price is that devs now have 3 modules to potentially juggle. Do we keep the enum design?

Tracking issue: https://github.com/OpenZeppelin/contracts-sui/issues/136
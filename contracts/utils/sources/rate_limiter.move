/// A small, embeddable rate-limiting primitive for Sui.
///
/// `RateLimiter` is a plain `store + drop` value that integrators embed as a field inside
/// their own objects. There is no registry, no policy object, and no separate ID that
/// integrators must track and assert against: the limiter's scope is whatever object it
/// lives inside.
///
/// Three strategies are provided in one enum, all sharing the same API:
/// - `Bucket` - continuously refilling token bucket with a configurable refill schedule,
/// - `FixedWindow` - up to `capacity` units per fixed-length window anchored at a chosen start,
/// - `Cooldown` - up to `capacity` units before requiring a `cooldown_ms` wait.
///
/// Typical lifecycle:
/// 1. the integrator creates a limiter with one of the `new_*` constructors and stores it in
///    their own struct,
/// 2. hot paths call `consume_or_abort` or `try_consume`,
/// 3. read paths call `available` for inspection,
/// 4. when configuration or runtime state must change, the integrator constructs a fresh
///    `RateLimiter` with the desired field values (reading current state via `available`,
///    `capacity`, `window_start_ms`, `cooldown_end_ms`, etc.) and overwrites the field.
///
/// # Examples
///
/// > **Warning:** These are **unaudited illustrations** of how the primitive can be integrated,
/// > not production-ready code.
///
/// Integration examples live in https://github.com/OpenZeppelin/contracts-sui/blob/release-v1.3/contracts/utils/examples/rate_limiter:
/// - [`faucet`](https://github.com/OpenZeppelin/contracts-sui/blob/release-v1.3/contracts/utils/examples/rate_limiter/faucet.move) - a per-holder token bucket composed with a global window across two objects.
/// - [`staking_vault`](https://github.com/OpenZeppelin/contracts-sui/blob/release-v1.3/contracts/utils/examples/rate_limiter/staking_vault.move) - a cooldown armed as a one-shot timelock that gates claims until an unbonding delay elapses.
/// - [`mage_duel`](https://github.com/OpenZeppelin/contracts-sui/blob/release-v1.3/contracts/utils/examples/rate_limiter/mage_duel.move) - many limiters of mixed variants packed into one type: per-mage health and mana buckets plus per-spell cooldowns.
///
/// # Operator responsibilities
///
/// Configs only need positivity; the implementation handles internal overflow safety
/// without further upper bounds. One operator-side caveat: for `Cooldown`, the deadline
/// is computed as `now + cooldown_ms`. The Sui `Clock` is monotonic and bounded well
/// below `u64::MAX`, but `cooldown_ms` near `u64::MAX` would overflow this addition.
/// Operators must pick `cooldown_ms` such that `now + cooldown_ms` cannot overflow at
/// any plausible chain timestamp during the limiter's lifetime - any policy-meaningful
/// value (seconds to days to years in ms) satisfies this trivially. The arming site
/// guards this explicitly: an overflowing deadline aborts with `ECooldownDeadlineOverflow`.
///
/// Any function taking `&mut RateLimiter` mutates live state. Gate the entry functions
/// that expose them with whatever authorization model is appropriate for the call site
/// (`Cap`, `openzeppelin_access`, governance, multisig, ...). The module is agnostic.
///
/// # Reconfiguration
///
/// This module deliberately does not provide in-place reconfigure functions. To change a
/// limiter's configuration or runtime state, read the current state via the getters,
/// compute the desired new field values, construct a fresh `RateLimiter`, and overwrite
/// the field. Every reconfigure policy - preserve anchor, project then re-anchor, full
/// reset, proportional carry, freeze in-flight gate, etc. - is expressible in caller code.
/// The library validates structural invariants on construction; the choice of semantics is
/// entirely the integrator's.
///
/// One semantic pitfall the library does not guard against: a `Bucket`'s (or `FixedWindow`'s)
/// anchor may be carried over from the old limiter only when the rate is unchanged - that is,
/// `refill_amount` and `refill_interval_ms` (or `window_ms`) stay the same. Accrual applies
/// the *current* rate over the entire span since the anchor, so preserving an old anchor while
/// changing the rate re-prices time that elapsed under the previous rate, minting tokens
/// instantly. Any change to the rate must re-anchor to `clock.timestamp_ms()` so the new rate
/// only applies going forward.
///
/// # Observability
///
/// This module deliberately emits no events. The limiter has no stable identity of its own -
/// it shares the on-chain identity of the integrator-owned object hosting it. Emitting events
/// for rate-limit hits, cooldown arming, and reconfiguration is therefore the integrator's
/// responsibility, at their own entry functions where the hosting object's ID and call
/// context are available.
///
/// # Upgrade compatibility
///
/// `RateLimiter` is a `public enum` embedded inside integrator-owned objects. Adding a new
/// variant or new fields to an existing variant in a future package upgrade is not a
/// binary-compatible change: any object that already stored a prior shape would fail to
/// deserialize. Future evolution must either preserve the current variant set and field
/// layouts, or ship as a parallel `RateLimiterV2` type with a migration path for integrators.
module openzeppelin_utils::rate_limiter;

use sui::clock::Clock;

// === Errors ===

/// The limiter cannot satisfy the requested consume against its current state.
#[error(code = 0)]
const ERateLimited: vector<u8> = "Rate limited";
/// Capacity must be greater than zero.
#[error(code = 1)]
const EZeroCapacity: vector<u8> = "Capacity must be greater than zero";
/// A variant-typed function was called on a limiter of a different variant.
#[error(code = 2)]
const EWrongVariant: vector<u8> = "Wrong rate limiter variant";
/// Consume amount must be greater than zero; a zero-unit consume is a programmer error,
/// not a rate-limit decision.
#[error(code = 3)]
const EInvalidAmount: vector<u8> = "Amount must be greater than zero";
/// Refill amount must be greater than zero.
#[error(code = 4)]
const EZeroRefillAmount: vector<u8> = "Refill amount must be greater than zero";
/// Refill interval must be greater than zero.
#[error(code = 5)]
const EZeroRefillInterval: vector<u8> = "Refill interval must be greater than zero";
/// Window must be greater than zero.
#[error(code = 6)]
const EZeroWindow: vector<u8> = "Window must be greater than zero";
/// Cooldown must be greater than zero.
#[error(code = 7)]
const EZeroCooldown: vector<u8> = "Cooldown must be greater than zero";
/// Initial available amount must not exceed capacity.
#[error(code = 8)]
const EInitialAboveCapacity: vector<u8> = "Initial available amount must not exceed capacity";
/// `FixedWindow` anchor strictly in the future would underflow the next projection.
#[error(code = 9)]
const EWindowAnchorInFuture: vector<u8> = "Window start must not be in the future";
/// `Cooldown` with both `initial_available > 0` and a future `cooldown_end_ms` is
/// self-contradictory: the hot path ignores the gate while `available > 0`, so the
/// seeded deadline would be silently dropped the next time the batch drains.
#[error(code = 10)]
const ECooldownArmedWithTokens: vector<u8> =
    "An active cooldown deadline cannot be set together with an initial available amount";
/// `Bucket` refill anchor strictly in the future would underflow the next projection.
#[error(code = 11)]
const EBucketAnchorInFuture: vector<u8> = "Last refill time must not be in the future";
/// Arming a `Cooldown` gate would overflow `now + cooldown_ms`. See "Operator responsibilities".
#[error(code = 12)]
const ECooldownDeadlineOverflow: vector<u8> =
    "Cooldown deadline (now + cooldown_ms) would overflow u64";

// === Structs ===

/// One embeddable limiter, three strategies. The variant is chosen at construction and can
/// only be swapped by building a fresh `RateLimiter` and overwriting the field.
///
/// All variants store an `available` counter that starts at `initial_available` and is
/// decremented by successful `try_consume` calls. Refill (Bucket), window rollover
/// (FixedWindow), and cooldown release (Cooldown) all reset `available` back toward `capacity`.
/// A failed `try_consume` (returning `false`) leaves persisted state untouched across all
/// variants; pending time transitions are still observable through `available()`, which always
/// projects on read.
public enum RateLimiter has drop, store {
    /// Continuously refilling bucket. `available` accrues `refill_amount` every
    /// `refill_interval_ms`, capped at `capacity`. Each `try_consume` draws `available` down.
    Bucket {
        capacity: u64,
        refill_amount: u64,
        refill_interval_ms: u64,
        last_refill_ms: u64,
        available: u64,
    },
    /// Up to `capacity` units per window of length `window_ms`, anchored at `window_start_ms`
    /// (defaults to creation time, but may be backdated to preserve window phase across a
    /// reconstruction). `available` resets to `capacity` when current time crosses into a
    /// later window boundary.
    FixedWindow {
        capacity: u64,
        window_ms: u64,
        window_start_ms: u64,
        available: u64,
    },
    /// Up to `capacity` units may be consumed before the limiter gates on `cooldown_ms`.
    /// Each successful `try_consume(amount, _)` decrements `available` by `amount` and
    /// rejects when `amount` exceeds the projected headroom (the stored `available`, or
    /// `capacity` once the gate has elapsed). Once `available` reaches `0`, `cooldown_end_ms`
    /// is set to `now + cooldown_ms` - the absolute deadline at which the gate releases.
    /// No further consume succeeds until `now >= cooldown_end_ms`, at which point
    /// `available` resets to `capacity` and the next batch is granted. `cooldown_end_ms`
    /// is taken into account only once the limiter has been drained and the gate is armed.
    Cooldown {
        capacity: u64,
        cooldown_ms: u64,
        cooldown_end_ms: u64,
        available: u64,
    },
}

// === Public Functions ===

// === Constructors ===

/// Create a token bucket with an explicit initial token balance.
///
/// #### Parameters
/// - `capacity`: Maximum token balance the bucket can hold.
/// - `refill_amount`: Tokens credited per refill interval.
/// - `refill_interval_ms`: Length of one refill interval, in milliseconds.
/// - `last_refill_ms`: Anchor for the refill schedule. For greenfield use, pass
///   `clock.timestamp_ms()`; pass an earlier value to preserve the refill phase, but only
///   when the rate is unchanged (see the `# Reconfiguration` section in module docs).
/// - `initial_available`: Starting token balance. Setting this to `0` forces the caller
///   to wait for the first refill interval before any consume succeeds.
/// - `clock`: Reference to the Sui `Clock`, used to validate the anchor.
///
/// #### Returns
/// - A new bucket `RateLimiter` ready to be embedded in the caller's object.
///
/// #### Aborts
/// - `EZeroCapacity` if `capacity == 0`.
/// - `EZeroRefillAmount` if `refill_amount == 0`.
/// - `EZeroRefillInterval` if `refill_interval_ms == 0`.
/// - `EBucketAnchorInFuture` if `last_refill_ms > clock.timestamp_ms()`.
/// - `EInitialAboveCapacity` if `initial_available > capacity`.
public fun new_bucket(
    capacity: u64,
    refill_amount: u64,
    refill_interval_ms: u64,
    last_refill_ms: u64,
    initial_available: u64,
    clock: &Clock,
): RateLimiter {
    assert!(capacity > 0, EZeroCapacity);
    assert!(refill_amount > 0, EZeroRefillAmount);
    assert!(refill_interval_ms > 0, EZeroRefillInterval);
    assert!(last_refill_ms <= clock.timestamp_ms(), EBucketAnchorInFuture);
    assert!(initial_available <= capacity, EInitialAboveCapacity);

    RateLimiter::Bucket {
        capacity,
        refill_amount,
        refill_interval_ms,
        last_refill_ms,
        available: initial_available,
    }
}

/// Create a fixed window limiter anchored at `window_start_ms`. Subsequent windows are
/// exactly `[window_start_ms + k * window_ms, window_start_ms + (k+1) * window_ms)` for
/// `k >= 0`. For greenfield use, pass `clock.timestamp_ms()` as `window_start_ms`; pass an
/// earlier value to seed a limiter that is already partway through a window.
///
/// A future anchor is rejected at construction; combined with the Sui `Clock`'s
/// monotonicity, this keeps `window_start_ms <= clock.timestamp_ms()` at every subsequent
/// call site so that the projection cannot underflow.
///
/// `initial_available` is meaningful only within the window containing the anchor. If the
/// anchor is backdated a full `window_ms` or more into the past, the first read crosses a
/// window boundary and resets the balance to `capacity`, silently discarding the seeded
/// value. For example, `new_fixed_window(5, 100, 0, 2)` read at timestamp `100` reports `5`,
/// not the seeded `2`, because one full window has elapsed since the anchor at `0`;
/// anchoring at `50` (still inside the first window) preserves the seeded `2`.
///
/// #### Parameters
/// - `capacity`: Maximum units consumable per window.
/// - `window_ms`: Length of one window, in milliseconds.
/// - `window_start_ms`: Anchor for the first window.
/// - `initial_available`: Starting available units for the current window.
/// - `clock`: Reference to the Sui `Clock`, used to validate the anchor.
///
/// #### Returns
/// - A new fixed window `RateLimiter` ready to be embedded in the caller's object.
///
/// #### Aborts
/// - `EZeroCapacity` if `capacity == 0`.
/// - `EZeroWindow` if `window_ms == 0`.
/// - `EWindowAnchorInFuture` if `window_start_ms > clock.timestamp_ms()`.
/// - `EInitialAboveCapacity` if `initial_available > capacity`.
public fun new_fixed_window(
    capacity: u64,
    window_ms: u64,
    window_start_ms: u64,
    initial_available: u64,
    clock: &Clock,
): RateLimiter {
    assert!(capacity > 0, EZeroCapacity);
    assert!(window_ms > 0, EZeroWindow);
    assert!(window_start_ms <= clock.timestamp_ms(), EWindowAnchorInFuture);
    assert!(initial_available <= capacity, EInitialAboveCapacity);

    RateLimiter::FixedWindow {
        capacity,
        window_ms,
        window_start_ms,
        available: initial_available,
    }
}

/// Create a cooldown limiter. Up to `capacity` units may be consumed (in any combination of
/// per-call `amount`s) before the limiter requires `cooldown_ms` to elapse before the next
/// batch.
///
/// The only rejected combination is `initial_available > 0` with `cooldown_end_ms > now`,
/// which is self-contradictory: the hot path consults `cooldown_end_ms` only when
/// `available == 0`, so a seeded future deadline would be silently dropped the next time
/// the batch drains. Every other pairing is valid:
/// - greenfield: `initial_available > 0` with `cooldown_end_ms <= now` (typically `0`). The
///   gate is not armed; up to `initial_available` units can be consumed before the first arm.
/// - in-flight gate: `initial_available == 0` with `cooldown_end_ms > now`, used when
///   reconstructing a limiter mid-throttle.
/// - released gate: `initial_available == 0` with `cooldown_end_ms <= now` (e.g. both `0`).
///   Projects to fully available on the next read or consume; useful when reconstructing a
///   limiter whose gate has just elapsed without recomputing `capacity`.
///
/// #### Parameters
/// - `capacity`: Maximum units consumable per batch.
/// - `cooldown_ms`: Wait, in milliseconds, between exhausting the batch and the next reset.
/// - `cooldown_end_ms`: Initial gate deadline. `<= now` means no gate armed.
/// - `initial_available`: Starting available units.
/// - `clock`: Reference to the Sui `Clock`, used to validate the gate-deadline pairing.
///
/// #### Returns
/// - A new cooldown `RateLimiter`.
///
/// #### Aborts
/// - `EZeroCapacity` if `capacity == 0`.
/// - `EZeroCooldown` if `cooldown_ms == 0`.
/// - `ECooldownArmedWithTokens` if `initial_available > 0 && cooldown_end_ms > clock.timestamp_ms()`.
/// - `EInitialAboveCapacity` if `initial_available > capacity`.
public fun new_cooldown(
    capacity: u64,
    cooldown_ms: u64,
    cooldown_end_ms: u64,
    initial_available: u64,
    clock: &Clock,
): RateLimiter {
    assert!(capacity > 0, EZeroCapacity);
    assert!(cooldown_ms > 0, EZeroCooldown);
    assert!(
        initial_available == 0 || cooldown_end_ms <= clock.timestamp_ms(),
        ECooldownArmedWithTokens,
    );
    assert!(initial_available <= capacity, EInitialAboveCapacity);

    RateLimiter::Cooldown {
        capacity,
        cooldown_ms,
        cooldown_end_ms,
        available: initial_available,
    }
}

// === Hot Path ===

/// Apply accrual, then consume `amount` or abort with `ERateLimited`.
///
/// #### Parameters
/// - `self`: Limiter being charged.
/// - `amount`: Units to consume.
/// - `clock`: Reference to the Sui `Clock`, used to apply accrual / window rollover / cooldown release.
///
/// #### Aborts
/// - `EInvalidAmount` if `amount == 0`.
/// - `ERateLimited` if the limiter cannot satisfy the request.
/// - `ECooldownDeadlineOverflow` if arming a `Cooldown` gate would overflow `now + cooldown_ms`.
public fun consume_or_abort(self: &mut RateLimiter, amount: u64, clock: &Clock) {
    assert!(amount > 0, EInvalidAmount);
    assert!(self.try_consume(amount, clock), ERateLimited);
}

/// Project state forward (accrual / window rollover / gate release), then consume `amount`
/// if the projected headroom allows it.
///
/// All-or-nothing: on success the projected state is committed and `amount` is deducted; on
/// failure (return `false`) persisted state is left untouched. Pending time transitions
/// remain observable through `available()`, which projects on read.
///
/// #### Parameters
/// - `self`: Limiter being charged.
/// - `amount`: Units to consume.
/// - `clock`: Reference to the Sui `Clock`, used to project accrual / window rollover / cooldown release.
///
/// #### Returns
/// - `true` if the consume succeeded.
/// - `false` if the limiter refused, or if `amount == 0`.
///
/// #### Aborts
/// - `ECooldownDeadlineOverflow` if arming a `Cooldown` gate would overflow `now + cooldown_ms`.
public fun try_consume(self: &mut RateLimiter, amount: u64, clock: &Clock): bool {
    if (amount == 0) return false;

    let now = clock.timestamp_ms();
    match (self) {
        RateLimiter::Bucket {
            capacity,
            refill_amount,
            refill_interval_ms,
            last_refill_ms,
            available,
        } => bucket_try_consume(
            *capacity,
            *refill_amount,
            *refill_interval_ms,
            last_refill_ms,
            available,
            amount,
            now,
        ),
        // FixedWindow is a Bucket with `refill_amount = capacity`: one elapsed window
        // refills the bucket exactly to the cap, mirroring window rollover semantics.
        RateLimiter::FixedWindow {
            capacity,
            window_ms,
            window_start_ms,
            available,
        } => bucket_try_consume(
            *capacity,
            *capacity,
            *window_ms,
            window_start_ms,
            available,
            amount,
            now,
        ),
        RateLimiter::Cooldown { capacity, cooldown_ms, cooldown_end_ms, available } => {
            let usable = if (*available > 0) *available
            else if (now >= *cooldown_end_ms) *capacity
            else return false;

            if (amount > usable) return false;

            *available = usable - amount;
            if (*available == 0) {
                assert!(*cooldown_ms <= std::u64::max_value!() - now, ECooldownDeadlineOverflow);
                *cooldown_end_ms = now + *cooldown_ms;
            };
            true
        },
    }
}

/// Read-only view of the currently available units (headroom) after projecting accrual,
/// window reset, or cooldown release.
///
/// For `Bucket` this is the number of tokens that could be consumed right now; for
/// `FixedWindow` it is the remaining headroom after any window rollover; for `Cooldown` it
/// is `capacity` if the cooldown has elapsed and the stored `available` otherwise.
///
/// Note: `try_consume(self.available(clock), clock)` returns `false` when `available()`
/// returns `0` (empty Bucket, exhausted FixedWindow, or gated Cooldown), because a
/// zero-unit consume is rejected. Guard with `if n > 0 { self.try_consume(n, clock) }`
/// or branch on `available()` directly.
///
/// #### Parameters
/// - `self`: Limiter to inspect.
/// - `clock`: Reference to the Sui `Clock`, used to project pending accrual / rollover / release.
///
/// #### Returns
/// - The number of units that can currently be consumed.
public fun available(self: &RateLimiter, clock: &Clock): u64 {
    let now = clock.timestamp_ms();
    match (self) {
        RateLimiter::Bucket {
            capacity,
            refill_amount,
            refill_interval_ms,
            last_refill_ms,
            available,
        } => {
            let (_, accrued) = bucket_accrue(
                *capacity,
                *refill_amount,
                *refill_interval_ms,
                *last_refill_ms,
                *available,
                now,
            );
            accrued
        },
        RateLimiter::FixedWindow { capacity, window_ms, window_start_ms, available } => {
            let (_, accrued) = bucket_accrue(
                *capacity,
                *capacity,
                *window_ms,
                *window_start_ms,
                *available,
                now,
            );
            accrued
        },
        RateLimiter::Cooldown { capacity, cooldown_end_ms, available, .. } => {
            if (*available > 0) *available
            else if (now >= *cooldown_end_ms) *capacity
            else 0
        },
    }
}

// === Getters ===
//
// These expose the inner fields a caller needs to rebuild a limiter with adjusted state.
// The bucket-shaped anchor getters (`last_refill_ms`, `window_start_ms`) take a `&Clock`
// and return projected values, so they pair coherently with `available(&self, clock)` for
// snapshotting state. `cooldown_end_ms` returns the stored value as-is (a cooldown deadline
// does not evolve with time); it is only semantically meaningful when `available(clock) == 0`.

/// Capacity of the limiter, regardless of variant.
public fun capacity(self: &RateLimiter): u64 {
    match (self) {
        RateLimiter::Bucket { capacity, .. } => *capacity,
        RateLimiter::FixedWindow { capacity, .. } => *capacity,
        RateLimiter::Cooldown { capacity, .. } => *capacity,
    }
}

/// Returns `true` if the limiter is a `Bucket`.
///
/// Variant-agnostic and never aborts. Use it (or its `is_fixed_window` / `is_cooldown`
/// siblings) to branch before calling a variant-typed getter, which would otherwise abort
/// with `EWrongVariant` on a mismatch. Intended for code that holds a limiter of unknown
/// variant - e.g. a `Table` mixing variants, or generic tooling - and cannot otherwise
/// introspect it.
public fun is_bucket(self: &RateLimiter): bool {
    match (self) {
        RateLimiter::Bucket { .. } => true,
        _ => false,
    }
}

/// Returns `true` if the limiter is a `FixedWindow`.
///
/// Variant-agnostic and never aborts. Use it (or its `is_bucket` / `is_cooldown`
/// siblings) to branch before calling a variant-typed getter, which would otherwise abort
/// with `EWrongVariant` on a mismatch. Intended for code that holds a limiter of unknown
/// variant - e.g. a `Table` mixing variants, or generic tooling - and cannot otherwise
/// introspect it.
public fun is_fixed_window(self: &RateLimiter): bool {
    match (self) {
        RateLimiter::FixedWindow { .. } => true,
        _ => false,
    }
}

/// Returns `true` if the limiter is a `Cooldown`.
///
/// Variant-agnostic and never aborts. Use it (or its `is_bucket` / `is_fixed_window`
/// siblings) to branch before calling a variant-typed getter, which would otherwise abort
/// with `EWrongVariant` on a mismatch. Intended for code that holds a limiter of unknown
/// variant - e.g. a `Table` mixing variants, or generic tooling - and cannot otherwise
/// introspect it.
public fun is_cooldown(self: &RateLimiter): bool {
    match (self) {
        RateLimiter::Cooldown { .. } => true,
        _ => false,
    }
}

/// Tokens credited per refill interval.
///
/// #### Aborts
/// - `EWrongVariant` if the limiter is not a `Bucket`.
public fun refill_amount(self: &RateLimiter): u64 {
    match (self) {
        RateLimiter::Bucket { refill_amount, .. } => *refill_amount,
        _ => abort EWrongVariant,
    }
}

/// Length of one refill interval, in milliseconds.
///
/// #### Aborts
/// - `EWrongVariant` if the limiter is not a `Bucket`.
public fun refill_interval_ms(self: &RateLimiter): u64 {
    match (self) {
        RateLimiter::Bucket { refill_interval_ms, .. } => *refill_interval_ms,
        _ => abort EWrongVariant,
    }
}

/// Projected timestamp of the latest refill checkpoint at `now`: the stored anchor
/// advanced by every whole `refill_interval_ms` that has elapsed since it was last
/// committed. Pairs coherently with `available(clock)` for snapshotting state before
/// reconstructing a bucket under a new configuration.
///
/// #### Aborts
/// - `EWrongVariant` if the limiter is not a `Bucket`.
public fun last_refill_ms(self: &RateLimiter, clock: &Clock): u64 {
    match (self) {
        RateLimiter::Bucket { last_refill_ms, refill_interval_ms, .. } => {
            project_anchor(*last_refill_ms, *refill_interval_ms, clock.timestamp_ms())
        },
        _ => abort EWrongVariant,
    }
}

/// Length of one window, in milliseconds.
///
/// #### Aborts
/// - `EWrongVariant` if the limiter is not a `FixedWindow`.
public fun window_ms(self: &RateLimiter): u64 {
    match (self) {
        RateLimiter::FixedWindow { window_ms, .. } => *window_ms,
        _ => abort EWrongVariant,
    }
}

/// Projected anchor of the current window at `now`: the stored anchor advanced by
/// every whole `window_ms` that has elapsed since it was last committed. Pairs
/// coherently with `available(clock)` for snapshotting state before reconstructing
/// under a new configuration.
///
/// #### Aborts
/// - `EWrongVariant` if the limiter is not a `FixedWindow`.
public fun window_start_ms(self: &RateLimiter, clock: &Clock): u64 {
    match (self) {
        RateLimiter::FixedWindow { window_ms, window_start_ms, .. } => {
            project_anchor(*window_start_ms, *window_ms, clock.timestamp_ms())
        },
        _ => abort EWrongVariant,
    }
}

/// Wait between batches, in milliseconds.
///
/// #### Aborts
/// - `EWrongVariant` if the limiter is not a `Cooldown`.
public fun cooldown_ms(self: &RateLimiter): u64 {
    match (self) {
        RateLimiter::Cooldown { cooldown_ms, .. } => *cooldown_ms,
        _ => abort EWrongVariant,
    }
}

/// Absolute deadline at which an armed cooldown gate releases. The hot path only
/// consults this when `available == 0`, so the value is only semantically meaningful
/// when `available(clock) == 0`; otherwise it is stale leftover from the last arm.
/// Exposed so callers reconstructing mid-throttle can preserve the in-flight deadline.
///
/// #### Aborts
/// - `EWrongVariant` if the limiter is not a `Cooldown`.
public fun cooldown_end_ms(self: &RateLimiter): u64 {
    match (self) {
        RateLimiter::Cooldown { cooldown_end_ms, .. } => *cooldown_end_ms,
        _ => abort EWrongVariant,
    }
}

// === Private Functions ===

/// Advance a bucket-shaped anchor by every whole `interval_ms` that has elapsed since
/// it was committed. `now` must be `>= anchor`; the constructors enforce this and the
/// `Clock` is monotonic.
fun project_anchor(anchor: u64, interval_ms: u64, now: u64): u64 {
    anchor + ((now - anchor) / interval_ms) * interval_ms
}

/// Project bucket-shaped state forward and consume `amount` on success. Shared by `Bucket`
/// and `FixedWindow` (the latter passes `refill_amount = capacity`, so one elapsed interval
/// refills exactly to the cap - the window-rollover semantics).
///
/// All-or-nothing: on success advances `last_refill_ms` to the latest completed boundary
/// and deducts `amount` from `available`; on failure leaves both untouched.
fun bucket_try_consume(
    capacity: u64,
    refill_amount: u64,
    refill_interval_ms: u64,
    last_refill_ms: &mut u64,
    available: &mut u64,
    amount: u64,
    now: u64,
): bool {
    let (new_last, new_available) = bucket_accrue(
        capacity,
        refill_amount,
        refill_interval_ms,
        *last_refill_ms,
        *available,
        now,
    );
    if (amount > new_available) return false;
    *available = new_available - amount;
    *last_refill_ms = new_last;
    true
}

/// Project a `Bucket`'s `(last_refill_ms, available)` forward to `now` under the given
/// configuration. Pure function: callers decide whether to persist the projected state.
///
/// Credits `refill_amount` per elapsed `refill_interval_ms` since `last_refill_ms`, capped
/// at `capacity`. The returned `last_refill_ms` is advanced to the latest completed refill
/// boundary at or before `now` whenever any whole step has elapsed - any sub-interval
/// remainder is preserved so accrual stays aligned to the original anchor. Intervals that
/// elapse after the bucket reaches capacity are overflow and are discarded by this same
/// advance, so a subsequent drain at the same `now` cannot re-mint them as fresh headroom.
///
/// #### Parameters
/// - `capacity`: Maximum token balance.
/// - `refill_amount`: Tokens credited per refill interval.
/// - `refill_interval_ms`: Length of one refill interval, in milliseconds.
/// - `last_refill_ms`: Timestamp of the last accrual checkpoint.
/// - `available`: Stored token balance at `last_refill_ms`.
/// - `now`: Current timestamp; must be `>= last_refill_ms`.
///
/// #### Returns
/// - `(new_last_refill_ms, new_available)`: the advanced anchor and projected balance.
fun bucket_accrue(
    capacity: u64,
    refill_amount: u64,
    refill_interval_ms: u64,
    last_refill_ms: u64,
    available: u64,
    now: u64,
): (u64, u64) {
    let elapsed_steps = (now - last_refill_ms) / refill_interval_ms;
    if (elapsed_steps == 0) return (last_refill_ms, available);
    // Both branches advance `last_refill_ms` by the full `elapsed_steps * refill_interval_ms`
    // so overflow intervals (those after the bucket reaches capacity) are discarded rather
    // than left as anchor drift that the next call would re-credit. The branch split below
    // also keeps all u64 products bounded without requiring upper bounds on `capacity` or
    // `refill_amount`.
    let headroom = capacity - available;
    let steps_to_full = headroom / refill_amount;
    // SAFETY: `elapsed_steps * refill_interval_ms <= now - last_refill_ms` (floor division above),
    // so the advanced `new_last <= now`. No overflow.
    let new_last = last_refill_ms + elapsed_steps * refill_interval_ms;
    if (elapsed_steps <= steps_to_full) {
        // SAFETY: Under-fill branch:
        // `elapsed_steps * refill_amount <= steps_to_full * refill_amount <= headroom <= capacity`,
        // so `available + credit <= capacity`. No overflow.
        let credit = elapsed_steps * refill_amount;
        (new_last, available + credit)
    } else {
        (new_last, capacity)
    }
}

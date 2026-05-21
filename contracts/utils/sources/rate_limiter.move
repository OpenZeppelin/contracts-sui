/// A small, embeddable rate-limiting primitive for Sui.
///
/// `RateLimiter` is a plain `store + drop` value that integrators embed as a field inside
/// their own objects. There is no registry, no policy object, and no separate ID that
/// integrators must track and assert against: the limiter's scope is whatever object it
/// lives inside.
///
/// Three strategies are provided in one enum, all sharing the same API:
/// - `Bucket` - continuously refilling token bucket with a configurable refill schedule,
/// - `FixedWindow` - up to `capacity` units per fixed-length window anchored at creation,
/// - `Cooldown` - up to `capacity` units before requiring a `cooldown_ms` wait.
///
/// Typical lifecycle:
/// 1. the integrator creates a limiter with one of the `new_*` constructors and stores it in
///    their own struct,
/// 2. hot paths call `consume_or_abort` or `try_consume`,
/// 3. read paths call `available` for inspection,
/// 4. when configuration changes, the integrator calls the matching `reconfigure_*` function
///    on its own object's limiter field.
///
/// # Operator responsibilities
///
/// Configs only need positivity; the implementation handles internal overflow safety
/// without further upper bounds. One operator-side caveat: for `Cooldown`, the deadline
/// is computed as `now + cooldown_ms`. The Sui `Clock` is monotonic and bounded well
/// below `u64::MAX`, but `cooldown_ms` near `u64::MAX` would overflow this addition.
/// Operators must pick `cooldown_ms` such that `now + cooldown_ms` cannot overflow at
/// any plausible chain timestamp during the limiter's lifetime - any policy-meaningful
/// value (seconds to days to years in ms) satisfies this trivially.
///
/// Any function taking `&mut RateLimiter` mutates live state. Gate the entry functions
/// that expose them with whatever authorization model is appropriate for the call site
/// (`Cap`, `openzeppelin_access`, governance, multisig, ...) - admin-level for
/// `reconfigure_*`, caller-level for `consume_*`. The module is agnostic.
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
/// Reconfigure target does not match the limiter's current variant.
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
/// Cooldown `initial_available` must be greater than zero. The cooldown gate is a
/// post-consumption penalty, so a "start drained" state has no consume to attach the
/// gate to and would silently behave as `initial_available == capacity`.
#[error(code = 9)]
const EZeroCooldownInitial: vector<u8> =
    "Cooldown initial available amount must be greater than zero";

// === Structs ===

/// One embeddable limiter, three strategies. The variant is chosen at construction and can
/// only be swapped by building a fresh `RateLimiter` and overwriting the field.
///
/// All variants store an `available` counter that starts at `initial_available` and is
/// decremented by `try_consume`. Refill (Bucket), window rollover (FixedWindow), and cooldown
/// release (Cooldown) all reset `available` back toward `capacity`.
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
    /// Up to `capacity` units per window of length `window_ms`, anchored at the limiter's
    /// creation time. `available` resets to `capacity` when current time crosses into a
    /// later window boundary.
    FixedWindow {
        capacity: u64,
        window_ms: u64,
        window_start_ms: u64,
        available: u64,
    },
    /// Up to `capacity` units may be consumed before the limiter gates on `cooldown_ms`.
    /// Each successful `try_consume(amount, _)` decrements `available` by `amount` and
    /// rejects when `amount > available`. Once `available` reaches `0`, `cooldown_end_ms`
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
/// - `initial_available`: Starting token balance. Must be `<= capacity`. Setting this to
///   `0` forces the caller to wait for the first refill interval before any consume succeeds.
/// - `clock`: Reference to the Sui `Clock`, used to anchor the first refill timestamp.
///
/// #### Returns
/// - A new bucket `RateLimiter` ready to be embedded in the caller's object.
///
/// #### Aborts
/// - `EZeroCapacity` if `capacity == 0`.
/// - `EZeroRefillAmount` if `refill_amount == 0`.
/// - `EZeroRefillInterval` if `refill_interval_ms == 0`.
/// - `EInitialAboveCapacity` if `initial_available > capacity`.
public fun new_bucket(
    capacity: u64,
    refill_amount: u64,
    refill_interval_ms: u64,
    initial_available: u64,
    clock: &Clock,
): RateLimiter {
    assert!(capacity > 0, EZeroCapacity);
    assert!(refill_amount > 0, EZeroRefillAmount);
    assert!(refill_interval_ms > 0, EZeroRefillInterval);
    assert!(initial_available <= capacity, EInitialAboveCapacity);

    RateLimiter::Bucket {
        capacity,
        refill_amount,
        refill_interval_ms,
        last_refill_ms: clock.timestamp_ms(),
        available: initial_available,
    }
}

/// Create a fixed window limiter with its first window anchored at `now`. Subsequent
/// windows are exactly `[now + k * window_ms, now + (k+1) * window_ms)` for `k >= 0`.
///
/// #### Parameters
/// - `capacity`: Maximum units consumable per window.
/// - `window_ms`: Length of one window, in milliseconds.
/// - `initial_available`: Starting available units for the first window.
/// - `clock`: Reference to the Sui `Clock`, used to anchor the first window.
///
/// #### Returns
/// - A new fixed window `RateLimiter` ready to be embedded in the caller's object.
///
/// #### Aborts
/// - `EZeroCapacity` if `capacity == 0`.
/// - `EZeroWindow` if `window_ms == 0`.
/// - `EInitialAboveCapacity` if `initial_available > capacity`.
public fun new_fixed_window(
    capacity: u64,
    window_ms: u64,
    initial_available: u64,
    clock: &Clock,
): RateLimiter {
    assert!(capacity > 0, EZeroCapacity);
    assert!(window_ms > 0, EZeroWindow);
    assert!(initial_available <= capacity, EInitialAboveCapacity);

    RateLimiter::FixedWindow {
        capacity,
        window_ms,
        window_start_ms: clock.timestamp_ms(),
        available: initial_available,
    }
}

/// Create a cooldown limiter. Up to `capacity` units may be consumed (in any combination of
/// per-call `amount`s) before the limiter requires `cooldown_ms` to elapse before the next
/// batch.
///
/// Unlike `Bucket` and `FixedWindow`, `Cooldown` does NOT support a "start drained" state:
/// the cooldown gate is a post-consumption penalty that only arms once a batch has been
/// drained by an actual `try_consume`. To force callers to wait before the first batch,
/// gate creation of the enclosing object, not the limiter's initial balance.
///
/// #### Parameters
/// - `capacity`: Maximum units consumable per batch.
/// - `cooldown_ms`: Wait, in milliseconds, between exhausting the batch and the next reset.
/// - `initial_available`: Starting available units. Must be `> 0` and `<= capacity`.
///
/// #### Returns
/// - A new cooldown `RateLimiter` with `initial_available` units available.
///
/// #### Aborts
/// - `EZeroCapacity` if `capacity == 0`.
/// - `EZeroCooldown` if `cooldown_ms == 0`.
/// - `EZeroCooldownInitial` if `initial_available == 0`.
/// - `EInitialAboveCapacity` if `initial_available > capacity`.
public fun new_cooldown(capacity: u64, cooldown_ms: u64, initial_available: u64): RateLimiter {
    assert!(capacity > 0, EZeroCapacity);
    assert!(cooldown_ms > 0, EZeroCooldown);
    assert!(initial_available > 0, EZeroCooldownInitial);
    assert!(initial_available <= capacity, EInitialAboveCapacity);

    RateLimiter::Cooldown {
        capacity,
        cooldown_ms,
        cooldown_end_ms: 0,
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
public fun consume_or_abort(self: &mut RateLimiter, amount: u64, clock: &Clock) {
    assert!(self.try_consume(amount, clock), ERateLimited);
}

/// Apply accrual, then consume `amount` if the limiter allows it.
///
/// A zero-unit consume is treated as a programmer error, not a rate-limit condition, so
/// behavior stays uniform across variants.
///
/// #### Parameters
/// - `self`: Limiter being charged.
/// - `amount`: Units to consume.
/// - `clock`: Reference to the Sui `Clock`, used to apply accrual / window rollover / cooldown release.
///
/// #### Returns
/// - `true` if the consume succeeded, `false` if the limiter refused.
///
/// #### Aborts
/// - `EInvalidAmount` if `amount == 0`.
public fun try_consume(self: &mut RateLimiter, amount: u64, clock: &Clock): bool {
    assert!(amount > 0, EInvalidAmount);
    let now = clock.timestamp_ms();
    match (self) {
        RateLimiter::Bucket {
            capacity,
            refill_amount,
            refill_interval_ms,
            last_refill_ms,
            available,
        } => {
            let (new_last, new_available) = bucket_accrue(
                *last_refill_ms,
                *available,
                *capacity,
                *refill_amount,
                *refill_interval_ms,
                now,
            );
            if (amount > new_available) return false;
            *available = new_available - amount;
            *last_refill_ms = new_last;
            true
        },
        RateLimiter::FixedWindow { capacity, window_ms, window_start_ms, available } => {
            let steps = (now - *window_start_ms) / *window_ms;
            if (steps != 0) {
                // SAFETY: `steps * window_ms <= now - window_start_ms` (floor division above),
                // so the advanced `window_start_ms <= now`. No overflow.
                *window_start_ms = *window_start_ms + steps * *window_ms;
                *available = *capacity;
            };
            if (amount > *available) return false;
            *available = *available - amount;
            true
        },
        RateLimiter::Cooldown { cooldown_ms, capacity, available, cooldown_end_ms } => {
            if (*available == 0) {
                if (now < *cooldown_end_ms) return false;
                *available = *capacity;
            };
            if (amount > *available) return false;
            *available = *available - amount;
            if (*available == 0) {
                // SAFETY: `now + cooldown_ms` overflow is the operator's responsibility
                // (see module-level "Operator responsibilities"). Trivially safe for any
                // policy-meaningful `cooldown_ms`.
                *cooldown_end_ms = now + *cooldown_ms;
            };
            true
        },
    }
}

/// Read-only view of the currently available capacity after applying accrual or window reset.
///
/// For `Bucket` this is the number of tokens that could be consumed right now; for
/// `FixedWindow` it is the remaining headroom after any window rollover; for `Cooldown` it
/// is `capacity` if the cooldown has elapsed and the stored `available` otherwise.
///
/// Note: `try_consume(self.available(clock), clock)` aborts with `EInvalidAmount` when
/// `available()` returns `0` (empty Bucket, exhausted FixedWindow, or gated Cooldown).
/// Guard with `if n > 0 { self.try_consume(n, clock) }` or branch on `available()` directly.
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
                *last_refill_ms,
                *available,
                *capacity,
                *refill_amount,
                *refill_interval_ms,
                now,
            );
            accrued
        },
        RateLimiter::FixedWindow { capacity, window_ms, window_start_ms, available } => {
            // A new window has begun once `window_ms` has elapsed since the current anchor.
            if (now - *window_start_ms >= *window_ms) *capacity else *available
        },
        RateLimiter::Cooldown { capacity, available, cooldown_end_ms, .. } => {
            if (*available > 0) *available
            else if (now >= *cooldown_end_ms) *capacity
            else 0
        },
    }
}

// === Reconfigure ===

/// Rewrite a `Bucket` limiter's configuration in place.
///
/// Accrues any tokens earned under the old rules first, then re-anchors the refill counter
/// at `now`, installs the new configuration, and clamps the stored token balance to the new
/// capacity. Any sub-interval remainder still pending under the old anchor is discarded -
/// future refills accrue from `now` under the new configuration.
///
/// #### Parameters
/// - `self`: Limiter to reconfigure.
/// - `capacity`: New maximum token balance.
/// - `refill_amount`: New tokens credited per refill interval.
/// - `refill_interval_ms`: New refill interval, in milliseconds.
/// - `clock`: Reference to the Sui `Clock`, used to apply accrual under the old config.
///
/// #### Aborts
/// - `EWrongVariant` if the limiter is not currently a `Bucket`.
/// - `EZeroCapacity` if `capacity == 0`.
/// - `EZeroRefillAmount` if `refill_amount == 0`.
/// - `EZeroRefillInterval` if `refill_interval_ms == 0`.
public fun reconfigure_bucket(
    self: &mut RateLimiter,
    capacity: u64,
    refill_amount: u64,
    refill_interval_ms: u64,
    clock: &Clock,
) {
    let now = clock.timestamp_ms();
    match (self) {
        RateLimiter::Bucket {
            capacity: cap_field,
            refill_amount: refill_amount_field,
            refill_interval_ms: refill_interval_field,
            last_refill_ms,
            available,
        } => {
            assert!(capacity > 0, EZeroCapacity);
            assert!(refill_amount > 0, EZeroRefillAmount);
            assert!(refill_interval_ms > 0, EZeroRefillInterval);

            let (_, new_available) = bucket_accrue(
                *last_refill_ms,
                *available,
                *cap_field,
                *refill_amount_field,
                *refill_interval_field,
                now,
            );
            *cap_field = capacity;
            *refill_amount_field = refill_amount;
            *refill_interval_field = refill_interval_ms;
            *last_refill_ms = now;
            *available = new_available.min(capacity);
        },
        _ => abort EWrongVariant,
    }
}

/// Rewrite a `FixedWindow` limiter's configuration in place.
///
/// Rolls the window forward under the old config if current time has crossed into a later
/// window, then re-anchors the window at `now`, installs the new configuration, and clamps
/// `available` to the new capacity. Future windows run for the new `window_ms` each,
/// anchored at `now`. If a rollover occurred under the old config, the new window starts
/// fully available under the new `capacity`.
///
/// #### Parameters
/// - `self`: Limiter to reconfigure.
/// - `capacity`: New maximum units consumable per window.
/// - `window_ms`: New window length, in milliseconds.
/// - `clock`: Reference to the Sui `Clock`, used to roll the anchor forward under the old config.
///
/// #### Aborts
/// - `EWrongVariant` if the limiter is not currently a `FixedWindow`.
/// - `EZeroCapacity` if `capacity == 0`.
/// - `EZeroWindow` if `window_ms == 0`.
public fun reconfigure_fixed_window(
    self: &mut RateLimiter,
    capacity: u64,
    window_ms: u64,
    clock: &Clock,
) {
    match (self) {
        RateLimiter::FixedWindow {
            capacity: cap_field,
            window_ms: window_field,
            window_start_ms,
            available,
        } => {
            assert!(capacity > 0, EZeroCapacity);
            assert!(window_ms > 0, EZeroWindow);

            // Roll forward under the OLD `window_ms` first so the carried-over `available`
            // reflects the old schedule; then re-anchor at `now` and install the new config.
            // If a roll occurred, the new window starts with the NEW capacity available.
            let now = clock.timestamp_ms();
            let steps = (now - *window_start_ms) / *window_field;
            if (steps > 0) {
                *available = capacity;
            } else {
                *available = (*available).min(capacity);
            };
            *window_start_ms = now;
            *cap_field = capacity;
            *window_field = window_ms;
        },
        _ => abort EWrongVariant,
    }
}

/// Rewrite a `Cooldown` limiter's configuration in place.
///
/// `available` is clamped to the new capacity. If after the clamp `available == 0` - whether
/// because a gate was already armed under the old config or because the clamp drained the
/// batch - the cooldown deadline is reset to `now + cooldown_ms` under the new `cooldown_ms`.
/// An in-flight deadline armed under the old config does NOT carry over; reconfigure
/// restarts the wait from `now`.
///
/// #### Parameters
/// - `self`: Limiter to reconfigure.
/// - `capacity`: New maximum units consumable per batch.
/// - `cooldown_ms`: New wait between batches, in milliseconds.
/// - `clock`: Reference to the Sui `Clock`, used to arm a fresh deadline if needed.
///
/// #### Aborts
/// - `EWrongVariant` if the limiter is not currently a `Cooldown`.
/// - `EZeroCapacity` if `capacity == 0`.
/// - `EZeroCooldown` if `cooldown_ms == 0`.
public fun reconfigure_cooldown(
    self: &mut RateLimiter,
    capacity: u64,
    cooldown_ms: u64,
    clock: &Clock,
) {
    match (self) {
        RateLimiter::Cooldown {
            cooldown_ms: cd_field,
            capacity: cap_field,
            available,
            cooldown_end_ms,
        } => {
            assert!(capacity > 0, EZeroCapacity);
            assert!(cooldown_ms > 0, EZeroCooldown);

            *cd_field = cooldown_ms;
            *cap_field = capacity;
            *available = (*available).min(capacity);

            if (*available == 0) {
                // SAFETY: `now + cooldown_ms` overflow is the operator's responsibility
                // (see module-level "Operator responsibilities").
                *cooldown_end_ms = clock.timestamp_ms() + cooldown_ms;
            };
        },
        _ => abort EWrongVariant,
    }
}

// === Private Functions ===

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
/// - `last_refill_ms`: Timestamp of the last accrual checkpoint.
/// - `available`: Stored token balance at `last_refill_ms`.
/// - `capacity`: Maximum token balance.
/// - `refill_amount`: Tokens credited per refill interval.
/// - `refill_interval_ms`: Length of one refill interval, in milliseconds.
/// - `now`: Current timestamp; must be `>= last_refill_ms`.
///
/// #### Returns
/// - `(new_last_refill_ms, new_available)`: the advanced anchor and projected balance.
fun bucket_accrue(
    last_refill_ms: u64,
    available: u64,
    capacity: u64,
    refill_amount: u64,
    refill_interval_ms: u64,
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

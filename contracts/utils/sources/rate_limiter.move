/// A small, embeddable rate-limiting primitive for Sui.
///
/// `RateLimiter` is a plain `store + drop` value that integrators embed as a field inside
/// their own objects. There is no registry, no policy object, and no separate ID that
/// integrators must track and assert against: the limiter's scope is whatever object it
/// lives inside.
///
/// Three strategies are provided in one enum, all sharing the same API:
/// - `Bucket` — continuously refilling token bucket with a configurable refill schedule,
/// - `FixedWindow` — up to `capacity` units per fixed-length window anchored at creation,
/// - `Cooldown` — up to `capacity` units before requiring a `cooldown_ms` wait.
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
/// any plausible chain timestamp during the limiter's lifetime — any policy-meaningful
/// value (seconds to days to years in ms) satisfies this trivially.
module openzeppelin_utils::rate_limiter;

use sui::clock::Clock;

// === Errors ===

/// The limiter cannot satisfy the requested consume against its current state.
#[error(code = 0)]
const ERateLimited: vector<u8> = "Rate limited";

/// `capacity` must be greater than zero.
#[error(code = 1)]
const EZeroCapacity: vector<u8> = "capacity must be greater than zero";

/// Reconfigure target does not match the limiter's current variant.
#[error(code = 2)]
const EWrongVariant: vector<u8> = "Wrong rate limiter variant";

/// Consume amount must be greater than zero; a zero-unit consume is a programmer error,
/// not a rate-limit decision.
#[error(code = 3)]
const EInvalidAmount: vector<u8> = "Amount must be greater than zero";

/// `refill_amount` must be greater than zero.
#[error(code = 4)]
const EZeroRefillAmount: vector<u8> = "refill_amount must be greater than zero";

/// `refill_interval_ms` must be greater than zero (zero would also divide by zero on accrual).
#[error(code = 5)]
const EZeroRefillInterval: vector<u8> = "refill_interval_ms must be greater than zero";

/// `window_ms` must be greater than zero (zero would also divide by zero on rollover).
#[error(code = 6)]
const EZeroWindowMs: vector<u8> = "window_ms must be greater than zero";

/// `cooldown_ms` must be greater than zero.
#[error(code = 7)]
const EZeroCooldownMs: vector<u8> = "cooldown_ms must be greater than zero";

/// `initial_available` must not exceed `capacity`.
#[error(code = 8)]
const EInitialAboveCapacity: vector<u8> = "initial_available must not exceed capacity";

// === Structs ===

/// One embeddable limiter, three strategies. The variant is chosen at construction and can
/// only be swapped by building a fresh `RateLimiter` and overwriting the field.
///
/// All variants store an `available` counter that starts equal to `capacity` and is
/// decremented by `consume`. Refill (Bucket), window rollover (FixedWindow), and cooldown
/// release (Cooldown) all reset `available` back toward `capacity`.
public enum RateLimiter has drop, store {
    /// Continuously refilling bucket. `available` accrues `refill_amount` every
    /// `refill_interval_ms`, capped at `capacity`. Each `consume` draws `available` down.
    Bucket {
        capacity: u64,
        refill_amount: u64,
        refill_interval_ms: u64,
        last_refill_ms: u64,
        available: u64,
    },
    /// Up to `capacity` units per window of length `window_ms`, anchored at the limiter's
    /// creation time. `available` resets to `capacity` when `now` crosses into a later
    /// window boundary.
    FixedWindow {
        capacity: u64,
        window_ms: u64,
        window_start_ms: u64,
        available: u64,
    },
    /// Up to `capacity` units may be consumed before the limiter gates on `cooldown_ms`.
    /// `available` decrements with each successful consume. Once `available == 0`,
    /// `cooldown_end_ms` is set to `now + cooldown_ms` — the absolute deadline at which
    /// the gate releases. No further consume succeeds until `now >= cooldown_end_ms`,
    /// at which point `available` resets to `capacity` and the next batch is granted.
    /// `cooldown_end_ms` is a don't-care field while `available > 0`; it is only read
    /// once the limiter has been drained and the gate is armed.
    Cooldown {
        cooldown_ms: u64,
        capacity: u64,
        available: u64,
        cooldown_end_ms: u64,
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
/// - A new `Bucket` `RateLimiter` ready to be embedded in the caller's object.
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
    assert_bucket_config!(capacity, refill_amount, refill_interval_ms);
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
/// - `clock`: Reference to the Sui `Clock`, used to anchor the first window.
///
/// #### Returns
/// - A new `FixedWindow` `RateLimiter` ready to be embedded in the caller's object.
///
/// #### Aborts
/// - `EZeroCapacity` if `capacity == 0`.
/// - `EZeroWindowMs` if `window_ms == 0`.
public fun new_fixed_window(capacity: u64, window_ms: u64, clock: &Clock): RateLimiter {
    assert_fixed_window_config!(capacity, window_ms);
    RateLimiter::FixedWindow {
        capacity,
        window_ms,
        window_start_ms: clock.timestamp_ms(),
        available: capacity,
    }
}

/// Create a cooldown limiter that is ready to be used immediately. Up to `capacity` units
/// may be consumed before the limiter requires `cooldown_ms` to elapse before the next batch.
///
/// #### Parameters
/// - `capacity`: Maximum units consumable per batch.
/// - `cooldown_ms`: Wait, in milliseconds, between exhausting the batch and the next reset.
///
/// #### Returns
/// - A new `Cooldown` `RateLimiter` starting fully available.
///
/// #### Aborts
/// - `EZeroCapacity` if `capacity == 0`.
/// - `EZeroCooldownMs` if `cooldown_ms == 0`.
public fun new_cooldown(capacity: u64, cooldown_ms: u64): RateLimiter {
    assert_cooldown_config!(capacity, cooldown_ms);
    RateLimiter::Cooldown {
        cooldown_ms,
        capacity,
        available: capacity,
        cooldown_end_ms: 0,
    }
}

// === Hot Path ===

/// Apply accrual, then consume `amount` or abort with `ERateLimited`.
///
/// #### Parameters
/// - `self`: Limiter being charged.
/// - `amount`: Units to consume. Must be greater than zero.
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
/// - `amount`: Units to consume. Must be greater than zero.
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
            if (new_available < amount) return false;
            *last_refill_ms = new_last;
            *available = new_available - amount;
            true
        },
        RateLimiter::FixedWindow { capacity, window_ms, window_start_ms, available } => {
            let steps = (now - *window_start_ms) / *window_ms;
            if (steps != 0) {
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
            *available = *available - 1;
            if (*available == 0) {
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
/// #### Parameters
/// - `self`: Limiter to inspect.
/// - `clock`: Reference to the Sui `Clock`, used to project pending accrual / rollover / release.
///
/// #### Returns
/// - The number of units that a `try_consume` call would currently accept.
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
        RateLimiter::Cooldown { cooldown_ms: _, capacity, available, cooldown_end_ms } => {
            if (*available > 0) *available
            else if (now >= *cooldown_end_ms) *capacity
            else 0
        },
    }
}

// === Reconfigure ===

/// Rewrite a `Bucket` limiter's configuration in place.
///
/// Accrues any tokens earned under the old rules first, then updates the configuration and
/// clamps the stored token balance to the new capacity.
///
/// #### Parameters
/// - `self`: Limiter to reconfigure. Must currently be a `Bucket`.
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
            assert_bucket_config!(capacity, refill_amount, refill_interval_ms);
            let (new_last, new_available) = bucket_accrue(
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
            *last_refill_ms = new_last;
            *available = new_available.min(capacity);
        },
        _ => abort EWrongVariant,
    }
}

/// Rewrite a `FixedWindow` limiter's configuration in place.
///
/// Rolls the window forward if `now` has crossed into a later window, then updates the
/// configuration and clamps `available` to the new capacity. If a rollover occurred,
/// the fresh window starts fully available under the new `capacity`.
///
/// #### Parameters
/// - `self`: Limiter to reconfigure. Must currently be a `FixedWindow`.
/// - `capacity`: New maximum units consumable per window.
/// - `window_ms`: New window length, in milliseconds.
/// - `clock`: Reference to the Sui `Clock`, used to roll the anchor forward under the old config.
///
/// #### Aborts
/// - `EWrongVariant` if the limiter is not currently a `FixedWindow`.
/// - `EZeroCapacity` if `capacity == 0`.
/// - `EZeroWindowMs` if `window_ms == 0`.
public fun reconfigure_fixed_window(
    self: &mut RateLimiter,
    capacity: u64,
    window_ms: u64,
    clock: &Clock,
) {
    let now = clock.timestamp_ms();
    match (self) {
        RateLimiter::FixedWindow {
            capacity: cap_field,
            window_ms: window_field,
            window_start_ms,
            available,
        } => {
            assert_fixed_window_config!(capacity, window_ms);
            // roll forward under the OLD `window_ms` first; the new config takes
            // effect from the rolled-forward anchor going forward. If a roll
            // occurred, the fresh window starts with the NEW capacity available.
            let steps = (now - *window_start_ms) / *window_field;
            if (steps > 0) {
                *window_start_ms = *window_start_ms + steps * *window_field;
                *available = capacity;
            } else {
                *available = (*available).min(capacity);
            };
            *cap_field = capacity;
            *window_field = window_ms;
        },
        _ => abort EWrongVariant,
    }
}

/// Rewrite a `Cooldown` limiter's configuration in place.
///
/// An in-flight cooldown deadline is preserved as-is — the new `cooldown_ms` does NOT
/// retroactively shift a gate that is already armed. `available` is clamped to the new
/// capacity. If after the clamp `available == 0` and no in-flight gate exists (deadline
/// already elapsed, or never set), a fresh deadline is armed at `now + cooldown_ms` so
/// the gate engages instead of granting a free reset.
///
/// #### Parameters
/// - `self`: Limiter to reconfigure. Must currently be a `Cooldown`.
/// - `capacity`: New maximum units consumable per batch.
/// - `cooldown_ms`: New wait between batches, in milliseconds.
/// - `clock`: Reference to the Sui `Clock`, used to arm a fresh deadline if needed.
///
/// #### Aborts
/// - `EWrongVariant` if the limiter is not currently a `Cooldown`.
/// - `EZeroCapacity` if `capacity == 0`.
/// - `EZeroCooldownMs` if `cooldown_ms == 0`.
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
            assert_cooldown_config!(capacity, cooldown_ms);
            *cd_field = cooldown_ms;
            *cap_field = capacity;
            *available = (*available).min(capacity);

            let now = clock.timestamp_ms();
            if (*available == 0 && now >= *cooldown_end_ms) {
                *cooldown_end_ms = now + cooldown_ms;
            };
        },
        _ => abort EWrongVariant,
    }
}

// === Private Functions ===

macro fun assert_bucket_config($capacity: u64, $refill_amount: u64, $refill_interval_ms: u64) {
    assert!($capacity > 0, EZeroCapacity);
    assert!($refill_amount > 0, EZeroRefillAmount);
    assert!($refill_interval_ms > 0, EZeroRefillInterval);
}

macro fun assert_fixed_window_config($capacity: u64, $window_ms: u64) {
    assert!($capacity > 0, EZeroCapacity);
    assert!($window_ms > 0, EZeroWindowMs);
}

macro fun assert_cooldown_config($capacity: u64, $cooldown_ms: u64) {
    assert!($capacity > 0, EZeroCapacity);
    assert!($cooldown_ms > 0, EZeroCooldownMs);
}

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
    // Two branches keep all intermediate u64 products and sums bounded without relying on
    // upper bounds on `capacity` or `refill_amount`:
    //   * Under-fill: `elapsed_steps * refill_amount <= steps_to_full * refill_amount <= headroom <= capacity`,
    //     so `available + credit <= capacity`. No overflow.
    //   * Fill: write `capacity` directly; advance `last_refill_ms` by `steps * refill_interval_ms`
    //     where `steps <= elapsed_steps`, bounded by `now - last_refill_ms`.
    let headroom = capacity - available;
    let steps_to_full = headroom / refill_amount;
    if (elapsed_steps <= steps_to_full) {
        let credit = elapsed_steps * refill_amount;
        (last_refill_ms + elapsed_steps * refill_interval_ms, available + credit)
    } else {
        // Smallest step count that reaches capacity: `steps_to_full` if exactly divisible, `steps_to_full + 1`
        // otherwise. `steps_to_full + 1` cannot overflow: `steps_to_full <= elapsed_steps - 1 < u64::MAX`.
        let steps = if (headroom == steps_to_full * refill_amount) steps_to_full
        else steps_to_full + 1;
        (last_refill_ms + steps * refill_interval_ms, capacity)
    }
}

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
module openzeppelin_utils::rate_limiter;

use sui::clock::Clock;

// === Errors ===

#[error(code = 0)]
const ERateLimited: vector<u8> = "Rate limited";
#[error(code = 1)]
const EInvalidConfig: vector<u8> = "Invalid config";
#[error(code = 2)]
const EWrongVariant: vector<u8> = "Wrong rate limiter variant";
#[error(code = 3)]
const EInvalidAmount: vector<u8> = "Amount must be greater than zero";

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

// === Constructors ===

/// Create a token bucket with an explicit initial token balance.
///
/// `initial_available` must be `<= capacity`. This is the knob to use when "start full" is the
/// wrong default — for example, starting at `0` forces the caller to wait for the first
/// refill interval before any consume can succeed.
public fun new_bucket(
    capacity: u64,
    refill_amount: u64,
    refill_interval_ms: u64,
    initial_available: u64,
    clock: &Clock,
): RateLimiter {
    assert_bucket_config!(capacity, refill_amount, refill_interval_ms);
    assert!(initial_available <= capacity, EInvalidConfig);
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
/// This is the normal hot-path entry point. Integrators call it from real actions such as
/// withdrawing from a vault or casting a spell. The policy check is implicit: the caller
/// already has `&mut` access to the limiter field, so they own the scope by construction.
public fun consume_or_abort(self: &mut RateLimiter, amount: u64, clock: &Clock) {
    assert!(try_consume(self, amount, clock), ERateLimited);
}

/// Apply accrual, then consume `amount` if the limiter allows it. Returns `true` on success.
///
/// Aborts with `EInvalidAmount` if `amount == 0`. A zero-unit consume is treated as a
/// programmer error, not a rate-limit condition, so behavior stays uniform across variants.
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
/// clamps the stored token balance to the new capacity. Aborts with `EWrongVariant` if the
/// limiter is not currently a `Bucket`.
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
/// configuration and clamps `available` to the new capacity. Aborts with `EWrongVariant`
/// if the limiter is not currently a `FixedWindow`.
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

/// Rewrite a `Cooldown` limiter's configuration in place. An in-flight cooldown deadline
/// is preserved as-is — the new `cooldown_ms` does NOT retroactively shift a gate that is
/// already armed. `available` is clamped to the new capacity. If after the clamp
/// `available == 0` and no in-flight gate exists (deadline already elapsed, or never set),
/// a fresh deadline is armed at `now + cooldown_ms` so the gate engages instead of granting
/// a free reset.
///
/// Aborts with `EWrongVariant` if the limiter is not currently a `Cooldown`.
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

// === Private ===

macro fun assert_bucket_config($capacity: u64, $refill_amount: u64, $refill_interval_ms: u64) {
    let capacity = $capacity;
    assert!(capacity > 0, EInvalidConfig);
    assert!($refill_amount > 0, EInvalidConfig);
    assert!($refill_interval_ms > 0, EInvalidConfig);
    assert!(capacity.checked_add($refill_amount).is_some(), EInvalidConfig);
}

macro fun assert_fixed_window_config($capacity: u64, $window_ms: u64) {
    assert!($capacity > 0, EInvalidConfig);
    assert!($window_ms > 0, EInvalidConfig);
}

macro fun assert_cooldown_config($capacity: u64, $cooldown_ms: u64) {
    assert!($capacity > 0, EInvalidConfig);
    assert!($cooldown_ms > 0, EInvalidConfig);
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
    //   * Under-fill: `elapsed_steps * refill_amount <= q * refill_amount <= headroom <= capacity`,
    //     so `available + credit <= capacity`. No overflow.
    //   * Fill: write `capacity` directly; advance `last_refill_ms` by `steps * refill_interval_ms`
    //     where `steps <= elapsed_steps`, bounded by `now - last_refill_ms`.
    // INV-S6 holds either way: `last_refill_ms` advances by an integer multiple of
    // `refill_interval_ms`.
    let headroom = capacity - available;
    let q = headroom / refill_amount;
    if (elapsed_steps <= q) {
        let credit = elapsed_steps * refill_amount;
        (last_refill_ms + elapsed_steps * refill_interval_ms, available + credit)
    } else {
        // Smallest step count that reaches capacity: `q` if exactly divisible, `q + 1`
        // otherwise. `q + 1` cannot overflow: `q <= elapsed_steps - 1 < u64::MAX`.
        let steps = if (headroom == q * refill_amount) q else q + 1;
        (last_refill_ms + steps * refill_interval_ms, capacity)
    }
}

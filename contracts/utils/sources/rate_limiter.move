/// A small, embeddable rate-limiting primitive for Sui.
///
/// `RateLimiter` is a plain `store + drop` value that integrators embed as a field inside
/// their own objects. There is no registry, no policy object, and no separate ID that
/// integrators must track and assert against: the limiter's scope is whatever object it
/// lives inside.
///
/// Three strategies are provided in one enum, all sharing the same API:
/// - `Bucket` — continuously refilling token bucket with a configurable refill schedule,
/// - `FixedWindow` — up to `capacity` units per aligned time window that resets on boundaries,
/// - `Cooldown` — minimum elapsed time between consumes (amount is ignored).
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
public enum RateLimiter has drop, store {
    /// Continuously refilling bucket. `tokens` accrues `refill_amount` every
    /// `refill_interval_ms`, capped at `capacity`. Each `consume` draws `tokens` down.
    Bucket {
        capacity: u64,
        refill_amount: u64,
        refill_interval_ms: u64,
        last_refill_ms: u64,
        tokens: u64,
    },
    /// Up to `capacity` units per aligned window of length `window_ms`. The counter resets
    /// when `now` crosses into a later window boundary.
    FixedWindow {
        capacity: u64,
        window_ms: u64,
        window_start_ms: u64,
        used: u64,
    },
    /// Minimum `cooldown_ms` between consumes. Any positive amount is a single "attempt".
    /// `last_used_ms` is `None` until the first successful consume, so the first consume
    /// succeeds at any clock value, including zero.
    Cooldown {
        cooldown_ms: u64,
        last_used_ms: Option<u64>,
    },
}

// === Constructors ===

/// Create a token bucket starting at full `capacity`.
///
/// Use `new_bucket_with_tokens` if the bucket should start at a different level, such as an
/// empty onboarding bucket that must accrue before it can be used.
public fun new_bucket(
    capacity: u64,
    refill_amount: u64,
    refill_interval_ms: u64,
    clock: &Clock,
): RateLimiter {
    new_bucket_with_tokens(capacity, refill_amount, refill_interval_ms, capacity, clock)
}

/// Create a token bucket with an explicit initial token balance.
///
/// `initial_tokens` must be `<= capacity`. This is the knob to use when "start full" is the
/// wrong default — for example, starting at `0` forces the caller to wait for the first
/// refill interval before any consume can succeed.
public fun new_bucket_with_tokens(
    capacity: u64,
    refill_amount: u64,
    refill_interval_ms: u64,
    initial_tokens: u64,
    clock: &Clock,
): RateLimiter {
    assert_bucket_config!(capacity, refill_amount, refill_interval_ms);
    assert!(initial_tokens <= capacity, EInvalidConfig);
    RateLimiter::Bucket {
        capacity,
        refill_amount,
        refill_interval_ms,
        last_refill_ms: clock.timestamp_ms(),
        tokens: initial_tokens,
    }
}

/// Create a fixed window limiter with its first window aligned to `now`.
public fun new_fixed_window(capacity: u64, window_ms: u64, clock: &Clock): RateLimiter {
    assert_fixed_window_config!(capacity, window_ms);
    RateLimiter::FixedWindow {
        capacity,
        window_ms,
        window_start_ms: align_window(clock.timestamp_ms(), window_ms),
        used: 0,
    }
}

/// Create a cooldown limiter that is ready to be used immediately.
public fun new_cooldown(cooldown_ms: u64): RateLimiter {
    assert!(cooldown_ms > 0, EInvalidConfig);
    RateLimiter::Cooldown { cooldown_ms, last_used_ms: option::none() }
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
            tokens,
        } => {
            let (new_last, new_tokens) = bucket_accrue(
                *last_refill_ms,
                *tokens,
                *capacity,
                *refill_amount,
                *refill_interval_ms,
                now,
            );
            if (new_tokens < amount) return false;
            *last_refill_ms = new_last;
            *tokens = new_tokens - amount;
            true
        },
        RateLimiter::FixedWindow { capacity, window_ms, window_start_ms, used } => {
            let aligned = align_window(now, *window_ms);
            if (aligned > *window_start_ms) {
                *window_start_ms = aligned;
                *used = 0;
            };
            if (*used + amount > *capacity) return false;
            *used = *used + amount;
            true
        },
        RateLimiter::Cooldown { cooldown_ms, last_used_ms } => {
            // `amount` is meaningless to a cooldown: any call is an attempt to "fire".
            if (last_used_ms.is_some() && now < *last_used_ms.borrow() + *cooldown_ms) {
                return false
            };
            *last_used_ms = option::some(now);
            true
        },
    }
}

/// Read-only view of the currently available capacity after applying accrual or window reset.
///
/// For `Bucket` this is the number of tokens that could be consumed right now; for
/// `FixedWindow` it is `capacity - used` after any window rollover; for `Cooldown` it is
/// `1` if the cooldown has elapsed and `0` otherwise.
public fun available(self: &RateLimiter, clock: &Clock): u64 {
    let now = clock.timestamp_ms();
    match (self) {
        RateLimiter::Bucket {
            capacity,
            refill_amount,
            refill_interval_ms,
            last_refill_ms,
            tokens,
        } => {
            let (_, t) = bucket_accrue(
                *last_refill_ms,
                *tokens,
                *capacity,
                *refill_amount,
                *refill_interval_ms,
                now,
            );
            t
        },
        RateLimiter::FixedWindow { capacity, window_ms, window_start_ms, used } => {
            if (align_window(now, *window_ms) > *window_start_ms) *capacity else *capacity - *used
        },
        RateLimiter::Cooldown { cooldown_ms, last_used_ms } => {
            if (last_used_ms.is_none() || now >= *last_used_ms.borrow() + *cooldown_ms) 1 else 0
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
    assert_bucket_config!(capacity, refill_amount, refill_interval_ms);
    let now = clock.timestamp_ms();
    match (self) {
        RateLimiter::Bucket {
            capacity: cap_field,
            refill_amount: refill_amount_field,
            refill_interval_ms: refill_interval_field,
            last_refill_ms,
            tokens,
        } => {
            let (new_last, new_tokens) = bucket_accrue(
                *last_refill_ms,
                *tokens,
                *cap_field,
                *refill_amount_field,
                *refill_interval_field,
                now,
            );
            *cap_field = capacity;
            *refill_amount_field = refill_amount;
            *refill_interval_field = refill_interval_ms;
            *last_refill_ms = new_last;
            *tokens = new_tokens.min(capacity);
        },
        _ => abort EWrongVariant,
    }
}

/// Rewrite a `FixedWindow` limiter's configuration in place.
///
/// Rolls the window forward if `now` has crossed into a later window, then updates the
/// configuration and clamps `used` to the new capacity. Aborts with `EWrongVariant` if the
/// limiter is not currently a `FixedWindow`.
public fun reconfigure_fixed_window(
    self: &mut RateLimiter,
    capacity: u64,
    window_ms: u64,
    clock: &Clock,
) {
    assert_fixed_window_config!(capacity, window_ms);
    let now = clock.timestamp_ms();
    match (self) {
        RateLimiter::FixedWindow {
            capacity: cap_field,
            window_ms: window_field,
            window_start_ms,
            used,
        } => {
            let aligned = align_window(now, window_ms);
            if (aligned > *window_start_ms) {
                *window_start_ms = aligned;
                *used = 0;
            } else {
                *window_start_ms = align_window(*window_start_ms, window_ms);
            };
            *cap_field = capacity;
            *window_field = window_ms;
            *used = (*used).min(capacity);
        },
        _ => abort EWrongVariant,
    }
}

/// Rewrite a `Cooldown` limiter's `cooldown_ms` in place. `last_used_ms` is preserved.
///
/// Aborts with `EWrongVariant` if the limiter is not currently a `Cooldown`.
public fun reconfigure_cooldown(self: &mut RateLimiter, cooldown_ms: u64) {
    assert!(cooldown_ms > 0, EInvalidConfig);
    match (self) {
        RateLimiter::Cooldown { cooldown_ms: cd_field, last_used_ms: _ } => {
            *cd_field = cooldown_ms;
        },
        _ => abort EWrongVariant,
    }
}

// === Private ===

macro fun assert_bucket_config($capacity: u64, $refill_amount: u64, $refill_interval_ms: u64) {
    assert!($capacity > 0, EInvalidConfig);
    assert!($refill_amount > 0, EInvalidConfig);
    assert!($refill_interval_ms > 0, EInvalidConfig);
}

macro fun assert_fixed_window_config($capacity: u64, $window_ms: u64) {
    assert!($capacity > 0, EInvalidConfig);
    assert!($window_ms > 0, EInvalidConfig);
}

fun bucket_accrue(
    last_refill_ms: u64,
    tokens: u64,
    capacity: u64,
    refill_amount: u64,
    refill_interval_ms: u64,
    now: u64,
): (u64, u64) {
    if (now <= last_refill_ms) return (last_refill_ms, tokens);
    let steps = (now - last_refill_ms) / refill_interval_ms;
    if (steps == 0) return (last_refill_ms, tokens);
    (last_refill_ms + steps * refill_interval_ms, capacity.min(tokens + steps * refill_amount))
}

fun align_window(now: u64, window_ms: u64): u64 {
    now - (now % window_ms)
}

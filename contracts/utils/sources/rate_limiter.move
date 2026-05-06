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
    /// Up to `capacity` units per window of length `window_ms`, anchored at the limiter's
    /// creation time. The counter resets when `now` crosses into a later window boundary.
    FixedWindow {
        capacity: u64,
        window_ms: u64,
        window_start_ms: u64,
        used: u64,
    },
    /// Up to `capacity` units may be consumed before the limiter gates on `cooldown_ms`.
    /// `used` accumulates with each successful consume. Once `used == capacity`,
    /// `cooldown_end_ms` is set to `now + cooldown_ms` — the absolute deadline at which
    /// the gate releases. No further consume succeeds until `now >= cooldown_end_ms`,
    /// at which point `used` resets to 0 and the next batch becomes available.
    /// `cooldown_end_ms` is a don't-care field while `used < capacity`; it is only read
    /// once the limiter has reached capacity and the gate is armed.
    Cooldown {
        cooldown_ms: u64,
        capacity: u64,
        used: u64,
        cooldown_end_ms: u64,
    },
}

// === Constructors ===

/// Create a token bucket with an explicit initial token balance.
///
/// `initial_tokens` must be `<= capacity`. This is the knob to use when "start full" is the
/// wrong default — for example, starting at `0` forces the caller to wait for the first
/// refill interval before any consume can succeed.
public fun new_bucket(
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

/// Create a fixed window limiter with its first window anchored at `now`. Subsequent
/// windows are exactly `[now + k * window_ms, now + (k+1) * window_ms)` for `k >= 0`.
public fun new_fixed_window(capacity: u64, window_ms: u64, clock: &Clock): RateLimiter {
    assert_fixed_window_config!(capacity, window_ms);
    RateLimiter::FixedWindow {
        capacity,
        window_ms,
        window_start_ms: clock.timestamp_ms(),
        used: 0,
    }
}

/// Create a cooldown limiter that is ready to be used immediately. Up to `capacity` units
/// may be consumed before the limiter requires `cooldown_ms` to elapse before the next batch.
public fun new_cooldown(capacity: u64, cooldown_ms: u64): RateLimiter {
    assert_cooldown_config!(capacity, cooldown_ms);
    RateLimiter::Cooldown {
        cooldown_ms,
        capacity,
        used: 0,
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
            roll_window(window_start_ms, used, *window_ms, now);
            // INV-S2 holds (`used <= capacity`), so `capacity - used` never underflows.
            // Reformulating as subtraction avoids the `used + amount` overflow path.
            if (amount > *capacity - *used) return false;
            *used = *used + amount;
            true
        },
        RateLimiter::Cooldown { cooldown_ms, capacity, used, cooldown_end_ms } => {
            if (*used == *capacity) {
                if (now < *cooldown_end_ms) return false;
                *used = 0;
            };
            // INV-S2 holds (`used <= capacity`), so `capacity - used` never underflows.
            if (amount > *capacity - *used) return false;
            *used = *used + amount;
            if (*used == *capacity) {
                *cooldown_end_ms = now + *cooldown_ms;
            };
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
            // A new window has begun once `window_ms` has elapsed since the current anchor.
            if (now - *window_start_ms >= *window_ms) *capacity else *capacity - *used
        },
        RateLimiter::Cooldown { cooldown_ms: _, capacity, used, cooldown_end_ms } => {
            if (*used < *capacity) *capacity - *used
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
            tokens,
        } => {
            assert_bucket_config!(capacity, refill_amount, refill_interval_ms);
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
    let now = clock.timestamp_ms();
    match (self) {
        RateLimiter::FixedWindow {
            capacity: cap_field,
            window_ms: window_field,
            window_start_ms,
            used,
        } => {
            assert_fixed_window_config!(capacity, window_ms);
            // roll forward under the OLD `window_ms` first; the new config takes
            // effect from the rolled-forward anchor going forward.
            roll_window(window_start_ms, used, *window_field, now);
            *cap_field = capacity;
            *window_field = window_ms;
            *used = (*used).min(capacity);
        },
        _ => abort EWrongVariant,
    }
}

/// Rewrite a `Cooldown` limiter's configuration in place. An in-flight cooldown deadline
/// is preserved as-is — the new `cooldown_ms` does NOT retroactively shift a gate that is
/// already armed. `used` is clamped to the new capacity. If after the clamp `used ==
/// capacity` and no in-flight gate exists (deadline already elapsed, or never set), a
/// fresh deadline is armed at `now + cooldown_ms` so the gate engages instead of granting
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
            used,
            cooldown_end_ms,
        } => {
            assert_cooldown_config!(capacity, cooldown_ms);
            *cd_field = cooldown_ms;
            *cap_field = capacity;
            *used = (*used).min(capacity);

            let now = clock.timestamp_ms();
            if (*used == capacity && now >= *cooldown_end_ms) {
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
    tokens: u64,
    capacity: u64,
    refill_amount: u64,
    refill_interval_ms: u64,
    now: u64,
): (u64, u64) {
    let elapsed_steps = (now - last_refill_ms) / refill_interval_ms;
    if (elapsed_steps == 0) return (last_refill_ms, tokens);
    // Two branches keep all intermediate u64 products and sums bounded without relying on
    // upper bounds on `capacity` or `refill_amount`:
    //   * Under-fill: `elapsed_steps * refill_amount <= q * refill_amount <= headroom <= capacity`,
    //     so `tokens + credit <= capacity`. No overflow.
    //   * Fill: write `capacity` directly; advance `last_refill_ms` by `steps * refill_interval_ms`
    //     where `steps <= elapsed_steps`, bounded by `now - last_refill_ms`.
    // INV-S6 holds either way: `last_refill_ms` advances by an integer multiple of
    // `refill_interval_ms`.
    let headroom = capacity - tokens;
    let q = headroom / refill_amount;
    if (elapsed_steps <= q) {
        let credit = elapsed_steps * refill_amount;
        (last_refill_ms + elapsed_steps * refill_interval_ms, tokens + credit)
    } else {
        // Smallest step count that reaches capacity: `q` if exactly divisible, `q + 1`
        // otherwise. `q + 1` cannot overflow: `q <= elapsed_steps - 1 < u64::MAX`.
        let steps = if (headroom == q * refill_amount) q else q + 1;
        (last_refill_ms + steps * refill_interval_ms, capacity)
    }
}

/// Advance `window_start_ms` by integer multiples of `window_ms` until it sits within the
/// current window, resetting `used` if any advance occurred. With the anchor-based design,
/// this preserves `window_start_ms = creation_ms (mod window_ms)` (INV-S3) and monotonicity
/// (INV-S4). `steps * window_ms <= now - *window_start_ms`, so the new value never exceeds
/// `now` and can't overflow `u64`.
fun roll_window(window_start_ms: &mut u64, used: &mut u64, window_ms: u64, now: u64) {
    let steps = (now - *window_start_ms) / window_ms;
    if (steps == 0) return;
    *window_start_ms = *window_start_ms + steps * window_ms;
    *used = 0;
}

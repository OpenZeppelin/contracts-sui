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
/// 4. when configuration changes, the integrator either calls the matching `reconfigure_*`
///    function with a per-call policy enum, or constructs a fresh `RateLimiter` with the
///    desired fields (reading current state via `available`, `capacity`, `window_start_ms`,
///    `cooldown_end_ms`, etc.) and overwrites the field.
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
/// # Reconfiguration
///
/// Two paths are supported, and integrators can mix them per call site:
/// - `reconfigure_*(limiter, ..., policy, clock)`: in-place rewrite where `policy` selects
///   one of the named carry-over strategies (project-and-reanchor, install-only, reset,
///   preserve-phase / preserve-active-gate, rebase, proportional, ...). Use when one of the
///   library-provided semantics is what you want.
/// - construct-fresh: read the current state via the getters (`available`, `capacity`,
///   `last_refill_ms`, `window_start_ms`, `cooldown_end_ms`, ...), compute the desired
///   field values, build a new `RateLimiter` with the rich constructor, and overwrite the
///   field. Use when you need a carry-over that isn't on the policy menu - the library
///   validates structural invariants on construction, and the choice of semantics is
///   entirely yours.
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
/// `FixedWindow` anchor strictly in the future would underflow the next projection.
#[error(code = 9)]
const EWindowAnchorInFuture: vector<u8> = "window_start_ms must not be in the future";
/// `Cooldown` with both `initial_available > 0` and a future `cooldown_end_ms` is
/// self-contradictory: the hot path ignores the gate while `available > 0`, so the
/// seeded deadline would be silently dropped the next time the batch drains.
#[error(code = 10)]
const ECooldownArmedWithTokens: vector<u8> =
    "Armed cooldown_end_ms is incompatible with initial_available > 0";
/// `Bucket` refill anchor strictly in the future would underflow the next projection.
#[error(code = 11)]
const EBucketAnchorInFuture: vector<u8> = "last_refill_ms must not be in the future";

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

/// Choice of how `reconfigure_bucket` should treat in-flight state when installing a
/// new configuration. Every variant validates the new config the same way; they differ
/// only in what they do with the existing `available` balance and the refill anchor.
public enum BucketReconfigurePolicy has copy, drop, store {
    /// Accrue pending tokens under the old rate, install the new config, re-anchor the
    /// refill counter at `now`, and clamp `available` to the new capacity. Any
    /// sub-interval remainder accrued under the old anchor is discarded.
    ProjectAndReanchor,
    /// Overwrite config fields only; do not touch `last_refill_ms`. `available` is
    /// clamped to the new capacity to preserve the limiter invariant, but no time
    /// projection runs. The stale anchor may produce a surprising first tick under the
    /// new schedule.
    InstallOnly,
    /// Reset the limiter as if freshly constructed: `available = capacity`,
    /// `last_refill_ms = now`. Discards every trace of prior state.
    Reset,
    /// Accrue pending tokens under the old rate, install the new config, clamp
    /// `available` to the new capacity, but keep the floor-aligned refill anchor from
    /// the old schedule so future ticks stay phase-aligned with the original anchor.
    PreservePhase,
    /// Accrue pending tokens under the old rate, install the new config, clamp
    /// `available`, then back-date `last_refill_ms` so the fraction of the refill
    /// interval already elapsed under the old schedule equals the fraction elapsed
    /// under the new one. Symmetric across shrink and grow.
    Proportional,
}

/// Choice of how `reconfigure_fixed_window` should treat in-flight state when installing
/// a new configuration.
public enum FixedWindowReconfigurePolicy has copy, drop, store {
    /// Roll forward under the old `window_ms` first (fresh capacity if a rollover
    /// occurred, otherwise clamp `available`), then install the new config and
    /// re-anchor `window_start_ms = now`.
    ProjectAndReanchor,
    /// Overwrite config fields only; do not touch `window_start_ms`. `available` is
    /// clamped to the new capacity. The stale anchor may produce a surprising first
    /// rollover under the new schedule.
    InstallOnly,
    /// Reset the limiter as if freshly constructed: `available = capacity`,
    /// `window_start_ms = now`.
    Reset,
    /// Roll forward under the old `window_ms`, then back-date `window_start_ms` so the
    /// fraction of the current window already elapsed under the old schedule equals
    /// the fraction elapsed under the new one.
    Proportional,
}

/// Choice of how `reconfigure_cooldown` should treat an in-flight cooldown gate when
/// installing a new configuration. Variants only differ when the gate is armed
/// (`available == 0`) and not yet elapsed at the time of reconfigure.
public enum CooldownReconfigurePolicy has copy, drop, store {
    /// Project the gate under the old config; if the gate is still in flight after the
    /// new capacity is clamped, restart it at `now + new_cooldown_ms`. Active waits are
    /// reset to a fresh deadline under the new policy.
    ProjectAndReanchor,
    /// Overwrite config fields only; do not touch `cooldown_end_ms`. `available` is
    /// clamped to the new capacity. An in-flight deadline runs to completion under
    /// whatever clock value it was originally set to.
    InstallOnly,
    /// Reset the limiter as if freshly constructed: `available = capacity`,
    /// `cooldown_end_ms = 0`.
    Reset,
    /// Project the release if the gate has elapsed under the old config; otherwise
    /// leave the in-flight `cooldown_end_ms` untouched. The new `cooldown_ms` only
    /// applies to gates armed after this reconfigure - admin cannot affect an active wait.
    PreserveActiveGate,
    /// Project the release if the gate has elapsed; otherwise rebase the in-flight
    /// deadline to `arm_time + new_cooldown_ms` (as if the new policy had been in
    /// effect since the gate was armed). If the rebased deadline is `<= now`, release
    /// immediately. Reconfiguring with identical `cooldown_ms` is a no-op for the
    /// deadline.
    RebaseActiveGate,
    /// Same as `RebaseActiveGate`, but additionally clamp the rebased deadline to the
    /// old deadline so reconfigure can shorten an active wait but never extend it.
    RebaseActiveGateNoExtend,
    /// Project the release if the gate has elapsed; otherwise scale the remaining
    /// wait by the ratio of new to old `cooldown_ms`. If the scaled remainder is zero,
    /// release immediately.
    Proportional,
}

// === Public Functions ===

// === Policy constructors ===
//
// Enum variants in Move can only be instantiated from inside the defining module, so
// each policy variant exposes a trivial public constructor. Constructors return by value;
// callers can hold the policy in a variable, pass it positionally, or build a default
// per call site.

public fun bucket_policy_project_and_reanchor(): BucketReconfigurePolicy {
    BucketReconfigurePolicy::ProjectAndReanchor
}

public fun bucket_policy_install_only(): BucketReconfigurePolicy {
    BucketReconfigurePolicy::InstallOnly
}

public fun bucket_policy_reset(): BucketReconfigurePolicy {
    BucketReconfigurePolicy::Reset
}

public fun bucket_policy_preserve_phase(): BucketReconfigurePolicy {
    BucketReconfigurePolicy::PreservePhase
}

public fun bucket_policy_proportional(): BucketReconfigurePolicy {
    BucketReconfigurePolicy::Proportional
}

public fun fixed_window_policy_project_and_reanchor(): FixedWindowReconfigurePolicy {
    FixedWindowReconfigurePolicy::ProjectAndReanchor
}

public fun fixed_window_policy_install_only(): FixedWindowReconfigurePolicy {
    FixedWindowReconfigurePolicy::InstallOnly
}

public fun fixed_window_policy_reset(): FixedWindowReconfigurePolicy {
    FixedWindowReconfigurePolicy::Reset
}

public fun fixed_window_policy_proportional(): FixedWindowReconfigurePolicy {
    FixedWindowReconfigurePolicy::Proportional
}

public fun cooldown_policy_project_and_reanchor(): CooldownReconfigurePolicy {
    CooldownReconfigurePolicy::ProjectAndReanchor
}

public fun cooldown_policy_install_only(): CooldownReconfigurePolicy {
    CooldownReconfigurePolicy::InstallOnly
}

public fun cooldown_policy_reset(): CooldownReconfigurePolicy {
    CooldownReconfigurePolicy::Reset
}

public fun cooldown_policy_preserve_active_gate(): CooldownReconfigurePolicy {
    CooldownReconfigurePolicy::PreserveActiveGate
}

public fun cooldown_policy_rebase_active_gate(): CooldownReconfigurePolicy {
    CooldownReconfigurePolicy::RebaseActiveGate
}

public fun cooldown_policy_rebase_active_gate_no_extend(): CooldownReconfigurePolicy {
    CooldownReconfigurePolicy::RebaseActiveGateNoExtend
}

public fun cooldown_policy_proportional(): CooldownReconfigurePolicy {
    CooldownReconfigurePolicy::Proportional
}

// === Constructors ===

/// Create a token bucket with an explicit initial token balance.
///
/// #### Parameters
/// - `capacity`: Maximum token balance the bucket can hold.
/// - `refill_amount`: Tokens credited per refill interval.
/// - `refill_interval_ms`: Length of one refill interval, in milliseconds.
/// - `initial_available`: Starting token balance. Must be `<= capacity`. Setting this to
///   `0` forces the caller to wait for the first refill interval before any consume succeeds.
/// - `last_refill_ms`: Anchor for the refill schedule. For greenfield use, pass
///   `clock.timestamp_ms()`; pass an earlier value to preserve the refill phase when
///   reconstructing under a new configuration. Must be `<= clock.timestamp_ms()`.
/// - `clock`: Reference to the Sui `Clock`, used to validate the anchor.
///
/// #### Returns
/// - A new bucket `RateLimiter` ready to be embedded in the caller's object.
///
/// #### Aborts
/// - `EZeroCapacity` if `capacity == 0`.
/// - `EZeroRefillAmount` if `refill_amount == 0`.
/// - `EZeroRefillInterval` if `refill_interval_ms == 0`.
/// - `EInitialAboveCapacity` if `initial_available > capacity`.
/// - `EBucketAnchorInFuture` if `last_refill_ms > clock.timestamp_ms()`.
public fun new_bucket(
    capacity: u64,
    refill_amount: u64,
    refill_interval_ms: u64,
    initial_available: u64,
    last_refill_ms: u64,
    clock: &Clock,
): RateLimiter {
    assert!(capacity > 0, EZeroCapacity);
    assert!(refill_amount > 0, EZeroRefillAmount);
    assert!(refill_interval_ms > 0, EZeroRefillInterval);
    assert!(initial_available <= capacity, EInitialAboveCapacity);
    assert!(last_refill_ms <= clock.timestamp_ms(), EBucketAnchorInFuture);

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
/// #### Parameters
/// - `capacity`: Maximum units consumable per window.
/// - `window_ms`: Length of one window, in milliseconds.
/// - `window_start_ms`: Anchor for the first window. Must be `<= clock.timestamp_ms()`.
/// - `initial_available`: Starting available units for the current window.
/// - `clock`: Reference to the Sui `Clock`, used to validate the anchor.
///
/// #### Returns
/// - A new fixed window `RateLimiter` ready to be embedded in the caller's object.
///
/// #### Aborts
/// - `EZeroCapacity` if `capacity == 0`.
/// - `EZeroWindow` if `window_ms == 0`.
/// - `EInitialAboveCapacity` if `initial_available > capacity`.
/// - `EWindowAnchorInFuture` if `window_start_ms > clock.timestamp_ms()`.
public fun new_fixed_window(
    capacity: u64,
    window_ms: u64,
    window_start_ms: u64,
    initial_available: u64,
    clock: &Clock,
): RateLimiter {
    assert!(capacity > 0, EZeroCapacity);
    assert!(window_ms > 0, EZeroWindow);
    assert!(initial_available <= capacity, EInitialAboveCapacity);
    assert!(window_start_ms <= clock.timestamp_ms(), EWindowAnchorInFuture);

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
/// Two configurations are valid:
/// - greenfield: `initial_available > 0` with `cooldown_end_ms <= now` (typically `0`). The
///   gate is not armed; up to `initial_available` units can be consumed before the first arm.
/// - in-flight gate: `initial_available == 0` with `cooldown_end_ms > now`, used when
///   reconstructing a limiter mid-throttle.
///
/// The library rejects the contradictory combination: `initial_available > 0` with
/// `cooldown_end_ms > now`.
///
/// #### Parameters
/// - `capacity`: Maximum units consumable per batch.
/// - `cooldown_ms`: Wait, in milliseconds, between exhausting the batch and the next reset.
/// - `initial_available`: Starting available units. Must be `<= capacity`.
/// - `cooldown_end_ms`: Initial gate deadline. `<= now` means no gate armed.
/// - `clock`: Reference to the Sui `Clock`, used to validate the gate-deadline pairing.
///
/// #### Returns
/// - A new cooldown `RateLimiter`.
///
/// #### Aborts
/// - `EZeroCapacity` if `capacity == 0`.
/// - `EZeroCooldown` if `cooldown_ms == 0`.
/// - `EInitialAboveCapacity` if `initial_available > capacity`.
/// - `ECooldownArmedWithTokens` if `initial_available > 0 && cooldown_end_ms > clock.timestamp_ms()`.
public fun new_cooldown(
    capacity: u64,
    cooldown_ms: u64,
    initial_available: u64,
    cooldown_end_ms: u64,
    clock: &Clock,
): RateLimiter {
    assert!(capacity > 0, EZeroCapacity);
    assert!(cooldown_ms > 0, EZeroCooldown);
    assert!(initial_available <= capacity, EInitialAboveCapacity);
    assert!(
        initial_available == 0 || cooldown_end_ms <= clock.timestamp_ms(),
        ECooldownArmedWithTokens,
    );

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
public fun consume_or_abort(self: &mut RateLimiter, amount: u64, clock: &Clock) {
    assert!(self.try_consume(amount, clock), ERateLimited);
}

/// Project state forward (accrual / window rollover / gate release), then consume `amount`
/// if the projected headroom allows it.
///
/// All-or-nothing: on success the projected state is committed and `amount` is deducted; on
/// failure (return `false`) persisted state is left untouched. Pending time transitions
/// remain observable through `available()`, which projects on read.
///
/// A zero-unit consume is treated as a programmer error, not a rate-limit condition, so
/// behavior stays uniform across variants.
///
/// #### Parameters
/// - `self`: Limiter being charged.
/// - `amount`: Units to consume.
/// - `clock`: Reference to the Sui `Clock`, used to project accrual / window rollover / cooldown release.
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
        } => bucket_try_consume(
            last_refill_ms,
            available,
            *capacity,
            *refill_amount,
            *refill_interval_ms,
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
            window_start_ms,
            available,
            *capacity,
            *capacity,
            *window_ms,
            amount,
            now,
        ),
        RateLimiter::Cooldown { cooldown_ms, capacity, available, cooldown_end_ms } => {
            let usable = if (*available > 0) *available
            else if (now >= *cooldown_end_ms) *capacity
            else return false;

            if (amount > usable) return false;

            *available = usable - amount;
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
            // FixedWindow is a Bucket with `refill_amount = capacity`; see `try_consume`.
            let (_, accrued) = bucket_accrue(
                *window_start_ms,
                *available,
                *capacity,
                *capacity,
                *window_ms,
                now,
            );
            accrued
        },
        RateLimiter::Cooldown { capacity, available, cooldown_end_ms, .. } => {
            if (*available > 0) *available
            else if (now >= *cooldown_end_ms) *capacity
            else 0
        },
    }
}

// === Getters ===
//
// These expose the inner fields a caller needs to rebuild a limiter with adjusted state
// via the construct-fresh path. Raw `available` is intentionally NOT exposed: use
// `available(&self, clock)` for the projected reading, which is the only semantically
// meaningful value at a point in time.

/// Capacity of the limiter, regardless of variant.
public fun capacity(self: &RateLimiter): u64 {
    match (self) {
        RateLimiter::Bucket { capacity, .. } => *capacity,
        RateLimiter::FixedWindow { capacity, .. } => *capacity,
        RateLimiter::Cooldown { capacity, .. } => *capacity,
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

/// Timestamp of the last refill checkpoint. Exposed so callers can preserve the
/// refill phase when reconstructing a bucket under a new configuration.
///
/// #### Aborts
/// - `EWrongVariant` if the limiter is not a `Bucket`.
public fun last_refill_ms(self: &RateLimiter): u64 {
    match (self) {
        RateLimiter::Bucket { last_refill_ms, .. } => *last_refill_ms,
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

/// Anchor timestamp of the current window.
///
/// #### Aborts
/// - `EWrongVariant` if the limiter is not a `FixedWindow`.
public fun window_start_ms(self: &RateLimiter): u64 {
    match (self) {
        RateLimiter::FixedWindow { window_start_ms, .. } => *window_start_ms,
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

/// Absolute deadline at which an armed cooldown gate releases. `0` means no gate is
/// armed. Only consulted by the hot path when `available == 0`.
///
/// #### Aborts
/// - `EWrongVariant` if the limiter is not a `Cooldown`.
public fun cooldown_end_ms(self: &RateLimiter): u64 {
    match (self) {
        RateLimiter::Cooldown { cooldown_end_ms, .. } => *cooldown_end_ms,
        _ => abort EWrongVariant,
    }
}

// === Reconfigure ===

/// Rewrite a `Bucket` limiter's configuration in place, with `policy` deciding how
/// in-flight state is carried across the boundary. See `BucketReconfigurePolicy` for
/// per-variant semantics.
///
/// #### Parameters
/// - `self`: Limiter to reconfigure.
/// - `capacity`: New maximum token balance.
/// - `refill_amount`: New tokens credited per refill interval.
/// - `refill_interval_ms`: New refill interval, in milliseconds.
/// - `policy`: How to treat existing `available` and `last_refill_ms`.
/// - `clock`: Reference to the Sui `Clock`, used by every policy except `InstallOnly`.
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
    policy: BucketReconfigurePolicy,
    clock: &Clock,
) {
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

            let now = clock.timestamp_ms();
            match (policy) {
                BucketReconfigurePolicy::InstallOnly => {
                    *cap_field = capacity;
                    *refill_amount_field = refill_amount;
                    *refill_interval_field = refill_interval_ms;
                    *available = (*available).min(capacity);
                },
                BucketReconfigurePolicy::Reset => {
                    *cap_field = capacity;
                    *refill_amount_field = refill_amount;
                    *refill_interval_field = refill_interval_ms;
                    *last_refill_ms = now;
                    *available = capacity;
                },
                BucketReconfigurePolicy::ProjectAndReanchor => {
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
                BucketReconfigurePolicy::PreservePhase => {
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
                BucketReconfigurePolicy::Proportional => {
                    let old_interval = *refill_interval_field;
                    let (new_last, new_available) = bucket_accrue(
                        *last_refill_ms,
                        *available,
                        *cap_field,
                        *refill_amount_field,
                        old_interval,
                        now,
                    );
                    // `now - new_last` is the sub-interval remainder under the old
                    // schedule (floor in `bucket_accrue`). Scale by `new / old` to
                    // get the equivalent phase under the new schedule and back-date.
                    // SAFETY: u128 widening keeps the product in range even when both
                    // intervals approach u64::MAX. The result is `<= refill_interval_ms`
                    // so the cast back to u64 is safe.
                    let elapsed_old = (now - new_last) as u128;
                    let elapsed_new =
                        elapsed_old * (refill_interval_ms as u128) / (old_interval as u128);
                    *cap_field = capacity;
                    *refill_amount_field = refill_amount;
                    *refill_interval_field = refill_interval_ms;
                    *last_refill_ms = now - (elapsed_new as u64);
                    *available = new_available.min(capacity);
                },
            };
        },
        _ => abort EWrongVariant,
    }
}

/// Rewrite a `FixedWindow` limiter's configuration in place, with `policy` deciding how
/// in-flight state is carried across the boundary. See `FixedWindowReconfigurePolicy` for
/// per-variant semantics.
///
/// #### Parameters
/// - `self`: Limiter to reconfigure.
/// - `capacity`: New maximum units consumable per window.
/// - `window_ms`: New window length, in milliseconds.
/// - `policy`: How to treat existing `available` and `window_start_ms`.
/// - `clock`: Reference to the Sui `Clock`, used by every policy except `InstallOnly`.
///
/// #### Aborts
/// - `EWrongVariant` if the limiter is not currently a `FixedWindow`.
/// - `EZeroCapacity` if `capacity == 0`.
/// - `EZeroWindow` if `window_ms == 0`.
public fun reconfigure_fixed_window(
    self: &mut RateLimiter,
    capacity: u64,
    window_ms: u64,
    policy: FixedWindowReconfigurePolicy,
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

            let now = clock.timestamp_ms();
            match (policy) {
                FixedWindowReconfigurePolicy::InstallOnly => {
                    *cap_field = capacity;
                    *window_field = window_ms;
                    *available = (*available).min(capacity);
                },
                FixedWindowReconfigurePolicy::Reset => {
                    *cap_field = capacity;
                    *window_field = window_ms;
                    *window_start_ms = now;
                    *available = capacity;
                },
                FixedWindowReconfigurePolicy::ProjectAndReanchor => {
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
                FixedWindowReconfigurePolicy::Proportional => {
                    let old_window = *window_field;
                    let steps = (now - *window_start_ms) / old_window;
                    if (steps > 0) {
                        // SAFETY: `steps * old_window <= now - *window_start_ms`
                        // (floor above), so the advanced anchor is `<= now`.
                        *window_start_ms = *window_start_ms + steps * old_window;
                        *available = capacity;
                    } else {
                        *available = (*available).min(capacity);
                    };
                    // `now - *window_start_ms` is the phase elapsed in the current
                    // window under the old schedule (always `< old_window` after the
                    // roll). Scale by `new / old` to get the equivalent phase under
                    // the new schedule and back-date.
                    // SAFETY: u128 widening keeps the product in range. The result
                    // is `<= window_ms` so the cast back to u64 is safe.
                    let elapsed_old = (now - *window_start_ms) as u128;
                    let elapsed_new = elapsed_old * (window_ms as u128) / (old_window as u128);
                    *window_start_ms = now - (elapsed_new as u64);
                    *cap_field = capacity;
                    *window_field = window_ms;
                },
            };
        },
        _ => abort EWrongVariant,
    }
}

/// Rewrite a `Cooldown` limiter's configuration in place, with `policy` deciding how an
/// in-flight cooldown gate is carried across the boundary. See `CooldownReconfigurePolicy`
/// for per-variant semantics.
///
/// #### Parameters
/// - `self`: Limiter to reconfigure.
/// - `capacity`: New maximum units consumable per batch.
/// - `cooldown_ms`: New wait between batches, in milliseconds.
/// - `policy`: How to treat the in-flight gate.
/// - `clock`: Reference to the Sui `Clock`, used by every policy except `InstallOnly`.
///
/// #### Aborts
/// - `EWrongVariant` if the limiter is not currently a `Cooldown`.
/// - `EZeroCapacity` if `capacity == 0`.
/// - `EZeroCooldown` if `cooldown_ms == 0`.
public fun reconfigure_cooldown(
    self: &mut RateLimiter,
    capacity: u64,
    cooldown_ms: u64,
    policy: CooldownReconfigurePolicy,
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

            let now = clock.timestamp_ms();
            match (policy) {
                CooldownReconfigurePolicy::InstallOnly => {
                    *cap_field = capacity;
                    *cd_field = cooldown_ms;
                    *available = (*available).min(capacity);
                },
                CooldownReconfigurePolicy::Reset => {
                    *cap_field = capacity;
                    *cd_field = cooldown_ms;
                    *cooldown_end_ms = 0;
                    *available = capacity;
                },
                CooldownReconfigurePolicy::ProjectAndReanchor => {
                    if (*available == 0 && now >= *cooldown_end_ms) {
                        *available = *cap_field;
                    };
                    *cap_field = capacity;
                    *cd_field = cooldown_ms;
                    *available = (*available).min(capacity);
                    if (*available == 0) {
                        // SAFETY: `now + cooldown_ms` overflow is the operator's
                        // responsibility (see module-level "Operator responsibilities").
                        *cooldown_end_ms = now + cooldown_ms;
                    };
                },
                CooldownReconfigurePolicy::PreserveActiveGate => {
                    if (*available == 0 && now >= *cooldown_end_ms) {
                        *available = *cap_field;
                    };
                    *cap_field = capacity;
                    *cd_field = cooldown_ms;
                    *available = (*available).min(capacity);
                    // If the gate is still in flight, leave `cooldown_end_ms` as-is:
                    // the new `cooldown_ms` only applies to gates armed after this call.
                },
                CooldownReconfigurePolicy::RebaseActiveGate => {
                    if (*available == 0 && now >= *cooldown_end_ms) {
                        *available = *cap_field;
                    };
                    *cap_field = capacity;
                    *available = (*available).min(capacity);
                    if (*available == 0) {
                        // SAFETY: see safety notes in `RebaseActiveGateNoExtend`.
                        let arm_time = *cooldown_end_ms - *cd_field;
                        let new_deadline = arm_time + cooldown_ms;
                        if (new_deadline <= now) {
                            *available = capacity;
                        } else {
                            *cooldown_end_ms = new_deadline;
                        };
                    };
                    *cd_field = cooldown_ms;
                },
                CooldownReconfigurePolicy::RebaseActiveGateNoExtend => {
                    if (*available == 0 && now >= *cooldown_end_ms) {
                        *available = *cap_field;
                    };
                    *cap_field = capacity;
                    *available = (*available).min(capacity);
                    if (*available == 0) {
                        // SAFETY: `cooldown_end_ms >= *cd_field` because the gate was
                        // armed as `now_at_arm + *cd_field`, so the subtraction does
                        // not underflow. `arm_time + cooldown_ms` overflow is the
                        // operator's responsibility (`arm_time <= now`, so any
                        // policy-meaningful `cooldown_ms` stays well below u64::MAX).
                        let arm_time = *cooldown_end_ms - *cd_field;
                        let rebased = arm_time + cooldown_ms;
                        let new_deadline = rebased.min(*cooldown_end_ms);
                        if (new_deadline <= now) {
                            *available = capacity;
                        } else {
                            *cooldown_end_ms = new_deadline;
                        };
                    };
                    *cd_field = cooldown_ms;
                },
                CooldownReconfigurePolicy::Proportional => {
                    if (*available == 0 && now >= *cooldown_end_ms) {
                        *available = *cap_field;
                    };
                    *cap_field = capacity;
                    *available = (*available).min(capacity);
                    if (*available == 0) {
                        // Gate is in flight: `now < *cooldown_end_ms`, so
                        // `time_left_old > 0`.
                        // SAFETY: u128 widening keeps the product in range. The result
                        // is `<= cooldown_ms` so the cast back to u64 is safe.
                        let time_left_old = (*cooldown_end_ms - now) as u128;
                        let time_left_new =
                            time_left_old * (cooldown_ms as u128) / (*cd_field as u128);
                        if (time_left_new == 0) {
                            *available = capacity;
                        } else {
                            // SAFETY: `now + time_left_new` overflow is the operator's
                            // responsibility; `time_left_new <= cooldown_ms`.
                            *cooldown_end_ms = now + (time_left_new as u64);
                        };
                    };
                    *cd_field = cooldown_ms;
                },
            };
        },
        _ => abort EWrongVariant,
    }
}

// === Private Functions ===

/// Project bucket-shaped state forward and consume `amount` on success. Shared by `Bucket`
/// and `FixedWindow` (the latter passes `refill_amount = capacity`, so one elapsed interval
/// refills exactly to the cap - the window-rollover semantics).
///
/// All-or-nothing: on success advances `last_refill_ms` to the latest completed boundary
/// and deducts `amount` from `available`; on failure leaves both untouched.
fun bucket_try_consume(
    last_refill_ms: &mut u64,
    available: &mut u64,
    capacity: u64,
    refill_amount: u64,
    refill_interval_ms: u64,
    amount: u64,
    now: u64,
): bool {
    let (new_last, new_available) = bucket_accrue(
        *last_refill_ms,
        *available,
        capacity,
        refill_amount,
        refill_interval_ms,
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

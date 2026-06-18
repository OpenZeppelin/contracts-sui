/// A per-user faucet that composes two limiters of different variants across two objects.
///
/// The shared `Faucet` carries one global fixed-window limiter that throttles *every*
/// claimer collectively. On top of that global window, each holder is handed a `ClaimCap`
/// carrying its own `RateLimiter` (a token bucket) that caps how much that specific holder
/// can claim. A claim must satisfy both limiters - the holder's personal bucket and the
/// global window.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `RateLimiter` primitive can be integrated. It is not production-ready and must not be
/// deployed as-is.
module openzeppelin_utils::faucet;

use openzeppelin_utils::rare_coin::RARE_COIN;
use openzeppelin_utils::rate_limiter::{Self, RateLimiter};
use sui::balance::Balance;
use sui::clock::Clock;
use sui::coin::{Self, Coin};

// === Constants ===

const HOUR: u64 = 60 * 60 * 1000;

const HOURLY_LIMIT: u64 = 100;

// === Structs ===

/// Shared faucet with one global claim limiter shared by every holder.
public struct Faucet has key {
    id: UID,
    balance: Balance<RARE_COIN>,
    global_limiter: RateLimiter,
}

/// Handed to whoever funds the faucet; authorizes issuing `ClaimCap`s with per-holder limits.
public struct AdminCap has key, store { id: UID }

/// Presented on every claim. Carries a personal bucket limiter that caps this holder.
public struct ClaimCap has key, store {
    id: UID,
    personal_limiter: RateLimiter,
}

// === Public Functions ===

/// Share a faucet whose global budget is 100 coins per hour, and return an `AdminCap`
/// for issuing claim capabilities.
public fun new(funds: Coin<RARE_COIN>, clock: &Clock, ctx: &mut TxContext): AdminCap {
    let global_limiter = rate_limiter::new_fixed_window(
        HOURLY_LIMIT,
        HOUR,
        clock.timestamp_ms(),
        HOURLY_LIMIT,
        clock,
    );

    transfer::share_object(Faucet {
        id: object::new(ctx),
        balance: funds.into_balance(),
        global_limiter,
    });
    AdminCap { id: object::new(ctx) }
}

/// Issue a claim capability with a personal token-bucket limit: at most `per_user_cap`
/// outstanding, refilling `refill_amount` every `refill_interval_ms`, starting full.
public fun issue_claim_cap(
    _: &AdminCap,
    recipient: address,
    per_user_cap: u64,
    refill_amount: u64,
    refill_interval_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let personal_limiter = rate_limiter::new_bucket(
        per_user_cap,
        refill_amount,
        refill_interval_ms,
        clock.timestamp_ms(),
        per_user_cap, // start full
        clock,
    );
    transfer::transfer(ClaimCap { id: object::new(ctx), personal_limiter }, recipient);
}

/// Claim `amount`, charging the holder's personal bucket first, then the global window.
/// Both checks run before the balance split, so a denial on either never touches `balance`.
public fun claim(
    self: &mut Faucet,
    cap: &mut ClaimCap,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<RARE_COIN> {
    cap.personal_limiter.consume_or_abort(amount, clock); // per-user cap
    self.global_limiter.consume_or_abort(amount, clock); // global cap
    coin::from_balance(self.balance.split(amount), ctx)
}

// === View helpers ===

/// This holder's currently-available personal allowance (projects refill on read).
public fun personal_allowance(cap: &ClaimCap, clock: &Clock): u64 {
    cap.personal_limiter.available(clock)
}

/// The faucet's currently-available global allowance (projects window rollover on read).
public fun global_allowance(self: &Faucet, clock: &Clock): u64 {
    self.global_limiter.available(clock)
}

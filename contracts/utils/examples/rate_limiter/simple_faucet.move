/// The simplest possible integration of `RateLimiter`.
///
/// A single shared `Faucet` holds one `RateLimiter` (a fixed window) embedded directly
/// as a field. Every claimer draws against that one limiter collectively: the window
/// budget is global, not per-user. This is the minimal pattern — one object, one
/// embedded limiter, no capabilities — and is the foundation that `tiered_faucet`
/// layers a per-holder limiter on top of.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `RateLimiter` primitive can be integrated. It is not production-ready and must not be
/// deployed as-is.
module openzeppelin_utils::simple_faucet;

use openzeppelin_utils::rare_coin::RARE_COIN;
use openzeppelin_utils::rate_limiter::{Self, RateLimiter};
use sui::balance::Balance;
use sui::clock::Clock;
use sui::coin::{Self, Coin};

const HOUR: u64 = 60 * 60 * 1000;

const HOURLY_LIMIT: u64 = 100;

/// Shared faucet. The `limiter` field is the entire rate-limiting mechanism — there is no
/// separate policy object or registry; the limiter's scope is just this `Faucet`.
public struct Faucet has key {
    id: UID,
    balance: Balance<RARE_COIN>,
    limiter: RateLimiter,
}

/// Share a faucet whose global budget is 100 coins per hour, anchored at creation time.
public fun new(funds: Coin<RARE_COIN>, clock: &Clock, ctx: &mut TxContext) {
    let limiter = rate_limiter::new_fixed_window(
        HOURLY_LIMIT,
        HOUR,
        clock.timestamp_ms(),
        HOURLY_LIMIT,
        clock,
    );

    sui::transfer::share_object(Faucet {
        id: object::new(ctx),
        balance: funds.into_balance(),
        limiter,
    })
}

/// Claim `amount` coins. The limiter is charged first, so a rate-limited claim aborts
/// before the balance is ever touched.
public fun claim(
    self: &mut Faucet,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<RARE_COIN> {
    self.limiter.consume_or_abort(amount, clock);
    coin::from_balance(self.balance.split(amount), ctx)
}

/// The faucet's currently-available global allowance (projects window rollover on read).
public fun available(self: &Faucet, clock: &Clock): u64 {
    self.limiter.available(clock)
}

#[test_only]
use sui::test_scenario as ts;
#[test_only]
use std::unit_test::{destroy, assert_eq};
#[test_only]
use openzeppelin_utils::rare_coin;

#[test]
fun user_claims_when_respecting_limits() {
    let admin = @0xA;
    let user = @0xB;

    let mut scenario = ts::begin(admin);
    let mut clock = sui::clock::create_for_testing(scenario.ctx());

    rare_coin::init_for_testing(scenario.ctx());

    scenario.next_tx(admin);
    let rare_coins = scenario.take_from_sender<Coin<RARE_COIN>>();
    new(rare_coins, &clock, scenario.ctx());

    scenario.next_tx(user);
    let mut faucet = scenario.take_shared<Faucet>();

    // The window starts full at 100, shared across all claimers.
    assert_eq!(faucet.available(&clock), 100);
    destroy(faucet.claim(100, &clock, scenario.ctx()));
    assert_eq!(faucet.available(&clock), 0);

    // The allowance resets only on a window boundary: nothing accrues mid-minute.
    clock.increment_for_testing(3_599_000);
    assert_eq!(faucet.available(&clock), 0);

    // Crossing the minute boundary resets to the full 100 at once.
    clock.increment_for_testing(1_000);
    assert_eq!(faucet.available(&clock), 100);

    // Later windows stay capped at 100, never accumulating beyond the per-window limit.
    clock.increment_for_testing(120_000);
    assert_eq!(faucet.available(&clock), 100);

    ts::return_shared(faucet);
    sui::clock::destroy_for_testing(clock);
    scenario.end();
}

#[test, expected_failure(abort_code = rate_limiter::ERateLimited)]
fun global_throttle() {
    let admin = @0xA;
    let user = @0xB;

    let mut scenario = ts::begin(admin);
    let clock = sui::clock::create_for_testing(scenario.ctx());

    rare_coin::init_for_testing(scenario.ctx());

    scenario.next_tx(admin);
    let rare_coins = scenario.take_from_sender<Coin<RARE_COIN>>();
    new(rare_coins, &clock, scenario.ctx());

    scenario.next_tx(user);
    let mut faucet = scenario.take_shared<Faucet>();

    // The window starts full at 100, shared across all claimers.
    assert_eq!(faucet.available(&clock), 100);
    // User tries to consume more than the global limiter allows.
    destroy(faucet.claim(110, &clock, scenario.ctx()));

    abort
}

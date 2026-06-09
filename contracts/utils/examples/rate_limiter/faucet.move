/// A per-user faucet that composes two limiters of different variants across two objects.
///
/// The shared `Faucet` carries one global fixed-window limiter that throttles *every*
/// claimer collectively. On top of that global window, each holder is handed a `ClaimCap`
/// carrying its own `RateLimiter` (a token bucket) that caps how much that specific holder
/// can claim. A claim must satisfy both limiters — the holder's personal bucket and the
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

// === Test-Only Helpers ===

#[test_only]
use sui::test_scenario as ts;
#[test_only]
use std::unit_test::{destroy, assert_eq};
#[test_only]
use openzeppelin_utils::rare_coin;

#[test]
fun users_claim_when_respecting_all_limits() {
    let admin = @0xA;
    let user_1 = @0xB;
    let user_2 = @0xC;

    let mut scenario = ts::begin(admin);
    let mut clock = sui::clock::create_for_testing(scenario.ctx());

    rare_coin::init_for_testing(scenario.ctx());
    scenario.next_tx(admin);

    let rare_coins = scenario.take_from_sender<Coin<RARE_COIN>>();
    let admin_cap = new(rare_coins, &clock, scenario.ctx());

    scenario.next_tx(admin);

    let mut faucet = scenario.take_shared<Faucet>();
    // User 1: Personal cap of 60, refilling 10/sec.
    issue_claim_cap(&admin_cap, user_1, 60, 10, 1_000, &clock, scenario.ctx());
    // User 2: Personal cap of 50, refilling 15/sec.
    issue_claim_cap(&admin_cap, user_2, 50, 15, 1_000, &clock, scenario.ctx());

    scenario.next_tx(user_1);

    let mut cap_1 = scenario.take_from_sender<ClaimCap>();
    // The personal allowance binds well below the 100 global window.
    assert_eq!(cap_1.personal_allowance(&clock), 60);
    destroy(faucet.claim(&mut cap_1, 60, &clock, scenario.ctx()));
    assert_eq!(cap_1.personal_allowance(&clock), 0);
    // The global window only saw 60 consumed, so it still has 40.
    assert_eq!(faucet.global_allowance(&clock), 40);

    // the faucet will still permit the other user to claim
    scenario.next_tx(user_2);
    let mut cap_2 = scenario.take_from_sender<ClaimCap>();
    assert_eq!(cap_2.personal_allowance(&clock), 50);
    destroy(faucet.claim(&mut cap_2, 40, &clock, scenario.ctx()));
    assert_eq!(cap_2.personal_allowance(&clock), 10);
    // The global window is now empty
    assert_eq!(faucet.global_allowance(&clock), 0);

    // Confirm personal buckets refill appropriately
    clock.increment_for_testing(2_000);
    assert_eq!(cap_1.personal_allowance(&clock), 20);
    assert_eq!(cap_2.personal_allowance(&clock), 40);

    destroy(cap_1);
    destroy(cap_2);
    destroy(admin_cap);
    ts::return_shared(faucet);
    sui::clock::destroy_for_testing(clock);
    scenario.end();
}

#[test, expected_failure(abort_code = rate_limiter::ERateLimited)]
fun personal_limit_binds_even_if_global_allows() {
    let admin = @0xA;
    let user = @0xB;

    let mut scenario = ts::begin(admin);
    let clock = sui::clock::create_for_testing(scenario.ctx());

    rare_coin::init_for_testing(scenario.ctx());
    scenario.next_tx(admin);

    let rare_coins = scenario.take_from_sender<Coin<RARE_COIN>>();
    let admin_cap = new(rare_coins, &clock, scenario.ctx());

    scenario.next_tx(admin);

    let mut faucet = scenario.take_shared<Faucet>();
    // User 1: Personal cap of 60, refilling 10/sec.
    issue_claim_cap(&admin_cap, user, 60, 10, 1_000, &clock, scenario.ctx());

    scenario.next_tx(user);

    let mut cap = scenario.take_from_sender<ClaimCap>();
    // The personal allowance binds well below the 100 global window.
    assert_eq!(cap.personal_allowance(&clock), 60);
    // But it hits the personal limit, thus aborting
    destroy(faucet.claim(&mut cap, 100, &clock, scenario.ctx()));

    abort
}

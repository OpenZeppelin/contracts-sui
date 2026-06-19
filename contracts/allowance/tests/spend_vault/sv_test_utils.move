// Shared test scaffolding for the spend_vault unit suite.
//
// Holds the test coin types, common constants, and the high-traffic setup
// helpers so each thematic test file stays focused on the behavior it pins,
// not on boilerplate. Unit-test-only: never compiled into the published module.
//
// Testability note: the funds-accumulator pool (object-owned address balances)
// is NOT modeled by the unit-test VM (over-withdraw and withdraw-from-empty both
// succeed, and `AccumulatorRoot` cannot be constructed), so these helpers cover
// the ledger / cap / event / exact-value-delivery surface. Because the unit VM
// does not move accumulator funds and cannot construct an `AccumulatorRoot`, the
// following behaviors are NOT exercised by the unit suite:
//   (a) the native pool-short abort and the atomic-revert rollback of the
//       pre-decrement in `spend` / `withdraw`;
//   (b) all branches of `withdraw_all`, including the zero-pool `amount: 0` path;
//   (c) the root-taking reads `spendable_now` and `balance_value`.
// CAVEAT: because the unit VM lets the withdraw "succeed" without moving funds,
// line-coverage tooling will mark the `spend` / `withdraw` fund-movement lines as
// covered even though the pool-short and rollback behavior is NOT asserted by any
// unit test. Those paths (the pool-short native abort, the rollback, and every
// `&AccumulatorRoot`-taking read) require integration tests against a live
// network, not here.
#[test_only]
module openzeppelin_allowance::sv_test_utils;

use openzeppelin_allowance::spend_vault::{Self, Vault, OwnerCap, SpenderCap};
use sui::clock::{Self, Clock};
use sui::coin;
use sui::test_scenario::{Self as ts, Scenario};

// === Test coin types (distinct defining types so BudgetKeys differ) ===

public struct USDC has drop {}
public struct SUIT has drop {} // a stand-in "SUI"-like coin (avoids the real sui::sui::SUI)
public struct DEEP has drop {}
public struct FOO has drop {} // junk type for un-griefability / wrong-coin tests

// === Common constants (consts are module-private in Move; expose via fns) ===

const NO_EXPIRY: u64 = 18_446_744_073_709_551_615; // u64::MAX sentinel
const MAX_U64: u64 = 18_446_744_073_709_551_615;
const START_MS: u64 = 1_700_000_000_000; // a fixed "now" base for clock tests

public fun no_expiry(): u64 { NO_EXPIRY }

public fun max_u64(): u64 { MAX_U64 }

public fun start_ms(): u64 { START_MS }

// === Clock helpers ===

/// A fresh test Clock set to `ms` (caller owns it; share or destroy it).
public fun clock_at(ms: u64, ctx: &mut TxContext): Clock {
    let mut c = clock::create_for_testing(ctx);
    c.set_for_testing(ms);
    c
}

// === Vault setup helpers (each runs inside the CURRENT scenario tx) ===

/// Create + share a vault funded with `amt` of `T`, send the OwnerCap to
/// `owner`, and create+share a Clock at START_MS. Returns the vault id.
/// No cap, no grant: for fund/withdraw/lifecycle tests.
public fun new_funded_vault<T>(s: &mut Scenario, owner: address, amt: u64): ID {
    let (v, oc) = spend_vault::new(s.ctx());
    let vault_id = object::id(&v);
    if (amt > 0) {
        spend_vault::deposit(&v, coin::mint_for_testing<T>(amt, s.ctx()), s.ctx());
    };
    spend_vault::share(v);
    transfer::public_transfer(oc, owner);
    let clk = clock_at(START_MS, s.ctx());
    clk.share_for_testing();
    vault_id
}

/// Full single-coin setup in one tx: create vault, deposit `amt` of `T`, mint a
/// cap, grant (`budget`, `expiry`) on (cap, T), share the vault, send the
/// OwnerCap to `owner` and the SpenderCap to `spender`, and create+share a Clock
/// at START_MS. Returns (vault_id, cap_id). The workhorse for spend / revoke /
/// cap-update tests.
public fun setup_granted<T>(
    s: &mut Scenario,
    owner: address,
    spender: address,
    amt: u64,
    budget: u64,
    expiry: u64,
): (ID, ID) {
    let clk = clock_at(START_MS, s.ctx());
    let (mut v, oc) = spend_vault::new(s.ctx());
    let vault_id = object::id(&v);
    if (amt > 0) {
        spend_vault::deposit(&v, coin::mint_for_testing<T>(amt, s.ctx()), s.ctx());
    };
    let cap = spend_vault::mint_cap(&v, &oc, s.ctx());
    let cap_id = object::id(&cap);
    spend_vault::set_allowance<T>(&mut v, &oc, cap_id, budget, expiry, option::none(), &clk, s.ctx());
    transfer::public_transfer(cap, spender);
    spend_vault::share(v);
    transfer::public_transfer(oc, owner);
    clk.share_for_testing();
    (vault_id, cap_id)
}

// === Object-taking shorthands (cut return_shared boilerplate noise) ===

public fun take_vault(s: &Scenario): Vault { ts::take_shared<Vault>(s) }

public fun take_clock(s: &Scenario): Clock { ts::take_shared<Clock>(s) }

public fun return_vault(v: Vault) { ts::return_shared(v); }

public fun return_clock(c: Clock) { ts::return_shared(c); }

public fun take_owner_cap(s: &Scenario, owner: address): OwnerCap {
    ts::take_from_address<OwnerCap>(s, owner)
}

public fun take_spender_cap(s: &Scenario, spender: address): SpenderCap {
    ts::take_from_address<SpenderCap>(s, spender)
}

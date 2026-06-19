/// Basic usage: direct delegation.
///
/// The simplest end-to-end integration of `openzeppelin_allowance::spend_vault`:
/// an owner opens a funded, budgeted allowance for a known delegate address, the
/// delegate spends directly, the owner manages the grant, and finally the vault is
/// torn down. Everything here is generic over the coin type `T`, so the same code
/// serves any coin.
///
/// Each step is a separate `public fun` so you can see exactly which objects and
/// capabilities each call needs.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `spend_vault` allowance primitive can be integrated. It is not production-ready and
/// must not be deployed as-is.
module openzeppelin_allowance::direct_delegation;

use openzeppelin_allowance::spend_vault::{Self, Vault, OwnerCap, SpenderCap};
use sui::accumulator::AccumulatorRoot;
use sui::balance::Balance;
use sui::clock::Clock;
use sui::coin::Coin;

// === Owner setup ===

/// One PTB that creates the vault, funds it, mints a cap for `delegate`, grants a
/// budget, shares the vault, and returns the OwnerCap for the caller to keep or route.
///
/// Order matters: every fund / mint / grant step must precede `share`, because the
/// Vault is only addressable as a shared input in LATER transactions. The Vault has
/// no `drop`, so the tx fails unless it is consumed by `share` (or `destroy`).
///
/// Returns the `OwnerCap` by value rather than self-transferring it, so the caller
/// (or the enclosing PTB) decides its destination: composable.
public fun open_allowance<T>(
    funding: Coin<T>,
    delegate: address,
    budget: u64,
    expires_at_ms: u64, // pass std::u64::max_value!() for "no expiry"
    clock: &Clock,
    ctx: &mut TxContext,
): OwnerCap {
    let (mut vault, owner_cap) = spend_vault::new(ctx);

    // Permissionless top-up. Confers no rights; the funds become the owner's pool.
    vault.deposit(funding, ctx);

    // Bare cap, no budget yet. Returned by value, so we choose its destination.
    let cap = vault.mint_cap(&owner_cap, ctx);
    let cap_id = object::id(&cap);
    transfer::public_transfer(cap, delegate);

    // Create the (cap, T) budget. `option::none()` = no CAS guard on a fresh create.
    vault.set_allowance<T>(&owner_cap, cap_id, budget, expires_at_ms, option::none(), clock, ctx);

    // Make the vault spendable, then hand owner authority back to the caller.
    vault.share();
    owner_cap
}

// === Delegate spends ===

/// The delegate draws `amount` of `T` and gets it back as a wallet `Coin<T>`.
///
/// `spend` returns `Balance<T>`, which has no `drop`: it must be consumed in the
/// same PTB. Here we turn it into a `Coin` and return it, so the caller (or the
/// enclosing PTB) decides where the coin goes: composable. A spend aborts (with a
/// distinct, deterministic code) if the cap is wrong, the (cap, T) entry is missing,
/// the grant expired, or the amount is zero or over budget. It can also fail with the
/// `InsufficientFundsForWithdraw` execution status at `redeem_funds` if the pool is
/// short (surfaced via the SDK / a dry run, not a Move abort code).
///
/// Note `ctx: &mut TxContext`: both `into_coin` (to mint the Coin) and `spend` take
/// `&mut TxContext`, so one parameter serves both.
public fun spend_to_wallet<T>(
    vault: &mut Vault,
    cap: &SpenderCap,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    let bal = vault.spend<T>(cap, amount, clock, ctx);
    bal.into_coin(ctx)
}

// === Owner manages the grant ===

/// Raise / lower / renew with the race-free CAS idiom: read, then write with
/// `expected = Some(current)` in the SAME PTB. If a spend was sequenced between the
/// read and the write, the call aborts `EUnexpectedAllowance` instead of clobbering.
public fun change_budget<T>(
    vault: &mut Vault,
    owner_cap: &OwnerCap,
    cap_id: ID,
    new_budget: u64,
    new_expires_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let current = vault.allowance<T>(cap_id);
    vault.set_allowance<T>(
        owner_cap,
        cap_id,
        new_budget,
        new_expires_at_ms,
        option::some(current),
        clock,
        ctx,
    );
}

/// Suspend a grant without removing it: zero the budget but keep the entry + cap
/// alive. The next `spend<T>` aborts `EAllowanceExceeded` (NOT `ENoAllowance`), so
/// the spender knows to ask the owner to raise rather than to ask for a new grant.
public fun suspend<T>(
    vault: &mut Vault,
    owner_cap: &OwnerCap,
    cap_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // new_amount = 0 = suspend. A finite expiry must still be future, so reuse "no expiry".
    vault.set_allowance<T>(
        owner_cap,
        cap_id,
        0,
        std::u64::max_value!(),
        option::none(),
        clock,
        ctx,
    );
}

/// Owner kill-switch for one coin. Idempotent: returns whether anything was removed
/// (`false` is the typo'd-cap_id / wrong-coin signal). Cannot be raced into failure.
public fun revoke_one_coin<T>(
    vault: &mut Vault,
    owner_cap: &OwnerCap,
    cap_id: ID,
    ctx: &mut TxContext,
): bool {
    vault.revoke<T>(owner_cap, cap_id, ctx)
}

// === Owner exit + teardown ===

/// Drain one coin's settled pool to the owner. Needs the AccumulatorRoot (0xacc).
/// Run this in its OWN tx, never in the same PTB as a `spend` / `withdraw` on this
/// vault: a same-checkpoint pool drop makes the settled read over-ask and abort (the
/// settled-vs-live pool skew), retry-safe next checkpoint.
public fun drain_one_coin<T>(
    vault: &mut Vault,
    owner_cap: &OwnerCap,
    root: &AccumulatorRoot,
    ctx: &mut TxContext,
): Balance<T> {
    vault.withdraw_all<T>(owner_cap, root, ctx)
}

/// Tear down the vault. PRECONDITION: every coin already drained via
/// `withdraw_all<T>` (enumerate types off-chain with `suix_getAllBalances`), or any
/// remaining funds strand permanently at the dead vault address. `destroy` drains
/// only the budget ledger and deletes the UIDs; it does not touch the pool.
public fun tear_down(vault: Vault, owner_cap: OwnerCap, ctx: &mut TxContext) {
    vault.destroy(owner_cap, ctx);
}

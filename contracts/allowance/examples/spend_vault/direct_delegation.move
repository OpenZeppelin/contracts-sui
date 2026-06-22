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

/// Build a funded, budgeted allowance and return its three objects unattached, for
/// the caller to wire into the surrounding PTB. Creates the vault, deposits the
/// funding, mints a fresh cap, and grants it `budget` of `T`: then hands back
/// `(Vault, SpenderCap, OwnerCap)` without sharing or transferring anything.
///
/// The caller composes the edges in the SAME tx: share the vault with
/// `spend_vault::share(vault)`, `transfer::public_transfer` the `SpenderCap` to the
/// delegate, and keep or route the `OwnerCap`. The Vault has no `drop`, so it must be
/// shared (or destroyed) in this tx or execution aborts. Sharing must also come last:
/// the Vault is only addressable as a shared input in LATER transactions, so every
/// fund / mint / grant step here precedes the caller's `share`.
///
/// Returning the objects rather than self-wiring them keeps the flow composable: the
/// enclosing PTB decides every destination.
///
/// #### Parameters
/// - `funding`: The `Coin<T>` deposited into the new vault's pool (consumed by value).
/// - `budget`: The `(cap, T)` spend budget granted to the minted cap; `u64::MAX` is
///   the unlimited sentinel.
/// - `expires_at_ms`: Grant expiry in ms; pass `std::u64::max_value!()` for no expiry.
/// - `clock`: Reference to the Sui `Clock`, used to validate `expires_at_ms`.
/// - `ctx`: Transaction context.
///
/// #### Returns
/// - `(Vault, SpenderCap, OwnerCap)` by value, unattached, for the caller to share and
///   route in the same PTB.
///
/// #### Aborts
/// - `EZeroAmount` if `funding` has zero value (from `deposit`).
/// - `EExpiryInPast` if `expires_at_ms` is finite and not strictly in the future (from
///   `set_allowance`).
public fun open_allowance<T>(
    funding: Coin<T>,
    budget: u64,
    expires_at_ms: u64, // pass std::u64::max_value!() for "no expiry"
    clock: &Clock,
    ctx: &mut TxContext,
): (Vault, SpenderCap, OwnerCap) {
    let (mut vault, owner_cap) = spend_vault::new(ctx);

    // Permissionless top-up. Confers no rights; the funds become the owner's pool.
    vault.deposit(funding, ctx);

    // Bare cap, no budget yet. Returned by value, so the caller chooses its destination.
    let cap = vault.mint_cap(&owner_cap, ctx);
    let cap_id = object::id(&cap);

    // Create the (cap, T) budget. `option::none()` = no CAS guard on a fresh create.
    vault.set_allowance<T>(&owner_cap, cap_id, budget, expires_at_ms, option::none(), clock, ctx);

    // Hand the objects back; the caller shares the vault and routes the caps.
    (vault, cap, owner_cap)
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
///
/// #### Parameters
/// - `vault`: The vault to spend against.
/// - `cap`: The `SpenderCap` bound to `vault` whose `(cap, T)` budget is charged.
/// - `amount`: Units of coin `T` to draw; must be positive.
/// - `clock`: Reference to the Sui `Clock`, used to evaluate expiry.
/// - `ctx`: Transaction context.
///
/// #### Returns
/// - A `Coin<T>` of exactly `amount`.
///
/// #### Aborts
/// - `EWrongVault` if `cap` is bound to a different vault (from `spend`).
/// - `ENoAllowance` if there is no `(cap, T)` entry (from `spend`).
/// - `EAllowanceExpired` if the grant has expired (from `spend`).
/// - `EZeroAmount` if `amount == 0` (from `spend`).
/// - `EAllowanceExceeded` if `amount` exceeds the remaining budget (from `spend`).
/// - `InsufficientFundsForWithdraw` (Sui execution status, not a Move abort code) if the
///   settled pool is below `amount`; surfaced via effects / a dry run.
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
///
/// #### Parameters
/// - `vault`: The vault whose ledger is updated.
/// - `owner_cap`: The `OwnerCap` bound to `vault`.
/// - `cap_id`: The `SpenderCap` object id whose `(cap_id, T)` budget is changed.
/// - `new_budget`: New `remaining` budget; `0` suspends, `u64::MAX` is unlimited.
/// - `new_expires_at_ms`: New expiry in ms; `u64::MAX` is the no-expiry sentinel.
/// - `clock`: Reference to the Sui `Clock`, used to validate `new_expires_at_ms`.
/// - `ctx`: Transaction context.
///
/// #### Aborts
/// - `EWrongOwnerCap` if `owner_cap` is bound to a different vault (from `set_allowance`).
/// - `EExpiryInPast` if `new_expires_at_ms` is finite and not strictly future (from
///   `set_allowance`).
/// - `EUnexpectedAllowance` if a spend was sequenced between the read and the CAS write
///   (from `set_allowance`).
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
///
/// #### Parameters
/// - `vault`: The vault whose ledger is updated.
/// - `owner_cap`: The `OwnerCap` bound to `vault`.
/// - `cap_id`: The `SpenderCap` object id whose `(cap_id, T)` budget is suspended.
/// - `clock`: Reference to the Sui `Clock` (unused for the zero-budget path; required by
///   `set_allowance`).
/// - `ctx`: Transaction context.
///
/// #### Aborts
/// - `EWrongOwnerCap` if `owner_cap` is bound to a different vault (from `set_allowance`).
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
///
/// #### Parameters
/// - `vault`: The vault whose ledger entry is removed.
/// - `owner_cap`: The `OwnerCap` bound to `vault`.
/// - `cap_id`: The `SpenderCap` object id whose `(cap_id, T)` entry is targeted.
/// - `ctx`: Transaction context.
///
/// #### Returns
/// - `true` if an entry was present and removed; `false` if there was none.
///
/// #### Aborts
/// - `EWrongOwnerCap` if `owner_cap` is bound to a different vault (from `revoke`).
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
///
/// #### Parameters
/// - `vault`: The vault whose settled `T` pool is drained.
/// - `owner_cap`: The `OwnerCap` bound to `vault`.
/// - `root`: The `AccumulatorRoot` (`0xacc`), read for the settled pool value.
/// - `ctx`: Transaction context.
///
/// #### Returns
/// - A possibly-zero `Balance<T>` holding the drained settled pool; the caller must
///   consume it.
///
/// #### Aborts
/// - `EWrongOwnerCap` if `owner_cap` is bound to a different vault (from `withdraw_all`).
/// - `InsufficientFundsForWithdraw` (Sui execution status, not a Move abort code) if the
///   live pool fell below the settled snapshot earlier in this checkpoint; retry-safe.
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
///
/// #### Parameters
/// - `vault`: The vault to tear down (consumed by value).
/// - `owner_cap`: The `OwnerCap` bound to `vault` (consumed by value).
/// - `ctx`: Transaction context.
///
/// #### Aborts
/// - `EWrongOwnerCap` if `owner_cap` is bound to a different vault (from `destroy`).
public fun tear_down(vault: Vault, owner_cap: OwnerCap, ctx: &mut TxContext) {
    vault.destroy(owner_cap, ctx);
}

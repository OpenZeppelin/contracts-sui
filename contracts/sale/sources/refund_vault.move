/// Generic refundable escrow over `Balance<P>`. No knowledge of sales.
///
/// The vault is a standalone primitive. It can be used outside the
/// sales context as a generic refundable-escrow building block, though
/// in this library it is paired with `PrefundedSale<_, P>` and the
/// sale's lifecycle drives the vault's state.
///
/// ### State machine
///
/// ```text
///   Active  --cap-->  Refunding   (depositors claim individually)
///   Active  --cap-->  Closed      (controller withdraws all)
/// ```
///
/// One-way transitions. `Active` accepts deposits; the terminal states
/// do not. `Refunding` supports targeted per-amount releases; `Closed`
/// supports a single full withdrawal.
///
/// ### Pairing with a sale
///
/// `RefundVaultCap<P>` is phantom-typed on the payment coin so the cap
/// for a `RefundVault<USDC>` cannot be paired with a sale that uses SUI
/// as its payment coin — the type system rejects the mismatch at
/// compile time.
///
/// In the paired-sale flow, `pair_refund_vault` consumes the cap into
/// the sale; from that point on, only the sale's gated functions drive
/// the vault. Admin cannot bypass the sale to drain the vault.
///
/// ### Pairing requires an empty vault
///
/// The paired sale asserts `value(vault) == 0` before accepting the
/// cap. Pre-existing funds would be stranded: the cap is wrapped into
/// the sale, `withdraw_all` requires `Closed` (reachable only via the
/// sale's `finalize`), and the sale's withdrawals only touch funds it
/// routed itself. Don't pair a vault that has been used before.
module openzeppelin_sale::refund_vault;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;

// === Errors ===

#[error(code = 0)]
const ENotActiveState: vector<u8> = "Vault must be in Active state";
#[error(code = 1)]
const ENotRefundingState: vector<u8> = "Vault must be in Refunding state";
#[error(code = 2)]
const ENotClosedState: vector<u8> = "Vault must be in Closed state";
#[error(code = 10)]
const EWrongVaultCap: vector<u8> = "Cap does not match this vault";
#[error(code = 20)]
const EInsufficientLocked: vector<u8> = "Release amount exceeds locked balance";

// === State ===

public enum VaultState has copy, drop, store {
    Active,
    Refunding,
    Closed,
}

public struct RefundVault<phantom P> has key {
    id: UID,
    locked: Balance<P>,
    state: VaultState,
}

/// Controller capability. Phantom-typed on `P` so it can only be paired
/// with vaults (and sales) of the matching payment coin.
public struct RefundVaultCap<phantom P> has key, store {
    id: UID,
    vault_id: ID,
}

// === Events ===

public struct RefundVaultCreated<phantom P> has copy, drop {
    vault_id: ID,
}

public struct VaultDeposit<phantom P> has copy, drop {
    vault_id: ID,
    amount: u64,
    locked_after: u64,
}

public struct VaultStateChanged<phantom P> has copy, drop {
    vault_id: ID,
    old_state: VaultState,
    new_state: VaultState,
}

public struct VaultRelease<phantom P> has copy, drop {
    vault_id: ID,
    amount: u64,
    locked_after: u64,
}

// === Construction ===

/// Create a fresh vault in `Active` state. Returns the vault (caller
/// shares it) and the controller cap.
///
/// The typical paired-sale flow is `new` → pair with a sale → `share`,
/// in that order, so the sale can take the vault by reference before
/// the vault becomes shared.
public fun new<P>(ctx: &mut TxContext): (RefundVault<P>, RefundVaultCap<P>) {
    let vault = RefundVault<P> {
        id: object::new(ctx),
        locked: balance::zero<P>(),
        state: VaultState::Active,
    };
    let vault_id = object::id(&vault);
    let cap = RefundVaultCap<P> { id: object::new(ctx), vault_id };
    event::emit(RefundVaultCreated<P> { vault_id });
    (vault, cap)
}

/// Share an existing vault. Provided because `RefundVault<P>` is
/// `key`-only — external modules cannot call
/// `transfer::public_share_object` on it directly.
public fun share<P>(vault: RefundVault<P>) {
    transfer::share_object(vault);
}

// === Cap-gated mutations ===

/// Deposit funds. Vault must be in `Active` state.
public fun deposit<P>(vault: &mut RefundVault<P>, cap: &RefundVaultCap<P>, funds: Balance<P>) {
    assert_cap(vault, cap);
    assert!(is_active_state(&vault.state), ENotActiveState);
    let amount = balance::value(&funds);
    balance::join(&mut vault.locked, funds);
    event::emit(VaultDeposit<P> {
        vault_id: object::id(vault),
        amount,
        locked_after: balance::value(&vault.locked),
    });
}

/// Transition `Active → Refunding`. Enables per-amount releases.
public fun flip_to_refunding<P>(vault: &mut RefundVault<P>, cap: &RefundVaultCap<P>) {
    assert_cap(vault, cap);
    assert!(is_active_state(&vault.state), ENotActiveState);
    let old = vault.state;
    vault.state = VaultState::Refunding;
    event::emit(VaultStateChanged<P> {
        vault_id: object::id(vault),
        old_state: old,
        new_state: vault.state,
    });
}

/// Transition `Active → Closed`. Enables `withdraw_all`.
public fun flip_to_closed<P>(vault: &mut RefundVault<P>, cap: &RefundVaultCap<P>) {
    assert_cap(vault, cap);
    assert!(is_active_state(&vault.state), ENotActiveState);
    let old = vault.state;
    vault.state = VaultState::Closed;
    event::emit(VaultStateChanged<P> {
        vault_id: object::id(vault),
        old_state: old,
        new_state: vault.state,
    });
}

/// Release a specific amount. Vault must be in `Refunding`. Returns
/// `Balance<P>` so the caller can wrap into a `Coin<P>` as needed.
public fun release_balance<P>(
    vault: &mut RefundVault<P>,
    cap: &RefundVaultCap<P>,
    amount: u64,
): Balance<P> {
    assert_cap(vault, cap);
    assert!(is_refunding_state(&vault.state), ENotRefundingState);
    assert!(balance::value(&vault.locked) >= amount, EInsufficientLocked);
    let part = balance::split(&mut vault.locked, amount);
    event::emit(VaultRelease<P> {
        vault_id: object::id(vault),
        amount,
        locked_after: balance::value(&vault.locked),
    });
    part
}

/// Withdraw the entire locked balance. Vault must be in `Closed`.
public fun withdraw_all<P>(
    vault: &mut RefundVault<P>,
    cap: &RefundVaultCap<P>,
    ctx: &mut TxContext,
): Coin<P> {
    assert_cap(vault, cap);
    assert!(is_closed_state(&vault.state), ENotClosedState);
    let amount = balance::value(&vault.locked);
    let part = balance::split(&mut vault.locked, amount);
    event::emit(VaultRelease<P> {
        vault_id: object::id(vault),
        amount,
        locked_after: 0,
    });
    coin::from_balance(part, ctx)
}

// === Views ===

public fun state<P>(vault: &RefundVault<P>): VaultState { vault.state }

/// Locked balance amount in `P`'s smallest units.
public fun value<P>(vault: &RefundVault<P>): u64 { balance::value(&vault.locked) }

public fun cap_vault_id<P>(cap: &RefundVaultCap<P>): ID { cap.vault_id }

public fun is_active<P>(vault: &RefundVault<P>): bool { is_active_state(&vault.state) }

public fun is_refunding<P>(vault: &RefundVault<P>): bool { is_refunding_state(&vault.state) }

public fun is_closed<P>(vault: &RefundVault<P>): bool { is_closed_state(&vault.state) }

// === Internal helpers ===

fun assert_cap<P>(vault: &RefundVault<P>, cap: &RefundVaultCap<P>) {
    assert!(cap.vault_id == object::id(vault), EWrongVaultCap);
}

fun is_active_state(s: &VaultState): bool {
    match (s) {
        VaultState::Active => true,
        _ => false,
    }
}

fun is_refunding_state(s: &VaultState): bool {
    match (s) {
        VaultState::Refunding => true,
        _ => false,
    }
}

fun is_closed_state(s: &VaultState): bool {
    match (s) {
        VaultState::Closed => true,
        _ => false,
    }
}

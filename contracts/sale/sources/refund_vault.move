/// Generic refundable escrow over `Balance<P>`. No knowledge of sales.
///
/// The vault is a standalone primitive. It can be used outside the
/// sales context as a generic refundable-escrow building block, though
/// in this library it is paired with a `PrefundedSale` whose payment coin is
/// `P`, and the sale's lifecycle drives the vault's state.
///
/// ### State machine
///
/// ```text
///   Active  --cap-->  Refunding   (controller releases per-amount, cap-gated)
///   Active  --cap-->  Closed      (controller withdraws all)
/// ```
///
/// One-way transitions. `Active` accepts deposits; the terminal states
/// do not. `Refunding` supports targeted per-amount releases; `Closed`
/// supports a single full withdrawal. Every egress is gated on the
/// `RefundVaultCap`; the vault keeps no per-depositor ledger and
/// `release_balance` takes no claimant. Per-depositor accounting, when
/// needed, lives in the layer holding the cap - in the paired-sale flow,
/// the sale, which authorizes each buyer's `refund` against a `Receipt`.
///
/// ### Pairing with a sale
///
/// `RefundVaultCap<P>` is phantom-typed on the payment coin so the cap
/// for a `RefundVault<USDC>` cannot be paired with a sale that uses SUI
/// as its payment coin - the type system rejects the mismatch at
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
use sui::event;

// === Errors ===

/// A state-gated operation required the `Active` state (deposits, `flip_to_*`).
#[error(code = 0)]
const ENotActiveState: vector<u8> = "The refund vault must be active";

/// `release_balance` was called while the vault was not in the `Refunding` state.
#[error(code = 1)]
const ENotRefundingState: vector<u8> = "The refund vault must be in the refunding state";

/// `withdraw_all` was called while the vault was not in the `Closed` state.
#[error(code = 2)]
const ENotClosedState: vector<u8> = "The refund vault must be closed";

/// The supplied cap does not control this vault (`cap.vault_id != id(vault)`).
#[error(code = 3)]
const EWrongVaultCap: vector<u8> = "This capability does not control this refund vault";

/// A release requested more than the vault's locked balance.
#[error(code = 4)]
const EInsufficientLocked: vector<u8> = "The requested amount exceeds the funds held in the vault";

// === Structs ===

/// The refund vault's lifecycle state. Transitions are one-way:
/// `Active -> Refunding` or `Active -> Closed`.
public enum VaultState has copy, drop, store {
    /// Accepting deposits.
    Active,
    /// The controller releases funds per-amount via `release_balance`
    /// (cap-gated; no per-depositor ledger, no claimant argument).
    Refunding,
    /// The controller withdraws the whole balance via `withdraw_all`.
    Closed,
}

/// A refundable escrow over `Balance<P>`. Holds locked funds and a lifecycle state;
/// every mutation requires the matching `RefundVaultCap<P>`.
public struct RefundVault<phantom P> has key {
    id: UID,
    /// Funds currently held by the vault.
    locked: Balance<P>,
    /// Current lifecycle state.
    state: VaultState,
}

/// Controller capability. Phantom-typed on `P` so it can only be paired
/// with vaults (and sales) of the matching payment coin.
public struct RefundVaultCap<phantom P> has key, store {
    id: UID,
    /// Id of the vault this cap controls.
    vault_id: ID,
}

// === Events ===

/// Emitted by `new` when a vault is created.
public struct RefundVaultCreated<phantom P> has copy, drop {
    vault_id: ID,
    /// Id of the controller cap minted alongside the vault.
    cap_id: ID,
}

/// Emitted by `deposit` when funds are added to the locked balance.
public struct VaultDeposit<phantom P> has copy, drop {
    vault_id: ID,
    /// Amount added by this deposit.
    amount: u64,
    /// Locked balance after this deposit.
    locked_after: u64,
}

/// Emitted by `flip_to_refunding` and `flip_to_closed` when the state changes.
public struct VaultStateChanged<phantom P> has copy, drop {
    vault_id: ID,
    old_state: VaultState,
    new_state: VaultState,
}

/// Emitted by `release_balance` and `withdraw_all` when funds leave the vault.
public struct VaultRelease<phantom P> has copy, drop {
    vault_id: ID,
    /// Amount released by this call.
    amount: u64,
    /// Locked balance remaining after this release.
    locked_after: u64,
}

// === Public Functions ===

// === Construction ===

/// Create a fresh vault in `Active` state. Returns the vault (caller shares it) and
/// the controller cap.
///
/// The typical paired-sale flow is `new` -> `prefunded_sale::pair_refund_vault` (which
/// takes the vault by reference) -> `prefunded_sale::share_and_activate` (which consumes
/// the vault by value and shares it alongside the sale). Integrators should not call
/// `share` themselves in this flow; use `share` only when using a vault standalone, outside a sale.
///
/// #### Parameters
/// - `ctx`: Transaction context, used to allocate the vault and cap `UID`s.
///
/// #### Returns
/// - The new `RefundVault<P>` (in `Active` state, empty) and its `RefundVaultCap<P>`.
public fun new<P>(ctx: &mut TxContext): (RefundVault<P>, RefundVaultCap<P>) {
    let vault = RefundVault {
        id: object::new(ctx),
        locked: balance::zero(),
        state: VaultState::Active,
    };
    let vault_id = object::id(&vault);
    let cap = RefundVaultCap { id: object::new(ctx), vault_id };
    event::emit(RefundVaultCreated<P> { vault_id, cap_id: object::id(&cap) });
    (vault, cap)
}

/// Share an existing vault. Provided because `RefundVault<P>` is `key`-only -
/// external modules cannot call `transfer::public_share_object` on it directly.
///
/// #### Parameters
/// - `vault`: The vault to share.
public fun share<P>(vault: RefundVault<P>) {
    transfer::share_object(vault);
}

// === Cap-gated mutations ===

/// Deposit funds into the locked balance. Vault must be in `Active` state.
///
/// A deposit of a zero-value balance is a no-op: the balance is consumed but no
/// `VaultDeposit` event is emitted.
///
/// #### Parameters
/// - `vault`: The vault to deposit into.
/// - `cap`: The vault's controller cap.
/// - `funds`: The balance to add to the locked balance.
///
/// #### Aborts
/// - `EWrongVaultCap` if `cap` does not control `vault`.
/// - `ENotActiveState` if `vault` is not in `Active` state.
/// - Arithmetic overflow if the deposit would push the locked balance past `u64::MAX`.
public fun deposit<P>(vault: &mut RefundVault<P>, cap: &RefundVaultCap<P>, funds: Balance<P>) {
    assert_cap(vault, cap);
    assert!(vault.state.is_active_state(), ENotActiveState);
    let amount = funds.value();
    vault.locked.join(funds);
    if (amount == 0) return;
    event::emit(VaultDeposit<P> {
        vault_id: object::id(vault),
        amount,
        locked_after: vault.locked.value(),
    });
}

/// Transition `Active -> Refunding`. Enables per-amount releases.
///
/// #### Parameters
/// - `vault`: The vault to transition.
/// - `cap`: The vault's controller cap.
///
/// #### Aborts
/// - `EWrongVaultCap` if `cap` does not control `vault`.
/// - `ENotActiveState` if `vault` is not in `Active` state.
public fun flip_to_refunding<P>(vault: &mut RefundVault<P>, cap: &RefundVaultCap<P>) {
    assert_cap(vault, cap);
    assert!(vault.state.is_active_state(), ENotActiveState);
    let old = vault.state;
    vault.state = VaultState::Refunding;
    event::emit(VaultStateChanged<P> {
        vault_id: object::id(vault),
        old_state: old,
        new_state: vault.state,
    });
}

/// Transition `Active -> Closed`. Enables `withdraw_all`.
///
/// #### Parameters
/// - `vault`: The vault to transition.
/// - `cap`: The vault's controller cap.
///
/// #### Aborts
/// - `EWrongVaultCap` if `cap` does not control `vault`.
/// - `ENotActiveState` if `vault` is not in `Active` state.
public fun flip_to_closed<P>(vault: &mut RefundVault<P>, cap: &RefundVaultCap<P>) {
    assert_cap(vault, cap);
    assert!(vault.state.is_active_state(), ENotActiveState);
    let old = vault.state;
    vault.state = VaultState::Closed;
    event::emit(VaultStateChanged<P> {
        vault_id: object::id(vault),
        old_state: old,
        new_state: vault.state,
    });
}

/// Release a specific amount from the locked balance. Vault must be in `Refunding`.
/// Returns `Balance<P>` so the caller can wrap it into a `Coin<P>` as needed.
///
/// #### Parameters
/// - `vault`: The vault to release from.
/// - `cap`: The vault's controller cap.
/// - `amount`: The amount to release.
///
/// #### Returns
/// - A `Balance<P>` of exactly `amount`, split from the locked balance.
///
/// #### Aborts
/// - `EWrongVaultCap` if `cap` does not control `vault`.
/// - `ENotRefundingState` if `vault` is not in `Refunding` state.
/// - `EInsufficientLocked` if `amount` exceeds the locked balance.
public fun release_balance<P>(
    vault: &mut RefundVault<P>,
    cap: &RefundVaultCap<P>,
    amount: u64,
): Balance<P> {
    assert_cap(vault, cap);
    assert!(vault.state.is_refunding_state(), ENotRefundingState);
    assert!(vault.locked.value() >= amount, EInsufficientLocked);
    let part = vault.locked.split(amount);
    event::emit(VaultRelease<P> {
        vault_id: object::id(vault),
        amount,
        locked_after: vault.locked.value(),
    });
    part
}

/// Withdraw the entire locked balance. Vault must be in `Closed`.
///
/// Idempotent: a second call (or one against an empty vault) returns an empty balance
/// and emits no `VaultRelease` event.
///
/// #### Parameters
/// - `vault`: The vault to drain.
/// - `cap`: The vault's controller cap.
///
/// #### Returns
/// - A `Balance<P>` holding the entire locked balance.
///
/// #### Aborts
/// - `EWrongVaultCap` if `cap` does not control `vault`.
/// - `ENotClosedState` if `vault` is not in `Closed` state.
public fun withdraw_all<P>(vault: &mut RefundVault<P>, cap: &RefundVaultCap<P>): Balance<P> {
    assert_cap(vault, cap);
    assert!(vault.state.is_closed_state(), ENotClosedState);
    let amount = vault.locked.value();
    let part = vault.locked.split(amount);
    if (amount > 0) {
        event::emit(VaultRelease<P> {
            vault_id: object::id(vault),
            amount,
            locked_after: 0,
        });
    };
    part
}

// === View helpers ===

/// The vault's current state (`Active`, `Refunding`, or `Closed`).
///
/// #### Parameters
/// - `vault`: The vault to query.
///
/// #### Returns
/// - The current `VaultState`.
public fun state<P>(vault: &RefundVault<P>): VaultState { vault.state }

/// The locked balance amount in `P`'s smallest units.
///
/// #### Parameters
/// - `vault`: The vault to query.
///
/// #### Returns
/// - The locked balance amount.
public fun value<P>(vault: &RefundVault<P>): u64 { vault.locked.value() }

/// The id of the vault this cap controls.
///
/// #### Parameters
/// - `cap`: The controller cap to read.
///
/// #### Returns
/// - The controlled vault's id.
public fun cap_vault_id<P>(cap: &RefundVaultCap<P>): ID { cap.vault_id }

/// True if the vault is in `Active` state.
///
/// #### Parameters
/// - `vault`: The vault to query.
///
/// #### Returns
/// - Whether the vault is `Active`.
public fun is_active<P>(vault: &RefundVault<P>): bool { vault.state.is_active_state() }

/// True if the vault is in `Refunding` state.
///
/// #### Parameters
/// - `vault`: The vault to query.
///
/// #### Returns
/// - Whether the vault is `Refunding`.
public fun is_refunding<P>(vault: &RefundVault<P>): bool { vault.state.is_refunding_state() }

/// True if the vault is in `Closed` state.
///
/// #### Parameters
/// - `vault`: The vault to query.
///
/// #### Returns
/// - Whether the vault is `Closed`.
public fun is_closed<P>(vault: &RefundVault<P>): bool { vault.state.is_closed_state() }

// === Private Functions ===

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

// === Test-Only Helpers ===
//
// Event struct fields and the `VaultState` variants are module-private, so tests in
// other modules cannot build an expected event to compare against
// `event::events_by_type`. These mirror the `test_new_*` seam used by
// `openzeppelin_finance::vesting_wallet`.

/// The `Active` vault state, for asserting `VaultStateChanged` events.
#[test_only]
public fun test_state_active(): VaultState { VaultState::Active }

/// The `Refunding` vault state, for asserting `VaultStateChanged` events.
#[test_only]
public fun test_state_refunding(): VaultState { VaultState::Refunding }

/// The `Closed` vault state, for asserting `VaultStateChanged` events.
#[test_only]
public fun test_state_closed(): VaultState { VaultState::Closed }

/// Build a `RefundVaultCreated` event value for asserting against `event::events_by_type`.
#[test_only]
public fun test_new_refund_vault_created<P>(vault_id: ID, cap_id: ID): RefundVaultCreated<P> {
    RefundVaultCreated { vault_id, cap_id }
}

/// Build a `VaultDeposit` event value for asserting against `event::events_by_type`.
#[test_only]
public fun test_new_vault_deposit<P>(
    vault_id: ID,
    amount: u64,
    locked_after: u64,
): VaultDeposit<P> {
    VaultDeposit { vault_id, amount, locked_after }
}

/// Build a `VaultStateChanged` event value for asserting against `event::events_by_type`.
#[test_only]
public fun test_new_vault_state_changed<P>(
    vault_id: ID,
    old_state: VaultState,
    new_state: VaultState,
): VaultStateChanged<P> {
    VaultStateChanged { vault_id, old_state, new_state }
}

/// Build a `VaultRelease` event value for asserting against `event::events_by_type`.
#[test_only]
public fun test_new_vault_release<P>(
    vault_id: ID,
    amount: u64,
    locked_after: u64,
): VaultRelease<P> {
    VaultRelease { vault_id, amount, locked_after }
}

/// Advanced usage: a protocol custodies a user's `SpenderCap` and spends on their
/// behalf. This is the library's primary use case.
///
/// A keeper service holds users' caps and draws from their vaults within the
/// per-coin budget and expiry the vault owner set, without the owner signing each
/// spend. The service is untyped and `execute_topup<T>` is generic, so one custodied
/// cap can be driven for every coin the owner budgeted it for.
///
/// #### The flow an integrator must get right
///
/// 1. Create a `Service` pinned to exactly ONE vault id and share it. Pinning up
///    front is what makes the step-2 binding check meaningful.
/// 2. The user mints a cap (`mint_cap` returns it by value) and hands it into
///    custody via `register`, which validates the cap's vault binding
///    (`spender_cap_vault_id`) BEFORE accepting it. This is the custody-boundary
///    rule for ANY protocol that takes a `SpenderCap`.
/// 3. The operator calls `execute_topup<T>` to draw coin `T`. **This is
///    sender-gated, and the gate is the point of this module:** a `SpenderCap` is a
///    bearer instrument, so any code that gets the library to see `&cap` exercises
///    its full authority. An ungated public function that borrows a custodied cap is
///    world-drainable, so the operator check is the integration's security boundary,
///    not optional hygiene.
/// 4. The user reclaims the cap any time with `unregister`.
///
/// The vault owner keeps full control throughout: raising, lowering, suspending, or
/// revoking the grant (`set_allowance` / `revoke` / `revoke_all`) never changes the
/// cap object, so a cap embedded here keeps working and is never re-registered.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `spend_vault` allowance primitive can be integrated. It is not production-ready and
/// must not be deployed as-is.
module openzeppelin_allowance::defi_keeper;

use openzeppelin_allowance::spend_vault::{Vault, SpenderCap};
use sui::balance::Balance;
use sui::clock::Clock;
use sui::table::{Self, Table};

// === Errors ===

#[error(code = 0)]
const ENotOperator: vector<u8> = "Caller is not the service operator";
#[error(code = 1)]
const EWrongVaultForService: vector<u8> =
    "Cap is bound to a different vault than this service serves";
#[error(code = 2)]
const ENotRegistered: vector<u8> = "No cap registered under this user address";

// === Structs ===

/// Shared keeper service. Serves exactly one `Vault` and custodies at most one cap
/// per user. Untyped, so one service drives every coin a cap is budgeted for.
public struct Service has key {
    id: UID,
    operator: address,
    vault_id: ID,
    caps: Table<address, SpenderCap>,
}

// === Public Functions ===

/// Create a service pinned to `vault_id` and return it for the caller to configure
/// and then `share`. The creator becomes the operator, the only address the
/// cap-borrowing entrypoint accepts. Returning the `Service` rather than sharing it
/// here keeps the flow composable: a `Service` is `key`-only, so the caller must use
/// this module's `share` to make it shared.
///
/// #### Parameters
/// - `vault_id`: The id of the one `Vault` this service serves; pin it up front so the
///   `register` binding check is meaningful.
/// - `ctx`: Transaction context; the sender becomes the operator.
///
/// #### Returns
/// - A `key`-only `Service` by value; consume it with this module's `share`.
///
/// #### Aborts
/// - Never.
public fun create(vault_id: ID, ctx: &mut TxContext): Service {
    Service {
        id: object::new(ctx),
        operator: ctx.sender(),
        vault_id,
        caps: table::new(ctx),
    }
}

/// Share the service so users can register caps against it. Two-step
/// create-then-share keeps the flow composable (mirrors `spend_vault::share`).
public fun share(service: Service) {
    transfer::share_object(service);
}

/// Hand a cap into the service's custody, keyed by the registering sender.
///
/// The binding check is the custody-boundary rule for ANY protocol that accepts a
/// `SpenderCap`: validate `spender_cap_vault_id` against the vault you intend to
/// spend from, on-chain, BEFORE taking the cap.
///
/// #### Parameters
/// - `s`: The service taking the cap into custody.
/// - `cap`: The `SpenderCap` to custody (consumed by value), keyed by the sender.
/// - `ctx`: Transaction context; the sender is the custody key.
///
/// #### Aborts
/// - `EWrongVaultForService` if `cap` is bound to a different vault than `s` serves.
public fun register(s: &mut Service, cap: SpenderCap, ctx: &mut TxContext) {
    assert!(cap.spender_cap_vault_id() == s.vault_id, EWrongVaultForService);
    s.caps.add(ctx.sender(), cap);
}

/// Draw `amount` of coin `T` from `user`'s allowance and return the funds for the
/// caller to route (into a position, a `Coin`, ...). Generic over `T`, so the same
/// custodied cap serves every coin the owner budgeted it for; asking for a coin the
/// owner never granted aborts inside the library (`ENoAllowance`), so this fails
/// safe.
///
/// SENDER-GATED: the operator check below is the security boundary. The library
/// never checks who calls `spend`, so the custody layer must.
///
/// #### Parameters
/// - `s`: The service custodying `user`'s cap.
/// - `v`: The vault to spend against; must be the one `s` serves and the cap is bound to.
/// - `user`: The address whose custodied cap is charged.
/// - `amount`: Units of coin `T` to draw; must be positive.
/// - `clock`: Reference to the Sui `Clock`, used to evaluate expiry.
/// - `ctx`: Transaction context; the sender must be the operator.
///
/// #### Returns
/// - A `Balance<T>` of exactly `amount`; the caller must consume it.
///
/// #### Aborts
/// - `ENotOperator` if the caller is not the service operator.
/// - `ENotRegistered` if `user` has no cap in custody.
/// - `EWrongVault` if `v` is not the vault the cap is bound to (from `spend`).
/// - `ENoAllowance` if there is no `(cap, T)` entry (from `spend`).
/// - `EAllowanceExpired` if the grant has expired (from `spend`).
/// - `EZeroAmount` if `amount == 0` (from `spend`).
/// - `EAllowanceExceeded` if `amount` exceeds the remaining budget (from `spend`).
/// - `InsufficientFundsForWithdraw` (Sui execution status, not a Move abort code) if the
///   settled pool is below `amount`; surfaced via effects / a dry run.
public fun execute_topup<T>(
    s: &mut Service,
    v: &mut Vault,
    user: address,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Balance<T> {
    assert!(ctx.sender() == s.operator, ENotOperator);
    assert!(s.caps.contains(user), ENotRegistered);

    let cap = s.caps.borrow(user);
    v.spend<T>(cap, amount, clock, ctx)
}

/// Take a cap back out of custody. The grant is untouched: it stays live in the
/// vault; only custody of the cap changes hands.
///
/// #### Parameters
/// - `s`: The service releasing the cap.
/// - `ctx`: Transaction context; the sender must have a cap in custody.
///
/// #### Returns
/// - The caller's `SpenderCap`, removed from custody.
///
/// #### Aborts
/// - `ENotRegistered` if the sender has no cap in custody.
public fun unregister(s: &mut Service, ctx: &mut TxContext): SpenderCap {
    assert!(s.caps.contains(ctx.sender()), ENotRegistered);
    s.caps.remove(ctx.sender())
}

// === View helpers ===

/// The vault this service is pinned to.
public fun vault_id(s: &Service): ID {
    s.vault_id
}

/// Whether `user` currently has a cap in custody.
public fun is_registered(s: &Service, user: address): bool {
    s.caps.contains(user)
}

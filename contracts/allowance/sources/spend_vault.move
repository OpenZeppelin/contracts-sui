/// Cap-keyed, multi-coin allowance / approval primitive for Sui.
///
/// > **BEARER-CAP WARNING: read this first.** A `SpenderCap` is a bearer
/// > instrument: whoever can present `&SpenderCap` to `spend` exercises the
/// > FULL spend authority of EVERY per-coin budget that cap holds, up to each
/// > budget's limits: holder, borrower, custodian protocol, or thief alike.
/// > One untyped cap spans N coin budgets, so a leaked cap
/// > exposes the SUM across all coins the owner granted it. The library never
/// > inspects holder identity, provenance, or intent; transfer of the cap is
/// > transfer of authority, and sending it to the wrong party hands that party
/// > the authority. There is no recipient binding in this module. Owner-side
/// > mitigations: small per-coin budgets, finite expiry per `(cap, coin)`,
/// > suspension (`set_allowance(..., 0, ...)`), and `revoke_all` (bounds a
/// > leaked cap's exposure to zero in one call). Integrators custodying a cap
/// > MUST sender-gate any function that borrows it: an ungated public borrow is
/// > world-drainable authority.
///
/// A `Vault` is a single UNTYPED shared escrow that holds N coin types at once.
/// Its pool is NOT a struct field: per-coin funds live as object-owned
/// **address balances** at the vault's own object address
/// (`object::id_address(&v)`). Authority to spend the pool is possession of
/// `&mut v.id`, which only this module produces and, for any fund egress, only
/// ever behind a cap gate: there is no EOA signer. (The one ungated `&mut v.id`
/// use is `squash`, which is permissionless but strictly funds-in.) Owner
/// authority is a transferable
/// `OwnerCap`; spend authority is a transferable, embeddable `SpenderCap`. Each
/// cap carries its per-coin budgets in a ledger keyed by `(cap_id, coin_type)`,
/// never in the cap. `spend`, `withdraw`, and `withdraw_all` all return
/// `Balance<T>`.
///
/// #### When to use which
///
/// You want to...                                Call
/// ------------------------------------------   -----------------------------
/// issue a cap now, set the budget later         mint_cap (bare; transfer/embed it)
/// create OR change a (cap, coin) budget         set_allowance<T> (upsert; 0 = suspend)
/// suspend a grant (keep cap valid)              set_allowance<T>(new_amount = 0)
/// end one coin of a grant (owner side)          revoke<T> (idempotent; returns was_present)
/// end an entire cap (owner side)                revoke_all (whole-cap kill)
/// end a grant (spender side)                    renounce (consumes cap, all coins)
/// dispose an orphaned cap (vault destroyed)     delete_orphaned_cap (prefer renounce if vault still live)
/// recover a stray Coin sent to the vault        squash<T> (permissionless)
/// emergency stop                                revoke_all (tx1), then withdraw_all<T> (tx2, retry-safe)
/// tear down the vault                           withdraw_all<T> every coin, THEN destroy
///
/// #### Core semantics
///
/// - **Untyped, multi-coin.** There is no phantom type; cross-coin safety is a
///   runtime gate. The ledger is keyed by `BudgetKey{cap_id, coin_type}`, and
///   `spend<T>` looks up the `(cap, T)` entry by that key. The coin type is
///   always `type_name::with_defining_ids<T>()`, never the deprecated `get`
///   (mixing the two would fragment the ledger).
/// - **Mixed error model.** This module's own aborts are dense codes 0..7. The
///   pool-short case is not one of them: it surfaces as the Sui execution status
///   `InsufficientFundsForWithdraw` (a funds-accumulator `ExecutionFailureStatus`)
///   raised at `redeem_funds` when the object's settled balance is below the
///   amount. You see it as a status in transaction effects or a dry run, not as a
///   matchable Move `#[error]` code, so integrator preflight must handle it on top
///   of this module's codes.
/// - **Ceiling, not guarantee.** Allowances are spending limits, not
///   reservations: the live `remaining` values may sum to more than the pool, by
///   design (over-subscription across coins is sound). So a live, unexpired,
///   within-budget `spend` can still fail with `InsufficientFundsForWithdraw` if
///   the owner withdrew first or sibling spenders drained the pool. Nothing is
///   reserved per entry; competing spenders are served in consensus order, first
///   sequenced first served.
/// - **Exact-amount-or-abort `spend`.** A successful `spend` delivers exactly
///   `amount` and decrements `remaining` by exactly `amount` (the `u64::MAX`
///   unlimited sentinel is never decremented). On any abort, every entry and the
///   pool are left bit-identical to the pre-call state, since Move's atomic revert
///   rolls back the pre-decrement.
/// - **`u64::MAX` sentinels.** `remaining == u64::MAX` means unlimited and
///   `expires_at_ms == u64::MAX` means no expiry. Both are tested by equality
///   only; no arithmetic ever touches them. The trade-off: a deliberate finite
///   grant of exactly `u64::MAX` is unrepresentable, and SDKs must exclude
///   `remaining == u64::MAX` from volume math.
/// - **Bare mint, upsert set.** `mint_cap` creates no ledger entry: it returns a
///   budgetless, untyped cap by value for the caller to transfer or embed.
///   `set_allowance<T>` is a per-`(cap, coin)` upsert: it creates the entry if
///   absent (recording the coin in `granted_coin_types`), otherwise overwrites it
///   in place. Re-setting a key overwrites, it never adds, so the only way to give
///   one person two summing budgets is two caps.
/// - **`cap_id` stable across `set_allowance`.** Owner-side changes mutate the
///   entry in place, keyed by `cap_id`; the cap object, its id, and every
///   downstream embedding survive any number of owner updates. This is the
///   load-bearing composition property of the cap-keyed design.
/// - **Suspension idiom.** `set_allowance<T>(..., 0, ...)` zeroes the budget but
///   keeps the entry and cap alive, so the next `spend<T>` aborts
///   `EAllowanceExceeded` rather than `ENoAllowance`. Removal is lazy too: entries
///   go away only on `revoke`, `revoke_all`, `renounce`, or `destroy`, never by
///   spending to zero.
/// - **Opt-in CAS on `set_allowance`.** Pass `expected = Some(e)` on any
///   read-derived update. The race-free idiom is `allowance<T>()` then
///   `set_allowance<T>(..., Some(result), ...)` in one PTB: the shared Vault is
///   locked for the tx, so the read/write pair is atomic. `Some(e)` on an absent
///   entry aborts, since there is no value to match.
/// - **Unconditional owner exit.** `withdraw`, `withdraw_all`, and `destroy`
///   consult only the OwnerCap binding and the pool, never the ledger, so no
///   spender or ledger state can block defunding or teardown. `withdraw_all<T>`
///   drains the settled (start-of-checkpoint) pool via `settled_funds_value`
///   (a self-tracked counter would desync against permissionless top-ups). It can
///   still fail with `InsufficientFundsForWithdraw` if the live pool fell earlier
///   in the same checkpoint (the settled-vs-live skew, retry-safe next
///   checkpoint), but never on spender or ledger state.
/// - **Owner-enumerated teardown.** `destroy` drains the ledger and the UIDs and
///   returns nothing: it cannot iterate runtime coin types to drain the
///   heterogeneous address balances. The owner must `withdraw_all<T>` every coin
///   first, enumerating the types off-chain via
///   `suix_getAllBalances(vault_address)` (which lists every address-balance type
///   plus loose coins), or those funds strand at the dead vault address.
module openzeppelin_allowance::spend_vault;

use std::type_name::{Self, TypeName};
use sui::accumulator::AccumulatorRoot;
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::Coin;
use sui::event;
use sui::linked_table::{Self, LinkedTable};
use sui::transfer::Receiving;
use sui::vec_set::{Self, VecSet};

// === Errors ===
//
// Dense, first-publication ABI: codes 0..7, no reserved gaps. There is
// deliberately NO `EInsufficientVault`: the pool-short case is covered by the
// Sui execution status `InsufficientFundsForWithdraw` (a funds-accumulator
// `ExecutionFailureStatus`), raised at `redeem_funds` when the object's settled
// balance is below the amount, the last failure on the `spend`/`withdraw` hot
// path. It is recognized by status in transaction effects / a dry run, not a
// matchable Move `#[error]` code.

/// Presented `OwnerCap` is bound to a different Vault. First check on every
/// owner-gated function.
#[error(code = 0)]
const EWrongOwnerCap: vector<u8> = "OwnerCap does not match this Vault";

/// Presented `SpenderCap` is bound to a different Vault. First check in `spend`
/// and `renounce`.
#[error(code = 1)]
const EWrongVault: vector<u8> = "SpenderCap does not match this Vault";

/// No `(cap, coin)` allowance entry: never granted, owner-revoked, or
/// spender-renounced. Remedy: a new grant. **Spend-only:**
/// `set_allowance` is an upsert and never aborts here. Distinct from
/// `EAllowanceExceeded` on a suspended entry (`remaining == 0`), whose remedy
/// is asking the owner to raise; `contains<T>` is the absent-vs-suspended
/// disambiguator, called as an on-chain public view.
#[error(code = 2)]
const ENoAllowance: vector<u8> = "No allowance entry for this cap";

/// Entry exists with finite expiry and `now >= expires_at_ms` (closed
/// boundary: a spend in the exact millisecond of expiry fails). The `u64::MAX`
/// sentinel never expires.
#[error(code = 3)]
const EAllowanceExpired: vector<u8> = "Allowance has expired";

/// `amount` exceeds the entry's `remaining`. Also fires on suspended entries
/// (`remaining == 0`) for any positive amount: the suspension-vs-revocation
/// discriminator.
#[error(code = 4)]
const EAllowanceExceeded: vector<u8> = "Amount exceeds remaining allowance";

/// Zero amount where zero is meaningless: `deposit`, `deposit_balance`,
/// `spend`, partial `withdraw`. `set_allowance` deliberately accepts 0
/// (suspension idiom); `withdraw_all`/`destroy`/`squash` permit zero-value
/// outcomes; `mint_cap` is bare (no amount).
#[error(code = 5)]
const EZeroAmount: vector<u8> = "Amount must be greater than zero";

/// Finite `new_expires_at_ms` was at or before `clock.timestamp_ms()` on
/// `set_allowance`. The `u64::MAX` sentinel is "no expiry" and always passes.
/// Corollary: a future expiry REVIVES an expired entry in place.
#[error(code = 6)]
const EExpiryInPast: vector<u8> = "Expiry must be in the future";

/// CAS guard failed on `set_allowance`: the entry is absent, or its current
/// `remaining` does not equal `expected`. A spend was sequenced between your
/// read and this write, or you CAS'd a `(cap, coin)` that does not exist;
/// re-read and retry.
#[error(code = 7)]
const EUnexpectedAllowance: vector<u8> = "Current allowance does not match expected";

// === Structs ===

/// Shared, UNTYPED escrow + per-`(cap, coin)` allowance ledger. One vault holds
/// N coin types at once; its lifecycle is exactly `new -> share` or
/// `new -> destroy`.
///
/// The pool is NOT a struct field: per-coin funds live as object-owned address
/// balances at `object::id_address(&v)`. The `key`-only ability protects `id`
/// (the `&mut v.id` spend authority) and the ledger, and forces every teardown
/// through `destroy`.
///
/// - `allowances`: a `LinkedTable` so `destroy`/`revoke_all`/
///   `renounce` can drain entries and recover each per-entry storage rebate;
///   the cost is O(n) drains and ~66 B of neighbour links per entry.
/// - `granted_coin_types`: the OWNER-WRITABLE enumeration handle that
///   `revoke_all`/`renounce` iterate on-chain. Written ONLY by
///   `set_allowance`-that-creates, so permissionless `deposit`/`squash` cannot
///   inflate it (un-griefable); complete because a `(cap, T)` entry can exist
///   only for a granted `T`. **GROWS-ONLY, never pruned:** `revoke<T>`
///   reclaims an entry's rebate but does NOT remove its `T` here, and a
///   phantom/typo'd `cap_id` on a new `T` adds that `T` permanently. So the O(k)
///   `revoke_all`/`renounce` loops are bounded by the distinct types the owner
///   has EVER granted on this vault (not the live entry count): keep that modest
///   and shard long-lived, many-type vaults. It is NOT the drain-before-destroy
///   list: that is off-chain `getAllBalances`, which also surfaces untracked
///   `send_funds` types and loose coins.
public struct Vault has key {
    id: UID,
    allowances: LinkedTable<BudgetKey, Allowance>,
    granted_coin_types: VecSet<TypeName>,
}

/// Composite ledger key: one entry per `(cap, coin type)`.
/// `coin_type` is always `type_name::with_defining_ids<T>()`.
public struct BudgetKey has copy, drop, store {
    cap_id: ID,
    coin_type: TypeName,
}

/// Owner authority for exactly one Vault. Exactly ONE OwnerCap exists per Vault
/// for its whole life: `new` mints it and `destroy` consumes it. `vault_id` is
/// set at `new` and never rewritten; transfer of the cap IS owner rotation. It
/// gates a wide blast radius: `withdraw<T>`/`withdraw_all<T>` over every coin and
/// `revoke_all` over every `(cap, coin)` entry.
public struct OwnerCap has key, store {
    id: UID,
    vault_id: ID,
}

/// Spend authority. **BEARER INSTRUMENT** (see the module-level warning):
/// whoever presents `&SpenderCap` to `spend<T>` holds the full spend authority
/// of every `(cap, coin)` budget it keys, so a leaked cap exposes the SUM of
/// its per-coin budgets.
///
/// UNTYPED: no phantom, no coin-type field. The coin dimension is supplied by
/// the `T` argument at the `spend<T>` call site and resolved against the ledger
/// key. `vault_id` is set at `mint_cap` and never rewritten; the binding
/// survives every transfer, wrap, or table embedding. On-chain custodians
/// should validate it via `spender_cap_vault_id` before accepting a cap.
public struct SpenderCap has key, store {
    id: UID,
    vault_id: ID,
}

/// Private ledger entry for one `(cap, coin)` grant. Reachable only through this
/// module's functions on the owning Vault, and the single source of truth for
/// the grant's state (the cap carries no budget). The coin type lives in the
/// `BudgetKey`, not here, so a single cap has N independent `Allowance` values.
public struct Allowance has drop, store {
    /// `u64::MAX` is the UNLIMITED sentinel (never decremented); `0` is a
    /// live-but-suspended entry; anything else is the raw drawable budget.
    remaining: u64,
    /// `u64::MAX` is the NO-EXPIRY sentinel; any finite value must be strictly
    /// in the future at `set_allowance` time.
    expires_at_ms: u64,
}

// === Events ===
//
// One canonical event per state change; reads and `share` emit
// nothing. Events are UNTYPED (no phantom) and carry a runtime `coin_type:
// TypeName` on coin-specific events, none on coin-agnostic ones. Unspoofable:
// these structs are module-private, so only this module can construct and emit
// them. Each gets a `#[test_only]` constructor at the foot
// of the module.
//
// Actor-field naming: `by` is the actor (`ctx.sender()`) of an administrative or
// terminal action; `creator` / `depositor` / `caller` are role-specific synonyms
// for the same `ctx.sender()` at `new` / `deposit` / `spend`. `CapDeleted` carries
// no actor field (see its doc).

/// Emitted by `new`. `owner_cap_id` is the vault->cap discovery anchor:
/// indexers resolve current owner custody by following object-ownership changes
/// of this cap. `creator` is `ctx.sender()` at `new` and may differ from the
/// eventual owner.
public struct VaultCreated has copy, drop {
    vault_id: ID,
    owner_cap_id: ID,
    creator: address,
}

/// Emitted by `deposit` and `deposit_balance`. `depositor` is indexer
/// attribution only; depositing confers no rights.
public struct Deposited has copy, drop {
    vault_id: ID,
    coin_type: TypeName,
    amount: u64,
    depositor: address,
}

/// Emitted by `squash`. DISTINCT from `Deposited` so indexers can separate
/// recovered strays from real deposits. Can carry `amount: 0` (because `squash`
/// has no `EZeroAmount` guard), mirroring the zero-amount note on `Withdrawn`.
public struct Squashed has copy, drop {
    vault_id: ID,
    coin_type: TypeName,
    amount: u64,
    by: address,
}

/// Emitted by `mint_cap`. BARE: the cap carries no budget yet, so there is no
/// recipient / amount / expiry here: budget data rides on the subsequent
/// `AllowanceSet { was_created: true }`. `by` is `ctx.sender()`.
public struct SpenderCapMinted has copy, drop {
    vault_id: ID,
    cap_id: ID,
    by: address,
}

/// Emitted by `set_allowance`. `new_amount == 0` signals the suspension idiom
/// (entry and cap stay alive). `cas_was_provided` records whether the CAS guard
/// was engaged, so off-chain tooling can spot CAS-less read-derived updates;
/// `was_created` is `true` on the create branch, `false` on overwrite.
public struct AllowanceSet has copy, drop {
    vault_id: ID,
    cap_id: ID,
    coin_type: TypeName,
    new_amount: u64,
    new_expires_at_ms: u64,
    cas_was_provided: bool,
    was_created: bool,
    by: address,
}

/// Emitted on every successful `spend`, strictly AFTER `redeem_funds` succeeds
/// (so a decremented-then-reverted pool-short spend emits nothing).
/// `remaining` is the entry's RAW value after the call; for an unlimited grant
/// it stays `u64::MAX`. `caller` is `ctx.sender()`: attribution, never a gate,
/// in wrapper flows it is the wrapper's caller, not necessarily the cap holder.
public struct Spent has copy, drop {
    vault_id: ID,
    cap_id: ID,
    coin_type: TypeName,
    amount: u64,
    remaining: u64,
    caller: address,
}

/// Emitted by `revoke` on every non-aborting call (including the idempotent
/// no-op), and by `revoke_all` once per removed coin. For single-coin `revoke`,
/// `was_present == false` is the typo'd-cap_id signal: nothing was actually
/// removed. For `revoke_all`, a whole-cap miss emits NOTHING (event absence is
/// the signal), so it has no `was_present == false` record. Indexers must gate
/// state changes on `was_present == true`: this struct is one-event-per-call from
/// `revoke` but one-event-per-removal from `revoke_all`.
public struct Revoked has copy, drop {
    vault_id: ID,
    cap_id: ID,
    coin_type: TypeName,
    was_present: bool,
    by: address,
}

/// Emitted by `renounce` (spender self-revoke). Coin-agnostic TERMINAL event:
/// it removes every `(cap, *)` entry, so an indexer closes all of the cap's
/// open entries on it. It carries no coin list or count, so an indexer closing
/// the cap's open entries relies on previously indexed `AllowanceSet` (grant)
/// state, not data in this event. `by` is `ctx.sender()`.
public struct Renounced has copy, drop {
    vault_id: ID,
    cap_id: ID,
    by: address,
}

/// Emitted by both `withdraw` and `withdraw_all` with no source discriminant, so
/// an indexer cannot distinguish a partial `withdraw` from a full settled-pool
/// `withdraw_all` drain from this event alone. `amount` is the actual value
/// extracted, possibly 0 from `withdraw_all` on an empty pool.
public struct Withdrawn has copy, drop {
    vault_id: ID,
    coin_type: TypeName,
    amount: u64,
    by: address,
}

/// Emitted by `destroy`. Coin-agnostic TERMINAL event for every `(vault, *)`
/// entry; indexers close all open entries under `vault_id` on it. It carries no
/// coin list or count, so an indexer closing the vault's open entries relies on
/// previously indexed `AllowanceSet` (grant) state, not data in this event. No
/// `refunded` field: the owner drained each coin via `withdraw_all<T>`
/// beforehand (the vault holds N coin types, so there is no single refund to
/// report).
public struct VaultDestroyed has copy, drop {
    vault_id: ID,
    by: address,
}

/// Emitted by `delete_orphaned_cap`. Non-generic (a bare cap has no coin type in scope):
/// lets event-only indexers follow a cap deletion. Without it, deleting a cap
/// whose entries are still live would leave them looking like live authority.
/// Intentionally carries no actor field: `delete_orphaned_cap` is the lone
/// ctx-free disposal path (callable after the vault is gone), so there is no
/// `ctx.sender()` to record.
public struct CapDeleted has copy, drop {
    vault_id: ID,
    cap_id: ID,
}

// === Public Functions ===

// === Lifecycle ===

/// Create an UNTYPED, multi-coin Vault and its sole, vault-bound `OwnerCap`,
/// both returned BY VALUE.
///
/// One PTB composes the full setup atomically: `new -> deposit<T> (xN) ->
/// mint_cap -> set_allowance<T> (xM) -> share -> transfer(owner_cap)`. Creator and
/// owner can differ: transfer the cap anywhere. The Vault has no `drop`, so the
/// tx fails unless it is consumed by `share` or `destroy` in the same tx.
///
/// #### Parameters
/// - `ctx`: Transaction context.
///
/// #### Returns
/// - The new `Vault` (consume it with `share` or `destroy`) and its sole
///   `OwnerCap`, both by value.
public fun new(ctx: &mut TxContext): (Vault, OwnerCap) {
    let vault = Vault {
        id: object::new(ctx),
        allowances: linked_table::new<BudgetKey, Allowance>(ctx),
        granted_coin_types: vec_set::empty<TypeName>(),
    };
    let vault_id = object::id(&vault);

    let owner_cap = OwnerCap {
        id: object::new(ctx),
        vault_id,
    };

    event::emit(VaultCreated {
        vault_id,
        owner_cap_id: object::id(&owner_cap),
        creator: ctx.sender(),
    });

    (vault, owner_cap)
}

/// Share the Vault.
///
/// Must run in the same tx as `new`; there is no deferred-share path. After
/// `share`, the Vault is addressable as a shared input only in subsequent
/// transactions, so all same-PTB fund / grant / embed steps must precede it. No
/// event: sharing is platform-visible.
public fun share(v: Vault) {
    transfer::share_object(v);
}

/// Terminal owner exit: tear the vault down and reclaim its storage rebates.
///
/// > **DANGER: DRAIN THE POOL FIRST, OR FUNDS ARE LOST FOREVER.** `destroy`
/// > deletes the vault and the owner cap and drains the budget ledger, but it
/// > does NOT drain the pool. Any coin still held in the vault's address
/// > balances strands permanently at the dead vault address: with the UID gone,
/// > no cap and no transaction can ever reach it again. The vault cannot drain
/// > itself (Move cannot iterate runtime coin types to dispatch
/// > `withdraw_all<T>` per type), and NO on-chain guard can stop a premature
/// > `destroy` (you cannot enumerate the pool's coin types on-chain), so the
/// > safe teardown is owner discipline:
/// >
/// > // 1. list EVERY coin type at the vault address (off-chain, complete):
/// > //      suix_getAllBalances(vault_address)
/// > // 2. fold in any loose Coins (shown as totalBalance > fundsInAddressBalance):
/// > //      squash<T>(&mut vault, receiving, ctx)
/// > // 3. drain every listed type, one call each:
/// > //      let bal = withdraw_all<T>(&mut vault, &owner_cap, &root, ctx)
/// > // 4. WAIT one checkpoint, then re-run getAllBalances; if non-empty, GOTO 2
/// > //    (a same-checkpoint deposit is invisible to step 3's settled read, so
/// > //     you cannot catch it by draining harder in one checkpoint)
/// > // 5. ONLY when getAllBalances reads empty across a settled checkpoint:
/// > //      destroy(vault, owner_cap, ctx)
/// >
/// > Drain in a PRIOR transaction, never the same PTB as `destroy`: a same-tx
/// > `send_funds` credit settles AFTER the drain read and strands.
/// > Residual: a permissionless deposit landing between step 4's check and step 5
/// > strands, so time `destroy` when no deposits are expected. To merely stop a
/// > spender or freeze the vault, use `revoke_all` then `withdraw_all` (separate
/// > txs), which do NOT delete the vault.
///
/// Mechanics: consumes the Vault and OwnerCap by value, `pop_front`-drains
/// EVERY ledger entry (recovering each per-entry storage rebate), deletes
/// both UIDs, and returns NOTHING (it cannot return N heterogeneous per-coin
/// balances). The drain is O(n) in live entries; for a very large ledger,
/// batch-`revoke` first to spread gas across txs. Teardown is never blockable
/// by spender state. `VaultDestroyed` is the terminal event for every entry
/// under this vault_id.
///
/// #### Parameters
/// - `v`: The vault to tear down.
/// - `cap`: The OwnerCap bound to `v`.
/// - `ctx`: Transaction context.
///
/// #### Aborts
/// - `EWrongOwnerCap` if cap is bound to a different Vault.
public fun destroy(v: Vault, cap: OwnerCap, ctx: &mut TxContext) {
    assert!(cap.vault_id == object::id(&v), EWrongOwnerCap);

    // `granted_coin_types` is deliberately dropped, not drained: the ledger drain
    // below works off the `allowances` table, not the type set.
    let Vault { id: vault_uid, mut allowances, granted_coin_types: _ } = v;
    let vault_id = vault_uid.to_inner();

    // Full drain. `destroy_empty` is the backstop; the loop makes a non-empty
    // table unreachable there. Each pop drops a (BudgetKey, Allowance) and
    // recovers the entry's storage rebate.
    while (!allowances.is_empty()) {
        let (_key, _entry) = allowances.pop_front();
    };
    allowances.destroy_empty();

    let OwnerCap { id: owner_cap_uid, vault_id: _ } = cap;
    vault_uid.delete();
    owner_cap_uid.delete();

    event::emit(VaultDestroyed { vault_id, by: ctx.sender() });
}

// === Fund (permissionless, confers no rights) ===

// NOTE (direct address-balance funding is a valid alternative). Because the pool
// IS the vault's object-owned address balance, anyone can fund it WITHOUT this module by
// calling `sui::balance::send_funds(bal, object::id_address(v))` directly (a
// `Coin<T>` via `c.into_balance()` first). Such funds are spendable by `spend` and
// withdrawable by the owner identically to a `deposit` (the accumulator is the
// single source of truth). The ONLY difference: a raw `send_funds` emits no
// typed `Deposited` event, so an event-only indexer will not see it (the balance is
// still visible on-chain via `getBalance`/`getAllBalances`). Use `deposit` /
// `deposit_balance` when the typed event matters; a raw `send_funds` is a lighter
// permissionless top-up.

/// Add a `Coin<T>` to the vault's per-coin pool: a thin `Coin<T>` wrapper over
/// `deposit_balance`. PERMISSIONLESS: anyone may deposit, and depositing confers
/// NO rights (no entry, no claim, no refund path); the funds become the owner's
/// pool. Only fund a vault whose owner you trust.
///
/// CAVEAT: because deposits are permissionless and allowances are ceilings on
/// the pool, a deposit by anyone (including a spender) re-arms live allowances
/// after a `withdraw_all`-as-freeze. The durable kill-all is `revoke_all` or
/// `destroy`, not draining the pool.
///
/// #### Parameters
/// - `v`: The vault whose pool receives the funds.
/// - `c`: The `Coin<T>` to deposit.
/// - `ctx`: Transaction context.
///
/// #### Aborts
/// - `EZeroAmount` if `c.value() == 0`.
public fun deposit<T>(v: &Vault, c: Coin<T>, ctx: &mut TxContext) {
    v.deposit_balance(c.into_balance(), ctx);
}

/// `Balance<T>`-native deposit: the symmetric ingress to the `Balance<T>`
/// egress of `spend`/`withdraw`/`withdraw_all`. The natural sink for a
/// `spend` output routed back into escrow, or for funding from any address
/// balance the caller controls (`redeem_funds(...)` then `deposit_balance`).
/// Same permissionless, rights-free, `&Vault` semantics as `deposit`.
///
/// #### Parameters
/// - `v`: The vault whose pool receives the funds.
/// - `b`: The `Balance<T>` to deposit.
/// - `ctx`: Transaction context.
///
/// #### Aborts
/// - `EZeroAmount` if `b.value() == 0`.
public fun deposit_balance<T>(v: &Vault, b: Balance<T>, ctx: &mut TxContext) {
    let amount = b.value();
    assert!(amount > 0, EZeroAmount);

    b.send_funds(object::id_address(v));

    event::emit(Deposited {
        vault_id: object::id(v),
        coin_type: type_name::with_defining_ids<T>(),
        amount,
        depositor: ctx.sender(),
    });
}

// === Cap + budgets (two owner verbs: mint_cap, set_allowance) ===

/// Mint a BARE, untyped `SpenderCap` and return it BY VALUE: no
/// budget, no ledger entry, no coin type yet. The caller decides the
/// cap's destination in the same PTB: `public_transfer` it to a delegate, or
/// embed it by value in a wrapper object / protocol record. Per-coin budgets
/// are added separately via `set_allowance<T>`.
///
/// Takes `&Vault` (it creates no ledger entry). The cap's `vault_id` binds it
/// to this vault for life and is never rewritten.
///
/// #### Parameters
/// - `v`: The vault the minted cap is bound to.
/// - `cap`: The OwnerCap bound to `v`.
/// - `ctx`: Transaction context.
///
/// #### Returns
/// - A new, budgetless `SpenderCap` bound to `v`, by value.
///
/// #### Aborts
/// - `EWrongOwnerCap` if cap is bound to a different Vault.
public fun mint_cap(v: &Vault, cap: &OwnerCap, ctx: &mut TxContext): SpenderCap {
    assert!(cap.vault_id == object::id(v), EWrongOwnerCap);

    let spender_cap = SpenderCap {
        id: object::new(ctx),
        vault_id: object::id(v),
    };
    let cap_id = object::id(&spender_cap);

    event::emit(SpenderCapMinted {
        vault_id: object::id(v),
        cap_id,
        by: ctx.sender(),
    });

    spender_cap
}

/// UPSERT the `(cap_id, T)` budget: create it if absent, else
/// overwrite `remaining` and `expires_at_ms` IN PLACE. The primary
/// create-or-change path; one cap accrues N independent per-coin budgets via N
/// `set_allowance<T>` calls.
///
/// Takes `cap_id: ID`, not `&SpenderCap`: the owner manages budgets without
/// holding the cap. The cap object, its ID, and every downstream embedding are
/// untouched by any change here, so a cap embedded in a protocol table
/// survives unlimited owner updates and re-granting is never required.
///
/// **`cap_id` is the SPENDER cap's object id** (`object::id(&spender_cap)`, the
/// id `mint_cap` minted), NOT the OwnerCap's id. It is UNVALIDATED by design
/// (kept a bare ID) and the owner gate only checks the OwnerCap, so a
/// mistyped or wrongly-copied `cap_id` silently targets a different budget. The
/// CREATE branch gives NO error signal: a wrong `cap_id` provisions a
/// fresh budget with `was_created == true`, shaped exactly like success (and adds
/// its `T` to the never-pruned `granted_coin_types`). Confirm before
/// granting: preflight `contains<T>(cap_id)` / `granted_coin_types()`, read
/// `AllowanceSet.was_created` to tell create from update, and derive `cap_id`
/// from a held `&SpenderCap` off-chain rather than copying a literal id.
///
/// - **Create vs overwrite.** Absent: create, recording `T` in
///   `granted_coin_types` (the owner-only revoke-iteration handle).
///   Present: overwrite. Re-setting a key OVERWRITES, it never adds. Two summing
///   budgets for one person require two caps.
/// - **Suspension.** `new_amount == 0` zeroes the budget but keeps the
///   entry and cap alive; the next `spend<T>` aborts `EAllowanceExceeded`. There
///   is deliberately no `EZeroAmount` here.
/// - **Revival.** A future `new_expires_at_ms` revives an expired entry
///   in place. Suspending an already-expired entry necessarily restates a valid
///   future expiry (or `u64::MAX`), time-reviving it while zeroing the budget.
/// - **CAS.** `expected = Some(e)` proceeds only if the entry exists
///   AND its current `remaining == e`; on an absent entry or a mismatch it
///   aborts `EUnexpectedAllowance`. The race-free idiom is `allowance<T>()` then
///   `set_allowance<T>(..., Some(result), ...)` in one PTB (the shared Vault is
///   locked for the tx). `None` is the unconditional create-or-overwrite. CAS
///   compares the RAW `remaining` (0 for suspended and `u64::MAX` for unlimited
///   included). CAS guards `remaining` ONLY; the upsert always overwrites
///   `expires_at_ms` too. A read-then-CAS-write that means to change only the
///   budget MUST re-read and re-pass the current expiry (via `expiry<T>()`), or
///   it will silently overwrite it.
///
/// #### Parameters
/// - `v`: The vault whose ledger is updated.
/// - `cap`: The OwnerCap bound to `v`.
/// - `cap_id`: The SpenderCap object id whose `(cap_id, T)` budget is upserted.
/// - `new_amount`: New `remaining` budget; `0` suspends, `u64::MAX` is unlimited.
/// - `new_expires_at_ms`: New expiry in ms; `u64::MAX` is the no-expiry sentinel,
///   any finite value must be strictly in the future.
/// - `expected`: Optional CAS guard; `Some(e)` proceeds only if the entry exists
///   and its current `remaining == e`, `None` is unconditional.
/// - `clock`: The Sui `Clock`.
/// - `ctx`: Transaction context.
///
/// #### Aborts
/// - `EWrongOwnerCap` if cap is bound to a different Vault.
/// - `EExpiryInPast` if `new_expires_at_ms` is finite and `<= now`.
/// - `EUnexpectedAllowance` if CAS is provided and the entry is absent or its
///   current `remaining` differs.
public fun set_allowance<T>(
    v: &mut Vault,
    cap: &OwnerCap,
    cap_id: ID,
    new_amount: u64,
    new_expires_at_ms: u64,
    expected: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let vault_id = object::id(v);

    // Precedence: owner gate, then expiry validity, then CAS. No ENoAllowance
    // (upsert), no EZeroAmount (0 = suspend).
    assert!(cap.vault_id == vault_id, EWrongOwnerCap);
    assert!(
        new_expires_at_ms == std::u64::max_value!()
            || new_expires_at_ms > clock.timestamp_ms(),
        EExpiryInPast, // the u64::MAX no-expiry sentinel always passes
    );

    let coin_type = type_name::with_defining_ids<T>();
    let key = BudgetKey { cap_id, coin_type };

    // CAS: compare-without-consuming against the raw `remaining`. Under the
    // upsert, `Some(e)` on an ABSENT entry must abort (you cannot CAS-match a
    // value that does not exist); the `contains` short-circuits the `&&`.
    let cas_was_provided = expected.is_some();
    if (cas_was_provided) {
        let e = expected.destroy_some();
        assert!(
            v.allowances.contains(key) && v.allowances.borrow(key).remaining == e,
            EUnexpectedAllowance,
        );
    };

    // Upsert: overwrite in place if present (cap_id + embeddings untouched),
    // else create.
    let was_created = if (v.allowances.contains(key)) {
        let entry = v.allowances.borrow_mut(key);
        entry.remaining = new_amount;
        entry.expires_at_ms = new_expires_at_ms;
        false
    } else {
        v
            .allowances
            .push_back(
                key,
                Allowance { remaining: new_amount, expires_at_ms: new_expires_at_ms },
            );
        // `granted_coin_types` is written ONLY here (set_allowance-create,
        // owner-gated), so permissionless funding can never inflate the set the
        // revoke paths iterate. Guard the insert: `vec_set::insert` aborts on a
        // duplicate.
        if (!v.granted_coin_types.contains(&coin_type)) {
            v.granted_coin_types.insert(coin_type);
        };
        true
    };

    event::emit(AllowanceSet {
        vault_id,
        cap_id,
        coin_type,
        new_amount,
        new_expires_at_ms,
        cas_was_provided,
        was_created,
        by: ctx.sender(),
    });
}

// === Spend (cap-gated, never sender-gated; exact-amount-or-abort) ===

/// Draw exactly `amount` of coin `T` against the presented `&SpenderCap`.
/// CAP-GATED, never sender-gated: any transaction context (an EOA, a
/// protocol module borrowing an embedded cap, a sponsored tx) spends
/// identically. `ctx.sender()` feeds `Spent.caller` only.
///
/// **Runtime coin-type gate.** The `(cap, T)` budget is resolved by
/// `BudgetKey{cap_id, with_defining_ids<T>()}`. A cap budgeted only for another
/// coin aborts `ENoAllowance` for this `T`: cross-coin safety is a runtime
/// check, not a compile-time phantom type.
///
/// EXACT-AMOUNT-OR-ABORT: success extracts exactly `amount` from the pool and
/// decrements `remaining` by exactly `amount`, unless `remaining == u64::MAX`,
/// which is never decremented. On ANY abort, the pool and every entry
/// are bit-identical to pre-call: the five library checks precede the
/// first mutation, and a pool-short failure rolls back the pre-decrement via
/// Move's atomic revert.
///
/// Returns `Balance<T>` with no `drop`, so the caller MUST consume it: plumb it
/// onward in the same PTB (`into_coin`, `send_funds`, `deposit_balance`, a
/// downstream protocol call). Spend-to-zero leaves the entry in place; removal
/// is `revoke`/`revoke_all`/`renounce`/`destroy`.
///
/// **Ceiling, not guarantee + mixed error model.** An allowance is a
/// ceiling on the pool, not a reservation: a live, unexpired, within-budget
/// spend can still fail when the pool is short, and that failure is the Sui
/// execution status `InsufficientFundsForWithdraw` (a funds-accumulator
/// `ExecutionFailureStatus`), raised at `redeem_funds` when the object's settled
/// balance is below the amount, NOT one of this module's codes. It is not a
/// matchable Move `#[error]` code, so detect it with a dry run (it is surfaced
/// in transaction effects / the SDK) rather than by matching an abort code.
/// Integrator preflight must handle the framework conditions too. The status is
/// deterministic and dry-run-visible.
///
/// #### Parameters
/// - `v`: The vault to spend against.
/// - `cap`: The SpenderCap bound to `v` whose `(cap, T)` budget is charged.
/// - `amount`: Units of coin `T` to draw; must be positive.
/// - `clock`: The Sui `Clock`.
/// - `ctx`: Transaction context.
///
/// #### Returns
/// - A `Balance<T>` of exactly `amount`; the caller must consume it.
///
/// The library checks abort in the listed order (a deterministic integrator ABI).
///
/// #### Aborts
/// - `EWrongVault` if cap is bound to a different Vault.
/// - `ENoAllowance` if there is no `(cap, T)` entry (never granted, revoked, or
///   a different coin).
/// - `EAllowanceExpired` if expiry is finite and `now >= expires_at_ms`.
/// - `EZeroAmount` if `amount == 0`.
/// - `EAllowanceExceeded` if `remaining` is finite and `amount > remaining`;
///   includes suspended-at-zero.
/// - `EObjectFundsWithdrawNotEnabled` (execution status) if the
///   `enable_object_funds_withdraw` protocol feature is off. Propagated from
///   `withdraw_funds_from_object`, total (not per-amount) and not a matchable
///   Move `#[error]` code.
/// - `InsufficientFundsForWithdraw` (execution status) if the object's settled
///   balance is below `amount`. A funds-accumulator execution status raised at
///   `redeem_funds` (surfaced in effects / dry run / SDK), NOT a Move `#[error]`
///   code you can match with `expected_failure(abort_code = ...)`, and not one
///   of this module's codes.
public fun spend<T>(
    v: &mut Vault,
    cap: &SpenderCap,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Balance<T> {
    let vault_id = object::id(v);
    let cap_id = object::id(cap);

    // 1. Binding gate, before any ledger access.
    assert!(cap.vault_id == vault_id, EWrongVault);

    let coin_type = type_name::with_defining_ids<T>();
    let key = BudgetKey { cap_id, coin_type };

    // 2. Existence. Absent (never granted / revoked / a different coin) is
    //    deliberately distinct from suspended-at-zero (check 5). This is the
    //    runtime coin-type gate.
    assert!(v.allowances.contains(key), ENoAllowance);

    // Read phase: copy the two scalars; the immutable borrow ends here.
    let (remaining, expires_at_ms) = {
        let entry = v.allowances.borrow(key);
        (entry.remaining, entry.expires_at_ms)
    };

    // 3. Closed boundary: a spend in the exact millisecond of expiry fails. The
    //    no-expiry sentinel short-circuits by equality.
    assert!(
        expires_at_ms == std::u64::max_value!() || clock.timestamp_ms() < expires_at_ms,
        EAllowanceExpired,
    );

    // 4. No zero-value draws.
    assert!(amount > 0, EZeroAmount);

    // 5. Compare-before-decrement (no underflow path exists). The unlimited
    //    sentinel short-circuits by equality, no arithmetic.
    assert!(remaining == std::u64::max_value!() || amount <= remaining, EAllowanceExceeded);

    // === Commit (all five library checks passed; no library abort below) ===
    //
    // Order is load-bearing: decrement the budget, THEN draw from the
    // pool. The pool is deliberately NOT pre-checked against the root;
    // if it is short, `redeem_funds` fails with the `InsufficientFundsForWithdraw`
    // execution status (when the object's settled balance is below the amount)
    // and Move's atomic revert rolls the decrement back. No external call runs
    // between the decrement and the withdraw, so there is no observable window
    // where the budget shrank but no funds moved.

    // Exact decrement; the unlimited sentinel is never decremented.
    let remaining_after = if (remaining == std::u64::max_value!()) {
        remaining
    } else {
        remaining - amount
    };
    v.allowances.borrow_mut(key).remaining = remaining_after;

    // Draw exactly `amount` from the per-coin address balance via `&mut v.id`:
    // no signer, only this module's cap-gated `&mut UID`.
    // `withdraw_funds_from_object` asserts the `enable_object_funds_withdraw`
    // feature, then builds the Withdrawal; the fund movement and the pool-short
    // check both happen at `redeem_funds`.
    let w = balance::withdraw_funds_from_object<T>(&mut v.id, amount);
    let bal = balance::redeem_funds(w);

    // Emit AFTER redeem succeeds: a reverted pool-short spend emits
    // nothing.
    event::emit(Spent {
        vault_id,
        cap_id,
        coin_type,
        amount,
        remaining: remaining_after,
        caller: ctx.sender(),
    });

    bal
}

// === Revoke / renounce / cap disposal ===

/// Owner kill-switch for ONE coin: remove the `(cap_id, T)` entry. IDEMPOTENT
/// and ledger-state-independent: a present entry is removed, an absent one is
/// a no-op, and the return says which (`was_present == false` is the typo'd
/// cap_id / wrong-coin signal, never a success-shaped lie). No allowance state
/// (absent, suspended, expired, unlimited) can make it abort: the kill-switch
/// cannot be raced into failure.
///
/// Strictly per-coin: revoking `(cap, USDC)` leaves `(cap, SUI)` and
/// every other coin of the cap untouched. The coin type stays in
/// `granted_coin_types` (grows-only); a later `revoke_all`/`renounce` probe of
/// it is a harmless no-op.
///
/// NOT retroactive: a spend sequenced before the owner's tx still succeeds.
/// Pair `revoke`/`revoke_all` (durably kills authority) with `withdraw_all`
/// (sweeps funds, but reversible by permissionless deposit) for emergencies.
/// The cap OBJECT survives in its holder's wallet as inert non-authority;
/// dispose of it via `renounce` (live vault) or `delete_orphaned_cap`.
///
/// #### Parameters
/// - `v`: The vault whose ledger entry is removed.
/// - `cap`: The OwnerCap bound to `v`.
/// - `cap_id`: The SpenderCap object id whose `(cap_id, T)` entry is targeted.
/// - `ctx`: Transaction context.
///
/// #### Returns
/// - `true` if an entry was present and removed; `false` if there was none.
///
/// #### Aborts
/// - `EWrongOwnerCap` if cap is bound to a different Vault.
public fun revoke<T>(v: &mut Vault, cap: &OwnerCap, cap_id: ID, ctx: &mut TxContext): bool {
    // Owner gate: the ONLY check, so no state can race this into failure.
    assert!(cap.vault_id == object::id(v), EWrongOwnerCap);

    let coin_type = type_name::with_defining_ids<T>();
    let key = BudgetKey { cap_id, coin_type };

    let was_present = if (v.allowances.contains(key)) {
        // Allowance has `drop`; removal recovers the entry's storage rebate to
        // this tx's gas payer. `granted_coin_types` is grows-only and untouched.
        v.allowances.remove(key);
        true
    } else {
        false
    };

    // Emitted on EVERY non-aborting call, no-op included.
    event::emit(Revoked {
        vault_id: object::id(v),
        cap_id,
        coin_type,
        was_present,
        by: ctx.sender(),
    });

    was_present
}

/// Owner whole-cap kill: remove EVERY `(cap_id, T)` entry the cap holds, in one
/// call: the blast-radius answer for a leaked cap spanning N budgets.
/// Iterates the vault's `granted_coin_types` and emits one `Revoked` per removed
/// coin. A cap with no entries emits nothing and still succeeds; total on ledger
/// state, it cannot be raced into failure.
///
/// **Un-griefable.** It iterates `granted_coin_types`, written
/// ONLY by `set_allowance`-create (owner action), so permissionless
/// `deposit`/`squash` can never inflate the loop toward the gas ceiling.
/// Owner-bounded by construction. It never touches another cap's entries (it
/// only builds keys with this `cap_id`); a coin this cap never held is a
/// harmless no-op probe.
///
/// **`cap_id` is the SPENDER cap's id, UNVALIDATED:** a wrong id is a
/// silent whole no-op (no `Revoked` emitted), leaving the intended cap LIVE.
/// During an incident, confirm the kill landed via the emitted `Revoked` events
/// (one per removed coin) or a `contains<T>` recheck.
///
/// NOT retroactive (see `revoke`). For an emergency stop, `revoke_all` is the
/// PRIMARY action: run it FIRST in its own tx (it never touches the pool, so it
/// cannot be raced into failure), THEN `withdraw_all<T>` per coin in a later tx
/// (retry-safe). Do NOT bundle them in one PTB: a same-checkpoint pool-short in
/// `withdraw_all` would revert the `revoke_all` with it (the settled-vs-live skew).
///
/// #### Parameters
/// - `v`: The vault whose ledger entries are removed.
/// - `cap`: The OwnerCap bound to `v`.
/// - `cap_id`: The SpenderCap object id whose entries are all removed.
/// - `ctx`: Transaction context.
///
/// #### Aborts
/// - `EWrongOwnerCap` if cap is bound to a different Vault.
public fun revoke_all(v: &mut Vault, cap: &OwnerCap, cap_id: ID, ctx: &mut TxContext) {
    assert!(cap.vault_id == object::id(v), EWrongOwnerCap);

    let vault_id = object::id(v);
    let by = ctx.sender();

    // Snapshot the owner-written type set (a copy) so the loop can mutate the
    // ledger with no outstanding immutable borrow of the vault. O(k) in the
    // owner-granted distinct coin types (owner-bounded, un-griefable).
    let types = *v.granted_coin_types.keys();
    let n = types.length();
    let mut i = 0;
    while (i < n) {
        let coin_type = *types.borrow(i);
        let key = BudgetKey { cap_id, coin_type };
        if (v.allowances.contains(key)) {
            v.allowances.remove(key);
            event::emit(Revoked { vault_id, cap_id, coin_type, was_present: true, by });
        };
        i = i + 1;
    };
}

/// Spender self-revoke against a LIVE vault, whole-cap. Consumes the cap by
/// value, removes EVERY `(cap_id, T)` entry it holds, deletes the cap object:
/// the only path that removes both sides atomically. No inert authority-shaped
/// garbage survives, and each entry's storage rebate routes to this tx's gas
/// payer.
///
/// Total on ledger state: a cap whose entries were already revoked
/// still renounces successfully (absent coins are harmless probes); the cap is
/// always deleted. Un-griefable: it iterates the owner-bounded
/// `granted_coin_types`. Emits one coin-agnostic `Renounced` (the terminal
/// event closes every `(cap, *)` from an indexer's view).
///
/// If the vault is already destroyed this is uncallable (no `&mut Vault`
/// exists); use `delete_orphaned_cap` for orphaned caps.
///
/// #### Parameters
/// - `v`: The live vault whose entries for this cap are removed.
/// - `cap`: The SpenderCap to renounce, bound to `v`.
/// - `ctx`: Transaction context.
///
/// #### Aborts
/// - `EWrongVault` if cap is bound to a different Vault.
public fun renounce(v: &mut Vault, cap: SpenderCap, ctx: &mut TxContext) {
    let vault_id = object::id(v);
    assert!(cap.vault_id == vault_id, EWrongVault);

    let SpenderCap { id, vault_id: _ } = cap;
    let cap_id = id.to_inner();

    // Remove every (cap, T) entry the cap holds. Snapshot the type set (copy)
    // so the loop can mutate the ledger; absent coins are harmless no-op probes.
    let types = *v.granted_coin_types.keys();
    let n = types.length();
    let mut i = 0;
    while (i < n) {
        let key = BudgetKey { cap_id, coin_type: *types.borrow(i) };
        if (v.allowances.contains(key)) {
            v.allowances.remove(key);
        };
        i = i + 1;
    };

    id.delete();

    event::emit(Renounced { vault_id, cap_id, by: ctx.sender() });
}

/// Dispose of an ORPHANED cap, one whose vault was already `destroy`ed.
/// `renounce` is the live-vault path (it needs `&mut Vault`, gone after
/// teardown); this is its vault-less counterpart. Total: never aborts, touches
/// no vault state, deletes exactly the cap's UID, and emits
/// `CapDeleted { vault_id, cap_id }` so event-only indexers can follow it.
///
/// **On a LIVE vault, prefer `renounce`.** Deleting a live cap STRANDS ALL of
/// its `(cap, T)` entries at once (one cap spans N coins). Each becomes inert
/// (the cap is gone, so it is unspendable, NOT live authority) but lingers in
/// the ledger, still visible via `contains<T>`, and you forfeit the storage
/// rebates `renounce` would have recovered.
///
/// **Owner cleanup of a stranded cap:** take the `cap_id` from the `CapDeleted`
/// event (or your issuance records) and call
/// `revoke_all(&mut vault, &owner_cap, cap_id, ctx)` to remove the entries and
/// reclaim their rebate. Optional, though: the entries are inert, and `destroy`
/// drains the whole ledger regardless.
///
/// #### Parameters
/// - `cap`: The orphaned SpenderCap to delete.
public fun delete_orphaned_cap(cap: SpenderCap) {
    let SpenderCap { id, vault_id } = cap;
    let cap_id = id.to_inner();
    id.delete();

    event::emit(CapDeleted { vault_id, cap_id });
}

// === Recovery ===

/// Recover a stray `Coin<T>` that was `public_transfer`'d to the vault address
/// (it lands as a loose owned object, counted in the address's totals but NOT
/// in the spendable address balance) by folding it back into the per-coin pool.
/// PERMISSIONLESS and STRICTLY FUNDS-IN: it can only move value INTO
/// the pool, never out or elsewhere, so exposing it to the world has no griefing
/// or extraction vector (the worst a caller can do is donate). Writes no type
/// set; the squashed type is still enumerable for teardown via the
/// off-chain `getAllBalances`. Emits `Squashed` (distinct from `Deposited` so
/// indexers separate recovered strays).
///
/// Recovers only strays sent to THIS vault: a generic cross-address squash is
/// unbuildable (you cannot consume a coin you do not control). It needs
/// `&mut v.id` only for `public_receive`. It is the vault's only object-receive
/// path and is `Coin`-typed, so any non-`Coin` object sent to the vault address
/// cannot be recovered.
///
/// #### Parameters
/// - `v`: The vault whose pool receives the recovered stray.
/// - `c`: The `Receiving<Coin<T>>` ticket for the stray coin sent to `v`.
/// - `ctx`: Transaction context.
///
/// #### Aborts
/// - The framework `public_receive` can abort on an invalid or stale
///   `Receiving` ticket; this module itself never aborts on pool/ledger state.
public fun squash<T>(v: &mut Vault, c: Receiving<Coin<T>>, ctx: &mut TxContext) {
    let vault_id = object::id(v);

    let coin = transfer::public_receive(&mut v.id, c);
    let amount = coin.value();
    coin.into_balance().send_funds(vault_id.to_address());

    event::emit(Squashed {
        vault_id,
        coin_type: type_name::with_defining_ids<T>(),
        amount,
        by: ctx.sender(),
    });
}

// === Owner exit (consults only the cap binding + pool, never the ledger) ===

/// Withdraw exactly `amount` of coin `T` from the pool as
/// `Balance<T>`. May leave live allowances unbacked: intended (allowances are
/// ceilings; the next over-pool spend fails with the `InsufficientFundsForWithdraw`
/// execution status with a live budget).
///
/// Consults only the OwnerCap binding and the pool, never the ledger,
/// so no spender state can block it. Pool-short is the Sui execution status
/// `InsufficientFundsForWithdraw` (a funds-accumulator `ExecutionFailureStatus`),
/// raised at `redeem_funds` when the object's settled balance is below the
/// amount, consistent with `spend` (no root, no pre-check).
///
/// #### Parameters
/// - `v`: The vault whose pool is drawn down.
/// - `cap`: The OwnerCap bound to `v`.
/// - `amount`: Units of coin `T` to withdraw; must be positive.
/// - `ctx`: Transaction context.
///
/// #### Returns
/// - A `Balance<T>` of exactly `amount`; the caller must consume it.
///
/// #### Aborts
/// - `EWrongOwnerCap` if cap is bound to a different Vault.
/// - `EZeroAmount` if `amount == 0`.
/// - `EObjectFundsWithdrawNotEnabled` (execution status) if the
///   `enable_object_funds_withdraw` protocol feature is off.
/// - `InsufficientFundsForWithdraw` (execution status) if the object's settled
///   balance is below `amount`. A funds-accumulator execution status raised at
///   `redeem_funds` (surfaced in effects / dry run / SDK), NOT a Move `#[error]`
///   code you can match with `expected_failure(abort_code = ...)`, and not one
///   of this module's codes.
public fun withdraw<T>(
    v: &mut Vault,
    cap: &OwnerCap,
    amount: u64,
    ctx: &mut TxContext,
): Balance<T> {
    let vault_id = object::id(v);
    assert!(cap.vault_id == vault_id, EWrongOwnerCap);
    assert!(amount > 0, EZeroAmount);

    let w = balance::withdraw_funds_from_object<T>(&mut v.id, amount);
    let bal = balance::redeem_funds(w);

    event::emit(Withdrawn {
        vault_id,
        coin_type: type_name::with_defining_ids<T>(),
        amount,
        by: ctx.sender(),
    });

    bal
}

/// Drain the SETTLED `T` pool as a possibly-zero `Balance<T>`. It
/// reads `settled_funds_value<T>(root, vault_address)` (the START-OF-CHECKPOINT
/// snapshot) and withdraws exactly that. There is deliberately no
/// caller-supplied amount: a fixed amount would be a stale-amount DoS (a racing
/// spend or top-up between read and call would over-withdraw and abort, or
/// under-withdraw and strand). An empty settled pool returns a zero `Balance<T>`
/// (consume it via `destroy_zero` or a join) without touching the accumulator.
///
/// **The settled-vs-live skew: NOT abort-free against the pool.** The
/// settled read disagrees with `redeem_funds`'s LIVE check whenever the pool
/// moved earlier in the SAME consensus checkpoint (a prior `spend`/`withdraw` on
/// this vault, including an earlier command in the same PTB):
/// - over-ask -> abort: a prior same-checkpoint `spend` lowers the live pool below
///   the settled snapshot, so the withdraw fails with the `InsufficientFundsForWithdraw`
///   execution status (a funds-accumulator `ExecutionFailureStatus` at
///   `redeem_funds`, when the object's settled balance is below the amount) (e.g.
///   settled 1000, a prior `spend(600)`
///   leaves live 400, draining 1000 against 400 aborts; even `spend(1)` trips it);
/// - under-drain: a same-checkpoint `deposit` is not yet in the snapshot, so the
///   drain misses it.
/// Both are RETRY-SAFE: the next checkpoint settles and a retry succeeds. It still
/// NEVER aborts on spender/ledger state.
///
/// Call once per coin type in the drain-before-`destroy` ritual,
/// enumerating types off-chain via `getAllBalances`. Do NOT sequence it after a
/// `spend`/`withdraw` on this vault in the same PTB (deterministic abort).
///
/// CAVEAT: `withdraw_all`-as-freeze is REVERSIBLE: `deposit` is permissionless,
/// so anyone can re-arm live allowances by topping up the pool. The durable
/// kill-all is `revoke_all` or `destroy`. For an emergency stop, run `revoke_all`
/// FIRST in its own tx (pool-independent, cannot be raced), THEN `withdraw_all`
/// in a later tx; do NOT bundle them, or a front-run `spend(1)` reverts the whole
/// PTB and rolls back the `revoke_all` with it.
///
/// #### Parameters
/// - `v`: The vault whose settled `T` pool is drained.
/// - `cap`: The OwnerCap bound to `v`.
/// - `root`: The `AccumulatorRoot`.
/// - `ctx`: Transaction context.
///
/// #### Returns
/// - A possibly-zero `Balance<T>` holding the drained settled pool; the caller
///   must consume it.
///
/// #### Aborts
/// - `EWrongOwnerCap` if cap is bound to a different Vault.
/// - `EObjectFundsWithdrawNotEnabled` (execution status) if the
///   `enable_object_funds_withdraw` protocol feature is off; only reachable on a
///   non-empty settled pool (the empty-pool path returns `balance::zero` without
///   touching the primitive).
/// - `InsufficientFundsForWithdraw` (execution status) if the live pool fell
///   below the settled snapshot earlier in this checkpoint (the settled-vs-live
///   skew; retry-safe). A funds-accumulator execution status raised at
///   `redeem_funds` (surfaced in effects / dry run / SDK), NOT a Move `#[error]`
///   code you can match with `expected_failure(abort_code = ...)`, and not one
///   of this module's codes. Never aborts on spender/ledger state.
public fun withdraw_all<T>(
    v: &mut Vault,
    cap: &OwnerCap,
    root: &AccumulatorRoot,
    ctx: &mut TxContext,
): Balance<T> {
    let vault_id = object::id(v);
    assert!(cap.vault_id == vault_id, EWrongOwnerCap);

    // Drain-exact: read the SETTLED (start-of-checkpoint) pool (a self-tracked
    // counter would desync under permissionless top-ups) and
    // withdraw exactly it. The settled-vs-live skew: this settled value can over-ask
    // the LIVE balance if a prior same-checkpoint spend/withdraw lowered it, so redeem
    // may fail with the `InsufficientFundsForWithdraw` execution status (retry-safe next
    // checkpoint). The empty settled
    // case is a clean zero-balance no-op that never reaches the flagged primitive.
    let amount = balance::settled_funds_value<T>(root, vault_id.to_address());
    let bal = if (amount == 0) {
        balance::zero<T>()
    } else {
        let w = balance::withdraw_funds_from_object<T>(&mut v.id, amount);
        balance::redeem_funds(w)
    };

    event::emit(Withdrawn {
        vault_id,
        coin_type: type_name::with_defining_ids<T>(),
        amount,
        by: ctx.sender(),
    });

    bal
}

// === View helpers ===

// All reads are TOTAL: they never abort, for any input, in any vault state
// (absent `(cap, T)`, revoked, suspended, expired, empty pool, zero coin
// types). Absent entries return the documented defaults, not errors.
//
// All reads are ADVISORY: results are stale the moment a later tx mutates the
// vault or the pool (a permissionless `send_funds` top-up moves the pool between
// a read and a later act). Cross-tx check-then-act is unsound; within one PTB
// the shared Vault is locked for the whole tx, so read -> decide -> write is
// atomic (the CAS idiom on `set_allowance`). The pool-reading reads take the
// `AccumulatorRoot` and report the settled (start-of-checkpoint) balance.

/// Raw `remaining` for `(cap, T)`; `0` if absent. Ambiguous at 0: suspended and
/// absent both read 0, disambiguate with `contains`. `u64::MAX` is the
/// unlimited sentinel, not a volume.
public fun allowance<T>(v: &Vault, cap_id: ID): u64 {
    let key = budget_key<T>(cap_id);
    if (v.allowances.contains(key)) {
        v.allowances.borrow(key).remaining
    } else {
        0
    }
}

/// What a `spend<T>` through this entry could draw RIGHT NOW: `0` if absent,
/// expired, or suspended (`remaining == 0`), else `min(remaining, settled_pool)`;
/// for an unlimited entry this
/// reduces to the settled pool. ADVISORY UPPER BOUND, not a guarantee: the pool
/// term is the SETTLED (start-of-checkpoint) value, so
/// `spend<T>(spendable_now<T>(...))` can still fail with the
/// `InsufficientFundsForWithdraw` execution status if a
/// prior same-checkpoint op reduced the LIVE pool below this quote (the
/// settled-vs-live skew). Time and budget do hold (no intervening mutation); treat
/// the pool as a ceiling and handle the abort, or avoid same-checkpoint contention.
/// Guard `> 0` before feeding it to `spend`: a zero quote aborts `EZeroAmount`.
/// Flag-independent: this read does not check `enable_object_funds_withdraw`, so on
/// a network where that feature is off it still returns a non-zero quote that
/// cannot actually be spent or withdrawn.
///
/// #### Parameters
/// - `v`: The vault to inspect.
/// - `root`: The `AccumulatorRoot`.
/// - `cap_id`: The SpenderCap object id whose `(cap_id, T)` entry is quoted.
/// - `clock`: The Sui `Clock`.
///
/// #### Returns
/// - The advisory upper bound on a current `spend<T>`; `0` when absent, expired,
///   or suspended (`remaining == 0`).
public fun spendable_now<T>(v: &Vault, root: &AccumulatorRoot, cap_id: ID, clock: &Clock): u64 {
    let key = budget_key<T>(cap_id);
    if (!v.allowances.contains(key)) {
        return 0
    };
    let entry = v.allowances.borrow(key);
    // Same closed boundary as `spend` check 3.
    if (
        entry.expires_at_ms != std::u64::max_value!()
        && clock.timestamp_ms() >= entry.expires_at_ms
    ) {
        return 0
    };
    // The u64::MAX sentinel is min's neutral element: unlimited reduces to the
    // settled pool with no special case.
    entry.remaining.min(balance::settled_funds_value<T>(root, object::id_address(v)))
}

/// Raw `expires_at_ms` for `(cap, T)`; `0` if absent. A present entry's value is
/// a future timestamp or the `u64::MAX` no-expiry sentinel, never `0`, so use
/// `contains` to distinguish absent from present.
public fun expiry<T>(v: &Vault, cap_id: ID): u64 {
    let key = budget_key<T>(cap_id);
    if (v.allowances.contains(key)) {
        v.allowances.borrow(key).expires_at_ms
    } else {
        0
    }
}

/// Ledger membership for `(cap, T)`: the absent-vs-suspended disambiguator.
/// `allowance == 0 && contains` is a suspended (or drained) entry whose cap is
/// still valid; `!contains` is never-granted / revoked / renounced.
public fun contains<T>(v: &Vault, cap_id: ID): bool {
    v.allowances.contains(budget_key<T>(cap_id))
}

/// The settled `T` pool at the vault's address (the START-OF-CHECKPOINT snapshot;
/// advisory). Named for the balance it reports, though the funds live as an address
/// balance rather than a struct field. NOTE: deriving a `withdraw(amount)` from
/// this read can still fail with the `InsufficientFundsForWithdraw` execution
/// status if the live pool dropped since the read (the settled-vs-live skew). It is
/// also flag-independent: a non-zero result on a network with
/// `enable_object_funds_withdraw` off still cannot be spent or withdrawn.
public fun balance_value<T>(v: &Vault, root: &AccumulatorRoot): u64 {
    balance::settled_funds_value<T>(root, object::id_address(v))
}

/// The coin types the OWNER has granted: exactly what `revoke_all`/`renounce`
/// iterate (SDK / indexer aid). GROWS-ONLY and never pruned: includes
/// every type ever granted, even ones whose entries were all revoked. NOTE: this
/// is NOT the drain-before-`destroy` list: that is off-chain
/// `getAllBalances(vault_address)`, which also surfaces untracked `send_funds`
/// types and loose coins.
public fun granted_coin_types(v: &Vault): vector<TypeName> {
    *v.granted_coin_types.keys()
}

/// The Vault this OwnerCap is bound to: on-chain custodians validate the binding
/// before accepting a cap.
public fun owner_cap_vault_id(cap: &OwnerCap): ID {
    cap.vault_id
}

/// The Vault this SpenderCap is bound to: protocols accepting a user's cap MUST
/// check this against the expected vault before custody (see the module-level
/// bearer-cap warning).
public fun spender_cap_vault_id(cap: &SpenderCap): ID {
    cap.vault_id
}

// === Private Functions ===

/// Build the composite ledger key for `(cap_id, T)`. The canonical
/// `with_defining_ids<T>()` (never the deprecated `get`) keeps keys stable
/// across grant and spend. Used by the read paths; the mutating
/// paths build the key inline because they also emit `coin_type` in their event.
fun budget_key<T>(cap_id: ID): BudgetKey {
    BudgetKey { cap_id, coin_type: type_name::with_defining_ids<T>() }
}

// === Test-Only Helpers ===

// Event-value constructors for test-side equality assertions (the events are
// otherwise module-private and unconstructable). One per event, matching the
// untyped + runtime `coin_type` schema.

#[test_only]
public fun test_new_vault_created(vault_id: ID, owner_cap_id: ID, creator: address): VaultCreated {
    VaultCreated { vault_id, owner_cap_id, creator }
}

#[test_only]
public fun test_new_deposited(
    vault_id: ID,
    coin_type: TypeName,
    amount: u64,
    depositor: address,
): Deposited {
    Deposited { vault_id, coin_type, amount, depositor }
}

#[test_only]
public fun test_new_squashed(
    vault_id: ID,
    coin_type: TypeName,
    amount: u64,
    by: address,
): Squashed {
    Squashed { vault_id, coin_type, amount, by }
}

#[test_only]
public fun test_new_spender_cap_minted(vault_id: ID, cap_id: ID, by: address): SpenderCapMinted {
    SpenderCapMinted { vault_id, cap_id, by }
}

#[test_only]
public fun test_new_allowance_set(
    vault_id: ID,
    cap_id: ID,
    coin_type: TypeName,
    new_amount: u64,
    new_expires_at_ms: u64,
    cas_was_provided: bool,
    was_created: bool,
    by: address,
): AllowanceSet {
    AllowanceSet {
        vault_id,
        cap_id,
        coin_type,
        new_amount,
        new_expires_at_ms,
        cas_was_provided,
        was_created,
        by,
    }
}

#[test_only]
public fun test_new_spent(
    vault_id: ID,
    cap_id: ID,
    coin_type: TypeName,
    amount: u64,
    remaining: u64,
    caller: address,
): Spent {
    Spent { vault_id, cap_id, coin_type, amount, remaining, caller }
}

#[test_only]
public fun test_new_revoked(
    vault_id: ID,
    cap_id: ID,
    coin_type: TypeName,
    was_present: bool,
    by: address,
): Revoked {
    Revoked { vault_id, cap_id, coin_type, was_present, by }
}

#[test_only]
public fun test_new_renounced(vault_id: ID, cap_id: ID, by: address): Renounced {
    Renounced { vault_id, cap_id, by }
}

#[test_only]
public fun test_new_withdrawn(
    vault_id: ID,
    coin_type: TypeName,
    amount: u64,
    by: address,
): Withdrawn {
    Withdrawn { vault_id, coin_type, amount, by }
}

#[test_only]
public fun test_new_vault_destroyed(vault_id: ID, by: address): VaultDestroyed {
    VaultDestroyed { vault_id, by }
}

#[test_only]
public fun test_new_cap_deleted(vault_id: ID, cap_id: ID): CapDeleted {
    CapDeleted { vault_id, cap_id }
}

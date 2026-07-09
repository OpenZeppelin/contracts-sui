# `openzeppelin_allowance`

Capability-keyed, multi-coin spending allowances for Sui: an owner funds a shared vault and grants bounded, optionally expiring, revocable spend authority that delegates draw on demand, without giving up custody and without signing each spend.

The `openzeppelin_allowance` package lets a treasury, protocol, or wallet delegate "you may spend up to X of coin T" to another party (an address, a keeper service, an embedded protocol record) while keeping the funds, the ability to raise or lower the budget at any time, and a one-call kill switch.

> [!WARNING]
> A `SpenderCap` is a **bearer instrument**: whoever can present it to `spend` exercises the full authority of every budget it keys, up to each budget's limit. The library never checks who holds or presents a cap. Any protocol that custodies a cap MUST sender-gate the function that borrows it, and MUST validate the cap's vault binding before accepting it. See [Security Notes](#security-notes).

## Module Snapshot

| Module | Summary |
|--------|---------|
| `spend_vault` | A shared, untyped vault that escrows many coin types and grants per-`(cap, coin)` spend budgets to capability holders. |

---

## Spend Vault

One shared `Vault` holds N coin types at once. Funds are not a struct field: each coin lives as an object-owned address balance at the vault's own address. Authority is split across two transferable capabilities, and every budget lives in a ledger keyed by `(cap_id, coin_type)`, never in the cap itself.

| Object | Role |
|--------|------|
| `Vault` (shared) | The escrow and the per-`(cap, coin)` budget ledger. Created and shared once. |
| `OwnerCap` (owned, transferable) | Full control: mint spender caps, set / raise / lower / suspend / revoke budgets, withdraw funds, destroy the vault. Exactly one per vault; transferring it is owner rotation. |
| `SpenderCap` (owned, bearer) | Spend authority. Carries no budget; the owner grants per-coin budgets against its id. Whoever holds it can spend every budget it keys. |
| `Balance<T>` (returned) | `spend`, `withdraw`, and `withdraw_all` hand back a `Balance<T>` with no `drop`, so the caller must consume it in the same transaction. |
| `Clock` (`0x6`), `AccumulatorRoot` (`0xacc`) | Shared system objects that the time-checked and pool-reading calls take by reference. |

### When to use it

| Use it when |
| --- |
| A protocol or keeper should spend from a user's funds on their behalf, repeatedly, within a budget the user sets and can revoke, without the user signing each spend. |
| A treasury or DAO issues bounded, expiring, auditable spend grants to contributors or sub-agents and wants to raise, lower, or cut them at any time. |
| A wallet or app offers an "approve up to X" allowance UX over real custody rather than a per-transaction signature. |

### Lifecycle

1. **Create and fund** - `new` returns the `Vault` and its `OwnerCap` by value; `deposit<T>` (or a raw address-balance top-up) funds the pool; `share` makes the vault usable. Compose all of this in one PTB before `share`.
2. **Grant** - `mint_cap` returns a bare `SpenderCap`; `set_allowance<T>` creates or overwrites the `(cap, coin)` budget. `0` suspends (keeps the cap), `u64::MAX` means unlimited / no expiry, and an optional CAS guard makes read-then-write races safe.
3. **Spend** - the cap holder calls `spend<T>` for exactly `amount`, receiving a `Balance<T>` to route onward. Spending is cap-gated, never sender-gated.
4. **Manage** - the owner raises, lowers, or suspends a live grant in place with `set_allowance<T>` (the cap object is never invalidated), ends one coin with `revoke<T>`, or kills an entire cap with `revoke_all`. A spender can self-revoke with `renounce`.
5. **Exit and teardown** - the owner withdraws funds at any time with `withdraw<T>` / `withdraw_all<T>`, then `destroy`s the drained vault. Owner exit is never blocked by spender state.

### Usage

```move
use openzeppelin_allowance::spend_vault;
use sui::clock::Clock;
use sui::coin::Coin;

// Owner: create a vault, fund it, mint a cap for a delegate, grant a capped budget, then share.
public fun open<T>(
    funding: Coin<T>,
    delegate: address,
    budget: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (mut vault, owner_cap) = spend_vault::new(ctx);

    vault.deposit(funding, ctx); // permissionless top-up; confers no rights

    let cap = vault.mint_cap(&owner_cap, ctx); // bare cap, no budget yet
    let cap_id = object::id(&cap);
    transfer::public_transfer(cap, delegate);

    // Grant the (cap, T) budget. u64::MAX expiry = no expiry; option::none() = no CAS guard on create.
    vault.set_allowance<T>(
        &owner_cap, cap_id, budget, std::u64::max_value!(), option::none(), clock, ctx,
    );

    vault.share(); // every fund / mint / grant step must precede share
    transfer::public_transfer(owner_cap, ctx.sender());
}
```

```move
use openzeppelin_allowance::spend_vault::{Self, Vault, SpenderCap};
use sui::clock::Clock;
use sui::coin;

// Spender: draw `amount` of T against the held cap and take it as a wallet coin.
// `spend` returns a Balance<T> with no `drop`, so it must be consumed in the same PTB.
public fun draw<T>(
    vault: &mut Vault,
    cap: &SpenderCap,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let bal = vault.spend<T>(cap, amount, clock, ctx);
    transfer::public_transfer(coin::from_balance(bal, ctx), ctx.sender());
}
```

### Examples

> [!Warning]
> These are **unaudited illustrations** of how the primitive can be integrated, not production-ready code.

Complete integration examples live in [`examples/spend_vault/`](examples/spend_vault):

- [`direct_delegation`](examples/spend_vault/direct_delegation.move) - an owner funds a vault and delegates a capped, optionally expiring budget straight to a known address; the delegate spends directly and the owner manages and tears down the grant. The library API is the whole integration, no wrapper needed.
- [`defi_keeper`](examples/spend_vault/defi_keeper.move) - a protocol custodies a user's `SpenderCap` and spends on the user's behalf within the owner's budget. Shows the two custody rules every cap-holding protocol must follow: validate the cap's vault binding before accepting it, and sender-gate the cap-borrowing entrypoint, because a bearer cap is otherwise world-drainable.

## Security Notes

- **Bearer model.** A `SpenderCap` confers authority by possession; the library never inspects who holds or presents it. A protocol that custodies a cap MUST sender-gate the function that borrows it (an ungated public borrow is world-drainable), and MUST validate `spender_cap_vault_id` against the intended vault before accepting a cap.
- **Budgets are ceilings, not reservations.** Allowances may sum to more than the pool by design. A live, unexpired, within-budget `spend` can still fail when the pool is short; competing spenders are resolved by consensus sequencing (first sequenced, first served). The pool-short failure is the Sui execution status `InsufficientFundsForWithdraw` (a funds-accumulator `ExecutionFailureStatus`), raised at `redeem_funds` when the object's live balance at execution is below the amount and surfaced via the SDK / a dry run, NOT one of this module's abort codes and NOT a matchable Move `#[error]` code, so integrator preflight must dry-run the withdraw path rather than match a code.
- **Sentinels.** `remaining == u64::MAX` means unlimited (never decremented) and `expires_at_ms == u64::MAX` means no expiry. Off-chain tooling must exclude `u64::MAX` from volume math.
- **Owner exit is unconditional.** `withdraw`, `withdraw_all`, and `destroy` consult only the owner-cap binding and the pool, never the ledger, so no spender or ledger state can block defunding or teardown.
- **Drain before destroy.** `destroy` deletes the vault and its budget ledger but does NOT drain the pool. Withdraw every coin first (enumerate the vault address's coin types off-chain), or any remaining funds strand permanently at the dead vault address. Drain in a transaction prior to `destroy`, never the same PTB.
- **Emergency stop.** Funds withdrawal is reversible (deposits are permissionless, so anyone can re-arm a live allowance by topping up the pool). The durable kill is `revoke_all` (or `destroy`). For an emergency, run `revoke_all` first in its own transaction (it never touches the pool, so it cannot be raced into failure), then `withdraw_all` per coin in a later transaction. Do not bundle the two in one PTB.
- **Consume the returned balance.** `spend` / `withdraw` / `withdraw_all` return a `Balance<T>` with no `drop`. Route it in the same PTB (into a `Coin`, back into escrow, or a downstream call).

## Learn More

- [Allowance package overview](https://docs.openzeppelin.com/contracts-sui/1.x/allowance)
- [Allowance API reference](https://docs.openzeppelin.com/contracts-sui/1.x/api/allowance)
- [`llms.txt`](https://raw.githubusercontent.com/OpenZeppelin/contracts-sui/main/llms.txt): discovery entry point for AI integrators
- [OpenZeppelin Contracts for Sui](https://docs.openzeppelin.com/contracts-sui)

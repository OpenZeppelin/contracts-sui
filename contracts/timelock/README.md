# `openzeppelin_timelock`

A delayed-operation controller for Sui - a Sui-native take on OpenZeppelin's `TimelockController`. It enforces a minimum on-chain delay between *scheduling* a privileged operation and *executing* it, giving users a window to react before the change takes effect.

Operations carry typed parameters stored on-chain, and an integration binds to a specific timelock through a stored `OperationCap`, so the canonical-timelock check is enforced by the library rather than by hand-written asserts. Execution returns the typed params through a no-ability `ExecutionTicket<Action, Params>` hot potato that the consumer redeems in the same transaction. Roles come from a hard dependency on `openzeppelin_access`.

## Install

```toml
[dependencies]
openzeppelin_timelock = { r.mvr = "@openzeppelin-move/timelock" }
```

## Module Snapshot

| Module | Summary |
|--------|---------|
| `timelock` | Hash-keyed operation timelock: a shared `Timelock` with typed on-chain params, `OperationCap`-bound entries (structural canonical-timelock binding), typed `ExecutionTicket<Action, Params>` execution, predecessor-based operation chaining, optional permissionless (open-executor) execution, a configurable delay + expiry window, and self-administered configuration. |

---

## Timelock

There is no `target.call(data)` in Move, so rather than dispatching an arbitrary call the timelock stores the operation's typed params and, at execute time, hands them back through a one-shot ticket - the consumer dispatches to itself. An operation id is `keccak256(DOMAIN_TAG || bcs(IdInput { action, payload_digest, predecessor, salt, timelock_id }))`: deterministic, off-chain reproducible, and isolated per `Timelock` instance. The ready window is half-open `[ready_at_ms, expires_at_ms)` and both bounds are locked at schedule time, so later config changes never move an in-flight op; `Done` is sticky, so ops are non-replayable.

| Object | Role |
|--------|------|
| `Timelock` (shared) | The per-protocol registry: the per-op state machine plus each op's typed params (dynamic fields). Created and shared once. |
| `OperationCap<Action, Params>` (stored) | Binds one operation kind to one `Timelock`. Minted at `init` and stored in the object you protect; the `*_with` entries check it, so the canonical-timelock binding is structural. Carries no authority. |
| `ExecutionTicket<Action, Params>` (returned) | A no-ability hot potato carrying the typed params. `execute_with` mints it; the consumer must `consume` it in the same PTB. |
| `Auth<R>` (from `openzeppelin_access`) | Authorization. Every gated entry takes `&Auth<R>` and checks `R` against the role bound at creation (proposer / executor / canceller / admin). |
| `Clock` (`0x6`) | Time source, threaded through `schedule` and `execute`. |

### Lifecycle

1. **Deploy** - in `init`, create the `AccessControl` registry and a `Timelock` (`new` + `share`, so you can mint caps before sharing), mint one `OperationCap` per operation kind with `new_operation_cap`, and store the caps in the object you protect.
2. **Schedule** - a proposer calls your wrapper, which calls `schedule_with(&obj.cap, &auth, params, predecessor, salt, delay_ms, clock, ctx)` and returns the op id.
3. **Execute** - after the delay, an executor calls `execute_with(&obj.cap, &auth, id, clock, ctx)` for a ticket, `consume(ticket, Action {})` for `(op_id, params)`, then applies the typed params - all in the same PTB.
4. **Cancel** - `cancel_with(&obj.cap, &auth, id, ctx)` drops a Waiting / Ready / Expired op.
5. **Self-administer** - `min_delay_ms` / `grace_period_ms` / `open_executor` change only through the admin-gated `schedule_* / execute_*` pairs, each itself timelocked.

### Usage

```move
module my_protocol::amm;

use openzeppelin_access::access_control::{Self, Auth};
use openzeppelin_timelock::timelock::{Self, Timelock, OperationCap};
use sui::{clock::Clock, event};

public struct AMM has drop {}
public struct ProposerRole {}
public struct ExecutorRole {}
public struct CancellerRole {}
public struct TimelockAdminRole {}

public struct FeeChangeAction has drop {} // drop-only; construction never leaves this module

public struct Pool has key { id: UID, fee_bps: u16, fee_cap: OperationCap<FeeChangeAction, u16> }
public struct FeeChanged has copy, drop { op_id: vector<u8>, old: u16, new: u16 }

fun init(otw: AMM, ctx: &mut TxContext) {
    let mut ac = access_control::new(otw, 7 * 86_400_000, ctx);
    ac.set_role_admin<_, ProposerRole, AMM>(ctx);
    ac.set_role_admin<_, ExecutorRole, AMM>(ctx);
    ac.set_role_admin<_, CancellerRole, AMM>(ctx);
    ac.set_role_admin<_, TimelockAdminRole, AMM>(ctx);

    // `new` + `share` so we can mint the cap from the object before sharing it.
    let tl = timelock::new<ProposerRole, ExecutorRole, CancellerRole, TimelockAdminRole>(
        24 * 60 * 60 * 1_000,
        7 * 24 * 60 * 60 * 1_000,
        ctx,
    );
    let fee_cap = tl.new_operation_cap<FeeChangeAction, u16>();
    timelock::share(tl);
    transfer::share_object(Pool { id: object::new(ctx), fee_bps: 30, fee_cap });
    transfer::public_share_object(ac);
}

// Proposer schedules; the OperationCap binds this call to the canonical timelock.
public fun schedule_fee_change(
    tl: &mut Timelock,
    pool: &Pool,
    proposer: &Auth<ProposerRole>,
    new_fee_bps: u16,
    predecessor: vector<u8>,
    salt: vector<u8>,
    delay_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): vector<u8> {
    tl.schedule_with(&pool.fee_cap, proposer, new_fee_bps, predecessor, salt, delay_ms, clock, ctx)
}

// Executor cranks it after the delay; consume hands back the typed params; apply them.
public fun execute_fee_change(
    tl: &mut Timelock,
    pool: &mut Pool,
    executor: &Auth<ExecutorRole>,
    id: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let ticket = tl.execute_with(&pool.fee_cap, executor, id, clock, ctx);
    let (op_id, new_fee_bps) = tl.consume(ticket, FeeChangeAction {}); // MUST consume in this PTB
    let old = pool.fee_bps;
    pool.fee_bps = new_fee_bps;
    event::emit(FeeChanged { op_id, old, new: new_fee_bps });
}
```

### Examples

> [!Warning]
> These are **unaudited illustrations** of how the primitive can be integrated, not production-ready code.

Complete integration examples live in [`examples/timelock/`](examples/timelock):

- [`example_amm`](examples/timelock/example_amm.move) - a single `Timelock` gating an AMM fee change; the `OperationCap` lives on the `Pool`, so the canonical-timelock binding is structural and call sites carry zero type args. Also shows a self-administered `min_delay` change.
- [`example_dual_governance`](examples/timelock/example_dual_governance.move) - two timelocks for two risk profiles (a 24h main for routine fee changes, a 1h emergency for pause / unpause), each routed by its own `OperationCap`.
- [`example_upgrade_vault`](examples/timelock/example_upgrade_vault.move) - timelocking a package `UpgradeCap`: cranking a matured upgrade op consumes the timelock ticket and yields Sui's `UpgradeTicket`.

## Security Notes

- **Use the `OperationCap` path.** The `*_with` entries assert `object::id(timelock) == cap.timelock_id`, so storing the cap in the object you protect makes the canonical-timelock binding structural - an attacker cannot route a self-created, zero-delay timelock through your wrapper. The raw `&Auth` entries (`schedule` / `execute` / `cancel`) do **not** bind the id; if you use them you must `assert!(object::id(timelock) == expected)` yourself in every entry, and forgetting it silently disables the delay.
- **Witness discipline.** `Action` witnesses must be `drop`-only, one per `consume` function, and their construction must never leak across the package boundary (no public helper returning an `Action`) - otherwise a foreign module could redeem your tickets.
- **Consume the ticket in the same PTB.** `ExecutionTicket` has no abilities, so the transaction aborts unless `execute` / `execute_with` is followed by `consume`. This is what makes execute -> apply atomic.
- **A predecessor being `Done` is not the same as its effect being applied.** Within one PTB, run each `execute -> consume -> apply` triple to completion before the next dependent op; the library only guarantees the predecessor op is `Done`, not that its effect ran.
- **`min_delay_ms == 0` is permitted but unprotected** - no reaction window, and self-administered config changes are then instant.
- **`Action` and `Params` must match the scheduled op.** `execute` re-checks both against the operation it was scheduled with (the `Action` is bound at schedule and re-verified, since the id is taken directly): a wrong `Action` aborts with `EWrongAction` and a wrong `Params` with `EWrongParams`. On the cap path both are pinned by the `OperationCap`. A `delay_ms` so large that `now + delay_ms` would overflow aborts with `EScheduleOverflow` (never wraps).
- **Off-chain id reproduction.** Recompute an id as `keccak256(DOMAIN_TAG || bcs(IdInput { action, payload_digest, predecessor, salt, timelock_id }))` with `payload_digest = keccak256(bcs(params))`. The `action` is the BCS of a `TypeName` (the sharp edge for tooling) - cross-check against an on-chain `hash_operation<Action>` call before relying on predicted ids.

## Learn More

- [Timelock package overview](https://docs.openzeppelin.com/contracts-sui/1.x/timelock)
- [Timelock API reference](https://docs.openzeppelin.com/contracts-sui/1.x/api/timelock)
- [`llms.txt`](https://raw.githubusercontent.com/OpenZeppelin/contracts-sui/main/llms.txt): discovery entry point for AI integrators
- [OpenZeppelin Contracts for Sui](https://docs.openzeppelin.com/contracts-sui)

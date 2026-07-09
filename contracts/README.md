# Contracts

OpenZeppelin building blocks for Sui smart contracts development.

**AI agents:** [`llms.txt`](https://raw.githubusercontent.com/OpenZeppelin/contracts-sui/main/llms.txt) is the discovery entry point for integrating this library into a downstream project.

---

## Packages

| Package | MVR | Move package | Docs | Highlights |
|---------|----------|--------------|------|-----------|
| [`access/`](access/) | [`@openzeppelin-move/access`](https://www.moveregistry.com/package/@openzeppelin-move/access) | `openzeppelin_access` | [docs](https://docs.openzeppelin.com/contracts-sui/1.x/access) | Transfer policies that wrap privileged capabilities and guard ownership handoffs (two-step approvals and time-locked transfers). |
| [`allowance/`](allowance/) | - | `openzeppelin_allowance` | [docs](https://docs.openzeppelin.com/contracts-sui/1.x/allowance) | Capability-keyed, multi-coin spending allowances: an owner funds a shared vault and grants bounded, optionally expiring, revocable spend budgets that cap holders draw on demand, without the owner giving up custody or signing each spend. See [`allowance/examples/spend_vault/`](allowance/examples/spend_vault) for integration examples. |
| [`finance/`](finance/) | - | `openzeppelin_finance` | [docs](https://docs.openzeppelin.com/contracts-sui/1.x/finance) | Vesting wallet that locks a coin for a beneficiary and releases it on a schedule, with a built-in linear (and stepped/tranche) curve and a curve-agnostic core for custom schedules. See [`finance/examples/vesting_wallet/`](finance/examples/vesting_wallet) for integration examples. |
| [`timelock/`](timelock/) | - | `openzeppelin_timelock` | [docs](https://docs.openzeppelin.com/contracts-sui/1.x/timelock) | A delayed-operation controller (a Sui-native `TimelockController`): schedule a privileged operation, enforce a mandatory on-chain delay, then execute it - with typed on-chain params, operation dependency chaining, optional permissionless execution, and a structural canonical-timelock binding via `OperationCap`. See [`timelock/examples/timelock/`](timelock/examples/timelock) for integration examples. |
| [`utils/`](utils/) | [`@openzeppelin-move/utils`](https://www.moveregistry.com/package/@openzeppelin-move/utils) | `openzeppelin_utils` | [docs](https://docs.openzeppelin.com/contracts-sui/1.x/utils) | Embeddable primitives for everyday module logic, starting with a unified rate-limiter (token bucket, fixed window, cooldown). See [`utils/examples/rate_limiter/`](utils/examples/rate_limiter) for integration examples. |

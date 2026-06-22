# Contracts

OpenZeppelin building blocks for Sui smart contracts development.

---

## Packages

| Package | MVR | Move package | Docs | Highlights |
|---------|----------|--------------|------|-----------|
| [`access/`](access/) | [`@openzeppelin-move/access`](https://www.moveregistry.com/package/@openzeppelin-move/access) | `openzeppelin_access` | [docs](https://docs.openzeppelin.com/contracts-sui/1.x/access) | Transfer policies that wrap privileged capabilities and guard ownership handoffs (two-step approvals and time-locked transfers). |
| [`finance/`](finance/) | [`@openzeppelin-move/finance`](https://www.moveregistry.com/package/@openzeppelin-move/finance) | `openzeppelin_finance` | [docs](https://docs.openzeppelin.com/contracts-sui/1.x/finance) | Vesting wallet that locks a coin for a beneficiary and releases it on a schedule, with a built-in linear (and stepped/tranche) curve and a curve-agnostic core for custom schedules. See [`finance/examples/vesting_wallet/`](finance/examples/vesting_wallet) for integration examples. |
| [`utils/`](utils/) | [`@openzeppelin-move/utils`](https://www.moveregistry.com/package/@openzeppelin-move/utils) | `openzeppelin_utils` | [docs](https://docs.openzeppelin.com/contracts-sui/1.x/utils) | Embeddable primitives for everyday module logic, starting with a unified rate-limiter (token bucket, fixed window, cooldown). See [`utils/examples/rate_limiter/`](utils/examples/rate_limiter) for integration examples. |

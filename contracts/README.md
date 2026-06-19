# Contracts

OpenZeppelin building blocks for Sui smart contracts development.

---

## Packages

| Package | MVR | Move package | Docs | Highlights |
|---------|----------|--------------|------|-----------|
| [`allowance/`](allowance/) | [`@openzeppelin-move/allowance`](https://www.moveregistry.com/package/@openzeppelin-move/allowance) | `openzeppelin_allowance` | [docs](https://docs.openzeppelin.com/contracts-sui/1.x/allowance) | Capability-keyed, multi-coin spending allowances: an owner funds a shared vault and grants capped, optionally expiring, revocable spend rights that delegates draw on demand. See [`allowance/examples/spend_vault/`](allowance/examples/spend_vault) for integration examples. |
| [`access/`](access/) | [`@openzeppelin-move/access`](https://www.moveregistry.com/package/@openzeppelin-move/access) | `openzeppelin_access` | [docs](https://docs.openzeppelin.com/contracts-sui/1.x/access) | Transfer policies that wrap privileged capabilities and guard ownership handoffs (two-step approvals and time-locked transfers). |
| [`utils/`](utils/) | [`@openzeppelin-move/utils`](https://www.moveregistry.com/package/@openzeppelin-move/utils) | `openzeppelin_utils` | [docs](https://docs.openzeppelin.com/contracts-sui/1.x/utils) | Embeddable primitives for everyday module logic, starting with a unified rate-limiter (token bucket, fixed window, cooldown). See [`utils/examples/rate_limiter/`](utils/examples/rate_limiter) for integration examples. |

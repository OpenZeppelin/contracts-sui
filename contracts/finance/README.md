# `openzeppelin_finance`

Vesting primitives for releasing a locked coin to a beneficiary over time.

The `openzeppelin_finance` package locks a `Balance<C>` for a single beneficiary
and pays it out on a schedule. A curve-agnostic core handles release accounting and
conservation of funds; the curve - linear, stepped, cliff, or a custom shape you
write - is a separate, swappable concern. Use it for token grants, team and investor
vesting, payroll streams, and emission schedules.

## Install

```toml
[dependencies]
openzeppelin_finance = { r.mvr = "@openzeppelin-move/finance" }
```

## Modules

| Module | Use it when |
| --- | --- |
| [`vesting_wallet_linear`](https://docs.openzeppelin.com/contracts-sui/1.x/api/finance#vesting_wallet_linear) | You want standard token-grant vesting: a linear unlock, or `N` equal tranches, with an optional cliff. **Most integrators only need this module.** |
| [`vesting_wallet`](https://docs.openzeppelin.com/contracts-sui/1.x/api/finance#vesting_wallet) | You're building a custom vesting curve (milestone unlocks, oracle-gated release, exotic cliff shapes) on top of a safe release-accounting core. |

## Linear Vesting

`vesting_wallet_linear` is the built-in curve and the path most integrators take.
It vests funds in `steps` equal tranches, one every `period_ms`, after an optional
cliff. Continuous linear vesting is the same curve in the `period_ms = 1` limit,
exposed as `new_continuous`.

The curve, piecewise over time:

- **Before `start_ms`:** nothing is vested.
- **Before the cliff** (`now < start_ms + cliff_ms`): nothing is vested. The cliff
  *gates* the staircase; it does not shift it. At the cliff boundary the curve jumps
  straight to the value for however many periods have already elapsed - a cliff
  longer than one period releases several tranches at once as a catch-up, then
  resumes its regular cadence.
- **Mid-schedule:** a staircase. After `k` full periods the cumulative vested total
  is `total * k / steps`, flat across a period and stepping up at each boundary.
- **After the end** (`start_ms + period_ms * steps`): the full total.

The total is re-derived on every call from `balance + released`, so a deposit made
after `start_ms` immediately participates at the current step proportion - funding
is not required up front.

### Lifecycle

1. **Create** - call `new` (stepped) or `new_continuous`, both returning the wallet
   by value so you can fund and choose a topology in the same PTB. `create_and_share`
   is sugar that builds a stepped wallet and shares it in one call.
2. **Fund** - `deposit` a `Coin<C>`. Permissionless: anyone may fund, and funds added
   after the schedule starts participate retroactively.
3. **Release** - `release` evaluates the curve at the current `Clock` and pays the
   not-yet-released portion to the beneficiary. Permissionless and idempotent: if
   nothing new has vested it is a no-op.
4. **Inspect** - `releasable` returns what `release` would pay right now; `start`,
   `period`, `steps`, `duration`, `end`, and `cliff` read the schedule.
5. **Tear down** - once drained and ended, `destroy` reclaims the storage rebate.

### Usage

```move
module my_protocol::grant;

use openzeppelin_finance::vesting_wallet_linear::{Self, Linear, Params};
use openzeppelin_finance::vesting_wallet::VestingWallet;
use sui::clock::Clock;
use sui::coin::Coin;

const DAY_MS: u64 = 86_400_000;

// Four monthly tranches (~30 days each), no cliff, funded up front and shared so
// anyone can poke `release` on the beneficiary's behalf.
public fun grant<C>(beneficiary: address, start_ms: u64, funds: Coin<C>, ctx: &mut TxContext) {
    let mut wallet = vesting_wallet_linear::new<C>(
        beneficiary,
        start_ms,
        0,            // cliff_ms: no cliff
        30 * DAY_MS,  // period_ms
        4,            // steps
        ctx,
    );
    wallet.deposit(funds);
    transfer::public_share_object(wallet);
}

// Continuous one-year linear vest with a 90-day cliff. `create_and_share` only
// covers the stepped form, so share the continuous wallet explicitly.
public fun stream<C>(beneficiary: address, start_ms: u64, ctx: &mut TxContext) {
    let wallet = vesting_wallet_linear::new_continuous<C>(
        beneficiary,
        start_ms,
        90 * DAY_MS,   // cliff_ms
        365 * DAY_MS,  // duration_ms
        ctx,
    );
    transfer::public_share_object(wallet);
}

// Anyone can release; the beneficiary is read fresh from the wallet at call time.
public fun claim<C>(wallet: &mut VestingWallet<Linear, Params, C>, clock: &Clock, ctx: &mut TxContext) {
    vesting_wallet_linear::release(wallet, clock, ctx);
}

// A read-only "what can I claim?" query for clients.
public fun claimable<C>(wallet: &VestingWallet<Linear, Params, C>, clock: &Clock): u64 {
    vesting_wallet_linear::releasable(wallet, clock)
}
```

## Topologies: shared vs. owned

`VestingWallet<S, P, C>` has `key + store`, so the constructor returns it by value
and you pick the topology:

- **Shared** (recommended) - `transfer::public_share_object(wallet)`, or use
  `create_and_share`. Anyone can poke `release`, and the beneficiary always receives
  the funds regardless of who triggered it.
- **Owned** (fast path) - `transfer::public_transfer(wallet, holder)`. Only the
  holder can pass the wallet by `&mut`, so release is reachable from the holder's
  transactions only. Outside parties fund an owned wallet by `public_transfer`-ing a
  `Coin<C>` to the wallet's object address; the holder then claims each with
  `receive_and_deposit`.

The `beneficiary` is fixed at construction. To rotate the recipient, point
`beneficiary` at a consumer-owned object and rotate ownership of that object instead.

## Custom Schedules

`vesting_wallet` is the curve-agnostic core. It never interprets the schedule - it
only enforces release accounting and conservation of funds - so any curve can be
built on top of it. `VestingWallet<S, P, C>` is parameterized by three types chosen
at construction:

- `S` - the **schedule witness**: a `drop`-only struct declared by the curve module.
  It carries no data; minting a vested attestation or tearing the wallet down
  requires a value of `S`, so only the declaring module can do either.
- `P` - the **schedule parameters** (`copy + drop + store`): the curve's stored
  configuration (start, duration, cliff, ...). Held in the wallet, opaque to it.
- `C` - the **coin type** being vested.

Because struct fields are module-private in Move, only the module that declares `S`
and `P` can build a `VestingWallet<S, P, C>` or advance it. This makes "a wallet
without a curve" and "a wallet with the wrong parameters" unrepresentable - the type
system, not a runtime check, binds every wallet to exactly its curve.

To write a curve, follow the `vesting_wallet_linear` pattern:

1. Declare a witness `public struct MyCurve has drop {}` and a parameters struct
   `public struct MyParams has copy, drop, store { /* ... */ }`.
2. A constructor that validates the parameters and calls
   `vesting_wallet::new<MyCurve, MyParams, C>(MyParams { .. }, beneficiary, ctx)`.
3. A `vested_amount(&VestingWallet<MyCurve, MyParams, C>, &Clock): VestedAmount<MyCurve>`
   that evaluates the curve and ends in `wallet.mint_vested_amount(MyCurve {}, amount)`.
4. A teardown that calls `wallet.destroy_empty(MyCurve {})` and destructures the
   returned parameters.

The curve **must be monotonically non-decreasing in time and bounded above by
`balance + released`.** A curve that violates either makes `release` abort before any
state changes - funds stay safe, but the release path is bricked until the curve is
fixed.

### The `VestedAmount` attestation

`vested_amount` mints a `VestedAmount<S>` - a transient record that curve `S` has
vested a given cumulative total for a specific wallet. It is **not a hot potato**: it
has only `drop`, so it cannot be copied, stored, or held across transactions, and
`release` borrows it (it does not consume it). It cannot be used to over-release -
`release` pays `attested - released` and reads `released` fresh each call - and its
`wallet_id` stamp rejects it against any other wallet.

This split - minting needs the witness `S`, spending needs only `&VestedAmount<S>` -
is what lets a third party wrap a `VestingWallet` (e.g. a DAO-gated grant) without
the curve module knowing about the wrapper. A reconfigurable curve can additionally
wrap `set_schedule_params` (witness-gated); a curve that omits it - like
`vesting_wallet_linear` - leaves its wallets' parameters permanently immutable on
chain.

## Security Notes

- **Release and deposit are permissionless.** Anyone can fund a wallet or trigger a
  release; funds always go to the `beneficiary` recorded at construction. Identity is
  data, not a capability.
- **A custom curve must stay honest.** The wallet trusts the witness and never
  re-derives the curve. A curve that mints a dishonest amount against its own wallet
  can over-release up to the wallet's balance. Keep curves monotonic and bounded by
  `balance + released`.
- **Coins sent to a destroyed wallet are stranded.** After `destroy`/`destroy_empty`
  the object address has no claim path. `vesting_wallet_linear::destroy` requires the
  schedule to have ended, which blocks front-running a pending deposit; pair teardown
  with halting any upstream emissions that target the wallet.
- **`receive_and_deposit` can strand a coin on overflow.** If claiming a received
  coin would push the lifetime total (`balance + released`) past `u64::MAX` the call
  aborts, leaving the already-transferred coin parked at the wallet address. High
  volume emitters should track headroom before transferring.

## Learn More

- [Finance package overview](https://docs.openzeppelin.com/contracts-sui/1.x/finance)
- [Finance API reference](https://docs.openzeppelin.com/contracts-sui/1.x/api/finance)
- [OpenZeppelin Contracts for Sui](https://docs.openzeppelin.com/contracts-sui)

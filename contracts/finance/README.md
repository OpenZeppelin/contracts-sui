# `openzeppelin_finance`

Vesting primitives for releasing a locked coin to a beneficiary over time.

The `openzeppelin_finance` package locks a `Balance<C>` for a single beneficiary
and pays it out on a schedule. A curve-agnostic core handles release accounting and
conservation of funds; the curve - linear, stepped, cliff, or a custom shape you
write - is a separate, swappable concern. Use it for token grants, team and investor
vesting, payroll streams, and emission schedules.

## Modules

| Module | Use it when |
| --- | --- |
| [`vesting_wallet_linear`](https://docs.openzeppelin.com/contracts-sui/1.x/api/finance#vesting_wallet_linear) | You want standard token-grant vesting: a linear unlock, or `N` equal tranches, with an optional cliff. **Most integrators only need this module.** |
| [`vesting_wallet`](https://docs.openzeppelin.com/contracts-sui/1.x/api/finance#vesting_wallet) | You're authoring a custom curve (milestone unlocks, oracle-gated release, exotic cliff shapes) on a safe release-accounting core or building a protocol that drives vesting wallets **curve-agnostically** - wrapping or gating release without committing to a schedule. |

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
   by value (plus a `DestroyCap` that authorizes its later teardown) so you can fund and
   choose a topology in the same PTB. `create_and_share`/`create_and_share_continuous`
   are sugar that builds the wallet, shares it, and returns its `ID` and `DestroyCap` in
   one call.
2. **Fund** - `deposit` a `Balance<C>`, claim an addressed `Coin<C>` with
   `receive_and_deposit`, or pull settled address-balance funds in with `sweep_settled`.
   Permissionless: anyone may fund, and funds added after the schedule starts
   participate retroactively.
3. **Release** - `release` evaluates the curve at the current `Clock` and pays the
   not-yet-released portion into the beneficiary's address balance. Permissionless
   and idempotent: if nothing new has vested it is a no-op. No payout `Coin<C>` object
   is minted.
4. **Inspect** - `releasable` returns what `release` would pay right now; `start_ms`,
   `period_ms`, `steps`, `duration_ms`, `end_ms`, and `cliff_ms` read the schedule.
5. **Tear down** - once drained and any settled funds have been swept,
   `vesting_wallet::destroy_empty` reclaims the storage rebate and returns a
   `DestroyReceipt`; hand that, together with the wallet's `DestroyCap`, to
   `vesting_wallet_linear::destroy`, which requires the schedule to have ended before
   accepting the teardown. Authority is the cap, not the caller's address, so a wallet
   whose `beneficiary` is an object (never a transaction sender) can still be torn down
   by whoever holds its cap.

### Usage

```move
module my_protocol::grant;

use openzeppelin_finance::vesting_wallet_linear::{Self, Linear, Params};
use openzeppelin_finance::vesting_wallet::VestingWallet;
use sui::clock::Clock;
use sui::coin::Coin;

const DAY_MS: u64 = 86_400_000;

// Four monthly tranches (~30 days each), no cliff, funded up front and shared so
// anyone can poke `release` on the beneficiary's behalf. The teardown cap is handed to
// the beneficiary so they can reclaim the storage rebate once the wallet is drained.
public fun grant<C>(beneficiary: address, start_ms: u64, funds: Coin<C>, ctx: &mut TxContext) {
    let (mut wallet, cap) = vesting_wallet_linear::new<C>(
        beneficiary,
        start_ms,
        0,            // cliff_ms: no cliff
        30 * DAY_MS,  // period_ms
        4,            // steps
        ctx,
    );
    wallet.deposit(funds.into_balance());
    transfer::public_share_object(wallet);
    transfer::public_transfer(cap, beneficiary);
}

// Continuous one-year linear vest with a 90-day cliff.
public fun stream<C>(beneficiary: address, start_ms: u64, ctx: &mut TxContext) {
    let (_wallet_id, cap) = vesting_wallet_linear::create_and_share_continuous<C>(
        beneficiary,
        start_ms,
        90 * DAY_MS,   // cliff_ms
        365 * DAY_MS,  // duration_ms
        ctx,
    );
    transfer::public_transfer(cap, beneficiary);
}

// Anyone can release; the beneficiary is read fresh from the wallet at call time.
public fun claim<C>(wallet: &mut VestingWallet<Linear, Params, C>, clock: &Clock) {
    vesting_wallet_linear::release(wallet, clock);
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
  `create_and_share`/`create_and_share_continuous`. Anyone can poke `release`,
  and the beneficiary always receives the funds regardless of who triggered it.
  `release` pays into the beneficiary's address balance with `balance::send_funds`,
  so no payout `Coin<C>` object is minted.
- **Owned** (fast path) - `transfer::public_transfer(wallet, holder)`. Only the
  holder can pass the wallet by `&mut`, so release is reachable from the holder's
  transactions only. Outside parties fund an owned wallet by `public_transfer`-ing a
  `Coin<C>` to the wallet's object address; the holder then claims each with
  `receive_and_deposit`. They can also settle a `Balance<C>` into the address for the
  holder to pull in with `sweep_settled`. Liveness risk: `release`, `deposit`,
  `receive_and_deposit`, `sweep_settled`, and `destroy_empty` all require `&mut` or
  by-value access only the holder can produce, so a holder who is not the beneficiary
  and turns uncooperative can withhold every payout with no on-chain path for the
  beneficiary to force one. The recommended Shared topology avoids this because its
  `release` is permissionless.

The `beneficiary` is fixed at construction. To rotate the recipient, point
`beneficiary` at a consumer-owned object and rotate ownership of that object instead.

## Building on the Core

`vesting_wallet` is the curve-agnostic core. It never interprets the schedule - it
only enforces release accounting and conservation of funds - so it serves two kinds
of integrator: protocols that **drive vesting wallets without committing to a curve**,
and authors of a **new curve**. `VestingWallet<S, P, C>` is parameterized by three
types chosen at construction:

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

### Curve-agnostic protocols (recommended)

A protocol that wraps, gates, or routes vesting - a DAO-gated grant, a treasury, an
escrow, a vesting factory - should build on `vesting_wallet` and stay **generic over
the curve** (`S`, `P`), rather than depend on `vesting_wallet_linear` or any single
schedule. This keeps one integration working for every present and future curve.

The core is designed for exactly this. Releasing funds needs only `&VestedAmount<S>`
and `&mut wallet` - it does **not** need the witness `S` - so a wrapper can nest a
`VestingWallet`, hand out an immutable `&inner` (enough for any curve module to mint
an attestation), keep `&mut inner` private, and re-expose `release` behind its own
checks:

```move
module my_protocol::gated_vault;

use openzeppelin_finance::vesting_wallet::{Self, VestingWallet, VestedAmount};
use sui::transfer::Receiving;
use sui::coin::Coin;

/// Adds protocol gating around any vesting curve - note it stays generic over `S`, `P`.
public struct GatedVault<phantom S: drop, P: copy + drop + store, phantom C> has key {
    id: UID,
    inner: VestingWallet<S, P, C>,
    // ... protocol state: pause flag, approval gate, ...
}

/// Hand out a read-only view so any curve module can mint an attestation against it.
public fun inner<S: drop, P: copy + drop + store, C>(
    self: &GatedVault<S, P, C>,
): &VestingWallet<S, P, C> {
    &self.inner
}

/// Re-expose release behind protocol checks, then delegate. `&mut inner` never escapes.
public fun release<S: drop, P: copy + drop + store, C>(
    self: &mut GatedVault<S, P, C>,
    vested: &VestedAmount<S>,
) {
    // ... enforce protocol invariants (not paused, caller approved, ...) ...
    self.inner.release(vested);
}

/// Re-expose `receive_and_deposit` so address-targeted funding can still be claimed
/// while wrapped - it needs the same private `&mut inner`. Omit this and any `Coin<C>`
/// `public_transfer`'d to the inner wallet's address stays stranded until unwrapped.
public fun receive_and_deposit<S: drop, P: copy + drop + store, C>(
    self: &mut GatedVault<S, P, C>,
    receiving: Receiving<Coin<C>>,
) {
    self.inner.receive_and_deposit(receiving);
}
```

The caller picks the curve module at the call site; the vault never knows which curve it holds:

```move
let v = vesting_wallet_linear::vested_amount(vault.inner(), clock);
vault.release(&v);
```

If `release` instead required the witness `S`, this would be impossible: a wrapper
that doesn't own `S` could not call it, so it would have to expose `&mut inner` and
lose all control over deposits and releases.

**Constructing the wallet.** The wrapper either accepts an already-built
`VestingWallet<S, P, C>` from the caller, or builds one itself. To build it without
depending on a curve's `new`, take a validated `P` from the curve module's `params`
constructor and call the core directly - so the protocol owns topology and nesting
while the curve module still owns validation. For the linear curve:

```move
let params = vesting_wallet_linear::params(start_ms, cliff_ms, period_ms, steps);
let (inner, cap) = vesting_wallet::new<Linear, Params, C>(params, beneficiary, ctx);
let vault = GatedVault { id: object::new(ctx), inner, /* ... */ };
// Keep `cap` (store it in the vault, or transfer it) - it is required to tear the
// wallet down later.
```

Every curve following the pattern exposes an analogous `params` constructor, so the
protocol stays one integration wide across curves.

### Custom schedules

To author a new curve, follow the `vesting_wallet_linear` pattern:

1. Declare a witness `public struct MyCurve has drop {}` and a parameters struct
   `public struct MyParams has copy, drop, store { /* ... */ }`.
2. A public `params` constructor that validates and returns a `MyParams`, plus a
   `new` that is sugar over `vesting_wallet::new<MyCurve, MyParams, C>(params(..),
   beneficiary, ctx)` (returning the wallet and its `DestroyCap`). Exposing `params`
   separately lets a curve-agnostic protocol build the wallet itself without routing
   through `new`.
3. A `vested_amount(&VestingWallet<MyCurve, MyParams, C>, &Clock): VestedAmount<MyCurve>`
   that evaluates the curve and ends in `wallet.mint_vested_amount(MyCurve {}, amount)`.
4. A teardown that calls `wallet.destroy_empty(root)` for a `DestroyReceipt<MyCurve,
   MyParams>`, then `vesting_wallet::consume_receipt(receipt, cap, MyCurve {})` - passing
   the wallet's `DestroyCap` - to recover the schedule parameters and destructure them.
   `destroy_empty` is permissionless; `consume_receipt` is gated on both the witness
   (so the curve can run teardown logic or veto) and the cap (the teardown authority).
   **Gate teardown on the cap, never on `ctx.sender() == beneficiary`:** an object
   beneficiary is never a transaction sender, so that check could never be satisfied
   and would brick teardown for object-beneficiary wallets.

The curve **must be monotonically non-decreasing in time and bounded above by
`balance + released`.** `release` enforces only the failure modes that threaten funds:
a regression *below* `released` aborts with `EVestedBelowReleased`, and exceeding
`balance + released` aborts with `EInsufficientBalance` - in both cases before any state
changes, so funds stay safe. An in-range regression (the attested cumulative dips but
stays `>= released`) does **not** abort: `release` silently pays the smaller increment
`vested - released`. Keep the curve monotone so releases only ever move forward.

### The `VestedAmount` attestation

`vested_amount` mints a `VestedAmount<S>` - a transient record that curve `S` has
vested a given cumulative total for a specific wallet. It is **not a hot potato**: it
has only `drop`, so it cannot be copied, stored, or held across transactions, and
`release` borrows it (it does not consume it). It cannot be used to over-release -
`release` pays `attested - released` and reads `released` fresh each call - and its
`wallet_id` stamp rejects it against any other wallet. That stamp is also what lets a
curve-agnostic wrapper safely hand out `&inner`: the worst a holder can do is mint an
inert attestation; no funds move without `&mut`, which the wrapper keeps private.

## Examples

> [!WARNING]
> These are **unaudited illustrations** of how the primitive can be integrated, not production-ready code.

Complete integration examples live in [`examples/vesting_wallet/`](examples/vesting_wallet),
one per integration boundary described above:

- [`vesting_quadratic`](examples/vesting_wallet/vesting_quadratic.move) - the **custom
  schedule** pattern: a backloaded `vested = total * (elapsed / duration)^2` curve that
  ships *only* the operations requiring the schedule's private types (`params`,
  `vested_amount`, and the witness-gated `destroy` that consumes the teardown receipt)
  and lets the integrator drive `new`, `deposit`, `release`, and `destroy_empty` against
  `vesting_wallet` directly. The minimal shape of a new curve.
- [`pausable_grant`](examples/vesting_wallet/pausable_grant.move) - the **curve-agnostic
  wrapper** pattern: a shared grant that nests a wallet, stays generic over `S`/`P`,
  hands out `&inner` while keeping `&mut` private, and re-exposes `release` behind a
  pause check whose flag the employer toggles via cap-gated `pause`/`resume`.
  `unwrap` dissolves the wrapper back to the bare wallet so the curve module can finalize
  teardown. Works with any present or future curve.
- [`splitter`](examples/vesting_wallet/splitter.move) - the **beneficiary-as-object**
  pattern: point a wallet's `beneficiary` at a shared `Beneficiary` object so each
  release settles into the object's accumulator, which anyone can `disperse` to many
  receivers by fixed weights (crediting each via `balance::send_funds`). Composes with
  any curve and topology.

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
  with halting any upstream emissions that target the wallet. Teardown is gated by the
  wallet's `DestroyCap`, so the cap holder bears this strand risk - route the cap to the
  party that should own the teardown decision (commonly the beneficiary or its controller).
- **`receive_and_deposit` can strand a coin on overflow.** If claiming a received
  coin would push the lifetime total (`balance + released`) past `u64::MAX` the call
  aborts, leaving the already-transferred coin parked at the wallet address. High
  volume emitters should track headroom before transferring. The inner
  `transfer::public_receive` can also abort with `EUnableToReceiveObject` when the
  ticket is no longer receivable (the coin was already claimed, e.g. a stale-version
  double-receive race, or it was wrapped/transferred away/absent at that version).
- **A wrapped wallet strands address-targeted funding until unwrapped.**
  `receive_and_deposit` needs `&mut wallet`. A wrapper that keeps `&mut inner` private
  (the recommended pattern above) must re-expose `receive_and_deposit` alongside
  `release` to support address-targeted funding; otherwise a `Coin<C>`
  `public_transfer`'d to the inner wallet's address cannot be claimed until the
  wallet is unwrapped and `&mut` is restored. The funds are recoverable, not lost.

## Learn More

- [Finance package overview](https://docs.openzeppelin.com/contracts-sui/1.x/finance)
- [Finance API reference](https://docs.openzeppelin.com/contracts-sui/1.x/api/finance)
- [`llms.txt`](https://raw.githubusercontent.com/OpenZeppelin/contracts-sui/main/llms.txt): discovery entry point for AI integrators
- [OpenZeppelin Contracts for Sui](https://docs.openzeppelin.com/contracts-sui)

## Summary

41 live invariants (INV-1..INV-39 plus INV-44, INV-45) across five categories.
The feature now spans **two modules**: the curve-agnostic primitive
`vesting_wallet`, and the built-in linear-with-cliff curve `linear_schedule`
(the reference curve and the template downstream schedule modules copy).

The property surface splits in two tiers:

- **Tier 1 — wallet-level invariants** (`vesting_wallet`): conservation, release
  accounting, schedule typing, composability. Curve-agnostic.
- **Tier 2 — schedule-shape invariants** (`linear_schedule`): pre-start zero,
  pre-cliff zero, cliff proportional jump, linear-in-time, u128 intermediate,
  post-end clamp. Scoped to the built-in `Linear` schedule. Custom curve modules
  inherit only the weaker curve contract (INV-36: monotone non-decreasing,
  bounded by `balance + released`); they are responsible for the schedule-shape
  properties they ship.

A `VestingWallet<S, P, C>` is parameterized on **three** types: a phantom
schedule-witness `S` (`drop`) that tags the wallet's curve, a params struct `P`
(`copy + drop + store`) stored by value in the `schedule_params` field, and a
phantom coin type `C`. A wallet never interprets `P` — it only enforces release
accounting and conservation. A curve module mints a `VestedAmount<S>` for the
current clock; `release` pays out the not-yet-released portion.

The critical wallet-level properties are:

- **(a) Conservation** — no path mints or burns coin internally (INV-28).
- **(b) Schedule-gated construction and minting** (INV-37): only the module that
  declares schedule witness `S` and params `P` can build a
  `VestingWallet<S, P, C>` (construction takes `P` by value) or mint a
  `VestedAmount<S>` (minting takes an `S` witness), because struct fields are
  module-private — this makes a wallet with the wrong/missing parameters
  unforgeable at the type level.
- **(c) Per-instance binding of `VestedAmount<S>`** (INV-44): every minted
  `VestedAmount<S>` records the `wallet_id` it was minted against; `release` and
  `releasable` abort with `EWalletMismatch` if applied to any other wallet, even
  one of the same `<S, P, C>`.
- **(d) `VestedAmount<S>` is PTB-confined** (INV-38): no `key`/`store`/`copy`,
  so it cannot be persisted across transactions, copied, or made into an object.
- **(e) Curve type-pinning** (INV-39): the type parameter `S` pins each wallet
  to a single curve module's witness.
- **(f) Fixed beneficiary** (INV-8): the beneficiary is set once at construction
  and never changes.
- **(g) Witness-gated, balance-gated destroy** (INV-10, INV-37): `destroy_empty`
  requires the `S` witness and an empty balance, and returns `P` to the curve
  module for destructuring.

### Changes from the prior invariant set

The design moved from a two-type-parameter wallet (`VestingWallet<C, T>`, `C` =
schedule, `T` = coin) to the three-parameter `VestingWallet<S, P, C>`, and split
the single `vesting_wallet` module into the primitive plus the `linear_schedule`
curve module. Consequences:

- **Time bounds moved off the wallet.** `start_ms` / `duration_ms` are no longer
  wallet fields — they live in `linear_schedule::Params`. The zero-duration
  check (INV-6) and the cliff check (INV-7) are therefore Tier-2
  (`linear_schedule::new`) checks, not primitive checks.
- **`VestedAmount<S>` is no longer a strict hot potato.** It now has `drop` and
  carries a `wallet_id` (INV-38 relaxed; INV-44 added). `release` / `releasable`
  take it by reference.
- **`destroy_empty` is witness-gated and balance-only.** The "vesting ended"
  gate (INV-9) moved into `linear_schedule::destroy` (error `ENotEnded`), applied
  *after* the wallet is consumed; the primitive `destroy_empty` only checks the
  empty-balance gate (INV-10, `ENotEmpty`) and requires the `S` witness.
- **No `schedule_mut`.** Params are immutable: there is no mutation path, and
  `schedule_params()` returns `P` by copy (INV-14).
- **New runtime check `EScheduleOverflow`** (INV-45) in `linear_schedule::new`.

Five invariants from the original design remain removed: the sender-gated
rotation invariant (beneficiary is immutable, INV-8) and the four
params-lifecycle invariants INV-40..INV-43 (dynamic-field `attach`/`detach`/
`ParamsKey` machinery) — curve parameters now live in the typed `schedule_params:
P` field. Labels INV-40..INV-43 stay retired and are not reused; INV-44 and
INV-45 are new.

## Type-Level Invariants

### INV-1: Per-(schedule, params, coin) wallet isolation

**Category:** Type-level

**Statement:** A `VestingWallet<S, P, C>` is parameterized on a phantom schedule
witness `S` (`S: drop`), a params struct `P` (`P: copy + drop + store`, stored by
value in `schedule_params`), and a phantom coin type `C`. A wallet for one
`(S, P, C)` triple cannot be substituted for a wallet of a different triple at
any public API entry — the type system rejects the call.

**Applies to:** All public functions.

**Enforcement mechanism:**

- Type system: `VestingWallet<S, P, C>` carries `S, P, C` through every
signature; the Move compiler refuses to mix `VestingWallet<Linear, Params, USDC>`
with operations expecting `VestingWallet<Linear, Params, SUI>` or
`VestingWallet<Stepped, StepParams, USDC>`.
- Runtime check: none required.
- Test: Compile a snippet that mixes types — expect compile failure.

**Violation scenario:** Impossible by construction. If hypothetically violated,
a caller could pass a `VestedAmount<Linear>` to a `VestingWallet<Stepped, _, C>`
and silently use the wrong schedule, or cross-pollinate balances between coin
types.

**Severity:** Critical (but enforced by Move; no runtime risk).

---

### INV-2: Balance is encapsulated

**Category:** Type-level

**Statement:** `Balance<C>` lives inside `VestingWallet<S, P, C>` as a private
field. No public API returns a `&mut Balance<C>` or a `&Balance<C>` reference to
the internal field; the only public accessor (`balance<S, P, C>`) returns `u64`
(the value), not the balance object.

**Applies to:** `balance` field of `VestingWallet<S, P, C>`.

**Enforcement mechanism:**

- Type system: Move's module-private field visibility hides `wallet.balance`
from external callers.
- Runtime check: none.
- Test: Static — confirm no `public fun` returns `&mut Balance<C>` or
`&Balance<C>`.

**Violation scenario:** If a `&mut Balance<C>` were exposed, an external caller
could `balance::split` arbitrary amounts out, bypassing every vesting check.

**Severity:** Critical.

---

### INV-3: Both shared and owned topologies are reachable

**Category:** Type-level

**Statement:** `VestingWallet<S, P, C>` has both `key` and `store` abilities.
`key` makes it a top-level on-chain object; `store` lets external modules call
`transfer::public_share_object(wallet)` or
`transfer::public_transfer(wallet, addr)` on it directly without a library-side
wrapper.

**Applies to:** Wallet creation and topology selection.

**Enforcement mechanism:**

- Type system: ability declarations on `VestingWallet<S, P, C>`.
- Runtime check: none.
- Test: Two scenarios — one ending in `public_share_object`, one in
`public_transfer`; both must compile and execute.

**Violation scenario:** If `store` were dropped, only the library itself could
share/transfer the wallet — `linear_schedule::create_and_share` would still work,
but external factories couldn't compose `new` with their own topology choice. If
`key` were dropped, it couldn't be a top-level object.

**Severity:** High (capability contract for consumers). Note: with the
beneficiary fixed at construction (INV-8), owned-mode hand-off does not redirect
cashflow, so `store` carries no rotation footgun (INV-35 is a positive
guarantee).

---

### INV-4: Wallet must be explicitly destroyed

**Category:** Type-level

**Statement:** `VestingWallet<S, P, C>` does NOT have `drop`. The only path that
consumes a wallet by value is
`destroy_empty<S, P, C>(wallet: VestingWallet<S, P, C>, _w: S): P`, which returns
the params for the curve module to destructure. Code paths cannot silently drop
a wallet.

**Applies to:** `VestingWallet<S, P, C>` lifetime.

**Enforcement mechanism:**

- Type system: absence of `drop` ability on `VestingWallet<S, P, C>`; also
requires the `S` witness (only the declaring module can call it).
- Runtime check: `destroy_empty` aborts if the balance is non-empty (INV-10).
The "ended" gate, if any, is the curve module's responsibility
(`linear_schedule::destroy` adds `ENotEnded`).
- Test: Try to drop a wallet without calling `destroy_empty` — compile failure.

**Violation scenario:** A path that dropped a non-empty wallet would burn the
trapped balance permanently (INV-28 violation).

**Severity:** Critical.

---

### INV-5: `receive_and_deposit` only accepts receipts addressed to the wallet

**Category:** Type-level

**Statement:** `Receiving<Coin<C>>` passed to `receive_and_deposit` is validated
by Sui's framework — `transfer::public_receive` only succeeds if the receipt's
parent ID matches the wallet's UID. Receipts addressed elsewhere cannot be
claimed through this wallet.

**Applies to:** `receive_and_deposit`.

**Enforcement mechanism:**

- Type system + framework: `transfer::public_receive(&mut wallet.id, receiving)`
aborts if the receipt's parent doesn't equal `wallet.id`.
- Runtime check: framework-level, not user-visible.
- Test: Pass a `Receiving<Coin<C>>` constructed against another address —
expect framework abort.

**Violation scenario:** Impossible — framework guarantees this. If hypothetically
violated, one wallet could "steal" coins addressed to another.

**Severity:** Critical (but framework-enforced).

---

## Runtime Invariants

### INV-6: `linear_schedule::new` rejects zero duration

**Category:** Runtime (scope: Tier 2 linear schedule)

**Statement:** `linear_schedule::new` aborts with `EZeroDuration` (= 0) if
`duration_ms == 0`. A zero-duration wallet is not meaningfully a vesting wallet
(instant grant) and would force a divide-by-zero in the curve math. This is a
Tier-2 check — the curve-agnostic `vesting_wallet::new` knows nothing about
duration (time bounds live in `linear_schedule::Params`, not on the wallet).

**Applies to:** `linear_schedule::new`, `linear_schedule::create_and_share`.

**Enforcement mechanism:**

- Type system: none.
- Runtime check: `assert!(duration_ms > 0, EZeroDuration)` in
`linear_schedule::new`, before it calls `vesting_wallet::new(Params { .. }, ..)`.
- Test: Call `linear_schedule::new` with `duration_ms = 0` — expect abort with
`EZeroDuration`.

**Severity:** Critical (prevents bricked / malformed wallets). Custom curve
modules carry the analogous obligation for any divisor in their own math.

---

### INV-7: `linear_schedule::new` rejects cliff longer than duration

**Category:** Runtime (scope: Tier 2 linear schedule)

**Statement:** `linear_schedule::new` aborts with `EInvalidCliff` (= 1) if
`cliff_ms > duration_ms`.

**Applies to:** `linear_schedule::new`, `linear_schedule::create_and_share`.

**Enforcement mechanism:**

- Type system: none.
- Runtime check: `assert!(cliff_ms <= duration_ms, EInvalidCliff)` in
`linear_schedule::new`, before it calls
`vesting_wallet::new(Params { start_ms, duration_ms, cliff_ms }, ..)`.
- Test: Call `linear_schedule::new` with `cliff_ms = duration_ms + 1` — expect
abort.

**Violation scenario:** A wallet with `cliff > duration` would gate releases past
the end of the vesting window — funds never vest. OZ matches this check.

**Severity:** High.

---

### INV-8: Beneficiary is fixed at construction

**Category:** Type-level / State transition

**Statement:** The `beneficiary` field is set once inside `vesting_wallet::new`
and never changes for the lifetime of the wallet. There is no
`migrate_beneficiary` (or any other) function that mutates it; no internal path
does either. This mirrors OpenZeppelin's `VestingWallet`, where the beneficiary
is immutable.

**Applies to:** `beneficiary` field; whole wallet lifetime.

**Enforcement mechanism:**

- Type system: Move field-level mutation visibility — no `public fun` exposes a
path that writes `wallet.beneficiary` outside the module, and no internal write
site exists after `new`.
- Runtime check: none required (the field is simply not writable).
- Test: Property test — for an arbitrary sequence of `deposit`, `release`,
`receive_and_deposit` calls, accessor `beneficiary()` returns the same value as
at construction.

**Violation scenario:** If the beneficiary were mutable, a rotation entrypoint
would need an authorization gate, and an owned-mode hand-off could redirect
cashflow. Fixing the field at construction removes that entire surface; rotation
is handled by the Beneficiary-object pattern (Design Integration Pattern C).

**Severity:** Critical (immutability is the property consumers and indexers rely
on; rotation, if needed, is layered above via object ownership).

---

### INV-9: `linear_schedule::destroy` requires vesting ended

**Category:** Runtime (scope: Tier 2 linear schedule)

**Statement:** `linear_schedule::destroy` aborts with `ENotEnded` (= 3) if
`clock.timestamp_ms() < start_ms + duration_ms`. This is a Tier-2 gate — the
curve-agnostic `vesting_wallet::destroy_empty` knows nothing about time and does
not enforce it.

**Applies to:** `linear_schedule::destroy`.

**Enforcement mechanism:**

- Type system: none.
- Runtime check: `assert!(clock.timestamp_ms() >= start_ms + duration_ms,
ENotEnded)`. NOTE: in the current code this assert runs *after*
`vesting_wallet::destroy_empty` has already consumed the wallet and returned the
`Params`. Because Move transactions are atomic, a failing assert still rolls back
the whole call — no partial teardown is observable — but the check is positioned
after destruction rather than before. (See Dev Notes / open question on whether
this gate should exist at all.)
- Test: Destroy before `end` with balance == 0 — expect abort with `ENotEnded`.

**Violation scenario:** Premature destruction of a still-vesting wallet would
discard the remaining schedule. Even with balance == 0, destroying before end is
questionable — late deposits may still be expected.

**Severity:** High.

---

### INV-10: `destroy_empty` requires zero balance

**Category:** Runtime

**Statement:** `vesting_wallet::destroy_empty` aborts with `ENotEmpty` (= 0) if
`wallet.balance.value() > 0`.

**Applies to:** `vesting_wallet::destroy_empty`, `linear_schedule::destroy`.

**Enforcement mechanism:**

- Type system: `Balance<C>` does not have `drop`, so the final
`balance.destroy_zero()` inside `destroy_empty` would itself abort on a non-zero
balance. The explicit `assert!` provides the typed error and a clean message.
- Runtime check: `assert!(wallet.balance.value() == 0, ENotEmpty)`, first
statement of `destroy_empty`.
- Test: Fund the wallet, attempt destroy without release — expect abort with
`ENotEmpty`.

**Violation scenario:** Destroying with non-zero balance would burn funds
(INV-28 violation).

**Severity:** Critical.

---

### INV-11: `release` is a no-op when releasable is zero

**Category:** Runtime

**Statement:** When `vested.amount == wallet.released`, `release` does not call
`coin::from_balance`, does not call `transfer::public_transfer`, does not emit a
`Released` event, and does not mutate `wallet.released` or `wallet.balance`. It
returns early.

**Applies to:** `release`.

**Enforcement mechanism:**

- Type system: none.
- Runtime check: explicit `if (releasable == 0) return;` early return inside
`release`, after the `wallet_id` and `vested_amount >= released` asserts, before
any balance split, transfer, or event emit.
- Test: Call `release` (a) with a `VestedAmount<S>` whose amount equals `released`
(already drained at this clock), (b) immediately after a prior `release` at the
same `clock` (re-mint vested, release again) — neither should emit `Released`,
neither should change `released`, neither should abort.

**Violation scenario:** Aborting on zero releasable would force callers
(off-chain bots) to pre-check before poking — wasted gas and consensus traffic.
Minting a zero-value coin would also bloat the on-chain coin table.

**Severity:** Medium (UX / cost, not safety).

---

### INV-12: Event emission contract

**Category:** Runtime

**Statement:** Events are emitted by exactly one call site each, with the
documented shape and emission gates:

| Event | Emitter | Gate | Cardinality per call |
| --- | --- | --- | --- |
| `Created<S, P, C>` | `vesting_wallet::new` | always | exactly 1 |
| `Deposited` | `deposit` (also reached transitively via `receive_and_deposit`) | always (per deposit operation) | exactly 1 per call |
| `Released` | `release` | only when `vested.amount > wallet.released` (paired with INV-11) | 0 or 1 |
| `Destroyed` | `destroy_empty` | always (after the empty-balance gate passes) | exactly 1 |

`Created<S, P, C>` carries `{ wallet_id, beneficiary, schedule_params: P }` — the
full params struct (for the linear curve, `start_ms` / `duration_ms` /
`cliff_ms`), NOT individual time fields on the wallet. `Deposited` carries
`{ wallet_id, amount }`; `Released` carries `{ wallet_id, beneficiary, amount }`;
`Destroyed` carries `{ wallet_id, beneficiary, total_released }`. There is no
`BeneficiaryMigrated` event — the beneficiary is fixed (INV-8).

`receive_and_deposit` does NOT emit a separate `Received` event — it fans into
`deposit`, which emits a single `Deposited` for the funded amount.

All four events carry the schedule witness `S` as their first type argument
(`Created<S, P, C>`, `Deposited<S, C>`, `Released<S, C>`, `Destroyed<S, C>`), so a
single wallet's events are indexed under one uniform tag for downstream indexers.

**Applies to:** All event-emitting functions.

**Enforcement mechanism:**

- Type system: none.
- Runtime check: control flow inside each function emits at most one event of
each type. The `Released` emission lives behind the same `if (releasable == 0)
return;` guard as INV-11.
- Test: For each function, inspect the test scenario's emitted events and assert
count + field values + type arguments.

**Violation scenario:** Extra or missing events corrupt indexer state — duplicate
`Created` would create phantom wallets in dashboards; missed `Released` would
misaccount cashflow.

**Severity:** Medium (off-chain correctness; no on-chain fund risk).

---

### INV-13: `vested_amount_raw` guards `now < start_ms` underflow

**Category:** Runtime (scope: Tier 2 linear schedule — see also INV-21)

**Statement:** When `clock.timestamp_ms() < start_ms`, the private
`linear_schedule::vested_amount_raw(&wallet, &clock)` helper (used by
`vested_amount` and `releasable`) returns `0` via an explicit first branch,
before computing `now - start_ms` (which would underflow u64).
`linear_schedule::vested_amount` therefore yields a `VestedAmount<Linear>` with
`amount == 0`.

**Applies to:** `linear_schedule::vested_amount_raw`,
`linear_schedule::vested_amount`, `linear_schedule::releasable`.

**Enforcement mechanism:**

- Type system: none.
- Runtime check: `if (now < start_ms) { 0 }` as the first branch of
`vested_amount_raw`.
- Test: With `start_ms = 1000`, call `vested_amount` at `clock = 999` and read
`amount(&result)` — expect `0`. Without the guard this would abort on u64
underflow.

**Violation scenario:** Without the guard, every pre-start curve evaluation would
abort, bricking the wallet's release path (and any view that relies on the
curve) until `start_ms` arrives.

**Severity:** Critical (bricks the curve's evaluation; for the built-in linear
schedule this also bricks `release`). Custom curve modules carry the analogous
obligation for their own pre-start handling.

---

## State Transition Invariants

### INV-14: Schedule params are immutable after creation

**Category:** State transition

**Statement:** Once `vesting_wallet::new` returns a `VestingWallet<S, P, C>`, the
`schedule_params: P` field never changes for the lifetime of the wallet. There is
no `schedule_mut` (or any other) function that mutates it, and no internal path
does either; `schedule_params()` returns `P` by copy, not by `&mut`. For the
built-in linear curve this means `start_ms`, `duration_ms`, and `cliff_ms` are
fixed for the wallet's whole lifetime.

**Applies to:** `schedule_params` field (and, for the linear curve, the
`start_ms` / `duration_ms` / `cliff_ms` it contains).

**Enforcement mechanism:**

- Type system: Move's field-level mutation visibility — no `public fun` exposes a
write path to `schedule_params`, and no internal mutation site exists. The only
accessor, `schedule_params<S, P, C>(&wallet): P`, returns a copy (`P: copy`).
- Runtime check: none required.
- Test: Property test — for an arbitrary sequence of `deposit`, `release`,
`receive_and_deposit` calls, the linear accessors `start()`, `duration()`,
`cliff()`, `end()` return identical values before and after.

> **Change from prior design.** The earlier invariant set permitted mutating the
> schedule through a witness-gated `schedule_mut`. That function no longer exists.
> Params are now strictly immutable for the lifetime of the wallet — a curve
> module that wants mutable parameters would have to add its own typed mutator on
> top of the primitive (the primitive ships none).

**Violation scenario:** A mutable `duration_ms` would let a misbehaving path
shorten the window and vest everything early. Immutable params remove that
surface entirely.

**Severity:** Critical.

---

### INV-15: `released` is monotonically non-decreasing

**Category:** State transition

**Statement:** `wallet.released` only increases (by `releasable = vested.amount -
wallet.released` inside `release`) or stays the same across any sequence of
public calls. It never decreases.

**Applies to:** `released` field; affects `release` and `releasable` directly.

**Enforcement mechanism:**

- Type system: none.
- Runtime check: the only mutation site is `wallet.released = wallet.released +
releasable` inside `release`, after the zero-check (INV-11). No path subtracts
from `released`.
- Test: Property test — sequence of operations, assert `released` is monotone.

**Violation scenario:** A decreasing `released` could let the wallet pay out more
than the deposited total cumulatively — fund creation (INV-28 violation).

**Severity:** Critical.

---

### INV-16: Balance + released = sum of deposits (ledger conservation)

**Category:** State transition

**Statement:** At every observable point,
`balance.value() + released == Σ(deposits)` where `Σ(deposits)` is the sum of
`Coin<C>.value()` across all successful `deposit` and `receive_and_deposit` calls
on this wallet.

**Applies to:** Whole-wallet ledger consistency.

**Enforcement mechanism:**

- Type system: none.
- Runtime check: every state transition either (a) increases `balance` by a
coin's value and leaves `released` unchanged (deposit paths), or (b) decreases
`balance` by `releasable` and increases `released` by the same `releasable`
(`release`).
- Test: Test scenario tracks `Σ(deposits)` off-chain and asserts the equation
after every step.

**Violation scenario:** Breakage means either coins were paid out without being
recorded (under-counted `released`) or recorded without being paid out
(over-counted `released`) — both corrupt the "vests as if from start" semantic.

**Severity:** Critical.

---

### INV-17: Wallet identity (UID/ID) is stable

**Category:** State transition

**Statement:** The `wallet.id` (and the `ID` it derives) is set once inside
`vesting_wallet::new` and never changes. `deposit`, `release`,
`receive_and_deposit`, and every other mutating call preserve `wallet.id`; only
`destroy_empty` consumes it.

**Applies to:** `id` field.

**Enforcement mechanism:**

- Type system: `UID` has no public mutation API; `object::new` is the only
constructor.
- Runtime check: none required.
- Test: Capture the wallet's `ID` after `new`, do arbitrary operations, capture
again — must be equal.

**Violation scenario:** ID drift would break indexers, the Beneficiary-object
pattern, and the `VestedAmount.wallet_id` binding (INV-44), which uses the
wallet's `ID` as a long-lived handle.

**Severity:** High.

---

### INV-18: After `release`, `releasable` against the same `VestedAmount<S>` is zero

**Category:** State transition

**Statement:** For any `vested: VestedAmount<S>` minted against this wallet with
`vested.amount >= wallet.released`, calling `release(&mut wallet, &vested, ctx)`
followed by `releasable(&wallet, &vested')`, where `vested'` is a fresh
`VestedAmount<S>` minted at the same `clock`, returns 0.

**Applies to:** `release` ↔ `releasable` consistency.

**Enforcement mechanism:**

- Type system: none.
- Runtime check: `release` increments `released` by exactly `vested.amount -
wallet.released` (the value `releasable` would have returned), so a subsequent
`releasable` at the same `vested.amount` reads `vested.amount - released == 0`.
- Test: At several timestamps (pre-cliff, mid-vest, post-end), call `release`
then re-mint `VestedAmount<S>` at the same clock and check `releasable` — expect
0. (Because `VestedAmount<S>` has `drop` and `release` takes it by reference, the
same witness value may also be reused directly for the `releasable` view in the
same PTB.)

**Violation scenario:** Residual availability after release indicates a mismatch
between the curve's computation and the amount actually paid out — either
under-pay (beneficiary loses funds) or over-pay (impossible without violating
INV-16, but worth checking).

**Severity:** High.

---

### INV-19: `released` never exceeds `vested.amount` (per release)

**Category:** State transition

**Statement:** After any successful `release(&mut wallet, &vested, ctx)` call,
`wallet.released == vested.amount`. No `release` can produce `released >
vested.amount`: `release` first asserts `vested.amount >= wallet.released`, then
computes `releasable = vested.amount - wallet.released`, then sets `released =
released + releasable`.

**Applies to:** `release`, whole-wallet correctness.

**Enforcement mechanism:**

- Type system: none.
- Runtime check: an explicit `assert!(*vested_amount >= wallet.released,
EVestedBelowReleased)` guards the subtraction, followed by
`let releasable = *vested_amount - wallet.released;` and
`wallet.released = wallet.released + releasable;`. After the addition, `released`
equals `vested.amount` exactly.
- Test: Property — at every step after a `release`, assert `released ==
vested.amount` for the consumed witness. Negative test — mint a curve module that
violates monotonicity (returns a `vested.amount < released`), call `release`,
expect abort on the `>=` assert.

Both `release` and `releasable` guard the subtraction with the same
`assert!(*vested_amount >= wallet.released, EVestedBelowReleased)`, so a
`vested.amount < released` witness aborts with the typed error on either path,
before any state mutation.

**Violation scenario:** Over-release would mean the wallet pays out ahead of the
schedule — cliff cheating, team grants leaking ahead of time. The `>=` assert
plus the subtraction are the structural guard.

**Severity:** Critical.

---

## Economic / Protocol Invariants

INV-20 through INV-27 describe the **built-in `Linear` schedule**
(`linear_schedule`, Tier 2) and the wallet-wide conservation properties that hold
regardless of curve. Custom curve modules built per the `linear_schedule` pattern
owe only INV-36 (monotone + bounded); they may, but are not required to, mirror
INV-20..INV-25.

### INV-20: `vested_amount` is non-decreasing in time (given constant total)

**Category:** Economic / Protocol (scope: Tier 2 linear schedule)

**Statement:** For a wallet with no intervening deposits or releases between `t1`
and `t2` (`t1 <= t2`), `amount(&linear_schedule::vested_amount(&wallet,
&clock_at_t1)) <= amount(&linear_schedule::vested_amount(&wallet, &clock_at_t2))`.

**Applies to:** `linear_schedule::vested_amount`,
`linear_schedule::vested_amount_raw`.

**Enforcement mechanism:**

- Type system: none.
- Runtime check: math is `total * (now - start) / duration` clamped — `now`
monotone with constant `total` implies output monotone.
- Test: Sample at increasing timestamps without intervening deposits/releases —
assert non-decreasing.

**Severity:** High. Strengthens INV-36 for the built-in curve.

---

### INV-21: Pre-start: `vested_amount` returns 0

**Category:** Economic / Protocol (scope: Tier 2 linear schedule)

**Statement:** When `clock.timestamp_ms() < start_ms`,
`amount(&linear_schedule::vested_amount(&wallet, &clock)) == 0` regardless of
`cliff_ms` (see also INV-13).

**Applies to:** `linear_schedule::vested_amount`, `vested_amount_raw`.

**Enforcement mechanism:**

- Type system: none.
- Runtime check: pre-start guard (INV-13) returns 0.
- Test: With `start_ms = 1000`, sample at `clock = 999` — expect 0.

**Severity:** Critical.

---

### INV-22: Pre-cliff: `vested_amount` returns 0 (when cliff > 0)

**Category:** Economic / Protocol (scope: Tier 2 linear schedule)

**Statement:** When `cliff_ms > 0` and `start_ms <= clock.timestamp_ms() <
start_ms + cliff_ms`, `amount(&linear_schedule::vested_amount(&wallet, &clock))
== 0`.

**Applies to:** `linear_schedule::vested_amount`, `vested_amount_raw`.

**Enforcement mechanism:**

- Type system: none.
- Runtime check: `else if (cliff_ms > 0 && now < start_ms + cliff_ms) { 0 }`
inside `vested_amount_raw` (reading `cliff_ms` from the destructured `Params`).
- Test: With `cliff_ms = 1000`, `start_ms = 0`, sample at `clock = 999` — expect
0. At `clock = 0` — expect 0.

**Violation scenario:** Releasable funds before cliff would violate the OZ cliff
contract — a team member with a 1-year cliff could claim partial vest in month 1.

**Severity:** Critical.

---

### INV-23: Cliff boundary: proportional jump

**Category:** Economic / Protocol (scope: Tier 2 linear schedule)

**Statement:** When `cliff_ms > 0` and `clock.timestamp_ms() == start_ms +
cliff_ms`, `amount(&linear_schedule::vested_amount(&wallet, &clock)) == (total *
cliff_ms) / duration_ms` where `total = balance.value() + released`. The cliff
gates the curve — at the cliff boundary, vesting jumps from 0 to the
linear-from-start proportion (not to zero, not to a linear-from-cliff curve).

**Applies to:** `linear_schedule::vested_amount`, `vested_amount_raw`.

**Enforcement mechanism:**

- Type system: none.
- Runtime check: when `now == start_ms + cliff_ms`, the pre-cliff guard releases
control and the standard linear formula applies; `now - start_ms == cliff_ms`, so
the formula yields `total * cliff_ms / duration_ms`.
- Test: With `duration_ms = 4000`, `cliff_ms = 1000`, `total = 1000`, sample at
`clock = start_ms + 999` — expect 0; at `clock = start_ms + 1000` — expect 250.

**Violation scenario:** Wrong cliff math is the most common bug class in vesting
contracts — implementations that compute "linear from cliff" instead of "linear
from start, gated at cliff" silently underpay beneficiaries by `cliff/duration`
proportion forever.

**Severity:** Critical.

---

### INV-24: Post-end: `vested_amount` clamps to total

**Category:** Economic / Protocol (scope: Tier 2 linear schedule)

**Statement:** When `clock.timestamp_ms() >= start_ms + duration_ms`,
`amount(&linear_schedule::vested_amount(&wallet, &clock)) == balance.value() +
released`.

**Applies to:** `linear_schedule::vested_amount`, `vested_amount_raw`.

**Enforcement mechanism:**

- Type system: none.
- Runtime check: explicit branch `if (now >= start_ms + duration_ms) { total }`
inside `vested_amount_raw` — the "clamp to total" step. INV-45 guarantees
`start_ms + duration_ms` does not overflow, so this comparison is well-defined.
- Test: Sample at `clock = end`, `clock = end + 1`, `clock = u64::MAX` — all
return `balance + released`.

**Violation scenario:** If post-end didn't clamp, the linear formula `total *
(now - start) / duration` could exceed `total` (since `now - start > duration`),
letting the curve violate INV-36's boundedness and trigger underflow at
`release`.

**Severity:** Critical.

---

### INV-25: Linear schedule between (cliff or start) and end

**Category:** Economic / Protocol (scope: Tier 2 linear schedule)

**Statement:** In the open interval `(start_ms + max(cliff_ms, 0), start_ms +
duration_ms)`, `amount(&linear_schedule::vested_amount(&wallet, &clock)) ==
(total * (now - start_ms)) / duration_ms` (with u128 intermediate; integer
division floors).

**Applies to:** `linear_schedule::vested_amount`, `vested_amount_raw`.

**Enforcement mechanism:**

- Type system: none.
- Runtime check: standard linear formula in the middle branch of
`vested_amount_raw`.
- Test: With known `(start, duration, total)`, sample at several intermediate
timestamps and verify against off-chain re-computation.

**Violation scenario:** Anything other than linear-from-start (e.g.
linear-from-cliff, exponential, stair-stepped) violates the OZ contract.

**Severity:** Critical.

---

### INV-26: Linear-curve math uses u128 intermediate, fits in u64

**Category:** Economic / Protocol (scope: Tier 2 linear schedule)

**Statement:** The computation is `((total as u128) * (elapsed as u128) /
(duration_ms as u128)) as u64`. The u128 multiplication absorbs the worst-case
`u64::MAX * u64::MAX < u128::MAX`. The final cast to u64 is safe because the
quotient is at most `total <= u64::MAX`.

**Applies to:** `linear_schedule::vested_amount_raw` arithmetic.

**Enforcement mechanism:**

- Type system: explicit `as u128` / `as u64` casts.
- Runtime check: math itself; no separate assert needed.
- Test: With `total = u64::MAX`, `duration_ms = u64::MAX`, `now - start_ms =
u64::MAX - 1` — expect `vested` to return a u64 close to but not exceeding
`u64::MAX` without aborting.

**Violation scenario:** A u64-only multiplication overflows for any realistic
9-decimal coin × multi-year ms duration (10¹⁸ × 10¹¹ = 10²⁹). The OZ analog is
issue #5793 with `u256` — Sui's tighter u64 makes this MORE important. Custom
curves are responsible for their own overflow discipline; the wallet itself never
multiplies.

**Severity:** Critical.

---

### INV-27: Post-deposit "vests as if from the beginning" (linear curve)

**Category:** Economic / Protocol (scope: Tier 2 linear schedule)

**Statement:** `vested_amount_raw` is computed against `total = balance.value() +
released` at the time of the query — NOT against a stored "original allocation"
captured at construction. Therefore a deposit made at time `t > start_ms`
immediately participates in vesting at the proportion `(t - start_ms) /
duration_ms`.

**Applies to:** `linear_schedule::vested_amount`, `linear_schedule::releasable`,
`vested_amount_raw`; all deposit paths in interaction with the linear curve.

**Enforcement mechanism:**

- Type system: `vested_amount_raw` does not store an `original_balance` — it
re-derives `total` from `wallet.balance() + wallet.released()` on every call.
- Runtime check: none required (it's a derivation, not an assert).
- Test: Create a 1000ms wallet with 0 starting balance, advance to t=500, deposit
1000 — `amount(&linear_schedule::vested_amount(at 500))` should immediately read
500 (half-vested retroactively), not 0.

**Violation scenario:** Storing `original_balance` and computing against it would
break the "fund-after-creation" semantic — recurring emissions schedules and
payroll top-ups would each create a fresh schedule, defeating the design.

**Severity:** Critical (defines the library's core differentiator vs every
existing Sui locker). Custom curves are encouraged to derive `total` the same
way; the integration patterns in the design assume they do.

---

### INV-28: Conservation of funds (no minting, no burning)

**Category:** Economic / Protocol

**Statement:** Within the library, no code path creates `Coin<C>` out of thin air
or destroys `Coin<C>` value. Specifically: (a) `release` only moves value from
`wallet.balance` into a fresh `Coin<C>` via `coin::from_balance` / `balance.split`,
conserving total value; (b) `destroy_empty` requires `balance.value() == 0`
(INV-10), so no value is lost when the wallet is consumed; (c)
`schedule_params` touches no balance.

**Applies to:** All public functions; whole-library accounting.

**Enforcement mechanism:**

- Type system: `Balance<C>` has no `drop`; the framework prevents value loss at
the type level. The wallet has no `drop` (INV-4), so the balance can't ride a
dropped wallet to the dustbin.
- Runtime check: INV-10 enforces empty-balance at destroy; release paths use
`balance::split` and `coin::from_balance`, both value-preserving.
- Test: Property test — for any sequence of operations, off-chain ledger
`Σ(deposits) - Σ(release amounts) == wallet.balance.value()` always holds (this
is also INV-16 from the other direction).

**Violation scenario:** Any minting path would let a malicious upgrade or bug
create coins; any burning path would destroy beneficiary funds. The library must
be a pure accounting layer over coin movement.

**Severity:** Critical.

---

### INV-29: Release sends to the wallet's fixed beneficiary

**Category:** Economic / Protocol

**Statement:** `release` reads `wallet.beneficiary` and `public_transfer`s the
released coin to that address. Because the beneficiary is fixed at construction
(INV-8), every release over the wallet's lifetime pays the same address — there
is no rotation that could redirect a future release. In owned mode, transferring
the wallet object to a new holder does NOT change the recipient: releases still
flow to the construction-time beneficiary.

**Applies to:** `release`; `release` ↔ object-ownership interaction.

**Enforcement mechanism:**

- Type system: `beneficiary` is immutable (INV-8).
- Runtime check: `release` reads `wallet.beneficiary` directly into a local
before transferring; no caching outside the call.
- Test: Create wallet for Alice, vest partially, call `release` → Alice receives.
Move the wallet object to Bob (owned mode) or have Bob poke `release` (shared
mode), vest further → Alice still receives the newly-vested portion.

**Severity:** High (semantic clarity for indexers and beneficiaries).

---

### INV-30: Released coins are out of the wallet's reach

**Category:** Economic / Protocol

**Statement:** Once `release` `public_transfer`s a coin to the beneficiary, that
coin is owned by the beneficiary and the library has no path to reach it back.
There is no clawback. (With a fixed beneficiary there is also no rotation that
could ever target prior releases.)

**Applies to:** `release` post-conditions.

**Enforcement mechanism:**

- Type system: released coins are no longer the wallet's responsibility — they
are owned by their recipient.
- Runtime check: none required.
- Test: Vest and release to Alice, then run further wallet operations — assert
Alice's released coin balance is never reduced by the wallet.

**Violation scenario:** Any clawback path would let a malicious upgrade reclaim
already-vested funds. The design treats released funds as final (matches OZ).

**Severity:** Medium (documented design choice; tests verify the chosen
semantics).

---

## Composability Invariants

### INV-31: Permissionless poke and fund

**Category:** Composability

**Statement:** `release`, `releasable`, `deposit`, and `receive_and_deposit`
require no capability and no specific sender — any address with the required
references can call them. At the linear-curve API level, `linear_schedule::release`,
`linear_schedule::releasable`, and `linear_schedule::destroy` are likewise
permissionless (the module supplies the `Linear {}` witness internally).

**Applies to:** `release`, `releasable`, `deposit`, `receive_and_deposit`;
`linear_schedule::release` / `releasable` / `destroy`.

**Enforcement mechanism:**

- Type system: no `Cap` parameter and no witness gate on these functions. Witness
gating is reserved for schedule construction (`vesting_wallet::new` takes `P`),
minting (`mint_vested_amount` takes `_w: S`), and teardown
(`vesting_wallet::destroy_empty` takes `_w: S`).
- Runtime check: no `ctx.sender()` comparison anywhere in these paths.
- Test: For each function, call from an unrelated address and assert success.

> **Note on `destroy_empty`.** The *primitive* `vesting_wallet::destroy_empty` is
> witness-gated (it takes `_w: S`), so only the declaring curve module can call
> it directly. But the curve module's wrapper (`linear_schedule::destroy`) takes
> no witness from the caller, so end-to-end destruction is permissionless for the
> integrator.

**Violation scenario:** Adding sender gates would break the OZ "anyone can poke"
contract and prevent off-chain bots from acting as relays for beneficiaries.

**Severity:** High (consumer contract).

---

### INV-32: Single-PTB compositions are reachable

**Category:** Composability

**Statement:** A consumer can compose `linear_schedule::new` + `deposit` +
`transfer::public_share_object` (or `public_transfer`) in a single PTB. Likewise
`linear_schedule::new` + `deposit` + `linear_schedule::release` is reachable in
one transaction (and the generic `linear_schedule::vested_amount` +
`vesting_wallet::release` pair, or any custom `<curve>::vested_amount` +
`release`). Likewise `receive_and_deposit` + `linear_schedule::release` in one
transaction.

**Applies to:** API surface design (function shapes and ability bounds).

**Enforcement mechanism:**

- Type system: `vesting_wallet::new` / `linear_schedule::new` return
`VestingWallet<S, P, C>` by value (not by reference and not shared internally),
letting PTBs chain them into `deposit` then any topology finalizer.
`mint_vested_amount` returns `VestedAmount<S>` by value, letting PTBs chain it
into `release`; `linear_schedule::release` bundles the vested+release pair.
- Runtime check: none.
- Test: PTB-style test scenarios chaining `linear_schedule::new` → `deposit` →
`public_share_object` → (separate tx) `linear_schedule::release`. Also a chain
`linear_schedule::new` → `deposit` → `linear_schedule::release` in one tx for the
owned-mode case.

**Violation scenario:** If `new` instead took `&mut TxContext` and immediately
shared the wallet internally (no return value), every PTB would need a second
transaction to deposit — defeating the presale-style use case (Integration
Pattern A in the design).

**Severity:** High.

---

### INV-33: Beneficiary may be any address, including object IDs

**Category:** Composability

**Statement:** The `beneficiary: address` field can hold any 32-byte address,
including the address of a Move object (used by the Beneficiary-object pattern,
Design Integration Pattern C). The library makes no assumption that the
beneficiary corresponds to an externally-owned account.

**Applies to:** `vesting_wallet::new`, `linear_schedule::new`, `release`.

**Enforcement mechanism:**

- Type system: `address` is opaque — Move does not distinguish "user address" vs
"object address" at the type level.
- Runtime check: none.
- Test: Create a wallet pointing at an object's address, advance time, release —
assert the released coin is transferred to the object's address.

**Severity:** High (composability contract).

---

### INV-34: Shared-mode concurrent release is safe

**Category:** Composability

**Statement:** When `VestingWallet<S, P, C>` is a shared object and two
transactions both mint `VestedAmount<S>` then `release`, Sui consensus serializes
them. The total paid out across both transactions equals
`releasable(now_at_finalization)`, not `2 * releasable(now)`. The second to
finalize observes a higher `released` and either pays a small delta if time
advanced or no-ops (INV-11).

**Applies to:** `release` under shared topology.

**Enforcement mechanism:**

- Type system + Sui runtime: shared-object consensus ordering. A `VestedAmount<S>`
has no `key`/`store` (INV-38), so it cannot be split across transactions — each
tx mints fresh against the wallet's current state, and its `wallet_id` binds it
to that wallet (INV-44).
- Runtime check: each `release` computes `releasable = vested.amount -
wallet.released` fresh against the current state — there is no read-then-write
race window inside the transaction.
- Test: Document. (A two-tx race test is hard to author deterministically in
`test_scenario`; cover via the "two back-to-back mint+release at the same clock"
test, which exercises the same idempotency property — see INV-18.)

**Violation scenario:** A non-atomic `release` (e.g. reading `vested.amount` in
one tx and consuming it in another — impossible here because `VestedAmount<S>`
has no `store`/`key`) would double-pay in a race. Move's transaction atomicity
combined with the PTB-confinement (INV-38) and per-instance binding (INV-44)
prevent this by construction.

**Severity:** Critical (but framework-guaranteed).

---

### INV-35: Owned-mode hand-off does not redirect cashflow

**Category:** Composability

**Statement:** In owned mode, a holder can `transfer::public_transfer(wallet,
new_owner)` to move the object. This does NOT change who gets paid: the
`beneficiary` field is fixed at construction (INV-8), so subsequent releases still
flow to the construction-time beneficiary regardless of the current holder. There
is no rotation entrypoint to misuse.

**Applies to:** Owned mode operational guarantees; `release` ↔ object-ownership
interaction.

**Enforcement mechanism:**

- Type system: `beneficiary` immutability (INV-8); `store` enables the hand-off
but cannot touch the beneficiary field.
- Runtime check: none.
- Test: Owned-mode test scenario — create wallet with Alice as beneficiary and
holder, `public_transfer` to Bob, have Bob poke `release` → Alice still receives.

**Violation scenario:** If a future revisor reintroduced a mutable beneficiary
without a careful auth model, an owned-mode hand-off could silently strand or
redirect cashflow. The fixed-beneficiary design (matching OZ) keeps the hand-off
safe.

**Severity:** Low (with a fixed beneficiary this is a positive guarantee, not a
hazard).

---

### INV-36: Custom curve modules must mint monotone, bounded `VestedAmount<S>`

**Category:** Composability (consumer obligation)

**Statement:** A curve module that pairs with `VestingWallet<S, P, C>` exposes a
`vested_amount(&VestingWallet<S, P, C>, &Clock): VestedAmount<S>` (or analogous)
that must satisfy, for any fixed `wallet`:

- **Monotone in time.** `vested.amount` is non-decreasing as
`clock.timestamp_ms()` increases (under no intervening deposits / releases).
- **Bounded by wallet total.** `vested.amount <= wallet.balance() +
wallet.released()` at every call.

The built-in `linear_schedule::vested_amount` satisfies both: INV-20 covers
monotonicity and INV-24 (post-end clamp) covers boundedness.

**Applies to:** Every curve module that calls `mint_vested_amount`. The wallet
relies on this contract; it does not re-verify it.

**Enforcement mechanism:**

- Type system: none. `mint_vested_amount<S, P, C>(&wallet, _w: S, amount: u64)`
only constrains that the caller possess a witness of type `S` — not that `amount`
is well-formed.
- Runtime check at `release`: a `vested.amount < wallet.released` trips the
explicit `assert!(*vested_amount >= wallet.released)` (INV-19) and aborts before
any state mutation — funds remain safe, but the release path is operationally
bricked until the curve is fixed.
- Runtime check at `release` (boundedness): if `vested.amount` exceeds
`wallet.balance() + wallet.released()`, the subsequent `balance.split` aborts at
the framework level. Same outcome — atomic rollback, no value leaked.
- Documentation: stated in the module-level docs of `vesting_wallet` and
`linear_schedule`. Downstream packages shipping a custom curve are responsible
for testing both properties for the specific curve.

**Violation scenario:**

- *Non-monotone curve.* A subsequent `vested_amount` returns a value smaller than
the running `wallet.released`. The `>=` assert (INV-19) fires and the release
aborts. The wallet is not corrupted (atomic rollback); the curve is bricked for
that consumer until they ship a fixed curve.
- *Unbounded curve.* A `vested_amount` call returns `amount > balance + released`.
`balance.split` aborts at the framework level. Same outcome: no coin minted, no
funds leaked, transaction reverts.

**Severity:** High (violations brick the consumer's curve, but cannot leak funds
out of the wallet — INV-28 keeps holding because the abort happens before any
`coin::from_balance` or `public_transfer` runs).

---

### INV-37: Only the declaring module can build a `VestingWallet<S, P, C>` or mint a `VestedAmount<S>`

**Category:** Composability (schedule gate / type-level authority)

**Statement:** Building a wallet requires supplying a `P` value
(`vesting_wallet::new<S, P, C>(schedule_params: P, ..)` takes the params by
value), and minting / destroying requires supplying an `S` witness
(`mint_vested_amount<S, P, C>(&wallet, _w: S, ..)` and `destroy_empty<S, P,
C>(wallet, _w: S)`). Struct fields are module-private in Move, so only the module
that declares schedule witness `S` and params `P` can construct those values —
and therefore only that module can build a `VestingWallet<S, P, C>` or mint a
`VestedAmount<S>` redeemable against it. No foreign module — not even one holding
`&mut VestingWallet<S, P, C>` — can synthesize a release amount.

This is what makes "a wallet with the wrong parameters" unforgeable: the
release-controlling authority (the `S` witness needed to mint `VestedAmount<S>`)
is module-private, enforced by the type system rather than a runtime check.

**Applies to:** `vesting_wallet::new`, `mint_vested_amount`, `destroy_empty`;
every curve module.

**Enforcement mechanism:**

- Type system: `new` takes `schedule_params: P` by value; `mint_vested_amount`
and `destroy_empty` take `_w: S`. The Move module system prevents any module from
constructing a struct value it does not declare, so `P` and `S` values are only
producible inside the declaring module.
- Runtime check: none required.
- Test: Attempt (in a test fixture) to construct a `Linear {}` or `Params { .. }`,
or to call `mint_vested_amount(&wallet, Linear {}, amount)`, outside
`linear_schedule` — expect compile failure. Conversely, the built-in
`linear_schedule::new` and `vested_amount` (inside the module) succeed.

> **Subtlety (S vs P authority).** The schedule witness `S` on the wallet type is
> *phantom* — naming `S = Linear` in a `VestingWallet<Linear, P, C>` type does not
> by itself require constructing a `Linear`. The structural guarantee is on
> *minting*: a `VestedAmount<Linear>` can only be produced by whoever can
> construct a `Linear` witness, i.e. `linear_schedule`. A foreign module could
> name `<Linear, ForeignParams, C>` and supply its own `ForeignParams`, but it
> could never mint a matching `VestedAmount<Linear>` (no `Linear` witness) and the
> real `linear_schedule` functions expect `P = Params`, so such a wallet is inert
> (no one can release against it) rather than exploitable. The authority that
> matters for fund safety is the `S` witness on `mint_vested_amount`.

**Violation scenario:** If a foreign module could mint `VestedAmount<S>`
unilaterally, it could pass `vested.amount = u64::MAX` to `release` and drain any
wallet of witness `S` it can reach (subject to INV-44's per-wallet binding). The
module-private witness is the structural guarantee against this.

**Severity:** Critical.

---

### INV-38: `VestedAmount<S>` is PTB-confined (drop-only, no key/store/copy)

**Category:** Composability

**Statement:** `VestedAmount<S>` has exactly one ability: `drop`. It has no `key`,
`store`, or `copy`. Consequences:

- **No `store` / `key`** → it cannot be stored in a struct field, wrapped in
another object, or made a standalone object — so it cannot persist across
transactions. It lives and dies within a single PTB.
- **No `copy`** → it cannot be duplicated, so a single mint cannot be redeemed
twice by copying.
- **Has `drop`** → unlike a strict hot potato, it is NOT forced to be consumed;
it may be silently discarded. `release` and `releasable` take it by reference
(`&VestedAmount<S>`), so the same witness can serve both a `releasable` view and
a `release` in one PTB.

Combined with the per-instance `wallet_id` binding (INV-44) and the fact that the
recorded `amount` only matters relative to the wallet's *current* `released`
(read fresh on every `release`), the relaxed `drop` ability does not enable
over-release or double-release.

**Applies to:** `VestedAmount<S>` lifecycle; all curve modules and consumers.

**Enforcement mechanism:**

- Type system: the single `drop` ability (and absence of `key`/`store`/`copy`).
The Move compiler refuses to store or copy the value.
- Runtime check: none.
- Test: Attempt (in a test fixture) to write a function that stores a
`VestedAmount<S>` in a struct field or returns it as a transaction object —
expect compile failure. Confirm a function that drops it compiles (drop is
allowed).

> **Change from prior design.** The original invariant set required
> `VestedAmount` to have NO abilities at all (a strict hot potato that *must* be
> consumed in the same PTB). The current type adds `drop`, relaxing the
> forced-consumption requirement; the cross-transaction protection (no
> `store`/`key`) and the no-double-spend protection (no `copy`) are unchanged.
> This relaxation should be confirmed as intentional (see Open Questions) — it
> appears safe because of INV-44 and the fresh-`released` read in `release`.

**Violation scenario:** If `VestedAmount<S>` had `store`, a consumer could mint at
favorable clock state, persist the witness, then redeem when schedule conditions
diverge — defeating the at-call-time semantics. If it had `copy`, one mint could
be redeemed twice.

**Severity:** Critical (for the surviving `store`/`copy` prohibitions).

---

### INV-39: Type parameter `S` pins each wallet to a single curve module

**Category:** Composability (type discrimination)

**Statement:** `release<S, P, C>(wallet: &mut VestingWallet<S, P, C>, vested:
&VestedAmount<S>, ctx)` requires the schedule witness type `S` on the wallet and
on the `VestedAmount` to match. A `VestedAmount<Linear>` cannot be fed into a
`VestingWallet<Stepped, _, C>`, and vice versa. The pairing is established at
`vesting_wallet::new<S, P, C>(..)` and is immutable thereafter.

**Applies to:** `vesting_wallet::new`, `release`, `releasable`,
`mint_vested_amount`, every curve module.

**Enforcement mechanism:**

- Type system: shared type parameter `S` in `release` / `releasable` /
`mint_vested_amount` signatures.
- Runtime check: none for the type match (the per-instance `wallet_id` check is
the separate runtime layer — INV-44).
- Test: Compile a fixture that calls `release<Stepped, _, C>(wallet_linear,
vested_stepped, ctx)` where `wallet_linear: VestingWallet<Linear, Params, C>` —
expect compile failure.

**Violation scenario:** If `release` were generic in two independent witnesses, a
malicious curve module could mint a cheap `VestedAmount<MyCheatingCurve>` and
redeem against any wallet. INV-39 + INV-37 together close that hole: only the
wallet's own curve module can mint amounts of the matching witness type.

**Severity:** Critical.

---

### INV-40..INV-43: Retired (dynamic-field params lifecycle)

These four invariants covered the dynamic-field curve-params machinery
(`attach_params`/`detach_params`/`borrow_params`/`has_params`/`ParamsKey` and the
`EParamsAttached` destroy gate), which no longer exists. Curve parameters now live
in the typed `schedule_params: P` field, baked into the wallet's type at
construction. Their guarantees are subsumed structurally:

- **INV-40 (at most one params blob per wallet)** — superseded by the type
system: a `VestingWallet<S, P, C>` carries exactly one `schedule_params: P`.
- **INV-41 (params mutation is witness-gated)** — superseded by INV-14: there is
no params-mutation path at all. `schedule_params()` returns `P` by copy.
- **INV-42 (destroy requires no params attached)** — gone with `EParamsAttached`.
`destroy_empty` returns the params by value for the curve module to destructure
(e.g. `linear_schedule::destroy` does `let Params { .. } = destroy_empty(..)`).
- **INV-43 (`ParamsKey` integrity)** — gone with the dynamic-field slot. The
params are a typed field, not a dynamic field at a constructible key.

Labels INV-40..INV-43 are retired and not reused.

---

### INV-44: `VestedAmount<S>` is bound to the wallet it was minted against

**Category:** Composability (runtime instance binding) — **new**

**Statement:** Every `VestedAmount<S>` records the `wallet_id: ID` of the wallet
it was minted against (`mint_vested_amount` reads `object::id(wallet)`). `release`
and `releasable` assert `vested.wallet_id == object::id(wallet)` and abort with
`EWalletMismatch` (= 1) otherwise. A `VestedAmount<S>` minted against wallet A
cannot be redeemed (or even read via `releasable`) against wallet B, even when A
and B share the same `<S, P, C>` triple.

**Applies to:** `mint_vested_amount`, `release`, `releasable`.

**Enforcement mechanism:**

- Type system: none (the type triple alone cannot distinguish two instances).
- Runtime check: `assert!(wallet_id == object::id(wallet), EWalletMismatch)` —
present in both `release` and `releasable`. `mint_vested_amount` stamps the
`wallet_id` at mint time.
- Test: Mint a `VestedAmount<Linear>` against wallet A, attempt
`release(&mut B, &vested_A, ctx)` (and `releasable(&B, &vested_A)`) where B is a
second wallet of the same type — expect abort with `EWalletMismatch`.

**Violation scenario:** Without the binding, a beneficiary could create a second
wallet with attacker-chosen params, mint a large `VestedAmount<S>` from that
wallet's favorable curve, and redeem it against the original wallet to over-draw.
The `wallet_id` stamp closes this: the amount is only ever redeemable against the
exact wallet whose `schedule_params` produced it. (This is the structural answer
to the `QUESTION` comment in `mint_vested_amount`.)

**Severity:** Critical.

---

### INV-45: `linear_schedule::new` rejects `start_ms + duration_ms` overflow

**Category:** Runtime (scope: Tier 2 linear schedule) — **new**

**Statement:** `linear_schedule::new` aborts with `EScheduleOverflow` (= 2) if
`duration_ms > u64::MAX - start_ms`, i.e. if the wallet's end time `start_ms +
duration_ms` would overflow u64.

**Applies to:** `linear_schedule::new`, `linear_schedule::create_and_share`;
transitively protects every `start_ms + duration_ms` / `start_ms + cliff_ms`
computation in `vested_amount_raw`, `end()`, and `linear_schedule::destroy`.

**Enforcement mechanism:**

- Type system: none.
- Runtime check: `assert!(duration_ms <= std::u64::max_value!() - start_ms,
EScheduleOverflow)` in `linear_schedule::new`.
- Test: Call `linear_schedule::new` with `start_ms = u64::MAX` and
`duration_ms = 1` — expect abort with `EScheduleOverflow`. Also confirm a wallet
near the boundary (e.g. `start_ms + duration_ms == u64::MAX`) constructs and its
`end()` does not abort.

**Violation scenario:** Without the guard, `start_ms + duration_ms` could wrap,
making the post-end branch in `vested_amount_raw` (`now >= start_ms +
duration_ms`) reachable far too early — or `end()` return a nonsensical small
value — corrupting the curve and `ENotEnded` gate.

**Severity:** High.

---

## Invariant Coverage Matrix

### `vesting_wallet` (primitive)

| Function | Invariants | Enforcement |
| --- | --- | --- |
| `new<S, P, C>` | INV-1, INV-2, INV-3, INV-4, INV-8, INV-12, INV-14, INV-17, INV-32, INV-33, INV-37, INV-39 | Type + Runtime |
| `mint_vested_amount<S, P, C>` | INV-37, INV-38, INV-39, INV-44 | Type (witness gate + PTB-confinement) + Runtime (wallet_id stamp) |
| `amount<S>` (view on `&VestedAmount<S>`) | INV-38 (read does not consume) | Type |
| `deposit<S, P, C>` | INV-2, INV-12, INV-16, INV-27, INV-28, INV-31 | Type + Runtime |
| `receive_and_deposit<S, P, C>` | INV-2, INV-5, INV-12, INV-16, INV-27, INV-28, INV-31 | Type + Runtime |
| `release<S, P, C>` | INV-11, INV-12, INV-15, INV-16, INV-18, INV-19, INV-28, INV-29, INV-30, INV-31, INV-34, INV-36, INV-38, INV-39, INV-44 | Type + Runtime |
| `releasable<S, P, C>` (view) | INV-18, INV-19, INV-39, INV-44 | Type + Runtime |
| `schedule_params<S, P, C>` | INV-14, INV-37 (ungated read, returns `P` by copy) | Type |
| `destroy_empty<S, P, C>` | INV-4, INV-10, INV-12, INV-28, INV-37 (witness-gated) | Type + Runtime |
| `beneficiary`, `released`, `balance` (accessors) | INV-2, INV-8, INV-15, INV-17 (read-only) | Type |

### `linear_schedule` (built-in curve, Tier 2)

| Function | Invariants | Enforcement |
| --- | --- | --- |
| `new<C>` | INV-6, INV-7, INV-45, plus all `vesting_wallet::new` invariants it delegates to (INV-1..4, 8, 12, 14, 17, 32, 33, 37, 39) | Type + Runtime |
| `create_and_share<C>` | same as `new<C>` plus `public_share_object` (INV-3) | Type + Runtime |
| `vested_amount<C>` | INV-13, INV-20, INV-21, INV-22, INV-23, INV-24, INV-25, INV-26, INV-27, INV-36, INV-37, INV-38, INV-44 | Runtime + Type |
| `release<C>` | INV-11, INV-12, INV-15, INV-16, INV-19, INV-28, INV-29, INV-31, plus INV-13/20..27 via `vested_amount` | Type + Runtime |
| `releasable<C>` (view) | INV-18, INV-19, INV-44, plus INV-13/20..27 via `vested_amount` | Runtime |
| `destroy<C>` | INV-4, INV-9, INV-10, INV-12, INV-28, INV-31 (wraps `destroy_empty`) | Type + Runtime |
| `start`, `duration`, `end`, `cliff<C>` (accessors) | INV-14 (read-only) | Type |
| `vested_amount_raw<C>` (internal) | INV-13, INV-20..INV-27 | Runtime |

INV-20..INV-27 describe the built-in linear schedule and therefore transitively
apply to `vesting_wallet::release` when paired with
`linear_schedule::vested_amount`. Custom curve modules built per the same pattern
owe only INV-36 (monotone + bounded), INV-37/INV-38 (witness gate +
PTB-confinement — automatic by reusing `new` and `mint_vested_amount`), and
inherit INV-44 (wallet binding — also automatic). Consumers shipping a custom
curve decide which of INV-20..INV-27 they want to mirror.

## Out of Scope

- **Late deposits after `destroy_empty`** — coins `public_transfer`'d to a
destroyed wallet's address have no `&mut VestingWallet` to be claimed against.
Their fate is the depositor's responsibility. No library invariant covers their
recovery.
- **Rotation / selling unvested rights** — the beneficiary is fixed at
construction (INV-8); there is no wallet-level rotation. Consumers who need
rotation use the Beneficiary-object pattern (Design Integration Pattern C). No
invariant enforces non-sale.
- **`u64` aggregate-deposit overflow boundaries** — at `Σ(deposits) > u64::MAX`,
`balance::join` aborts (framework-level). No library invariant or typed error
wraps this. Depositor must bound their own accumulation. (Note: the *schedule*
end-time overflow IS covered — INV-45.)
- **Shared-object contention SLOs** — concurrent `release` finalizes correctly
(INV-34) but the library makes no claim about throughput under contention.
- **Off-chain time skew between `clock.timestamp_ms()` and wall-clock** — the
library trusts whatever the `Clock` object reports. No invariant constrains
`Clock` accuracy.
- **Re-entrancy** — Move has no re-entrancy in the EVM sense; no invariant
required.
- **Custom-curve schedule-shape correctness** — INV-20..INV-27 cover the built-in
`Linear` schedule. Downstream curves are constrained only by INV-36; the wallet
does not (and structurally cannot) enforce a specific shape for custom curves.
- **Curve-parameter semantics** — the params struct `P` is opaque to the generic
primitive; it stores and returns `schedule_params` but never interprets the
fields. A curve module that ships a malformed parameter set bricks only its own
curve (INV-36), never the wallet's accounting.

## Dev Notes

- INV-23 (cliff proportional jump) is the single most important math invariant in
the built-in `Linear` schedule and the one most likely to be implemented
incorrectly. A reference test `release_at_cliff_jumps_to_proportional` directly
verifies this — the Tests stage must author it as one of the first
linear-schedule tests.
- INV-26 (u128 intermediate) is non-obvious from a casual read of OZ's Solidity
reference (which uses u256 throughout and is silent about overflow). The
`linear_schedule::vested_amount_raw` implementation keeps the `as u128` →
multiply → divide → `as u64` as a single expression — do not split it across
statements, which would invite a "let me simplify this" refactor that
reintroduces u64 arithmetic.
- INV-27 (vests-as-if-from-start) is the library's core differentiator vs every
existing Sui locker. If a future revisor proposes "store `original_balance` for
gas savings," this invariant is the reason to reject it. Scoped to the built-in
`Linear` schedule.
- INV-44 (per-wallet `VestedAmount` binding) is the structural answer to the
`QUESTION` comment left in `mint_vested_amount`: a beneficiary cannot mint a
favorable `VestedAmount<S>` from a side wallet and redeem it against the target,
because the `wallet_id` stamp is checked at `release`/`releasable`.
- INV-38 was relaxed: `VestedAmount<S>` now has `drop` (was abilityless). Verify
this was intentional before publishing — the relaxation only removes
forced-consumption, and INV-44 + the fresh-`released` read keep it safe, but a
reviewer should confirm the design intent.
- INV-9 (`ENotEnded`) lives in `linear_schedule::destroy` and is currently checked
*after* `vesting_wallet::destroy_empty` consumes the wallet. There is an open
`QUESTION` comment in the code about whether this gate should exist at all
(arguably only `balance == 0` matters). If it stays, consider moving the check
*before* `destroy_empty` for clarity (atomicity makes the observable behaviour
identical either way).
- INV-12 (events): the four event structs are declared with a phantom `S` first
parameter, but `deposit`/`release`/`destroy_empty` emit them with the params type
`P` in that slot while `new` uses `S`. Make the first type argument consistent
(almost certainly `S` for all four) so indexers see a uniform tag. Consider a
test-only helper that captures `event::events_by_type<E>()` per event shape and
asserts cardinality + type arguments.
- No `EOverflow` constant on the primitive — overflow protection lives in the
built-in `vested_amount_raw` math (INV-26), the `EScheduleOverflow` construction
guard (INV-45), and `balance::join`'s framework abort (out of scope above).

## Open Questions

None.

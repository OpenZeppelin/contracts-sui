---
stage: review
project: vesting-wallet
mode: greenfield
extends: null
status: draft
timestamp: 2026-06-17
author: 0xNeshi
previous_stage: vesting-wallet-artifacts/tests.md
tags: [vesting, finance, linear-schedule, basic-review, post-core]
---

# Vesting Wallet — Basic Review Report

## Summary

**Verdict: ready for publishing.** No Critical, High, or Medium findings. The two
modules (`vesting_wallet` primitive + `linear_schedule` curve) are correct against
all 41 live invariants, conserve funds on every path, and gate authority at the
type level. 48/48 tests pass; `sui move build --lint --warnings-are-errors` is
clean.

Findings are 5 Informational, of which **INF-2 was fixed during review** (a
permanent fund-trap on `balance + released` overflow — now guarded at `deposit` by
the new INV-46 / `EOverflow`). The rest: a teardown-ordering nit, two
code-style/doc items, one optional test. Plus artifact-drift items in
`invariants.md` / `tests.md` (doc sync, not code).

**Review scope note:** only `invariants.md` (stage 3), `tests.md` (stage 5), and
`post-core/btt-coverage.md` were present — no research, design, code, or docs
stage artifacts exist. Invariants was used as the primary checklist; design intent
was read from the (thorough) module-level doc comments.

## Invariant Verification

All 41 enforced. Locations are `file:line` in `contracts/finance/sources/`.

| Invariant | Enforced? | Location | Notes |
|-----------|-----------|----------|-------|
| INV-1 per-triple isolation | ✅ Type | `VestingWallet<S,P,C>` on every sig | compiler-enforced |
| INV-2 balance encapsulated | ✅ Type | `balance()` returns `u64` (vw:444) | no `&mut Balance` exposed |
| INV-3 shared+owned | ✅ Type | `key, store` (vw:110) | both topologies tested |
| INV-4 no drop / explicit destroy | ✅ Type | no `drop`; `destroy_empty` (vw:377) | only by-value consumer |
| INV-5 receive only addressed | ✅ Framework | `public_receive(&mut wallet.id,..)` (vw:312) | — |
| INV-6 zero duration | ✅ Runtime | ls:103 `EZeroDuration` | — |
| INV-7 cliff > duration | ✅ Runtime | ls:104 `EInvalidCliff` | `<=` accept-edge tested |
| INV-8 beneficiary fixed | ✅ Type | set in `new` (vw:233); no mutator | — |
| INV-9 destroy requires ended | ⚠️ Yes, but ordered after consume | ls:179 | atomic rollback → safe; see **INF-1** |
| INV-10 destroy requires empty | ✅ Runtime | vw:381 `ENotEmpty` | — |
| INV-11 release no-op at zero | ✅ Runtime | vw:347 `if (releasable==0) return` | — |
| INV-12 event contract | ✅ Runtime | vw:239/302/354/397 | all four emit `<S, …>` |
| INV-13 pre-start underflow guard | ✅ Runtime | ls:212 `if (now < start_ms) 0` | — |
| INV-14 params immutable | ✅ Type | `schedule_params()` returns by copy (vw:427) | no mutator |
| INV-15 released monotone | ✅ Runtime | only `released = released + releasable` (vw:349) | — |
| INV-16 ledger conservation | ✅ Runtime | deposit/release arithmetic | tested each step |
| INV-17 id stable | ✅ Type | `object::new` once (vw:232) | — |
| INV-18 post-release releasable zero | ✅ Runtime | `released` → `vested.amount` (vw:349) | — |
| INV-19 released ≤ vested.amount | ✅ Runtime | `>=` guard vw:344 **and** vw:421 | both `EVestedBelowReleased` |
| INV-20 non-decreasing in time | ✅ Runtime | linear math (ls:221) | tested 8 samples |
| INV-21 pre-start 0 | ✅ Runtime | ls:212 | — |
| INV-22 pre-cliff 0 | ✅ Runtime | ls:214 | — |
| INV-23 cliff proportional jump | ✅ Runtime | ls:221-223 (linear-from-start) | tested = 250 |
| INV-24 post-end clamp | ✅ Runtime | ls:218 `if (now >= end) total` | — |
| INV-25 linear mid | ✅ Runtime | ls:221-223 | — |
| INV-26 u128 intermediate | ✅ Type/math | ls:221-223 single expr | worst-case tested |
| INV-27 vests as if from start | ✅ Derivation | `total = balance()+released()` (ls:217) | re-derived per call |
| INV-28 conservation | ✅ Type+Runtime | split/from_balance (vw:350); empty-destroy | no mint/burn |
| INV-29 pays fixed beneficiary | ✅ Runtime | reads `wallet.beneficiary` fresh (vw:351) | — |
| INV-30 released coins out of reach | ✅ Type | no clawback path | tested |
| INV-31 permissionless poke/fund | ✅ Type | no cap/sender gate on release/deposit | — |
| INV-32 single-PTB compositions | ✅ Type | `new` returns by value | — |
| INV-33 beneficiary any address | ✅ Type | `address` opaque | object-addr tested |
| INV-34 shared concurrent release | ✅ Framework | fresh `released` read per `release` | idempotency stand-in |
| INV-35 owned handoff no redirect | ✅ Type | beneficiary immutable (INV-8) | tested |
| INV-36 custom curve monotone+bounded | ✅ Reactive | `>=` assert (vw:344) + `balance.split` abort | built-in satisfies |
| INV-37 only declarer builds/mints | ✅ Type | `new` takes `P` by value; mint/destroy take `_w: S` | — |
| INV-38 `VestedAmount` drop-only | ✅ Type | `has drop` only (vw:169) | relaxation intentional — see note |
| INV-39 `S` pins curve | ✅ Type | shared `S` in release/releasable/mint | — |
| INV-44 wallet binding | ✅ Runtime | `wallet_id` check vw:343 **and** vw:420; stamp vw:285 | — |
| INV-45 end-time overflow | ✅ Runtime | ls:105 `EScheduleOverflow` | boundary tested |
| INV-46 deposit overflow guard | ✅ Runtime | `deposit` `EOverflow` (vw, code=3) | added post-review; resolves INF-2 |

**INV-38 note (resolves the doc's open concern):** the relaxation from "abilityless
hot potato" to `drop`-only is intentional and safe. `release` reads `wallet.released`
fresh and pays `amount - released`, so re-using or dropping the same attestation
pays nothing after the first; INV-44 blocks cross-wallet reuse. The module docs
(vw:123-168) justify this at length (it lets a curve-agnostic wrapper expose `&inner`
without `&mut`). No action needed — the `invariants.md` "confirm intentional" flag
can be closed.

## Findings

### Critical
None.

### High
None.

### Medium
None.

### Informational

#### INF-1: `linear_schedule::destroy` checks `ENotEnded` after consuming the wallet

**Location:** `linear_schedule::destroy()` ls:175-179
**Invariant:** INV-9

**Issue:** `destroy_empty(Linear {})` consumes the wallet and returns `Params`
*before* the `assert!(now >= start_ms + duration_ms, ENotEnded)` runs. Because Move
transactions are atomic a failing assert rolls the whole call back, so behavior is
correct — but the check reads as if teardown could partially proceed.

**Impact:** None functionally (atomic rollback). Readability/defensive-clarity only.

**Recommendation:** Read `end` from the wallet and assert *before* destroying:
```move
public fun destroy<C>(wallet: VestingWallet<Linear, Params, C>, clock: &Clock) {
    assert!(clock.timestamp_ms() >= wallet.end(), ENotEnded);
    let Params { .. } = wallet.destroy_empty(Linear {});
}
```
This is already flagged in `invariants.md` Dev Notes; the dev may also reconsider
whether the `ENotEnded` gate should exist at all (only `balance == 0` is strictly
required — the gate is a heuristic against front-running a pending deposit, which it
narrows but cannot eliminate, since late deposits are out of scope anyway).

**Status:** Open

---

#### INF-2: `balance + released` could overflow u64 → permanent fund-trap (RESOLVED)

**Location:** `vesting_wallet::deposit()` (guard); `linear_schedule::vested_amount_raw()` ls:217 (where it would have surfaced)
**Invariant:** INV-46 (new) / INV-16

**Issue:** `balance()` and `released()` each fit u64, but their **sum** is the
invariant `Σ(deposits)` (INV-16). A release-then-redeposit cycle could push
`balance + released` to `u64::MAX + 1`. Re-analysis during discussion found the
failure mode is worse than a transient DoS: the overflowing deposit would *succeed*,
then `vested_amount_raw`'s `balance + released` would abort on every subsequent call
— `release`/`releasable`/`destroy` all unreachable — **permanently trapping the
entire balance**. `deposit` is permissionless, so a near-`u64::MAX` wallet could be
tipped over by anyone.

**Resolution (implemented):** Added a `deposit`-time guard
`assert!(u64::MAX - balance - released >= amount, EOverflow)` (`EOverflow`, code=3),
codified as **INV-46**. The offending deposit is now rejected up front: a direct
depositor keeps their coin (tx rolls back) and the wallet stays operational. Pinned
by `vesting_wallet_tests::deposit_rejects_overflowing_total` and the reframed
`linear_schedule_tests::overflowing_refund_is_rejected_at_deposit`.

**Residual (accepted, documented):** a coin already `public_transfer`'d to the
wallet's address that overflows on `receive_and_deposit` is stranded at that address
(`Receiving` doesn't expose the sender, and any permissionless extraction would be a
funding-siphon). This is the same Out-of-Scope class as "late deposits after
`destroy_empty`"; the guard contains the blast radius to that one coin. Documented on
`receive_and_deposit` and in `invariants.md` Out of Scope.

**Status:** Fixed

---

#### INF-3: Section-header names deviate from STYLEGUIDE and repo convention

**Location:** `vesting_wallet.move` (`// === Types ===` :103, `// === Primitive ===`
:210, `// === Views and accessors ===` :402); `linear_schedule.move`
(`// === Types ===` :54, `// === Accessors ===` :182)

**Issue:** STYLEGUIDE §"Section ordering" specifies `// === Structs ===` (item 4),
`// === Public Functions ===` (8), `// === View helpers ===` (9),
`// === Private Functions ===` (12). The new files use `Types` (only these 2 files
in the whole repo; 28 other files use `Structs`), and replace the `Public Functions`
parent with feature names (`Primitive` / `Constructors` / `Curve evaluation`) with no
top-level `Public Functions` header. `Views and accessors` / `Accessors` vs
`View helpers`. (`// === Internal ===` is fine — used 12× elsewhere.)

**Impact:** Style consistency only; no functional effect.

**Recommendation:** Rename to the canonical headers, or run `/code-quality` for a
full style pass (that command is the proper owner of fine-grained style).

**Status:** Open

---

#### INF-4: Doc-comment structure inconsistent across public functions

**Location:** `vesting_wallet::deposit` (vw:294), `receive_and_deposit` (vw:305), the
accessors (vw:425-446); `linear_schedule::release` (ls:143), `vested_amount` (ls:126)

**Issue:** STYLEGUIDE §Documentation asks public functions to carry at least
`#### Parameters` / `#### Returns` (and `#### Aborts` when they can abort). `new`,
`release`, `destroy_empty`, and `linear_schedule::new`/`destroy` follow this fully,
but `deposit`, `receive_and_deposit`, the four primitive accessors, and
`linear_schedule::release`/`vested_amount`/`releasable` have only a prose line. Also
`vested_amount`/`release`/`releasable` can abort on the INF-2 overflow path but carry
no `#### Aborts`.

**Impact:** Documentation polish; no functional effect.

**Recommendation:** Add the structured sections for consistency, or defer to
`/code-quality`. Low priority for trivial getters.

**Status:** Open

---

#### INF-5: No end-to-end linear multi-release across advancing clocks

**Location:** `linear_schedule_tests.move`
**Invariant:** INV-15 / INV-25 (composition)

**Issue:** The linear suite releases once per test (`release_pays_linear_portion` at
t=400; `full_release_after_end`). Monotonic multi-release is covered only with the
synthetic `TestCurve` (`release_is_monotone_across_increasing_totals`), and the linear
*curve shape* is checked via the `vested()` view. The natural headline scenario —
release the linear delta at t1, advance the clock, release the next delta at t2 — is
not exercised end-to-end through the real curve.

**Impact:** Low — both halves are covered; only their composition is implicit. BTT
deemed it redundant (Out-of-Scope, "Linear two-installment release").

**Recommendation:** Optional. A short test (release at t=250 → assert 250, advance to
t=750 → release → assert delta 500, ledger conserved) would make the flagship use
case explicit.

**Status:** Open

## Security Checklist Results

| Category | Result | Notes |
|----------|--------|-------|
| 3.1 Access control | ✅ Pass | Authority is type-level: `new` consumes `P` by value, `mint_vested_amount`/`destroy_empty` consume `_w: S` — only the declaring curve module holds these. `release`/`deposit`/`releasable` are intentionally permissionless (INV-31). |
| 3.2 Object safety | ✅ Pass | Wallet has no `drop` (must `destroy_empty`); `Balance<C>` encapsulated, no `&mut`/`&` leak; `destroy_empty` destructures and `destroy_zero`s the balance, `delete`s the UID. No dynamic fields. `VestedAmount.wallet_id` binds attestations to one instance (INV-44). |
| 3.3 Arithmetic safety | ✅ Pass | Curve uses u128 intermediate (INV-26); `now-start` guarded by pre-start branch; `start+cliff`/`start+duration` guarded by INV-45; `released+releasable == vested.amount ≤ total` (no overflow). Only edge: `balance+released` sum can overflow → safe abort (**INF-2**). Division guarded by `EZeroDuration`. |
| 3.4 Type safety | ✅ Pass | `S,P,C` carried through all sigs; `S` phantom but minting requires constructing `S` (module-private); `VestedAmount<S>` drop-only, no `key/store/copy`; witness pattern correct. Foreign module can name `<Linear, ForeignParams, C>` but cannot mint `VestedAmount<Linear>` → inert, not exploitable (per INV-37 subtlety). |
| 3.5 Reentrancy / composability | ✅ Pass | `release` updates `released` before `balance.split`/transfer (check-effects-interaction); Move has no re-entrancy. `public_transfer` to an address has no callback. Returns-by-value enable single-PTB composition (INV-32). |
| 3.6 Economic security | ✅ Pass | Conservation holds on every path (INV-28): no mint, value-preserving `split`/`from_balance`, empty-balance destroy gate. Trusted `amount` in `mint_vested_amount` is bounded by the `>=` assert + `balance.split` abort and per-wallet binding (INV-36/44); a dishonest curve can only brick or over-draw *its own* wallet's balance, never another. No oracle/sandwich surface. |
| 3.7 Upgrade safety | ✅ Pass | Public API is minimal and value-returning. `public(package)` not needed (it's a library). Note (not a finding): `error(code=N)` constants are append-only per STYLEGUIDE — preserve numbering on future edits. Shared-object layout is stable (single `Balance` + scalars + typed `P`). |

## Test Coverage Assessment

- **48/48 pass** (`sui move test --build-env testnet`); lint clean under
  `--warnings-are-errors`. Artifacts claim 100% line coverage on both modules.
- Every live invariant has ≥1 runtime test or is 🔒 compile-enforced with positive
  coverage (verified against `tests.md` coverage matrix + BTT tree).
- The 3 uncommitted "Early-release resistance" tests (`release_before_cliff_moves_no_funds`,
  `retroactive_deposit_never_over_releases`, `balance_plus_released_overflow_bricks_release_not_overpays`)
  are strong additions — they pin the pre-cliff zero-payout region with non-zero
  `start_ms`, the retroactive-deposit boundedness, and the INF-2 safe-abort. **Commit
  them** (and reflect in `tests.md`).
- Gaps: only **INF-5** (linear multi-release over time), low severity.

## Artifact Drift

- **Artifact:** `vesting-wallet-artifacts/invariants.md` → **Stale:** references a
  "`QUESTION` comment in `mint_vested_amount`" (lines 1369, 1491) and a "`QUESTION`
  comment in the code about whether this gate should exist" in `destroy` (line 1500)
  → **Current:** source has **no** `QUESTION`/`TODO`/`FIXME` comments (the markers
  were replaced with explanatory prose) → **Suggested update:** reword to "as the
  rationale comment in `mint_vested_amount`/`destroy` explains" — the answers are now
  inline, not open questions.
- **Artifact:** `invariants.md` → **Stale:** INV-38 body (line ~1276) and Dev Notes
  (~1494-1497) say to "confirm intentional (see Open Questions)" → **Current:** Open
  Questions section says "None" (dangling cross-reference); the `drop` relaxation is
  intentional → **Suggested update:** drop the "see Open Questions" pointer and mark
  the relaxation confirmed (see INV-38 note above).
- **Artifact:** `invariants.md` → **Stale:** file begins at `## Summary` with no YAML
  frontmatter → **Current:** `tests.md` and `btt-coverage.md` both carry the standard
  frontmatter block → **Suggested update:** add the `stage: invariants` frontmatter
  header for consistency/parseability.
- **Artifact:** `vesting-wallet-artifacts/tests.md` → **Stale:** headline "45 tests"
  and Test Plan / Coverage Matrix omit the 3 uncommitted early-release tests →
  **Current:** working tree has 48 tests → **Suggested update:** bump to 48 and add
  the three rows once the tests are committed.

## Extension Mode: Compatibility Check
N/A — greenfield feature (new modules in the `openzeppelin_finance` package). The only
edits to existing files are additive `#[test_only]` helpers; no existing API changed.

## Recommendation

- **Overall verdict:** **Ready for publishing.** The implementation is correct,
  conservative, and well-tested; authority is enforced structurally rather than by
  runtime checks.
- **Blocking issues:** None.
- **Suggested improvements (non-blocking):**
  1. Commit the 3 early-release tests and update `tests.md` (48 tests).
  2. Reorder the `ENotEnded` assert before `destroy_empty` (INF-1).
  3. Sync the 4 `invariants.md` / `tests.md` drift items.
  4. Run `/code-quality` for the section-header / doc-section style items (INF-3, INF-4).
  5. Optionally add a linear multi-release-over-time test (INF-5).

## Out of Scope

- **Research / Design / Code / Docs stage artifacts** — not present on disk; not
  reviewed. Invariants was the checklist; design intent inferred from module docs.
- **Fine-grained STYLEGUIDE enforcement** — INF-3/INF-4 are surfaced, but a full
  style audit is the `/code-quality` command's job, not this pass.
- **Custom downstream curve correctness** — INV-20..27 are reviewed only for the
  built-in `Linear` curve; downstream curves owe their own shape tests (INV-36 is the
  only contract the wallet imposes).
- **Framework-level behaviors** — `transfer::public_receive` addressing (INV-5
  negative), `balance::join` aggregate-deposit overflow, two-transaction consensus
  race (INV-34): trusted to the Sui framework, consistent with the invariants doc.
- **Gas/throughput** — no performance review; correctness and security only.

## Dev Notes

The code is genuinely clean — this is a "no code bugs" result, consistent with what
the Tests and BTT stages reported. The structural-authority design (P-by-value for
construction, S-witness for minting, `wallet_id` stamp for redemption) is the
strongest part: it makes "wrong/missing params" and "cross-wallet redemption"
unrepresentable rather than runtime-checked. The only genuinely substantive
edge — the `balance + released` overflow — fails safe and is now pinned by a test.
Everything else is doc-sync and style polish.

## Open Questions

- Keep the `ENotEnded` gate on `destroy`, or reduce teardown to the `balance == 0`
  requirement only? (INF-1 — design call, not a correctness issue.)
- Should the 4 artifact-drift fixes be applied now (I can propose the exact edits),
  or deferred to a doc-sync pass?

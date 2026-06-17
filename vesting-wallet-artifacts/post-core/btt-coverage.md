---
stage: review
project: vesting-wallet
mode: greenfield
extends: null
status: complete
timestamp: 2026-06-17
author: 0xNeshi
previous_stage: vesting-wallet-artifacts/tests.md
tags: [btt, coverage, post-core]
---

# Vesting Wallet — BTT Coverage Report

## Summary

55 runtime tree leaves across 22 public functions in two modules, plus ~6
compile-/framework-enforced leaves (🔒, positive-covered only — negatives are
unrepresentable in-package).

- **Before:** 55 runtime leaves — **49 ✅, 1 ◐, 1 ⚠️, 4 ❌**.
- **After:** 55 runtime leaves — **54 ✅, 0 ◐, 1 ⚠️, 0 ❌**.

**5 additions landed (P1–P5), 0 rejected:** 4 new tests, 1 modification, 1
test-only helper. Test count 41 → 45; all pass; `sui move build --lint
--warnings-are-errors` clean. The remaining single ⚠️ is the shared-object
concurrent-release idempotency stand-in (the 2-tx race is documented OOS, not a
fillable gap). **Verdict: tight** — the one genuine failure-path gap (`release`
boundedness abort) is now pinned.

## Source-Derived Leaf List (from Step 2.0)

`assert!` sites (every one maps to a backing invariant):

| Site | Code | INV |
|---|---|---|
| [vesting_wallet.move:335](../../contracts/finance/sources/vesting_wallet.move#L335) | `wallet_id == object::id(wallet)` → `EWalletMismatch` | INV-44 |
| [vesting_wallet.move:336](../../contracts/finance/sources/vesting_wallet.move#L336) | `*vested_amount >= wallet.released` → `EVestedBelowReleased` | INV-19 / INV-36 |
| [vesting_wallet.move:373](../../contracts/finance/sources/vesting_wallet.move#L373) | `balance.value() == 0` → `ENotEmpty` | INV-10 |
| [vesting_wallet.move:412](../../contracts/finance/sources/vesting_wallet.move#L412) | `wallet_id == object::id(wallet)` → `EWalletMismatch` (view) | INV-44 |
| [vesting_wallet.move:413](../../contracts/finance/sources/vesting_wallet.move#L413) | `*vested_amount >= wallet.released` → `EVestedBelowReleased` (view) | INV-19 |
| [linear_schedule.move:103](../../contracts/finance/sources/linear_schedule.move#L103) | `duration_ms > 0` → `EZeroDuration` | INV-6 |
| [linear_schedule.move:104](../../contracts/finance/sources/linear_schedule.move#L104) | `cliff_ms <= duration_ms` → `EInvalidCliff` | INV-7 |
| [linear_schedule.move:105](../../contracts/finance/sources/linear_schedule.move#L105) | `duration_ms <= u64::MAX - start_ms` → `EScheduleOverflow` | INV-45 |
| [linear_schedule.move:179](../../contracts/finance/sources/linear_schedule.move#L179) | `clock.timestamp_ms() >= start_ms + duration_ms` → `ENotEnded` | INV-9 |

Implicit guard (not an `assert!`): [vesting_wallet.move:339](../../contracts/finance/sources/vesting_wallet.move#L339) `if (releasable == 0) return;` → INV-11.

`event::emit` sites (all in `vesting_wallet`; `linear_schedule` delegates, emits none) — all tagged `<S, ...>`:

| Site | Event | INV |
|---|---|---|
| [vesting_wallet.move:231](../../contracts/finance/sources/vesting_wallet.move#L231) | `Created<S, P, C>` | INV-12 |
| [vesting_wallet.move:294](../../contracts/finance/sources/vesting_wallet.move#L294) | `Deposited<S, C>` | INV-12 |
| [vesting_wallet.move:346](../../contracts/finance/sources/vesting_wallet.move#L346) | `Released<S, C>` | INV-12 |
| [vesting_wallet.move:389](../../contracts/finance/sources/vesting_wallet.move#L389) | `Destroyed<S, C>` | INV-12 |

No unmapped `assert!`, no unbacked invariant (besides the two stale-doc deviations below).

## Branching Tree

```
vesting_wallet::new<S,P,C>
├── happy → init {balance=0, released=0, beneficiary, id}, emit Created{id,bene,params} ✅ new_initializes_fields_and_emits_created
├── key+store → owned topology (public_transfer) ✅ new_supports_owned_topology
└── key+store → shared topology (public_share_object) ✅ create_and_share_shares_wallet
mint_vested_amount<S,P,C>
├── witness-gated mint, stamps wallet_id+amount, drop read-by-ref ✅ mint_stamps_*
└── foreign module mints → 🔒 compile (OOS)
amount<S> (view) → reads without consuming ✅ mint_stamps_*
deposit<S,P,C> → balance↑, Deposited{id,amount}, permissionless, conserved ✅ deposit_increases_*
receive_and_deposit<S,P,C>
├── claims addressed coin, single Deposited (no Received), conserved ✅ receive_and_deposit_claims_*
└── receipt addressed elsewhere → framework abort (OOS)
release<S,P,C>
├── given match / vested>released / releasable>0 → pays bene, released=vested, Released{...} ✅ release_pays_releasable_*
├── given releasable==0 → no-op (no event/state/abort) ✅ release_is_noop / release_again_at_same_total
├── given wallet_id mismatch → EWalletMismatch ✅ release_rejects_vested_from_other_wallet
├── given vested<released → EVestedBelowReleased ✅ release_rejects_vested_below_released
├── given vested>balance+released → abort on balance.split ✅ release_aborts_when_vested_exceeds_total  [P1]
├── monotone across increasing totals ✅ release_is_monotone_*
├── pays fixed beneficiary after owned handoff ✅ owned_handoff_*
└── released coins out of reach (no clawback) ✅ released_coins_stay_*
releasable<S,P,C> (view)
├── returns vested-released ✅ mint_stamps / releasable_view_matches_release
├── wallet_id mismatch → EWalletMismatch ✅ releasable_rejects_vested_from_other_wallet
├── vested<released → EVestedBelowReleased ✅ releasable_rejects_vested_below_released
└── post-release → 0 ✅ releasable_view_matches_release / full_release_after_end
destroy_empty<S,P,C>
├── given balance==0 → returns P, Destroyed{...}, witness-gated ✅ destroy_empty_returns_params / destroy_after_end
└── given balance>0 → ENotEmpty ✅ destroy_empty_rejects_nonempty_balance
accessors schedule_params/beneficiary/released/balance → correct + immutable ✅ new_initializes / beneficiary_params_and_id_are_immutable
ledger conservation (balance+released=Σdeposits) ✅ deposit_*/release_*/monotone
```
```
linear_schedule::new<C>
├── duration==0 → EZeroDuration ✅ new_rejects_zero_duration
├── cliff>duration → EInvalidCliff ✅ new_rejects_cliff_exceeding_duration
├── cliff==duration → accepted (boundary) ✅ new_accepts_cliff_equal_to_duration  [P2]
├── start+duration overflow → EScheduleOverflow ✅ new_rejects_schedule_overflow
├── start+duration==u64::MAX → accepted ✅ new_accepts_end_at_u64_max_boundary
└── happy → sets params, emit Created (full payload) ✅ new_sets_params_and_emits_created  [P4]
create_and_share<C> → shares wallet ✅ create_and_share_shares_wallet
vested_amount<C> / vested_amount_raw
├── now<start → 0 ✅ vested_amount_pre_start_is_zero
├── now==start exactly (elapsed=0) → 0 ✅ vested_amount_at_exact_start_is_zero  [P5]
├── cliff>0 & pre-cliff → 0 ✅ vested_amount_pre_cliff_is_zero
├── cliff boundary → total*cliff/duration ✅ vested_amount_at_cliff_jumps
├── mid-schedule → total*(now-start)/duration ✅ vested_amount_is_linear_mid_schedule
├── post-end → clamp to total ✅ vested_amount_post_end_clamps
├── non-decreasing in time ✅ vested_amount_is_nondecreasing
├── u128 intermediate at max ✅ vested_amount_uses_u128_intermediate_at_max
└── late deposit vests from start ✅ deposit_vests_as_if_from_start
release<C> → mid pays linear (permissionless) ✅ release_pays_linear_portion │ idempotent same clock ✅ release_then_release_* │ full after end ✅ full_release_after_end │ one-PTB ✅ create_deposit_release_in_one_flow
releasable<C> (view) → matches release, 0 after ✅ releasable_view_matches_release / full_release_after_end
destroy<C>
├── empty & ended → tears down + Destroyed ✅ destroy_after_end (clock==end boundary)
├── before end → ENotEnded ✅ destroy_rejects_before_end
└── nonempty → ENotEmpty (balance gate fires first) ✅ destroy_rejects_nonempty_balance
accessors start/duration/end/cliff → correct values ✅ new_sets_params / new_accepts_end
composability: permissionless ✅ | single-PTB new+deposit+release ✅ | receive_and_deposit+release one tx ✅ receive_and_deposit_then_release_in_one_flow [P3] | bene any address ✅ | concurrent ⚠️ idempotency stand-in (2-tx race OOS) | owned handoff ✅
type-level INV-1/2/4/37/38/39 → 🔒 compile (positive-covered)
```

## Coverage Map

Only the rows that were non-✅ before this pass (all other 49 leaves were ✅ and
unchanged):

| Function | Branch | Covered by | Confidence |
|---|---|---|---|
| `release` | given vested.amount > balance + released / it aborts on `balance.split` | `release_aborts_when_vested_exceeds_total` | ❌ → ✅ |
| `linear::new` | given cliff_ms == duration_ms / it constructs | `new_accepts_cliff_equal_to_duration` | ❌ → ✅ |
| `receive_and_deposit`+`release` | claim addressed coin then release in one tx | `receive_and_deposit_then_release_in_one_flow` | ❌ → ✅ |
| `vested_amount` | given now == start_ms exactly (elapsed=0) / it is 0 | `vested_amount_at_exact_start_is_zero` | ❌ → ✅ |
| `linear::new` | it emits `Created` with correct payload | `new_sets_params_and_emits_created` (+ `test_params` helper) | ◐ → ✅ |
| `linear::release` | shared concurrent release safe | `release_then_release_at_same_clock_is_noop` | ⚠️ (idempotency stand-in; 2-tx race OOS — no action) |

## Design Deviations

Both are cases where `invariants.md` describes a *superseded* code state; the code
is ahead and the tests pin current behavior. (Items 1–2 of the Tests stage's
"Upstream Sync"; Open Questions 1–3 were already removed from the doc, these two
notes were not.)

1. **INV-12 code-note + violation clause** ([invariants.md:416-426](../invariants.md#L416-L426), :441) claims `deposit`/`release`/`destroy_empty` emit `<P, C>` with `P` in the phantom `S` slot. Current code emits `<S, C>` for all four ([vesting_wallet.move:294/346/389](../../contracts/finance/sources/vesting_wallet.move#L294)). The event-tag inconsistency the note warns about no longer exists. Acceptable because the tests assert full event-value equality against the `<S, C>` shape.
2. **INV-19 statement + code-note + matrix row** ([invariants.md:650](../invariants.md#L650), [:659-664](../invariants.md#L659-L664), :1429) says `releasable` does a "bare subtraction… no preceding `>=` assert" and INV-19's runtime check is "a bare assert — no named error constant." Current code guards both `release` and `releasable` with the named `EVestedBelowReleased` ([vesting_wallet.move:336/413](../../contracts/finance/sources/vesting_wallet.move#L336)). Acceptable because the tests pin the typed abort on both paths (`release_rejects_vested_below_released`, `releasable_rejects_vested_below_released`).

## Additions Written

### release_aborts_when_vested_exceeds_total
**Type:** New test
**File:** `contracts/finance/tests/vesting_wallet_tests.move` (Release accounting section, before `// === Teardown ===`)
**Pins:** `release` / given vested.amount > balance + released / it aborts before any payout
**Confidence change:** `❌ → ✅`
**Verifies:** INV-36 (unbounded-curve violation), INV-28 (conservation — no over-release)
**Severity at proposal time:** High
**Note:** the abort is `sui::balance::split`'s insufficient-balance check (private framework const), so the test uses bare `#[expected_failure]` — it pins "it aborts," not a typed code.
```move
// INV-36 (boundedness) / INV-28: a curve that attests more than `balance + released`
// aborts `release` at the framework `balance.split` — no payout, no `Released` event,
// atomic rollback. (Framework abort, so no library-typed code to match on.)
#[test, expected_failure]
fun release_aborts_when_vested_exceeds_total() {
    let mut ctx = tx_context::dummy();

    let mut wallet = new_wallet(BENEFICIARY, &mut ctx);
    wallet.deposit(mint(100, &mut ctx));

    // Attest more than balance + released (= 100). `release` clears the wallet_id and
    // `>= released` guards, then `balance.split(200)` aborts before any coin is minted.
    let vested = wallet.mint_vested_amount(TestCurve {}, 200);
    wallet.release(&vested, &mut ctx);
    abort
}
```

### new_accepts_cliff_equal_to_duration
**Type:** New test
**File:** `contracts/finance/tests/linear_schedule_tests.move` (Construction guards section)
**Pins:** `linear::new` / given cliff_ms == duration_ms / it constructs (accept edge of `<=`)
**Confidence change:** `❌ → ✅`
**Verifies:** INV-7 (cliff <= duration accepted at equality); incidentally the cliff==end corner of INV-23/24
**Severity at proposal time:** Medium
```move
// INV-7 (accept boundary): cliff == duration is allowed; nothing vests until the end,
// then the curve jumps straight to the full total.
#[test]
fun new_accepts_cliff_equal_to_duration() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_linear(0, 1000, 1000, test.ctx());
    fund(&mut wallet, 1000, test.ctx());

    clk.set_for_testing(999);
    assert_eq!(vested(&wallet, &clk), 0); // still gated by the cliff
    clk.set_for_testing(1000);
    assert_eq!(vested(&wallet, &clk), 1000); // cliff boundary == end: total * 1000 / 1000

    destroy(wallet);
    teardown(test, clk);
}
```

### receive_and_deposit_then_release_in_one_flow
**Type:** New test
**File:** `contracts/finance/tests/linear_schedule_tests.move` (Composability section, end of file)
**Pins:** `receive_and_deposit` + `release` compose in one transaction
**Confidence change:** `❌ → ✅`
**Verifies:** INV-32 (single-PTB composition variant), INV-5 (claim coin addressed to the wallet)
**Severity at proposal time:** Medium
```move
// INV-32 / INV-5: receive_and_deposit + release compose in a single transaction — the
// emission-schedule / payroll path where a coin is claimed from the wallet's address
// and the vested portion is released in one go.
#[test]
fun receive_and_deposit_then_release_in_one_flow() {
    let mut test = test_scenario::begin(@0x1);
    let mut clk = clock::create_for_testing(test.ctx());

    let wallet = new_linear(0, 0, 1000, test.ctx());
    let wallet_addr = object::id_address(&wallet);
    transfer::public_share_object(wallet);

    // An upstream emitter sends a coin to the wallet's object address.
    test.next_tx(@0x1);
    let coin = coin::mint_for_testing<USDC>(1000, test.ctx());
    let coin_id = object::id(&coin);
    transfer::public_transfer(coin, wallet_addr);

    // One transaction: claim the coin AND release the vested portion.
    test.next_tx(@0x1);
    let mut wallet = test.take_shared<VestingWallet<Linear, Params, USDC>>();
    let receiving = test_scenario::receiving_ticket_by_id<coin::Coin<USDC>>(coin_id);
    wallet.receive_and_deposit(receiving);
    clk.set_for_testing(500);
    linear_schedule::release(&mut wallet, &clk, test.ctx());

    assert_eq!(wallet.released(), 500);
    assert_eq!(wallet.balance(), 500);

    test_scenario::return_shared(wallet);
    destroy(clk);
    test.end();
}
```

### vested_amount_at_exact_start_is_zero
**Type:** New test
**File:** `contracts/finance/tests/linear_schedule_tests.move` (Curve shape section, after `vested_amount_pre_start_is_zero`)
**Pins:** `vested_amount` / given now == start_ms exactly, no cliff / it is 0 (elapsed=0 edge)
**Confidence change:** `❌ → ✅`
**Verifies:** INV-25 (linear branch lower boundary)
**Severity at proposal time:** Low
```move
// INV-25 (lower boundary): at now == start_ms with no cliff the elapsed time is 0,
// so the curve reads exactly 0 — the lower edge of the linear branch.
#[test]
fun vested_amount_at_exact_start_is_zero() {
    let (mut test, mut clk) = setup(0);

    let mut wallet = new_linear(1000, 0, 1000, test.ctx());
    fund(&mut wallet, 1000, test.ctx());

    clk.set_for_testing(1000); // now == start_ms, elapsed == 0
    assert_eq!(vested(&wallet, &clk), 0);

    destroy(wallet);
    teardown(test, clk);
}
```

### new_sets_params_and_emits_created (+ test_params helper)
**Type:** Modification to existing test + new `#[test_only]` helper
**File:** `contracts/finance/tests/linear_schedule_tests.move` (test) and `contracts/finance/sources/linear_schedule.move` (helper)
**Pins:** `linear::new` / it emits `Created` with correct `{wallet_id, beneficiary, schedule_params}`
**Confidence change:** `◐ → ✅`
**Verifies:** INV-12 (Created payload), INV-14
**Severity at proposal time:** Medium
**Helper added to `linear_schedule.move`** (`Params` fields are module-private, so tests cannot build one directly):
```move
// === Test-Only Helpers ===

/// Build a `Params` value for asserting against `event::events_by_type` (the
/// `Params` fields are module-private, so tests cannot construct one directly).
#[test_only]
public fun test_params(start_ms: u64, cliff_ms: u64, duration_ms: u64): Params {
    Params { start_ms, duration_ms, cliff_ms }
}
```
**Test change** (replaced the cardinality-only assert with a full payload assertion):
```move
    assert_eq!(linear_schedule::end(&wallet), 1100);

    let created = event::events_by_type<Created<Linear, Params, USDC>>();
    assert_eq!(created.length(), 1);
    assert_eq!(
        created[0],
        vesting_wallet::test_new_created<Linear, Params, USDC>(
            object::id(&wallet),
            BENEFICIARY,
            linear_schedule::test_params(100, 250, 1000),
        ),
    );
```

## Rejections (Intentional Gaps)

None — all five proposals (P1–P5) were accepted.

## Out of Scope

### Deferred (will revisit)

None.

### Not Applicable (closed)

- **Type-level negatives (INV-1, INV-37 mint/build gate, INV-38 no store/key/copy, INV-39 curve pinning).** A violating snippet does not compile, so it cannot live in the package's test suite; positive directions execute. Closed unless the repo adopts an expected-compile-failure harness.
- **INV-5 negative (receipt addressed elsewhere).** Framework-enforced by `transfer::public_receive`; positive path tested.
- **INV-34 two-transaction concurrent race.** Requires real consensus ordering; not deterministically reproducible in `test_scenario`. Covered by the same-clock idempotency stand-in (`release_then_release_at_same_clock_is_noop`) — the remaining ⚠️.
- **`u64` aggregate-deposit overflow (`balance::join`).** Framework abort, no typed error; the depositor bounds their own accumulation. (Distinct from the *schedule* end-time overflow INV-45, which is tested, and from `release`'s split-underflow boundedness abort INV-36, which P1 now pins.)
- **Custom-curve schedule shapes (downstream).** INV-20..27 are tested only for the built-in `Linear` curve; downstream curves owe their own shape tests (INV-36 is the only contract the wallet imposes).
- **Linear two-installment release across advancing clocks.** Helper-equivalent to the primitive `release_is_monotone_across_increasing_totals` (TestCurve) plus the linear single-release tests; no new behavior to pin.

## Cascade Plan

| Artifact | Edit |
|---|---|
| `vesting-wallet-artifacts/invariants.md` | Remove the stale INV-12 code-note ([:416-426](../invariants.md#L416-L426)) and the "inconsistent type-argument tag" clause ([:441-442](../invariants.md#L441)); all four events are `<S, C>` in code. |
| `vesting-wallet-artifacts/invariants.md` | Update INV-19 runtime-check wording ([:650](../invariants.md#L650)) and remove the asymmetry code-note ([:659-664](../invariants.md#L659-L664)) to name `EVestedBelowReleased` on both `release` and `releasable`; fix the matrix row "INV-19 (bare subtraction)" ([:1429](../invariants.md#L1429)). |
| `vesting-wallet-artifacts/invariants.md` | (Optional) Note INV-36's unbounded-curve violation path is now directly tested (`release_aborts_when_vested_exceeds_total`) rather than only documented. |
| `vesting-wallet-artifacts/tests.md` | Update headline (41 → 45 tests) and add the five new rows to the Test Plan / Coverage Matrix; remove the now-resolved "Upstream Sync" section. |

These were offered during this run; the dev confirmed Open Questions 1–3 were already removed but the two code-notes above remain in the doc.

## Revision Log (revision mode only)

N/A — first BTT run for this project.

## Dev Notes

- The suite was already tight (49/55 ✅). The one substantive find was the
  `release` boundedness abort (INV-36 unbounded curve → `balance.split` abort),
  the only one of `release`'s three documented abort paths that was untested.
- P4 added a `#[test_only] linear_schedule::test_params` constructor (mirroring
  the four `#[test_only]` event constructors already in `vesting_wallet.move`),
  so the linear `Created` event can be asserted by full value rather than
  cardinality-only. This is defense-in-depth — the primitive's `new_initializes_*`
  test already pins the `Created` emission+fields, and `linear::new` delegates to
  `vesting_wallet::new`.
- All 45 tests pass; `sui move test --build-env testnet` green;
  `sui move build --lint --warnings-are-errors` clean.

## Open Questions

None blocking. The Cascade Plan edits to `invariants.md` / `tests.md` are
documentation-consistency follow-ups and do not affect any test or guarantee.

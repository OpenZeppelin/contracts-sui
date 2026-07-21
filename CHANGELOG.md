<!-- markdownlint-disable MD024 -->

# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)

## Unreleased

### `openzeppelin_finance`

#### Added

- `vesting_wallet`: new `VestingSchedule<W, P>` type bundling a curve's schedule params with its witness, plus a `new_schedule` constructor and `params` accessor. Lets a curve-agnostic consumer accept a witness-pinned schedule that keeps its witness and params type arguments coherent. (#489)
- `vesting_wallet_linear`: `vesting_schedule` and `vesting_schedule_continuous` constructors that validate and bundle a stepped/continuous `Params` into a `VestingSchedule<Linear, Params>`, plus `into_vesting_schedule` to wrap an already-built `Params`. (#489)

### `openzeppelin_sale`

#### Added

- new getter `max_sale_duration_ms`. (#488)
- `prefunded_sale::mint_quote_unversioned`: a witness-gated quote constructor that opts out of freshness, for curves whose price is immune to sale-state changes (e.g. `fixed_rate_curve`); lets several quotes be minted and purchased in one PTB. (#499)

#### Changed (Breaking)

- `prefunded_sale`: `Quote`s minted via `mint_quote` are now freshness-enforced. `mint_quote` stamps the sale's new `state_version`, every `purchase` advances it, and `purchase` aborts with the new `EStaleQuote` if an intervening same-PTB purchase advanced it since the quote was minted. Adds a `state_version` field to `PrefundedSale` and `minted_at_version` to `Quote`. (#499)
- `prefunded_sale::mint_quote` now takes a precomputed `allocation: u64` instead of `rate: u64`; aborts if the curve-computed allocation is zero. (#487)
- Moved the `allocation = paid * rate` overflow check (and the `EAllocationOverflow` error) from `prefunded_sale` into `fixed_rate_curve`, where the multiplication now lives. (#487)
- `prefunded_sale`: `EAllocationOverflow` (code `13`) is no longer emitted - its `paid * rate` overflow check moved to `fixed_rate_curve` - and its code is retired rather than reused; `ERaisedOverflow`, `EHardCapExceeded`, and `EInsufficientInventoryAtActivate` keep their existing codes `10`/`11`/`12`. A new `EZeroAllocation` error is appended at code `42`. (#487)
- `prefunded_sale`: renamed `VestingScheduleParamsSet -> VestingScheduleSet`, adding the `VestingWitness` type param; renamed `set_vesting_schedule_params -> set_vesting_schedule`, which now accepts the `VestingSchedule<VestingWitness, VestingScheduleParams>` parameter instead of just `VestingScheduleParams`; renamed getter `vesting_schedule_params -> vesting_schedule`. (#489)
- set a maximum sale duration cap `prefunded_sale::create_sale`, aborts with `ESaleDurationTooLong`. (#488)
- `prefunded_sale::SaleCreated` event's `CurveParams` type parameter moved to the end, and added `Curve` type parameter. (#491)
- `prefunded_sale`: aligned every abort message and doc comment with the guard that raises it, splitting error codes that conflated two predicates. `pair_refund_vault`'s wrong-cap check now raises a dedicated `EWrongVaultCap` (distinct from `EWrongVault`); `cancel_after_close`'s window check raises `ESaleNotClosed` (distinct from `finalize`'s `ESaleWindowStillOpen`); and the shared `ESoftCapMet` is replaced by `ESoftCapNotSet` and `ESoftCapReached`. `EActivationAfterClose`'s message now reflects its inclusive `now >= closes_at_ms` guard. (#498)

## 1.5.0 (17-07-2026)

### `openzeppelin_timelock`

#### Added

- New `timelock` module: a Sui-native `TimelockController` enforcing a minimum on-chain delay before a privileged operation executes. (#409)

### `openzeppelin_fp_math`

#### Added

- `cdf`: the standard-normal cumulative distribution function `Φ(z)` for `UD30x9` and `SD29x9` fixed-point inputs. (#345)

#### Changed

- `cdf` / `pdf`: raised the internal evaluation precision to `10^36`, making both functions monotone between every pair of adjacent representable inputs, and clamped their domains to the analytic saturation points (`6.109410205` / `6.402729806`). Gas, storage, and the public API are unchanged. (#431)

### `openzeppelin_sale`

#### Added

- `prefunded_sale` module: a fixed-price, pre-funded token sale (presale / IDO) over a fixed inventory, generic over a witness-gated pricing curve, with an `Init -> Active -> Finalized | Cancelled` lifecycle and permissionless buyer redemption (`purchase`, `finalize`, `cancel_after_close`, `claim` / `refund`). (#414)
- `fixed_rate_curve` module: the built-in `allocation = paid * rate` curve, minting the `Quote` and `ActivationTicket` a `FixedRateCurve` sale requires. (#414)
- `refund_vault` module: a generic refundable escrow over `Balance<P>` that holds proceeds on cancel and pays buyers back individually; usable standalone. (#414)

### `openzeppelin_collections`

#### Added

- New `openzeppelin_collections` package: an ordered-collections family in a single package, with two modules - `sorted_map` and `sorted_set`. Both provide bare (built-in integer `<`) and `_by` (custom comparator) macro forms. (#454)

## 1.4.0 (09-07-2026)

### `openzeppelin_allowance`

#### Added

- New `spend_vault` module: a shared multi-coin vault that grants capped, expiring, revocable spending allowances to capability holders. (#402)

### `openzeppelin_finance`

#### Added

- New `vesting_wallet` module: a curve-agnostic release-accounting core for authoring custom vesting curves.
- New `vesting_wallet_linear` module: built-in linear/stepped vesting with an optional cliff, plus a continuous mode.

## 1.3.0 (15-06-2026)

### `openzeppelin_math`

#### Added

- Added `vector::median!` macro for unsigned integer vectors with rounding for even lengths. (#362)

#### Changed

- `u128::is_power_of_ten` and `u256::is_power_of_ten` now compute the result via `log10_floor` and `pow` instead of a hardcoded lookup table. (#323)

### `openzeppelin_utils`

#### Added

- New `rate_limiter` module: an embeddable rate-limiting primitive with three strategies behind one enum. (#315)

## 1.2.0 (03-06-2026)

### `openzeppelin_access`

#### Added

- `access_control` module for role-based access control with typed `Auth<Role>` capabilities and timelocked root transfer.

### `openzeppelin_fp_math`

#### Added

- `sqrt` for `UD30x9` and `SD29x9` with round-down semantics. (#286)
- `log2`, `ln`, `log10` for `UD30x9` (rounds down) and `SD29x9` (rounds toward zero). (#320)

## 1.1.0 (21-04-2026)

### `openzeppelin_fp_math`

#### Added

- `SD29x9::rem` function for truncated remainder semantics (sign follows the dividend) (#301)
- Added `UD30x9::unchecked_lshift` and `UD30x9::unchecked_rshift` with truncating / zero-return behavior for shift operations. (#288)
- Explicit `mul_trunc`, `mul_away`, `div_trunc`, and `div_away` helpers for `UD30x9` and `SD29x9`.
- `ud30x9_convert` for scale-aware whole-number conversions to and from `UD30x9`. (#264)
- `sd29x9_convert` for scale-aware whole-number conversions to and from `SD29x9`. (#264)
- Cross-type casts between `UD30x9` and `SD29x9`, including checked `try_` variants. (#264)
- Object-call syntax for whole-number conversion helpers on `UD30x9` and `SD29x9`. (#264)

#### Changed (Breaking)

- Removed bitwise operations from `SD29x9`.
- Removed public module `casting_u128`; use `ud30x9::wrap` and `sd29x9::wrap` directly for raw casts. (#264)
- `UD30x9::lshift` now aborts on overflow, and both `lshift` and `rshift` now abort on invalid shift sizes. (#288)
- `SD29x9::mod` now uses Euclidean remainder semantics (result is always non-negative). The previous truncated remainder behavior is available via `SD29x9::rem` (#301)
- `UD30x9::sub` now aborts with `EUnderflow` instead of `EOverflow` when the result would be negative (#297)
- `ud30x9_base` abort codes renumbered: `EDivisionByZero` added at code `2`, `ECannotBeConvertedToSD29x9` moved from code `1` to code `3`. Code matching on numeric abort codes must be updated.

#### Fixed

- `SD29x9::pow` now properly handles overflow cases. (#280)

### `openzeppelin_math`

#### Changed

- `vector::quick_sort_by` and `vector::quick_sort` now use the Dutch National Flag partition scheme. (#298)
- `vector::quick_sort_by` and `vector::quick_sort` fall back to insertion sort for sub-partitions of size <= 10. (#298)

#### Fixed

- `u256::is_power_of_ten` helper now properly handles valid `10^77` value. (#291)

## 1.1.0-rc.0 (10-03-2026)

### `openzeppelin_fp_math`

#### Added

- `UD30x9` fixed-point type with: (#129)
  - Core: `wrap`, `unwrap`
  - Arithmetic: `add`, `sub`, `mul`, `div`, `pow`, `unchecked_add`, `unchecked_sub`, `mod`
  - Comparison: `eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `is_zero`
  - Bitwise: `and`, `and2`, `or`, `xor`, `not`, `lshift`, `rshift`
- `SD29x9` fixed-point type with: (#129)
  - Constants: `zero`, `min`, `max`
  - Core: `wrap`, `unwrap`
  - Arithmetic: `add`, `sub`, `mul`, `div`, `pow`, `unchecked_add`, `unchecked_sub`, `mod`
  - Comparison: `eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `is_zero`
  - Bitwise: `and`, `and2`, `or`, `xor`, `not`, `lshift`, `rshift`
- `casting_u128` helpers for `UD30x9` and `SD29x9`. (#129)

### `openzeppelin_math`

#### Added

- `is_power_of_ten` helpers for `u8`, `u16`, `u32`, `u64`, `u128`, and `u256`. (#125)

## 1.0.0 (04-03-2026)

### `openzeppelin_access`

#### Added

- Add missing event emissions on state changes (#159)
- `two_step_transfer::request_borrow_val` and `request_return_val` for borrowing the wrapper and its inner object during a pending transfer.
- `two_step_transfer::RequestBorrow` hot potato to guarantee wrapper return after `request_borrow_val`.

#### Changed (Breaking)

- Redesigned `two_step_transfer` from a requester-initiated to an owner-initiated flow using shared `PendingOwnershipTransfer` and TTO.
  - `request`, `transfer`, and `reject` replaced by `initiate_transfer`, `accept_transfer`, and `cancel_transfer`.
- Renamed `two_step_transfer` events: `OwnershipRequested` → `TransferInitiated`, `OwnershipTransferred` → `TransferAccepted`, `OwnershipTransferRejected` → `TransferCancelled`.
- All events in `two_step_transfer` and `delayed_transfer` now carry `phantom T` for type-specific indexing.
- `two_step_transfer::unwrap` now accepts an additional `&mut TxContext` param (#159)
- `delayed_transfer::wrap` now takes an explicit `recipient` and transfers the wrapper to that address instead of returning `DelayedTransferWrapper<T>`.
- `delayed_transfer::schedule_transfer` and `schedule_unwrap` now derive `current_owner` from `ctx.sender()` instead of accepting it as a parameter (#174)
- Emit dedicated `UnwrapExecuted` event on `delayed_transfer::unwrap` instead of `OwnershipTransferred` (#168)

### `openzeppelin_math`

#### Fixed

- Preserve the remainder for `u512::div_rem_u256` even when the quotient overflows, preventing incorrect results in `mul_mod` for large operands (#151)

## 1.0.0-rc.1 (19-12-2025)

### `openzeppelin_math`

#### Changed

- Rename `coin_utils` module to `decimal_scaling` (#123)

### All Packages

#### Fixed

- Add `#[test_only]` attribute to test modules (#122)

## 1.0.0-rc.0 (28-11-2025)

### `openzeppelin_math`

#### Added

- `rounding::RoundingMode` enum plus helpers for expressing Down/Up/Nearest behavior reused across all arithmetic APIs.
- public `u8`, `u16`, `u32`, `u64`, `u128`, and `u256` modules exposing averaged computations, checked shifting, configurable `mul_div` and `mul_shr`, logarithms, square roots, and modular math helpers tailored to each bit width.
- `u512` wide integer type that supports splitting, multiplication, and division helpers to safely handle 512-bit intermediates needed by the narrow modules.
- `decimal_scaling` helpers that upcast or downcast values between decimal domains (up to 24 decimals) with overflow checks and explicit truncation semantics.

### `openzeppelin_access`

#### Added

- `two_step_transfer` module that wraps a `key + store` object behind a two-step transfer flow.
- `delayed_transfer` module that enforces configurable, clock-based delays before transferring or unwrapping an object.

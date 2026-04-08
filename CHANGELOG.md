<!-- markdownlint-disable MD024 -->

# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)

## Unreleased

### `openzeppelin_fp_math`

#### Added

- Explicit `mul_trunc`, `mul_away`, `div_trunc`, and `div_away` helpers for `UD30x9` and `SD29x9`.
- `ud30x9_convert` for scale-aware whole-number conversions to and from `UD30x9`. (#264)
- `sd29x9_convert` for scale-aware whole-number conversions to and from `SD29x9`. (#264)
- Cross-type casts between `UD30x9` and `SD29x9`, including checked `try_` variants. (#264)
- Object-call syntax for whole-number conversion helpers on `UD30x9` and `SD29x9`. (#264)

#### Changed (Breaking)

- Removed bitwise operations from `SD29x9`.
- Removed public module `casting_u128`; use `ud30x9::wrap` and `sd29x9::wrap` directly for raw casts. (#264)
- `SD29x9::rem` function for truncated remainder semantics (sign follows the dividend) (#301)
- `SD29x9::mod` now uses Euclidean remainder semantics (result is always non-negative). The previous truncated remainder behavior is available via `SD29x9::rem` (#301)
- `UD30x9::sub` now aborts with `EUnderflow` instead of `EOverflow` when the result would be negative (#297)
- `ud30x9_base` abort codes renumbered: `EDivisionByZero` added at code `2`, `ECannotBeConvertedToSD29x9` moved from code `1` to code `3`. Code matching on numeric abort codes must be updated.

### `openzeppelin_math`

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

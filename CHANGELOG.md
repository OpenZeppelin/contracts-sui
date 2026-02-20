<!-- markdownlint-disable MD024 -->

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### `openzeppelin_access`

#### Changed (Breaking)

- Redesigned `two_step_transfer` from a requester-initiated to an owner-initiated flow using shared `OwnershipTransferRequest` and TTO.
  - `request`, `transfer`, and `reject` replaced by `initiate_transfer`, `accept_transfer`, and `cancel_transfer`.
- Renamed `two_step_transfer` events: `OwnershipRequested` → `TransferInitiated`, `OwnershipTransferred` → `TransferAccepted`, `OwnershipTransferRejected` → `TransferCancelled`.
- All events in `two_step_transfer` and `delayed_transfer` now carry `phantom T` for type-specific indexing.
- `two_step_transfer::unwrap` now accepts an additional `&mut TxContext` param (#159)

#### Added

- Add missing event emissions on state changes (#159)
- `two_step_transfer::request_borrow_val` and `request_return_val` for borrowing the wrapper and its inner object during a pending transfer.
- `two_step_transfer::RequestBorrow` hot potato to guarantee wrapper return after `request_borrow_val`.

### `openzeppelin_math`

#### Fixed

- Preserve the remainder for `u512::div_rem_u256` even when the quotient overflows, preventing incorrect results in `mul_mod` for large operands (#151)

##  1.0.0-rc.1 (19-12-2025)

### `openzeppelin_math`

#### Changed

- Rename `coin_utils` module to `decimal_scaling` (#123)

### All Packages

#### Fixed

- Add `#[test_only]` attribute to test modules (#122)

##  1.0.0-rc.0 (28-11-2025)

### `openzeppelin_math`

#### Added

- `rounding::RoundingMode` enum plus helpers for expressing Down/Up/Nearest behavior reused across all arithmetic APIs.
- public `u8`, `u16`, `u32`, `u64`, `u128`, and `u256` modules exposing averaged computations, checked shifting, configurable `mul_div` and `mul_shr`, logarithms, square roots, and modular math helpers tailored to each bit width.
- `u512` wide integer type that supports splitting, multiplication, and division helpers to safely handle 512-bit intermediates needed by the narrow modules.
- `decimal_scaling` helpers that upcast or downcast values between decimal domains (up to 24 decimals) with overflow checks and explicit truncation semantics.

### `openzeppelin_access`

#### Added

- `two_step_transfer` module that wraps a `key + store` object behind a request/approve flow.
- `delayed_transfer` module that enforces configurable, clock-based delays before transferring or unwrapping an object.

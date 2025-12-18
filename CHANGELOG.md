<!-- markdownlint-disable MD024 -->

# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

### `openzeppelin_math`

- Added `rounding::RoundingMode` enum plus helpers for expressing Down/Up/Nearest behavior reused across all arithmetic APIs.
- Added public `u8`, `u16`, `u32`, `u64`, `u128`, and `u256` modules exposing averaged computations, checked shifting, configurable `mul_div` and `mul_shr`, logarithms, square roots, and modular math helpers tailored to each bit width.
- Added `u512` wide integer type that supports splitting, multiplication, and division helpers to safely handle 512-bit intermediates needed by the narrow modules.
- Added `coin_utils` helpers that upcast or downcast balances between decimal domains (up to 24 decimals) with overflow checks and explicit truncation semantics.

### `openzeppelin_access`

- Added `two_step_transfer` module that wraps a `key + store` capability behind a request/approve flow.
- Added `delayed_transfer` module that enforces configurable, clock-based delays before transferring or unwrapping a capability.

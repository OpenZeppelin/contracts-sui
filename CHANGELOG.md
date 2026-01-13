<!-- markdownlint-disable MD024 -->

# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)

## Unreleased

### `openzeppelin_fp_math`

#### Added

- `UD30x9` fixed-point type with: (#129)
  - Core: `wrap`, `unwrap`
  - Arithmetic: `add`, `sub`, `unchecked_add`, `unchecked_sub`, `mod`
  - Comparison: `eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `is_zero`
  - Bitwise: `and`, `and2`, `or`, `xor`, `not`, `lshift`, `rshift`
- `SD29x9` fixed-point type with: (#129)
  - Constants: `zero`, `min`, `max`
  - Core: `wrap`, `unwrap`
  - Arithmetic: `add`, `sub`, `unchecked_add`, `unchecked_sub`, `mod`
  - Comparison: `eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `is_zero`
  - Bitwise: `and`, `and2`, `or`, `xor`, `not`, `lshift`, `rshift`
- `casting_u128` helpers for `UD30x9` and `SD29x9`. (#129)

### `openzeppelin_math`

#### Added

- `is_power_of_ten` helpers for `u8`, `u16`, `u32`, `u64`, `u128`, and `u256`. (#125)

##  1.0.0-rc.0 (28-11-2025)

### `openzeppelin_math`

#### Added

- `rounding::RoundingMode` enum plus helpers for expressing Down/Up/Nearest behavior reused across all arithmetic APIs.
- public `u8`, `u16`, `u32`, `u64`, `u128`, and `u256` modules exposing averaged computations, checked shifting, configurable `mul_div` and `mul_shr`, logarithms, square roots, and modular math helpers tailored to each bit width.
- `u512` wide integer type that supports splitting, multiplication, and division helpers to safely handle 512-bit intermediates needed by the narrow modules.
- `decimal_scaling` helpers that upcast or downcast values between decimal domains (up to 24 decimals) with overflow checks and explicit truncation semantics.

### `openzeppelin_access`

#### Added

- `two_step_transfer` module that wraps a `key + store` capability behind a request/approve flow.
- `delayed_transfer` module that enforces configurable, clock-based delays before transferring or unwrapping a capability.

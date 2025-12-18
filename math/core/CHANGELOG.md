<!-- markdownlint-disable MD024 -->

# Changelog

All notable changes to the `openzeppelin_math` package will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)

## Unreleased

### Added

- `rounding::RoundingMode` enum plus helpers for expressing Down/Up/Nearest behavior reused across all arithmetic APIs.
- Public `u8`, `u16`, `u32`, `u64`, `u128`, and `u256` modules exposing averaged computations, checked shifting, configurable `mul_div` and `mul_shr`, logarithms, square roots, and modular math helpers tailored to each bit width.
- `u512` wide integer type that supports splitting, multiplication, and division helpers to safely handle 512-bit intermediates needed by the narrow modules.
- `coin_utils` helpers that upcast or downcast balances between decimal domains (up to 24 decimals) with overflow checks and explicit truncation semantics.

# `openzeppelin_math`

Overflow-safe arithmetic helpers for unsigned integers with configurable rounding.

## Install

```toml
[dependencies]
openzeppelin_math = { r.mvr = "@openzeppelin-move/integer-math" }
```

## What it provides

Operations for `u8`, `u16`, `u32`, `u64`, `u128`, and `u256`, including:

- `mul_div`: Multiply then divide with rounding
- `mul_shr`: Multiply then shift right with rounding
- `average`: Arithmetic mean with rounding
- `checked_shl` / `checked_shr`: Safe shifts that return `Option`
- `clz`: Count leading zero bits
- `msb`: Position of the most significant bit
- `log2` / `log10` / `log256`: Integer logs with rounding
- `sqrt`: Integer square root with rounding
- `inv_mod`: Modular multiplicative inverse
- `mul_mod`: Modular multiplication
- `is_power_of_ten`: Power-of-ten check
- Decimal scaling helpers

### Vector operations

Generic over `u8`..`u256`, with comparator-based sorting available for other types:

- `vector::quick_sort!` / `vector::quick_sort_by!`: In-place iterative quicksort with three-way partitioning
- `vector::median!`: Median of a borrowed unsigned integer vector with configurable rounding for even-length input; uses quickselect instead of sorting the full vector and aborts on empty input
- `vector::median_u8` … `vector::median_u256`: Precompiled median wrappers for each unsigned integer width (`u8`, `u16`, `u32`, `u64`, `u128`, `u256`); same quickselect algorithm and abort behavior as `median!`, with the selection bytecode compiled once in the library instead of inlined at the call site

## Rounding modes

- **Down**: Round toward zero (truncate)
- **Up**: Round away from zero (ceiling)
- **Nearest**: Round to the closest integer; ties round up

## Usage examples

```move
use openzeppelin_math::rounding;
use openzeppelin_math::u128;

let result = u128::mul_div(100, 200, 3, rounding::up());
// result = Some(6667) (rounded up from 6666.66...)
```

```move
use openzeppelin_math::rounding;
use openzeppelin_math::u64;

let mean = u64::average(5, 6, rounding::down());
// mean = 5
```

```move
use openzeppelin_math::rounding;
use openzeppelin_math::vector;

let med = vector::median!(&vector[5u64, 1, 9, 3, 7], rounding::down());
// med = 5
```

## Examples

> [!Warning]
> These are **unaudited illustrations** of how the primitives can be integrated, not production-ready code.

Complete, compilable integration examples live in [`examples/`](examples):

- [`integer_math`](examples/integer_math/amm_quote.move) - a constant-product AMM pricing toolkit: `mul_div` for swap quotes (output rounded down, fee rounded up), `sqrt` for LP shares, `average`, `mul_shr` for a Q32.32 factor, and `log10` for magnitude, plus the same `mul_div` one width up on `u256` returning `none` on overflow.
- [`rounding`](examples/rounding/fee_split.move) - a solvency-preserving fee/payout splitter: round one side with the chosen `RoundingMode`, derive the other as the remainder, so the parts always sum to the whole. Shows why Down/Up/Nearest is an economic decision.
- [`vector`](examples/vector/median_oracle.move) - a bounded median price oracle: `median_u64` for a manipulation-resistant aggregate and the `quick_sort!` macro for a sorted view.
- [`decimal_scaling`](examples/decimal_scaling/token_normalizer.move) - a ledger that reconciles one token's 6-decimal canonical and 9-decimal bridged forms onto a common 18-decimal `u256` basis with `safe_upcast_balance` / `safe_downcast_balance`, where downcasting truncates dust to preserve solvency.

## Learn More

- [Integer math package overview](https://docs.openzeppelin.com/contracts-sui/1.x/math)
- [Integer math API reference](https://docs.openzeppelin.com/contracts-sui/1.x/api/math)
- [`llms.txt`](https://raw.githubusercontent.com/OpenZeppelin/contracts-sui/main/llms.txt): discovery entry point for AI integrators
- [OpenZeppelin Contracts for Sui](https://docs.openzeppelin.com/contracts-sui)

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

## Rounding modes

- **Down**: Round toward zero (truncate)
- **Up**: Round away from zero (ceiling)
- **Nearest**: Round to the closest integer; ties round up

## Usage examples

```move
use openzeppelin_math::{u128, rounding};

let result = u128::mul_div(100, 200, 3, rounding::up());
// result = Some(6667) (rounded up from 6666.66...)
```

```move
use openzeppelin_math::{u64, rounding};

let mean = u64::average(5, 6, rounding::down());
// mean = 5
```

## Learn More

- [Integer math package overview](https://docs.openzeppelin.com/contracts-sui/1.x/math)
- [Integer math API reference](https://docs.openzeppelin.com/contracts-sui/1.x/api/math)
- [OpenZeppelin Contracts for Sui](https://docs.openzeppelin.com/contracts-sui)

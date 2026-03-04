# `openzeppelin_fp_math`

Fixed-point decimal types with 9 decimals (10^9), matching Sui coin precision.

## Types

- `UD30x9`: Unsigned decimal fixed-point (internal: 0 to 2^128 - 1; decimal: 0 to ~3.4e29)
- `SD29x9`: Signed decimal fixed-point (two's complement, internal: -2^127 to 2^127 - 1; decimal: ~-1.7e29 to ~1.7e29)

## Operations

- Arithmetic: `add`, `sub`, `unchecked_add`, `unchecked_sub`, `mod`
- Comparison: `eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `is_zero`
- Bitwise: `and`, `and2`, `or`, `xor`, `not`, `lshift`, `rshift`

## Casting and helpers

```rust
use openzeppelin_fp_math::{sd29x9, ud30x9};
use openzeppelin_fp_math::casting_u128::into_UD30x9;
use fun into_UD30x9 as u128.into_UD30x9;

let value = ud30x9::wrap(1000000000); // 1.0
let value = 1000000000_u128.into_UD30x9(); // Casting

let positive = sd29x9::wrap(1000000000, false); // 1.0
let negative = sd29x9::wrap(1000000000, true); // -1.0
let zero = sd29x9::zero();
```

## Usage example

```rust
use openzeppelin_fp_math::{sd29x9, ud30x9};

let price1 = ud30x9::wrap(1500000000); // 1.5
let price2 = ud30x9::wrap(2000000000); // 2.0
let total = price1.add(price2); // 3.5

let balance = sd29x9::wrap(10000000000, false); // 10.0
let adjustment = sd29x9::wrap(2500000000, true); // -2.5
let new_balance = balance.add(adjustment); // 7.5
```

## Notes

- Stored as `u128` scaled by 10^9
- Right shifts preserve sign for `SD29x9` (arithmetic) and zero-fill for `UD30x9` (logical)

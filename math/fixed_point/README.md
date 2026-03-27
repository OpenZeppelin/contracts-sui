# `openzeppelin_fp_math`

Fixed-point decimal types with 9 decimals (10^9), matching Sui coin precision.

## Types

- `UD30x9`: Unsigned decimal fixed-point (internal: 0 to 2^128 - 1; decimal: 0 to ~3.4e29)
- `SD29x9`: Signed decimal fixed-point (two's complement, internal: -2^127 to 2^127 - 1; decimal: ~-1.7e29 to ~1.7e29)

## Operations

- Arithmetic: `add`, `sub`, `unchecked_add`, `unchecked_sub`, `mod`
- Comparison: `eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `is_zero`
- Bitwise: `and`, `and2`, `or`, `xor`, `not`, `lshift`, `rshift`

## Raw Casting

The core `wrap` / `unwrap` APIs and `casting_u128` module are **raw casts**.
They preserve the underlying fixed-point bits and do not multiply or divide by
`10^9`.

```rust
use openzeppelin_fp_math::{casting_u128, sd29x9, ud30x9};

let one = ud30x9::wrap(1_000_000_000); // 1.0
let raw = casting_u128::into_UD30x9(42); // Raw bits, not 42.0

let positive = sd29x9::wrap(1_000_000_000, false); // 1.0
let negative = casting_u128::into_SD29x9(42, true); // Raw bits for -0.000000042
```

## Whole-Number Conversions

Use the conversion modules when you want semantic integer conversions that
apply the fixed-point scale for you.

```rust
use openzeppelin_fp_math::{sd29x9_convert, ud30x9_convert};

let whole = ud30x9_convert::from_u128(42); // 42.0
let back = ud30x9_convert::to_u128_trunc(whole); // 42

let delta = sd29x9_convert::from_u128(5, true); // -5.0
let (magnitude, is_negative) = sd29x9_convert::to_parts_trunc(delta);
// magnitude == 5, is_negative == true
```

Because Move does not provide a native signed integer type for this package,
`SD29x9` conversions use an unsigned magnitude plus a sign flag instead of a
single `i128`-style input or output.

## Usage Example

```rust
use openzeppelin_fp_math::{sd29x9, sd29x9_convert, ud30x9, ud30x9_convert};

let price1 = ud30x9_convert::from_u128(1).add(ud30x9::wrap(500_000_000)); // 1.5
let price2 = ud30x9_convert::from_u128(2); // 2.0
let total = price1.add(price2); // 3.5

let balance = sd29x9_convert::from_u128(10, false); // 10.0
let adjustment = sd29x9_convert::from_u128(2, true).add(sd29x9::wrap(500_000_000, true)); // -2.5
let new_balance = balance.add(adjustment); // 7.5
```

## Notes

- Stored as `u128` scaled by 10^9
- Raw casts preserve scaled bits exactly; conversion helpers multiply or divide by `10^9`
- Right shifts preserve sign for `SD29x9` (arithmetic) and zero-fill for `UD30x9` (logical)
- `UD30x9.mul`/`UD30x9.div` and `SD29x9.mul`/`SD29x9.div` rescale with truncating integer
  division; for `UD30x9` this means rounding down, while for `SD29x9` this means truncation
  toward zero when results cannot be represented exactly with 9 decimals
- `pow` uses iterative truncating multiplication, so fractional results are approximate and can
  drift toward zero for large exponents

# `openzeppelin_fp_math`

Fixed-point decimal types with 9 decimals (10^9), matching Sui coin precision.

## Types

- `UD30x9`: Unsigned decimal fixed-point (internal: 0 to 2^128 - 1; decimal: 0 to ~3.4e29)
- `SD29x9`: Signed decimal fixed-point (two's complement, internal: -2^127 to 2^127 - 1; decimal: ~-1.7e29 to ~1.7e29)

## Operations

- Arithmetic: `add`, `sub`, `unchecked_add`, `unchecked_sub`, `mod`
- Comparison: `eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `is_zero`
- `UD30x9` also exposes bitwise helpers: `and`, `and2`, `or`, `xor`, `not`, `lshift`, `rshift`, `unchecked_lshift`, `unchecked_rshift`

## Casting vs Converting

This package uses **casting** and **converting** for different operations:

- **Casting** preserves the fixed-point scale already present in the value.
  It may reinterpret raw bits, or move between fixed-point types with only
  sign and range checks. It does **not** multiply or divide by `10^9`.
- **Converting** changes between whole-number semantics and fixed-point
  semantics. It applies or removes the `10^9` scale factor.

Rule of thumb:

- Use a **cast** when your input is already in raw fixed-point form.
- Use a **conversion** when your input is a whole integer like `42` and you
  mean `42.0`.

## Raw Casts

The core `wrap` / `unwrap` APIs are **raw casts**. They preserve the
underlying fixed-point representation and do not multiply or divide by `10^9`.

```rust
use openzeppelin_fp_math::{sd29x9, ud30x9};

let one = ud30x9::wrap(1_000_000_000); // 1.0
let raw = ud30x9::wrap(42); // Raw bits, not 42.0

let positive = sd29x9::wrap(1_000_000_000, false); // 1.0
let negative = sd29x9::wrap(42, true); // Raw bits for -0.000000042
```

## Cross-Type Fixed-Point Casts

Casting also includes moves between fixed-point types that keep the same
scaled numeric meaning and only validate signedness or range.

```rust
use openzeppelin_fp_math::{sd29x9, ud30x9_convert};

let unsigned = ud30x9_convert::from_u128(42); // 42.0
let signed = unsigned.into_SD29x9(); // 42.0 as SD29x9
let roundtrip = signed.into_UD30x9(); // 42.0 as UD30x9
```

These casts do not rescale the value. For example, `42.123456789` stays
`42.123456789`; only the target type changes.

## Whole-Number Conversions

Use the conversion modules when you want semantic integer conversions that
apply the fixed-point scale for you.

```rust
use openzeppelin_fp_math::{sd29x9_convert, ud30x9_convert};

let whole = ud30x9_convert::from_u128(42); // 42.0
let back = whole.to_u128_trunc(); // 42

let delta = sd29x9_convert::from_u128(5, true); // -5.0
let (magnitude, is_negative) = delta.to_parts_trunc();
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
